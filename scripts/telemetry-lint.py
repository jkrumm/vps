#!/usr/bin/env python3
"""Telemetry lint: observability/services.yaml (the registry) against what prod ClickHouse received.

Contract: docs/observability.md -> "Telemetry lint". Read-only: every ClickHouse query carries a
time filter on the table's partition column and a LIMIT, and runs through `ssh vps docker exec
clickstack clickhouse-client` (Tailscale SSH, keyless: no 1Password prompt on the mini). The drift
rule reads the HyperDX REST API with the agent access key from `secrets-run` (the offline cache).

Exit 0: no findings. Exit 1: findings (one line each: rule, service, measured value, owning repo).
Exit 2: the lint could not read prod (a probe error, not a verdict).

A rule is silenced for one service in the registry (`ignore: {<rule>: <reason>}`), never here.
"""

import argparse
import datetime
import glob
import json
import math
import os
import re
import shlex
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "observability", "services.yaml")

ENVIRONMENTS = {"prod", "dev"}
BAD_VERSIONS = {"local", "unknown", "latest", "0.0.0"}
CONTAINER_ID = re.compile(r"^[0-9a-f]{12,64}$")
SIGNALS = ("traces", "logs", "metrics")
# The 1 % bound of the empty-Body rule and the silence window.
EMPTY_BODY_SHARE = 0.01
SILENCE_HOURS = 24
# A dashboard or alert carrying one of these tags is owned and applied by another repo
# (scripts/hyperdx-sync.sh OWNED_ELSEWHERE_TAGS): not part of the drift comparison.
OWNED_ELSEWHERE_TAGS = {"weatherorb", "agw"}

RULES = (
    "unregistered",  # a service.name that emits but is not in the registry
    "silent",  # an expected signal with no rows for more than SILENCE_HOURS
    "environment",  # deployment.environment.name missing, not prod/dev, or not the registry's env
    "namespace",  # service.namespace missing
    "version",  # service.version missing or local/unknown/latest/0.0.0 on a prod service
    "host",  # host.name missing or shaped like a container ID
    "body-empty",  # empty log Body above EMPTY_BODY_SHARE
    "untraced-logs",  # logs without TraceId above budget.untraced_logs
    "volume",  # rows per day above budget.<signal>
    "drift",  # alert or dashboard on one side of prod / observability/ only
)


class ProbeError(Exception):
    """The lint could not read prod."""


# --------------------------------------------------------------------------- registry


