# vps

Production Docker Compose stack for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04). Single-node, no orchestration. Cloudflare Tunnel handles all public ingress — zero inbound ports on the server. Three core compose stacks by concern (networking, infra, monitoring), plus one `apps/<name>/compose.yml` per application.

---

## Quick Reference

```bash
make up              # start everything (networking → infra → monitoring → fpp)
make down             # stop everything (reverse order)
make ps               # container status

make backup           # manual Postgres pg_dump → S3 (prod)
make fpp-backup       # manual MariaDB dump → S3 (prod)
make firewall         # show UFW status
# Restoring PROD from S3 has NO make target by design — see docs/disaster-recovery.md
```

Full ENV-aware command reference (dev seeding, per-app up/down, upgrades, cron
seeding, HyperDX targets): `CLAUDE.md` → Quick Reference. Bare `make` prints an
ENV-aware help.

**SSH is Tailscale-only, enforced by UFW — not by sshd's bind address**
(sshd listens on all interfaces by design; see `CLAUDE.md` → Quick Reference
for why). Proof: `make firewall`.

**Internal hostnames (container-to-container):**

| Service | Hostname | Port |
|-|-|-|
| PostgreSQL | `postgres` | `5432` |
| MariaDB (FPP) | `mariadb` | `3306` |
| Valkey/Redis | `redis` | `6379` |
| ClickStack OTel (internal, unauthed) | `clickstack` | `4319` |
| ClickStack UI (HyperDX) | `clickstack` | `8080` |

External Docker networks apps join (`proxy`, `postgres-net`, `mariadb-net`,
`valkey-net`, `monitoring-net`): `CLAUDE.md` → Networks.

---

## Architecture

```
Internet
  │
Cloudflare edge (Tunnel — outbound-only from VPS, zero inbound ports)
  │
cloudflared (compose.networking.yml)
  │
Traefik v3
  ├─ Wildcard TLS via Cloudflare DNS-01 ACME (*.<DOMAIN>)
  ├─ Middleware chain: rate-limit → security-headers
  ├─ Traefik dashboard (DNS-only A record → Tailscale IP, not public)
  ├─ app-1  (network: proxy)
  └─ app-2  (network: proxy)

Internal networks — never exposed publicly:
  postgres-net  ── postgres:5432
  mariadb-net   ── mariadb:3306      (FPP only — see FPP MariaDB exception)
  valkey-net    ── redis:6379          (Valkey 9, hostname aliased to "redis")
  monitoring-net
    ├─ clickstack        all-in-one observability (ClickHouse + OTel + HyperDX UI)
    ├─ beszel-agent      pushes server + container metrics → Beszel hub
    └─ dozzle            streams container logs → Dozzle hub

Homelab connectivity: Tailscale
  VPS → Beszel hub, Dozzle hub (Tailscale IPs, no public ports)
  SSH → Tailscale only, UFW-enforced (see Quick Reference above)

Docker API — four socket-proxy instances, never docker.sock: CLAUDE.md → Networks.
```

---

## Stack

RollHook-managed images pull from `rollhook.jkrumm.com/<name>` unless noted (`...` below).

