#!/bin/bash
set -e
# Coolify entrypoint for loucent-mautic
# Roles: mautic_web (apache), cron, worker
# - Generates config/local.php from env on first boot if missing
# - Waits for DB, runs migrations or fresh install, warms cache
# - Fixes permissions, then execs the role command

ROLE="${DOCKER_MAUTIC_ROLE:-mautic_web}"
# Allow `docker run image cron` / `worker` as shorthand (compose uses command: ["cron"])
if [ "${1:-}" = "cron" ]; then ROLE="mautic_cron"; shift; fi
if [ "${1:-}" = "worker" ]; then ROLE="mautic_worker"; shift; fi

: "${MAUTIC_DB_DRIVER:=pdo_mysql}"
: "${MAUTIC_DB_HOST:=db}"
: "${MAUTIC_DB_PORT:=3306}"
: "${MAUTIC_DB_DATABASE:?MAUTIC_DB_DATABASE is required}"
: "${MAUTIC_DB_USER:?MAUTIC_DB_USER is required}"
: "${MAUTIC_DB_PASSWORD:?MAUTIC_DB_PASSWORD is required}"
: "${MAUTIC_SITE_URL:=}"
: "${MAUTIC_ADMIN_EMAIL:=mautic@example.com}"
: "${MAUTIC_ADMIN_PASSWORD:=}"
: "${MAUTIC_MAILER_DSN:=smtp://localhost:1025}"
: "${DOCKER_MAUTIC_RUN_MIGRATIONS:=true}"

LOCAL_PHP="/var/www/html/config/local.php"

echo "[entrypoint] role=${ROLE} driver=${MAUTIC_DB_DRIVER} db=${MAUTIC_DB_HOST}:${MAUTIC_DB_PORT}/${MAUTIC_DB_DATABASE}"

# Wait for database (MySQL via mysqladmin, Postgres via pg_isready), max ~90s
echo "[entrypoint] waiting for database..."
if [ "${MAUTIC_DB_DRIVER}" = "pdo_pgsql" ]; then
  export PGPASSWORD="${MAUTIC_DB_PASSWORD}"
  for i in $(seq 1 45); do
    if pg_isready -h"${MAUTIC_DB_HOST}" -p"${MAUTIC_DB_PORT}" -U"${MAUTIC_DB_USER}" -d"${MAUTIC_DB_DATABASE}" 2>/dev/null; then
      echo "[entrypoint] database reachable"
      break
    fi
    if [ "$i" -eq 45 ]; then
      echo "[entrypoint] ERROR: database not reachable after 90s" >&2
      exit 1
    fi
    sleep 2
  done
else
  for i in $(seq 1 45); do
    if mysqladmin ping -h"${MAUTIC_DB_HOST}" -P"${MAUTIC_DB_PORT}" -u"${MAUTIC_DB_USER}" -p"${MAUTIC_DB_PASSWORD}" --silent 2>/dev/null; then
      echo "[entrypoint] database reachable"
      break
    fi
    if [ "$i" -eq 45 ]; then
      echo "[entrypoint] ERROR: database not reachable after 90s" >&2
      exit 1
    fi
    sleep 2
  done
fi

# Generate local.php on first boot so config volume persists it
if [ ! -f "${LOCAL_PHP}" ]; then
  echo "[entrypoint] generating ${LOCAL_PHP} from environment..."
  if [ -z "${MAUTIC_SITE_URL}" ]; then
    echo "[entrypoint] ERROR: MAUTIC_SITE_URL is required for first install" >&2
    exit 1
  fi
  if [ -z "${MAUTIC_ADMIN_PASSWORD}" ] && [ "${ROLE}" = "mautic_web" ]; then
    echo "[entrypoint] ERROR: MAUTIC_ADMIN_PASSWORD is required for first install" >&2
    exit 1
  fi
  cat > "${LOCAL_PHP}" <<PHP
<?php
\$parameters = [
    'api_enabled'           => true,
    'api_enable_basic_auth' => true,
    // NOTE: Mautic 7.2 core forces pdo_mysql in ParameterLoader; pdo_pgsql
    // value is written for forward-compat but currently ignored by Mautic.
    'db_driver'             => '${MAUTIC_DB_DRIVER}',
    'db_host'               => '${MAUTIC_DB_HOST}',
    'db_table_prefix'       => null,
    'db_port'               => ${MAUTIC_DB_PORT},
    'db_name'               => '${MAUTIC_DB_DATABASE}',
    'db_user'               => '${MAUTIC_DB_USER}',
    'db_password'           => '${MAUTIC_DB_PASSWORD}',
    'admin_email'           => '${MAUTIC_ADMIN_EMAIL}',
    'admin_password'        => '${MAUTIC_ADMIN_PASSWORD}',
    'install_source'        => 'Coolify',
    'mailer_from_name'      => 'Mautic',
    'mailer_from_email'     => '${MAUTIC_ADMIN_EMAIL}',
    'mailer_dsn'            => '${MAUTIC_MAILER_DSN}',
];
PHP
fi

chown -R www-data:www-data /var/www/html/config /var/www/html/var 2>/dev/null || true

# Install or migrate (web role only, to avoid races from cron/worker)
if [ "${ROLE}" = "mautic_web" ]; then
  if php bin/console doctrine:query:sql "SELECT 1 FROM users LIMIT 1" --env=prod >/dev/null 2>&1; then
    echo "[entrypoint] existing install detected"
    if [ "${DOCKER_MAUTIC_RUN_MIGRATIONS}" = "true" ]; then
      echo "[entrypoint] running migrations..."
      php bin/console doctrine:migrations:migrate --no-interaction --env=prod || true
      php bin/console cache:warmup --env=prod --no-interaction || true
    fi
  else
    echo "[entrypoint] fresh install: ${MAUTIC_SITE_URL}"
    php bin/console mautic:install "${MAUTIC_SITE_URL}" --force --no-interaction --env=prod
    php bin/console mautic:plugins:reload --env=prod --no-interaction || true
    php bin/console cache:warmup --env=prod --no-interaction || true
  fi
fi

case "${ROLE}" in
  mautic_web)
    echo "[entrypoint] starting apache..."
    exec apache2-foreground "$@"
    ;;
  mautic_cron)
    echo "[entrypoint] starting cron..."
    # Ensure cron file uses current env user
    exec cron -f
    ;;
  mautic_worker)
    echo "[entrypoint] starting messenger workers via supervisor..."
    exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
    ;;
  *)
    echo "[entrypoint] ERROR: unknown role ${ROLE} (want mautic_web|mautic_cron|mautic_worker)" >&2
    exit 1
    ;;
esac
