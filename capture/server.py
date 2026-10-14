"""Small web UI listing the packet captures and serving them for download.

Sections are directories: the PBX live captures (CAPTURE_DIR) and, when
mounted, the test bench captures (/tests). Only the standard library is used.
"""

import html
import io
import os
import threading
import time
import zipfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

CAPTURE_DIR = os.environ.get("CAPTURE_DIR", "/captures")
CAPTURE_KEEP = int(os.environ.get("CAPTURE_KEEP", "48"))
CAPTURE_PORT = int(os.environ.get("CAPTURE_PORT", "8080"))

SECTIONS = {
    "pbx": ("Captures du PABX", CAPTURE_DIR),
    "tests": ("Banc de test (make test)", "/tests"),
}

PAGE = """<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Captures PABX</title>
<style>
:root {{ --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e5e5ea; --accent: #0a66c2; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg: #1c1c1e; --fg: #f2f2f7; --muted: #a1a1a6; --line: #38383a; --accent: #4da3ff; }}
}}
body {{ background: var(--bg); color: var(--fg); margin: 0 auto; max-width: 860px;
  padding: 24px 16px; font: 15px/1.5 system-ui, sans-serif; }}
h1 {{ font-size: 22px; margin: 0 0 4px; }}
h2 {{ font-size: 17px; margin: 32px 0 8px; display: flex; gap: 12px; align-items: baseline; }}
p {{ color: var(--muted); margin: 0; }}
a {{ color: var(--accent); text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
table {{ width: 100%; border-collapse: collapse; }}
td {{ padding: 6px 4px; border-top: 1px solid var(--line); }}
td.num {{ text-align: right; color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }}
td.name {{ word-break: break-all; }}
.tag {{ font-size: 12px; color: var(--muted); border: 1px solid var(--line); border-radius: 4px; padding: 0 4px; }}
.zip {{ font-size: 14px; font-weight: normal; }}
</style>
</head>
<body>
<h1>Captures PABX</h1>
<p>SIP et RTP, à ouvrir avec Wireshark (Téléphonie &gt; Appels VoIP pour écouter).
<a href="/">Actualiser</a></p>
{sections}
</body>
</html>
"""


def human_size(size):
    for unit in ("o", "Ko", "Mo"):
        if size < 1024:
            return f"{size:.0f} {unit}"
        size /= 1024
    return f"{size:.1f} Go"


def pcaps(directory):
    """Captures of a directory, most recent first."""
    try:
        entries = [e for e in os.scandir(directory)
                   if e.is_file() and e.name.endswith((".pcap", ".log"))]
    except FileNotFoundError:
        return []
    return sorted(entries, key=lambda e: e.stat().st_mtime, reverse=True)


def prune():
    """Keep the CAPTURE_KEEP most recent live captures."""
    for entry in pcaps(CAPTURE_DIR)[CAPTURE_KEEP:]:
        try:
            os.remove(entry.path)
        except OSError:
            pass


def prune_loop():
    while True:
        prune()
        time.sleep(60)


def render_section(key):
    title, directory = SECTIONS[key]
    files = pcaps(directory)
    if not os.path.isdir(directory):
        return ""
    rows = []
    for index, entry in enumerate(files):
        stat = entry.stat()
        live = key == "pbx" and index == 0
        rows.append(
            "<tr><td class=name><a href='/download/{k}/{q}'>{n}</a>{tag}</td>"
            "<td class=num>{size}</td><td class=num>{date}</td></tr>".format(
                k=key, q=quote(entry.name), n=html.escape(entry.name),
                tag=" <span class=tag>en cours</span>" if live else "",
                size=human_size(stat.st_size),
                date=time.strftime("%d/%m %H:%M:%S", time.localtime(stat.st_mtime))))
    body = ("<table>" + "".join(rows) + "</table>") if rows else "<p>Aucune capture.</p>"
    zip_link = f" <a class=zip href='/zip/{key}'>tout télécharger (.zip)</a>" if rows else ""
    return f"<h2>{html.escape(title)}{zip_link}</h2>{body}"


class Handler(BaseHTTPRequestHandler):
    server_version = "pbx-capture"

    def do_GET(self):
        parts = [unquote(p) for p in self.path.split("?")[0].strip("/").split("/")]
        if parts == [""]:
            prune()
            page = PAGE.format(sections="".join(render_section(k) for k in SECTIONS))
            self.send_body(page.encode(), "text/html; charset=utf-8")
        elif len(parts) == 3 and parts[0] == "download" and parts[1] in SECTIONS:
            self.send_capture(parts[1], parts[2])
        elif len(parts) == 2 and parts[0] == "zip" and parts[1] in SECTIONS:
            self.send_zip(parts[1])
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def send_capture(self, key, name):
        # Only files listed in the section, no path traversal.
        entry = next((e for e in pcaps(SECTIONS[key][1]) if e.name == name), None)
        if entry is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        with open(entry.path, "rb") as f:
            data = f.read()
        self.send_body(data, "application/vnd.tcpdump.pcap", name)

    def send_zip(self, key):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for entry in pcaps(SECTIONS[key][1]):
                archive.write(entry.path, entry.name)
        name = time.strftime(f"captures-{key}-%Y%m%d-%H%M%S.zip")
        self.send_body(buffer.getvalue(), "application/zip", name)

    def send_body(self, data, content_type, filename=None):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if filename:
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    threading.Thread(target=prune_loop, daemon=True).start()
    print(f"Captures UI on port {CAPTURE_PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", CAPTURE_PORT), Handler).serve_forever()
