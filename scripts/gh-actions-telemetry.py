#!/usr/bin/env python3
"""GitHub Actions telemetry: workflow runs and jobs of every repo of one owner -> ClickStack (OTLP/JSON).

One invocation is one poll tick (the mini's LaunchAgent runs it every minute through jobrun; docs/observability.md ->
"CI telemetry"). Outbound only: no webhook, no listener. State between ticks is one JSON file.

Per tick:
  1. The owner's repos (cached 1 h), each polled with `GET /actions/runs` and an ETag: an unchanged repo answers
     304, which GitHub does not count against the rate limit. A repo without any run is looked at again after 10 min.
  2. A run that completed since the last tick becomes spans: one `run` span (the workflow run), and for each of its
     jobs a `job` span (started -> completed) and a `queue` span (created -> started), all in one trace.
  3. Gauges: `ci.worker.busy` per self-hosted runner (1 while a job of an in-progress run is on it, else 0, so the
     busy share is the average of the gauge), `ci.pipeline.run.active` per repo and state, `ci.poll.repos` heartbeat.

Attribute names follow the OpenTelemetry CI/CD and VCS conventions (`cicd.*`, `vcs.*`); what they do not name is `ci.*`.
Environment (launchd/gh-actions-telemetry.env.tpl resolves the first three through secrets-run): GH_TOKEN (read access to
Actions), DOMAIN (OTLP goes to https://otel.<DOMAIN>, the authed tier; OTEL_EXPORTER_OTLP_ENDPOINT overrides it),
HYPERDX_API_KEY (the ingestion key, sent as the `authorization` header), GH_OWNER (default jkrumm), CI_POLLER_STATE,
CI_POLLER_LOOKBACK_HOURS (default 24), CI_POLLER_VERSION (service.version; default the short git SHA of this checkout).
Exit 0 on a tick that finished (a repo or a jobs call that failed is a warning on stderr and is retried), 1 when GitHub's
list of repos, its rate limit or ClickStack failed (state is kept, the next tick retries), 64 on bad config.
"""

import concurrent.futures
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"
REPO_LIST_TTL = 3600  # seconds the owner's repo list is cached
EMPTY_RECHECK = 600  # a repo with no workflow run is looked at again after this
RUNNER_MEMORY = 30 * 86400  # a runner name stays in the busy gauge this long after its last job
EMITTED_MEMORY = 3 * 86400  # how long a run's key stays in state to keep it from being emitted twice
MAX_RUNS_PER_TICK = 50  # completed runs turned into spans per tick (one jobs call each); the rest wait for the next
MAX_JOB_TRIES = 3  # failed jobs fetches of one run before its run span goes out alone
WORKERS = 8
HTTP_TIMEOUT = 30

QUEUED_STATES = {"queued", "waiting", "requested", "pending"}
RESULTS = {
    "success": "success",
    "failure": "failure",
    "cancelled": "cancellation",
    "timed_out": "timeout",
    "skipped": "skip",
    "startup_failure": "error",
}
SPAN_OK, SPAN_ERROR = 1, 2
ERROR_CONCLUSIONS = {"failure", "timed_out", "startup_failure"}


class RateLimited(Exception):
    """GitHub refused with an exhausted primary or secondary limit."""


# --------------------------------------------------------------------------- pure: payloads -> OTLP


def epoch(iso):
    """GitHub's `2026-11-17T19:23:08Z` as epoch seconds; None for a missing field."""
    if not iso:
        return None
    return datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def nanos(seconds):
    return str(int(seconds * 1_000_000_000))


def hex_id(nbytes, *parts):
    """A deterministic id: the same run or job always gets the same trace and span ids."""
    return hashlib.sha256("#".join(str(p) for p in parts).encode()).hexdigest()[: nbytes * 2]


def attrs(mapping):
    """OTLP key/value list from a dict; None and empty values are dropped."""
    out = []
    for key, value in mapping.items():
        if value is None or value == "":
            continue
        if isinstance(value, bool):
            out.append({"key": key, "value": {"boolValue": value}})
        elif isinstance(value, int):
            out.append({"key": key, "value": {"intValue": str(value)}})
        else:
            out.append({"key": key, "value": {"stringValue": str(value)}})
    return out


