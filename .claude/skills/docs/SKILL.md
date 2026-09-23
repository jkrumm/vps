---
name: docs
description: Documentation maintenance — sync compose files against README/AGENTS.md service tables, verify Secrets section coverage, check Makefile targets
---

# VPS Documentation Maintenance

**When to use:**
- After adding or removing services in any compose file
- After creating or modifying scripts
- After changing Traefik config, middleware, or OTel config
- Before committing infrastructure changes

**What this skill does:**
1. Diffs compose files against README.md and AGENTS.md service tables
2. Verifies README.md Secrets section covers every `${VAR}` referenced in compose files and scripts
3. Checks Makefile targets match what AGENTS.md Quick Reference documents
4. Flags internal socket-proxy networks missing from AGENTS.md Networks section
5. Detects services with `com.centurylinklabs.watchtower.enable=false` not documented in upgrade procedures
6. Scans for hardcoded real hostnames/domains/IPs in tracked files
7. Updates stale documentation

**What this skill does NOT do:**
- Execute infrastructure changes
- Commit changes (use `/commit` after review)
- Modify scripts, configs, or compose files

---

## Audit Checklist

### Service Inventory
- [ ] All services in `compose.networking.yml` appear in README stack table
- [ ] All services in `compose.infra.yml` appear in README stack table
- [ ] All services in `compose.monitoring.yml` appear in README stack table
- [ ] No removed services still referenced in README or AGENTS.md

### Secret Coverage
- [ ] Every `${VAR}` in compose files appears in README.md Secrets section
- [ ] Every `${VAR}` in `scripts/` appears in README.md Secrets section
- [ ] No variables documented in README.md Secrets that are no longer used in any compose file or script

Run to get full variable list:
```bash
grep -h '\${' compose*.yml scripts/*.sh | grep -oE '\$\{[A-Z_]+\}' | sort -u
```

### Network Documentation
- [ ] All external networks in compose files match what `setup.sh` creates
- [ ] All internal socket-proxy networks documented in AGENTS.md Networks section
- [ ] New proxy consumers (services using socket-proxy via `DOCKER_HOST`) noted in service notes

### Middleware Consistency
- [ ] Middleware names in AGENTS.md App Integration Pattern match `traefik/dynamic/middlewares.yml`
- [ ] Same middleware names in README.md Adding an App section

### Makefile ↔ AGENTS.md Sync
- [ ] Every `make <target>` in AGENTS.md Quick Reference exists in Makefile
- [ ] No Makefile targets that should be documented but aren't

### Manually-Managed Containers
Services with `com.centurylinklabs.watchtower.enable=false` require manual upgrades. Currently:
- `postgres` — documented in AGENTS.md and README Upgrade Procedures
- `redis` (valkey) — documented in AGENTS.md and README Upgrade Procedures

If a new excluded container appears, flag it and prompt to add upgrade procedure.

### Security — No Sensitive Data in Repo
Scan for real values that should be placeholders:
- [ ] No real domain names (e.g. `example.com` replacing `<DOMAIN>`) in README or AGENTS.md
- [ ] No real IPs (public or Tailscale) in any tracked file
- [ ] No real email addresses
- [ ] No real hostnames beyond placeholder format (`<registry-domain>`, `<tailscale-ip>`, etc.)

---

## Validation Checklist

After updates:
- [ ] README stack table image names match compose files
- [ ] README.md Secrets section covers all vars
- [ ] No stale service names remain anywhere
- [ ] Middleware names consistent across AGENTS.md, README.md, and compose examples
- [ ] AGENTS.md Quick Reference matches Makefile

---

## Output Format

```
## Documentation Audit

### Changes Found
- [file]: [specific stale or missing content]

### Changes Made
- README.md: [what was updated]
- AGENTS.md: [what was updated]

### No Action Needed
- [item]: already accurate

### Flagged for Review
- New Watchtower-excluded container: [name] — add upgrade procedure?
- Possible sensitive data: [file:line] — [value]

Next: /commit
```
