# vps

Infrastructure-as-code for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04). Docker Compose only, no Swarm/Kubernetes. Three compose files by concern (networking incl. RollHook, infra, monitoring) plus one `apps/<name>/compose.yml` per app.

> **Public repo.** Never commit real IPs, hostnames, Tailscale IPs, passwords, tokens, or provider-specific details. Use `<placeholder>` in docs. All actual values in 1Password.

---

## Quick Reference

Environment is controlled by `.env` (gitignored). Locally: `ENV=dev`. On server: `ENV=prod`.
Secrets: `op run --env-file=.env.tpl` — 1Password vaults: `vps` + `common`.

All container operations go through the Makefile — never raw `docker`/`docker compose` (global rule `docker-makefile.md`). Bare `make` prints an ENV-aware help: targets available in the current ENV are highlighted, prod-only / dev-only targets are listed dimmed under "Requires ENV=…". Prod-only and dev-only targets are gated by `require-prod` / `require-dev` prerequisites and refuse to run with the wrong ENV.

```bash
make                     # show ENV-aware help (default target)
# Primary operations — adapts to ENV automatically
make up                  # dev: compose.dev.yml | prod: networking → infra → monitoring
make down                # dev: compose.dev.yml | prod: reverse order

# Targeted restart (prod only — individual stacks)
make networking-up / make networking-down
make infra-up    / make infra-down
make monitoring-up / make monitoring-down
make fpp-up      / make fpp-down
make meteo-up    / make meteo-down   # nginx edge for meteo.DOMAIN; make meteo-env first, basemap under /var/lib/meteo
make imgproxy-up / make imgproxy-down

# Manual image upgrades — Postgres/Valkey/MariaDB are excluded from Watchtower
make infra-upgrade       # postgres + valkey (run make backup first)
make fpp-mariadb-upgrade # mariadb only (run make fpp-backup first)

# DB schema/user provisioning — idempotent, works for both envs
make postgres-setup      # run after make infra-up, before make monitoring-up
make fpp-mariadb-setup   # run after make fpp-up
make cron-env-seed       # materialize /etc/vps/*.env for cron jobs from 1Password (re-run after secret rotation)

# FPP TLS cert sync (extracts *.free-planning-poker.com from traefik/acme.json into apps/fpp/certs/)
make fpp-cert-sync       # run once after networking-up; cron does it every 6h

# HyperDX agent access + dashboards/alerts-as-code (see docs/observability.md → "Agent access")
make hyperdx-agent-setup       # prod — idempotent agent user + accessKey setup, MCP smoke test
make hyperdx-dev-bootstrap     # dev — idempotent local user + accessKey bootstrap, MCP smoke test
make hyperdx-webhook-setup     # prod — idempotent Slack webhook ("Slack #alerts") setup
make hyperdx-export ENV=dev    # export dashboards + alerts → observability/{dashboards,alerts}/*.json
make hyperdx-apply ENV=dev     # validate + upsert (by name) dashboards, then alerts, from those directories
make clickstack-restart        # dev — restart clickstack (fixes a dead local ClickHouse process)

# Status + ops
make ps                  # docker ps with name/status/ports
make db-counts           # exact per-table COUNT(*) (Postgres + MariaDB) — diff to verify a sync/restore matches prod
make shell-postgres      # psql shell (uses op run with .env.tpl)
make fpp-shell           # mariadb shell (uses op run with .env.tpl)
make backup              # manual pg_dump → S3 (prod only — guarded)
make fpp-backup          # manual mariadb-dump → S3 (prod only — guarded)

# Dev — local seeding / DR from prod (all dev-only, never touch prod)
make sync-from-prod      # whole-DB ssh+docker exec pg_dump from VPS → local (fresh, no S3). Drops whole local DB.
make restore-local       # pull latest (or BACKUP_FILE=) S3 pg backup → local. Drops whole local DB.
make pg-sync-schema SCHEMA=argo  # one schema only (least-priv, leaves other schemas intact)
make fpp-sync-from-prod  # direct ssh+docker exec mariadb-dump from VPS → local (fresh, no S3)
make fpp-restore-local   # pull latest S3 backup into local mariadb (DR drill / seed)
make firewall            # show UFW status and rules
make prune-cron-install  # prod — install the weekly Sunday 04:30 image + build-cache prune (cron/docker-prune); never volumes

# Restoring PROD from S3 has NO make target by design (it overwrites production).
# Gated, human-only DR scripts: scripts/restore-pg.sh + apps/fpp/scripts/restore-mariadb.sh
# → see docs/disaster-recovery.md

# Deploy config changes to server
git push && ssh vps "cd ~/vps && git pull"
```

