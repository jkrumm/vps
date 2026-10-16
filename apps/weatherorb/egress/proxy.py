"""A CONNECT-only egress proxy for weatherorb's forecast-alert webhooks (weatherorb ADR 0023).

The alert worker on the Mac mini POSTs to URLs strangers typed. So the home IP never reaches a
receiver, every delivery goes mini -> tailnet -> this proxy -> receiver, and the receiver sees the
VPS's public IP. The mini resolves the host and pins one checked address; this proxy is the second
layer behind its guard, so it takes IP literals only and refuses anything that is not globally
routable, whatever the mini sent.

Accepted: `CONNECT <IPv4>:443 HTTP/1.1` and `CONNECT [<IPv6>]:443 HTTP/1.1`, nothing else.

- 400 malformed request (line, headers, port, version), 403 refused target (hostname, port other
  than 443, non-public address), 405 other method, 408 header block slower than 5 s, 431 header
  block over 8 KiB, 502/504 upstream connect failed/timed out (5 s), 503 over 32 connections.
- A tunnel lives at most 30 s and is closed after 15 s without a byte in either direction.
- One log line per CONNECT on stdout: time, client, target, verdict, bytes up/down, duration. Never
  a payload, never a header.

`_DENIED` and `is_public_address` are a copy of the mini's guard
(weatherorb `src/weatherorb/alerts/guard.py`): keep the two lists identical.

Config by env: `LISTEN_HOST` (required, an IP literal; 0.0.0.0 and :: are refused) and
`LISTEN_PORT` (default 18443). `ALLOW_CONTAINER_BIND=1` lifts the wildcard refusal for one case:
inside the container the proxy must bind the wildcard, because the container's bridge address is
not known up front, and the exposure is decided by the compose port publish (the VPS's tailnet IP
only) on a bridge network that no other container shares.
"""

from __future__ import annotations

import asyncio
import ipaddress
import os
import signal
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime, timezone

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address

DEFAULT_PORT = 18443
HTTPS_PORT = 443
MAX_HEAD_BYTES = 8 * 1024
CHUNK = 64 * 1024
LINGER_S = 1.0

_DENIED = tuple(
    ipaddress.ip_network(net)
    for net in (
        # IPv4
        "0.0.0.0/8",  # "this network"
        "10.0.0.0/8",
        "100.64.0.0/10",  # CGNAT, which is where the tailnet lives
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",  # includes the docker bridge networks
        "192.0.0.0/24",  # IETF protocol assignments
        "192.0.2.0/24",
        "192.88.99.0/24",
        "192.168.0.0/16",
        "198.18.0.0/15",  # benchmarking
        "198.51.100.0/24",
        "203.0.113.0/24",
        "224.0.0.0/4",
        "240.0.0.0/4",  # reserved, and the limited broadcast
        # IPv6
        "::/8",  # unspecified, loopback, IPv4-compatible, IPv4-mapped (::ffff:0:0/96)
        "64:ff9b::/96",  # NAT64
        "64:ff9b:1::/48",
        "100::/64",  # discard-only
        "2001::/23",  # protocol assignments, Teredo
        "2001:db8::/32",
        "2002::/16",  # 6to4
        "3fff::/20",  # documentation
        "5f00::/16",
        "fc00::/7",  # ULA
        "fe80::/10",  # link-local
        "fec0::/10",  # site-local
        "ff00::/8",
    )
)

REASONS = {
    200: "Connection Established",
    400: "Bad Request",
    403: "Forbidden",
    405: "Method Not Allowed",
    408: "Request Timeout",
    431: "Request Header Fields Too Large",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout",
}


def is_public_address(address: IPAddress) -> bool:
    """True when `address` is globally routable and in none of the refused ranges."""
    if any(address in net for net in _DENIED if net.version == address.version):
        return False
    return address.is_global and not address.is_multicast


@dataclass(frozen=True)
class Config:
    """Production defaults are the strict ones; only the tests change them."""

    allowed_port: int = HTTPS_PORT
    is_public: Callable[[IPAddress], bool] = is_public_address
    max_connections: int = 32
    header_timeout_s: float = 5.0
    connect_timeout_s: float = 5.0
    total_timeout_s: float = 30.0
    idle_timeout_s: float = 15.0


class Refused(Exception):
    """A request answered with a 4xx and closed."""

    def __init__(self, status: int, verdict: str, target: str = "-") -> None:
        super().__init__(verdict)
        self.status = status
        self.verdict = verdict
        self.target = target


@dataclass
class Conn:
    client: str
    target: str = "-"
    verdict: str = "aborted"
    up: int = 0
    down: int = 0
    started: float = field(default_factory=lambda: asyncio.get_running_loop().time())
    seen: bool = True  # False: connected and closed without a byte (a health probe), not logged


