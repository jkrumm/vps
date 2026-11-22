# vps

Infrastructure-as-code for a VPS (12 vCPU · 24 GB · 180 GB SSD · Ubuntu 24.04). Docker Compose only, no Swarm/Kubernetes. Three compose files by concern (networking incl. RollHook, infra, monitoring) plus one `apps/<name>/compose.yml` per app.

> **Public repo.** Never commit real IPs, hostnames, Tailscale IPs, passwords, tokens, or provider-specific details. Use `<placeholder>` in docs. All actual values in 1Password.

## Reference docs

Read the one that matches the work before you change it:

- Anything under `apps/fpp/` (MariaDB, fpp-server, analytics, the open TCP 33306): Read `apps/fpp/AGENTS.md` first; an Edit or a shell command there does not load it.
- Which Makefile target does what: `docs/make-targets.md`.
- Networks, socket proxies, Traefik routing, tunnel ingress: `docs/networks.md`.
- Cloudflared, Traefik, Valkey, Watchtower, ClickStack, Umami, imgproxy, gh runners, photo-gallery: `docs/service-notes.md`.
- A new Postgres app, schema, role or migration journal: `docs/postgres-schema-model.md`.
- GitHub Actions telemetry (mini LaunchAgent → ClickStack, CI dashboard): `docs/observability.md` → CI telemetry.
- Backups and what is not backed up: `docs/object-storage.md`. Which file owns what: `docs/file-map.md`.
- A fresh server: `docs/deployment-order.md`. The `make deploy` path map, `make verify` details, shared-stack monitors: `docs/deploy.md`. The stopped argo containers: `docs/retired-argo.md`.

## Quick Reference

`ENV=dev` locally, `ENV=prod` on the server, set in `.env` (gitignored). All container operations go through the Makefile, never raw `docker` / `docker compose`: a raw call can miss `op run` and a required secret. Bare `make` prints an ENV-aware help; prod-only and dev-only targets refuse to run with the wrong ENV.

- `make up` / `make down` — dev: compose.dev.yml. Prod: networking → infra → monitoring → fpp → email-gateway → photo-gallery → imgproxy (reverse for down). weatherorb, shutterflow, basalt-ui-marketing and jkrumm-com are not in it: `make <app>-up`, the RollHook ones after their own bootstrap.
- Targeted restart (prod): `make <stack>-up` / `-down` for networking, infra, monitoring, fpp, weatherorb, imgproxy.
- Restoring PROD from S3 has no make target by design (it overwrites production): the gated, human-only scripts `scripts/restore-pg.sh` and `apps/fpp/scripts/restore-mariadb.sh`, see `docs/disaster-recovery.md`.
- Dev seeding from prod (`make pg-sync-schema SCHEMA=<app>`, `make fpp-sync-from-prod`, `make restore-local`) never touches prod. HyperDX, edge-cache, gh-runner, mini-Postgres and telemetry-lint targets: `docs/make-targets.md`.

> **SSH:** Tailscale only — enforced by UFW (default-deny inbound, only `tailscale0` allowed in), **not** by sshd's bind address: sshd may listen on all interfaces. Never set `ListenAddress` to the Tailscale IP (sshd fails at boot when `tailscale0` is late — a lock-out). Proof: `make firewall`. `ssh vps` uses the Tailscale IP from `~/.ssh/config`.

## Secrets

1Password vaults: `vps` + `common`. Full variable list + setup instructions: `README.md` → Secrets. **Never write actual values in this repo**; use `<placeholder>` in docs.

**Runner** (`SECRET_RUNNER`): `secrets-run` where it exists, plain `op run --account tkrumm` otherwise. Only the mini needs the shim: a bare `op` there has no human to answer its biometric prompt, so `make up` **blocks** instead of failing (one run sat wedged 19 h). `secrets-run` fails closed in a second.

**Template**: prod targets get the full `.env.tpl` (`$(OP_RUN)`); `require-dev` targets get the stripped-down `.env.dev.tpl` (`$(OP_RUN_DEV)`); `fpp-shell` follows `$(ENV)` via `$(OP_RUN_ENV)`. Why the dev subset and the runner split: `docs/secrets-injection.md`. Per-app schema passwords (`<APP>_DB_PASSWORD`) and every other variable: `README.md` → Secrets.

## Security Invariants

