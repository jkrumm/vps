#!/usr/bin/env python3
"""
Idempotent tool for the Cloudflare edge-cache pattern (docs/edge-cache.md).

Replaces the copy-paste API snippets in the /cloudflare skill for this one
pattern: a proxied CNAME + tunnel ingress entry + a "respect origin" Cache
Rule per hostname, verified with a live probe.

Usage (via Makefile, which pipes secrets through op run --env-file=.env.tpl):
    make edge-cache-status HOST=example.com
    make edge-cache-apply  HOST=example.com [DRY_RUN=1]

Required env: CLOUDFLARE_MANAGE_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_TUNNEL_ID.
stdlib only (urllib, json) — no pip dependency.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.cloudflare.com/client/v4"


class Cf404(RuntimeError):
    """The requested resource doesn't exist yet (e.g. no Cache Rules ruleset)."""


class CfApiError(RuntimeError):
    def __init__(self, errors):
        self.errors = errors
        hint = ""
        if any(e.get("code") == 10000 for e in errors):
            hint = (
                "\nhint: token lacks permission — cf-manage needs DNS:Edit, "
                "Cache Rules:Edit, Tunnel:Edit, Account Rulesets/Filter Lists:Edit"
            )
        super().__init__(f"{errors}{hint}")


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def env(name):
    value = os.environ.get(name)
    if not value:
        die(f"{name} not set — run via make edge-cache-status/edge-cache-apply")
    return value


def cf(method, path, body=None):
    """One HTTP call to the Cloudflare API. Raises Cf404 or CfApiError, never
    prints the token or any ID it's called with."""
    token = env("CLOUDFLARE_MANAGE_TOKEN")
    url = API_BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        text = e.read().decode(errors="replace")
        if e.code == 404:
            raise Cf404(path)
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            raise CfApiError([{"code": e.code, "message": text[:300]}])
        raise CfApiError(payload.get("errors") or [{"code": e.code, "message": text[:300]}])
    if not payload.get("success"):
        raise CfApiError(payload.get("errors") or [])
    return payload.get("result")


# --------------------------------------------------------------------------
# Zone / DNS / ingress / cache-rule reads
# --------------------------------------------------------------------------


def find_zone(host):
    """Walk label suffixes of HOST (most specific first) until one matches a
    registered zone. Returns (zone_name, zone_id) or (None, None)."""
    labels = host.split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        result = cf("GET", f"/zones?name={urllib.parse.quote(candidate)}")
        if result:
            return candidate, result[0]["id"]
    return None, None


def get_dns_record(zone_id, name):
    records = cf(
        "GET",
        f"/zones/{zone_id}/dns_records?name={urllib.parse.quote(name)}&type=CNAME",
    )
    return records[0] if records else None


def get_tunnel_config(account_id, tunnel_id):
    """The whole remote-managed config — PUT replaces all of it, so writers must
    round-trip every key, not just ingress."""
    result = cf("GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations")
    return result.get("config") or {}


def get_ingress(account_id, tunnel_id):
    return get_tunnel_config(account_id, tunnel_id).get("ingress") or []


def ingress_covers(ingress, host):
    """An explicit entry, or a wildcard *.x that covers host — but *.x never
    matches its own apex x."""
    for entry in ingress:
        hostname = entry.get("hostname")
        if hostname is None:
            continue
        if hostname == host:
            return True
        if hostname.startswith("*."):
            suffix = hostname[1:]  # ".example.com"
            apex = suffix[1:]  # "example.com"
            if host != apex and host.endswith(suffix):
                return True
    return False


def get_entrypoint_rules(zone_id):
    try:
        result = cf(
            "GET", f"/zones/{zone_id}/rulesets/phases/http_request_cache_settings/entrypoint"
        )
    except Cf404:
        return []
    return (result or {}).get("rules") or []


def cache_rule_ok(rules, host):
    description = f"edge-cache {host}"
    expression = f'(http.host eq "{host}")'
    for rule in rules:
        if rule.get("description") != description:
            continue
        params = rule.get("action_parameters") or {}
        if (
            rule.get("expression") == expression
            and params.get("cache") is True
            and (params.get("edge_ttl") or {}).get("mode") == "respect_origin"
            and (params.get("browser_ttl") or {}).get("mode") == "respect_origin"
        ):
            return True
    return False


# --------------------------------------------------------------------------
# Live probe
# --------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "edge-cache-check/1.0"})
    try:
        resp = _opener.open(req, timeout=15)
        return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def find_first_astro_asset(body, host):
    text = body.decode("utf-8", errors="replace")
    match = re.search(r"/_astro/[^\"'\s]+\.(?:css|js)", text)
    return f"https://{host}{match.group(0)}" if match else None