> **SSH:** Tailscale only — enforced by UFW (default-deny inbound, only `tailscale0` allowed in), **not** by sshd's bind address: sshd may listen on all interfaces. Never set `ListenAddress` to the Tailscale IP (sshd fails at boot when `tailscale0` is late — a lock-out). Proof: `make firewall`. `ssh vps` uses the Tailscale IP from `~/.ssh/config`.

---

## Skills

| Skill | Context | Purpose |
|-|-|-|
| `/audit` | main | 9-phase health audit: resources, containers, tunnel, Tailscale, errors, backup, updates, manual upgrades, FPP MariaDB exception |
| `/docs` | main | Documentation maintenance — sync compose files against README/CLAUDE.md, verify Secrets section coverage |
| `/cloudflare` | main | Cloudflare API operations — DNS records, tunnel ingress, multi-domain. Global skill (dotfiles), shared with HomeLab |

---

## Secrets

1Password vaults: `vps` + `common`. Full variable list + setup instructions:
`README.md` → Secrets. **Never write actual values in this repo** —
`<placeholder>` format in docs.

### Injection — two runners, two templates

**Runner** (`SECRET_RUNNER`): `secrets-run` where it exists, plain `op run
--account tkrumm` otherwise — prod (VPS) and the MacBook are both unchanged;
only the mini needs the shim, because a bare `op` there has no human to
answer its biometric prompt and `make up` **blocks** instead of failing (one
run sat wedged 19h, 2026-08-01). `secrets-run` fails closed in a second.

**Template**: prod targets get the full `.env.tpl` (~40 refs, `$(OP_RUN)`);
`require-dev` targets get `.env.dev.tpl` (~12 refs, `$(OP_RUN_DEV)`);
`postgres-setup`/`shell-postgres`/`fpp-shell` follow `$(ENV)` via
`$(OP_RUN_ENV)`. Why the dev template is a stripped-down subset (three
least-privilege choices — dev-only superuser passwords, no S3 credential,
`restore-local` staying MacBook-only) and the full rationale for the
runner split: `docs/secrets-injection.md`.

Per-app schema passwords (`<APP>_DB_PASSWORD`) and every other variable name,
source and setup step: `README.md` → Secrets.

---

## Object Storage — Bucket Layout

S3-compatible object storage, bucket `jkrumm`. All paths are prefixed to avoid collisions across sources:

```
jkrumm/
├── backups/vps/
│   ├── postgres/       ← backup-pg.sh (daily cron 03:00, 14-day retention)
│   └── mariadb/        ← apps/fpp/scripts/backup-mariadb.sh (daily cron 03:30)
└── img/                ← imgproxy origin — read-only, name-prefix-locked B2 key (docs/image-cdn.md)
```

HomeLab backup scripts write their own `backups/homelab/<service>/` prefix
using the same `AWS_*` credentials (`common` vault) — not enumerated here
since none exist yet.

---

## Networks

External networks (pre-created by `setup.sh`, referenced as `external: true`):

| Network | Purpose | Who connects |
|-|-|-|
| `proxy` | Traefik routing | Traefik, all apps |
| `postgres-net` | Postgres access | Postgres, apps needing DB |
| `mariadb-net` | FPP MariaDB access | MariaDB, FPP services, backup container |
| `valkey-net` | Valkey/Redis access | Valkey, apps needing cache |
| `monitoring-net` | Observability bus | ClickStack, Beszel, Dozzle, apps sending OTel |

Internal networks (created by Docker Compose, not external):

| Network | Purpose |
|-|-|
| `socket-proxy-net` | Traefik → socket-proxy (read-only, POST=0) |
| `socket-proxy-rollhook-net` | RollHook → socket-proxy-rollhook (POST=1, write access) |
| `socket-proxy-watchtower-net` | Watchtower → socket-proxy-watchtower (POST=1, write access) |
| `socket-proxy-monitoring-net` | Dozzle + Beszel → socket-proxy-monitoring (read-only, LOGS+STATS) |