Never violate these:

- No `ports:` for any service except the Tailscale-bound monitoring/dashboard ports — `13133` (OTel health), `8123` (ClickHouse HTTP, read-only `argo_ro`), `7007` (Dozzle), `443` (Traefik dashboard), all bound to `${VPS_TAILSCALE_IP}` — **plus `127.0.0.1:4319` (ClickStack's unauthed OTLP tier, loopback only, for host-agent in the host network namespace) and the FPP MariaDB exception below**. `scripts/lint-compose.py` enforces the allowed pairs.
- Zero inbound *public* ports — cloudflared is outbound-only, SSH via Tailscale only — **except 33306 (FPP MariaDB)**
- No actual IPs, secrets, tokens, or credentials in any tracked file
- `traefik/acme.json` must remain chmod 600 (Traefik refuses to start otherwise)
- Postgres, Valkey, MariaDB, ClickStack and the four socket proxies (pinned `lts@sha256:…`; bump by hand, then `make deploy`): no auto-update via Watchtower — manual only

**FPP MariaDB exception (TCP 33306 inbound):** Docker bypasses UFW for published ports, so 33306 is publicly reachable as soon as `make fpp-up` runs. Rationale and mitigations: `apps/fpp/AGENTS.md`.

## RollHook — Zero-Downtime Deployments

RollHook (port 7700, behind Traefik, public at `rollhook.<DOMAIN>` via Cloudflare) receives webhook calls from GitHub Actions and rolls one container at a time, waiting for healthchecks. Webhook secret: `vps/rollhook/SECRET`. Implementation details (shutdown patterns, the Actions step): `~/SourceRoot/rollhook/README.md`. A new app's minimal `compose.yml`: `README.md` → Adding an App.

A RollHook-managed app has:

- no `ports:` — Docker DNS routes traffic, `ports` blocks scaling to 2 instances
- no `container_name:` — a fixed name prevents the second instance during rollout
- a `healthcheck:` — the rollout waits for healthy before removing the old container
- image `${IMAGE_TAG:-<registry>/<image>:latest}` — RollHook passes `IMAGE_TAG=<full-uri>` as inline env
- graceful SIGTERM — `503` from `/health`, wait 2–3 s, drain, exit cleanly

## Upgrade Procedures

Postgres, Valkey, MariaDB and ClickStack (pinned `2.45.0`; bump the tag, `make deploy`) opt out of Watchtower — a plain restart reuses the image on disk, so they drift until `make infra-upgrade` / `make fpp-mariadb-upgrade` runs (patch/minor) or the gated `scripts/restore-pg.sh` DR pattern runs for a major version. Full commands + verification: `README.md` → Upgrading. Both upgrade targets are scoped to their own services and wait for health (`up -d --wait`): a bare `compose up -d` on `apps/fpp/compose.yml` would also recreate the RollHook-managed `fpp-server` / `fpp-analytics` off `:latest` and revert the last deploy.

## Validate

`make check` is the single local gate — no server, no secrets, no Docker, so it is safe to run anywhere (the MacBook, the mini, CI):

```bash
make check
```

It runs:

1. `scripts/lint-compose.py` parses every `compose.*.yml` and `apps/*/compose.yml` with PyYAML
   (no Docker, no interpolation, so `op://` references stay as written) and enforces the
   compose invariants. The system `python3` supplies PyYAML when it has it, else `uv run --with pyyaml`.
2. `bash -n` over `scripts/*.sh` and `apps/*/scripts/*.sh`.

CI (`.github/workflows/ci.yml`) runs the same `make check` on every push and PR; the target also covers the Python unit tests and `shellcheck`.

A non-zero exit means the change is not ready.

Not covered here: building any image (the app repos own that), each app's own test
suite, `op://` resolution, and live server state. The `cron/*` job scripts carry
no `.sh` extension and are not syntax-checked by this target.

## Deploy

This repo ships **compose/config and ops scripts**, not app code. App code ships when its own repo is pushed to `master`: RollHook rolls the new image (CI), or Watchtower for the few non-RollHook images. Config changes (`apps/<name>/compose.yml`, `traefik/`, …) ship by push, pull on the server, deploy:

```bash
git push && ssh vps "cd ~/vps && git pull"
make deploy APP=<name>      # on the VPS, ENV=prod
```

Off the VPS (e.g. on the mini), `make deploy` / `make verify` forward there: `ssh vps` → `git pull --ff-only` → `ENV=prod make <target>`, where `.deploy-sha` / `.deploy-apps` live.

`make deploy APP=<name>` runs that app's `<name>-up` target, which recreates it from `apps/<name>/compose.yml` **pinning the currently running image** (one Makefile helper, `PIN_SH` / `pin_all SVC:VAR …`, for every RollHook app), so a config change never rolls an app back to a stale `:latest`. A service with no container yet starts from the bootstrap-seeded `:latest`; a container whose image cannot be read fails the target. `rollhook-marketing` is CI-only: the target prints `deployed by CI on push` and exits 0. `weatherorb` is plain nginx over `apps/weatherorb/site`: the target recreates it.

With no `APP`, `make deploy` deploys what changed since the last deployed SHA (`.deploy-sha`, gitignored; the first run seeds `HEAD` and deploys nothing) and records the apps in `.deploy-apps`. The path-to-action map is in `docs/deploy.md`. Bind-mounted config (`traefik/traefik.yml`, `clickstack/*`) needs a recreate, which the map covers; `observability/**` only prints a hint, so run `make hyperdx-apply ENV=prod` yourself.

Rollback: `git revert` the offending change, push, pull on the server, re-run `make deploy APP=<name>`. A bad app **image** rolls back through RollHook to the prior image. Databases are restored only through the gated DR scripts (`docs/disaster-recovery.md`), never by a Makefile target.

## Verify & Monitor

`make verify APP=<name>` probes one app and exits non-zero if it is not live and healthy: public endpoints by `curl -fsS`, Tailscale-only or authed apps by their container healthcheck over SSH. `make logs APP=<name>` prints a bounded 200-line tail and exits. With no `APP`, `make verify` re-verifies the apps recorded in `.deploy-apps` by the last deploy (every known app when none is recorded). Details and `make version`: `docs/deploy.md`.

| App | Health URL | Kuma monitor |
|-|-|-|
| basalt-ui-marketing | `https://basalt-ui.com/` | — |
| email-gateway | `https://email-gateway.<your-domain>/health` | `EmailGateway - HTTP` |
| fpp | `https://server.free-planning-poker.com/health` · `https://analytics.free-planning-poker.com/health` · beta `https://next.free-planning-poker.com/api/health` | `FPP - Server - HTTP` · `FPP - Analytics - HTTP` |
| imgproxy | `https://img.<your-domain>/rs:fit:100/misc/monitor-probe.jpg` | `ImageCDN - HTTP` · `ImageCDN Origin - HTTP` |
| jkrumm-com | `https://jkrumm.com/` | — |
| photo-gallery | `https://photos.<your-domain>/` | `Photos - HTTP` |
| rollhook-marketing | `https://rollhook.com/` | — |
| shutterflow | `https://shutterflow.app/health` | — |
| weatherorb | `https://weatherorb.com/` | `WeatherOrb - HTTP` |

OTel `service.name`, namespace and host per service: `observability/services.yaml` (the registry; contract in `docs/observability.md` → Telemetry contract). Monitors of the shared stacks: `docs/deploy.md`.

- **No `ports:` except FPP MariaDB `33306` and the Tailscale-bound monitoring
  ports** — see `## Security Invariants`. Docker publishes bypass UFW entirely;
  FPP MariaDB relies on TLS, a schema-scoped user and `fail2ban` instead.

## Gotchas

- **Tailscale-only access is DNS-based** (grey-cloud A record to the Tailscale IP); see `docs/networks.md` for when `ipAllowList` applies.
- **`traefik.yml` does not support `${ENV_VAR}`** — ACME email goes in via the container env var, wildcard domains via `tls.domains` labels (Compose *does* substitute `${DOMAIN}` in labels).
- **Never run a bare `docker compose -f apps/<app>/compose.yml up -d` for a RollHook app** — it resolves `${IMAGE_TAG:-…:latest}` and rolls the container back to a stale `:latest`. Use `make <app>-up` (pins the running image) or `make deploy APP=<app>`.
- **Each Postgres app owns its migration journal in its own schema** (drizzle `migrations.schema` + `migrationsSchema`); otherwise a whole-DB restore breaks with `permission denied for schema drizzle`.