def runner_of(job):
    """(kind, runner): `self-hosted` and its registered runner name, or `hosted` (the pool is the runner)."""
    if "self-hosted" in (job.get("labels") or []):
        return "self-hosted", job.get("runner_name") or "self-hosted"
    return "hosted", "github-hosted"


def span(trace_id, span_id, parent, name, start, end, attributes, conclusion=None):
    result = {
        "traceId": trace_id,
        "spanId": span_id,
        "name": name,
        "kind": 1,
        "startTimeUnixNano": nanos(start),
        "endTimeUnixNano": nanos(max(end, start)),
        "attributes": attrs(attributes),
        "status": {},
    }
    if parent:
        result["parentSpanId"] = parent
    if conclusion == "success":
        result["status"] = {"code": SPAN_OK}
    elif conclusion in ERROR_CONCLUSIONS:
        result["status"] = {"code": SPAN_ERROR, "message": conclusion}
    return result


def run_spans(repo, run, jobs):
    """The spans of one completed run attempt: the run, and per job its execution and its time in the queue."""
    owner, name = repo.split("/", 1)
    attempt = run.get("run_attempt") or 1
    trace_id = hex_id(16, repo, run["id"], attempt)
    run_span_id = hex_id(8, repo, run["id"], attempt, "run")
    run_start = epoch(run.get("run_started_at")) or epoch(run.get("created_at"))
    run_end = epoch(run.get("updated_at")) or run_start
    conclusion = run.get("conclusion")
    common = {"vcs.owner.name": owner, "vcs.repository.name": name}
    spans = [
        span(
            trace_id,
            run_span_id,
            None,
            run.get("name") or "workflow",
            run_start,
            run_end,
            {
                **common,
                "ci.kind": "run",
                "cicd.pipeline.name": run.get("name"),
                "cicd.pipeline.run.id": str(run["id"]),
                "cicd.pipeline.result": RESULTS.get(conclusion, conclusion),
                "cicd.pipeline.run.url.full": run.get("html_url"),
                "ci.event": run.get("event"),
                "ci.run.attempt": attempt,
                "vcs.ref.head.name": run.get("head_branch"),
                "vcs.ref.head.revision": run.get("head_sha"),
            },
            conclusion,
        )
    ]
    for job in jobs:
        if job.get("conclusion") == "skipped":
            continue  # never reached a runner
        created, started, completed = epoch(job.get("created_at")), epoch(job.get("started_at")), epoch(job.get("completed_at"))
        kind, runner = runner_of(job)
        job_attrs = {
            **common,
            "cicd.pipeline.name": job.get("workflow_name") or run.get("name"),
            "cicd.pipeline.run.id": str(run["id"]),
            "cicd.pipeline.task.name": job.get("name"),
            "cicd.pipeline.task.run.id": str(job["id"]),
            "cicd.pipeline.task.run.result": RESULTS.get(job.get("conclusion"), job.get("conclusion")),
            "cicd.pipeline.task.run.url.full": job.get("html_url"),
            "cicd.worker.name": job.get("runner_name"),
            "cicd.worker.id": str(job["runner_id"]) if job.get("runner_id") else None,
            "ci.runner": runner,
            "ci.runner.kind": kind,
            "ci.runner.labels": ",".join(job.get("labels") or []),
        }
        job_span_id = hex_id(8, repo, job["id"], "job")
        if started is not None and completed is not None:
            spans.append(
                span(
                    trace_id,
                    job_span_id,
                    run_span_id,
                    job.get("name") or "job",
                    started,
                    completed,
                    {**job_attrs, "ci.kind": "job"},
                    job.get("conclusion"),
                )
            )
        if created is not None and started is not None:
            spans.append(
                span(
                    trace_id,
                    hex_id(8, repo, job["id"], "queue"),
                    run_span_id,
                    "queue",
                    created,
                    started,
                    {**job_attrs, "ci.kind": "queue"},
                )
            )
    return spans


