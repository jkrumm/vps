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
of the new jobs. Untouched: `~/orb-*` (WeatherOrb's own). `/var/lib/weatherorb` (the V1 basemap) was removed 2026-11-17.

## Measured 2026-11-20 (issue_2627)

The alert (`/` at 86 %) fired at 147 GB used, 24 GB free. Share of it: runners' weatherorb cache 27 GB
(3 × 1.100.0 at 7.5 to 8 GB, 3 × stale 1.97.1 at 1.3 GB), `~/orb-capture` 17 GB, `~/factory-steps` 16 GB,
`~/exp*` 13 GB, containerd 28 GB, runners' Docker 14 GB, Docker volumes 12 GB. The rest rests near 84 to 86 %
and the daily 04:30 prune takes 3 to 5 GB off the day's peak, so `/` has no headroom for one more large directory.

## Measured 2026-11-20, second alert (issue_2637)

The same day, `/` was back at 145 GB, 86 %, after issue_2627's toolchain cleanup had already run (weatherorb's
cache was down to the three live 1.100.0 dirs, 23 GB). What stays unbounded and keeps the rest at 84 to 86 %:
`~/orb-capture` 17 GB (grows daily, WeatherOrb's retention), `~/factory-steps` 13 GB (software-factory's),
`~/exp*` 24 GB (now reaped after 2 idle days, see below). A disk this size runs at its alert threshold as long as the
two owned directories grow; the durable lever is those owners' retention or a bigger disk, not this repo's pruning.

## Measured 2026-11-20, third alert (issue_2676)

`/` stood at 148 GB, 87 %, again, with the 7-day `~/exp*` reaper too slow to matter: six of the seven dirs (21 GB, one with
root-owned container output) belonged to weatherorb Issues already closed, the seventh to a running one. Removed by hand
(`/` 137 GB, 81 %) and `EXP_DAYS` cut from 7 to 2, so a closed Issue's scratch goes the next 04:40 run after it goes quiet.
What is left above the alert line is still the two owned directories (`~/orb-capture` 18 GB, `~/factory-steps` 16 GB).

## Per directory

| Directory | Bounded by |
|-|-|
| `/home/gh-runner/.local/share/docker` (images, volumes, build cache of the runners' rootless daemon) | `cron/docker-prune` 04:35 daily: unused images and volumes go; build cache is capped at 6 GB by `--max-used-space` (LRU). Peak is the day's churn plus 6 GB. |
| `/home/gh-runner/runners/*/_work/<repo>` (job checkouts, 0.8–1.6 GB each) | One checkout per runner and repo: `actions/checkout` replaces it. 6 runners, ~5.6 GB with the runner installs. |
| `/home/gh-runner/runners/*/{bin,externals}.<old>`, `_work/_update` | `scripts/gh-runner-clean.sh` 04:40 daily (cron/docker-prune): everything but the live pair, once untouched for a day. ~1.3 GB per runner per runner self-update (~monthly). |
| `/home/gh-runner/cache` (weatherorb's cargo target) | One dir per runner and toolchain version (WeatherOrb's `core` job): 7.5 to 8 GB per runner on 1.100.0, 3 runners, 23 GB live (measured 2026-11-20; the 1.2 GB per runner above was the 1.97.1 toolchain). WeatherOrb wipes one runner's target above 20 GiB (`CORE_CACHE_LIMIT_GIB`), so the worst case is 60 GB. A toolchain bump leaves the old dir: `scripts/gh-runner-clean.sh` 04:40 removes every toolchain dir but the newest per runner once untouched for a day. |
| `/home/gh-runner/.bun`, `.cache` | Tool caches, ~1.3 GB, keyed by lockfile contents; slow growth, no job-driven churn seen. Revisit if it passes 3 GB. |
| `/var/lib/containerd`, `/var/lib/docker/{overlay,image}` | Prod's image store (the containerd store keeps images here, not in `/var/lib/docker`). Live images plus RollHook's 5 tags per app (`ROLLHOOK_IMAGE_KEEP_COUNT`), plus `cron/docker-prune` 04:30 daily: unused images older than 48 h, build cache capped at 3 GB. |
| `/var/lib/docker/volumes` | Data, never pruned. ClickHouse 30 d TTL (7 d system logs), RollHook registry 5 tags per repo, Postgres/MariaDB are the databases. |
| `/var/log` | `journald` capped at 1 GB (`config/journald-vps.conf`, `make journald-install`); the rest is under 50 MB. |
| `~/factory-steps` | software-factory's remote step host: one worktree per project and slot (reused, not growing) plus a shared bun cache. No retention of its own; filed as a signal to software-factory. |
| `~/orb-*` | WeatherOrb's, its own Issue. Not touched here. `~/orb-capture` was 17 GB on 2026-11-20 (mosmix 8.9, wis2 4.5, truth 2.2) and grows daily; its retention is WeatherOrb's, filed as a signal. |
| `~/exp<issue>` | Factory leads' experiment scratch (24 GB across 8 dirs on 2026-11-20, `exp2251` alone 8 GB). `scripts/gh-runner-clean.sh` 04:40 removes a dir once no file in it changed for 2 days (`EXP_DAYS`); a dir an Issue still writes to stays. |
| `/tmp/pytest-of-gh-runner`, `/var/cache/apt` | CI test leftovers (1.1 GB) and the apt package cache (1.4 GB, measured 2026-11-20, issue_2637): `scripts/gh-runner-clean.sh` 04:40 removes the first once untouched for a day and runs `apt-get clean`. |

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
