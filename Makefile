-include .env
export

ENV ?= dev

# Compose derives volume names as <project>_<name>, project defaulting to this dir.
MARIADB_DEV_VOLUME ?= $(notdir $(CURDIR))_mariadb-dev-data

# Secret injection — TWO injectors, deliberately.
#
# The runner: prefer the `secrets-run` shim wherever it exists (the two Macs), where
# it is a drop-in `op` replacement — on the MacBook it passes through to live
# biometric `op`, on the headless mini it resolves from the age-encrypted offline
# cache. The VPS has no secrets-run and a working `op`, so prod keeps the direct
# call and nothing about prod changes.
#
# A bare `op` is not usable on the mini: with no human to answer its biometric
# prompt it does not fail, it BLOCKS. One `make up` sat wedged for 19 hours
# (2026-08-01 15:16 → 2026-08-02). secrets-run fails closed in a second instead.
#
# The template: prod targets get the full .env.tpl; require-dev targets get
# .env.dev.tpl, which is the ~12 refs the local stack actually needs rather than
# all ~40. That split is what makes the dev stack runnable on the mini at all —
# see the header of .env.dev.tpl for the reasoning behind each line, and
# dotfiles-private/headless.refs for which of them the mini may hold offline.
SECRET_RUNNER = $(shell command -v secrets-run >/dev/null 2>&1 \
	&& echo 'secrets-run run' \
	|| echo 'op run --account tkrumm')

OP_RUN     = $(SECRET_RUNNER) --env-file=.env.tpl --
OP_RUN_DEV = $(SECRET_RUNNER) --env-file=.env.dev.tpl --

# For the handful of targets documented as "works in both envs" (postgres-setup,
# shell-postgres, db-counts, fpp-shell). They must follow ENV rather than pick a
# side: the local containers are created with the DEV-ONLY superuser passwords
# from .env.dev.tpl, so handing them prod's values simply fails to authenticate.
ifeq ($(ENV),prod)
OP_RUN_ENV = $(OP_RUN)
else
OP_RUN_ENV = $(OP_RUN_DEV)
endif

.DEFAULT_GOAL := help

.PHONY: help require-prod require-dev weatherorb-up weatherorb-down weatherorb-env weatherorb-bootstrap-image weatherorb-redeploy \
        up down networking-up networking-down infra-up infra-down infra-upgrade monitoring-up monitoring-down \
        rollhook-update \
        fpp-up fpp-down fpp-mariadb-setup fpp-cert-sync fpp-bootstrap-images fpp-env \
        fpp-backup fpp-mariadb-upgrade fpp-shell fpp-restore-local fpp-sync-from-prod \
        bun-email-api-up bun-email-api-down bun-email-api-env bun-email-api-bootstrap-image \
        argo-up argo-down argo-env argo-bootstrap-image \
        research-gateway-up research-gateway-down research-gateway-env research-gateway-bootstrap-image \
        image-gen-gateway-up image-gen-gateway-down image-gen-gateway-env image-gen-gateway-redeploy image-gen-gateway-bootstrap-image \
        photo-gallery-up photo-gallery-down \
        imgproxy-up imgproxy-down \
        edge-cache-status edge-cache-apply \
        basalt-ui-marketing-up basalt-ui-marketing-down basalt-ui-marketing-bootstrap-image \
        jkrumm-com-up jkrumm-com-down jkrumm-com-bootstrap-image \
        audio-gateway-up audio-gateway-down audio-gateway-env audio-gateway-bootstrap-image \
        shutterflow-up shutterflow-down shutterflow-env shutterflow-bootstrap-image \
        postgres-setup dev-db-passwords dev-mariadb-reset cron-env-seed ps backup restore-local sync-from-prod pg-sync-schema firewall shell-postgres db-counts prune prune-cron-install \
        hyperdx-agent-setup hyperdx-dev-bootstrap hyperdx-webhook-setup hyperdx-export hyperdx-apply clickstack-up clickstack-down clickstack-restart clickstack-upgrade

## Show this help (default). Adapts to ENV — dims targets not available in the current env.
help:
	@printf "vps — ENV=$(ENV)\n\n"
	@awk -v env="$(ENV)" 'BEGIN { FS = ":"; primary_n = 0; other_n = 0 } \
		/^## / { if (doc == "") doc = substr($$0, 4); next } \
		/^[a-zA-Z][a-zA-Z0-9_-]*:/ { \
			split($$0, parts, ":"); \
			target = parts[1]; \
			prereqs = parts[2]; \
			sub(/[ \t]*;.*/, "", prereqs); \
			if (target == "require-prod" || target == "require-dev") { doc = ""; next } \
			tag = "any"; \
			if (prereqs ~ /require-prod/) tag = "prod"; \
			else if (prereqs ~ /require-dev/) tag = "dev"; \
			if (tag == "any" || tag == env) { \
				primary[primary_n++] = sprintf("  \033[36m%-26s\033[0m %s", target, doc); \
			} else { \
				other[other_n++] = sprintf("  \033[2m%-26s %s\033[0m", target, doc); \
			} \
			doc = ""; next \
		} \
		/^[[:space:]]*$$/ { doc = "" } \
		END { \
			printf "Available now (ENV=%s):\n\n", env; \
			for (i = 0; i < primary_n; i++) print primary[i]; \
			if (other_n > 0) { \
				other_env = (env == "dev") ? "prod" : "dev"; \
				printf "\nRequires ENV=%s:\n\n", other_env; \
				for (i = 0; i < other_n; i++) print other[i]; \
			} \
		}' $(MAKEFILE_LIST)