**Traffic routing model:**

| Traffic type | Path |
|-|-|
| Public apps + RollHook | Internet → Cloudflare edge → cloudflared (outbound) → Traefik → service |
| Traefik dashboard | DNS-only A → Tailscale IP → Traefik (CGNAT unreachable from internet) |
| OTel data from apps | app → clickstack:4319, unauthed (via monitoring-net) |
| HyperDX UI | DNS-only A → Tailscale IP → Traefik → clickstack:8080 (CGNAT unreachable from internet) |
| OTel from browsers | Cloudflare → Traefik → clickstack:4318 (public, otel.DOMAIN) |
| Postgres / Valkey | Internal Docker networks only — zero exposure |

**Key gotchas:**

- `traefik.yml` static config does NOT support `${ENV_VAR}`. Workarounds: ACME
  email via `TRAEFIK_CERTIFICATESRESOLVERS_LETSENCRYPT_ACME_EMAIL` env var on
  the container; wildcard cert domains via `tls.domains` labels (Compose DOES
  substitute `${DOMAIN}` in labels).
- **`ipAllowList` does NOT work behind Docker published ports** — Docker NAT
  masquerades the source IP to the bridge gateway before Traefik ever sees it.
  Tailscale-only access is **DNS-based** instead: a DNS-only A record (grey
  cloud) to the Tailscale IP — CGNAT makes that unreachable from the public
  internet, no middleware needed.

---

## File Map

