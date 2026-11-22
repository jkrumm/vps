# Disk budget — the VPS root disk

The root disk is 178 GB and the host runs prod, every private repo's CI and the factory's remote steps. It paged
at 90 % on 2026-11-17 (incident 1842) and at 85 to 87 % on three more days up to 2026-11-21, four rounds of hand
sweeping. Each directory was "bounded", but the bounds added up to the disk. This page is the one table that
cannot: caps that sum under 75 % of the disk, a daily job that measures them, and a signal to the owner of a row
that passes its cap. `scripts/disk-watch.sh` still pushes ntfy `alerts` at 80 % (the last line, not the plan).
The VPS is discontinued once the home server stands, so this holds the line until then and redesigns nothing.

## Budget

Caps in GiB. `config/disk-budget.json` is the same table as data (fields `id`, `paths`, `owner`, `cap_gib`,
`class`, `enforced_by`, like the mini's); `make check` fails when the caps pass 75 % of 178 GiB (133.5) or this
table and the file disagree. A directory with no row is unbounded: the daily job reports any path over 5 GiB that
no row covers.

| Row | Path | Owner | Class | Cap | Held by |
|-|-|-|-|-|-|
| `containerd` | `/var/lib/containerd` | vps | data | 30 | Prod's image store: live images plus RollHook's 5 tags per app (`ROLLHOOK_IMAGE_KEEP_COUNT`); `cron/docker-prune` 04:30 removes unused images older than 48 h and caps build cache at 3 GB. |
| `docker` | `/var/lib/docker` | vps | data | 13 | Volumes are data and never pruned: ClickHouse 30 d TTL (7 d system logs), RollHook 5 tags per repo, the databases. |
| `runner-docker` | `/home/gh-runner/.local` | vps | build | 12 | The runners' rootless daemon: images and volumes pruned daily 04:35, build cache capped at **3 GB** (was 6 until issue 2849). Peak is the day's churn plus the cap. |
| `runners` | `/home/gh-runner/runners` | vps | build | 7 | One checkout per runner and repo (`actions/checkout` replaces it); `scripts/gh-runner-clean.sh` 04:40 drops self-update leftovers (1.3 GB per runner and update). |
| `runner-cache` | `/home/gh-runner/cache` | weatherorb | build | 15 | WeatherOrb's cargo target, one dir per runner and toolchain, 5 to 10 GB each on 3 runners. WeatherOrb wipes one runner's target above `CORE_CACHE_LIMIT_GIB` (10, `core/core.mk`), so the worst case is 30 on 3 runners; measured 23 GB (2026-11-20) and 29 GB (2026-11-21), so the steady state is over the cap. The cap is **not held by the host**: over it files a signal to weatherorb (2 runners or a lower wipe cap). `gh-runner-clean.sh` drops superseded toolchains. |
| `runner-tools` | `/home/gh-runner/{.bun,.cache,.npm,.docker}` | vps | cache | 5 | Keyed by lockfile contents, 3.3 GB measured 2026-11-21, slow growth. |
| `factory-steps` | `~/factory-steps` | software-factory | cache | 12 | The factory's own step-host trim (`trim.ts`, every 6 h, runs only with no step running): slot copies idle 7 days go, the bun cache is capped at 3 GiB; bare repos (0.5 GB) stay. Worst case 4 projects × slots × up to 2 GB, bounded by the 7 days. |
| `orb-capture` | `~/orb-capture` | weatherorb | history | 16 | WeatherOrb's 7-day retention, the prune of confirmed captures started 2026-11-22; about 20 GiB measured that day (mosmix, wis2, truth), steady state about 15 GiB. Over it files a signal to weatherorb. |
| `exp` | `~/exp<issue>`, `~/agw<issue>` | vps | build | 6 | `scripts/exp-sweep.sh` 04:45 (root: containers leave root-owned files): removed once the Issue is closed, kept while the factory says it is open, else removed after 2 idle days (`EXP_DAYS`). |
| `home-other` | `~/{cache,orb-sites,orb-corpus,sizing-probe,shutterflow-releases,photo-gallery-dist,vps,backups}` | vps | data | 3 | Small and named; a path that grows past its share gets its own row. |
| `rest` | everything else | vps | data | 10 | `/usr` 3.5, swap 1.9, `/var` outside the rows 2.9 (journald capped at 1 GB, `config/journald-vps.conf`), `/tmp` 0.7, `/boot`; measured as df used minus the rows above. |
| | **Sum** | | | **129** | 72 % of 178 GiB; the line is 133.5. |

## The daily jobs

All in `cron/docker-prune` (`make prune-cron-install`), each logs one line per step:

| Time | Job | Log |
|-|-|-|
| 04:30 | prod daemon: unused images older than 48 h, build cache to 3 GB | `~/docker-prune.log` |
| 04:35 | runners' daemon: images, volumes, build cache to 3 GB | the gh-runner home's `docker-prune.log` |
| 04:40 | `scripts/gh-runner-clean.sh`: update leftovers, old toolchains, pytest leftovers, apt cache | `/var/log/gh-runner-clean.log` |
| 04:45 | `scripts/exp-sweep.sh`: closed Issues' scratch | `/var/log/exp-sweep.log` |
| 05:00 | `scripts/disk_budget.py`: sum check, measure every row, unknown paths over 5 GiB, status file `/var/tmp/disk-budget.json`, one signal per over-cap owner (refiled every 7 days while over) | `/var/log/disk-budget.log` |

The signal is `factory signal file --repo <owner>` when the factory CLI is on the host; this host has none, so
the job falls back to one ntfy push per owner on `alerts`. `exp-sweep.sh` asks the factory about an Issue the
same way and falls back to the idle rule; it takes `--closed <n>...` for a caller that knows. Both are filed
as signals to software-factory (a read path from this host) and dotfiles (pass the closed ids over ssh).

## Measured

- 2026-11-17 (issue 2033): 145 GB used, 86 % → 111 GB after manual runs; rootless Docker 28 → 5 GB (18 GB of cache), runners 16 → 5.6 GB.
- 2026-11-20 (issues 2627, 2637, 2676): 147 GB, 86 to 87 %; weatherorb's cargo cache 27 GB (3 runners × 8 GB + stale toolchains), `~/orb-capture` 17 GB, `~/factory-steps` 16 GB, `~/exp*` 13 to 24 GB, containerd 28 GB, runners' Docker 14 GB, volumes 12 GB.
- 2026-11-21 (issue 2849): 140 GB used, 82 %, 31 GB free. `/home/gh-runner` 47 GB (Docker 19, cache 19, runners 5.6), `/var/lib` 43 (containerd 30, docker 12), `~/orb-capture` 21, `~/factory-steps` 17, `~/exp*` 7. Over their caps that day: `runner-docker`, `runner-cache`, `factory-steps`, `orb-capture`.
- 2026-11-22 (issue 2895): `~/orb-capture` about 20 GiB (mosmix 10.2, wis2 5.5, truth 2.6: 18.3 named, the rest unlisted). The prune started that day; its 7-day steady state is about 15 GiB, so the row is 16 (was 12).

## Why a size cap, not an age filter

`docker builder prune --filter until=…` matches nothing on this engine (Docker 29.9, containerd image store,
buildkit 0.34): the daily 48 h prune of the runners reclaimed 0 B while 162 records last used four weeks earlier
stayed (18 GB). The same flag on `docker buildx prune` also does nothing; plain `prune -a` and `--max-used-space`
do. Without `-a` only dangling records are touched. The per-day `docker image prune` / `volume prune` calls are
unaffected.

## When the alert fires

`df -h /`, then `cat /var/tmp/disk-budget.json` (last night's rows with measured and cap) and
`sudo python3 -I ~/vps/scripts/disk_budget.py --dry` for a fresh read. A row over its cap names its owner and what
should have held it. For a path no row covers: `sudo du -xh --max-depth=1 /home/gh-runner /var/lib /home/jkrumm | sort -h | tail`,
then add the row. The runners' daemon is reached via `sudo -iu gh-runner` (`docs/gh-runner.md`).
