#!/usr/bin/env python3
"""Serve a disk report locally and reveal scanned folders in Finder."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--url-file", required=True)
    parser.add_argument("--pid-file", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    report = Path(args.report).resolve(strict=True)
    scan_root = Path(args.root).resolve(strict=True)
    token = args.token

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *values: object) -> None:
            return

        def send_json(self, status: int, payload: dict[str, object]) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def authorized(self) -> bool:
            query = parse_qs(urlparse(self.path).query)
            return query.get("token", [""])[0] == token

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path not in ("/", "/disk_report.html"):
                self.send_error(404)
                return
            if not self.authorized():
                self.send_error(403)
                return
            body = report.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self) -> None:
            if urlparse(self.path).path != "/api/open" or not self.authorized():
                self.send_json(403, {"ok": False, "error": "Unauthorized request"})
                return

            try:
                length = min(int(self.headers.get("Content-Length", "0")), 8192)
                payload = json.loads(self.rfile.read(length))
                relative = payload.get("path", "/")
                if not isinstance(relative, str):
                    raise ValueError("Invalid folder path")

                candidate = scan_root if relative == "/" else (scan_root / relative)
                candidate = candidate.resolve(strict=True)
                if os.path.commonpath((str(scan_root), str(candidate))) != str(scan_root):
                    raise ValueError("Folder is outside the scanned location")
                if not candidate.is_dir():
                    raise ValueError("Folder no longer exists")

                subprocess.run(
                    ["/usr/bin/open", str(candidate)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                self.send_json(200, {"ok": True, "path": str(candidate)})
            except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
                self.send_json(400, {"ok": False, "error": str(error)})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    Path(args.pid_file).write_text(str(os.getpid()), encoding="utf-8")
    Path(args.url_file).write_text(
        f"http://127.0.0.1:{port}/disk_report.html?token={token}",
        encoding="utf-8",
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
