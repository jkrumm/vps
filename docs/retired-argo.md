# Retired: Argo

Argo moved off the VPS on 2026-10-30 and runs natively on the Mac mini (deployed by `make deploy` in the argo repo). `argo.jkrumm.com` keeps its name, but its DNS-only A record points at the mini's tailnet IP and the mini's Caddy terminates TLS (mac/phone/tablet clients only; the `Argo - Door` Kuma monitor replaces the old `Argo / API - HTTP` ones). Argo's OTLP spans (`service.name` `argo-api`) still reach this ClickStack, from the mini over the authed tier, so the argo-api observability dashboards and alerts stay.

What remains here:

- **Stopped containers**, kept for rollback: the `argo-api` and `argo-dashboard` containers (not removed). Their compose file and `make argo-*` targets are gone.
- **The `argo` Postgres schema and role**, untouched and still provisioned by `make postgres-setup`, pending the owner's decision to drop them. The final verified dump is at `homelab:~/argo-backups/` (`argo-schema-final-<timestamp>.dump` plus `.sums` and `.sha256`).

Rollback: flip the `argo.jkrumm.com` A record back to the VPS tailnet IP, then `docker start` the two stopped argo containers on the VPS; both Traefik routers return with them.
