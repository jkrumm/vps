# Deployment order (fresh server)

```bash
git clone https://github.com/jkrumm/vps /home/jkrumm/vps
bash /home/jkrumm/vps/scripts/setup.sh
```

1. `tailscale up` → complete browser auth → note Tailscale IP
2. Create `/etc/vps/op.env` (one line `OP_SERVICE_ACCOUNT_TOKEN=<token>`, `chown jkrumm:jkrumm`, `chmod 600`) — cron jobs source it, `setup.sh` prints the commands and keeps its mode. Also add the token to `~/.bashrc` for interactive use → `source ~/.bashrc && op vault list`. Re-running `setup.sh` leaves ufw alone (`UFW_RESET=1` forces a reset)
3. `ufw status verbose` → default deny incoming, only `tailscale0` allowed in (sshd stays on all interfaces — never rebind it)
4. `tailscale set --ssh --accept-risk=lose-ssh` → enables SSH badge in Tailscale admin
5. Tunnel token already in 1Password (`vps/cloudflare-tunnel/TOKEN`)
6. `cd ~/vps && make networking-up` → wait for Traefik to issue `*.${DOMAIN}` cert (1–2 min, check `docker logs traefik | grep -i acme`)
7. `make fpp-cert-sync` → extracts wildcard cert into `apps/fpp/certs/`
8. `make up` → starts networking, infra, monitoring, fpp, email-gateway, photo-gallery, imgproxy (idempotent — re-runs networking-up too). weatherorb, shutterflow, basalt-ui-marketing and jkrumm-com are not in it: `make weatherorb-up`; bootstrap each of the others (`<app>-env` / `<app>-bootstrap-image`, see its compose header), then `make <app>-up`
9. `make postgres-setup` → provision Postgres schemas/users (after a DR restore, run it again: roles/globals are not in the dump)
10. `make fpp-mariadb-setup` → provision MariaDB fpp user + grants
11. `make cron-env-seed` → materialize /etc/vps/*.env for cron jobs from 1Password (`make cron-install` re-installs `cron/*` into `/etc/cron.d` later)
12. Add DNS-only A record `db.free-planning-poker.com` → VPS public IP (grey cloud — not proxied)
13. `reboot` → verify kernel updated, all containers restart automatically

**Note:** the provider has no panel firewall. UFW (deny inbound, allow `tailscale0`) is sufficient for everything except MariaDB. **Docker bypasses UFW for published ports**, so TCP 33306 is publicly reachable as soon as `make fpp-up` runs — no firewall change needed (rationale + mitigations: `apps/fpp/AGENTS.md`).