def probe_host(host):
    result = {"ok": True, "notes": [], "cf_cache_statuses": []}
    url = f"https://{host}/"

    status, headers, body = http_get(url)
    if cf_status := headers.get("cf-cache-status"):
        result["cf_cache_statuses"].append(cf_status)
    if status != 200:
        result["ok"] = False
        result["notes"].append(f"GET {url} returned {status}, expected 200 (no redirects followed)")
        return result

    cache_control = headers.get("Cache-Control", "")
    if "max-age=0" not in cache_control:
        result["ok"] = False
        result["notes"].append(f"Cache-Control missing max-age=0: {cache_control!r}")
    if headers.get("Cloudflare-CDN-Cache-Control"):
        result["ok"] = False
        result["notes"].append("Cloudflare-CDN-Cache-Control leaked to the client (should be stripped at the edge)")

    _, headers2, _ = http_get(url)
    cf_status2 = headers2.get("cf-cache-status")
    if cf_status2:
        result["cf_cache_statuses"].append(cf_status2)
    if cf_status2 != "HIT":
        result["ok"] = False
        result["notes"].append(f"second request cf-cache-status={cf_status2!r}, expected HIT")

    asset_url = find_first_astro_asset(body, host)
    if not asset_url:
        result["notes"].append("no /_astro/*.css|js asset found in the HTML to probe")
        return result

    a_status, a_headers, _ = http_get(asset_url)
    if a_status != 200:
        result["ok"] = False
        result["notes"].append(f"asset {asset_url} returned {a_status}, expected 200")
        return result
    a_cache_control = a_headers.get("Cache-Control", "")
    if "immutable" not in a_cache_control:
        result["ok"] = False
        result["notes"].append(f"asset {asset_url} Cache-Control missing immutable: {a_cache_control!r}")

    _, a_headers2, _ = http_get(asset_url)
    a_cf_status2 = a_headers2.get("cf-cache-status")
    if a_cf_status2:
        result["cf_cache_statuses"].append(a_cf_status2)
    if a_cf_status2 != "HIT":
        result["ok"] = False
        result["notes"].append(f"asset {asset_url} second request cf-cache-status={a_cf_status2!r}, expected HIT")

    return result


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------


def run_status(host, account_id, tunnel_id):
    fails = 0

    def check(ok, label, hint=None, fatal=True):
        nonlocal fails
        mark = "✓" if ok else "✗"
        print(f"  [{mark}] {label}")
        if not ok:
            if hint:
                print(f"      fix: {hint}")
            if fatal:
                fails += 1

    print(f"Edge cache status: {host}\n")

    zone_name, zone_id = find_zone(host)
    check(
        zone_id is not None,
        f"zone found: {zone_name}" if zone_name else f"zone found for {host}",
        hint=f"no Cloudflare zone covers {host} — add the zone in Cloudflare first",
    )

    www = f"www.{host}"

    if zone_id:
        cname = get_dns_record(zone_id, host)
        target = f"{tunnel_id}.cfargotunnel.com"
        cname_ok = bool(cname and cname.get("proxied") and cname.get("content") == target)
        check(
            cname_ok,
            f"DNS: proxied CNAME {host} -> VPS tunnel",
            hint=f"make edge-cache-apply HOST={host} to create a proxied CNAME to the VPS tunnel",
        )

        www_cname = get_dns_record(zone_id, www)
        if www_cname is None:
            print(f"  [~] DNS: no CNAME for {www} (optional, warn only)")
        else:
            www_ok = bool(www_cname.get("proxied") and www_cname.get("content") == target)
            check(
                www_ok,
                f"DNS: proxied CNAME {www} -> VPS tunnel",
                hint="fix or recreate the www CNAME to point at the VPS tunnel",
                fatal=False,
            )
    else:
        print("  [✗] DNS checks skipped — no zone")
        fails += 1

    ingress = get_ingress(account_id, tunnel_id)
    check(
        ingress_covers(ingress, host),
        f"tunnel ingress covers {host}",
        hint=f"make edge-cache-apply HOST={host} to insert an ingress entry",
    )
    check(
        ingress_covers(ingress, www),
        f"tunnel ingress covers {www}",
        hint=f"make edge-cache-apply HOST={host} to insert a www ingress entry (unless a wildcard already covers it)",
    )

    if zone_id:
        rules = get_entrypoint_rules(zone_id)
        check(
            cache_rule_ok(rules, host),
            f"Cache Rule 'edge-cache {host}' (cache=true, edge/browser TTL respect_origin)",
            hint=f"make edge-cache-apply HOST={host} to upsert the Cache Rule",
        )
    else:
        print("  [✗] Cache Rule check skipped — no zone")
        fails += 1

    probe = probe_host(host)
    check(
        probe["ok"],
        f"live probe https://{host}/ (200, Cache-Control max-age=0, no leaked "
        "Cloudflare-CDN-Cache-Control, second request HIT, /_astro asset immutable+HIT)",
        hint="; ".join(probe["notes"]) if probe["notes"] else None,
    )
    if probe["ok"]:
        for note in probe["notes"]:
            print(f"      note: {note}")
    if probe["cf_cache_statuses"]:
        print(f"  cf-cache-status values seen: {', '.join(probe['cf_cache_statuses'])}")

    print()
    return fails == 0