def gauge(name, points, now):
    """One OTLP gauge from (value, attribute dict) pairs, all at `now`."""
    return {
        "name": name,
        "unit": "1",
        "gauge": {"dataPoints": [{"timeUnixNano": nanos(now), "asDouble": float(v), "attributes": attrs(a)} for v, a in points]},
    }


def resource(version):
    return {
        "attributes": attrs(
            {
                "service.name": "ci-poller",
                "service.namespace": "ci",
                "service.version": version,
                "host.name": "mini",
                "deployment.environment.name": "prod",
            }
        )
    }


def traces_payload(spans, version):
    return {"resourceSpans": [{"resource": resource(version), "scopeSpans": [{"scope": {"name": "ci-poller"}, "spans": spans}]}]}


def metrics_payload(metrics, version):
    return {"resourceMetrics": [{"resource": resource(version), "scopeMetrics": [{"scope": {"name": "ci-poller"}, "metrics": metrics}]}]}


# --------------------------------------------------------------------------- the tick


def new_state():
    return {"repo_list": {"at": 0, "names": []}, "repos": {}, "emitted": {}, "runners": {}, "tries": {}, "active_nonzero": []}


def run_key(repo, run):
    return f"{repo}#{run['id']}#{run.get('run_attempt') or 1}"


def paged_jobs(gh, repo, run):
    """Every job of one run attempt (100 per page)."""
    jobs, page = [], 1
    while True:
        _, body, _ = gh(f"/repos/{repo}/actions/runs/{run['id']}/attempts/{run.get('run_attempt') or 1}/jobs?per_page=100&page={page}")
        jobs.extend(body["jobs"])
        if len(body["jobs"]) < 100:
            return jobs
        page += 1


def list_repos(gh, state, owner, now):
    cached = state["repo_list"]
    if cached["names"] and now - cached["at"] < REPO_LIST_TTL:
        return cached["names"]
    names, page = [], 1
    while True:
        _, body, _ = gh(f"/user/repos?affiliation=owner&per_page=100&page={page}")
        names.extend(r["full_name"] for r in body if not r.get("archived") and r["owner"]["login"] == owner)
        if len(body) < 100:
            break
        page += 1
    state["repo_list"] = {"at": now, "names": sorted(names)}
    return state["repo_list"]["names"]


def poll_runs(gh, state, repos, now):
    """GET each due repo's run list in parallel; {repo: (status, body, etag) | Exception}."""

    def one(repo):
        try:
            return gh(f"/repos/{repo}/actions/runs?per_page=100", state["repos"].get(repo, {}).get("etag"))
        except RateLimited:
            raise
        except urllib.error.URLError as err:
            return err  # one repo failing (Actions disabled, a 404) never stops the others

    due = [r for r in repos if state["repos"].get(r, {}).get("next_check", 0) <= now]
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        return dict(zip(due, pool.map(one, due)))


def fetch_all(gh, work):
    """Jobs of many runs in parallel: {key: jobs | Exception}."""

    def one(item):
        key, repo, run = item
        try:
            return key, paged_jobs(gh, repo, run)
        except RateLimited:
            raise
        except urllib.error.URLError as err:
            return key, err

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        return dict(pool.map(one, work))


