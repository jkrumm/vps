#!/usr/bin/env python3
"""Daily disk budget check for the VPS root disk (docs/disk.md, config/disk-budget.json).

Steps, each logged on its own line:
  table    the caps must sum under max_pct of the disk, else exit 2 (the table over-commits the disk)
  measure  du -xk per row; the row marked "rest" is df-used minus every other row
  unknown  a path over unknown_gib under scan_roots that no row covers
  status   the table with measured and cap, written to --status
  signal   ONE signal per owner with a row over its cap (refiled every REFILE_DAYS while it stays over)

Signal sink: `factory signal file --repo <owner>` when the factory CLI is on PATH; else an ntfy push on the
`alerts` topic (DOMAIN and NTFY_TOKEN from /etc/vps/disk-watch.env); else the log line says "no sink".

Usage: disk_budget.py [--table] [--budget FILE] [--status FILE] [--state FILE] [--dry]
  --table   only the sum check (what `make check` runs); measures nothing
"""
import argparse
import fnmatch
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BUDGET = os.path.join(HERE, "..", "config", "disk-budget.json")
GIB_KIB = 1024 * 1024
REFILE_DAYS = 7


def log(step, msg):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} disk-budget {step}: {msg}", flush=True)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def commitment(budget):
    """(sum of caps, limit, ok): the table must leave the disk room to breathe."""
    total = sum(r["cap_gib"] for r in budget["rows"])
    limit = budget["disk_gib"] * budget["max_pct"] / 100
    return total, limit, total < limit


def du_kib(path):
    """KiB under one path, 0 when it is gone; same-filesystem only, like the alert's df."""
    out = subprocess.run(["du", "-xsk", path], capture_output=True, text=True, check=False)
    first = out.stdout.split("\t", 1)[0].strip()
    return int(first) if first.isdigit() else 0


def expand(paths):
    found = []
    for p in paths:
        found.extend(sorted(glob.glob(p)) if any(c in p for c in "*?[") else [p])
    return found


def disk_used_kib():
    st = os.statvfs("/")
    return (st.f_blocks - st.f_bfree) * st.f_frsize // 1024


def measure(budget, du=du_kib, used_kib=disk_used_kib):
    """Rows with measured_gib; the 'rest' row is whatever the others do not explain."""
    rows, explained = [], 0
    for row in budget["rows"]:
        kib = None if row.get("rest") else sum(du(p) for p in expand(row["paths"]) if os.path.lexists(p))
        explained += kib or 0
        rows.append({**row, "measured_kib": kib})
    for r in rows:
        if r["measured_kib"] is None:
            r["measured_kib"] = max(0, used_kib() - explained)
        r["measured_gib"] = round(r.pop("measured_kib") / GIB_KIB, 2)
        r["over"] = r["measured_gib"] > r["cap_gib"]
    return rows


def covered(path, budget):
    """True when a row's path is this path, inside it, or contains it."""
    for row in budget["rows"]:
        for pat in row["paths"]:
            base = pat.rstrip("/")
            if fnmatch.fnmatch(path, base) or base.startswith(path + "/") or path.startswith(base + "/"):
                return True
    return False


def unknown_growth(budget, du=du_kib, listdir=os.listdir):
    """Top-level entries of the scan roots over unknown_gib that no row covers."""
    found = []
    for root in budget.get("scan_roots", []):
        try:
            names = listdir(root)
        except OSError:
            continue
        for name in sorted(names):
            path = os.path.join(root, name)
            if os.path.islink(path) or covered(path, budget):
                continue
            gib = du(path) / GIB_KIB
            if gib > budget["unknown_gib"]:
                found.append({"path": path, "gib": round(gib, 2)})
    return found


