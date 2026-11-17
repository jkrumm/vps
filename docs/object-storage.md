# Object storage — bucket layout and backup gaps

S3-compatible object storage, bucket `jkrumm`. All paths are prefixed to avoid collisions across sources:

```
jkrumm/
├── backups/vps/
│   ├── postgres/       ← backup-pg.sh (daily cron 03:00, 14-day retention)
│   ├── mariadb/        ← apps/fpp/scripts/backup-mariadb.sh (daily cron 03:30)
│   └── email-gateway/  ← scripts/backup-email-gateway.sh (daily cron 03:45, SQLite snapshots)
└── img/                ← imgproxy origin — read-only, name-prefix-locked B2 key (docs/image-cdn.md)
```

**Not backed up** (know the gap before a rebuild):

- **`shutterflow-key-broker-state`** (volume) holds only `purges.json` — closed accounts and their grace periods. Not rebuildable from git or 1Password; shutterflow's own docs recommend backing it up. **Known gap, open.**
- **`/home/jkrumm/shutterflow-releases`** (host dir, mounted `:ro` at `/releases` into `shutterflow-share`) is the desktop app's update feed: app data owned by the mini's publish script (last five releases, ~300 MB). Never prune by hand; rebuildable by re-publishing. `make shutterflow-up` creates it (jkrumm, 755) before the mount — Docker would create a missing bind source root-owned.
- **`rollhook-data`** holds the SQLite DB, job logs and registry images: deploy history only. Rebuildable by re-running each app's CI.
- **Postgres roles/globals** are not in the dump; `make postgres-setup` recreates them (DR order: setup → restore → setup, `docs/disaster-recovery.md`).

HomeLab backup scripts write their own `backups/homelab/<service>/` prefix
using the same `AWS_*` credentials (`common` vault) — not enumerated here
since none exist yet.