```
compose.networking.yml        Networking/proxy (cloudflared, Traefik, socket-proxy, RollHook)
compose.infra.yml             Databases (Postgres, Valkey) — internal-only, no exposed ports
compose.monitoring.yml        Monitoring (ClickStack, Beszel, Dozzle, Watchtower, Umami + two socket-proxy instances)
compose.dev.yml               Local dev (Postgres + Valkey + MariaDB + ClickStack with ports exposed)
apps/argo/compose.yml         argo-api + argo-dashboard — personal API/agent backbone, RollHook-managed
apps/audio-gateway/compose.yml  STT/TTS only (PODCAST_ENABLED=false) — podcast wiring is mini-only
apps/image-gen-gateway/compose.yml  Backend for the /img skill, RollHook-managed
apps/meteo/compose.yml        meteo-edge — Tailscale-serve edge for meteo
apps/rollhook-marketing/compose.yml  rollhook.com marketing site — managed by RollHook
apps/basalt-ui-marketing/compose.yml  basalt-ui.com marketing site (Astro docs) — managed by RollHook
apps/bun-email-api/compose.yml  bun-email-api (Bun + Resend) — sends FPP contact-form + daily-analytics + SY Serendipity charter-request emails. RollHook-managed.
apps/imgproxy/compose.yml     imgproxy — image CDN (resize/convert) over a private B2 bucket, served at img.DOMAIN
apps/research-gateway/compose.yml  + lightpanda sidecar — /research backend, Tailscale-only, RollHook-managed
apps/photo-gallery/compose.yml  photo-gallery — static Astro gallery served by nginx from /home/jkrumm/photo-gallery-dist (rsynced from laptop via photo-flow CLI)
apps/fpp/compose.yml          FPP — MariaDB (port 33306 exposed for Vercel) + fpp-server + fpp-analytics + updater sidecar, all RollHook-managed
apps/fpp/scripts/setup-mariadb.sh    Idempotent fpp user/grants — run via make fpp-mariadb-setup
apps/fpp/scripts/backup-mariadb.sh   mariadb-dump → S3 + Uptime Kuma push ping
apps/fpp/scripts/restore-mariadb.sh  PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
apps/fpp/scripts/restore-mariadb-local.sh  Dev — non-interactive S3 → local mariadb (DR validation + seeding)
apps/fpp/scripts/sync-mariadb-from-vps.sh  Dev — ssh vps + docker exec mariadb-dump → local mariadb (fresh, no S3)
apps/fpp/scripts/cert-sync.sh        Extract *.free-planning-poker.com cert from traefik/acme.json + FLUSH SSL
apps/fpp/fail2ban/                   filter + jail configs installed by setup.sh
apps/fpp/certs/                      gitignored — populated by cert-sync.sh, mounted RO into mariadb
traefik/traefik.yml           Static config: entrypoints, ACME (DNS-01/Cloudflare)
traefik/dynamic/middlewares.yml  rate-limit, security-headers, tailscale-only
traefik/acme.json             TLS certs — gitignored, chmod 600, auto-managed by Traefik
scripts/setup.sh              Server provisioning (user, SSH, sysctl, UFW, Docker, networks, cron, fail2ban)
scripts/setup-postgres.sh     Idempotent schema/user/grant setup — run via make postgres-setup
scripts/backup-pg.sh          pg_dump → S3 + Uptime Kuma push ping
scripts/health-pg.sh          SELECT 1 → Uptime Kuma push ping (per-minute liveness)
scripts/db-counts.sh          Exact per-table COUNT(*) (Postgres + MariaDB) — read-only, diff-friendly verification (make db-counts)
scripts/restore-pg.sh         PROD restore from S3 — gated DR tool, NO make target (docs/disaster-recovery.md)
scripts/restore-pg-local.sh   Dev — non-interactive S3 → local whole-DB restore (DR validation + seeding)
scripts/sync-pg-from-vps.sh   Dev — ssh vps + docker exec pg_dump (whole DB) → local (fresh, no S3)
scripts/sync-pg-schema-from-vps.sh  Dev — generic per-schema sync (SCHEMA=argo); least-priv, app role only
scripts/firewall.sh           UFW status — provider-level firewall configured via hosting panel
scripts/seed-cron-env.sh      Materializes cron/*.env.tpl → /etc/vps/*.env, chmod 600 — run via make cron-env-seed
scripts/hyperdx-agent-setup.sh  Prod — idempotent HyperDX agent user + accessKey setup, MCP smoke test (make hyperdx-agent-setup)
scripts/hyperdx-dev-bootstrap.sh  Dev — idempotent local HyperDX user + accessKey bootstrap, MCP smoke test (make hyperdx-dev-bootstrap)
scripts/hyperdx-webhook-setup.sh  Prod — idempotent Slack webhook ("Slack #alerts") setup from op://common/slack/VPS_WEBHOOK_ALERTS (make hyperdx-webhook-setup)
scripts/hyperdx-sync.sh       Dashboards + alerts-as-code over REST v2 — export/apply (make hyperdx-export / hyperdx-apply)
observability/dashboards/     Dashboard JSON source of truth — see observability/README.md
observability/alerts/         Alert JSON source of truth — same export/apply loop (docs/observability.md)
slack/                        One-time 12h config-token procedure for the VPS Slack app (slack/README.md)
cron/pg-backup                Postgres backup, daily 03:00
cron/pg-health                Postgres liveness heartbeat, every minute — sources /etc/vps/pg-health.env (no op run — rate limits)
cron/pg-health.env.tpl        op template for the seeded pg-health cron env (materialized via make cron-env-seed)
cron/fpp-mariadb-backup       MariaDB backup, daily 03:30
cron/fpp-cert-sync            MariaDB TLS cert sync, every 6h
cron/docker-prune             Weekly image + build-cache prune, Sunday 04:30 (make prune-cron-install) — never volumes
README.md → Secrets           All secret variable names with setup instructions (no values in repo)
Makefile                      Operational shortcuts
```

---

## Service Notes

**cloudflared** — all public ingress via Cloudflare Tunnel, outbound-only, no ports exposed. Public hostnames configured in Cloudflare dashboard (Zero Trust → Tunnels): `*.DOMAIN` → `https://traefik:443`, TLS verify disabled (internal cert). `--no-autoupdate` lets Watchtower manage the image.

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock), no ports exposed. Wildcard cert via DNS-01 (still required so cloudflared can verify the TLS handshake).

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**Watchtower** — connects via `socket-proxy-watchtower` (`POST=1`, isolated network). Auto-updates everything except Postgres/Valkey/MariaDB (`com.centurylinklabs.watchtower.enable=false`). Slack #updates via shoutrrr, warn level only, daily at 04:00.

