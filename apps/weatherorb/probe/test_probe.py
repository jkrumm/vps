"""Tests for the /v1 availability probe. Stdlib only: `python3 -m unittest` from this directory."""

import contextlib
import io
import json
import os
import random
import socket
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import probe

KEY = "wo_abcdef012345_TOPSECRETKEYMATERIAL0123456789"
GOOD_BODY = json.dumps({"latitude": 1.0, "time": ["2026-10-17T08:00Z"], "variables": {"temperature_2m": {}}})


class FakeServer:
    """A loopback HTTP server whose answer is whatever `respond(handler)` does; records every request."""

    def __init__(self, respond):
        self.requests: list[dict] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: ANN002
                pass

            def handle_any(self):
                length = int(self.headers.get("Content-Length") or 0)
                outer.requests.append(
                    {
                        "method": self.command,
                        "path": self.path,
                        "headers": {k.lower(): v for k, v in self.headers.items()},
                        "body": self.rfile.read(length) if length else b"",
                    }
                )
                respond(self)

            do_GET = do_POST = handle_any

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def reply(handler, status=200, body=GOOD_BODY, headers=None):
    data = body.encode() if isinstance(body, str) else body
    handler.send_response(status)
    for name, value in (headers or {}).items():
        handler.send_header(name, value)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def dead_url() -> str:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return f"http://127.0.0.1:{s.getsockname()[1]}"


class ServerCase(unittest.TestCase):
    def serve(self, respond) -> FakeServer:
        server = FakeServer(respond)
        self.addCleanup(server.close)
        return server

    def probe(self, server_url: str, timeout: float = 3.0) -> probe.Result:
        return probe.probe_once(server_url, KEY, random.Random(7), "a" * 32, "b" * 16, timeout)


class ClassifyTest(unittest.TestCase):
    def test_good(self):
        self.assertEqual(probe.classify(200, GOOD_BODY.encode()), "")

    def test_http_status(self):
        self.assertEqual(probe.classify(502, b"whatever"), "http 502")
        self.assertEqual(probe.classify(429, GOOD_BODY.encode()), "http 429")

    def test_bad_json(self):
        self.assertEqual(probe.classify(200, b"<html>"), "bad json")
        self.assertEqual(probe.classify(200, b""), "bad json")
        self.assertEqual(probe.classify(200, b"[1, 2]"), "bad json")

    def test_missing_keys(self):
        self.assertEqual(probe.classify(200, b'{"variables": {}}'), "missing time")
        self.assertEqual(probe.classify(200, b'{"time": []}'), "missing variables")


class ProbeOnceTest(ServerCase):
    def test_good_probe_and_request_shape(self):
        server = self.serve(lambda h: reply(h))
        result = self.probe(server.url)
        self.assertTrue(result.ok)
        self.assertEqual((result.status, result.reason), (200, ""))
        self.assertGreaterEqual(result.end_ns, result.start_ns)

        (request,) = server.requests
        split = urlsplit(request["path"])
        self.assertEqual(split.path, "/v1/pointcast")
        query = parse_qs(split.query)
        self.assertEqual(set(query), {"lat", "lon", "hours"})
        self.assertEqual(query["hours"], ["24"])
        lat, lon = query["lat"][0], query["lon"][0]
        self.assertTrue(-60 <= float(lat) <= 70 and -180 <= float(lon) <= 180)
        for value in (lat, lon):
            self.assertLessEqual(len(value.partition(".")[2]), 2)
        headers = request["headers"]
        self.assertEqual(headers["authorization"], f"Bearer {KEY}")
        self.assertEqual(headers["user-agent"], "weatherorb-probe/1")
        self.assertEqual(headers["traceparent"], f"00-{'a' * 32}-{'b' * 16}-01")

    def test_points_vary(self):
        rng = random.Random()
        points = {probe.random_point(rng) for _ in range(50)}
        self.assertGreater(len(points), 40)
        for lat, lon in points:
            self.assertTrue(-60 <= lat <= 70 and -180 <= lon <= 180)

    def test_http_error(self):
        server = self.serve(lambda h: reply(h, 502, "bad gateway"))
        result = self.probe(server.url)
        self.assertEqual((result.ok, result.status, result.reason), (False, 502, "http 502"))

    def test_rate_limited(self):
        server = self.serve(lambda h: reply(h, 429, '{"error": "slow down"}'))
        self.assertEqual(self.probe(server.url).reason, "http 429")

    def test_bad_json(self):
        server = self.serve(lambda h: reply(h, 200, "not json"))
        result = self.probe(server.url)
        self.assertEqual((result.ok, result.status, result.reason), (False, 200, "bad json"))

    def test_missing_time(self):
        server = self.serve(lambda h: reply(h, 200, '{"variables": {}}'))
        self.assertEqual(self.probe(server.url).reason, "missing time")

    def test_timeout(self):
        release = threading.Event()
        self.addCleanup(release.set)
        server = self.serve(lambda h: release.wait(5))
        started = time.monotonic()
        result = self.probe(server.url, timeout=0.3)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual((result.ok, result.status, result.reason), (False, 0, "timeout"))

    def test_slow_drip_hits_the_total_deadline(self):
        def drip(handler):
            handler.send_response(200)
            handler.send_header("Content-Length", "1000")
            handler.end_headers()
            with contextlib.suppress(OSError):
                for _ in range(20):
                    handler.wfile.write(b" ")
                    handler.wfile.flush()
                    time.sleep(0.1)

        server = self.serve(drip)
        started = time.monotonic()
        result = self.probe(server.url, timeout=0.5)
        self.assertLess(time.monotonic() - started, 1.8)
        self.assertEqual(result.reason, "timeout")

    def test_connection_refused_names_the_class(self):
        result = self.probe(dead_url())
        self.assertEqual((result.ok, result.status, result.reason), (False, 0, "ConnectionRefusedError"))

    def test_redirect_is_not_followed(self):
        target = self.serve(lambda h: reply(h))
        server = self.serve(lambda h: reply(h, 302, "", {"Location": target.url + "/elsewhere"}))
        result = self.probe(server.url)
        self.assertEqual(result.reason, "http 302")
        self.assertEqual(target.requests, [])


