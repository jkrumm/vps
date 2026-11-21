# Makefile targets

Environment is controlled by `.env` (gitignored). Locally: `ENV=dev`. On server: `ENV=prod`.
Secrets: `op run --env-file=.env.tpl` — 1Password vaults: `vps` + `common`.

All container operations go through the Makefile — never raw `docker`/`docker compose` (global rule `docker-makefile.md`). Bare `make` prints an ENV-aware help: targets available in the current ENV are highlighted, prod-only / dev-only targets are listed dimmed under "Requires ENV=…". Prod-only and dev-only targets are gated by `require-prod` / `require-dev` prerequisites and refuse to run with the wrong ENV.

```bash
make                     # show ENV-aware help (default target)
# Primary operations — adapts to ENV automatically
make up                  # dev: compose.dev.yml | prod: networking → infra → monitoring → fpp → email-gateway → photo-gallery → imgproxy (weatherorb, shutterflow, basalt-ui-marketing, jkrumm-com are NOT in it: `make <app>-up`, the RollHook ones after their own bootstrap)
make down                # dev: compose.dev.yml | prod: reverse order

# Targeted restart (prod only — individual stacks)
make networking-up / make networking-down
make infra-up    / make infra-down
make monitoring-up / make monitoring-down
make fpp-up      / make fpp-down
make weatherorb-up    / make weatherorb-down   # the one static page at weatherorb.com (apps/weatherorb/site, nginx, no RollHook)
make imgproxy-up / make imgproxy-down
make telemetry-lint           # registry vs prod ClickHouse (the factory's hygiene probe, docs/observability.md → Telemetry lint); keyless, read-only; non-zero on findings
make edge-cache-status HOST=example.com   # ✓/✗ checklist for the edge-cache pattern (docs/edge-cache.md)
make edge-cache-apply HOST=example.com    # idempotent provision — DNS, tunnel ingress, Cache Rule; DRY_RUN=1 to preview

# Manual image upgrades — Postgres/Valkey/MariaDB/ClickStack are excluded from Watchtower
make infra-upgrade       # postgres + valkey (run make backup first)
make fpp-mariadb-upgrade # mariadb only (run make fpp-backup first)

# DB schema/user provisioning — idempotent
make postgres-setup      # prod only: run after make infra-up, before make monitoring-up (the mini's Postgres: dotfiles config/postgres/cluster.yaml + make -C ~/SourceRoot/dotfiles pg-apply)
make fpp-mariadb-setup   # run after make fpp-up
make cron-env-seed       # materialize /etc/vps/*.env for cron jobs from 1Password (re-run after secret rotation)

# FPP TLS cert sync (extracts *.free-planning-poker.com from traefik/acme.json into apps/fpp/certs/)
make fpp-cert-sync       # run once after networking-up; cron does it every 6h

# HyperDX agent access + dashboards/alerts-as-code (see docs/observability.md → "Agent access")
make hyperdx-agent-setup       # prod — idempotent agent user + accessKey setup, MCP smoke test
make hyperdx-dev-bootstrap     # dev — idempotent local user + accessKey bootstrap, MCP smoke test
make hyperdx-webhook-setup     # prod — idempotent ntfy webhook ("ntfy alerts") setup
make hyperdx-export ENV=dev    # export dashboards + alerts → observability/{dashboards,alerts}/*.json
make hyperdx-apply ENV=dev     # validate + upsert (by name) dashboards, then alerts, from those directories
make dev-mariadb-up / dev-mariadb-down  # dev — mariadb only (up waits healthy; down = stop, no removal); dev-redis-up / dev-redis-down: the same for valkey. `make up`/`down` act on the whole dev project
make clickstack-up             # dev — start ClickStack on demand (profile `observability`; `make up` skips it, ~4 GB)
make clickstack-down           # dev — stop it again
make clickstack-restart        # dev — restart clickstack (fixes a dead local ClickHouse process)
make traefik-recreate / clickstack-recreate   # prod — force-recreate one service after a bind-mounted config change (what `make deploy` runs)
make cron-install / fail2ban-install          # prod — reinstall cron/* into /etc/cron.d, the MariaDB fail2ban filter + jail (what `make deploy` runs)

# Status + ops
make ps                  # docker ps with name/status/ports
make db-counts           # exact per-table COUNT(*) (Postgres + MariaDB) — diff to verify a sync/restore matches prod
make shell-postgres      # psql shell (dev: the mini's Postgres over /tmp:5432, DB=<name>; prod: op run + the container). make sql-postgres: SQL on stdin
make fpp-shell           # mariadb shell (uses op run with .env.tpl)
make backup              # manual pg_dump → S3 (prod only — guarded)
make fpp-backup          # manual mariadb-dump → S3 (prod only — guarded)

# Dev — local seeding / DR from prod (all dev-only, never touch prod)
make restore-local       # pull latest (or BACKUP_FILE=) S3 pg backup → the mini's Postgres. Drops and restores the dump's schemas in ${POSTGRES_DB}, never the database.
make pg-sync-schema SCHEMA=argo  # one schema only (least-priv, leaves other schemas intact)
make fpp-sync-from-prod  # direct ssh+docker exec mariadb-dump from VPS → local (fresh, no S3)
make fpp-restore-local   # pull latest S3 backup into local mariadb (DR drill / seed)
make firewall            # show UFW status and rules

# Mac mini Postgres — the one Homebrew server (agent_workflows lives in it), declared in dotfiles config/postgres/cluster.yaml, dev-only, docs/mini-postgres.md
make dev-pg-backup           # globals + every database + row-count manifest → HomeLab, checksum-verified; nightly via LaunchAgent; the Homebrew server over the socket /tmp:5432
make dev-pg-restore-drill    # newest backup → scratch DBs → exact counts vs the source at backup time → scratch dropped; non-zero on mismatch
make dev-pg-health           # readiness probe (one line, exit 0/1) for the devhost heartbeat
make dev-pg-launchd          # install the 03:15 backup LaunchAgent (from the main checkout, not a worktree)
make gh-actions-launchd      # install the GitHub Actions telemetry LaunchAgent (every 60 s → ClickStack; main checkout, not a worktree); gh-actions-launchd-remove, gh-actions-telemetry-run (one tick)
make prune-cron-install  # prod — install the daily image + size-capped build-cache prune, the runner-leftover trim, the exp-scratch sweep and the daily disk budget (cron/docker-prune); never prod volumes
make journald-install    # prod — journal size cap (config/journald-vps.conf) + vacuum
make gh-runner-setup REPO=jkrumm/<repo> [N=2]  # prod — self-hosted Actions runner (instance) for one private repo (token on stdin, docs/gh-runner.md); gh-runner-remove undoes it, gh-runner-reapply re-runs setup for all
make gh-runner-sync      # mini/MacBook (needs gh) — register a VPS runner for every private repo with workflows; DRY_RUN=1 previews

# Restoring PROD from S3 has NO make target by design (it overwrites production).
# Gated, human-only DR scripts: scripts/restore-pg.sh + apps/fpp/scripts/restore-mariadb.sh
# → see docs/disaster-recovery.md

# Deploy config changes to server
git push && ssh vps "cd ~/vps && git pull"
```

> **SSH:** Tailscale only — enforced by UFW (default-deny inbound, only `tailscale0` allowed in), **not** by sshd's bind address: sshd may listen on all interfaces. Never set `ListenAddress` to the Tailscale IP (sshd fails at boot when `tailscale0` is late — a lock-out). Proof: `make firewall`. `ssh vps` uses the Tailscale IP from `~/.ssh/config`.