def ntfy_push(title, text):
    domain, token = os.environ.get("DOMAIN"), os.environ.get("NTFY_TOKEN")
    if not domain or not token:
        return False
    req = urllib.request.Request(
        os.environ.get("DISK_BUDGET_NTFY_URL", f"https://ntfy.{domain}/alerts"),
        data=text.encode(),
        headers={"Authorization": f"Bearer {token}", "Title": title, "Tags": "floppy_disk,warning"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=15).close()
    return True


def file_signal(owner, title, text):
    """'filed' | 'pushed' | 'no sink'. Raises on a failed delivery, so the state is not written."""
    factory = os.environ.get("DISK_BUDGET_FACTORY", "factory")
    if shutil.which(factory):
        subprocess.run(
            [factory, "signal", "file", "--from", "agent:vps", "--repo", owner, "--title", title, "--text", text],
            check=True, capture_output=True, timeout=60,
        )
        return "filed"
    return "pushed" if ntfy_push(title, text) else "no sink"


def signal_owners(rows, state, now, dry=False, send=file_signal):
    """One signal per owner over a cap; returns the new state (owner -> last filed epoch)."""
    by_owner = {}
    for r in rows:
        if r["over"]:
            by_owner.setdefault(r["owner"], []).append(r)
    for owner, over in sorted(by_owner.items()):
        if now - state.get(owner, 0) < REFILE_DAYS * 86400:
            log("signal", f"{owner}: over cap, filed within {REFILE_DAYS} days, skipped")
            continue
        lines = [f"{r['id']} ({', '.join(r['paths']) or 'rest of the disk'}): {r['measured_gib']} GiB, cap {r['cap_gib']} GiB, held by: {r['enforced_by']}" for r in over]
        title = f"VPS disk budget: {', '.join(r['id'] for r in over)} over cap"
        text = "Measured by scripts/disk_budget.py in the vps repo (docs/disk.md has the table).\n" + "\n".join(lines)
        if dry:
            log("signal", f"{owner}: would file: {title}")
            continue
        try:
            how = send(owner, title, text)
        except Exception as exc:  # a failed delivery is retried tomorrow, not remembered
            log("signal", f"{owner}: FAILED {exc}")
            continue
        log("signal", f"{owner}: {how}: {title}")
        if how != "no sink":
            state[owner] = now
    return state


def read_state(path):
    try:
        return load(path)
    except (OSError, ValueError):
        return {}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", default=DEFAULT_BUDGET)
    ap.add_argument("--status", default="/var/tmp/disk-budget.json")
    ap.add_argument("--state", default="/var/tmp/disk-budget.state.json")
    ap.add_argument("--table", action="store_true")
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args(argv)

    budget = load(args.budget)
    total, limit, ok = commitment(budget)
    log("table", f"caps sum {total} GiB, limit {limit:g} GiB ({budget['max_pct']} % of {budget['disk_gib']} GiB): {'ok' if ok else 'OVER-COMMITTED'}")
    if not ok:
        return 2
    if args.table:
        return 0

    rows = measure(budget)
    for r in rows:
        log("measure", f"{r['id']}: {r['measured_gib']} GiB of {r['cap_gib']}{' OVER' if r['over'] else ''} ({r['owner']})")
    unknown = unknown_growth(budget)
    for u in unknown:
        log("unknown", f"{u['path']}: {u['gib']} GiB, no row covers it")
    status = {"at": int(time.time()), "caps_gib": total, "limit_gib": limit, "rows": rows, "unknown": unknown}
    if not args.dry:
        with open(args.status, "w", encoding="utf-8") as f:
            json.dump(status, f, indent=2)
    log("status", f"{sum(r['over'] for r in rows)} row(s) over cap, {len(unknown)} unknown path(s), written to {args.status}")

    now = int(time.time())
    # an uncovered path has no owner yet: it is this repo's, as one more over-cap row
    unowned = [{"id": f"unknown:{os.path.basename(u['path'])}", "paths": [u["path"]], "owner": "vps", "measured_gib": u["gib"], "cap_gib": budget["unknown_gib"],
                "enforced_by": "no row covers it: add one to config/disk-budget.json", "over": True} for u in unknown]
    state = signal_owners(rows + unowned, read_state(args.state), now, dry=args.dry)
    if not args.dry:
        with open(args.state, "w", encoding="utf-8") as f:
            json.dump(state, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