# --------------------------------------------------------------------------
# apply
# --------------------------------------------------------------------------


def ensure_cname(zone_id, name, tunnel_id, dry_run):
    target = f"{tunnel_id}.cfargotunnel.com"
    record = get_dns_record(zone_id, name)
    if record:
        if record.get("proxied") and record.get("content") == target:
            print(f"  DNS {name}: already a proxied CNAME -> VPS tunnel, skipping")
            return
        die(
            f"DNS record for {name} exists but doesn't point at the VPS tunnel "
            f"(proxied={record.get('proxied')}) — refusing to overwrite"
        )
    if dry_run:
        print(f"  [dry-run] would create a proxied CNAME {name} -> VPS tunnel")
        return
    cf(
        "POST",
        f"/zones/{zone_id}/dns_records",
        {"type": "CNAME", "name": name, "content": target, "proxied": True},
    )
    print(f"  created proxied CNAME {name} -> VPS tunnel")


def ensure_ingress(host, account_id, tunnel_id, dry_run):
    config = get_tunnel_config(account_id, tunnel_id)
    ingress = config.get("ingress") or []
    if not ingress or "hostname" in ingress[-1]:
        die("tunnel ingress has no trailing catch-all entry — refusing to edit it blind")
    www = f"www.{host}"
    to_add = [h for h in (host, www) if not ingress_covers(ingress, h)]
    if not to_add:
        print("  tunnel ingress: already covers HOST and www (if applicable), skipping")
        return
    if dry_run:
        print(f"  [dry-run] would insert ingress entries for: {', '.join(to_add)}")
        return
    new_entries = [
        {"hostname": h, "service": "https://traefik:443", "originRequest": {"noTLSVerify": True}}
        for h in to_add
    ]
    config["ingress"] = ingress[:-1] + new_entries + ingress[-1:]
    cf(
        "PUT",
        f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
        {"config": config},
    )
    print(f"  inserted ingress entries for: {', '.join(to_add)}")


CACHE_RULE_FIELDS = ("expression", "action", "action_parameters", "description", "enabled")


def build_cache_rule(host):
    return {
        "description": f"edge-cache {host}",
        "expression": f'(http.host eq "{host}")',
        "action": "set_cache_settings",
        "enabled": True,
        "action_parameters": {
            "cache": True,
            "edge_ttl": {"mode": "respect_origin"},
            "browser_ttl": {"mode": "respect_origin"},
        },
    }


def upsert_cache_rule(zone_id, host, dry_run):
    description = f"edge-cache {host}"
    rules = get_entrypoint_rules(zone_id)
    kept = [
        {field: rule[field] for field in CACHE_RULE_FIELDS if field in rule}
        for rule in rules
        if rule.get("description") != description
    ]
    kept.append(build_cache_rule(host))
    if dry_run:
        print(f"  [dry-run] would PUT the cache-rule entrypoint with {len(kept)} rule(s), upserting '{description}'")
        return
    cf(
        "PUT",
        f"/zones/{zone_id}/rulesets/phases/http_request_cache_settings/entrypoint",
        {"rules": kept},
    )
    print(f"  upserted Cache Rule '{description}' ({len(kept)} rule(s) total)")


def run_apply(host, account_id, tunnel_id, dry_run):
    if dry_run:
        print(f"[DRY RUN] edge-cache apply for {host} — no writes will be made\n")

    zone_name, zone_id = find_zone(host)
    if not zone_id:
        die(f"no Cloudflare zone found for any suffix of {host}")

    www = f"www.{host}"
    print(f"Zone: {zone_name}")

    print(f"Ensuring DNS for {host} and {www}...")
    ensure_cname(zone_id, host, tunnel_id, dry_run)
    ensure_cname(zone_id, www, tunnel_id, dry_run)

    print("Ensuring tunnel ingress...")
    ensure_ingress(host, account_id, tunnel_id, dry_run)

    print("Ensuring Cache Rule...")
    upsert_cache_rule(zone_id, host, dry_run)

    print()


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("status", "apply"):
        print(
            "usage: edge-cache.py status|apply HOST\n"
            "       DRY_RUN=1 edge-cache.py apply HOST",
            file=sys.stderr,
        )
        sys.exit(1)

    command, host = sys.argv[1], sys.argv[2]
    account_id = env("CLOUDFLARE_ACCOUNT_ID")
    tunnel_id = env("CLOUDFLARE_TUNNEL_ID")

    try:
        if command == "apply":
            dry_run = os.environ.get("DRY_RUN") == "1"
            run_apply(host, account_id, tunnel_id, dry_run)
            ok = run_status(host, account_id, tunnel_id)
        else:
            ok = run_status(host, account_id, tunnel_id)
    except (CfApiError, Cf404) as e:
        die(str(e))
        return

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
