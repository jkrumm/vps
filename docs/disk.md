# Disk budget — what bounds each directory

The root disk is 178 GB and the host runs prod, every private repo's CI and the factory's remote
steps. It crossed 90 % on 2026-11-17 (incident 1842), and stood at 86 % a day after the first fix.
This page says what bounds each large directory; a directory with no line here is unbounded and
the next incident. `scripts/disk-watch.sh` pushes ntfy `alerts` at 80 %.

## Measured 2026-11-17 (issue_2033)

| | Before (15:00 UTC) | After (16:30 UTC, same day) |
|-|-|-|
| `df /` | 145 GB used, 86 % | 111 GB used, 66 % |
| `/home/gh-runner` | 46 GB | 11 GB |
| of it rootless Docker | 28 GB (18 GB build cache) | 5 GB (cache emptied; refills with the day's CI) |
| of it runners | 16 GB (8 GB of update leftovers) | 5.6 GB |
| `/var/lib/docker` | 18 GB | 18 GB (volumes: data) |
| `/var/lib/containerd` | 20 GB | 19 GB |
| `/var/log` | 2.8 GB | 1.2 GB |
| `~/factory-steps` | 7.2 GB | 7.2 GB (not ours, see below) |

The one-day result is in the issue's report; this table is the same-day state after the manual runs
of the new jobs. Untouched: `~/orb-*`, `/var/lib/weatherorb` (WeatherOrb's own).

## Per directory

| Directory | Bounded by |
|-|-|
| `/home/gh-runner/.local/share/docker` (images, volumes, build cache of the runners' rootless daemon) | `cron/docker-prune` 04:35 daily: unused images and volumes go; build cache is capped at 6 GB by `--max-used-space` (LRU). Peak is the day's churn plus 6 GB. |
| `/home/gh-runner/runners/*/_work/<repo>` (job checkouts, 0.8–1.6 GB each) | One checkout per runner and repo: `actions/checkout` replaces it. 6 runners, ~5.6 GB with the runner installs. |
| `/home/gh-runner/runners/*/{bin,externals}.<old>`, `_work/_update` | `scripts/gh-runner-clean.sh` 04:40 daily (cron/docker-prune): everything but the live pair, once untouched for a day. ~1.3 GB per runner per runner self-update (~monthly). |
| `/home/gh-runner/cache` (weatherorb's cargo target) | One dir per runner and toolchain version (WeatherOrb's `core` job); 1.2 GB. Grows only with a toolchain bump or a new runner. |
| `/home/gh-runner/.bun`, `.cache` | Tool caches, ~1.3 GB, keyed by lockfile contents; slow growth, no job-driven churn seen. Revisit if it passes 3 GB. |
| `/var/lib/containerd`, `/var/lib/docker/{overlay,image}` | Prod's image store (the containerd store keeps images here, not in `/var/lib/docker`). Live images plus RollHook's 5 tags per app (`ROLLHOOK_IMAGE_KEEP_COUNT`), plus `cron/docker-prune` 04:30 daily: unused images older than 48 h except those labelled `factory.image` (the factory's step images, which it retains itself), build cache capped at 3 GB. |
| `/var/lib/docker/volumes` | Data, never pruned. ClickHouse 30 d TTL (7 d system logs), RollHook registry 5 tags per repo, Postgres/MariaDB are the databases. |
| `/var/log` | `journald` capped at 1 GB (`config/journald-vps.conf`, `make journald-install`); the rest is under 50 MB. |
| `~/factory-steps` | software-factory's remote step host: one worktree per project and slot (reused, not growing) plus a shared bun cache. No retention of its own; filed as a signal to software-factory. |
| `~/orb-*`, `/var/lib/weatherorb` | WeatherOrb's, its own Issue. Not touched here. |

## Why a size cap, not an age filter

`docker builder prune --filter until=…` matches nothing on this engine (Docker 29.9, containerd image
store, buildkit 0.34): the daily 48 h prune of the runners reclaimed 0 B while 162 records last used
four weeks earlier stayed (18 GB). The same flag on `docker buildx prune` also does nothing; plain
`prune -a` and `--max-used-space` do. Without `-a` only dangling records are touched.
The per-day `docker image prune` / `volume prune` calls are unaffected.

## When the alert fires

`df -h /`, then in this order: `docker system df` on both daemons (the runners' via `sudo -iu gh-runner`,
see `docs/gh-runner.md`), `sudo du -xh --max-depth=1 /home/gh-runner /var/lib /home/jkrumm | sort -h | tail`,
then the table above for what should have bounded it.