class PayloadTest(unittest.TestCase):
    def span_of(self, payload):
        (resource_spans,) = payload["resourceSpans"]
        (scope_spans,) = resource_spans["scopeSpans"]
        (span,) = scope_spans["spans"]
        return resource_spans["resource"], span

    @staticmethod
    def attrs(attributes):
        return {a["key"]: a["value"] for a in attributes}

    def test_good_span(self):
        result = probe.Result(True, 200, "", 1_700_000_000_000_000_000, 1_700_000_000_312_000_000)
        trace_id, span_id = "0123456789abcdef" * 2, "0123456789abcdef"
        resource, span = self.span_of(probe.build_payload(result, trace_id, span_id, "https://weatherorb.com"))

        self.assertEqual(
            self.attrs(resource["attributes"]),
            {
                "service.name": {"stringValue": "weatherorb-probe"},
                "service.namespace": {"stringValue": "weatherorb"},
                "deployment.environment": {"stringValue": "production"},
            },
        )
        self.assertEqual(span["name"], "probe v1_pointcast")
        self.assertEqual(span["kind"], 3)
        self.assertEqual((span["traceId"], span["spanId"]), (trace_id, span_id))
        self.assertEqual(span["startTimeUnixNano"], "1700000000000000000")
        self.assertEqual(span["endTimeUnixNano"], "1700000000312000000")
        self.assertEqual(span["status"], {"code": 0})
        self.assertEqual(
            self.attrs(span["attributes"]),
            {
                "http.status_code": {"intValue": "200"},
                "weatherorb.route_class": {"stringValue": "v1_pointcast"},
                "weatherorb.probe.ok": {"boolValue": True},
                "http.url": {"stringValue": "https://weatherorb.com/v1/pointcast"},
            },
        )

    def test_bad_span(self):
        result = probe.Result(False, 0, "timeout", 10, 20)
        _, span = self.span_of(probe.build_payload(result, "c" * 32, "d" * 16, "https://weatherorb.com"))
        self.assertEqual(span["status"], {"code": 2, "message": "timeout"})
        attributes = self.attrs(span["attributes"])
        self.assertNotIn("http.status_code", attributes)
        self.assertEqual(attributes["weatherorb.probe.ok"], {"boolValue": False})
        self.assertEqual(attributes["weatherorb.probe.error"], {"stringValue": "timeout"})

    def test_url_has_no_query(self):
        result = probe.Result(True, 200, "", 1, 2)
        _, span = self.span_of(probe.build_payload(result, "a" * 32, "b" * 16, "https://example.com/"))
        self.assertEqual(self.attrs(span["attributes"])["http.url"], {"stringValue": "https://example.com/v1/pointcast"})

    def test_roundtrip_to_collector(self):
        collector = FakeServer(lambda h: reply(h, 200, "{}"))
        self.addCleanup(collector.close)
        result = probe.Result(True, 200, "", 1, 2)
        payload = probe.build_payload(result, "a" * 32, "b" * 16, "https://weatherorb.com")
        self.assertEqual(probe.export_span(collector.url, payload), "")
        (request,) = collector.requests
        self.assertEqual(request["method"], "POST")
        self.assertEqual(request["path"], "/v1/traces")
        self.assertEqual(request["headers"]["content-type"], "application/json")
        self.assertEqual(json.loads(request["body"]), payload)

    def test_export_drain_is_bounded_against_a_trickling_body(self):
        release = threading.Event()
        self.addCleanup(release.set)

        def trickle(handler):
            handler.send_response(200)
            handler.send_header("Transfer-Encoding", "chunked")
            handler.end_headers()
            with contextlib.suppress(OSError):
                while not release.is_set():
                    handler.wfile.write(b"1\r\n.\r\n")
                    handler.wfile.flush()
                    time.sleep(0.1)

        collector = FakeServer(trickle)
        self.addCleanup(collector.close)
        payload = probe.build_payload(probe.Result(True, 200, "", 1, 2), "a" * 32, "b" * 16, "https://weatherorb.com")
        started = time.monotonic()
        self.assertEqual(probe.export_span(collector.url, payload, timeout=0.5), "")
        self.assertLess(time.monotonic() - started, 1.5)

    def test_export_failures_are_described_not_raised(self):
        result = probe.Result(True, 200, "", 1, 2)
        payload = probe.build_payload(result, "a" * 32, "b" * 16, "https://weatherorb.com")
        self.assertEqual(probe.export_span(dead_url(), payload), "ConnectionRefusedError")
        broken = FakeServer(lambda h: reply(h, 503, "no"))
        self.addCleanup(broken.close)
        self.assertEqual(probe.export_span(broken.url, payload), "http 503")