def tick(cfg, state, gh, post, now):
    """One poll. gh(path, etag=None) -> (status, body, etag); post(signal, payload) sends OTLP. Returns a stats dict."""
    lookback = cfg["lookback_hours"] * 3600
    repos = list_repos(gh, state, cfg["owner"], now)
    stats = {"repos": len(repos), "polled": 0, "runs": 0, "spans": 0, "errors": 0}

    # 1. run lists. A repo's ETag is stored only at the end of the tick (new_etags), once everything it showed went out:
    # a failed post or a deferred run then re-reads the list next tick instead of answering 304 and losing the run.
    todo, new_etags, deferred = [], {}, set()
    for repo, got in poll_runs(gh, state, repos, now).items():
        stats["polled"] += 1
        repo_state = state["repos"].setdefault(repo, {})
        if isinstance(got, Exception):
            stats["errors"] += 1
            repo_state["next_check"] = now + EMPTY_RECHECK
            print(f"warn: {repo}: {got}", file=sys.stderr)
            continue
        status, body, etag = got
        if status == 304:
            if repo_state.get("empty"):
                repo_state["next_check"] = now + EMPTY_RECHECK  # an unchanged empty list waits as long as a new one
            continue  # nothing changed: the cached counts below still stand
        runs = body["workflow_runs"]
        repo_state.update(empty=not runs, next_check=now + EMPTY_RECHECK if not runs else 0, etag=None)
        new_etags[repo] = etag  # an empty list too: its recheck is then a free 304, not a counted read
        repo_state["queued"] = sum(1 for r in runs if r["status"] in QUEUED_STATES)
        repo_state["in_progress"] = [r for r in runs if r["status"] == "in_progress"]
        repo_state["in_progress"] = [{"id": r["id"], "run_attempt": r.get("run_attempt") or 1} for r in repo_state["in_progress"]]
        for run in runs:
            key = run_key(repo, run)
            fresh = (epoch(run.get("updated_at")) or 0) >= now - lookback
            if run["status"] == "completed" and fresh and key not in state["emitted"]:
                todo.append((epoch(run["updated_at"]), key, repo, run))

    # 2. completed runs -> spans (oldest first; what is over the per-tick cap waits, and its repo is re-read next tick)
    todo.sort(key=lambda item: item[0])
    deferred.update(repo for _, _, repo, _ in todo[MAX_RUNS_PER_TICK:])
    todo = todo[:MAX_RUNS_PER_TICK]
    fetched = fetch_all(gh, [(key, repo, run) for _, key, repo, run in todo])
    spans, done = [], []
    for _, key, repo, run in todo:
        jobs = fetched[key]
        if isinstance(jobs, Exception):
            tries = state["tries"][key] = state["tries"].get(key, 0) + 1
            if tries < MAX_JOB_TRIES:
                deferred.add(repo)
                stats["errors"] += 1
                print(f"warn: {key}: jobs {jobs}", file=sys.stderr)
                continue
            jobs = []
        state["tries"].pop(key, None)
        for job in jobs:
            if (job.get("labels") or []) and "self-hosted" in job["labels"] and job.get("runner_name"):
                state["runners"][job["runner_name"]] = {"repo": repo, "seen": now}
        spans.extend(run_spans(repo, run, jobs))
        done.append(key)
    for i in range(0, len(spans), 500):
        post("traces", traces_payload(spans[i : i + 500], cfg["version"]))
    for key in done:
        state["emitted"][key] = now
    stats["runs"], stats["spans"] = len(done), len(spans)
    for repo, etag in new_etags.items():
        if repo not in deferred:
            state["repos"][repo]["etag"] = etag

    # 3. gauges: busy runners (jobs of in-progress runs), active runs per repo, the heartbeat
    live = [(f"{repo}#{r['id']}#{r['run_attempt']}", repo, r) for repo in repos for r in state["repos"].get(repo, {}).get("in_progress", [])]
    busy = {}
    for key, jobs in fetch_all(gh, live).items():
        if isinstance(jobs, Exception):
            continue
        for job in jobs:
            if job.get("status") == "in_progress" and "self-hosted" in (job.get("labels") or []) and job.get("runner_name"):
                repo = key.split("#", 1)[0]
                busy[job["runner_name"]] = repo
                state["runners"][job["runner_name"]] = {"repo": repo, "seen": now}
    points = []
    for name, info in sorted(state["runners"].items()):
        if now - info["seen"] <= RUNNER_MEMORY:
            points.append((1 if name in busy else 0, {"ci.runner.name": name, "vcs.repository.name": info["repo"].split("/", 1)[1]}))
    active, nonzero = [], []
    for repo in repos:
        repo_state = state["repos"].get(repo, {})
        counts = {"pending": repo_state.get("queued", 0), "executing": len(repo_state.get("in_progress", []))}
        for run_state, count in counts.items():
            tag = f"{repo}#{run_state}"
            if count or tag in state["active_nonzero"]:  # one trailing zero when a repo goes quiet, then nothing
                active.append((count, {"vcs.repository.name": repo.split("/", 1)[1], "cicd.pipeline.run.state": run_state}))
            if count:
                nonzero.append(tag)
    state["active_nonzero"] = nonzero
    metrics = [gauge("ci.poll.repos", [(len(repos), {})], now)]
    if points:
        metrics.append(gauge("ci.worker.busy", points, now))
    if active:
        metrics.append(gauge("ci.pipeline.run.active", active, now))
    post("metrics", metrics_payload(metrics, cfg["version"]))

    # 4. forget what is old
    state["emitted"] = {k: t for k, t in state["emitted"].items() if now - t <= lookback + EMITTED_MEMORY}
    return stats


