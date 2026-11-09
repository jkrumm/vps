#!/usr/bin/env python3
"""Lint the compose files against the AGENTS.md invariants (Security Invariants, RollHook constraints).

Parses with `docker compose config --no-interpolate --format json`, so no secrets or env are needed
and ${VAR} references stay visible as written. Exit 1 with file:service messages on any violation.
"""
import glob
import json
import re
import subprocess
import sys

# AGENTS.md → Security Invariants: only these (file, service) pairs may publish ports.
# The Tailscale/loopback bind is still enforced unless the pair is in PUBLIC_PORTS.
ALLOWED_PORTS = {
    ("compose.networking.yml", "traefik"),
    ("compose.monitoring.yml", "clickstack"),  # 13133 OTel health
    ("compose.monitoring.yml", "beszel-agent"),
    ("compose.monitoring.yml", "dozzle"),
    ("apps/weatherorb/compose.yml", "weatherorb-egress"),
    ("apps/fpp/compose.yml", "mariadb"),
}
# The one documented public exception: FPP MariaDB TCP 33306.
PUBLIC_PORTS = {("apps/fpp/compose.yml", "mariadb")}

TAILSCALE_BIND = re.compile(r"^(\$\{VPS_TAILSCALE_IP:\?[^}]*\}|\$\{VPS_TAILSCALE_IP:-127\.0\.0\.1\}|127\.0\.0\.1):")
STATEFUL_IMAGE = re.compile(r"(^|/)(postgres|valkey|redis|mariadb|mysql|clickhouse|clickstack)", re.I)
WATCHTOWER_LABEL = "com.centurylinklabs.watchtower.enable"


def labels_of(svc):
    labels = svc.get("labels") or {}
    if isinstance(labels, list):
        return dict(item.split("=", 1) if "=" in item else (item, "") for item in labels)
    return {k: str(v) for k, v in labels.items()}


def image_tag(image):
    last = image.rsplit("/", 1)[-1]
    return last.split(":", 1)[1] if ":" in last else "latest"


def lint_service(path, name, svc):
    """Return a list of violation messages for one service dict."""
    where = f"{path}:{name}"
    errors = []
    image = svc.get("image", "")
    ports = svc.get("ports") or []
    rollhook = "${IMAGE_TAG" in image

    if ports and (path, name) not in ALLOWED_PORTS:
        errors.append(f"{where}: publishes ports {ports} but is not in the ports allowlist")
    if ports and (path, name) not in PUBLIC_PORTS:
        for port in ports:
            if not isinstance(port, str) or not TAILSCALE_BIND.match(port):
                errors.append(f"{where}: port {port!r} must bind ${{VPS_TAILSCALE_IP:?...}} or 127.0.0.1")

    if rollhook:
        if ports:
            errors.append(f"{where}: RollHook app must not publish ports")
        if "container_name" in svc:
            errors.append(f"{where}: RollHook app must not set container_name")
        if "healthcheck" not in svc:
            errors.append(f"{where}: RollHook app needs a healthcheck")

    if STATEFUL_IMAGE.search(image):
        if labels_of(svc).get(WATCHTOWER_LABEL) != "false":
            errors.append(f"{where}: stateful service needs label {WATCHTOWER_LABEL}=false")
        if image_tag(image) == "latest":
            errors.append(f"{where}: stateful service must pin an image tag, not :latest ({image})")
    return errors


def lint_compose(path, config):
    errors = []
    for name, svc in (config.get("services") or {}).items():
        errors += lint_service(path, name, svc)
    return errors


def load_compose(path):
    out = subprocess.run(
        ["docker", "compose", "-f", path, "config", "--no-interpolate", "--format", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"{path}: docker compose config failed: {out.stderr.strip()}")
    return json.loads(out.stdout)


def main():
    files = sorted(glob.glob("compose.networking.yml") + glob.glob("compose.infra.yml")
                   + glob.glob("compose.monitoring.yml") + glob.glob("apps/*/compose.yml"))
    errors = []
    for path in files:
        errors += lint_compose(path, load_compose(path))
    for line in errors:
        print(f"✗ {line}", file=sys.stderr)
    if errors:
        return 1
    print(f"OK: compose invariants hold across {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
