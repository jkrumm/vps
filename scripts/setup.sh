#!/usr/bin/env bash
# =============================================================================
# VPS — Initial Server Provisioning & Hardening
# Run as root on a fresh Ubuntu 24.04 server.
# Idempotent: safe to re-run.
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

DEPLOY_USER="jkrumm"
GITHUB_USERNAME="jkrumm"
REPO_DIR="/home/${DEPLOY_USER}/vps"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
skip() { echo "[$(date +%H:%M:%S)] SKIP: $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*"; }

# Must run as root
[[ $EUID -ne 0 ]] && echo "Run as root." && exit 1

# =============================================================================
# 1. Hostname + timezone + system update
# =============================================================================
log "Setting hostname to vps..."
hostnamectl set-hostname vps

# cloud-init re-renders /etc/hosts from its template on EVERY boot: the provider's
# user-data carries `manage_etc_hosts: true` plus its own hostname, and user-data
# outranks anything dropped into /etc/cloud/cloud.cfg.d — so it cannot be switched
# off from here. Fix the live file for now AND the template it is rendered from,
# or the first reboot brings back "sudo: unable to resolve host vps".
if ! grep -q '^127.0.1.1 vps' /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1 vps/" /etc/hosts
  grep -q '^127.0.1.1 vps' /etc/hosts || echo '127.0.1.1 vps' >> /etc/hosts
fi
HOSTS_TMPL=/etc/cloud/templates/hosts.debian.tmpl
if [[ -f "${HOSTS_TMPL}" ]] && ! grep -q '^127.0.1.1 vps' "${HOSTS_TMPL}"; then
  log "Adding 127.0.1.1 vps to the cloud-init hosts template..."
  sed -i '/^127\.0\.1\.1 {{fqdn}} {{hostname}}$/a 127.0.1.1 vps' "${HOSTS_TMPL}"
fi

log "Setting timezone to UTC..."
timedatectl set-timezone UTC

# Configure needrestart to auto-restart services without interactive prompts
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\s*\$nrconf{restart}.*$/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
else
  mkdir -p /etc/needrestart
  echo "\$nrconf{restart} = 'a';" > /etc/needrestart/needrestart.conf
fi

log "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# =============================================================================
# 2. Create deploy user
# =============================================================================
if id "${DEPLOY_USER}" &>/dev/null; then
  skip "User ${DEPLOY_USER} already exists"
else
  log "Creating user ${DEPLOY_USER}..."
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
  usermod -aG sudo "${DEPLOY_USER}"
fi

# Passwordless sudo — deploy user has no password; NOPASSWD required for operational commands
if [[ ! -f "/etc/sudoers.d/${DEPLOY_USER}" ]]; then
  log "Configuring passwordless sudo for ${DEPLOY_USER}..."
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
  chmod 440 "/etc/sudoers.d/${DEPLOY_USER}"
else
  skip "Sudoers entry for ${DEPLOY_USER} already exists"
fi

# Add SSH keys — try GitHub first, fall back to root's authorized_keys
log "Fetching SSH keys..."
mkdir -p "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
if curl -fsSL --max-time 10 "https://github.com/${GITHUB_USERNAME}.keys" \
    >> "/home/${DEPLOY_USER}/.ssh/authorized_keys" 2>/dev/null; then
  log "SSH keys fetched from GitHub"
elif [[ -s /root/.ssh/authorized_keys ]]; then
  warn "GitHub unreachable (IPv6-only host?) — copying root authorized_keys as fallback"
  cat /root/.ssh/authorized_keys >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
else
  warn "Could not fetch SSH keys from GitHub and no root keys found. Add keys manually to /home/${DEPLOY_USER}/.ssh/authorized_keys"
fi
sort -u "/home/${DEPLOY_USER}/.ssh/authorized_keys" -o "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

# =============================================================================
# 3. SSH hardening
# sshd keeps listening on ALL interfaces. Tailscale-only reachability is UFW's
# job (section 5: default deny in, allow tailscale0) — never a ListenAddress on
# the Tailscale IP: sshd then fails to start whenever tailscale0 comes up after
# it at boot, which is a lock-out with no console. Proof: `make firewall`.
# =============================================================================
log "Hardening SSH..."
cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Hardened SSH config — key authentication only. Reachability is enforced by
# UFW (only tailscale0 allowed in), not by binding sshd to the Tailscale IP.
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers jkrumm
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
# No ListenAddress on purpose — see scripts/setup.sh section 3.
EOF
log "SSH config written. Apply with: systemctl restart sshd (keep this session open, verify a second one over Tailscale first)"

