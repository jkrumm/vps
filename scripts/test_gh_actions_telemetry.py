"""Tests of scripts/gh-actions-telemetry.py through its two ports: a fake GitHub and a recording OTLP sink."""

import importlib.util
import os
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ghat", os.path.join(HERE, "gh-actions-telemetry.py"))
ghat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ghat)

NOW = ghat.epoch("2026-11-17T20:00:00Z")
CFG = {"owner": "jkrumm", "lookback_hours": 24, "version": "abc1234"}


def run(run_id, status="completed", conclusion="success", updated="2026-11-17T19:25:23Z", name="ci", attempt=1):
    return {
        "id": run_id,
        "name": name,
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "event": "push",
        "head_branch": "master",
        "head_sha": "deadbeef",
        "run_attempt": attempt,
        "created_at": "2026-11-17T19:23:08Z",
        "run_started_at": "2026-11-17T19:23:08Z",
        "updated_at": updated,
        "html_url": f"https://github.com/jkrumm/rb/actions/runs/{run_id}",
    }


def job(job_id, labels=("self-hosted", "vps"), runner="vps-rb", status="completed", conclusion="success"):
    return {
        "id": job_id,
        "name": "check",
        "workflow_name": "ci",
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "created_at": "2026-11-17T19:23:09Z",
        "started_at": "2026-11-17T19:23:19Z",
        "completed_at": "2026-11-17T19:25:22Z" if status == "completed" else None,
        "labels": list(labels),
        "runner_id": 22,
        "runner_name": runner,
        "html_url": f"https://github.com/jkrumm/rb/actions/runs/1/job/{job_id}",
    }


class FakeGitHub:
    """GET handler: repos {full_name: runs}, jobs {run_id: [job]}; serves ETags and 304s like the real API."""

    def __init__(self, repos, jobs):
        self.repos, self.jobs, self.calls, self.version = repos, jobs, [], 1

    def __call__(self, path, etag=None):
        self.calls.append(path)
        if path.startswith("/user/repos"):
            return 200, [{"full_name": n, "archived": False, "owner": {"login": "jkrumm"}} for n in self.repos], None
        if "/actions/runs?" in path:
            repo = path.split("/repos/")[1].split("/actions")[0]
            if repo == "jkrumm/broken":
                raise urllib.error.HTTPError(path, 404, "not found", {}, None)
            tag = f'W/"{repo}-{self.version}"'
            if etag == tag:
                return 304, None, etag
            runs = self.repos[repo]
            return 200, {"total_count": len(runs), "workflow_runs": runs}, tag
        if "/jobs" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return 200, {"jobs": self.jobs.get(run_id, [])}, None
        raise AssertionError(path)


