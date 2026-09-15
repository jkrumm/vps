---
name: audit
description: Full health audit of the VPS — system resources, containers, Cloudflare tunnel, Tailscale, errors, updates, backup status, and manual upgrade checks
---

# VPS Audit

Run a full health audit of the VPS across 8 sequential phases, then offer to fix each issue found.

**Execution:** Always via `ssh vps "..."` — never local commands

---

## Instructions

Run all 8 phases first to gather data. Produce the structured report after all phases complete. Then, for each WARN/CRITICAL finding: auto-fix reversible remediations (container restart, dangling-image prune, log rotation, re-pull, service reload) and report what was done; confirm first only for irreversible or outward-facing changes (volume deletion, data-destroying prune, cert/DNS/tunnel changes, anything touching backups or a public endpoint).

### Phase 1: System Resources

```bash
ssh vps "uptime && echo '---' && free -h && echo '---' && df -h --output=source,target,pcent | grep -v 'tmpfs\|efivarfs\|udev'"
```

**Thresholds:**
- WARN: disk >80% on any mount, available memory <1GB, load average >4
- CRITICAL: disk >95% on any mount, load average >8

### Phase 2: Container Health

**All running containers:**
```bash
ssh vps "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'"
```

**Stopped, restarting, or dead (Docker built-in status filters — avoids tab/space grep mismatch):**
```bash
ssh vps "docker ps -a --filter 'status=exited' --filter 'status=restarting' --filter 'status=dead' --format '{{.Names}}\t{{.Status}}'"
```

**Restart counts (non-zero only):**
```bash
ssh vps "docker inspect \$(docker ps -q) --format '{{.Name}} restarts={{.RestartCount}}' 2>/dev/null | grep -v 'restarts=0'"
```

**Docker disk usage:**
```bash
ssh vps "docker system df"
```

**Expected running containers:**
- Networking: `cloudflared`, `traefik`, `socket-proxy`, `socket-proxy-rollhook`, `rollhook`
- Infra: `postgres`, `redis`
- FPP (`apps/fpp/compose.yml`): `mariadb`, `fpp-server`, `fpp-analytics`, `fpp-analytics-updater`
- Monitoring: `clickstack`, `beszel-agent`, `dozzle`, `watchtower`, `socket-proxy-watchtower`, `socket-proxy-monitoring`, `umami`
- Apps (RollHook-managed, auto-suffixed names like `argo-argo-api-146` — match by label, not name): `argo-api`, `argo-dashboard`, `audio-gateway`, `basalt-ui-marketing`, `bun-email-api`, `image-gen-gateway`, `imgproxy`, `weatherorb-edge`, `photo-gallery`, `research-gateway`, `research-gateway-lightpanda`, `rollhook-marketing`

```bash
ssh vps "docker ps --format '{{.Label \"com.docker.compose.service\"}}' | sort"
```

**Thresholds:**
- CRITICAL: any expected container not running
- WARN: restart count >3 on any container
- WARN: reclaimable Docker images >500MB (offer `docker image prune -f`)

### Phase 3: Cloudflare Tunnel Health

```bash
ssh vps "docker logs cloudflared --tail=30 2>&1 | grep -v 'receive buffer'"
```

**Known benign (suppress):** `failed to sufficiently increase receive buffer size` — harmless quic-go UDP startup warning

**Thresholds:**
- CRITICAL: `failed`, `connection refused`, or `ERR` repeated in last 30 lines
- WARN: `reconnecting` events in last 30 lines

### Phase 4: Tailscale Connectivity

```bash
ssh vps "tailscale status"
```

**Thresholds:**
- CRITICAL: Tailscale not running, offline, or no peers visible
- WARN: `# Health check:` section appears with warnings in the output (e.g. DNS configuration failures)
- Known benign: `/etc/resolv.conf` permission warning — harmless on Ubuntu 24.04 with systemd-resolved managing DNS

**Firewall proof — the SSH invariant is UFW, not sshd's bind address:**
```bash
ssh vps "sudo ufw status verbose && echo '---' && sudo ss -tlnp | grep -E ':22 '"
```

**Thresholds:**
- CRITICAL: `Status: inactive`, `Default:` not `deny (incoming)`, or any `ALLOW IN` rule that is not scoped `on tailscale0`
- Known benign (suppress): sshd on `0.0.0.0:22` / `[::]:22` — it listens on all interfaces by design; a `ListenAddress` on the Tailscale IP fails at boot when `tailscale0` is late (lock-out). Never propose rebinding it.

### Phase 5: Recent Errors (Log Scan)

```bash
ssh vps "for svc in traefik cloudflared clickstack mariadb; do echo \"=== \$svc ===\"; docker logs \$svc --tail=20 2>&1 | grep -iE 'error|fatal|panic|crash|exception' | grep -v 'context canceled' | tail -5; done"
```

```bash
ssh vps "journalctl -p err -n 30 --no-pager 2>/dev/null | grep -v 'systemd-networkd-wait-online'"
```