| Service | Image | Purpose | Update policy |
|-|-|-|-|
| cloudflared | cloudflare/cloudflared | Public ingress via Cloudflare Tunnel | auto |
| socket-proxy | tecnativa/docker-socket-proxy | Read-only Docker API for Traefik | auto |
| traefik | traefik:v3 | Reverse proxy, TLS termination | auto |
| socket-proxy-rollhook | tecnativa/docker-socket-proxy | Write Docker API for RollHook | auto |
| rollhook | ghcr.io/jkrumm/rollhook | Zero-downtime rolling deployments via webhook | auto |
| postgres | postgres:18 | Primary DB — pinned major version | **manual only** |
| valkey | valkey/valkey:9 | Cache + queues — `container_name: redis` | **manual only** |
| mariadb | mariadb:11.4 | FPP-only DB, publicly exposed on 33306 — see FPP MariaDB exception | **manual only** |
| clickstack | clickhouse/clickstack-all-in-one | Observability — OTel + ClickHouse + HyperDX UI. See [docs/observability.md](docs/observability.md) | auto |
| beszel-agent | henrygd/beszel-agent | Server metrics agent | auto |
| dozzle | amir20/dozzle | Log streaming agent | auto |
| socket-proxy-monitoring | tecnativa/docker-socket-proxy | Read-only Docker API for Dozzle + Beszel | auto |
| socket-proxy-watchtower | tecnativa/docker-socket-proxy | Write Docker API for Watchtower | auto |
| watchtower | containrrr/watchtower | Auto-updates containers, Slack notification on failure | auto |
| umami | ghcr.io/umami-software/umami | Self-hosted analytics at `umami.<DOMAIN>` — see Integrating Umami below | auto |
| photo-gallery | nginx:alpine | Static Astro photo gallery — content rsynced from laptop via photo-flow CLI | auto |
| imgproxy | ghcr.io/imgproxy/imgproxy:v4 | Image CDN — on-the-fly resize/convert over a private B2 bucket. See [docs/image-cdn.md](docs/image-cdn.md) | auto (v4.x) |
| argo-api, argo-dashboard | `rollhook.jkrumm.com/argo-*` | Personal API + dashboard, the agent backbone | RollHook |
| audio-gateway | `.../audio-gateway` | STT/TTS gateway (podcast wiring is mini-only here) | RollHook |
| image-gen-gateway | `.../image-gen-gateway` | Image generation behind the `/img` skill | RollHook |
| meteo-edge | `.../meteo-edge` | Tailscale-serve edge for the meteo weather/wave service | RollHook |
| bun-email-api | `.../bun-email-api` | Bun + Resend — FPP contact-form + analytics + SY Serendipity charter-request emails | RollHook |
| basalt-ui-marketing | `.../basalt-ui-marketing` | basalt-ui.com marketing/docs site (Astro) | RollHook |
| rollhook-marketing | `ghcr.io/jkrumm/rollhook-marketing` | rollhook.com marketing site | RollHook |
| research-gateway (+ lightpanda sidecar) | `.../research-gateway` | `/research` backend — bearer REST + MCP facade; Tailscale-only | RollHook |
| fpp-server, fpp-analytics, fpp-analytics-updater | `.../fpp-*` | Free Planning Poker backend + analytics — see FPP MariaDB exception | RollHook |

---

## Design Decisions

- **Cloudflare Tunnel, zero inbound ports.** cloudflared is outbound-only to the edge. DNS-01 ACME still issues the wildcard cert so cloudflared can verify Traefik's TLS handshake internally.
- **Four socket proxies, no docker.sock mounts.** Traefik and Dozzle/Beszel each get a dedicated read-only proxy; RollHook and Watchtower each get a dedicated `POST=1` proxy on an isolated network — write access never shared.
- **SSH via Tailscale only, enforced by UFW**, not sshd's bind address — see `CLAUDE.md` → Quick Reference for the boot-order reason sshd is never rebound.
- **Watchtower over WUD.** Auto-updates everything except Postgres/Valkey/MariaDB (major version bumps need a deliberate backup first). Slack, warn level only.
- **`container_name: redis` for Valkey** — every app references `redis:6379` unmodified.
- **1Password for secrets**, zero in the repo (`.env.tpl` is `op://` refs only). Deploy: `op run --env-file=.env.tpl -- docker compose up -d` (or `make up`). Why two runners/templates exist: `docs/secrets-injection.md`.
- **No Terraform.** Single-server setup doesn't justify state management; UFW is the only firewall layer.

---

## Provisioning a Fresh Server

One-time bring-up: `scripts/setup.sh` (user, SSH hardening, UFW, Docker,
networks, cron) → Tailscale (`--ssh`, note the IP, never rebind sshd to it) →
1Password CLI service-account token → verify secrets (below) → `make
networking-up` → `make fpp-cert-sync` → `make up` → `make postgres-setup` →
`make fpp-mariadb-setup` → Cloudflare tunnel ingress + DNS via the
`/cloudflare` skill. Full narrated walkthrough, one step at a time, with the
reasoning behind each: [docs/provisioning.md](docs/provisioning.md).

---

## Secrets

