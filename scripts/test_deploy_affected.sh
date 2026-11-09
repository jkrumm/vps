#!/usr/bin/env bash
# Feeds fixture paths through the awk program behind DEPLOY_AFFECTED (scripts/deploy-affected.awk).
set -u
awk_file="$(dirname "$0")/deploy-affected.awk"
fail=0

check() { # path expected-output ("" for none)
  got=$(printf '%s\n' "$1" | awk -f "$awk_file")
  if [ "$got" != "$2" ]; then echo "✗ $1 → '$got' (want '$2')" >&2; fail=1; fi
}

check apps/fpp/compose.yml fpp
check apps/fpp/fail2ban/x fail2ban
check traefik/traefik.yml traefik-conf
check traefik/dynamic/x ""
check clickstack/x clickstack-conf
check observability/x hyperdx
check cron/pg-backup cron
check cron/x.env.tpl ""
check compose.networking.yml networking
check compose.infra.yml infra
check compose.monitoring.yml monitoring
check README.md ""

[ "$fail" -eq 0 ] && echo "OK: deploy mapping"
exit "$fail"