# =============================================================================
# 4. Kernel hardening (sysctl)
# =============================================================================
log "Applying sysctl hardening..."
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Required for Valkey / Redis
vm.overcommit_memory = 1

# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Kernel hardening
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
EOF
sysctl -p /etc/sysctl.d/99-hardening.conf

# =============================================================================
# 5. UFW firewall
# =============================================================================
log "Configuring UFW..."
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# No inbound 80/443 — Traefik has no host ports; all public traffic enters via
# Cloudflare Tunnel (outbound-only).
# Tailscale interface: allow everything (SSH, monitoring agents, OTel)
ufw allow in on tailscale0 comment "Tailscale"
ufw --force enable
log "UFW enabled. SSH reachable via Tailscale only (deny in, allow tailscale0) — sshd itself stays on all interfaces."

# =============================================================================
# 6. Unattended upgrades (OS security patches only)
# =============================================================================
log "Configuring unattended-upgrades..."
apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};

// Never auto-upgrade Docker or container tooling — Watchtower handles container updates.
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
    "docker-compose-plugin";
    "docker-buildx-plugin";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades

# =============================================================================
# 7. Install Docker
# =============================================================================
if command -v docker &>/dev/null; then
  skip "Docker already installed ($(docker --version))"
else
  log "Installing Docker..."
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  # compose plugin installs to /usr/libexec/docker/cli-plugins/docker-compose on Ubuntu 24.04
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker "${DEPLOY_USER}"
fi

# Docker daemon config — global log limits as safety net, live-restore for no-downtime daemon restart
if [[ ! -f /etc/docker/daemon.json ]]; then
  log "Configuring Docker daemon..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
  if command -v docker &>/dev/null; then
    systemctl reload docker || systemctl restart docker
  fi
else
  skip "Docker daemon.json already exists"
fi

# =============================================================================
# 8. Install tooling
# =============================================================================

# make — required for Makefile targets
# jq — used by apps/fpp/scripts/cert-sync.sh to parse traefik/acme.json
# fail2ban — bans repeated MariaDB auth failures (apps/fpp/fail2ban/)
apt-get install -y -qq make jq fail2ban

# AWS CLI v2 (for S3 backup uploads) — official installer from awscli.amazonaws.com
if command -v aws &>/dev/null; then
  skip "AWS CLI already installed ($(aws --version 2>&1 | cut -d' ' -f1))"
else
  log "Installing AWS CLI v2..."
  apt-get install -y -qq unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# Tailscale
if command -v tailscale &>/dev/null; then
  skip "Tailscale already installed"
else
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# 1Password CLI
if command -v op &>/dev/null; then
  skip "1Password CLI already installed ($(op --version 2>&1))"
else
  log "Installing 1Password CLI..."
  curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
    tee /etc/apt/sources.list.d/1password.list
  apt-get update -qq && apt-get install -y -qq 1password-cli
fi

# =============================================================================
# 9. Private registry login (rollhook.jkrumm.com — RollHook's built-in Zot)
# Stores credentials in ~/.docker/config.json — Docker Compose picks them up
# automatically when pulling images from rollhook.jkrumm.com.
# The registry password IS ROLLHOOK_SECRET: RollHook derives Zot's credential
# from it directly (registry.ZotPassword() is the identity function) and writes
# the bcrypt hash to .htpasswd on every start. The username is the hardcoded
# internal ZotUser, "rollhook". There is no separate registry secret.
# Requires: OP_SERVICE_ACCOUNT_TOKEN set with access to the vps vault.
# =============================================================================
if op read "op://vps/rollhook/SECRET" &>/dev/null; then
  log "Logging into private registry (rollhook.jkrumm.com)..."
  su - "${DEPLOY_USER}" -c \
    "op read 'op://vps/rollhook/SECRET' \
     | docker login rollhook.jkrumm.com -u rollhook --password-stdin"
else
  warn "op://vps/rollhook/SECRET not accessible — skipping private registry login."
  warn "Ensure OP_SERVICE_ACCOUNT_TOKEN is set and has access to the vps vault."
fi