## Internal env gates — keep prod/dev-only targets from running in the wrong env.
require-prod:
	@[ "$(ENV)" = "prod" ] || { echo "ERROR: target requires ENV=prod (got ENV=$(ENV))"; exit 1; }

require-dev:
	@[ "$(ENV)" = "dev" ] || { echo "ERROR: target requires ENV=dev (got ENV=$(ENV))"; exit 1; }

## All stacks — adapts to ENV (dev: compose.dev.yml, prod: ordered stack sequence)
## Dev: if something is already bound to :6379 (e.g. another project's Valkey),
## skip our valkey service and let apps share the existing one. Same image,
## same protocol, dev data is throwaway — no reason to fight over the port.
up:
ifeq ($(ENV),prod)
	$(MAKE) networking-up
	$(MAKE) infra-up
	$(MAKE) monitoring-up
	$(MAKE) fpp-up
	$(MAKE) bun-email-api-up
	$(MAKE) photo-gallery-up
	$(MAKE) imgproxy-up
	$(MAKE) audio-gateway-up
else
	@if lsof -nP -iTCP:6379 -sTCP:LISTEN >/dev/null 2>&1; then \
		echo "→ Detected existing Redis/Valkey on :6379 — skipping the dev valkey service"; \
		echo "  Apps still connect to localhost:6379 either way."; \
		$(OP_RUN_DEV) docker compose -f compose.dev.yml up -d postgres mariadb; \
	else \
		$(OP_RUN_DEV) docker compose -f compose.dev.yml up -d; \
	fi
endif

down:
ifeq ($(ENV),prod)
	$(MAKE) audio-gateway-down
	$(MAKE) imgproxy-down
	$(MAKE) photo-gallery-down
	$(MAKE) bun-email-api-down
	$(MAKE) fpp-down
	$(MAKE) monitoring-down
	$(MAKE) infra-down
	$(MAKE) networking-down
else
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability down
endif

## Individual prod stacks — targeted restarts
networking-up:   require-prod ; $(OP_RUN) docker compose -f compose.networking.yml up -d
networking-down: require-prod ; $(OP_RUN) docker compose -f compose.networking.yml down
infra-up:        require-prod ; $(OP_RUN) docker compose -f compose.infra.yml up -d
infra-down:      require-prod ; $(OP_RUN) docker compose -f compose.infra.yml down
monitoring-up:   require-prod ; $(OP_RUN) docker compose -f compose.monitoring.yml up -d
monitoring-down: require-prod ; $(OP_RUN) docker compose -f compose.monitoring.yml down

## Manual image upgrade for the stateful infra containers (Postgres + Valkey).
## Both opt out of Watchtower, so patch releases only land through this target.
## ALWAYS `make backup` first. Same-major only — a major bump is the dump/restore
## procedure in docs/disaster-recovery.md, not this.
## Service-scoped on purpose: a bare `compose up -d` would also churn anything
## else in the file.
infra-upgrade: require-prod
	$(OP_RUN) docker compose -f compose.infra.yml pull postgres valkey
	$(OP_RUN) docker compose -f compose.infra.yml up -d postgres valkey
	@sleep 5; docker exec postgres postgres --version; docker exec redis valkey-server --version | cut -d, -f1

## Pull the newest ghcr.io/jkrumm/rollhook:latest and recreate the container.
## RollHook deploys every other app but cannot deploy itself; Watchtower only
## picks it up at the 04:00 sweep. Use this to take a fresh release immediately.
## Prints the running version afterwards — the container publishes no host port,
## so the probe goes through `docker exec`.
rollhook-update: require-prod
	$(OP_RUN) docker compose -f compose.networking.yml pull rollhook
	$(OP_RUN) docker compose -f compose.networking.yml up -d rollhook
	@sleep 5; echo "  running: $$(docker exec rollhook curl -sf http://localhost:7700/health || echo '<not answering yet>')"

## FPP stack (MariaDB now; fpp-server + fpp-analytics later) — apps/fpp/compose.yml
## On a fresh server: networking-up first, then fpp-cert-sync, then fpp-up.
fpp-up:   require-prod ; $(OP_RUN) docker compose -f apps/fpp/compose.yml up -d
fpp-down: require-prod ; $(OP_RUN) docker compose -f apps/fpp/compose.yml down
fpp-mariadb-setup: require-prod
	$(OP_RUN) ./apps/fpp/scripts/setup-mariadb.sh
fpp-cert-sync: require-prod
	$(OP_RUN) ./apps/fpp/scripts/cert-sync.sh
## One-shot bootstrap — pushes :initial fpp-server/fpp-analytics images to rollhook.jkrumm.com
## so RollHook has running containers to authorize OIDC deploys against. Re-runnable.
fpp-bootstrap-images: require-prod
	$(OP_RUN) ./apps/fpp/scripts/bootstrap-images.sh
## Materialize apps/fpp/.env from apps/fpp/.env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/fpp/compose.yml. Re-run after secret
## rotation. The resulting .env is chmod 600, gitignored, and stays on VPS.
fpp-env: require-prod
	op --account tkrumm inject -i apps/fpp/.env.tpl -o apps/fpp/.env -f
	chmod 644 apps/fpp/.env
	@echo "Wrote apps/fpp/.env (chmod 644, gitignored)"
	@echo "Note: 644 is required because the RollHook container runs as a"
	@echo "non-root user whose uid doesn't match the host's jkrumm uid."
	@echo "VPS has no other shell users so the local-readability risk is bounded."