class Sink:
    def __init__(self):
        self.sent = []

    def __call__(self, signal, payload):
        self.sent.append((signal, payload))

    def spans(self):
        return [s for sig, p in self.sent if sig == "traces" for s in p["resourceSpans"][0]["scopeSpans"][0]["spans"]]

    def gauges(self):
        out = {}
        for sig, p in self.sent:
            if sig == "metrics":
                for m in p["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]:
                    out[m["name"]] = m["gauge"]["dataPoints"]
        return out


def attr(span_or_point, key):
    for kv in span_or_point["attributes"]:
        if kv["key"] == key:
            return next(iter(kv["value"].values()))
    return None


class RunSpans(unittest.TestCase):
    def test_run_job_and_queue_spans_share_one_trace(self):
        spans = ghat.run_spans("jkrumm/rb", run(1), [job(11)])
        self.assertEqual([attr(s, "ci.kind") for s in spans], ["run", "job", "queue"])
        self.assertEqual(len({s["traceId"] for s in spans}), 1)
        run_span, job_span, queue_span = spans
        self.assertEqual(job_span["parentSpanId"], run_span["spanId"])
        self.assertEqual(queue_span["parentSpanId"], run_span["spanId"])
        # queue: created 19:23:09 -> started 19:23:19 = 10 s; job: 19:23:19 -> 19:25:22 = 123 s
        self.assertEqual(int(queue_span["endTimeUnixNano"]) - int(queue_span["startTimeUnixNano"]), 10_000_000_000)
        self.assertEqual(int(job_span["endTimeUnixNano"]) - int(job_span["startTimeUnixNano"]), 123_000_000_000)
        self.assertEqual(attr(job_span, "ci.runner"), "vps-rb")
        self.assertEqual(attr(job_span, "ci.runner.kind"), "self-hosted")
        self.assertEqual(attr(run_span, "vcs.repository.name"), "rb")
        self.assertEqual(attr(run_span, "cicd.pipeline.result"), "success")

    def test_ids_are_deterministic(self):
        a = ghat.run_spans("jkrumm/rb", run(1), [job(11)])
        b = ghat.run_spans("jkrumm/rb", run(1), [job(11)])
        self.assertEqual([(s["traceId"], s["spanId"]) for s in a], [(s["traceId"], s["spanId"]) for s in b])
        self.assertNotEqual(a[0]["traceId"], ghat.run_spans("jkrumm/rb", run(1, attempt=2), [job(11)])[0]["traceId"])

    def test_failure_is_an_error_span_and_hosted_runners_collapse_to_one_name(self):
        spans = ghat.run_spans("jkrumm/vps", run(2, conclusion="failure"), [job(21, ("ubuntu-latest",), "GitHub Actions 1000012345", conclusion="failure")])
        self.assertEqual(spans[0]["status"]["code"], ghat.SPAN_ERROR)
        self.assertEqual(attr(spans[1], "ci.runner"), "github-hosted")
        self.assertEqual(attr(spans[1], "ci.runner.kind"), "hosted")
        self.assertEqual(attr(spans[1], "cicd.worker.name"), "GitHub Actions 1000012345")

    def test_a_skipped_job_has_no_spans_and_a_cancelled_job_without_start_has_no_job_span(self):
        skipped = {**job(31), "conclusion": "skipped"}
        cancelled = {**job(32), "conclusion": "cancelled", "started_at": None}
        spans = ghat.run_spans("jkrumm/rb", run(3, conclusion="cancelled"), [skipped, cancelled])
        self.assertEqual([attr(s, "ci.kind") for s in spans], ["run"])
        self.assertEqual(attr(spans[0], "cicd.pipeline.result"), "cancellation")


class Tick(unittest.TestCase):
    def setUp(self):
        self.gh = FakeGitHub(
            {
                "jkrumm/rb": [run(1), run(2, status="in_progress", updated="2026-11-17T19:59:00Z"), run(3, status="queued", updated="2026-11-17T19:59:30Z")],
                "jkrumm/empty": [],
                "jkrumm/broken": [],
            },
            {1: [job(11)], 2: [job(21, status="in_progress", runner="vps-rb")]},
        )
        self.sink, self.state = Sink(), ghat.new_state()

    def tick(self, now=NOW):
        return ghat.tick(CFG, self.state, self.gh, self.sink, now)

    def test_first_tick_emits_the_completed_run_and_the_gauges(self):
        stats = self.tick()
        self.assertEqual((stats["runs"], stats["spans"]), (1, 3))
        busy = self.sink.gauges()["ci.worker.busy"]
        self.assertEqual([(p["asDouble"], attr(p, "ci.runner.name")) for p in busy], [(1.0, "vps-rb")])
        active = {attr(p, "cicd.pipeline.run.state"): p["asDouble"] for p in self.sink.gauges()["ci.pipeline.run.active"]}
        self.assertEqual(active, {"pending": 1.0, "executing": 1.0})
        self.assertEqual(self.sink.gauges()["ci.poll.repos"][0]["asDouble"], 3.0)

    def test_a_run_is_never_emitted_twice(self):
        self.tick()
        self.gh.version += 1  # the run list changed (new ETag), the completed run is still in it
        stats = self.tick(NOW + 60)
        self.assertEqual(stats["runs"], 0)
        self.assertEqual(len(self.sink.spans()), 3)

    def test_unchanged_repo_costs_a_304_and_keeps_the_gauges(self):
        self.tick()
        self.gh.calls.clear()
        self.tick(NOW + 60)
        list_calls = [c for c in self.gh.calls if "/actions/runs?" in c]
        self.assertIn("/repos/jkrumm/rb/actions/runs?per_page=100", list_calls)
        self.assertEqual(len([c for c in self.gh.calls if "/jobs" in c]), 1)  # only the in-progress run's jobs
        self.assertEqual(self.sink.gauges()["ci.worker.busy"][0]["asDouble"], 1.0)

    def test_an_empty_or_failing_repo_is_looked_at_again_after_ten_minutes_not_every_tick(self):
        self.tick()
        self.gh.calls.clear()
        self.tick(NOW + 60)
        self.assertFalse([c for c in self.gh.calls if "empty" in c or "broken" in c])
        self.gh.calls.clear()
        self.tick(NOW + ghat.EMPTY_RECHECK + 1)
        self.assertTrue([c for c in self.gh.calls if "empty" in c])

    def test_busy_runner_reads_zero_once_idle_and_a_quiet_repo_gets_one_trailing_zero(self):
        self.tick()
        self.gh.repos["jkrumm/rb"] = [run(1), run(2)]
        self.gh.version += 1
        self.tick(NOW + 60)
        self.assertEqual(self.sink.gauges()["ci.worker.busy"][0]["asDouble"], 0.0)
        self.assertEqual({p["asDouble"] for p in self.sink.gauges()["ci.pipeline.run.active"]}, {0.0})
        self.tick(NOW + 120)
        last = {m["name"] for m in self.sink.sent[-1][1]["resourceMetrics"][0]["scopeMetrics"][0]["metrics"]}
        self.assertNotIn("ci.pipeline.run.active", last)

    def test_runs_older_than_the_lookback_are_not_backfilled(self):
        self.gh.repos["jkrumm/rb"] = [run(1, updated="2026-11-15T19:25:23Z")]
        self.assertEqual(self.tick()["runs"], 0)

    def test_the_per_tick_cap_defers_the_rest_to_the_next_tick(self):
        runs = [run(100 + i, updated=f"2026-11-17T18:{i % 60:02d}:00Z") for i in range(ghat.MAX_RUNS_PER_TICK + 5)]
        self.gh.repos["jkrumm/rb"] = runs
        self.assertEqual(self.tick()["runs"], ghat.MAX_RUNS_PER_TICK)
        self.assertEqual(self.tick(NOW + 60)["runs"], 5)  # same ETag, but the cap dropped it

    def test_a_failed_post_leaves_the_run_unemitted_for_the_next_tick(self):
        def broken(signal, payload):
            raise urllib.error.URLError("clickstack down")

        with self.assertRaises(urllib.error.URLError):
            ghat.tick(CFG, self.state, self.gh, broken, NOW)
        self.assertEqual(self.state["emitted"], {})
        self.assertEqual(self.tick(NOW + 60)["runs"], 1)

    def test_a_jobs_failure_retries_then_emits_the_run_alone(self):
        original = self.gh.__call__

        def flaky(path, etag=None):
            if "/runs/1/attempts" in path:
                raise urllib.error.HTTPError(path, 500, "boom", {}, None)
            return original(path, etag)

        for i in range(ghat.MAX_JOB_TRIES - 1):
            self.assertEqual(ghat.tick(CFG, self.state, flaky, self.sink, NOW + i)["runs"], 0)
        self.assertEqual(ghat.tick(CFG, self.state, flaky, self.sink, NOW + 10)["spans"], 1)


if __name__ == "__main__":
    unittest.main()