# --------------------------------------------------------------------------- io


def make_gh(token):
    def gh(path, etag=None):
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "vps-ci-poller",
        }
        if etag:
            headers["If-None-Match"] = etag
        try:
            with urllib.request.urlopen(urllib.request.Request(API + path, headers=headers), timeout=HTTP_TIMEOUT) as resp:
                return resp.status, json.load(resp), resp.headers.get("ETag")
        except urllib.error.HTTPError as err:
            if err.code == 304:
                return 304, None, etag
            if err.code in (403, 429) and (err.headers.get("x-ratelimit-remaining") == "0" or err.headers.get("retry-after")):
                raise RateLimited(f"GitHub rate limit (resets {err.headers.get('x-ratelimit-reset')}, retry-after {err.headers.get('retry-after')})")
            raise

    return gh


def make_post(endpoint, headers):
    def post(signal, payload):
        req = urllib.request.Request(
            f"{endpoint.rstrip('/')}/v1/{signal}",
            data=json.dumps(payload).encode(),
            # Cloudflare answers the default Python-urllib agent with 403 (error 1010)
            headers={"Content-Type": "application/json", "User-Agent": "vps-ci-poller", **headers},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            resp.read()

    return post


def load_state(path):
    try:
        with open(path) as f:
            return {**new_state(), **json.load(f)}
    except (FileNotFoundError, json.JSONDecodeError):
        return new_state()


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def checkout_version():
    here = os.path.dirname(os.path.abspath(__file__))
    out = subprocess.run(["git", "-C", here, "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else "unknown"


def main():
    env = os.environ
    endpoint = env.get("OTEL_EXPORTER_OTLP_ENDPOINT") or (f"https://otel.{env['DOMAIN']}" if env.get("DOMAIN") else "")
    missing = [k for k, v in (("GH_TOKEN", env.get("GH_TOKEN")), ("DOMAIN", endpoint), ("HYPERDX_API_KEY", env.get("HYPERDX_API_KEY"))) if not v]
    if missing:
        print(f"gh-actions-telemetry: missing {', '.join(missing)}", file=sys.stderr)
        return 64
    cfg = {
        "owner": env.get("GH_OWNER", "jkrumm"),
        "lookback_hours": float(env.get("CI_POLLER_LOOKBACK_HOURS", "24")),
        "version": env.get("CI_POLLER_VERSION") or checkout_version(),
    }
    state_path = env.get("CI_POLLER_STATE") or os.path.expanduser("~/.local/state/gh-actions-telemetry/state.json")
    state = load_state(state_path)
    gh = make_gh(env["GH_TOKEN"])
    post = make_post(endpoint, {"authorization": env["HYPERDX_API_KEY"]})
    code = 0
    try:
        stats = tick(cfg, state, gh, post, time.time())
        print("tick " + " ".join(f"{k}={v}" for k, v in stats.items()))
    except (RateLimited, urllib.error.URLError, OSError) as err:
        print(f"gh-actions-telemetry: {err}", file=sys.stderr)
        code = 1
    finally:
        save_state(state_path, state)
    return code


if __name__ == "__main__":
    sys.exit(main())
