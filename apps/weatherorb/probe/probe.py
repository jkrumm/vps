"""External availability probe for weatherorb's keyed /v1 data API (weatherorb ADR 0026).

Once a minute it GETs `/v1/pointcast` at a random point through the public edge, the way a customer
does, with a real API key, and exports one OTLP span per probe to ClickStack's internal receiver. The
point is random so the edge's cache cannot answer: every probe reaches the mini.

A probe is good iff HTTP 200, a JSON object holding `time` and `variables`, within the timeout.
Anything else is bad with a short reason: `timeout`, `http 502`, `bad json`, `missing time`,
`missing variables`, or the class name of a connection error.

The key is read once from `PROBE_KEY_FILE` (default /run/secrets/probe_key). It goes into the
Authorization header and nowhere else: not a log line, not a span attribute. Without a key the probe
says so on stderr, waits (so a restart policy does not hot-loop) and exits 2.

Config by env: `PROBE_KEY_FILE`, `PROBE_BASE_URL` (default https://weatherorb.com),
`OTEL_EXPORTER_OTLP_ENDPOINT` (default http://clickstack:4319), `PROBE_ALIVE_FILE` (touched every
loop, the container healthcheck reads its age).
"""

from __future__ import annotations

import json
import os
import random
import secrets
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from urllib.parse import urlsplit

USER_AGENT = "weatherorb-probe/1"
ROUTE_CLASS = "v1_pointcast"
SPAN_NAME = "probe v1_pointcast"
PATH = "/v1/pointcast"
HOURS = 24
LAT_RANGE = (-60.0, 70.0)
LON_RANGE = (-180.0, 180.0)
PERIOD_S = 60.0
TIMEOUT_S = 10.0
EXPORT_TIMEOUT_S = 5.0
MAX_BODY_BYTES = 4 * 1024 * 1024
FAIL_CLOSED_SLEEP_S = 60.0
CHUNK = 64 * 1024

DEFAULT_KEY_FILE = "/run/secrets/probe_key"
DEFAULT_BASE_URL = "https://weatherorb.com"
DEFAULT_OTLP_ENDPOINT = "http://clickstack:4319"
DEFAULT_ALIVE_FILE = "/tmp/probe-alive"

SPAN_KIND_CLIENT = 3
STATUS_UNSET = 0
STATUS_ERROR = 2


class ConfigError(Exception):
    pass


@dataclass(frozen=True)
class Result:
    ok: bool
    status: int  # 0 when no HTTP answer came back
    reason: str  # empty when ok
    start_ns: int
    end_ns: int

    @property
    def duration_ms(self) -> int:
        return (self.end_ns - self.start_ns) // 1_000_000


def load_key(path: str) -> str:
    try:
        with open(path, encoding="ascii") as handle:
            key = handle.read().strip()
    except FileNotFoundError:
        raise ConfigError(f"API key file {path} does not exist") from None
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"API key file {path} is unreadable ({type(exc).__name__})") from None
    if not key:
        raise ConfigError(f"API key file {path} is empty")
    if not key.isprintable() or any(ch.isspace() for ch in key):
        raise ConfigError(f"API key file {path} does not hold a single-line key")
    return key


def random_point(rng: random.Random) -> tuple[float, float]:
    return round(rng.uniform(*LAT_RANGE), 2), round(rng.uniform(*LON_RANGE), 2)


def endpoint_url(base_url: str) -> str:
    return base_url.rstrip("/") + PATH


def classify(status: int, body: bytes) -> str:
    """The reason a finished HTTP answer is bad, or '' when it is good."""
    if status != 200:
        return f"http {status}"
    try:
        document = json.loads(body)
    except ValueError:
        return "bad json"
    if not isinstance(document, dict):
        return "bad json"
    for key in ("time", "variables"):
        if key not in document:
            return f"missing {key}"
    return ""


