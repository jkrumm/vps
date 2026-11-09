# Maps changed paths (stdin, one per line) to the `make deploy` targets they affect.
# Used by DEPLOY_AFFECTED in the Makefile and by scripts/test_deploy_affected.sh.
BEGIN { FS = "/" }
/^apps\/fpp\/fail2ban\// { print "fail2ban"; next }
/^apps\// { print $2; next }
/^compose\.networking\.yml$/ { print "networking"; next }
/^traefik\/traefik\.yml$/ { print "traefik-conf"; next }
/^compose\.infra\.yml$/ { print "infra"; next }
/^compose\.monitoring\.yml$/ { print "monitoring"; next }
/^clickstack\// { print "clickstack-conf"; next }
/^observability\// { print "hyperdx"; next }
/^cron\// && !/\.env\.tpl$/ { print "cron"; next }