def _printable(value: str, limit: int = 80) -> str:
    """Attacker-supplied text made safe for one log line."""
    clean = "".join(c if "!" <= c <= "~" else "?" for c in value[:limit])
    return clean or "-"


def parse_target(target: str, allowed_port: int) -> tuple[IPAddress, int]:
    """`<IPv4>:<port>` or `[<IPv6>]:<port>`; raises `Refused` for a hostname, another port or a bad shape."""
    host, sep, port_text = target.rpartition(":")
    if not sep or not host:
        raise Refused(400, "bad_target", _printable(target))
    if not (port_text.isascii() and port_text.isdigit()) or len(port_text) > 5:
        raise Refused(400, "bad_target", _printable(target))
    address: IPAddress
    try:
        if host.startswith("[") and host.endswith("]") and "%" not in host:
            address = ipaddress.IPv6Address(host[1:-1])
        else:
            address = ipaddress.IPv4Address(host)
    except ValueError:
        raise Refused(403, "refused_not_ip", _printable(target)) from None
    if int(port_text) != allowed_port:
        raise Refused(403, "refused_port", _printable(target))
    return address, int(port_text)


async def read_head(reader: asyncio.StreamReader) -> tuple[bytes, bytes] | None:
    """The request head (without its blank line) and any bytes read past it; None on a silent close."""
    buf = b""
    while True:
        end = buf.find(b"\r\n\r\n")
        if end != -1:
            if end + 4 > MAX_HEAD_BYTES:
                raise Refused(431, "head_too_large")
            return buf[:end], buf[end + 4 :]
        if len(buf) >= MAX_HEAD_BYTES:
            raise Refused(431, "head_too_large")
        chunk = await reader.read(4096)
        if not chunk:
            if not buf:
                return None
            raise Refused(400, "closed_mid_head")
        buf += chunk


def parse_head(head: bytes) -> str:
    """The CONNECT target of a well-formed head; raises `Refused` otherwise. Header values are never read."""
    try:
        text = head.decode("ascii")
    except UnicodeDecodeError:
        raise Refused(400, "malformed") from None
    lines = text.split("\r\n")
    if any(c in line for line in lines for c in "\r\n\0"):
        raise Refused(400, "malformed")
    parts = lines[0].split(" ")
    if len(parts) != 3 or not all(parts) or not parts[2].startswith("HTTP/"):
        raise Refused(400, "malformed")
    for line in lines[1:]:
        if ":" not in line or line[0] in " \t":
            raise Refused(400, "malformed")
    method, target, version = parts
    if method != "CONNECT":
        raise Refused(405, "refused_method", _printable(method))
    if version != "HTTP/1.1":
        raise Refused(400, "bad_version", _printable(target))
    return target


def _response(status: int) -> bytes:
    extra = "Allow: CONNECT\r\n" if status == 405 else ""
    if status == 200:
        return b"HTTP/1.1 200 Connection Established\r\n\r\n"
    return f"HTTP/1.1 {status} {REASONS[status]}\r\n{extra}Connection: close\r\nContent-Length: 0\r\n\r\n".encode()


def _release(writer: asyncio.StreamWriter, hard: bool) -> None:
    if hard:
        writer.transport.abort()
    else:
        writer.close()


