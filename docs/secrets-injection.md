# Secrets Injection — two runners, two templates

Variable names, values and setup instructions: `README.md` → **Secrets**. This
doc is the rationale for *how* they get injected, not the list itself.

## Two runners

`SECRET_RUNNER` (Makefile top): `secrets-run` wherever it exists, plain
`op run --account tkrumm` otherwise. In practice the two Macs use the shim and
the VPS uses `op` directly — the VPS has no `secrets-run` and a working `op`,
so **prod is unchanged**. On the MacBook the shim passes straight through to
biometric `op`, so that is unchanged too.

The mini is the reason for the indirection. A bare `op` on a headless machine
has no human to answer its biometric prompt, so `make up` does not fail — it
**blocks**. One such run sat wedged for 19 hours (2026-08-01 15:16 →
2026-08-02). `secrets-run` fails closed in a second instead.

## Two templates

Prod targets get the full `.env.tpl`; `require-dev` targets get
`.env.dev.tpl`.

| Variable | Template | Used by |
|-|-|-|
| `$(OP_RUN)` | `.env.tpl` (~40 refs) | `require-prod` targets |
| `$(OP_RUN_DEV)` | `.env.dev.tpl` (~12 refs) | `require-dev` targets |
| `$(OP_RUN_ENV)` | follows `$(ENV)` | targets that work in both envs — `postgres-setup`, `shell-postgres`, `fpp-shell` |

## Why the dev stack needs its own template

The dev stack belongs on the mini — it is the always-on dev host and every app
repo lives there, so the local Postgres/MariaDB/Valkey/ClickStack those apps
develop against has to run there too. Until 2026-08-02 it could not: `make up`
in dev resolved the *entire* prod `.env.tpl` to start four throwaway
containers, so making it work headlessly would have meant caching the
Cloudflare tunnel token, the bucket-wide B2 credential, the RollHook admin
token and every FPP/Sentry secret on the mini. The split is what makes it
possible to cache only what the dev stack actually needs.

Three least-privilege choices inside `.env.dev.tpl`, each explained at its
line there — read that header before adding to it:

- **Dev-only superuser passwords** (`op://mini/vps-dev/*`). Prod's postgres
  superuser and mariadb root passwords stay off the mini. Only the role
  *name* has to match prod (`restore-pg-local.sh` restores a dump carrying
  `OWNER TO <role>`); the password does not.
- **No S3 credential, because none is needed.** `pg-sync-schema SCHEMA=x`
  (one schema; the whole-DB `sync-from-prod` was retired when the mini's
  Postgres became a maintained instance) runs `pg_dump` *inside* the prod
  container against its local socket and stream the dump back over keyless
  Tailscale SSH — no credential crosses the wire either way, and the data is
  fresher than the nightly backup. `fpp-sync-from-prod` is the same shape for
  MariaDB. Don't "simplify" these into a direct remote connection; that would
  put a prod DB login on the mini.
- **`restore-local` / `fpp-restore-local` are the exception and stay
  MacBook-only.** They read S3, so they keep the full `.env.tpl`. They are not
  a data path — they are the DR drill that proves the backup chain replays,
  which belongs on a clean machine. Don't cache an S3 credential to make them
  run on the mini; `pg-sync-schema` already covers the case that motivates it.
- **`AGENT_WORKFLOWS_DB_PASSWORD`** (`op://mini/vps-dev/*`) is a fourth,
  dev-only credential: the login of the role that owns the `agent_workflows`
  database (`docs/mini-postgres.md`). Like the superuser passwords it has no
  prod counterpart.
