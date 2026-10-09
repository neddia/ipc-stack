#!/usr/bin/env python3
"""Local HTTP CONNECT proxy that reaches Hyper-V Default Switch VMs through Windows.

WSL cannot route to the Default Switch and has no root to add NAT; Windows can
reach it. Each CONNECT spawns the Windows-side relay (win-relay.py) and pipes
bytes, so urllib (https_proxy), httpx (proxy=) and Chromium (--proxy-server)
all reach the test VMs by their real addresses. Development only.
  python3 e2e/connect-proxy.py [--port 13128]
"""
import argparse
import asyncio
import os

RELAY = os.environ.get("E2E_WIN_PYTHON", "/mnt/c/msys64/ucrt64/bin/python.exe")
RELAY_SCRIPT = os.environ.get("E2E_WIN_RELAY", "C:/Users/Aidden/AppData/Local/toops-e2e/win-relay.py")
PRIVATE = ("172.", "10.", "192.168.")   # test networks: through Windows


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def open_upstream(host, port):
    """Private test addresses go through the Windows relay; everything else directly."""
    if not host.startswith(PRIVATE):
        return await asyncio.open_connection(host, int(port))
    proc = await asyncio.create_subprocess_exec(RELAY, RELAY_SCRIPT, host, str(port), stdin=asyncio.subprocess.PIPE,
                                                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    return proc.stdout, proc.stdin


async def forward_http(head, reader, writer):
    """Plain-HTTP proxying (GET http://host/path): one request per upstream connection."""
    from urllib.parse import urlsplit
    request_line, rest = head.split(b"\r\n", 1)
    method, url, version = request_line.decode().split(" ", 2)
    parts = urlsplit(url)
    path = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    headers = [h for h in rest.split(b"\r\n") if h and not h.lower().startswith((b"proxy-connection:", b"connection:"))]
    up_reader, up_writer = await open_upstream(parts.hostname, parts.port or 80)
    up_writer.write(f"{method} {path} {version}\r\n".encode() + b"\r\n".join(headers + [b"Connection: close"]) + b"\r\n\r\n")
    await up_writer.drain()
    await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))


async def handle(reader, writer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        method, target, _ = head.split(b"\r\n", 1)[0].decode().split(" ", 2)
        host, _, port = target.rpartition(":")
        if method != "CONNECT":
            await forward_http(head, reader, writer)
            return
        if not host.startswith(PRIVATE):
            # Public hosts (Tailscale API, Stripe) are reachable from WSL directly.
            up_reader, up_writer = await asyncio.open_connection(host, int(port))
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
            return
        proc = await asyncio.create_subprocess_exec(RELAY, RELAY_SCRIPT, host, port, stdin=asyncio.subprocess.PIPE,
                                                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await writer.drain()
        await asyncio.gather(pipe(reader, proc.stdin), pipe(proc.stdout, writer))
        proc.kill()
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ValueError, ConnectionError):
        writer.close()


async def main(port):
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    print(f"connect-proxy on 127.0.0.1:{port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=13128)
    asyncio.run(main(parser.parse_args().port))
