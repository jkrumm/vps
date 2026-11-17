# Deploy — the no-`APP` flow and the path map

With no `APP`, `make deploy` drives the same flow off the diff: it reads the last
deployed SHA from the gitignored `.deploy-sha` (seeding it with `HEAD` and
deploying nothing on the first run), maps every file changed since to its app
(`apps/<name>/**` → that app) or shared stack (`traefik/`,
`compose.networking.yml` → `networking`; `compose.infra.yml` → `infra`;
`compose.monitoring.yml` → `monitoring`, plus the tokens below), runs each affected
target, and records the new `HEAD` plus the app list in `.deploy-sha` /
`.deploy-apps` (both gitignored). A diff touching no app or stack prints
`nothing to deploy` and exits 0.

| Changed path | Token | Action |
|-|-|-|
| `apps/<name>/**` | app | `deploy APP=<name>` |
| `apps/fpp/fail2ban/**` | `fail2ban` | `make fail2ban-install` (install filter + jail, reload) |
| `compose.networking.yml` / `compose.infra.yml` / `compose.monitoring.yml` | stack | `networking-up` / `infra-up` / `monitoring-up` |
| `traefik/traefik.yml` | `traefik-conf` | `make traefik-recreate` (bind-mounted, `up -d` would keep the old config) |
| `clickstack/**` | `clickstack-conf` | `make clickstack-recreate` |
| `cron/*` (not `*.env.tpl`) | `cron` | `make cron-install` (to `/etc/cron.d`) |
| `observability/**` | `hyperdx` | hint only: run `make hyperdx-apply ENV=prod` — deploy never applies dashboards/alerts |

`traefik/dynamic/` is hot-reloaded (no token); `cron/*.env.tpl` needs `make cron-env-seed`. Infra tokens are skipped by `make verify`.

## make verify and make version

`make verify APP=<name>` probes one app and exits non-zero if it is not live and
healthy. Public endpoints are `curl -fsS`'d directly; apps reached only over
Tailscale (or behind auth) are checked by their container healthcheck over SSH —
no secrets or DNS lookup needed. `make logs APP=<name>` prints a bounded 200-line
tail and exits (no `-f`). With no `APP`, `make verify` re-verifies every app
recorded in `.deploy-apps` by the last `make deploy` and exits non-zero if any is
unhealthy; infra entries (which have no app health check) are skipped. When no
deploy is recorded (`.deploy-apps` missing or empty, e.g. the last deploy touched
no app), it verifies every known app's live state instead of exiting 0.

`make version` prints the VPS checkout's `HEAD` (one line, read-only); the factory
compares it with a shipped commit. `project.yaml` declares the factory manifest:
`deploy.mode make`, target `vps` verified by `make verify`, ships by push.

## Shared-stack Kuma monitors

The shared stacks have their own Kuma monitors: `traefik.<your-domain>` →
`Traefik - HTTP`, `rollhook.<your-domain>/ready` → `RollHook - Ready - HTTP`,
`hyperdx.<your-domain>` → `HyperDX - HTTP`, `umami.<your-domain>/api/heartbeat`
→ `Umami - HTTP`, plus the Postgres liveness/backup and FPP DB/readmodel push
monitors. `<your-domain>` stands for the apex in `DOMAIN`; the monitors
themselves live in the homelab repo. For a public service the edge probe can stay
green through an origin outage (Cloudflare edge cache) — `imgproxy` is the
clearest case: the `ImageCDN Origin` monitor is the one that proves a real B2
fetch.
