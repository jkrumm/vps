"""Tests for the egress proxy. Stdlib only: `python3 -m unittest` from this directory."""

import asyncio
import ipaddress
import os
import signal
import socket
import subprocess
import sys
import time
import unittest
from dataclasses import replace
from pathlib import Path

import proxy

HERE = Path(__file__).resolve().parent
PROXY_PY = HERE / "proxy.py"
PUBLIC_V4 = "93.184.216.34"


def connect_line(target: str, method: str = "CONNECT", version: str = "HTTP/1.1") -> bytes:
    return f"{method} {target} {version}\r\nHost: {target}\r\n\r\n".encode()


def status_of(raw: bytes) -> int:
    return int(raw.split(b" ", 2)[1])


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ProxyCase(unittest.IsolatedAsyncioTestCase):
    """A proxy on a loopback port; `self.cfg` is the strict config unless a test replaces it before `serve()`."""

    cfg = proxy.Config()

    async def serve(self, config: proxy.Config | None = None) -> int:
        self.lines: list[str] = []
        self.proxy = proxy.Proxy(config or self.cfg, log=self.lines.append)
        self.server = await self.proxy.start("127.0.0.1", 0)
        self.addCleanup(self.stop)
        return self.server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        await self.proxy.shutdown(self.server)

    async def exchange(self, port: int, raw: bytes, timeout: float = 3.0) -> bytes:
        """Send `raw`, read until the proxy closes."""
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        try:
            writer.write(raw)
            await writer.drain()
            async with asyncio.timeout(timeout):
                return await reader.read()
        finally:
            writer.close()

    async def wait_lines(self, count: int = 1) -> None:
        """The log line is written after the connection ends, which can be just after the client saw its answer."""
        for _ in range(100):
            if len(self.lines) >= count:
                return
            await asyncio.sleep(0.05)

    async def echo_server(self) -> int:
        async def echo(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            try:
                while data := await reader.read(4096):
                    writer.write(data)
                    await writer.drain()
            except OSError:
                pass
            finally:
                writer.close()

        server = await asyncio.start_server(echo, "127.0.0.1", 0)
        self.addAsyncCleanup(self._close_server, server)
        return server.sockets[0].getsockname()[1]

    @staticmethod
    async def _close_server(server: asyncio.Server) -> None:
        server.close()
        server.close_clients()

    def tunnel_config(self, echo_port: int, **overrides: float | int) -> proxy.Config:
        return replace(proxy.Config(), allowed_port=echo_port, is_public=lambda _a: True, **overrides)

    async def open_tunnel(self, port: int, echo_port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter, bytes]:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        self.addCleanup(writer.close)
        writer.write(connect_line(f"127.0.0.1:{echo_port}"))
        await writer.drain()
        async with asyncio.timeout(3):
            head = await reader.readuntil(b"\r\n\r\n")
        return reader, writer, head


class RefusalTests(ProxyCase):
    async def test_non_public_targets_get_403(self) -> None:
        port = await self.serve()
        targets = [
            "10.1.2.3:443",  # RFC 1918
            "192.168.1.1:443",
            "172.17.0.2:443",  # a docker bridge network
            "172.31.255.254:443",
            "127.0.0.1:443",  # loopback
            "169.254.169.254:443",  # link-local, cloud metadata
            "100.64.0.1:443",  # CGNAT, the tailnet
            "100.127.255.254:443",
            "0.0.0.0:443",
            "224.0.0.1:443",  # multicast
            "240.0.0.1:443",  # reserved
            "255.255.255.255:443",
            "192.0.2.1:443",  # documentation
            "198.51.100.1:443",
            "203.0.113.1:443",
            "[::1]:443",
            "[::]:443",
            "[fd00::1]:443",  # ULA
            "[fe80::1]:443",  # link-local
            "[ff02::1]:443",  # multicast
            "[2001:db8::1]:443",  # documentation
            "[::ffff:10.0.0.1]:443",  # IPv4-mapped, private
            "[::ffff:93.184.216.34]:443",  # IPv4-mapped, even a public one
            "[2002:5db8:d822::1]:443",  # 6to4
            "[64:ff9b::5db8:d822]:443",  # NAT64
        ]
        for target in targets:
            with self.subTest(target=target):
                raw = await self.exchange(port, connect_line(target))
                self.assertEqual(status_of(raw), 403, raw)
        await self.wait_lines(len(targets))
        self.assertEqual(len(self.lines), len(targets))
        self.assertTrue(all("verdict=refused_address" in line for line in self.lines))

    async def test_hostname_target_is_refused(self) -> None:
        port = await self.serve()
        for target in ("example.com:443", "localhost:443", "1.2.3.4.example.com:443", "[example.com]:443"):
            with self.subTest(target=target):
                raw = await self.exchange(port, connect_line(target))
                self.assertIn(status_of(raw), (400, 403), raw)

    async def test_odd_ip_spellings_are_refused(self) -> None:
        port = await self.serve()
        for target in ("2130706433:443", "0x7f.0.0.1:443", "127.1:443", "010.0.0.1:443", "::1:443", "[::1%25lo]:443", "[127.0.0.1]:443", "[::1%lo]:443"):
            with self.subTest(target=target):
                raw = await self.exchange(port, connect_line(target))
                self.assertIn(status_of(raw), (400, 403), raw)

    async def test_port_other_than_443_gets_403(self) -> None:
        port = await self.serve()
        for target in (f"{PUBLIC_V4}:80", f"{PUBLIC_V4}:8443", f"{PUBLIC_V4}:22", f"[2606:4700::1111]:80"):
            with self.subTest(target=target):
                raw = await self.exchange(port, connect_line(target))
                self.assertEqual(status_of(raw), 403, raw)

    async def test_malformed_target_ports_get_400(self) -> None:
        port = await self.serve()
        for target in (PUBLIC_V4, f"{PUBLIC_V4}:", f"{PUBLIC_V4}:44x", f"{PUBLIC_V4}:-443", f"{PUBLIC_V4}:4430000"):
            with self.subTest(target=target):
                raw = await self.exchange(port, connect_line(target))
                self.assertEqual(status_of(raw), 400, raw)

    async def test_other_methods_get_405(self) -> None:
        port = await self.serve()
        for method in ("GET", "POST", "HEAD", "OPTIONS", "PUT", "connect"):
            with self.subTest(method=method):
                raw = await self.exchange(port, connect_line(f"{PUBLIC_V4}:443", method=method))
                self.assertEqual(status_of(raw), 405, raw)
                self.assertIn(b"Allow: CONNECT", raw)
        raw = await self.exchange(port, b"GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")
        self.assertEqual(status_of(raw), 405)

    async def test_malformed_requests_get_400(self) -> None:
        port = await self.serve()
        cases = {
            "two tokens": b"CONNECT 1.2.3.4:443\r\n\r\n",
            "four tokens": b"CONNECT 1.2.3.4:443 HTTP/1.1 x\r\n\r\n",
            "double space": b"CONNECT  1.2.3.4:443 HTTP/1.1\r\n\r\n",
            "empty line": b"\r\n\r\n",
            "not http": b"CONNECT 1.2.3.4:443 SPDY/3\r\n\r\n",
            "http 1.0": b"CONNECT 1.2.3.4:443 HTTP/1.0\r\n\r\n",
            "binary": b"\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03\r\n\r\n",
            "header without colon": b"CONNECT 1.2.3.4:443 HTTP/1.1\r\nbroken\r\n\r\n",
            "folded header": b"CONNECT 1.2.3.4:443 HTTP/1.1\r\nA: b\r\n c\r\n\r\n",
            "bare LF": b"CONNECT 1.2.3.4:443 HTTP/1.1\nA: b\r\n\r\n",
        }
        for name, raw in cases.items():
            with self.subTest(name):
                answer = await self.exchange(port, raw)
                self.assertEqual(status_of(answer), 400, answer)

    async def test_oversized_head_is_refused_and_closed(self) -> None:
        port = await self.serve()
        filler = b"X-Pad: " + b"a" * 100 + b"\r\n"
        without_terminator = b"CONNECT 1.2.3.4:443 HTTP/1.1\r\n" + filler * 90  # ~9.5 KiB, never ends
        raw = await self.exchange(port, without_terminator)
        self.assertEqual(status_of(raw), 431, raw[:60])
        with_terminator = b"CONNECT 1.2.3.4:443 HTTP/1.1\r\n" + filler * 90 + b"\r\n"
        raw = await self.exchange(port, with_terminator)
        self.assertEqual(status_of(raw), 431, raw[:60])

    async def test_slow_head_is_closed(self) -> None:
        port = await self.serve(replace(proxy.Config(), header_timeout_s=0.3))
        started = time.monotonic()
        raw = await self.exchange(port, b"CONNECT 1.2.3.4:443 HTTP/1.1\r\nHost: x\r\n", timeout=3)
        self.assertEqual(status_of(raw), 408, raw)
        self.assertLess(time.monotonic() - started, 2)

    async def test_dripping_head_cannot_extend_the_deadline(self) -> None:
        port = await self.serve(replace(proxy.Config(), header_timeout_s=0.4))
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        self.addCleanup(writer.close)
        started = time.monotonic()
        async with asyncio.timeout(3):
            try:
                for byte in b"CONNECT 1.2.3.4:443 HTTP/1.1\r\n":
                    writer.write(bytes([byte]))
                    await writer.drain()
                    await asyncio.sleep(0.05)
                await reader.read()
            except ConnectionResetError:
                pass  # the proxy hung up on the dripping client, which is the point
        self.assertLess(time.monotonic() - started, 2)
        await self.wait_lines()
        self.assertIn("verdict=head_timeout", self.lines[0])

    async def test_silent_probe_is_closed_without_a_log_line(self) -> None:
        port = await self.serve()
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.close()
        await asyncio.sleep(0.2)
        self.assertEqual(self.lines, [])
        self.assertEqual(self.proxy._active, 0)


class TunnelTests(ProxyCase):
    async def test_tunnel_pipes_bytes_both_ways_and_logs_without_payload(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve(self.tunnel_config(echo_port))
        reader, writer, head = await self.open_tunnel(port, echo_port)
        self.assertTrue(head.startswith(b"HTTP/1.1 200 Connection Established\r\n"), head)
        secret = b"POST /hook HTTP/1.1 secret-payload-123"
        writer.write(secret)
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(len(secret)), 3), secret)
        writer.write(b"second")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(6), 3), b"second")
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 3), b"")
        for _ in range(50):
            if self.lines:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(len(self.lines), 1, self.lines)
        line = self.lines[0]
        self.assertIn(f"target=127.0.0.1:{echo_port}", line)
        self.assertIn("verdict=ok", line)
        self.assertIn(f"up={len(secret) + 6}", line)
        self.assertIn(f"down={len(secret) + 6}", line)
        self.assertIn("client=127.0.0.1", line)
        self.assertNotIn("secret-payload", line)

    async def test_bytes_sent_with_the_request_reach_upstream(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve(self.tunnel_config(echo_port))
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        self.addCleanup(writer.close)
        writer.write(connect_line(f"127.0.0.1:{echo_port}") + b"early")
        await writer.drain()
        await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 3)
        self.assertEqual(await asyncio.wait_for(reader.readexactly(5), 3), b"early")

    async def test_unreachable_upstream_gets_502(self) -> None:
        dead = free_port()
        port = await self.serve(self.tunnel_config(dead))
        raw = await self.exchange(port, connect_line(f"127.0.0.1:{dead}"))
        self.assertEqual(status_of(raw), 502, raw)
        await self.wait_lines()
        self.assertIn("verdict=upstream_failed", self.lines[0])

    async def test_idle_tunnel_is_closed(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve(self.tunnel_config(echo_port, idle_timeout_s=0.3, total_timeout_s=10))
        reader, _writer, _head = await self.open_tunnel(port, echo_port)
        started = time.monotonic()
        self.assertEqual(await asyncio.wait_for(reader.read(), 3), b"")
        self.assertLess(time.monotonic() - started, 2)
        await self.wait_lines()
        self.assertIn("verdict=timeout_idle", self.lines[0])

    async def test_total_lifetime_is_capped_even_while_active(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve(self.tunnel_config(echo_port, idle_timeout_s=5, total_timeout_s=0.8))
        reader, writer, _head = await self.open_tunnel(port, echo_port)
        started = time.monotonic()
        closed = False
        async with asyncio.timeout(4):
            while not closed:
                try:
                    writer.write(b"tick")
                    await writer.drain()
                except OSError:
                    break
                try:
                    data = await asyncio.wait_for(reader.read(4096), 0.1)
                    closed = data == b""
                except TimeoutError:
                    pass
                except ConnectionResetError:
                    break  # a forced end aborts the connection
        self.assertLess(time.monotonic() - started, 3)
        await self.wait_lines()
        self.assertIn("verdict=timeout_total", self.lines[0])

    async def test_concurrency_cap_answers_503(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve(self.tunnel_config(echo_port, max_connections=2))
        _r1, w1, _ = await self.open_tunnel(port, echo_port)
        await self.open_tunnel(port, echo_port)
        raw = await self.exchange(port, connect_line(f"127.0.0.1:{echo_port}"))
        self.assertEqual(status_of(raw), 503, raw)
        await self.wait_lines()
        self.assertTrue(any("verdict=busy" in line for line in self.lines), self.lines)

        w1.close()
        for _ in range(50):
            if self.proxy._active < 2:
                break
            await asyncio.sleep(0.05)
        reader, writer, head = await self.open_tunnel(port, echo_port)
        self.assertTrue(head.startswith(b"HTTP/1.1 200"), head)

    async def test_strict_defaults_refuse_a_local_echo_server(self) -> None:
        echo_port = await self.echo_server()
        port = await self.serve()
        raw = await self.exchange(port, connect_line(f"127.0.0.1:{echo_port}"))
        self.assertEqual(status_of(raw), 403, raw)


class DefaultsTests(unittest.TestCase):
    def test_production_defaults_are_strict(self) -> None:
        cfg = proxy.Config()
        self.assertEqual(cfg.allowed_port, 443)
        self.assertIs(cfg.is_public, proxy.is_public_address)
        self.assertEqual(cfg.max_connections, 32)
        self.assertEqual(cfg.header_timeout_s, 5.0)
        self.assertEqual(cfg.connect_timeout_s, 5.0)
        self.assertEqual(cfg.total_timeout_s, 30.0)
        self.assertEqual(cfg.idle_timeout_s, 15.0)
        self.assertEqual(proxy.MAX_HEAD_BYTES, 8192)

    def test_public_addresses_pass_the_deny_list(self) -> None:
        for text in (PUBLIC_V4, "1.1.1.1", "8.8.8.8", "2606:2800:220:1:248:1893:25c8:1946", "2a00:1450:4001::200e"):
            with self.subTest(text=text):
                self.assertTrue(proxy.is_public_address(ipaddress.ip_address(text)))

    def test_private_addresses_fail_the_deny_list(self) -> None:
        for text in ("10.0.0.1", "172.16.0.1", "172.17.0.1", "192.168.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1", "::1", "fd12::1", "::ffff:8.8.8.8", "2002::1", "64:ff9b::808:808"):
            with self.subTest(text=text):
                self.assertFalse(proxy.is_public_address(ipaddress.ip_address(text)))

    def test_listen_host_is_required_and_never_a_wildcard(self) -> None:
        for env in ({}, {"LISTEN_HOST": ""}, {"LISTEN_HOST": "0.0.0.0"}, {"LISTEN_HOST": "::"}, {"LISTEN_HOST": "tailnet-host"}, {"LISTEN_HOST": "0.0.0.0", "ALLOW_CONTAINER_BIND": "0"}):
            with self.subTest(env=env), self.assertRaises(proxy.ConfigError):
                proxy.listen_from_env(env)

    def test_listen_config_accepts_an_explicit_ip_and_the_container_override(self) -> None:
        self.assertEqual(proxy.listen_from_env({"LISTEN_HOST": "100.64.0.9"}), ("100.64.0.9", 18443))
        self.assertEqual(proxy.listen_from_env({"LISTEN_HOST": "127.0.0.1", "LISTEN_PORT": "9000"}), ("127.0.0.1", 9000))
        self.assertEqual(proxy.listen_from_env({"LISTEN_HOST": "0.0.0.0", "ALLOW_CONTAINER_BIND": "1"}), ("0.0.0.0", 18443))
        for bad in ("0", "65536", "x", "-1", ""):
            with self.subTest(port=bad), self.assertRaises(proxy.ConfigError):
                proxy.listen_from_env({"LISTEN_HOST": "127.0.0.1", "LISTEN_PORT": bad})


class ProcessTests(unittest.TestCase):
    def run_proxy(self, **env: str) -> subprocess.Popen[str]:
        return subprocess.Popen(
            [sys.executable, "-I", str(PROXY_PY)],
            env={"PATH": os.environ.get("PATH", ""), **env},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    @staticmethod
    def reap(child: subprocess.Popen[str]) -> None:
        child.kill()
        child.wait()
        for pipe in (child.stdout, child.stderr):
            if pipe:
                pipe.close()

    def test_wildcard_listen_host_refuses_to_start(self) -> None:
        for host in ("0.0.0.0", "::"):
            with self.subTest(host=host):
                result = subprocess.run(
                    [sys.executable, "-I", str(PROXY_PY)],
                    env={"PATH": os.environ.get("PATH", ""), "LISTEN_HOST": host},
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("LISTEN_HOST", result.stderr)

    def test_missing_listen_host_refuses_to_start(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(PROXY_PY)], env={"PATH": os.environ.get("PATH", "")}, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)

    def test_sigterm_stops_it_cleanly(self) -> None:
        port = free_port()
        child = self.run_proxy(LISTEN_HOST="127.0.0.1", LISTEN_PORT=str(port))
        self.addCleanup(self.reap, child)
        deadline = time.monotonic() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                if time.monotonic() > deadline or child.poll() is not None:
                    self.fail(f"proxy did not start: {child.stderr.read() if child.stderr else ''}")
                time.sleep(0.05)
        child.send_signal(signal.SIGTERM)
        self.assertEqual(child.wait(timeout=5), 0)
        self.assertIn("stopped", child.stdout.read() if child.stdout else "")


if __name__ == "__main__":
    unittest.main()