1Password vaults: `vps` + `common`. No `.env` file with real values — `.env.tpl` contains only `op://` references. Injection mechanism (two runners, two templates, the mini's headless constraint): `docs/secrets-injection.md`.

**Domain + TLS**

| Variable | Value | How to get |
|-|-|-|
| `DOMAIN` | `example.com` | Your apex domain — wildcard cert covers `*.DOMAIN` |
| `ACME_EMAIL` | `you@example.com` | Email for Let's Encrypt notifications |

All Cloudflare env vars use the unified `CLOUDFLARE_*` prefix (matches the `/cloudflare` skill at `~/.claude/skills/cloudflare/`).

| Variable | Source | Notes |
|-|-|-|
| `CLOUDFLARE_API_TOKEN` | `op://common/cloudflare/DNS_API_TOKEN` | Needs **DNS:Edit** + **Tunnel:Edit** for all zones. Same token as HomeLab. Traefik gets it as `CF_DNS_API_TOKEN` (lego's required name). |
| `CLOUDFLARE_ACCOUNT_ID` | `op://common/cloudflare/ACCOUNT_ID` | Same for all zones/tunnels. |
| `CLOUDFLARE_ZONE_ID` | `op://common/cloudflare/ZONE_ID_JKRUMM_COM` | Zone ID for `jkrumm.com`. Other zones looked up on demand by the `/cloudflare` skill. |
| `CLOUDFLARE_TUNNEL_ID` | `op://vps/cloudflare-tunnel/TUNNEL_ID` | UUID of the **VPS** tunnel (HomeLab has its own). |
| `CLOUDFLARE_TUNNEL_TOKEN` | `op://vps/cloudflare-tunnel/TOKEN` | Zero Trust → Networks → Tunnels → Create tunnel → copy token. |

**PostgreSQL**

| Variable | Value | How to get |
|-|-|-|
| `POSTGRES_USER` | `postgres` | Superuser name (default: `postgres`) |
| `POSTGRES_DB` | `postgres` | Default database name |
| `POSTGRES_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` |

Apps create their own users and databases on top of this superuser — schema
model + adding a new app's schema: `CLAUDE.md` → Postgres Schema Model.

**MariaDB (FPP)**

Single-tenant DB for Free Planning Poker, quarantined in `apps/fpp/` because it's exposed publicly on TCP 33306 (full rationale: `CLAUDE.md` → FPP MariaDB). Vercel connects with `?ssl={"rejectUnauthorized":true}` against `db.free-planning-poker.com`.

| Variable | Value | How to get |
|-|-|-|
| `MARIADB_DB` | `free-planning-poker` | Database name (in 1Password: `vps/config/MARIADB_DB`) |
| `MARIADB_ROOT_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` — used by backup/restore/setup scripts |
| `MARIADB_FPP_PASSWORD` | `<generated>` | Generate: `openssl rand -hex 32` — application user (REQUIRE SSL) |
| `UPTIME_KUMA_FPP_BACKUP_PUSH_URL` | `https://...` | Separate Uptime Kuma monitor for the MariaDB backup cron |

**FPP application services** (`apps/fpp/compose.yml` — fpp-server, fpp-analytics, updater)

| Variable | Value | How to get |
|-|-|-|
| `FPP_SERVER_SECRET`, `FPP_ANALYTICS_SECRET_TOKEN` | `<generated>` | `openssl rand -hex 32` — bearer tokens between Vercel and fpp-server/fpp-analytics |
| `FPP_SERVER_SENTRY_DSN`, `FPP_ANALYTICS_SENTRY_DSN` | `https://...@sentry.io/...` | Per-service Sentry DSN |
| `FPP_BEA_BASE_URL` | `https://...` | Bun email API base URL (used by fpp-analytics for survey emails) |
| `FPP_BEA_SECRET_KEY` | `<secret>` | Auth key for the bun email API |
| `UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL` | `https://...` | Heartbeat URL for the 10-min sync sidecar (separate Kuma monitor) |

**imgproxy (image CDN)**

Serves `img/` in the **same bucket as the backups** — the B2 key MUST be
created with `--name-prefix img/`, read-only, no `deleteFiles`. Full
walkthrough + provisioning + verification: [docs/image-cdn.md](docs/image-cdn.md).

| Variable | Value | How to get |
|-|-|-|
| `IMGPROXY_B2_KEY_ID` | `<key-id>` | `b2 key create --bucket <bucket> --name-prefix img/ imgproxy-read listBuckets,listFiles,readFiles` |
| `IMGPROXY_B2_APP_KEY` | `<secret>` | Shown once at key creation — capture immediately |
| `IMGPROXY_B2_BUCKET` | `<bucket>` | Reused from `op://common/backblaze-s3/BUCKET` |
| `IMGPROXY_B2_ENDPOINT` | `https://...` | Reused from `op://common/backblaze-s3/ENDPOINT` |
| `IMGPROXY_B2_REGION` | `<region>` | Reused from `op://common/backblaze-s3/REGION` |

**Backups (S3-compatible object storage)**

| Variable | Value | How to get |
|-|-|-|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `<key>`/`<secret>` | Object storage provider credential |
| `AWS_S3_BUCKET`, `AWS_S3_ENDPOINT` | `<bucket>`/`https://...` | Bucket name + S3-compatible endpoint URL |
| `UPTIME_KUMA_PUSH_URL` | `https://...` | Uptime Kuma → Add monitor → Push type → copy URL |

**Cron env seeding**

High-frequency cron jobs must not call `op` per run (1Password rate-limits —
this is how the pg-health monitor died). `make cron-env-seed` seeds their env
once into `/etc/vps/<job>.env` (chmod 600) from `cron/<job>.env.tpl`; re-run
it after rotating any referenced secret.

| Variable | Value | How to get |
|-|-|-|
| `UPTIME_KUMA_POSTGRES_PUSH_URL` | `https://...` | Uptime Kuma push monitor for the per-minute Postgres liveness check. Seeded into `/etc/vps/pg-health.env`. |

**Watchtower + Monitoring**

| Variable | Value | How to get |
|-|-|-|
| `SLACK_WATCHTOWER_URL` | `slack://hook:...@webhook` | `op read "op://common/slack/WATCHTOWER_URL" --account tkrumm` |
| `BESZEL_AGENT_KEY` | `ssh-ed25519 AAAA...` | Beszel hub UI → Add System → address `<tailscale-ip>:45876` → copy SSH public key shown |
| `EXPRESS_SESSION_SECRET` | `<generated>` | Generate: `openssl rand -hex 32` — HyperDX session encryption |
| `HYPERDX_API_KEY` | `<ingestion-key>` | HyperDX UI → Team Settings → API Keys → Ingestion API Key. No longer required by Traefik — browser SDKs still embed it (`op://vps/argo/HYPERDX_API_KEY_PROD`). See `docs/observability.md`. |

**RollHook**

| Variable | Value | How to get |
|-|-|-|
| `ROLLHOOK_SECRET` | `<generated>` | `vps/rollhook/SECRET`. Doubles as the registry password (`docker login rollhook.jkrumm.com -u rollhook`) — no separate registry secret. |
| `SLACK_WEBHOOK_URL` | reuses `SLACK_WATCHTOWER_URL` | Deploy success/failure to Slack `#updates`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://clickstack:4319` | Unauthed OTLP HTTP on the docker bridge — RollHook is on `monitoring-net`. |
| `DEPLOY_ENVIRONMENT` | `prod` | Tag attached to deploy logs/markers. |

---

## Adding an App

Minimal `compose.yml` in the app repo:

```yaml
networks:
  proxy:
    external: true
  postgres-net:   # omit if app doesn't use Postgres
    external: true
  monitoring-net: # include to reach clickstack by hostname
    external: true

services:
  myapp:
    image: ${IMAGE_TAG:-ghcr.io/jkrumm/myapp:latest}
    # NO container_name — RollHook must scale to 2 instances during rollout
    # NO ports — Traefik routes via Docker DNS; ports prevent scaling
    healthcheck:
      test: [CMD, curl, -f, http://localhost:3000/health]
      interval: 5s
      timeout: 5s
      start_period: 10s
      retries: 5
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`app.<DOMAIN>`)"
      - "traefik.http.routers.myapp.entrypoints=websecure"
      - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"
      - "traefik.http.routers.myapp.middlewares=rate-limit@file,security-headers@file"
      # Active health check — Traefik stops routing to a draining instance immediately
      - "traefik.http.services.myapp.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.myapp.loadbalancer.healthcheck.interval=5s"
    networks: [proxy, postgres-net, monitoring-net]
    security_opt: [no-new-privileges:true]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    environment:
      # Shared cluster: append ?schema=<app>. Keep the migration journal in the
      # app's own schema too (see "Postgres Schema Model" in CLAUDE.md).
      DATABASE_URL: postgresql://<user>:<pass>@postgres:5432/<db>?schema=<app>
      REDIS_URL: redis://redis:6379
      OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
```

Deploy: `op run --env-file=.env.tpl -- docker compose up -d`

Hard constraints for RollHook-managed apps (no `ports:`, no `container_name:`,
graceful SIGTERM, …): `CLAUDE.md` → RollHook.

---

## Backups

Two daily backups, both stream to the same `jkrumm` B2 bucket under `backups/vps/`. Retention (14-day hide → delete) enforced by a single B2 lifecycle rule on the `backups/vps/` prefix — append-only key, no client-side pruning.

| Cron | Time | Script | S3 path | Kuma var |
|-|-|-|-|-|
| `/etc/cron.d/pg-backup` | 03:00 | `scripts/backup-pg.sh` | `backups/vps/postgres/` | `UPTIME_KUMA_PUSH_URL` |
| `/etc/cron.d/fpp-mariadb-backup` | 03:30 | `apps/fpp/scripts/backup-mariadb.sh` | `backups/vps/mariadb/` | `UPTIME_KUMA_FPP_BACKUP_PUSH_URL` |
| `/etc/cron.d/pg-health` | every minute | `scripts/health-pg.sh` | n/a (liveness) | `UPTIME_KUMA_POSTGRES_PUSH_URL` |
| `/etc/cron.d/docker-prune` | Sunday 04:30 | inline `docker image prune -af && docker builder prune -f --filter until=168h` (never volumes) | n/a (hygiene) | — |

Manual triggers: `make backup` (Postgres), `make fpp-backup` (MariaDB).
Restoring PROD from S3 has **no make target by design** — gated, human-only DR
tools only (`scripts/restore-pg.sh`, `apps/fpp/scripts/restore-mariadb.sh`),
full procedure in `docs/disaster-recovery.md`. Dev seeding/DR-drill targets
(`restore-local`, `sync-from-prod`, `pg-sync-schema`, `fpp-restore-local`,
`fpp-sync-from-prod`, `db-counts`): `CLAUDE.md` → Quick Reference. App repos
delegate to these rather than re-implementing — e.g. `free-planning-poker`
calls `make -C ../vps fpp-sync-from-prod`.

**Verifying a restore/sync is faithful.** `make db-counts` prints stable-sorted
`schema|table|rows` for both DBs — diff a `sync-from-prod` capture against a
`restore-local` capture: Postgres should match exactly, MariaDB only by a
small positive delta on hot tables (live writes since the backup). Don't
trust the sync/restore scripts' own summaries — only `db-counts` runs a real
`COUNT(*)`.

---

## Upgrading Postgres, Valkey or MariaDB

All three are excluded from Watchtower auto-updates, and a restart alone does not
help — Docker reuses the image already on disk. They only move when `make
infra-upgrade` / `make fpp-mariadb-upgrade` runs (`CLAUDE.md` → Quick
Reference), so check them periodically (`/audit` phase 8).

Both targets name their services explicitly rather than recreating the whole
file — load-bearing for MariaDB, since `apps/fpp/compose.yml` also holds the
RollHook-managed `fpp-server` and `fpp-analytics`, and an unscoped `up -d`
would recreate them off `:latest`, undoing the last deploy.

**Postgres major upgrade (e.g., 18 → 19):** Dump with current version, update image tag in `compose.infra.yml`, restore into new container via the gated `scripts/restore-pg.sh` (see `docs/disaster-recovery.md`). Always backup first.

---

## Local Database Access

Postgres has no host port — access is over an SSH tunnel via Tailscale. DataGrip setup + psql one-liner: [docs/database-access.md](docs/database-access.md).

---

## Integrating Umami on a New Website

Embed snippet, the `/p.js` rename rationale, and the same-origin proxying
workaround for Brave Shields: [docs/umami-integration.md](docs/umami-integration.md).

---

## Monitoring

All dashboards are Tailscale-only — no public routes.

| Tool | Access | What it shows |
|-|-|-|
| Beszel | homelab Beszel hub | CPU, RAM, disk, network per container |
| Dozzle | homelab Dozzle hub | Live container logs |
| HyperDX (ClickStack) | `https://hyperdx.<DOMAIN>` (tailscale-only) | Traces, metrics, logs |
| Watchtower | Slack `#updates` (warn level) | Container update failures |
| RollHook | Slack `#updates` | Deploy success/failure (reuses Watchtower webhook) |
| RollHook | HyperDX (ClickStack) | OTLP deploy markers, `service.name=rollhook` |
| Traefik | `https://traefik.<DOMAIN>` | Router/service map, cert status |

Traefik dashboard is publicly DNS-resolvable but reachable only via a DNS-only
A record to the Tailscale IP (CGNAT — unreachable from the public internet).
There is no IP-allowlist middleware; Docker NAT would defeat one. Details:
`CLAUDE.md` → Networks.
