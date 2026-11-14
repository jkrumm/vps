# VPS .env.dev.tpl — the LOCAL DEV stack only.
#
# Why this exists, separate from .env.tpl
# ---------------------------------------
# The dev stack is three throwaway containers (valkey, mariadb, clickstack) plus the
# scripts that talk to the mini's Postgres (a Homebrew server, declared in dotfiles
# config/postgres/cluster.yaml). Until 2026-08-02 `make up` in
# dev resolved the FULL .env.tpl to start them — ~40 refs including the prod
# Cloudflare tunnel token, the bucket-wide B2 backup credential, every FPP and
# Sentry secret, and the RollHook admin token. None of that is used by a single
# dev container.
#
# That was merely wasteful on the MacBook. On the Mac mini — the always-on dev
# host, where these containers actually belong — it was fatal: `secrets-run`
# fails closed on any ref missing from dotfiles-private/headless.refs, and
# caching 40 production secrets to run a local Postgres is not a trade worth
# making. (Before secrets-run it was worse: a bare `op` there has no human to
# answer its biometric prompt, so `make up` blocked instead of failing. One run
# sat wedged for 19 hours, 2026-08-01 15:16 → 2026-08-02.)
#
# So the dev targets read THIS file. The rule for adding a line: it must be
# needed by a require-dev target, and it must be the least-privileged value that
# works — a dev-only credential where one is possible, a read-only prod
# credential where prod data genuinely has to be read.

# --- Database names ----------------------------------------------------------
# Names, not credentials — T1, safe to cache. They deliberately still resolve
# from the SAME op items prod uses rather than being hard-coded here, because
# restore-pg-local.sh (the S3 DR drill, MacBook) restores a prod dump into the local
# server and picks the backup by the prod database name, and pg-sync-schema pulls
# that same database from prod.
POSTGRES_DB=op://vps/config/POSTGRES_DB
MARIADB_DB=op://vps/config/MARIADB_DB

# --- Local MariaDB root password (DEV-ONLY VALUE, not prod's) ----------------
# The container is created from this value; nothing requires it to match production.
# Prod's mariadb root password is among the highest-value credentials in op://vps, and
# since 2026-08-01 physical possession of the mini yields the login password → sudo →
# the age key → every cached ref, so caching it there would hand a stolen mini full
# production database access for no benefit.
#
# There is no local Postgres superuser credential: the mini's Postgres (Homebrew
# server, dotfiles config/postgres/cluster.yaml) trusts the OS user over its 0700
# unix socket, and its other roles' passwords are declared there (`pg-apply`).
MARIADB_ROOT_PASSWORD=op://mini/vps-dev/MARIADB_ROOT_PASSWORD

# --- Per-schema roles of the prod mirror (scripts/sync-pg-schema-from-vps.sh) -
# Deliberately the PROD refs, like the cluster declares them (roles argo, umami,
# basalt_ui_playground): per-schema roles, not superusers, and each consuming app's own
# .env.local.tpl already points at the same ref for its local dev connection (argo's
# does) — giving the local roles different passwords would silently break every one of
# those app repos rather than improving anything. This is the owner-classified exception
# already recorded for op://vps/argo/DB_PASSWORD in dotfiles-private/headless.refs; the
# other two are the same call.
#
# sync-pg-schema-from-vps.sh resolves <SCHEMA>_DB_PASSWORD by name, so a new mirrored
# schema needs its line here and its role in dotfiles config/postgres/cluster.yaml.
ARGO_DB_PASSWORD=op://vps/argo/DB_PASSWORD
UMAMI_DB_PASSWORD=op://vps/umami/DB_PASSWORD
BASALT_UI_PLAYGROUND_DB_PASSWORD=op://vps/basalt-ui-playground/DB_PASSWORD

# --- Deliberately ABSENT ----------------------------------------------------
# AWS_* (S3 backup credential)
#   Getting prod data onto the mini does NOT need one. `make pg-sync-schema
#   SCHEMA=x` (one schema; the whole-DB sync-from-prod was retired because the mini's
#   Postgres is a maintained instance now) runs pg_dump INSIDE
#   the prod container against its local socket and stream the dump back over
#   keyless Tailscale SSH — no credential crosses the wire in either direction,
#   and the data is fresher than the nightly backup besides. `fpp-sync-from-prod`
#   is the same shape for MariaDB.
#
#   Only `restore-local` / `fpp-restore-local` read S3, and those are not a data
#   path — they are the DR drill that proves the backup chain replays, which
#   belongs on a clean machine anyway. They keep the full .env.tpl and stay
#   MacBook-only. Do not add an S3 credential here to make them run on the mini:
#   the whole reason this file exists is to keep prod credentials off it, and
#   `pg-sync-schema` already covers the case you actually want.
#
# CLOUDFLARE_* .......... no dev container fronts anything; prod tunnel token
# FPP_*, EMAIL_GATEWAY_* prod app secrets, prod-only compose files
# ROLLHOOK_SECRET ....... prod registry + admin token
# IMGPROXY_*, NTFY_*, UPTIME_KUMA_*, BESZEL_*, HYPERDX_API_KEY, DOMAIN,
# ACME_EMAIL, VPS_TAILSCALE_IP ... prod-only
# MARIADB_FPP_PASSWORD .. only apps/fpp/scripts/setup-mariadb.sh (require-prod)
