"""Serve the generated figure gallery on localhost without filesystem fstat."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import mimetypes
from pathlib import Path
from urllib.parse import unquote, urlsplit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--port", type=int, default=8875)
    args = parser.parse_args()
    root = (args.run_directory / "plots" / "curriculum_episode_curves").resolve()
    if not (root / "index.html").is_file():
        parser.error(f"Gallery does not exist: {root}")

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            request_path = unquote(urlsplit(self.path).path).lstrip("/") or "index.html"
            target = (root / request_path).resolve()
            if not target.is_relative_to(root) or not target.is_file():
                self.send_error(404)
                return
            try:
                content = target.read_bytes()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(target.name)[0] or "application/octet-stream")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(content)

    print(f"Gallery: http://127.0.0.1:{args.port}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