**ClickStack** — all-in-one observability container (ClickHouse + OTel Collector + HyperDX UI + MongoDB). Two OTLP receivers: `:4318` authed (browser SDKs, cross-host ingest, reached via `otel.DOMAIN` / per-app same-origin routes) and `:4319` unauthed, docker-bridge-only (Traefik + every internal `monitoring-net` service; trust boundary is the network, not the token) — two tiers exist because Traefik 3.x has unfixed env-var substitution bugs in OTLP headers, see `docs/observability.md`.

HyperDX UI at `hyperdx.DOMAIN` (Tailscale-only). Auth via first-visit account creation. Dev: `https://hyperdx.test` or `http://localhost:7707` direct.

**Adding a service to the pipeline**: full runbook in `docs/observability.md`.

**Umami** — analytics at `umami.DOMAIN`. Own schema + dedicated user in the main Postgres database (schema-only access; superuser can still JOIN across schemas). Default credentials `admin`/`umami` — change on first login. Embedding a new site: `docs/umami-integration.md`.

**imgproxy** — image CDN at `img.DOMAIN` (public via Cloudflare), unsigned URLs, renders from the `img/` prefix of the **same bucket as the Postgres/MariaDB backups**. Stateless, no volumes/DB. Monitored with two Kuma checks (public edge + a Tailscale-only `img-origin.DOMAIN` bypass that forces a real B2 fetch); `/health` is liveness-only and stays green while every image 404s. Upload/URL tooling: the global `/img` skill (`imgcli`).

> **Load-bearing invariant:** the B2 key must be created with `--name-prefix img/` — that server-side restriction, not `IMGPROXY_S3_ALLOWED_BUCKETS`, is what keeps this public unauthenticated service away from the database dumps in the same bucket. Never point it at `op://common/backblaze-s3/*` (bucket-wide, has `writeFiles`).

Full design, URL/prefix conventions, the Cloudflare `Vary`/`Accept` caveat, and B2 provisioning: `docs/image-cdn.md`.

**research-gateway** — the backend behind the global `/research` skill at `research.DOMAIN` (Tailscale-only via a grey-cloud A record, same pattern as argo). Bearer REST + an MCP facade with one submit→poll job contract; a `lightpanda` headless-browser sidecar does the page fetches. Job records persist in the `research-gateway-data` volume and a job orphaned by a restart is reaped to `error` once its heartbeat goes stale — the `job.reaped` log line is alerted on (`observability/alerts/`). RollHook-managed; `make research-gateway-up` pins the running image (never rolls back to a stale `:latest`).

**photo-gallery** — static Astro photo gallery at `photos.DOMAIN`. nginx:alpine serves a host-mounted directory (`/home/jkrumm/photo-gallery-dist:/usr/share/nginx/html:ro`). No image registry, no RollHook — content is built on the developer laptop and rsynced via SSH/Tailscale by the `photo-flow` CLI (`photoflow sync-gallery`). Watchtower auto-updates the nginx base image. The host directory must exist (and contain at least `index.html`) before `make photo-gallery-up`, otherwise the healthcheck fails.

---

## FPP MariaDB (apps/fpp/)

Single-tenant database for Free Planning Poker. Lives outside `compose.infra.yml` because **TCP 33306 is exposed publicly** for Vercel — Cloudflare Tunnel can't proxy raw MySQL (Spectrum is Enterprise-only). Quarantining the deviation in `apps/fpp/` keeps `compose.infra.yml`'s "no inbound ports" invariant intact.

Defenses on the open port:

- `--require-secure-transport=ON` and `REQUIRE SSL` on the `fpp@'%'` user — no plaintext, ever.
- TLS cert is the wildcard `*.free-planning-poker.com` from Traefik's ACME — extracted by `apps/fpp/scripts/cert-sync.sh` (cron every 6h, `FLUSH SSL` on rotation, no restart).
- fail2ban watches mariadb container's journald logs (`CONTAINER_TAG=mariadb`) and bans repeated auth failures at the iptables `DOCKER-USER` chain (UFW does NOT apply to Docker-published ports — `DOCKER-USER` is what works).
- Schema-scoped user — `fpp@'%'` has `ALL PRIVILEGES` on `${MARIADB_DB}` only, no other DBs, no admin grants.
- `mariadb-dump` backup runs on the internal `mariadb-net` (no public roundtrip).

