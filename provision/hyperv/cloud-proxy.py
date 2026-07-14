#!/usr/bin/env python3
"""Expose the loopback-only development cloud to a test IPC network."""

from __future__ import annotations

import argparse
import asyncio


async def _copy(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def _serve(listen_host: str, listen_port: int, target_host: str, target_port: int) -> None:
    async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter) -> None:
        try:
            target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
        except Exception:
            client_writer.close()
            return
        await asyncio.gather(
            _copy(client_reader, target_writer),
            _copy(target_reader, client_writer),
            return_exceptions=True,
        )

    server = await asyncio.start_server(handle, listen_host, listen_port)
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    print(f"[ipc-e2e] cloud proxy listening on {addresses}", flush=True)
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", type=int, default=18001)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=8001)
    args = parser.parse_args()
    asyncio.run(_serve(args.listen_host, args.listen_port, args.target_host, args.target_port))


if __name__ == "__main__":
    main()