## FPP MariaDB → S3 backup (cron 03:30 in prod; manual via this target).
fpp-backup: require-prod
	$(OP_RUN) ./apps/fpp/scripts/backup-mariadb.sh

## Manual MariaDB image upgrade — opted out of Watchtower like the other stateful
## containers. ALWAYS `make fpp-backup` first. Scoped to the mariadb service so the
## RollHook-managed fpp-server / fpp-analytics containers in the same file are left
## alone — a bare `compose up -d` there would recreate them off `:latest` and undo
## whatever RollHook last deployed.
fpp-mariadb-upgrade: require-prod
	$(OP_RUN) docker compose -f apps/fpp/compose.yml pull mariadb
	$(OP_RUN) docker compose -f apps/fpp/compose.yml up -d mariadb
	@sleep 5; docker exec mariadb mariadbd --version

# NOTE: restoring PROD MariaDB from S3 has NO make target by design — it overwrites
# production. It is a gated, human-only DR tool: apps/fpp/scripts/restore-mariadb.sh
# (see docs/disaster-recovery.md).
## Dev — pull latest (or BACKUP_FILE=...) S3 backup → local mariadb. Validates DR chain.
fpp-restore-local: require-dev
	$(OP_RUN) ./apps/fpp/scripts/restore-mariadb-local.sh
## Dev — fresh sync from prod mariadb over SSH (no S3). Re-runnable.
# No OP_RUN: the VPS resolves the prod credentials remotely (inside the script's
# `ssh vps ... op run`), and the local half reads the dev container's own env.
# That keeps this runnable on the headless mini, where op has no biometric.
fpp-sync-from-prod: require-dev
	./apps/fpp/scripts/sync-mariadb-from-vps.sh
## Interactive mariadb shell — works in both envs (resolves the local mariadb container).
fpp-shell:
	$(OP_RUN_ENV) sh -c 'docker exec -it -e MYSQL_PWD="$$MARIADB_ROOT_PASSWORD" mariadb mariadb -u root "$$MARIADB_DB"'

## bun-email-api stack (Bun + Resend, RollHook-managed) — apps/bun-email-api/compose.yml
## Stateless, no DB. RollHook deploys on push to jkrumm/bun-email-api:master.
bun-email-api-up:   require-prod ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml up -d
bun-email-api-down: require-prod ; $(OP_RUN) docker compose -f apps/bun-email-api/compose.yml down
## One-shot bootstrap — clone bun-email-api repo, build, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
bun-email-api-bootstrap-image: require-prod
	$(OP_RUN) ./apps/bun-email-api/scripts/bootstrap-image.sh
## Materialize apps/bun-email-api/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/bun-email-api/compose.yml. Re-run
## after rotating BEA secrets. Resulting .env is chmod 644 and gitignored.
bun-email-api-env: require-prod
	op --account tkrumm inject -i apps/bun-email-api/.env.tpl -o apps/bun-email-api/.env -f
	chmod 644 apps/bun-email-api/.env
	@echo "Wrote apps/bun-email-api/.env (chmod 644, gitignored)"

## argo stack (api + dashboard, RollHook-managed) — apps/argo/compose.yml
## Tailscale-only via DNS-only A record argo.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/argo:master.
##
## argo-up: recreate containers WITHOUT pulling a new image. Reads the SHAs
## of the currently-running-OR-STOPPED containers and pins IMAGE_TAG to each.
## Use this when you change apps/argo/compose.yml (labels, mounts, env) and
## need the changes applied without bumping the running code. To deploy new
## code, use `make argo-redeploy` (triggers RollHook via empty-commit push).
##
## Why this dance: RollHook tags pushed images by git SHA only — it does NOT
## update the :latest tag. So a naive `docker compose up -d` would resolve
## `${IMAGE_TAG:-...:latest}` and roll the running containers back to a stale
## :latest. Pinning to the running image avoids that regression.
##
## `docker ps` (no -a) only sees RUNNING containers — so an `exited` argo-api,
## the exact incident this target exists to fix, made it resolve to nothing
## and abort with "not running", refusing the one command that could recover
## it. `docker ps -a` names the container in any state; `docker inspect` on
## that name reads its pinned image whether it's up or down. The two failure
## messages below are deliberately different: no container by that name at
## all needs a bootstrap (there is no image to pin), a container that exists
## but couldn't be inspected is a different, rarer fault worth a manual look.
argo-up: require-prod
	@API_NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=argo-api' --format '{{.Names}}' | head -1); \
	WEB_NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=argo-dashboard' --format '{{.Names}}' | head -1); \
	if [ -z "$$API_NAME" ] || [ -z "$$WEB_NAME" ]; then \
	  echo "  ✗ no argo-api/argo-dashboard container exists at all — bootstrap via 'make argo-bootstrap-image' then push to argo master to trigger RollHook"; \
	  exit 1; \
	fi; \
	API_IMG=$$(docker inspect --format '{{.Config.Image}}' "$$API_NAME" 2>/dev/null || echo ""); \
	WEB_IMG=$$(docker inspect --format '{{.Config.Image}}' "$$WEB_NAME" 2>/dev/null || echo ""); \
	if [ -z "$$API_IMG" ] || [ -z "$$WEB_IMG" ]; then \
	  echo "  ✗ argo-api/argo-dashboard container exists ($$API_NAME/$$WEB_NAME, stopped or running) but its image could not be read — inspect it manually"; \
	  exit 1; \
	fi; \
	echo "  pinning argo-api      → $$API_IMG"; \
	echo "  pinning argo-dashboard → $$WEB_IMG"; \
	$(OP_RUN) env ARGO_API_IMAGE=$$API_IMG ARGO_DASHBOARD_IMAGE=$$WEB_IMG docker compose -f apps/argo/compose.yml --env-file apps/argo/.env up -d