def load_registry(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    return {entry["name"]: entry for entry in doc.get("services", [])}


def expected_signals(entry):
    """The signals whose silence is a finding: all of `signals`, a subset, or none."""
    declared = entry.get("expected", "all")
    if declared == "none" or declared is None:
        return []
    if declared == "all":
        return [s for s in entry.get("signals", []) if s in SIGNALS]
    return [s for s in declared if s in SIGNALS]


# --------------------------------------------------------------------------- collection

LOGS = ("otel_logs", "logs", "TimestampTime")
TRACES = ("otel_traces", "traces", "Timestamp")
METRIC_TABLES = tuple(
    ("otel_metrics_" + kind, "metrics", "TimeUnix")
    for kind in ("gauge", "sum", "histogram", "exponential_histogram", "summary")
)
ALL_TABLES = (TRACES, LOGS) + METRIC_TABLES
# Session replay only feeds the "unregistered" rule: the registry lists no signal for it.
SESSIONS = ("hyperdx_sessions", "sessions", "TimestampTime")


def union(selects):
    return " UNION ALL ".join(selects)


def build_queries():
    """Three read-only queries; every row is tagged with its query name in column q."""
    activity = union(
        f"SELECT '{sig}' AS signal, ServiceName AS service, count() AS rows7d, "
        f"countIf({col} > now() - INTERVAL 1 DAY) AS rows24h, toUnixTimestamp(max({col})) AS last "
        f"FROM {table} WHERE {col} > now() - INTERVAL 7 DAY GROUP BY signal, service"
        for table, sig, col in ALL_TABLES + (SESSIONS,)
    )
    attrs = union(
        f"SELECT '{sig}' AS signal, ServiceName AS service, "
        f"ResourceAttributes['deployment.environment.name'] AS env, "
        f"ResourceAttributes['service.namespace'] AS ns, "
        f"ResourceAttributes['service.version'] AS version, "
        f"ResourceAttributes['host.name'] AS host, count() AS rows "
        f"FROM {table} WHERE {col} > now() - INTERVAL 1 DAY GROUP BY signal, service, env, ns, version, host"
        for table, sig, col in ALL_TABLES
    )
    return [
        "SELECT 'activity' AS q, signal, service, sum(rows7d) AS rows7d, sum(rows24h) AS rows24h, "
        f"max(last) AS last FROM ({activity}) GROUP BY signal, service ORDER BY service, signal LIMIT 2000",
        "SELECT 'attrs' AS q, signal, service, env, ns, version, host, sum(rows) AS rows "
        f"FROM ({attrs}) GROUP BY signal, service, env, ns, version, host ORDER BY service, signal LIMIT 20000",
        "SELECT 'logs' AS q, ServiceName AS service, count() AS total, countIf(Body = '') AS empty_body, "
        "countIf(TraceId = '') AS untraced FROM otel_logs WHERE TimestampTime > now() - INTERVAL 1 DAY "
        "GROUP BY service ORDER BY service LIMIT 2000",
    ]


def clickhouse(ssh):
    """Run the queries on the prod ClickStack; returns {query name: [row dict]}."""
    script = "\n".join(sql + ";" for sql in build_queries())
    remote = "docker exec -i clickstack clickhouse-client --multiquery --format JSONEachRow"
    try:
        proc = subprocess.run(shlex.split(ssh) + [remote], input=script, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProbeError(f"ClickHouse unreachable ({ssh}): {exc}") from exc
    if proc.returncode != 0:
        raise ProbeError(f"ClickHouse query failed (exit {proc.returncode}): {proc.stderr.strip()[:300]}")
    out = {"activity": [], "attrs": [], "logs": []}
    for line in proc.stdout.splitlines():
        if line.strip():
            row = json.loads(line)
            out[row.pop("q")].append(row)
    return out


def hyperdx_names():
    """(dashboard names, alert names) in prod, minus those another repo owns."""
    key = os.environ.get("HYPERDX_PROD_ACCESS_KEY")
    base = os.environ.get("HYPERDX_PROD_BASE_URL")
    try:
        if not key:
            key = subprocess.run(
                ["secrets-run", "read", "op://vps/clickstack/AGENT_ACCESS_KEY"],
                capture_output=True, text=True, timeout=20, check=True,
            ).stdout.strip()
        if not base:
            domain = subprocess.run(
                ["secrets-run", "read", "op://vps/config/DOMAIN"],
                capture_output=True, text=True, timeout=20, check=True,
            ).stdout.strip()
            base = f"https://hyperdx.{domain}"
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProbeError(f"HyperDX key unavailable (set HYPERDX_PROD_ACCESS_KEY, or run where secrets-run exists): {exc}") from exc
    names = []
    for path in ("dashboards", "alerts"):
        try:
            proc = subprocess.run(
                ["curl", "-fsS", "--max-time", "30", f"{base}/api/api/v2/{path}", "-H", f"Authorization: Bearer {key}"],
                capture_output=True, text=True, timeout=45, check=True,
            )
            data = json.loads(proc.stdout)["data"]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as exc:
            raise ProbeError(f"HyperDX /{path} unreadable: {exc}") from exc
        names.append({d["name"] for d in data if not OWNED_ELSEWHERE_TAGS & set(d.get("tags") or [])})
    return names[0], names[1]


def exported_names():
    """(dashboard names, alert names) in observability/dashboards and observability/alerts."""
    result = []
    for kind in ("dashboards", "alerts"):
        names = set()
        for path in sorted(glob.glob(os.path.join(ROOT, "observability", kind, "*.json"))):
            with open(path) as f:
                names.add(json.load(f)["name"])
        result.append(names)
    return result[0], result[1]


# --------------------------------------------------------------------------- rules


class Finding:
    def __init__(self, rule, service, measured, repo):
        self.rule, self.service, self.measured, self.repo = rule, service, measured, repo

    def line(self):
        return f"{self.rule:<13} {self.service}: {self.measured} (repo {self.repo})"


def pct(part, whole):
    return f"{100 * part / whole:.1f} %" if whole else "0 %"


def fmt_age(now, last):
    hours = (now - last) / 3600
    return f"{hours:.0f} h" if hours < 72 else f"{hours / 24:.0f} d"


def top(counter, limit=3):
    """`'a' x 10, '' x 2` for the largest buckets of a {value: rows} map."""
    items = sorted(counter.items(), key=lambda kv: -kv[1])[:limit]
    return ", ".join(f"{v!r} x {n}" for v, n in items)


def tally(rows, key, wanted):
    """{value: rows} of the rows whose `key` value passes `wanted`."""
    out = {}
    for r in rows:
        if wanted(r[key]):
            out[r[key]] = out.get(r[key], 0) + r["rows"]
    return out


def evaluate(registry, snap, now, drift=None):
    """Findings for one snapshot. `now` is epoch seconds; `drift` is ((prod dashboards, alerts), (exported ...))."""
    findings = []

    def add(rule, service, measured):
        entry = registry.get(service)
        if entry is not None and rule in (entry.get("ignore") or {}):
            return
        findings.append(Finding(rule, service, measured, entry["repo"] if entry else "vps"))

    def live(service):
        entry = registry.get(service)
        return entry if entry is not None and entry.get("status") != "retired" else None

    activity = {}
    for row in snap["activity"]:
        activity.setdefault(row["service"], {})[row["signal"]] = row

    for name in sorted(activity):
        if name not in registry:
            seen = ", ".join(f"{s} {r['rows7d']} rows/7d" for s, r in sorted(activity[name].items()))
            add("unregistered", name, f"not in observability/services.yaml, emits {seen}")

    for name, entry in sorted(registry.items()):
        if not live(name):
            continue
        for sig in expected_signals(entry):
            row = activity.get(name, {}).get(sig)
            if row is None:
                add("silent", name, f"no {sig} in 7 d")
            elif now - row["last"] > SILENCE_HOURS * 3600:
                add("silent", name, f"no {sig} for {fmt_age(now, row['last'])}")

    by_service = {}
    for row in snap["attrs"]:
        by_service.setdefault(row["service"], []).append(row)
    for name, rows in sorted(by_service.items()):
        entry = live(name)
        if not entry:
            continue
        total = sum(r["rows"] for r in rows)
        want_env = entry.get("env", "prod")

        bad_env = tally(rows, "env", lambda e: e not in ENVIRONMENTS)
        wrong_env = tally(rows, "env", lambda e: e in ENVIRONMENTS and e != want_env)
        if bad_env:
            shown = {("<unset>" if e == "" else e): n for e, n in bad_env.items()}
            add("environment", name, f"{top(shown)} of {total} rows (24 h); want exactly prod or dev")
        if wrong_env:
            add("environment", name, f"{top(wrong_env)} of {total} rows (24 h); registry says {want_env}")

        missing_ns = sum(tally(rows, "ns", lambda v: v == "").values())
        if missing_ns:
            add("namespace", name, f"{missing_ns} of {total} rows ({pct(missing_ns, total)}, 24 h) without service.namespace")

        if want_env == "prod":
            bad_ver = tally(rows, "version", lambda v: v == "" or v in BAD_VERSIONS)
            if bad_ver:
                n = sum(bad_ver.values())
                shown = {("<unset>" if v == "" else v): c for v, c in bad_ver.items()}
                add("version", name, f"{top(shown)}: {n} of {total} rows ({pct(n, total)}, 24 h)")

        if entry.get("host") != "client":
            bad_host = tally(rows, "host", lambda h: h == "" or bool(CONTAINER_ID.match(h)))
            if bad_host:
                n = sum(bad_host.values())
                shown = {("<unset>" if h == "" else h): c for h, c in bad_host.items()}
                add("host", name, f"{top(shown)}: {n} of {total} rows ({pct(n, total)}, 24 h)")

    for row in snap["logs"]:
        name, total = row["service"], row["total"]
        entry = live(name)
        if not entry or not total:
            continue
        if row["empty_body"] / total > EMPTY_BODY_SHARE:
            add("body-empty", name, f"{row['empty_body']} of {total} log records ({pct(row['empty_body'], total)}, 24 h) have an empty Body")
        limit = (entry.get("budget") or {}).get("untraced_logs")
        if limit is not None and row["untraced"] / total > limit:
            add("untraced-logs", name, f"{pct(row['untraced'], total)} of {total} logs (24 h) have no TraceId, budget {limit:.0%}")

    for name, sigs in sorted(activity.items()):
        entry = live(name)
        if not entry:
            continue
        for sig in SIGNALS:
            limit = (entry.get("budget") or {}).get(sig)
            row = sigs.get(sig)
            if limit is not None and row and row["rows24h"] > limit:
                add("volume", name, f"{row['rows24h']} {sig} rows in 24 h, budget {limit}/day")

    if drift is not None:
        for i, kind in enumerate(("dashboard", "alert")):
            prod, repo = drift[0][i], drift[1][i]
            for n in sorted(prod - repo):
                add("drift", "observability", f"{kind} {n!r} is in prod, not in observability/ (make hyperdx-export ENV=prod)")
            for n in sorted(repo - prod):
                add("drift", "observability", f"{kind} {n!r} is in observability/, not in prod (make hyperdx-apply ENV=prod)")
    return findings


def summary(findings):
    counts = {rule: 0 for rule in RULES}
    for f in findings:
        counts[f.rule] += 1
    width = max(len(r) for r in RULES)
    lines = [f"{'rule':<{width}}  findings"]
    lines += [f"{r:<{width}}  {n}" for r, n in counts.items()]
    lines.append(f"{'total':<{width}}  {len(findings)}")
    return "\n".join(lines)


def seed_budgets(snap):
    """Seed helper: budget values from the live 7-day averages (3x), printed per service."""
    logs = {r["service"]: r for r in snap["logs"]}
    for row in snap["activity"]:
        if row["signal"] not in SIGNALS:
            continue
        per_day = max(100, 3 * row["rows7d"] / 7)  # a floor: a near-silent service has no meaningful average
        unit = 10 ** max(0, int(math.log10(max(per_day, 1))) - 1)
        extra = ""
        log = logs.get(row["service"])
        if row["signal"] == "logs" and log and log["total"]:
            share = log["untraced"] / log["total"]
            extra = f"  untraced_logs: {min(1.0, math.ceil((share + 0.05) / 0.05) * 0.05):.2f}"
        print(f"{row['service']}\t{row['signal']}: {math.ceil(per_day / unit) * unit}{extra}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Lint the telemetry registry against prod ClickHouse.")
    ap.add_argument("--registry", default=REGISTRY)
    ap.add_argument("--ssh", default=os.environ.get("TELEMETRY_LINT_SSH", "ssh vps"),
                    help="command that reaches the VPS shell (default: ssh vps)")
    ap.add_argument("--no-drift", action="store_true", help="skip the alert/dashboard drift rule")
    ap.add_argument("--seed-budgets", action="store_true",
                    help="print budget values (3x the 7-day daily average) per service and signal, then exit")
    args = ap.parse_args(argv)

    registry = load_registry(args.registry)
    try:
        snap = clickhouse(args.ssh)
        if args.seed_budgets:
            return seed_budgets(snap)
        drift = None if args.no_drift else (hyperdx_names(), exported_names())
    except ProbeError as exc:
        print(f"telemetry-lint: {exc}", file=sys.stderr)
        return 2

    findings = evaluate(registry, snap, datetime.datetime.now(datetime.timezone.utc).timestamp(), drift)
    for f in findings:
        print(f.line())
    if findings:
        print()
    print(summary(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
