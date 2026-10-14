# Self-hosted GitHub Actions runners (private repos)

jkrumm's private repos run their GitHub Actions on this host. The account is a personal GitHub
Free account: hosted minutes for private repos (2,000/month) run out mid-month, and every run
then fails before its first job ("recent account payments have failed or your spending limit
needs to be increased"). Self-hosted runner minutes are free and unmetered.

A personal account has **no account-level runners** — GitHub only offers repository,
organization and enterprise scope — so each private repo gets its **own registration** here.
One runner shared by all repos would need the repos in a GitHub organization.

| | |
|-|-|
| Runner per repo | `vps-<repo>`, labels `self-hosted`, `Linux`, `X64`, `vps` |
| Workflow | `runs-on: [self-hosted, vps]` |
| User | `gh-runner` (system user, no password, not in `docker`/`sudo`) — shared by all runners |
| Install | `/home/gh-runner/runners/<repo>` |
| Service | `actions.runner.jkrumm-<repo>.vps-<repo>.service` (systemd, runs as `gh-runner`) |
| Docker | one rootless daemon in `gh-runner`'s user systemd (`systemctl --user` + linger) |
| Code | `scripts/setup-gh-runner.sh`, `scripts/gh-runner-sync.sh`, `make gh-runner-{setup,remove,sync}` |
| Disk hygiene | `cron/docker-prune` (Sunday 04:35, images + week-old build cache of the rootless daemon) |

Each runner takes one job at a time, so a repo's parallel jobs queue behind each other.

## Why the VPS

Deploy jobs build the images RollHook runs on this host. The VPS is x86_64 like those images;
the mini is arm64 and would build them under emulation. The build load (a few image builds a
week) fits in the headroom next to prod.

## Security model

- **Private repos only.** Never register a runner on a public repo — a fork PR would run
  arbitrary code on the prod host. `setup-gh-runner.sh` refuses a repo the GitHub API reports as
  public; `gh-runner-sync.sh` only lists private repos.
- **No prod Docker.** `gh-runner` is not in the `docker` group (membership is root-equivalent:
  every container and every injected secret). Jobs build against its rootless daemon; each
  runner's `.env` (loaded by the runner into every job) sets `DOCKER_HOST` to that socket. The
  setup script removes any `docker` or `sudo` membership on every run.
- **No prod secrets.** The deploy user's home is `0750` and not world-traversable (re-asserted by
  the script), so the op-injected `apps/*/.env` files are unreadable; `/etc/vps/*.env` are root
  `0600`. A job holds only what its workflow gives it (e.g. the GitHub OIDC token RollHook
  verifies).
- **Shared between repos.** All runners share `gh-runner` and its daemon, so a job in one repo
  can see another repo's workspace and build cache. Acceptable: one owner, and the boundary that
  matters is runner ↔ prod. Unlike a hosted VM, nothing is wiped between jobs — workflows must
  not leave secrets on disk.
- The runners self-update. `RUNNER_VERSION` in the script only pins first install; GitHub stops
  sending jobs to a runner more than ~30 days behind the latest release.

## Add a repo

From any machine with an authenticated `gh` (the VPS has none) — the token is short-lived and
goes over stdin:

```bash
R=jkrumm/<repo>
gh api -X POST repos/$R/actions/runners/registration-token --jq .token \
  | ssh vps "cd ~/vps && make gh-runner-setup ENV=prod REPO=$R"
```

or for every private repo with workflows that has no runner yet:

```bash
make gh-runner-sync DRY_RUN=1   # preview
make gh-runner-sync
```

Then switch the repo's workflows to `runs-on: [self-hosted, vps]` and give jobs a
`timeout-minutes` (a hung job holds that repo's only runner). The job steps must not assume
the hosted image's preinstalled tools: install them per job (`oven-sh/setup-bun`,
`astral-sh/setup-uv`, …). The host has `git`, `curl`, `unzip`, `docker` (rootless) — no
rustup, Node or Python toolchains.

Setup is idempotent: on a registered runner it re-asserts the user, rootless Docker, `.env`,
drop-in and service, ignores the token, and only restarts the service when something it reads
changed (a restart kills an in-flight job). To re-register (e.g. after the runner was deleted
in GitHub's UI), run `make gh-runner-remove` first — `config.sh --replace` then takes over the
name.

## Remove a repo

```bash
R=jkrumm/<repo>
gh api -X POST repos/$R/actions/runners/remove-token --jq .token \
  | ssh vps "cd ~/vps && make gh-runner-remove ENV=prod REPO=$R"
```

Unregisters the runner and removes its systemd unit, drop-in and directory. The user and the
rootless daemon stay for the other repos; to purge them after the last runner is gone:

```bash
sudo loginctl disable-linger gh-runner
sudo userdel -r gh-runner      # also drops ~/.local/share/docker (build cache, images)
sudo sed -i '/^gh-runner:/d' /etc/subuid /etc/subgid
```

## Operate

```bash
gh api repos/jkrumm/<repo>/actions/runners --jq '.runners[] | {name, status, busy}'
ssh vps 'systemctl list-units "actions.runner.*"'
ssh vps 'sudo journalctl -u actions.runner.jkrumm-<repo>.vps-<repo>.service -n 100'
# Rootless Docker disk usage:
ssh vps 'sudo -iu gh-runner env XDG_RUNTIME_DIR=/run/user/$(id -u gh-runner) \
  DOCKER_HOST=unix:///run/user/$(id -u gh-runner)/docker.sock docker system df'
```

A change to `cron/docker-prune` only takes effect after `make prune-cron-install ENV=prod` on
the VPS.