DNS: `db.free-planning-poker.com` is a **DNS-only A record** (grey cloud) → VPS public IP. Cloudflare can't proxy MySQL anyway, so DNS-only is correct — and CGNAT considerations don't apply since this hits the public IP, not the Tailscale IP.

Vercel connection string:
```
mysql://fpp:<password>@db.free-planning-poker.com:33306/free-planning-poker?ssl={"rejectUnauthorized":true}
```

### FPP application services

`apps/fpp/compose.yml` also defines the application services that consume this DB:

| Service | Image | Network | Deploy |
|-|-|-|-|
| `fpp-server` | `rollhook.jkrumm.com/fpp-server:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics` | `rollhook.jkrumm.com/fpp-analytics:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics-updater` | same as fpp-analytics | `mariadb-net` | manual `docker compose up -d` after image change |

Both `fpp-server` and `fpp-analytics` follow the RollHook contract (no `container_name`, no `ports`, healthcheck, `IMAGE_TAG` env var, `rollhook.allowed_repos=jkrumm/free-planning-poker`). The updater is a sleep-loop sidecar that connects to MariaDB internally with TLS+no-verify (cert CN `*.free-planning-poker.com` doesn't match the `mariadb` hostname).

---

## Postgres Schema Model

All apps share one database (`${POSTGRES_DB}`). Each app gets its own schema and a dedicated user with schema-only access. The superuser can JOIN across schemas natively.

Pattern for new apps:
1. Add `APP_DB_PASSWORD` to 1Password `vps` vault, and the matching `<APP>_DB_PASSWORD` line to `.env.tpl`
2. Add a setup block to `scripts/setup-postgres.sh` (CREATE SCHEMA + ROLE + GRANTs)
3. Run `make postgres-setup`
4. In compose: `DATABASE_URL: postgresql://app:${APP_DB_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=app`

**Migration journals — own schema, not the shared `drizzle` schema.** drizzle-kit
(and Prisma) default the migration journal to a single `drizzle` schema owned by
whichever app migrates first. On a shared cluster that's a cross-app collision
*and* breaks after a whole-DB restore (`permission denied for schema drizzle`).
Each Postgres app MUST keep its journal in its own schema: drizzle-kit →
`migrations: { schema: '<app>' }` in `drizzle.config.ts` **and** `migrationsSchema`
in the runtime `migrate()` call (Postgres-only option). Then the schema-owning
role owns its journal — no extra grants needed here. Applied: argo
(`argo.__drizzle_migrations`), basalt-ui-playground. N/A for FPP (own MariaDB).

**Local dev seeding** (do not re-implement in the app repo — delegate to vps):
`make pg-sync-schema SCHEMA=<app>` pulls just that schema from prod over SSH, using the
app's own least-priv role. The convention is fixed: **role name == schema name**, and the
password env var is **`UPPER(schema)_DB_PASSWORD`** (so `argo` → `ARGO_DB_PASSWORD`). App
repos call `make -C ../vps pg-sync-schema SCHEMA=<app> ENV=dev` (argo's `bun db:sync` does
exactly this). For a full local mirror of every schema, use `make sync-from-prod`
(whole-DB) or `make restore-local` (whole-DB from S3, version-pickable).

Current schemas:

| Schema | App | User |
|-|-|-|
| public | (main app / reserved) | ${POSTGRES_USER} |
| umami | Umami analytics | umami |
| basalt_ui_playground | basalt-ui-playground | basalt_ui_playground |
| argo | argo (api) | argo |

---

## App Integration Pattern

Minimal `compose.yml` for a new app (networks, no `ports`/`container_name`,
healthcheck, Traefik labels, env): `README.md` → Adding an App. Hard
constraints for RollHook-managed apps: below.

---

## RollHook — Zero-Downtime Deployments

RollHook (port 7700, behind Traefik, publicly accessible via Cloudflare at `rollhook.<DOMAIN>`) receives webhook calls from GitHub Actions to trigger rolling deployments. It pulls the new image and scales one container at a time, waiting for healthchecks before removing the old instance.

### Hard constraints for RollHook-managed apps

| Constraint | Why |
|-|-|
| No `ports:` | Docker DNS routes traffic; `ports` blocks scaling to 2 instances |
| No `container_name:` | Fixed names prevent creating the second instance during rollout |
| `healthcheck:` required | Rollout waits for healthy before removing old container |
| Image: `${IMAGE_TAG:-<registry>/<image>:latest}` | RollHook passes `IMAGE_TAG=<full-uri>` as inline env var |
| Graceful SIGTERM | Return `503` from `/health`, wait 2-3s, drain requests, exit cleanly |

See `~/SourceRoot/rollhook/README.md` for implementation details (shutdown patterns, GitHub Actions step).

### 1Password secrets (RollHook)

| 1Password Path | Purpose |
|-|-|
| `vps/rollhook/SECRET` | RollHook webhook authentication |

---

## Security Invariants

Never violate these:

- No `ports:` for any service except the Tailscale-bound monitoring/dashboard ports — `13133` (OTel health), `45876` (Beszel), `7007` (Dozzle), `443` (Traefik dashboard), all bound to `${VPS_TAILSCALE_IP}` — **and the FPP MariaDB exception below**
- Zero inbound *public* ports — cloudflared is outbound-only, SSH via Tailscale only — **except 33306 (FPP MariaDB)**
- UFW: default-deny inbound, only `tailscale0` allowed in; sshd may listen on all interfaces (never rebind it — boot-order lock-out). `make firewall` is the proof
- Provider firewall: only TCP 33306 inbound (FPP MariaDB), nothing else
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres, Valkey, and MariaDB: no auto-update via Watchtower — manual only

**FPP MariaDB exception (TCP 33306 inbound):** rationale + mitigations in full — **FPP MariaDB** section above.

---

## Deployment Order (fresh server)

```bash
git clone https://github.com/jkrumm/vps /home/jkrumm/vps
bash /home/jkrumm/vps/scripts/setup.sh
```

1. `tailscale up` → complete browser auth → note Tailscale IP
2. Add `OP_SERVICE_ACCOUNT_TOKEN` to `~/.bashrc` → `source ~/.bashrc && op vault list`
3. `ufw status verbose` → default deny incoming, only `tailscale0` allowed in (sshd stays on all interfaces — never rebind it)
4. `tailscale set --ssh --accept-risk=lose-ssh` → enables SSH badge in Tailscale admin
5. Tunnel token already in 1Password (`vps/cloudflare-tunnel/TOKEN`)
6. `cd ~/vps && make networking-up` → wait for Traefik to issue `*.${DOMAIN}` cert (1–2 min, check `docker logs traefik | grep -i acme`)
7. `make fpp-cert-sync` → extracts wildcard cert into `apps/fpp/certs/`
8. `make up` → starts everything (idempotent — re-runs networking-up too)
9. `make postgres-setup` → provision Postgres schemas/users
10. `make fpp-mariadb-setup` → provision MariaDB fpp user + grants
11. `make cron-env-seed` → materialize /etc/vps/*.env for cron jobs from 1Password
12. Add DNS-only A record `db.free-planning-poker.com` → VPS public IP (grey cloud — not proxied)
13. `reboot` → verify kernel updated, all containers restart automatically

**Note:** the provider has no panel firewall. UFW (deny inbound, allow `tailscale0`) is sufficient for everything except MariaDB. **Docker bypasses UFW for published ports**, so TCP 33306 is publicly reachable as soon as `make fpp-up` runs — no firewall change needed (rationale + mitigations: FPP MariaDB section above).

---

## Upgrade Procedures

Postgres, Valkey and MariaDB opt out of Watchtower — a plain restart reuses
the image already on disk, so they drift indefinitely until `make
infra-upgrade` / `make fpp-mariadb-upgrade` runs (patch/minor) or the gated
`scripts/restore-pg.sh` DR pattern runs for a major version. Full commands +
verification: `README.md` → Upgrading. The one gotcha not to lose: both
upgrade targets are scoped to their own services — a bare `compose up -d` on
`apps/fpp/compose.yml` would also recreate the RollHook-managed `fpp-server`
/ `fpp-analytics` off `:latest` and revert the last deploy.
