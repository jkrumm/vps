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
| `fpp-server` | `rollhook.jkrumm.com/fpp-server:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics` | `rollhook.jkrumm.com/fpp-analytics:latest` | `proxy` | RollHook on push to master |
| `fpp-analytics-updater` | `rollhook.jkrumm.com/fpp-analytics-updater:latest` (same content as fpp-analytics) | `mariadb-net` | RollHook on push to master |

`fpp-server`, `fpp-analytics` and the updater follow the RollHook contract (no `container_name`, no `ports`, healthcheck, `IMAGE_TAG` env var, `rollhook.allowed_repos=jkrumm/free-planning-poker`). The updater is a sleep-loop sidecar that connects to MariaDB internally with TLS+no-verify (cert CN `*.free-planning-poker.com` doesn't match the `mariadb` hostname).

`fpp-server` also forwards in-app feedback to the software-factory door on the mini (`FACTORY_FEEDBACK_URL` + `FACTORY_FEEDBACK_TOKEN`; unset → `POST /feedback` answers 503, wrong → 502). The VPS has no MagicDNS, so `extra_hosts` pins `${MINI_TAILNET_NAME}` to `${MINI_TAILSCALE_IP}`; the URL must keep the name because the door (`tailscale serve`) only has a cert for it. Needs the ACL grant `tag:vps → tag:devhost` on tcp:8796. The three vars live in the root `.env.tpl` (for `make fpp-up`) and `apps/fpp/.env.tpl` (for RollHook; re-run `make fpp-env` after changing them). They are `${X:-}`, never `${X:?}`: RollHook's validate step loads the compose file without `apps/fpp/.env` (only its rollout step passes it), so a `:?` var rejects every fpp deploy (Issue 1348). If the mini is renamed or re-joined, update `op://vps/config/MINI_*`.