argo-down: require-prod ; $(OP_RUN) docker compose -f apps/argo/compose.yml --env-file apps/argo/.env down

## Trigger a fresh RollHook deploy by pushing an empty commit to argo's master.
## RollHook detects the push, rebuilds both images at the new SHA, and rolling-
## restarts the containers. Use this instead of `make argo-up` when you want
## new code (or when you just want compose.yml changes safely applied via a
## fresh build).
argo-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/argo ]; then echo "  ✗ argo repo not found at ~/SourceRoot/argo"; exit 1; fi
	@cd $$HOME/SourceRoot/argo && \
	  git commit --allow-empty -m "chore: redeploy (triggered via vps make argo-redeploy)" && \
	  git push && \
	  echo "  ✓ pushed — watch the build at https://github.com/jkrumm/argo/actions"
## One-shot bootstrap — clone argo repo, build both images, push :initial to
## rollhook.jkrumm.com so RollHook has running containers to authorize OIDC
## deploys against. Re-runnable.
argo-bootstrap-image: require-prod
	$(OP_RUN) ./apps/argo/scripts/bootstrap-image.sh
## Materialize apps/argo/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any argo secret. Resulting .env is chmod 644 and gitignored.
argo-env: require-prod
	op --account tkrumm inject -i apps/argo/.env.tpl -o apps/argo/.env -f
	chmod 644 apps/argo/.env
	@echo "Wrote apps/argo/.env (chmod 644, gitignored)"

## research-gateway stack (Bun research API, RollHook-managed) — apps/research-gateway/compose.yml
## Deploys to research.jkrumm.com. RollHook deploys on push to jkrumm/research-gateway:master.
##
## research-gateway-up: recreate container WITHOUT pulling a new image. Reads the SHA
## of the currently-running container and pins RESEARCH_GATEWAY_IMAGE to it. Use this
## when you change apps/research-gateway/compose.yml (labels, mounts, env) and need the
## changes applied without bumping the running code. To deploy new code, use
## `make research-gateway-redeploy` (triggers RollHook via empty-commit push).
##
## Why this dance: RollHook tags pushed images by git SHA only — it does NOT
## update the :latest tag. So a naive `docker compose up -d` would resolve
## `${IMAGE_TAG:-...:latest}` and roll the running container back to a stale
## :latest. Pinning to the running image avoids that regression.
##
## `docker ps -a` (not `docker ps`), because a stopped-but-present container
## used to look identical to "never created" here — both gave an empty IMG —
## and this target then took the genesis branch and rolled a merely-exited
## container back to :latest, the exact regression the pinning dance exists
## to prevent. Genesis now means what it says: no container by that name in
## any state, not "not currently running".
research-gateway-up: require-prod
	@NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=research-gateway' --format '{{.Names}}' | head -1); \
	if [ -z "$$NAME" ]; then \
	  echo "  no research-gateway container exists — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env up -d; \
	else \
	  IMG=$$(docker inspect --format '{{.Config.Image}}' "$$NAME" 2>/dev/null || echo ""); \
	  if [ -z "$$IMG" ]; then \
	    echo "  ✗ research-gateway container '$$NAME' exists but its image could not be read — inspect it manually"; \
	    exit 1; \
	  fi; \
	  echo "  pinning research-gateway → $$IMG"; \
	  $(OP_RUN) env RESEARCH_GATEWAY_IMAGE=$$IMG docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env up -d; \
	fi
research-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/research-gateway/compose.yml --env-file apps/research-gateway/.env down

## Trigger a fresh RollHook deploy by pushing an empty commit to research-gateway's master.
## RollHook detects the push, rebuilds the image at the new SHA, and rolling-
## restarts the container. Use this instead of `make research-gateway-up` when you want
## new code (or when you just want compose.yml changes safely applied via a fresh build).
research-gateway-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/research-gateway ]; then echo "  ✗ research-gateway repo not found at ~/SourceRoot/research-gateway"; exit 1; fi
	@cd $$HOME/SourceRoot/research-gateway && \
	  git commit --allow-empty -m "chore: redeploy (triggered via vps make research-gateway-redeploy)" && \
	  git push && \
	  echo "  ✓ pushed — watch the build at https://github.com/jkrumm/research-gateway/actions"
## One-shot bootstrap — clone research-gateway repo, build image, push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
research-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/research-gateway/scripts/bootstrap-image.sh
## Materialize apps/research-gateway/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any research-gateway secret. Resulting .env is chmod 644 and gitignored.
research-gateway-env: require-prod
	op --account tkrumm inject -i apps/research-gateway/.env.tpl -o apps/research-gateway/.env -f
	chmod 644 apps/research-gateway/.env
	@echo "Wrote apps/research-gateway/.env (chmod 644, gitignored)"

