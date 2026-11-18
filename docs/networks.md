# Networks and traffic routing

External networks (pre-created by `setup.sh`, referenced as `external: true`):

| Network | Purpose | Who connects |
|-|-|-|
| `proxy` | Traefik routing | Traefik, all apps |
| `postgres-net` | Postgres access | Postgres, apps needing DB |
| `mariadb-net` | FPP MariaDB access | MariaDB, FPP services, backup container |
| `valkey-net` | Valkey/Redis access | Valkey, apps needing cache |
| `monitoring-net` | Observability bus | ClickStack, Dozzle, host-probe, apps sending OTel |

Internal networks (created by Docker Compose, not external):

| Network | Purpose |
|-|-|
| `socket-proxy-net` | Traefik → socket-proxy (read-only, POST=0) |
| `socket-proxy-rollhook-net` | RollHook → socket-proxy-rollhook (POST=1, write access) |
| `socket-proxy-watchtower-net` | Watchtower → socket-proxy-watchtower (POST=1, write access) |
| `socket-proxy-monitoring-net` | Dozzle + host-probe → socket-proxy-monitoring (read-only, LOGS+STATS) |

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
- **No `ipAllowList` on the dashboard/HyperDX routers.** Their access control is
  DNS: a grey-cloud A record to the Tailscale IP (CGNAT, unreachable from the
  internet). `ipAllowList` only sees a real client IP if the request reaches
  Traefik with its source address intact. Through cloudflared every request
  arrives from a container address, so a router that wants it as an allowlist
  (a tunnel request fails it) relies on the `:443` publish keeping tailnet
  source addresses. No router uses one today. Unverified live: confirm with a
  tailnet request before building on it.
