# Self-hosted GitHub Actions runner (jkrumm/shutterflow)

One runner on this host, registered to **jkrumm/shutterflow only**. Shutterflow is a private
repo on a GitHub Free account; its hosted-runner minutes run out mid-month and every run then
fails before the first job. Self-hosted runner minutes are free and unmetered, so its workflows
run here: `runs-on: [self-hosted, vps]`.

| | |
|-|-|
| Name | `vps-shutterflow` |
| Labels | `self-hosted`, `Linux`, `X64`, `vps` |
| User | `gh-runner` (system user, no password, not in `docker`/`sudo`) |
| Install | `/home/gh-runner/actions-runner` |
| Service | `actions.runner.jkrumm-shutterflow.vps-shutterflow.service` (systemd, runs as `gh-runner`) |
| Docker | rootless daemon in `gh-runner`'s user systemd (`systemctl --user` + linger) |
| Setup code | `scripts/setup-gh-runner.sh`, `make gh-runner-setup` / `make gh-runner-remove` |

## Why the VPS

The deploy job builds the `shutterflow-share` image that RollHook runs on this host. The VPS is
x86_64 like that image; the mini is arm64 and would build it under emulation. The build load
(a Bun image, a few times a week) fits in the headroom next to prod.

## Security model

- **Repo-scoped, private repo only.** Never register this runner on a public repo — a fork PR
  would run arbitrary code on the prod host.
- **No prod Docker.** `gh-runner` is not in the `docker` group (membership is root-equivalent:
  every container and every injected secret). Jobs build against its own rootless daemon; the
  runner's `.env` sets `DOCKER_HOST` to that socket. The setup script removes any `docker` or
  `sudo` membership on every run.
- **No prod secrets.** The deploy user's home is `0750` and not world-traversable (re-asserted by
  the script), so the op-injected `apps/*/.env` files are unreadable. `/etc/vps/*.env` are root
  `0600`. The only credential a job holds is the GitHub OIDC token RollHook verifies.
- The runner self-updates. `RUNNER_VERSION` in the script only pins the first install; GitHub
  stops sending jobs to a runner more than ~30 days behind the latest release, so auto-update
  stays on.

## Install / re-register

Run from any machine with an authenticated `gh` (the VPS has none). The token is short-lived
and goes over stdin, never argv:

```bash
gh api -X POST repos/jkrumm/shutterflow/actions/runners/registration-token --jq .token \
  | ssh vps 'cd ~/vps && make gh-runner-setup ENV=prod'
```

Idempotent: on a registered runner it re-asserts the user, rootless Docker, `.env` and service,
and ignores the token. To re-register (e.g. after the runner was deleted in GitHub's UI), run
`make gh-runner-remove` first, or delete `/home/gh-runner/actions-runner/.runner` and re-run
setup — `config.sh --replace` takes over the existing name.

## Remove

```bash
gh api -X POST repos/jkrumm/shutterflow/actions/runners/remove-token --jq .token \
  | ssh vps 'cd ~/vps && make gh-runner-remove ENV=prod'
```

Unregisters the runner and uninstalls its systemd unit. The user and its rootless Docker data
stay; to purge them too:

```bash
sudo loginctl disable-linger gh-runner
sudo userdel -r gh-runner      # also drops ~/.local/share/docker (build cache, images)
sudo sed -i '/^gh-runner:/d' /etc/subuid /etc/subgid
```

## Operate

```bash
gh api repos/jkrumm/shutterflow/actions/runners --jq '.runners[] | {name, status, busy}'
ssh vps 'systemctl status actions.runner.jkrumm-shutterflow.vps-shutterflow.service'
ssh vps 'sudo journalctl -u actions.runner.jkrumm-shutterflow.vps-shutterflow.service -n 100'
# Rootless Docker disk usage / prune (build cache grows with every deploy):
ssh vps 'sudo -iu gh-runner env XDG_RUNTIME_DIR=/run/user/$(id -u gh-runner) \
  DOCKER_HOST=unix:///run/user/$(id -u gh-runner)/docker.sock docker system df'
```