## shutterflow stack (share server + signed imgproxy CDN, RollHook-managed) — apps/shutterflow/compose.yml
## shutterflow.app + cdn.shutterflow.app via the Cloudflare tunnel. RollHook deploys on push to
## jkrumm/shutterflow:master. shutterflow-up pins the running share image (never rolls back to a
## stale :latest); genesis start uses the bootstrap-seeded :latest.
shutterflow-up: require-prod
	@NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=shutterflow-share' --format '{{.Names}}' | head -1); \
	if [ -z "$$NAME" ]; then \
	  echo "  no shutterflow-share container exists — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/shutterflow/compose.yml --env-file apps/shutterflow/.env up -d; \
	else \
	  IMG=$$(docker inspect --format '{{.Config.Image}}' "$$NAME" 2>/dev/null || echo ""); \
	  if [ -z "$$IMG" ]; then \
	    echo "  ✗ shutterflow-share container '$$NAME' exists but its image could not be read — inspect it manually"; \
	    exit 1; \
	  fi; \
	  echo "  pinning shutterflow-share → $$IMG"; \
	  $(OP_RUN) env SHUTTERFLOW_SHARE_IMAGE=$$IMG docker compose -f apps/shutterflow/compose.yml --env-file apps/shutterflow/.env up -d; \
	fi
shutterflow-down: require-prod ; $(OP_RUN) docker compose -f apps/shutterflow/compose.yml --env-file apps/shutterflow/.env down

## Materialize apps/shutterflow/.env from .env.tpl (via `op inject`) plus the `proxy` network
## CIDR as SHUTTERFLOW_TRUSTED_PROXIES. Re-run after rotating any secret.
shutterflow-env: require-prod
	op --account tkrumm inject -i apps/shutterflow/.env.tpl -o apps/shutterflow/.env -f
	@CIDR=$$(docker network inspect proxy --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'); \
	[ -n "$$CIDR" ] || { echo "  ✗ could not read the proxy network subnet"; exit 1; }; \
	echo "SHUTTERFLOW_TRUSTED_PROXIES=$$CIDR" >> apps/shutterflow/.env
	chmod 644 apps/shutterflow/.env
	@echo "Wrote apps/shutterflow/.env (chmod 644, gitignored)"

## One-shot bootstrap — build + push :initial from a shipped source tree (the repo is private;
## see apps/shutterflow/scripts/bootstrap-image.sh for the one-line `git archive | ssh` step).
shutterflow-bootstrap-image: require-prod
	$(OP_RUN) ./apps/shutterflow/scripts/bootstrap-image.sh

## weatherorb stack (nginx edge in front of the tileserver on the Mac mini, RollHook-managed) —
## apps/weatherorb/compose.yml. Public at weatherorb.com through the cloudflared tunnel.
## The mini does all computation; this container serves the built map, the basemap
## archive under /var/lib/weatherorb/basemap, and a disk cache of proxied API responses.
## `docker ps -a` (not `docker ps`) — same fix as research-gateway-up above:
## a stopped-but-present container must still be pinned, not mistaken for
## genesis and rolled back to a stale :latest.
weatherorb-up: require-prod
	@NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=weatherorb-edge' --format '{{.Names}}' | head -1); \
	if [ -z "$$NAME" ]; then \
	  echo "  no weatherorb-edge container exists — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/weatherorb/compose.yml --env-file apps/weatherorb/.env up -d; \
	else \
	  IMG=$$(docker inspect --format '{{.Config.Image}}' "$$NAME" 2>/dev/null || echo ""); \
	  if [ -z "$$IMG" ]; then \
	    echo "  ✗ weatherorb-edge container '$$NAME' exists but its image could not be read — inspect it manually"; \
	    exit 1; \
	  fi; \
	  echo "  pinning weatherorb-edge → $$IMG"; \
	  $(OP_RUN) env WEATHERORB_EDGE_IMAGE=$$IMG docker compose -f apps/weatherorb/compose.yml --env-file apps/weatherorb/.env up -d; \
	fi
weatherorb-down: require-prod ; $(OP_RUN) docker compose -f apps/weatherorb/compose.yml --env-file apps/weatherorb/.env down

## Trigger a fresh RollHook deploy by pushing an empty commit to weatherorb's master.
weatherorb-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/weatherorb ]; then echo "  ✗ weatherorb repo not found at ~/SourceRoot/weatherorb"; exit 1; fi
	@cd $$HOME/SourceRoot/weatherorb && \
	  git commit --allow-empty -m "chore: redeploy (triggered via vps make weatherorb-redeploy)" && \
	  git push && \
	  echo "  ✓ pushed — watch the build at https://github.com/jkrumm/weatherorb/actions"
## One-shot bootstrap — build the edge image from the context `make edge-bootstrap` (weatherorb
## repo, on the mini) pushed to /tmp/weatherorb-bootstrap, push :initial + :latest to the registry.
weatherorb-bootstrap-image: require-prod
	$(OP_RUN) ./apps/weatherorb/scripts/bootstrap-image.sh
## Materialize apps/weatherorb/.env from this host's tailscale peer list — the mini's tailnet
## IP and MagicDNS name are the only two values the edge needs, and neither is a secret.
## Re-run after a mini rename or re-join.
weatherorb-env: require-prod
	@$(OP_RUN) sh -c 'ip=$$(tailscale ip -4 mini) && \
	  host=$$(tailscale status --json | jq -r ".Peer[] | select(.HostName==\"mini\") | .DNSName") && host=$${host%.} && \
	  printf "DOMAIN=%s\nMINI_TAILSCALE_IP=%s\nMINI_TAILNET_HOST=%s\n" "$$DOMAIN" "$$ip" "$$host" > apps/weatherorb/.env && \
	  chmod 644 apps/weatherorb/.env && echo "Wrote apps/weatherorb/.env (mini = $$host)"'