```bash
ssh vps "journalctl -p warning -n 100 --no-pager 2>/dev/null | grep -iE 'sudo|pam_unix|authentication failure|invalid user' | tail -10"
```

**Thresholds:**
- CRITICAL: panic / fatal lines in any service
- WARN: repeated error patterns (3+ times in 20 lines)
- WARN: sudo authentication failures or PAM errors in journalctl
- Known benign (suppress): `"error":"reading: context canceled"` in Dozzle/SSE endpoints — normal browser-disconnect events; `systemd-networkd-wait-online` timeouts — harmless in Docker environments; `pam_unix(sudo:auth): auth could not identify password for [jkrumm]` from VPS sessions where `echo '$ROOT_PW' | sudo -S` was attempted — VPS has NOPASSWD sudo, so this pattern is expected from non-interactive SSH sessions

### Phase 6: Backup Status

Two daily backups, separate S3 prefixes:

```bash
ssh vps "cd ~/vps && op run --env-file=.env.tpl -- bash -c '
  echo \"--- postgres (cron 03:00):\"
  aws s3 ls \$AWS_S3_BUCKET/backups/vps/postgres/ --endpoint-url \$AWS_S3_ENDPOINT | sort | tail -2
  echo \"--- mariadb (cron 03:30):\"
  aws s3 ls \$AWS_S3_BUCKET/backups/vps/mariadb/ --endpoint-url \$AWS_S3_ENDPOINT | sort | tail -2
'"
```

**Thresholds (apply to each prefix independently):**
- CRITICAL: no backup file from the last 48 hours
- WARN: no backup file from the last 25 hours (missed last daily run)

If a backup looks stale, also check cron logs:

```bash
ssh vps "grep -E 'pg-backup|fpp-mariadb-backup|fpp-cert-sync' /var/log/syslog 2>/dev/null | tail -10 || journalctl -u cron -n 20 --no-pager"
```

### Phase 7: Pending Updates

```bash
ssh vps "docker logs watchtower --tail=10 2>&1 | grep -iE 'scheduling|updated|new version|error' | tail -5 || echo '(no recent watchtower activity)'"
```

```bash
ssh vps "apt list --upgradable 2>/dev/null | grep -v '^Listing'"
```

**Thresholds:**
- WARN: any apt upgradable packages (especially linux-image, docker-ce, security patches)
- INFO: Watchtower auto-updated containers (expected behavior)
- INFO: "Scheduling first run" line with next run time — normal after a restart

### Phase 8: Manual Upgrade Check

Postgres, Valkey, and MariaDB are excluded from Watchtower. Check their current versions vs latest available:

```bash
ssh vps "docker inspect postgres --format '{{.Config.Image}}' && docker inspect redis --format '{{.Config.Image}}' && docker inspect mariadb --format '{{.Config.Image}}'"
```

Then use WebSearch to check:
- Latest stable `postgres` major version on hub.docker.com/\_/postgres
- Latest stable `valkey/valkey` major version on hub.docker.com/r/valkey/valkey
- Latest stable `mariadb` LTS version on hub.docker.com/\_/mariadb
- Any active CVEs for the running major versions

Compare against what is actually running, not just the tag:

```bash
ssh vps "docker exec postgres postgres --version; docker exec redis valkey-server --version | cut -d, -f1; docker exec mariadb mariadbd --version"
```

**Thresholds:**
- WARN: a newer major version has been stable for 3+ months
- WARN: a patch release inside the pinned major is available. Watchtower does NOT
  cover these — the containers opt out, and a restart reuses the on-disk image, so
  they drift until upgraded by hand.

Remediation: `make backup && make infra-upgrade`, `make fpp-backup && make
fpp-mariadb-upgrade`, then `make db-counts` against the pre-upgrade output.

### Phase 9: FPP MariaDB Exception (TCP 33306 public)

Single point of inbound exposure on the VPS — verify the defenses are still in place.

```bash
ssh vps "
  echo '--- fail2ban mariadb jail:'
  sudo fail2ban-client status mariadb 2>&1 | head -10
  echo
  echo '--- TLS still required (must reject non-TLS):'
  docker run --rm --network host -e MYSQL_PWD=invalid mariadb:11.4 mariadb -h 127.0.0.1 -P 33306 -u fpp --skip-ssl --connect-timeout=3 -e 'SELECT 1;' 2>&1 | head -3
  echo
  echo '--- TLS cert age (renewed every ~60d by Traefik, synced every 6h by cert-sync.sh):'
  openssl x509 -in /home/jkrumm/vps/apps/fpp/certs/cert.pem -noout -dates 2>&1
"
```

External reachability + TLS cert from a fresh-eyes perspective:

```bash
echo | openssl s_client -connect db.free-planning-poker.com:33306 -starttls mysql -servername db.free-planning-poker.com 2>&1 | grep -E 'subject=|issuer=|Verification'
```

