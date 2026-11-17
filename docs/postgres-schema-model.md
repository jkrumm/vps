# Postgres schema model

All apps share one database (`${POSTGRES_DB}`). Each app gets its own schema and a dedicated user with schema-only access. The superuser can JOIN across schemas natively.

Pattern for new apps:
1. Add `APP_DB_PASSWORD` to 1Password `vps` vault, and the matching `<APP>_DB_PASSWORD` line to `.env.tpl`
2. Add a setup block to `scripts/setup-postgres.sh` (CREATE SCHEMA + ROLE + GRANTs)
3. Run `make postgres-setup`
4. In compose: `DATABASE_URL: postgresql://app:${APP_DB_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=app`

**Migration journals — own schema, not the shared `drizzle` schema.** drizzle-kit
(and Prisma) default the migration journal to a single `drizzle` schema owned by
whichever app migrates first. On a shared cluster that's a cross-app collision
*and* breaks after a whole-DB restore (`permission denied for schema drizzle`).
Each Postgres app MUST keep its journal in its own schema: drizzle-kit →
`migrations: { schema: '<app>' }` in `drizzle.config.ts` **and** `migrationsSchema`
in the runtime `migrate()` call (Postgres-only option). Then the schema-owning
role owns its journal — no extra grants needed here. Applied: argo
(`argo.__drizzle_migrations`), basalt-ui-playground. N/A for FPP (own MariaDB).

**Local dev seeding** (do not re-implement in the app repo — delegate to vps):
`make pg-sync-schema SCHEMA=<app>` pulls just that schema from prod over SSH, using the
app's own least-priv role. The convention is fixed: **role name == schema name**, and the
password env var is **`UPPER(schema)_DB_PASSWORD`** (so `argo` → `ARGO_DB_PASSWORD`). App
repos call `make -C ../vps pg-sync-schema SCHEMA=<app> ENV=dev` (argo's `bun db:sync` does
exactly this). The local side is the mini's Homebrew Postgres (127.0.0.1:5432, as the schema's role). There is no
whole-DB sync: that server is a maintained instance (`agent_workflows` lives in it), so `sync-from-prod` was
retired. `make restore-local` (MacBook-only S3 DR drill) drops and restores the dump's schemas inside `${POSTGRES_DB}`
and leaves every other database alone.

Current schemas:

| Schema | App | User |
|-|-|-|
| public | (main app / reserved) | ${POSTGRES_USER} |
| umami | Umami analytics | umami |
| basalt_ui_playground | basalt-ui-playground | basalt_ui_playground |
| argo | retired (kept pending drop, see `docs/retired-argo.md`) | argo |
| shutterflow | shutterflow-share | shutterflow |

**Mac mini only — own databases, not schemas:** `agent_workflows`, `shared` and the rest are declared in dotfiles
`config/postgres/cluster.yaml` and applied by `make -C ~/SourceRoot/dotfiles pg-apply`; nothing in this repo
provisions the mini's Postgres. Prod has no such databases. Operations: `docs/mini-postgres.md`.