## image-gen-gateway stack (Bun image API, RollHook-managed) — apps/image-gen-gateway/compose.yml
## Deploys to image.jkrumm.com (Tailscale-only, grey-cloud A record — NOT the cloudflared
## tunnel). RollHook deploys on push to jkrumm/image-gen:master touching gateway/** or shared/**.
##
## Same image-pinning dance as research-gateway-up above, for the same reason: RollHook
## tags by git SHA and never moves :latest, so a naive `up -d` would roll the container
## back to a stale :latest. `docker ps -a` (not `docker ps`), same fix as research-gateway-up:
## a stopped-but-present container must be pinned, not mistaken for genesis.
image-gen-gateway-up: require-prod
	@NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=image-gen-gateway' --format '{{.Names}}' | head -1); \
	if [ -z "$$NAME" ]; then \
	  echo "  no image-gen-gateway container exists — genesis start from :latest (bootstrap-seeded)"; \
	  $(OP_RUN) docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env up -d; \
	else \
	  IMG=$$(docker inspect --format '{{.Config.Image}}' "$$NAME" 2>/dev/null || echo ""); \
	  if [ -z "$$IMG" ]; then \
	    echo "  ✗ image-gen-gateway container '$$NAME' exists but its image could not be read — inspect it manually"; \
	    exit 1; \
	  fi; \
	  echo "  pinning image-gen-gateway → $$IMG"; \
	  $(OP_RUN) env IMAGE_GEN_GATEWAY_IMAGE=$$IMG docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env up -d; \
	fi
image-gen-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/image-gen-gateway/compose.yml --env-file apps/image-gen-gateway/.env down

## Trigger a fresh RollHook deploy of image-gen-gateway via workflow_dispatch.
## NOT the empty-commit trick the other -redeploy targets use: image-gen's deploy.yml is
## path-filtered (gateway/**, shared/**, the workflow itself), so an empty commit touches
## none of those paths and would silently do nothing.
image-gen-gateway-redeploy: require-dev
	@if [ ! -d $$HOME/SourceRoot/image-gen ]; then echo "  ✗ image-gen repo not found at ~/SourceRoot/image-gen"; exit 1; fi
	@gh workflow run deploy.yml --repo jkrumm/image-gen --ref master && \
	  echo "  ✓ dispatched — watch the build at https://github.com/jkrumm/image-gen/actions"
## One-shot bootstrap — clone image-gen repo, build image, push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable. Builds from the REPO ROOT (bun monorepo).
image-gen-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/image-gen-gateway/scripts/bootstrap-image.sh
## Materialize apps/image-gen-gateway/.env from .env.tpl. Required so RollHook's
## `docker compose up --scale` can resolve ${VAR} interpolations. Re-run after
## rotating any image-gen-gateway secret. Resulting .env is chmod 644 and gitignored.
image-gen-gateway-env: require-prod
	op --account tkrumm inject -i apps/image-gen-gateway/.env.tpl -o apps/image-gen-gateway/.env -f
	chmod 644 apps/image-gen-gateway/.env
	@echo "Wrote apps/image-gen-gateway/.env (chmod 644, gitignored)"

## audio-gateway stack (Bun audio service, RollHook-managed) — apps/audio-gateway/compose.yml
## Tailscale-only via DNS-only A record audio-gateway.jkrumm.com → ${VPS_TAILSCALE_IP}.
## RollHook deploys on push to jkrumm/audio-gateway:master.
## Recreate-with-config-change without rolling back to a stale :latest (same
## foot-gun as argo-up): pin the running image SHA into IMAGE_TAG. New code still
## deploys only through RollHook (push to audio-gateway master).
## `docker ps -a` (not `docker ps`) so a stopped-but-present container still
## resolves — same argo-up fix, same reason: `docker ps` alone made this abort
## on exactly the exited container it exists to recover.
audio-gateway-up: require-prod
	@NAME=$$(docker ps -a --filter 'label=com.docker.compose.service=audio-gateway' --format '{{.Names}}' | head -1); \
	if [ -z "$$NAME" ]; then echo "  ✗ no audio-gateway container exists at all — bootstrap via 'make audio-gateway-bootstrap-image' then push to audio-gateway master"; exit 1; fi; \
	IMG=$$(docker inspect --format '{{.Config.Image}}' "$$NAME" 2>/dev/null || echo ""); \
	if [ -z "$$IMG" ]; then echo "  ✗ audio-gateway container '$$NAME' exists but its image could not be read — inspect it manually"; exit 1; fi; \
	echo "  pinning audio-gateway → $$IMG"; \
	$(OP_RUN) env IMAGE_TAG=$$IMG docker compose -f apps/audio-gateway/compose.yml up -d
audio-gateway-down: require-prod ; $(OP_RUN) docker compose -f apps/audio-gateway/compose.yml down
## Materialize apps/audio-gateway/.env from .env.tpl (via `op inject`). Required so
## RollHook's `docker compose up --scale` — which doesn't go through `op run` —
## can resolve ${VAR} interpolations in apps/audio-gateway/compose.yml. Re-run after
## rotating any audio-gateway secret. Resulting .env is chmod 644 and gitignored.
audio-gateway-env: require-prod
	op --account tkrumm inject -i apps/audio-gateway/.env.tpl -o apps/audio-gateway/.env -f
	chmod 644 apps/audio-gateway/.env
	@echo "Wrote apps/audio-gateway/.env (chmod 644, gitignored)"
## One-shot bootstrap — clone audio-gateway repo, build, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
audio-gateway-bootstrap-image: require-prod
	$(OP_RUN) ./apps/audio-gateway/scripts/bootstrap-image.sh

