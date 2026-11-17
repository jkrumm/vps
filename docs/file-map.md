# File map

```
compose.networking.yml        Networking/proxy (cloudflared, Traefik, socket-proxy, RollHook)
compose.infra.yml             Databases (Postgres, Valkey) — internal-only, no exposed ports
compose.monitoring.yml        Monitoring (ClickStack, Beszel, Dozzle, host-agent + host-probe built from agent/, Watchtower, Umami + two socket-proxy instances)
compose.dev.yml               Local dev (Valkey + MariaDB + ClickStack with ports exposed; Postgres is the mini's Homebrew server, not here)
apps/weatherorb/compose.yml        weatherorb-site — nginx:alpine serving `site/` read-only; apex + www routers (www → apex 301). No RollHook, no registry, no env file (V1's edge/account/egress/probe were removed 2026-11-17)
apps/weatherorb/site/index.html   the page: the name and "WeatherOrb is being rebuilt."
apps/rollhook-marketing/compose.yml  rollhook.com marketing site — managed by RollHook
apps/basalt-ui-marketing/compose.yml  basalt-ui.com marketing site (Astro docs) — managed by RollHook
apps/jkrumm-com/compose.yml   jkrumm.com portfolio site (Astro, repo-root Dockerfile) — managed by RollHook, edge cache pattern in docs/edge-cache.md
apps/email-gateway/compose.yml  email-gateway (Bun + Resend) — sends FPP contact-form + daily-analytics + SY Serendipity charter-request emails. RollHook-managed.
apps/imgproxy/compose.yml     imgproxy — image CDN (resize/convert) over a private B2 bucket, served at img.DOMAIN
apps/shutterflow/compose.yml  shutterflow-share (shutterflow.app) + signed shutterflow-imgproxy (cdn.shutterflow.app) — RollHook-managed; source repo is private, bootstrap via apps/shutterflow/scripts/bootstrap-image.sh. Plus the `/releases` update-feed mount (`RELEASES_DIR`) on shutterflow-share, and shutterflow-key-broker (internal only, own env file key-broker.env, built by `make shutterflow-key-broker-image TAG=<sha>`, tag pinned in the compose)
apps/photo-gallery/compose.yml  photo-gallery — static Astro gallery served by nginx from /home/jkrumm/photo-gallery-dist (rsynced from laptop via photo-flow CLI)
apps/fpp/compose.yml          FPP — MariaDB (port 33306 exposed for Vercel) + fpp-server + fpp-analytics + updater sidecar, all RollHook-managed
apps/fpp/scripts/setup-mariadb.sh    Idempotent fpp user/grants — run via make fpp-mariadb-setup
apps/fpp/scripts/backup-mariadb.sh   mariadb-dump → S3 (verified before the Kuma push ping)
apps/fpp/scripts/restore-mariadb.sh  PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
apps/fpp/scripts/restore-mariadb-local.sh  Dev — non-interactive S3 → local mariadb (DR validation + seeding)
apps/fpp/scripts/sync-mariadb-from-vps.sh  Dev — ssh vps + docker exec mariadb-dump → local mariadb (fresh, no S3)
apps/fpp/scripts/cert-sync.sh        Extract *.free-planning-poker.com cert from traefik/acme.json + FLUSH SSL
apps/fpp/fail2ban/                   filter + jail configs installed by setup.sh
apps/fpp/certs/                      gitignored — populated by cert-sync.sh, mounted RO into mariadb
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron, fail2ban)
scripts/setup-postgres.sh     Idempotent schema/user/grant setup (prod) — run via make postgres-setup
scripts/backup-pg.sh          pg_dump → S3 (verified before the Kuma push ping)
scripts/backup-email-gateway.sh  SQLite `.backup` snapshots of email-gateway.sqlite + mail.sqlite → tar.gz → S3 `backups/vps/email-gateway/`; optional Kuma push via `EMAIL_GATEWAY_BACKUP_KUMA_PUSH_URL` (not yet in any template)
scripts/health-pg.sh          SELECT 1 → Uptime Kuma push ping (per-minute liveness)
scripts/db-counts.sh          Exact per-table COUNT(*) (Postgres + MariaDB) — read-only, diff-friendly verification (make db-counts)
scripts/setup-gh-runner.sh    Idempotent per-repo Actions runner for private repos — gh-runner user, rootless Docker, systemd unit (make gh-runner-setup / gh-runner-remove REPO=…, docs/gh-runner.md)
scripts/gh-runner-sync.sh     Registers the runner(s) of every private repo with workflows, per-repo count in instances() (make gh-runner-sync, runs where gh is authenticated)
scripts/gh-runner-clean.sh    Trims a runner's old bin/externals and _work/_update left by self-updates (cron/docker-prune, root, daily)
scripts/gh-runner-watchdog.sh Restarts runners stuck in reconnect back-off — installed by setup as a 5-min systemd timer
scripts/restore-pg.sh         PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
scripts/restore-pg-local.sh   Dev — non-interactive S3 → local whole-DB restore (DR validation + seeding)
scripts/backup-pg-dev.sh      Mac mini Postgres → HomeLab nightly backup (globals, per-DB dumps, counts.tsv, SHA256SUMS; keep 14) — make dev-pg-backup
scripts/restore-drill-pg-dev.sh  Restore drill of the newest mini backup into scratch DBs, counts vs source — make dev-pg-restore-drill
scripts/lib-pg-dev.sh         Shared by the dev-pg scripts: picks the live server per run (container `postgres`, else the bare Homebrew server) and runs the client binaries against it
scripts/health-pg-dev.sh      Mini Postgres readiness probe for the devhost heartbeat — make dev-pg-health
scripts/pg-counts.sh          Exact row counts + relation-kind counts of ONE database (drill); pg-counts.sql is the shared SQL the backup runs inside the dump's snapshot
launchd/                      LaunchAgent template for the mini's nightly Postgres backup (make dev-pg-launchd)
scripts/sync-pg-schema-from-vps.sh  Dev — generic per-schema sync (SCHEMA=argo); least-priv, app role only
scripts/firewall.sh           UFW status — provider-level firewall configured via hosting panel
scripts/seed-cron-env.sh      Materializes cron/*.env.tpl → /etc/vps/*.env, chmod 600 — run via make cron-env-seed
scripts/hyperdx-agent-setup.sh  Prod — idempotent HyperDX agent user + accessKey setup, MCP smoke test (make hyperdx-agent-setup)
scripts/hyperdx-dev-bootstrap.sh  Dev — idempotent local HyperDX user + accessKey bootstrap, MCP smoke test (make hyperdx-dev-bootstrap)
scripts/hyperdx-webhook-setup.sh  Prod — idempotent ntfy webhook ("ntfy alerts", topic `alerts`) setup, token from op://common/ntfy/TOKEN (make hyperdx-webhook-setup)
scripts/hyperdx-sync.sh       Dashboards + alerts-as-code over REST v2 — export/apply (make hyperdx-export / hyperdx-apply)
observability/dashboards/     Dashboard JSON source of truth — see observability/README.md
observability/services.yaml   Telemetry service registry — every service.name that emits, with namespace, host, env, repo, signals (contract: docs/observability.md)
observability/alerts/         Alert JSON source of truth — same export/apply loop (docs/observability.md); every telemetry app has an error alert on the `Factory door` webhook, routed to its repo by a door route named after the alert (docs/observability.md → Per-app error alerts)
cron/pg-backup                Postgres backup, daily 03:00
cron/pg-health                Postgres liveness heartbeat, every minute — sources /etc/vps/pg-health.env (no op run — rate limits)
cron/pg-health.env.tpl        op template for the seeded pg-health cron env (materialized via make cron-env-seed)
cron/fpp-mariadb-backup       MariaDB backup, daily 03:30
cron/email-gateway-backup     email-gateway SQLite backup, daily 03:45
cron/fpp-cert-sync            MariaDB TLS cert sync, every 6h
cron/docker-prune             Daily prune: 04:30 prod daemon (images >48h unused, build cache capped 3 GB, never volumes), 04:35 gh-runner rootless daemon (images, volumes, cache capped 6 GB — `--filter until=` matches nothing on this engine), 04:40 scripts/gh-runner-clean.sh (make prune-cron-install; bounds per directory: docs/disk.md)
cron/disk-watch               Root-disk alert every 15 min: ntfy `alerts` at >= 80 % (scripts/disk-watch.sh, env seeded from cron/disk-watch.env.tpl)
config/journald-vps.conf      journald SystemMaxUse=1G (setup.sh, make journald-install)
README.md → Secrets           All secret variable names with setup instructions (no values in repo)
Makefile                      Operational shortcuts (`PIN_SH`/`pin_all` = the one image-pin helper every RollHook `<app>-up` uses)
.github/workflows/ci.yml      CI: `make check` on every push/PR
scripts/lint-compose.py       Compose-invariants linter (part of `make check`)
scripts/telemetry-lint.py     Telemetry registry vs prod ClickHouse + alert/dashboard drift (make telemetry-lint; rules unit-tested in test_telemetry_lint.py, part of `make check`)
```
