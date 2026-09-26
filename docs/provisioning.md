# Provisioning a Fresh Server

One-time server bring-up. The terse agent checklist is `AGENTS.md` →
Deployment Order; this is the narrated walkthrough.

### 1. Create server

Order a VPS (Ubuntu 24.04) with a public IPv4. Add your SSH public key for root access via the hosting panel.

### 2. Run setup.sh

SSH as root, then:

```bash
git clone https://github.com/jkrumm/vps /home/jkrumm/vps
bash /home/jkrumm/vps/scripts/setup.sh
```

Creates user `jkrumm`, hardens SSH, applies sysctl, sets up UFW, installs Docker + toolchain (awscli, 1Password CLI, Tailscale), creates external Docker networks, drops cron job for Postgres backups.

### 3. Tailscale

```bash
sudo tailscale up --ssh --advertise-tags=tag:vps   # complete auth in browser
tailscale ip -4                                     # note the assigned Tailscale IP (100.x.x.x)
```

Do **not** bind sshd to the Tailscale IP — see `AGENTS.md` → Quick Reference for why. Verify instead:
```bash
sudo ufw status verbose        # Default: deny (incoming); only "Anywhere on tailscale0 ALLOW IN"
# ⚠ Open a second SSH session via the Tailscale IP to verify before closing this one
```

`--ssh` enables Tailscale SSH — identity-based auth via your Tailscale account, no SSH keys required once active. The `authorized_keys` populated by `setup.sh` is only needed for this bootstrap window.

Add the server to your local `~/.ssh/config`:
```
Host vps
    HostName <tailscale-ip>
    User jkrumm
```

SSH agent is handled globally via 1Password (`IdentityAgent` in `~/.ssh/config`).

### 4. 1Password CLI

```bash
# Add to ~/.bashrc as jkrumm:
export OP_SERVICE_ACCOUNT_TOKEN="<token>"
source ~/.bashrc
op vault list   # verify access to vps + common vaults
```

### 5. Verify secrets

All secrets are pre-populated in 1Password (`vps` + `common` vaults). See `README.md` → Secrets.

### 6. Cloudflare Tunnel

Tunnel token already in 1Password (`vps/cloudflare-tunnel/TOKEN`). The `.env.tpl` references it automatically.

### 7. Firewall

The provider has no panel firewall, so UFW is the only host-level filter. UFW denies all inbound by default and only allows the Tailscale interface — that's sufficient for everything except FPP MariaDB.

**Note on Docker + UFW:** Docker publishes ports via its own iptables rules that bypass UFW entirely. Adding `ports: ["33306:3306"]` to `apps/fpp/compose.yml` makes MariaDB reachable on the public IP automatically — UFW does not block it. fail2ban operates on the `DOCKER-USER` chain (not the UFW chain) to ban auth-failure source IPs.

Verify UFW on the server: `make firewall`

### 8. Start the stack

```bash
make networking-up        # issues *.${DOMAIN} cert via DNS-01
make fpp-cert-sync        # extracts wildcard cert for MariaDB TLS
make up                   # full stack (networking → infra → monitoring → fpp)
make postgres-setup       # provision Postgres schemas + users
make fpp-mariadb-setup    # provision MariaDB fpp user + grants
```

Verify: `make ps` — all containers should be running within ~30 seconds.

Add a DNS-only A record `db.free-planning-poker.com` → VPS public IP (grey cloud, **not** proxied — Cloudflare can't proxy MySQL).

### 9. Photo gallery host directory

```bash
mkdir -p /home/jkrumm/photo-gallery-dist
```

Content (built Astro `dist/`) is rsynced from the developer laptop by the `photo-flow` CLI — see `~/SourceRoot/photo-flow`. Sync at least an `index.html` before `make photo-gallery-up` so the healthcheck passes.

### 10. Cloudflare tunnel ingress + DNS

Use the `/cloudflare` Claude Code skill to set the wildcard ingress rule and add DNS records. The skill handles all API calls via `ssh vps "op run --env-file=.env.tpl --"` — the token never leaves 1Password.

- Set wildcard ingress: `*.DOMAIN → https://traefik:443` (once after provisioning)
- Apex and other-zone hosts each need their own ingress entry (`DOMAIN`, `basalt-ui.com`, …) — the wildcard doesn't match them
- Add DNS record per app subdomain (CNAME → tunnel)

Traefik will issue a wildcard cert via DNS-01 on first request (may take 1–2 min — check `docker logs traefik | grep -i acme`).

> **Wildcard ingress scope:** Only matches requests already DNS-routed to the VPS tunnel. Other subdomains pointing to different tunnels (HomeLab, etc.) are unaffected.
