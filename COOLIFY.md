# Deploying loucent-mautic to Coolify v4

This repo ships a Coolify-ready production stack for **Mautic 7.2**:

| File | Purpose |
|---|---|
| `Dockerfile` | Production image (`php:8.3-apache-bookworm` + all Mautic extensions, Composer deps, frontend assets) |
| `docker-compose.yml` | Coolify stack: `db` (MySQL 8.4) + `mautic_web` + `mautic_cron` + `mautic_worker` |
| `docker/entrypoint.sh` | First-boot auto-install / migrations, then starts the service role |
| `docker/mautic.crontab` | Mautic cron cadence (segments, campaigns, emails, broadcasts, cleanup) |
| `docker/supervisord.conf` | Messenger workers (`email` / `hit` / `failed`) |
| `docker/php-coolify.ini` | Production PHP defaults (512M, OPcache, `zend.assertions=-1`) |
| `.env.coolify.example` | All env vars Coolify needs (no real secrets) |

> **Important:** deploy this as a **Docker Compose** resource, NOT as an Application.
> An Application resource triggers Coolify's Railpack auto-detect (`frankenphp`,
> `railpack-plan.json`) which lacks Mautic's PHP extensions and fails at
> `composer install` (exit code 2). If your build log mentions `frankenphp` or
> `railpack`, you're on the wrong resource type.

## Prerequisites

- Coolify v4 server with Traefik proxy running and a domain pointed at it
  (e.g. `mautic.yourdomain.com` → server IP via DNS A record).
- This repo connected to Coolify (GitHub App or deploy key with read access).

## 1. Create the resource

1. Coolify dashboard → **Projects** → your project → environment → **+ Add Resource**.
2. Choose **Docker Compose** (do NOT choose Application / Dockerfile / Nixpacks).
3. Connect Git repository: `moreishi/mautic-app`, branch `main`.
4. Coolify loads `docker-compose.yml` from the repo root. Leave the compose file
   as-is — it follows Coolify conventions (no custom `networks:`, no `ports:`
   on web, named volumes only).

## 2. Set environment variables

In the resource → **Environment Variables**, add every key from
`.env.coolify.example`. Required values (generate fresh secrets — never reuse
the placeholders):

```bash
APP_ENV=prod
APP_DEBUG=0

MYSQL_DATABASE=mautic
MYSQL_USER=mautic
MYSQL_PASSWORD=<32+ random chars>
MYSQL_ROOT_PASSWORD=<32+ random chars>

MAUTIC_SITE_URL=https://mautic.yourdomain.com
MAUTIC_ADMIN_EMAIL=mautic@yourdomain.com
MAUTIC_ADMIN_PASSWORD=<strong admin password>
MAUTIC_MAILER_DSN=smtp://localhost:1025

DOCKER_MAUTIC_RUN_MIGRATIONS=true
DOCKER_MAUTIC_WORKERS_CONSUME_EMAIL=2
DOCKER_MAUTIC_WORKERS_CONSUME_HIT=2
DOCKER_MAUTIC_WORKERS_CONSUME_FAILED=2
```

> Mautic 7.2 requires **MySQL 8.4+** (or MariaDB 10.11+) — the compose file
> already pins `mysql:8.4`. Mautic core hardcodes `pdo_mysql`, so do not point
> it at Postgres.

## 3. Deploy

1. Click **Deploy**. The first build takes ~10–15 minutes (Composer install,
   `npm run build`, `mautic:assets:generate`) — this is normal.
2. Watch the `mautic_web` logs. A healthy first boot shows:
   ```
   [entrypoint] role=mautic_web db=db:3306/mautic
   [entrypoint] database reachable
   [entrypoint] generating /var/www/html/config/local.php from environment...
   [entrypoint] fresh install: https://mautic.yourdomain.com
   [entrypoint] starting apache...
   ```
   Redeploys instead show `existing install detected` + `running migrations...`.
3. Set the domain: in the resource, find service **`mautic_web`** → **Domains /
   FQDN** → `https://mautic.yourdomain.com` → redeploy. Traefik provisions the
   Let's Encrypt certificate automatically.

## 4. Verify

- Open `https://mautic.yourdomain.com/s/login` → log in with
  `MAUTIC_ADMIN_EMAIL` / `MAUTIC_ADMIN_PASSWORD`.
- `mautic_cron` runs segments/campaigns/emails on schedule
  (see `docker/mautic.crontab`); check `var/logs/cron.log` via the Coolify
  terminal if sends seem stuck.
- `mautic_worker` consumes the `email` / `hit` / `failed` messenger queues.

## Updates

1. Push to `main` (or your tracked branch).
2. In Coolify, **Redeploy**. The entrypoint runs pending Doctrine migrations
   automatically (`DOCKER_MAUTIC_RUN_MIGRATIONS=true`).
3. Persistent data (`config/local.php`, uploads, logs, MySQL) lives in named
   volumes and survives redeploys. When deleting the resource, choose
   **Keep Volumes** unless you intend a full wipe.

## Backups

- **Database:** schedule Coolify database backups (or `mysqldump` from the
  `db` service) to S3.
- **Volumes:** snapshot `mautic-config`, `mautic-files`, `mautic-images`, e.g.:
  ```bash
  docker run --rm -v <stack>_mautic-files:/data -v /backups:/backup \
    alpine tar czf /backup/mautic-files-$(date +%Y%m%d).tar.gz /data
  ```

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Build log shows `frankenphp` / `railpack-plan.json` / `composer install ... exit code: 2` | Wrong resource type (Application + Railpack). Recreate as **Docker Compose**. |
| `database not reachable after 90s` | `MYSQL_*` vars mismatch between `db` and Mautic services, or `db` unhealthy — check `db` logs. |
| `MAUTIC_SITE_URL is required` / `MAUTIC_ADMIN_PASSWORD is required` | Missing env vars on first boot; add them and redeploy. |
| 504 / app unreachable after deploy | Custom `networks:` in compose (none here — don't add any) or missing FQDN on `mautic_web`. |
| White page / cache issues after update | Terminal into `mautic_web`: `php bin/console cache:clear --env=prod && php bin/console mautic:assets:generate --env=prod`. |