## photo-gallery stack — static Astro gallery served by nginx from a host volume.
## Content lives at /home/jkrumm/photo-gallery-dist on the VPS; photo-flow CLI on the
## developer laptop rsyncs the built dist/ there. No registry, no RollHook — the
## container only serves files. First bring-up requires content already in place
## (at minimum index.html) so the healthcheck can pass.
photo-gallery-up:   require-prod ; $(OP_RUN) docker compose -f apps/photo-gallery/compose.yml up -d
photo-gallery-down: require-prod ; $(OP_RUN) docker compose -f apps/photo-gallery/compose.yml down

## imgproxy stack — image CDN at img.DOMAIN, sourcing a private B2 bucket.
## Stateless: no volumes, no DB. Cloudflare's edge cache is the CDN layer.
## Requires op://vps/imgproxy/* (read-only, bucket-scoped B2 key) to exist first.
imgproxy-up:   require-prod ; $(OP_RUN) docker compose -f apps/imgproxy/compose.yml up -d
imgproxy-down: require-prod ; $(OP_RUN) docker compose -f apps/imgproxy/compose.yml down

## Read-only Cloudflare edge-cache checklist for HOST (zone, DNS, tunnel ingress,
## Cache Rule, live probe) — docs/edge-cache.md. Exits 1 if any check fails.
edge-cache-status: require-prod
	@[ -n "$(HOST)" ] || { echo "usage: make edge-cache-status HOST=example.com"; exit 1; }
	$(OP_RUN) python3 scripts/edge-cache.py status $(HOST)

## Idempotently provision the edge-cache pattern for HOST (proxied CNAMEs, tunnel
## ingress, Cache Rule), preserving every other DNS/ingress/rule entry, then runs
## status. DRY_RUN=1 previews without writing.
edge-cache-apply: require-prod
	@[ -n "$(HOST)" ] || { echo "usage: make edge-cache-apply HOST=example.com [DRY_RUN=1]"; exit 1; }
	$(OP_RUN) python3 scripts/edge-cache.py apply $(HOST)

## basalt-ui-marketing stack (static Astro docs site, RollHook-managed) — apps/basalt-ui-marketing/compose.yml
## Stateless, no DB, no .env — the image bakes the built site; RollHook injects IMAGE_TAG.
## RollHook deploys on pushes to jkrumm/basalt-ui:master touching apps/marketing/**.
basalt-ui-marketing-up:   require-prod ; $(OP_RUN) docker compose -f apps/basalt-ui-marketing/compose.yml up -d
basalt-ui-marketing-down: require-prod ; $(OP_RUN) docker compose -f apps/basalt-ui-marketing/compose.yml down
## One-shot bootstrap — clone basalt-ui, build apps/marketing, and push :initial to
## rollhook.jkrumm.com so RollHook has a running container to authorize OIDC
## deploys against. Re-runnable.
basalt-ui-marketing-bootstrap-image: require-prod
	$(OP_RUN) ./apps/basalt-ui-marketing/scripts/bootstrap-image.sh

## jkrumm-com stack (static Astro portfolio site, RollHook-managed) — apps/jkrumm-com/compose.yml
## Stateless, no DB, no .env — the image bakes the built site; RollHook injects IMAGE_TAG.
## RollHook deploys on pushes to jkrumm/jkrumm.com:master.
jkrumm-com-up:   require-prod ; $(OP_RUN) docker compose -f apps/jkrumm-com/compose.yml up -d
jkrumm-com-down: require-prod ; $(OP_RUN) docker compose -f apps/jkrumm-com/compose.yml down
## One-shot bootstrap — clone jkrumm.com, build the repo-root Dockerfile, and push
## :initial to rollhook.jkrumm.com so RollHook has a running container to
## authorize OIDC deploys against. Re-runnable.
jkrumm-com-bootstrap-image: require-prod
	$(OP_RUN) ./apps/jkrumm-com/scripts/bootstrap-image.sh

## Postgres schema/user provisioning — idempotent, works for both envs
postgres-setup:
	$(OP_RUN_ENV) ./scripts/setup-postgres.sh

## Materialize /etc/vps/*.env for cron jobs from cron/*.env.tpl (via op inject).
## Re-run after rotating a referenced secret.
cron-env-seed: require-prod
	./scripts/seed-cron-env.sh

## HyperDX agent user — idempotent, prod-only. Ensures op://vps/clickstack/AGENT_*
## resolves to a working HyperDX user + MCP-capable accessKey. Re-run after rotation.
hyperdx-agent-setup: require-prod
	./scripts/hyperdx-agent-setup.sh

## HyperDX local dev user — idempotent, dev-only. Registers/refreshes
## ~/.config/hyperdx/local.env (email/password/accessKey) against the local
## clickstack container. Safe to re-run.
hyperdx-dev-bootstrap: require-dev
	./scripts/hyperdx-dev-bootstrap.sh

## HyperDX Slack webhook — idempotent, prod-only. Ensures webhook "Slack #alerts"
## exists/matches op://common/slack/VPS_WEBHOOK_ALERTS. Run before hyperdx-apply.
hyperdx-webhook-setup: require-prod
	./scripts/hyperdx-webhook-setup.sh

## Dashboards + alerts-as-code — export every dashboard and alert from ENV to
## observability/dashboards/*.json and observability/alerts/*.json.
hyperdx-export:
	./scripts/hyperdx-sync.sh export $(ENV)

## Dashboards + alerts-as-code — validate + upsert (by name) dashboards from
## observability/dashboards/ (or FILES=...), then alerts from
## observability/alerts/, into ENV.
hyperdx-apply:
	./scripts/hyperdx-sync.sh apply $(ENV) $(FILES)

## Dev — ClickStack is on demand (profile `observability`, ~4 GB): `make up` skips it.
clickstack-up: require-dev
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability up -d clickstack