class Proxy:
    def __init__(self, config: Config = Config(), log: Callable[[str], None] | None = None) -> None:
        self.config = config
        self._log = log or _stdout
        self._tasks: set[asyncio.Task[None]] = set()
        self._active = 0

    async def start(self, host: str, port: int) -> asyncio.Server:
        return await asyncio.start_server(self.handle, host, port)

    async def shutdown(self, server: asyncio.Server) -> None:
        server.close()
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        if task is not None:
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        peer = writer.get_extra_info("peername")
        conn = Conn(client=str(peer[0]) if peer else "-")
        hard = True
        self._active += 1
        try:
            if self._active > self.config.max_connections:
                conn.verdict = "busy"
                await self._answer(reader, writer, 503)
                hard = False
                return
            hard = await self._serve(reader, writer, conn)
        except Refused as refusal:
            conn.verdict, conn.target = refusal.verdict, refusal.target
            await self._answer(reader, writer, refusal.status)
            hard = False
        except (OSError, asyncio.IncompleteReadError):
            conn.verdict = "reset"
        finally:
            self._active -= 1
            _release(writer, hard)
            if conn.seen:
                self._emit(conn)

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, conn: Conn) -> bool:
        """One request. Returns True when the client side must be aborted rather than flushed."""
        cfg = self.config
        try:
            async with asyncio.timeout(cfg.header_timeout_s):
                got = await read_head(reader)
        except TimeoutError:
            raise Refused(408, "head_timeout") from None
        if got is None:
            conn.seen = False
            return False
        head, leftover = got
        target = parse_target(parse_head(head), cfg.allowed_port)
        address, port = target
        conn.target = f"{_host_text(address)}:{port}"
        if not cfg.is_public(address):
            raise Refused(403, "refused_address", conn.target)

        try:
            async with asyncio.timeout(cfg.connect_timeout_s):
                up_reader, up_writer = await asyncio.open_connection(str(address), port)
        except TimeoutError:
            conn.verdict = "upstream_timeout"
            await self._answer(reader, writer, 504)
            return False
        except OSError:
            conn.verdict = "upstream_failed"
            await self._answer(reader, writer, 502)
            return False

        hard = True
        try:
            writer.write(_response(200))
            if leftover:
                up_writer.write(leftover)
                conn.up += len(leftover)
            await writer.drain()
            hard = await self._tunnel(reader, writer, up_reader, up_writer, conn)
        finally:
            _release(up_writer, hard)
        return hard

    async def _tunnel(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        up_reader: asyncio.StreamReader,
        up_writer: asyncio.StreamWriter,
        conn: Conn,
    ) -> bool:
        """Pipe both ways under the total and idle limits. Returns True when it ended by force."""
        cfg = self.config
        loop = asyncio.get_running_loop()
        last = loop.time()

        async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter, upward: bool) -> None:
            nonlocal last
            while chunk := await src.read(CHUNK):
                last = loop.time()
                if upward:
                    conn.up += len(chunk)
                else:
                    conn.down += len(chunk)
                dst.write(chunk)
                await dst.drain()
            if dst.can_write_eof():
                dst.write_eof()

        pending = {asyncio.ensure_future(pipe(reader, up_writer, True)), asyncio.ensure_future(pipe(up_reader, writer, False))}
        conn.verdict = "aborted"
        forced = False
        try:
            while pending:
                now = loop.time()
                total_left = conn.started + cfg.total_timeout_s - now
                idle_left = last + cfg.idle_timeout_s - now
                if min(total_left, idle_left) <= 0:
                    conn.verdict = "timeout_total" if total_left <= idle_left else "timeout_idle"
                    forced = True
                    break
                done, pending = await asyncio.wait(pending, timeout=min(total_left, idle_left))
                if any(task.exception() for task in done):
                    conn.verdict = "reset"
                    forced = True
                    break
            else:
                conn.verdict = "ok"
        finally:
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        return forced

    async def _answer(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, status: int) -> None:
        """Send the status, half-close, then swallow what the client is still sending for up to a second: closing
        with unread input would reset the connection and the client could lose the answer."""
        try:
            writer.write(_response(status))
            async with asyncio.timeout(2):
                await writer.drain()
            writer.write_eof()
            async with asyncio.timeout(LINGER_S):
                while await reader.read(CHUNK):
                    pass
        except (OSError, TimeoutError):
            pass

    def _emit(self, conn: Conn) -> None:
        duration = asyncio.get_running_loop().time() - conn.started
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self._log(
            f"{stamp} client={conn.client} target={conn.target} verdict={conn.verdict} "
            f"up={conn.up} down={conn.down} dur={duration:.2f}s"
        )


def _host_text(address: IPAddress) -> str:
    return f"[{address}]" if address.version == 6 else str(address)


def _stdout(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class ConfigError(Exception):
    pass


def listen_from_env(env: Mapping[str, str]) -> tuple[str, int]:
    """The (host, port) to bind; raises `ConfigError` for anything unsafe or missing."""
    host = env.get("LISTEN_HOST", "").strip()
    if not host:
        raise ConfigError("LISTEN_HOST is required (the tailnet IP; there is no default)")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        raise ConfigError("LISTEN_HOST must be an IP literal") from None
    if address.is_unspecified and env.get("ALLOW_CONTAINER_BIND") != "1":
        raise ConfigError("LISTEN_HOST must not be a wildcard address (ALLOW_CONTAINER_BIND=1 inside the container only)")
    text = env.get("LISTEN_PORT", str(DEFAULT_PORT)).strip()
    if not (text.isascii() and text.isdigit() and 0 < int(text) < 65536):
        raise ConfigError("LISTEN_PORT must be a port number")
    return host, int(text)


async def run(host: str, port: int, proxy: Proxy | None = None) -> None:
    proxy = proxy or Proxy()
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    server = await proxy.start(host, port)
    _stdout(f"listening on {host}:{port}")
    await stop.wait()
    await proxy.shutdown(server)
    _stdout("stopped")


def main() -> int:
    try:
        host, port = listen_from_env(os.environ)
    except ConfigError as exc:
        sys.stderr.write(f"egress proxy: {exc}\n")
        return 2
    asyncio.run(run(host, port))
    return 0


if __name__ == "__main__":
    sys.exit(main())
