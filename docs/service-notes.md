# Service notes

**cloudflared** — all public ingress via Cloudflare Tunnel, outbound-only, no ports exposed. Remote-managed ingress (edit via the `/cloudflare` skill, or `scripts/edge-cache.py` for the edge-cache pattern below): `*.DOMAIN` → `https://traefik:443`, TLS verify disabled (internal cert), **plus one explicit entry per apex / other-zone host** (`DOMAIN`, `basalt-ui.com`, …) — a wildcard never matches its own apex, and a missing entry shows as a bodiless `404`. `--no-autoupdate` lets Watchtower manage the image. Static sites behind Cloudflare's edge cache (proxied CNAME + ingress entry + Cache Rule, verified live): `make edge-cache-status` / `edge-cache-apply` — full pattern in `docs/edge-cache.md`.

**Traefik** — reads Docker labels via `socket-proxy` (TCP, not docker.sock), no ports exposed. Wildcard cert via DNS-01 (still required so cloudflared can verify the TLS handshake). Image pinned to `v3.7` (minor); upgrade by hand, then `make traefik-recreate`. Trace sampling `0.1`.

**Valkey** — `container_name: redis` so apps reference it as `redis:6379`. Persistence enabled (`--save 60 1`). Major version pinned — update manually.

**Watchtower** — `nickfedor/watchtower` (the `containrrr` image is archived), connects via `socket-proxy-watchtower` (`POST=1`, isolated network). Auto-updates everything except Postgres/Valkey/MariaDB/ClickStack and the four socket proxies (`com.centurylinklabs.watchtower.enable=false`; a proxy recreate drops Traefik's docker provider and strands the sweep, incident 2026-11-17). ntfy topic `updates` via shoutrrr, warn level only, daily at 04:00.

**ClickStack** — all-in-one observability container (ClickHouse + OTel Collector + HyperDX UI + MongoDB). Pinned to `2.45.0`, excluded from Watchtower (an auto-bump orphans system-log tables, see `docs/observability.md`), `mem_limit: 6g`. Upgrade by hand: bump the tag, `make deploy` (→ `clickstack-recreate`). Pipelines normalise `deployment.environment.name` (prod/dev) and `host.name` (clickstack/otel-custom.yaml); retention is tiered (sessions 14 d, metrics 400 d, logs/traces 30 d, env in `compose.monitoring.yml`). Two OTLP receivers: `:4318` authed (browser SDKs, cross-host ingest, reached via `otel.DOMAIN` / per-app same-origin routes) and `:4319` unauthed, docker-bridge-only (Traefik + every internal `monitoring-net` service; trust boundary is the network, not the token) — two tiers exist because Traefik 3.x has unfixed env-var substitution bugs in OTLP headers, see `docs/observability.md`.

HyperDX UI at `hyperdx.DOMAIN` (Tailscale-only). Auth via first-visit account creation. Dev: `https://hyperdx.test` or `http://localhost:7707` direct.

**Adding a service to the pipeline**: full runbook in `docs/observability.md`.

**Umami** — analytics at `umami.DOMAIN`. Own schema + dedicated user in the main Postgres database (schema-only access; superuser can still JOIN across schemas). Default credentials `admin`/`umami` — change on first login. Embedding a new site: `docs/umami-integration.md`.

**imgproxy** — image CDN at `img.DOMAIN` (public via Cloudflare), unsigned URLs, renders from the `img/` prefix of the **same bucket as the Postgres/MariaDB backups**. Stateless, no volumes/DB. Monitored with two Kuma checks (public edge + a Tailscale-only `img-origin.DOMAIN` bypass that forces a real B2 fetch); `/health` is liveness-only and stays green while every image 404s. Upload/URL tooling: the global `/img` skill (`imgcli`).

> **Load-bearing invariant:** the B2 key must be created with `--name-prefix img/` — that server-side restriction, not `IMGPROXY_S3_ALLOWED_BUCKETS`, is what keeps this public unauthenticated service away from the database dumps in the same bucket. Never point it at `op://common/backblaze-s3/*` (bucket-wide, has `writeFiles`).

Full design, URL/prefix conventions, the Cloudflare `Vary`/`Accept` caveat, and B2 provisioning: `docs/image-cdn.md`.

**GitHub Actions runners** — one `vps-<repo>` registration per private jkrumm repo, more instances where a repo runs several jobs per push (labels `self-hosted`, `vps`), because the account's free hosted minutes run out and a personal account has no account-level runners. All run as `gh-runner` (no `docker`/`sudo` group) and build against its own rootless Docker daemon, never the prod one. Never on a public repo (fork-PR code execution on the prod host) — the setup script refuses. Install, remove, sync, security model: `docs/gh-runner.md`.

**photo-gallery** — static Astro photo gallery at `photos.DOMAIN`. nginx:alpine serves a host-mounted directory (`/home/jkrumm/photo-gallery-dist:/usr/share/nginx/html:ro`). No image registry, no RollHook — content is built on the developer laptop and rsynced via SSH/Tailscale by the `photo-flow` CLI (`photoflow sync-gallery`). Watchtower auto-updates the nginx base image. The host directory must exist (and contain at least `index.html`) before `make photo-gallery-up`, otherwise the healthcheck fails.
