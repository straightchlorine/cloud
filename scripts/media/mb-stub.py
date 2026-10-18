#!/usr/bin/env python3
"""A stand-in for the MusicBrainz web service, serving fixture releases.

    scripts/media/mb-stub.py <fixture dir> <port file> [<request log>]

Each fixture is <dir>/<release id>.json, shaped like MusicBrainz's own answer to
/ws/2/release/<id>?inc=recordings+artist-credits+labels&fmt=json. A fixture
{"_status": 503} answers with that status instead, and {"_truncate": true} with a
body cut short, for the retry paths.
/ws/2/release?query=release:(<album>) AND artist:(<artist>) returns the fixtures
whose title and credited artist match after media_common.key(), and
release:"<album>" those whose title does, so the search paths are exercised
without the network. Anything else is a 404.

Binds 0.0.0.0 on a free port (containers reach it through host-gateway) and
writes the port to <port file> once it listens. Every request is appended to the
request log (path TAB User-Agent), so a test can count what reached the service.
"""

import http.server
import json
import pathlib
import re
import sys
import urllib.parse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "roles/media/files/tools"))
import media_common as mc

FIXTURES = pathlib.Path(sys.argv[1])
LOG = sys.argv[3] if len(sys.argv) > 3 else None


def unescape(term):
    return re.sub(r"\\(.)", r"\1", term)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send(self, status, body=None):
        data = json.dumps(body or {"error": "Not Found"}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if LOG:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write("%s\t%s\n" % (urllib.parse.unquote(self.path), self.headers.get("User-Agent", "")))
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        m = re.fullmatch(r"/ws/2/release/([0-9a-f-]{36})", url.path)
        if m:
            fixture = FIXTURES / (m.group(1) + ".json")
            if not fixture.exists():
                return self.send(404)
            release = json.loads(fixture.read_text(encoding="utf-8"))
            if "_status" in release:
                return self.send(release["_status"], {"error": "stub"})
            if "_truncate" in release:
                # promises more than it sends: the client sees a body cut off mid-way
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.write(b'{"id": ')
                return None
            return self.send(200, release)
        if url.path == "/ws/2/release" and "query" in query:
            m = (re.fullmatch(r"release:\((.*)\) AND artist:\((.*)\)", query["query"][0])
                 or re.fullmatch(r'release:"(.*)"()', query["query"][0]))
            if not m:
                return self.send(400, {"error": "unexpected query"})
            album, artist = mc.key(unescape(m.group(1))), mc.key(unescape(m.group(2)))
            hits = []
            for fixture in sorted(FIXTURES.glob("*.json")):
                release = json.loads(fixture.read_text(encoding="utf-8"))
                if "_status" in release or "_truncate" in release:
                    continue
                if mc.key(release.get("title")) == album and artist in mc.key(mc.credit(release)):
                    hits.append({k: release[k] for k in release if k != "media"})
            limit = int(query.get("limit", ["25"])[0])
            return self.send(200, {"count": len(hits), "offset": 0, "releases": hits[:limit]})
        return self.send(404)


server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Handler)
pathlib.Path(sys.argv[2]).write_text(str(server.server_address[1]))
server.serve_forever()