class KeyFileTest(unittest.TestCase):
    def write(self, content: str) -> str:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = os.path.join(directory.name, "key")
        Path(path).write_text(content)
        return path

    def test_reads_and_strips(self):
        self.assertEqual(probe.load_key(self.write(f"  {KEY}\n")), KEY)

    def test_missing_empty_and_blank_are_refused(self):
        with self.assertRaisesRegex(probe.ConfigError, "does not exist"):
            probe.load_key("/nonexistent/probe_key")
        with self.assertRaisesRegex(probe.ConfigError, "is empty"):
            probe.load_key(self.write(""))
        with self.assertRaisesRegex(probe.ConfigError, "is empty"):
            probe.load_key(self.write(" \n\n"))

    def test_directory_is_refused(self):
        with self.assertRaisesRegex(probe.ConfigError, "unreadable"):
            probe.load_key(tempfile.gettempdir())

    def test_multiline_key_is_refused(self):
        with self.assertRaisesRegex(probe.ConfigError, "single-line"):
            probe.load_key(self.write("wo_a\nX-Injected: 1\n"))

    def test_main_refuses_to_start_without_a_key(self):
        for env in ({"PROBE_KEY_FILE": "/nonexistent/probe_key"}, {}):
            err = io.StringIO()
            called = []
            with contextlib.redirect_stderr(err):
                code = probe.main(
                    env, fail_closed_sleep=0, install_signals=False, runner=lambda *a, **k: called.append(1) or 0
                )
            self.assertEqual(code, 2)
            self.assertEqual(called, [])
            self.assertIn("does not exist", err.getvalue())
            self.assertIn("WEATHERORB_PROBE_KEY_FILE", err.getvalue())

    def test_main_refuses_a_key_over_cleartext(self):
        path = self.write(KEY + "\n")
        for url in ("http://weatherorb.com", "http://192.0.2.1:8080", "ftp://127.0.0.1", "weatherorb.com", "https://"):
            err = io.StringIO()
            called = []
            with contextlib.redirect_stderr(err):
                code = probe.main(
                    {"PROBE_KEY_FILE": path, "PROBE_BASE_URL": url},
                    fail_closed_sleep=0,
                    install_signals=False,
                    runner=lambda *a, **k: called.append(1) or 0,
                )
            self.assertEqual((code, called), (2, []), url)
            self.assertIn("PROBE_BASE_URL must be https", err.getvalue())
            self.assertNotIn(KEY, err.getvalue())

    def test_main_accepts_https_and_loopback_http(self):
        path = self.write(KEY + "\n")
        for url in ("https://weatherorb.com", "http://127.0.0.1:8082", "http://localhost", "http://[::1]:8082"):
            called = []
            with contextlib.redirect_stdout(io.StringIO()):
                code = probe.main(
                    {"PROBE_KEY_FILE": path, "PROBE_BASE_URL": url},
                    install_signals=False,
                    runner=lambda *a, **k: called.append(1) or 0,
                )
            self.assertEqual((code, called), (0, [1]), url)

    def test_main_fail_closed_waits_before_exiting(self):
        started = time.monotonic()
        with contextlib.redirect_stderr(io.StringIO()):
            probe.main({"PROBE_KEY_FILE": "/nonexistent"}, fail_closed_sleep=0.3, install_signals=False)
        self.assertGreaterEqual(time.monotonic() - started, 0.25)

    def test_main_hands_the_key_to_the_loop(self):
        path = self.write(KEY + "\n")
        seen = {}

        def runner(key, base_url, otlp, alive, stop):
            seen.update(key=key, base_url=base_url, otlp=otlp, alive=alive)
            return 0

        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = probe.main({"PROBE_KEY_FILE": path}, install_signals=False, runner=runner)
        self.assertEqual(code, 0)
        self.assertEqual(seen["key"], KEY)
        self.assertEqual(seen["base_url"], "https://weatherorb.com")
        self.assertEqual(seen["otlp"], "http://clickstack:4319")
        self.assertEqual(seen["alive"], "/tmp/probe-alive")
        self.assertNotIn(KEY, out.getvalue())