**Thresholds:**
- CRITICAL: fail2ban jail not active, OR non-TLS connection succeeds (would mean `--require-secure-transport=ON` got dropped), OR cert expired/expiring within 7 days, OR external openssl probe fails to verify
- WARN: cert expiring within 21 days (cert-sync should have picked up renewal — check Traefik ACME logs), OR fail2ban ban count >50 in last 24h (suggests targeted attack — consider tightening jail or restricting source IPs)
- INFO: fail2ban currently-banned count — sporadic bans from random scanners are normal

---

## Report Format

```
# VPS Audit — <timestamp>

## Summary
🟢 X healthy  🟡 Y warnings  🔴 Z critical

## [1/9] System Resources      🟢/🟡/🔴
<disk %, memory available, load — numbers only>

## [2/9] Container Health      🟢/🟡/🔴
<list non-running or high-restart containers; "all running" if clean>
<Docker disk usage summary if reclaimable >500MB>

## [3/9] Cloudflare Tunnel     🟢/🟡/🔴
<connection status, any reconnect events>

## [4/9] Tailscale             🟢/🟡/🔴
<online status, peer count, any health warnings>

## [5/9] Recent Errors         🟢/🟡/🔴
<per-service summary; "no errors" if clean>

## [6/9] Backup Status         🟢/🟡/🔴
postgres: <last backup timestamp>
mariadb:  <last backup timestamp>

## [7/9] Pending Updates       🟢/🟡/🔴
<watchtower activity + apt package count>

## [8/9] Manual Upgrades       🟢/🟡/🔴
postgres: running X, latest Y — <up to date / upgrade available>
valkey:   running X, latest Y — <up to date / upgrade available>
mariadb:  running X, latest Y — <up to date / upgrade available>

## [9/9] FPP MariaDB Exception 🟢/🟡/🔴
fail2ban jail: <active / inactive>, banned now: N, total banned: M
TLS enforced: <yes/no>, cert valid until: <date>
External TLS verify (db.free-planning-poker.com): <OK / FAILED>

## Recommendations
- [CRITICAL] <finding> → <proposed fix>
- [WARN] <finding> → <proposed fix>
```

---

## Repair Actions

For each CRITICAL/WARN finding: auto-fix reversible remediations (container restart, dangling-image prune, log rotation, re-pull, service reload) and report what was done; confirm first only for irreversible or outward-facing changes (volume deletion, data-destroying prune, cert/DNS/tunnel changes, anything touching backups or a public endpoint).

| Finding | Proposed Fix |
|-|-|
| Container not running (networking/rollhook) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.networking.yml up -d <name>"` |
| Container not running (infra) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.infra.yml up -d <name>"` |
| Container not running (monitoring) | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.monitoring.yml up -d <name>"` |
| Container restart count >3 | Show `docker logs <name> --tail=20`, offer restart via appropriate stack |
| Cloudflared errors | `ssh vps "cd ~/vps && op run --env-file=.env.tpl -- docker compose -f compose.networking.yml up -d --force-recreate cloudflared"` |
| Tailscale down | `ssh vps "sudo systemctl restart tailscaled"` |
| Docker image bloat | `ssh vps "docker image prune -f"` (dangling only — safe) |
| Disk >95% | Report + offer `docker image prune -f` — confirm before running; do NOT auto-run `system prune` |
| Apt security updates available | `ssh vps "sudo apt upgrade -y --only-upgrade"` (VPS has NOPASSWD sudo) |
| Postgres backup >48h old | `ssh vps "cd ~/vps && ENV=prod make backup"` |
| MariaDB backup >48h old | `ssh vps "cd ~/vps && ENV=prod make fpp-backup"` |
| Postgres upgrade available | `make backup && make infra-upgrade` (major bump: see "Upgrade Procedures" in CLAUDE.md) |
| Valkey upgrade available | `make backup && make infra-upgrade` — same target as Postgres (data in volume) |
| MariaDB upgrade available (patch/minor) | `ssh vps "cd ~/vps && make fpp-backup && make fpp-mariadb-upgrade"` — never `make fpp-up`, which would also recreate the RollHook-managed fpp-server/fpp-analytics off `:latest` |
| fail2ban mariadb jail not active | `ssh vps "sudo systemctl restart fail2ban && sudo fail2ban-client status mariadb"` |
| MariaDB cert <7d from expiry | `ssh vps "cd ~/vps && make fpp-cert-sync"` (forces re-extraction from acme.json + FLUSH SSL) |
| MariaDB non-TLS connection succeeded (CRITICAL) | Check `--require-secure-transport=ON` in `apps/fpp/compose.yml` is intact, then `ssh vps "cd ~/vps && make fpp-up"` to apply |

**After each repair:** Re-run the relevant phase command to verify the fix worked before moving to the next issue.

**Never:** Reboot the server, run `docker compose down` across all stacks, delete volumes, or take any action affecting all services simultaneously without explicit discussion.