def error_reason(exc: BaseException) -> str:
    if isinstance(exc, urllib.error.URLError) and exc.reason is not None and not isinstance(exc.reason, str):
        exc = exc.reason
    if isinstance(exc, TimeoutError):
        return "timeout"
    return type(exc).__name__


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect is a failure of the contract, and must never carry the key to another origin."""

    def redirect_request(self, *args, **kwargs):  # noqa: ANN002, ANN003
        return None


def _read_body(response, deadline: float) -> bytes:
    chunks: list[bytes] = []
    size = 0
    # read1: one underlying read at most, so the deadline is checked between packets of a slow drip.
    while chunk := response.read1(CHUNK):
        if time.monotonic() > deadline:
            raise TimeoutError
        size += len(chunk)
        if size > MAX_BODY_BYTES:
            return b"".join(chunks)  # too large to be a pointcast; classify() decides on what is there
        chunks.append(chunk)
    return b"".join(chunks)


def probe_once(
    base_url: str,
    key: str,
    rng: random.Random,
    trace_id: str,
    span_id: str,
    timeout: float = TIMEOUT_S,
) -> Result:
    lat, lon = random_point(rng)
    url = f"{endpoint_url(base_url)}?lat={lat}&lon={lon}&hours={HOURS}"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {key}",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            "traceparent": f"00-{trace_id}-{span_id}-01",
        },
    )
    opener = urllib.request.build_opener(_NoRedirect)
    start_ns = time.time_ns()
    started = time.monotonic()
    status = 0
    reason = ""
    try:
        try:
            with opener.open(request, timeout=timeout) as response:
                status = response.status
                body = _read_body(response, started + timeout)
        except urllib.error.HTTPError as exc:
            status = exc.code
            body = b""
            exc.close()
        reason = classify(status, body)
        if not reason and time.monotonic() - started > timeout:
            reason = "timeout"
    except Exception as exc:  # noqa: BLE001 - every failure is a bad probe, never a crash
        reason = error_reason(exc)
    end_ns = max(time.time_ns(), start_ns)
    return Result(ok=not reason, status=status, reason=reason, start_ns=start_ns, end_ns=end_ns)


def _attr(key: str, value: str | int | bool) -> dict:
    # bool before int: bool is an int subclass. OTLP/JSON writes int64 as a decimal string.
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    return {"key": key, "value": {"stringValue": value}}


def build_payload(result: Result, trace_id: str, span_id: str, base_url: str = DEFAULT_BASE_URL) -> dict:
    attributes = [
        _attr("http.status_code", result.status),
        _attr("weatherorb.route_class", ROUTE_CLASS),
        _attr("weatherorb.probe.ok", result.ok),
        _attr("http.url", endpoint_url(base_url)),
    ]
    status: dict = {"code": STATUS_UNSET}
    if not result.ok:
        attributes.append(_attr("weatherorb.probe.error", result.reason))
        status = {"code": STATUS_ERROR, "message": result.reason}
    span = {
        "traceId": trace_id,
        "spanId": span_id,
        "name": SPAN_NAME,
        "kind": SPAN_KIND_CLIENT,
        "startTimeUnixNano": str(result.start_ns),
        "endTimeUnixNano": str(result.end_ns),
        "status": status,
        "attributes": attributes,
    }
    return {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        _attr("service.name", "weatherorb-probe"),
                        _attr("service.namespace", "weatherorb"),
                        _attr("deployment.environment", "production"),
                    ]
                },
                "scopeSpans": [{"scope": {"name": "weatherorb-probe"}, "spans": [span]}],
            }
        ]
    }


def export_span(endpoint: str, payload: dict, timeout: float = EXPORT_TIMEOUT_S) -> str:
    """POST the span; return '' on success or a one-line failure description."""
    request = urllib.request.Request(
        endpoint.rstrip("/") + "/v1/traces",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        exc.close()
        return f"http {exc.code}"
    except Exception as exc:  # noqa: BLE001 - an unreachable collector must not stop the probe
        return error_reason(exc)
    return ""


def touch(path: str) -> None:
    try:
        with open(path, "a"):
            os.utime(path)
    except OSError as exc:
        sys.stderr.write(f"probe: cannot touch {path} ({type(exc).__name__})\n")


def next_slot(now_wall: float, now_mono: float) -> float:
    """The monotonic time of the next minute boundary on the wall clock."""
    return now_mono + (PERIOD_S - now_wall % PERIOD_S)


def run(
    key: str,
    base_url: str,
    otlp_endpoint: str,
    alive_file: str,
    stop: threading.Event,
    max_probes: int | None = None,
    rng: random.Random | None = None,
    timeout: float = TIMEOUT_S,
    period: float = PERIOD_S,
    align: bool = True,
) -> int:
    rng = rng or random.Random()
    touch(alive_file)
    next_at = next_slot(time.time(), time.monotonic()) if align else time.monotonic()
    done = 0
    while not stop.is_set():
        if stop.wait(max(0.0, next_at - time.monotonic())):
            break
        trace_id, span_id = secrets.token_hex(16), secrets.token_hex(8)
        result = probe_once(base_url, key, rng, trace_id, span_id, timeout)
        verdict = f"ok {result.status}" if result.ok else f"bad {result.reason}"
        sys.stdout.write(f"{verdict} {result.duration_ms}ms\n")
        sys.stdout.flush()
        failure = export_span(otlp_endpoint, build_payload(result, trace_id, span_id, base_url))
        if failure:
            sys.stderr.write(f"probe: span export failed ({failure})\n")
        touch(alive_file)
        done += 1
        if max_probes is not None and done >= max_probes:
            break
        # Drift-free: slots are fixed multiples of the period; a slow probe skips slots, never bunches them.
        next_at += period
        now = time.monotonic()
        if next_at <= now:
            next_at += period * ((now - next_at) // period + 1)
    return 0


def main(
    env: Mapping[str, str] | None = None,
    stop: threading.Event | None = None,
    fail_closed_sleep: float = FAIL_CLOSED_SLEEP_S,
    install_signals: bool = True,
    runner: Callable[..., int] = run,
) -> int:
    env = os.environ if env is None else env
    stop = stop or threading.Event()
    if install_signals:
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: stop.set())
    key_file = env.get("PROBE_KEY_FILE") or DEFAULT_KEY_FILE
    try:
        key = load_key(key_file)
    except ConfigError as exc:
        sys.stderr.write(f"probe: {exc}; set WEATHERORB_PROBE_KEY_FILE in apps/weatherorb/.env\n")
        stop.wait(fail_closed_sleep)
        return 2
    base_url = env.get("PROBE_BASE_URL") or DEFAULT_BASE_URL
    if urlsplit(base_url).scheme not in ("http", "https"):
        sys.stderr.write("probe: PROBE_BASE_URL must be an http(s) URL\n")
        stop.wait(fail_closed_sleep)
        return 2
    otlp = env.get("OTEL_EXPORTER_OTLP_ENDPOINT") or DEFAULT_OTLP_ENDPOINT
    alive = env.get("PROBE_ALIVE_FILE") or DEFAULT_ALIVE_FILE
    sys.stdout.write(f"probing {endpoint_url(base_url)} every {int(PERIOD_S)}s\n")
    sys.stdout.flush()
    return runner(key, base_url, otlp, alive, stop)


if __name__ == "__main__":
    sys.exit(main())