# =============================================================================
# 10. Create Docker external networks
# =============================================================================
log "Creating Docker networks..."
for network in proxy postgres-net valkey-net monitoring-net mariadb-net; do
  if docker network inspect "${network}" &>/dev/null; then
    skip "Network ${network} already exists"
  else
    docker network create "${network}"
    log "Created network: ${network}"
  fi
done

# =============================================================================
# 11. Set up repo directory + acme.json
# =============================================================================
# Ensure repo dir exists and is owned by deploy user
mkdir -p "${REPO_DIR}/traefik"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${REPO_DIR}"

ACME_JSON="${REPO_DIR}/traefik/acme.json"
if [[ ! -f "${ACME_JSON}" ]]; then
  log "Creating traefik/acme.json..."
  touch "${ACME_JSON}"
fi
chmod 600 "${ACME_JSON}"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${ACME_JSON}"

# Holds cron env files seeded from 1Password by scripts/seed-cron-env.sh.
# Deliberately outside the repo tree so plaintext secret values can never
# reach the public git repo.
mkdir -p /etc/vps
chown "root:${DEPLOY_USER}" /etc/vps
chmod 750 /etc/vps

# =============================================================================
# 12. Install cron jobs (Postgres backup, Postgres liveness, MariaDB backup,
# MariaDB cert sync, weekly Docker image/build-cache prune, hourly weatherorb accounts dump)
# =============================================================================
log "Installing cron jobs..."
for cronfile in pg-backup pg-health fpp-mariadb-backup fpp-cert-sync docker-prune weatherorb-accounts-dump; do
  cp "${REPO_DIR}/cron/${cronfile}" "/etc/cron.d/${cronfile}"
  chmod 644 "/etc/cron.d/${cronfile}"
  chown root:root "/etc/cron.d/${cronfile}"
done

# =============================================================================
# 13. fail2ban for MariaDB (auth failures via journald → DOCKER-USER chain)
# Only effective once apps/fpp/compose.yml is up (mariadb container logs to
# journald with CONTAINER_TAG=mariadb).
# =============================================================================
log "Installing fail2ban configs for MariaDB..."
cp "${REPO_DIR}/apps/fpp/fail2ban/filter-mariadb-auth.conf" /etc/fail2ban/filter.d/mariadb-auth.conf
cp "${REPO_DIR}/apps/fpp/fail2ban/jail-mariadb.conf"        /etc/fail2ban/jail.d/mariadb.conf
chmod 644 /etc/fail2ban/filter.d/mariadb-auth.conf /etc/fail2ban/jail.d/mariadb.conf
systemctl enable fail2ban
systemctl restart fail2ban

# =============================================================================
# 14. Bootstrap apps/fpp/certs/ — owned by deploy user so cert-sync.sh can write
# =============================================================================
mkdir -p "${REPO_DIR}/apps/fpp/certs"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${REPO_DIR}/apps/fpp"

# =============================================================================
# Done
# =============================================================================
log ""
log "============================================================"
log " Setup complete! Next steps:"
log "============================================================"
log " 1. Connect Tailscale:    tailscale up  (already done if you see a TS IP)"
log " 2. Apply SSH hardening:  systemctl restart sshd   (sshd stays on all interfaces;"
log "                          UFW admits only tailscale0 — verify: ufw status verbose)"
log " 3. Set 1Password SA:     Add OP_SERVICE_ACCOUNT_TOKEN to /home/${DEPLOY_USER}/.bashrc"
log "                          source ~/.bashrc && op vault list (verify access)"
log " 4. Cloudflare Tunnel:    Token already in 1Password (vps/cloudflare-tunnel)"
log " 5. UFW status:            ufw status verbose"
log "                          Note: Docker bypasses UFW for published ports — TCP 33306 (MariaDB)"
log "                          becomes reachable on the public IP as soon as 'make fpp-up' runs."
log "                          fail2ban handles auth-failure bans via the DOCKER-USER chain."
log " 6. Start networking:     make networking-up   (issues *.\${DOMAIN} cert via DNS-01)"
log " 7. Sync TLS cert:        make fpp-cert-sync   (extracts wildcard cert for MariaDB)"
log " 8. Start all stacks:     make up"
log "                          (networking → infra → monitoring → fpp in order)"
log " 9. Provision DBs:        make postgres-setup && make fpp-mariadb-setup"
log "10. DNS A record:         db.free-planning-poker.com → VPS public IP (DNS-only / grey cloud)"
log "11. Seed cron env:        make cron-env-seed   (pg-health cron stays broken until this runs)"
log "============================================================"
