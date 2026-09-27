# VPS .env.dev.tpl — the LOCAL DEV stack only.
#
# Why this exists, separate from .env.tpl
# ---------------------------------------
# The dev stack is four throwaway containers (postgres, valkey, mariadb,
# clickstack) that between them need five values. Until 2026-08-02 `make up` in
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

# --- Postgres / MariaDB identity -------------------------------------------
# Names, not credentials — T1, safe to cache. They deliberately still resolve
# from the SAME op items prod uses rather than being hard-coded here, because
# sync-pg-from-vps.sh restores a prod dump into the local container: the dump
# carries `OWNER TO <role>` and `CREATE DATABASE <name>`, so a local database or
# superuser role named differently from prod makes the restore fail.
POSTGRES_DB=op://vps/config/POSTGRES_DB
POSTGRES_USER=op://vps/config/POSTGRES_USER
MARIADB_DB=op://vps/config/MARIADB_DB

# --- Local superuser passwords (DEV-ONLY VALUES, not prod's) ----------------
# These containers are created fresh from these values and their volumes are
# throwaway; nothing requires them to match production. Prod's postgres
# superuser and mariadb root passwords are the two highest-value credentials in
# op://vps, and since 2026-08-01 physical possession of the mini yields the
# login password → sudo → the age key → every cached ref, so caching them there
# would hand a stolen mini full production database access for no benefit.
#
# Only the role NAME has to match prod (above); the password does not — the
# dump is restored through the local socket against the local password.
POSTGRES_PASSWORD=op://mini/vps-dev/POSTGRES_PASSWORD
MARIADB_ROOT_PASSWORD=op://mini/vps-dev/MARIADB_ROOT_PASSWORD

# --- Per-app schema roles (scripts/setup-postgres.sh provisions these) ------
# Deliberately still the PROD refs, unlike the superuser passwords above. These
# are per-schema roles, not superusers, and each consuming app's own
# .env.local.tpl already points at the same ref for its local dev connection
# (argo's does) — giving the local roles different passwords would silently
# break every one of those app repos rather than improving anything. This is the
# owner-classified exception already recorded for op://vps/argo/DB_PASSWORD in
# dotfiles-private/headless.refs; the other three are the same call.
#
# sync-pg-schema-from-vps.sh resolves <SCHEMA>_DB_PASSWORD by name, so a new
# schema needs its line here as well as in setup-postgres.sh.
ARGO_DB_PASSWORD=op://vps/argo/DB_PASSWORD
UMAMI_DB_PASSWORD=op://vps/umami/DB_PASSWORD
BASALT_UI_PLAYGROUND_DB_PASSWORD=op://vps/basalt-ui-playground/DB_PASSWORD

# --- Deliberately ABSENT ----------------------------------------------------
# AWS_* (S3 backup credential)
#   Getting prod data onto the mini does NOT need one. `make sync-from-prod`
#   (whole DB) and `make pg-sync-schema SCHEMA=x` (one schema) run pg_dump INSIDE
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
#   `sync-from-prod` already covers the case you actually want.
#
# CLOUDFLARE_* .......... no dev container fronts anything; prod tunnel token
# FPP_*, EMAIL_GATEWAY_* prod app secrets, prod-only compose files
# ROLLHOOK_SECRET ....... prod registry + admin token
# IMGPROXY_*, SLACK_*, UPTIME_KUMA_*, BESZEL_*, HYPERDX_API_KEY, DOMAIN,
# ACME_EMAIL, VPS_TAILSCALE_IP ... prod-only
# MARIADB_FPP_PASSWORD .. only apps/fpp/scripts/setup-mariadb.sh (require-prod)