clickstack-down: require-dev
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability stop clickstack

## Dev — restart clickstack only. Fixes a dead local ClickHouse process while
## the all-in-one container still reports healthy (the healthcheck only covers the UI).
clickstack-restart: require-dev
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability restart clickstack

## Dev — pull the latest clickstack image and recreate the container (data volumes
## persist). `make up` never pulls, so the dev HyperDX drifts behind prod (Watchtower)
## until this runs — tile features differ between versions.
clickstack-upgrade: require-dev
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability pull clickstack
	$(OP_RUN_DEV) docker compose -f compose.dev.yml --profile observability up -d clickstack

## Status — docker ps with name/status/ports
ps:
	docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

## Manual Postgres → S3 backup (cron 03:00 in prod; manual via this target).
backup: require-prod
	$(OP_RUN) ./scripts/backup-pg.sh
# NOTE: restoring PROD Postgres from S3 has NO make target by design — it overwrites
# production. It is a gated, human-only DR tool: scripts/restore-pg.sh
# (see docs/disaster-recovery.md).
## Dev — pull latest (or BACKUP_FILE=...) S3 pg backup → local. Validates DR chain. Drops whole local DB.
## MacBook-only: keeps the full .env.tpl because it needs the S3 backup credential,
## which is deliberately not cached on the mini. To get prod DATA onto the mini use
## sync-from-prod (pg_dump over SSH, no credential) — this target is the DR drill.
restore-local: require-dev
	$(OP_RUN) ./scripts/restore-pg-local.sh
## Dev — converge the local superuser passwords onto .env.dev.tpl. Idempotent.
## Both images apply their password variable ONLY when initializing an EMPTY data
## directory, so a volume created before the dev-only credentials existed keeps
## whatever password initialized it — silently, with healthy containers and passing
## healthchecks, because those use the unix socket. Only TCP connections fail.
dev-db-passwords: require-dev
	$(OP_RUN_DEV) ./scripts/dev-db-passwords.sh

## Dev — DESTROY and re-initialize the local FPP MariaDB volume. Destructive.
## The only in-place way to change a root password whose volume predates the
## dev-only credentials: unlike Postgres, MariaDB root has no socket-trust path,
## so an ALTER needs the CURRENT password — prod's, deliberately not cached here.
## Re-init is the route that needs no prod credential at all. Repopulate after
## with `make fpp-sync-from-prod`, which also needs none.
## Guarded: pass CONFIRM=yes.
dev-mariadb-reset: require-dev
	@[ "$(CONFIRM)" = "yes" ] || { \
		echo "refusing: this DELETES volume $(MARIADB_DEV_VOLUME) and every local FPP row in it."; \
		echo "re-run with CONFIRM=yes (then: make fpp-sync-from-prod)"; exit 1; }
	$(OP_RUN_DEV) docker compose -f compose.dev.yml rm -sf mariadb
	docker volume rm $(MARIADB_DEV_VOLUME)
	$(OP_RUN_DEV) docker compose -f compose.dev.yml up -d mariadb
	@echo "  ✓ mariadb re-initialized from .env.dev.tpl — now run 'make fpp-sync-from-prod'"

## Dev — fresh whole-DB sync from prod Postgres over SSH (no S3). Drops whole local DB.
sync-from-prod: require-dev
	$(OP_RUN_DEV) ./scripts/sync-pg-from-vps.sh
## Dev — per-schema sync from prod (SCHEMA=argo). Least-priv, leaves other schemas intact.
pg-sync-schema: require-dev
	SCHEMA="$(SCHEMA)" $(OP_RUN_DEV) ./scripts/sync-pg-schema-from-vps.sh

## UFW status + rules — prod-only (the dev box has its own firewall).
firewall: require-prod
	./scripts/firewall.sh

## Interactive psql shell — works in both envs.
shell-postgres:
	$(OP_RUN_ENV) sh -c 'docker exec -it postgres psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

## Non-interactive psql: SQL on stdin, results on stdout (no TTY — usable over
## plain ssh and from agents). Same env wrapper as shell-postgres.
##   make sql-postgres <<< "SELECT count(*) FROM usage_record"
sql-postgres:
	@$(OP_RUN_ENV) sh -c 'docker exec -i postgres psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -v ON_ERROR_STOP=1'

## Exact per-table row counts (Postgres all schemas + MariaDB fpp). Read-only,
## both envs, diff-friendly — use to verify two DB states match after sync/restore.
db-counts:
	./scripts/db-counts.sh

## Reclaim disk: stopped containers, unused images, build cache. Both envs. Never touches volumes.
prune:
	@echo "→ Pruning stopped containers..."
	@docker container prune -f
	@echo ""
	@echo "→ Pruning unused images (tagged + dangling)..."
	@docker image prune -af
	@echo ""
	@echo "→ Pruning build cache..."
	@docker builder prune -af
	@echo ""
	@echo "✓ Done. Volumes left intact — run 'docker volume prune' manually if you really mean it."

## Install the weekly image + build-cache prune cron (cron/docker-prune → /etc/cron.d).
## Prod-only, idempotent; setup.sh installs the same file on a fresh server. Prints
## what the next run would reclaim.
prune-cron-install: require-prod
	sudo install -o root -g root -m 644 cron/docker-prune /etc/cron.d/docker-prune
	@echo "  ✓ /etc/cron.d/docker-prune installed (Sunday 04:30 — images + build cache, never volumes)"
	@docker system df | awk 'NR==1 || /^Images|^Build Cache/'
