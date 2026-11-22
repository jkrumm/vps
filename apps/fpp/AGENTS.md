# FPP (apps/fpp/)

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

## FPP application services

`apps/fpp/compose.yml` also defines the application services that consume this DB:

| Service | Image | Network | Deploy |
|-|-|-|-|
| `fpp-server` | `rollhook.jkrumm.com/fpp-server:latest` | `proxy` | RollHook on push to v1 |
| `fpp-analytics` | `rollhook.jkrumm.com/fpp-analytics:latest` | `proxy` | RollHook on push to v1 |
| `fpp-analytics-updater` | `rollhook.jkrumm.com/fpp-analytics-updater:latest` (same content as fpp-analytics) | `mariadb-net` | RollHook on push to v1 |

`fpp-server`, `fpp-analytics` and the updater follow the RollHook contract (no `container_name`, no `ports`, healthcheck, `IMAGE_TAG` env var, `rollhook.allowed_repos=jkrumm/free-planning-poker`, `rollhook.allowed_refs=refs/heads/v1`: v1 is frozen on the branch `v1`, deploys come from it only, master is deliberately not allowed). The updater is a sleep-loop sidecar that connects to MariaDB internally with TLS+no-verify (cert CN `*.free-planning-poker.com` doesn't match the `mariadb` hostname).

## fpp-api — the v9 beta host

`fpp-api` is the Free Planning Poker rewrite: one image (built from `apps/api/Dockerfile` of the app repo) serving the API, the WebSocket and the room app on port 7740, public at `https://next.free-planning-poker.com` until the cutover (v1, Vercel and the apex are untouched). RollHook contract as above, with `rollhook.allowed_refs=refs/heads/master`; it talks to the shared Postgres (role and schema `fpp`, `make postgres-setup`), not MariaDB, and has `stop_grace_period: 30s` because the app drains for 20 s.

- **Secrets:** `FPP_VISITOR_KEY` (`op://vps/fpp/VISITOR_KEY`, 32+ characters, the app refuses to start without it) and `FPP_DB_PASSWORD` are in both `.env.tpl` files; re-run `make fpp-env` after changing them. The VPS service account cannot write to 1Password: a new field is created from a MacBook, and its ref must resolve before the `.env.tpl` line is pushed.
- **Routing:** the tunnel's wildcard ingress covers the hostname; DNS is a proxied CNAME `next` to the tunnel (`/cloudflare`). The router has `security-headers@file`, an `X-Robots-Tag: noindex` header and its own rate limit `fpp-api-ratelimit` (100/s per `Cf-Connecting-Ip`, burst 1500). `rate-limit@file` (burst 200) would 429 part of a room of 30 behind one address loading the room app at once; the sizing is in the compose comment. Health: `/api/health` (503 while draining), also Traefik's active check. `/api/u/p.js` and `/api/u/api/p` on this host are Umami's tracker and collect endpoint (router `umami-fpp` on the `umami` service in `compose.monitoring.yml`, priority 1000; `docs/umami-integration.md`), not fpp-api.
- **No image yet:** `make fpp-api-up` (called by `make fpp-up`) skips with a message while there is no container and no image in the registry, and `make verify APP=fpp` skips an absent fpp-api container; the first image comes from the app repo's `v9-next-deploy`. Once it runs, move `fpp-api` into `APP_SERVICE_fpp` (Makefile).
- **Telemetry:** `fpp-api` and the browser service `fpp-room` are in `observability/services.yaml` with `expected: none` and no budget; after the first image set `expected` to all, seed budgets and add the `fpp-api silent` alert (`docs/observability.md` → Free Planning Poker v9: dashboard `Free Planning Poker v9`, the alerts, and the list of v1 items to remove at the cutover).

`fpp-server` also forwards in-app feedback to the software-factory door on the mini (`FACTORY_FEEDBACK_URL` + `FACTORY_FEEDBACK_TOKEN`; unset → `POST /feedback` answers 503, wrong → 502). The VPS has no MagicDNS, so `extra_hosts` pins `${MINI_TAILNET_NAME}` to `${MINI_TAILSCALE_IP}`; the URL must keep the name because the door (`tailscale serve`) only has a cert for it. Needs the ACL grant `tag:vps → tag:devhost` on tcp:8796. The three vars live in the root `.env.tpl` (for `make fpp-up`) and `apps/fpp/.env.tpl` (for RollHook; re-run `make fpp-env` after changing them). They are `${X:-}`, never `${X:?}`: RollHook's validate step loads the compose file without `apps/fpp/.env` (only its rollout step passes it), so a `:?` var rejects every fpp deploy (Issue 1348). If the mini is renamed or re-joined, update `op://vps/config/MINI_*`.