class LoopTest(ServerCase):
    def run_loop(self, edge_url: str, otlp_url: str, probes: int = 2):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        alive = os.path.join(directory.name, "alive")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = probe.run(
                KEY, edge_url, otlp_url, alive, threading.Event(), max_probes=probes, period=0.1, align=False, timeout=1
            )
        return code, out.getvalue(), err.getvalue(), alive

    def test_loop_logs_exports_and_touches(self):
        edge = self.serve(lambda h: reply(h))
        collector = self.serve(lambda h: reply(h, 200, "{}"))
        code, out, err, alive = self.run_loop(edge.url, collector.url)

        self.assertEqual(code, 0)
        lines = out.splitlines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertRegex(line, r"^ok 200 \d+ms$")
        self.assertEqual(err, "")
        self.assertTrue(os.path.exists(alive))
        self.assertLess(time.time() - os.stat(alive).st_mtime, 5)
        self.assertEqual(len(collector.requests), 2)

        # The edge span joins the trace through the traceparent the probe sent.
        for edge_request, export in zip(edge.requests, collector.requests, strict=True):
            span = json.loads(export["body"])["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
            self.assertRegex(span["traceId"], r"^[0-9a-f]{32}$")
            self.assertRegex(span["spanId"], r"^[0-9a-f]{16}$")
            self.assertEqual(edge_request["headers"]["traceparent"], f"00-{span['traceId']}-{span['spanId']}-01")

    def test_bad_probe_line_and_dead_collector_do_not_stop_the_loop(self):
        edge = self.serve(lambda h: reply(h, 502, "nope"))
        code, out, err, _ = self.run_loop(edge.url, dead_url())
        self.assertEqual(code, 0)
        self.assertEqual(len(out.splitlines()), 2)
        for line in out.splitlines():
            self.assertRegex(line, r"^bad http 502 \d+ms$")
        self.assertEqual(len(err.splitlines()), 2)
        self.assertIn("span export failed (ConnectionRefusedError)", err)

    def test_key_never_appears_in_logs_or_spans(self):
        cases = (
            lambda h: reply(h),
            lambda h: reply(h, 502, "echo " + h.headers["Authorization"]),  # an origin that reflects the key
            lambda h: reply(h, 200, "not json"),
        )
        for respond in cases:
            edge = self.serve(respond)
            collector = self.serve(lambda h: reply(h, 200, "{}"))
            _, out, err, _ = self.run_loop(edge.url, collector.url, probes=1)
            secret = KEY.split("_")[-1]
            for text in (out, err, *(r["body"].decode() for r in collector.requests)):
                self.assertNotIn(KEY, text)
                self.assertNotIn(secret, text)

        # ... and a dead edge, whose exception text is the only thing logged
        _, out, err, _ = self.run_loop(dead_url(), dead_url(), probes=1)
        self.assertNotIn(KEY, out + err)

    def test_stop_event_ends_the_loop(self):
        stop = threading.Event()
        stop.set()
        self.assertEqual(
            probe.run(KEY, "http://127.0.0.1:1", "http://127.0.0.1:1", os.devnull, stop, max_probes=5), 0
        )

    def test_next_slot_is_the_minute_boundary(self):
        self.assertAlmostEqual(probe.next_slot(120.0, 1000.0), 1060.0)
        self.assertAlmostEqual(probe.next_slot(179.25, 1000.0), 1000.75)


if __name__ == "__main__":
    unittest.main()
