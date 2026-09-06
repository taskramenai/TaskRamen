#!/usr/bin/env python3
# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)
"""Single-use HTTP server for receiving a Telegram bot token during install.

Usage:
    python3 token-server.py --port 18088 --output /tmp/tg_token_received

GET  /             -> serves token-page.html
POST /submit-token -> validates token, writes to output file, exits
"""

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

TOKEN_RE = re.compile(r'^[0-9]{8,12}:[A-Za-z0-9_\-]{35,}$')

# Globals set by main()
OUTPUT_FILE = ''
HTML_PATH = ''


class TokenHandler(BaseHTTPRequestHandler):
    """Handles GET / and POST /submit-token."""

    def do_GET(self):
        if self.path == '/' or self.path == '':
            try:
                with open(HTML_PATH, 'r', encoding='utf-8') as f:
                    html = f.read()
                html = html.replace('{{PRODUCT_NAME}}', os.environ.get('PRODUCT_NAME', 'TaskRamen.ai'))
                content = html.encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            except FileNotFoundError:
                self._json_response(500, {'error': 'HTML page not found'})
        else:
            self._json_response(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path != '/submit-token':
            self._json_response(404, {'error': 'Not found'})
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length)
            data = json.loads(body)
            token = data.get('token', '').strip()
        except (json.JSONDecodeError, ValueError):
            self._json_response(400, {'error': 'Invalid JSON'})
            return

        if not TOKEN_RE.match(token):
            self._json_response(400, {'error': 'Invalid token format. Expected: 1234567890:ABCdefGHI...'})
            return

        # Call getMe FIRST (before writing token file, since the bash loop
        # kills us as soon as it detects the file)
        bot_username = ''
        try:
            api_url = f'https://api.telegram.org/bot{token}/getMe'
            req = urllib.request.Request(api_url, method='GET')
            with urllib.request.urlopen(req, timeout=10) as resp:
                me_data = json.loads(resp.read())
                if me_data.get('ok'):
                    bot_username = me_data['result'].get('username', '')
        except Exception:
            pass

        # Send response to browser BEFORE writing token file
        response = {'ok': True}
        if bot_username:
            response['bot_username'] = bot_username
        self._json_response(200, response)

        # NOW write token file (this triggers the bash loop to kill us)
        try:
            dir_name = os.path.dirname(OUTPUT_FILE)
            fd, tmp_path = tempfile.mkstemp(dir=dir_name or '/tmp')
            with os.fdopen(fd, 'w') as f:
                f.write(token)
            os.rename(tmp_path, OUTPUT_FILE)
        except OSError:
            pass  # Response already sent; bash will retry via terminal

        # Self-terminate after a delay (in case bash doesn't kill us)
        import threading
        import time
        def delayed_shutdown():
            time.sleep(2)
            self.server.shutdown()
        threading.Thread(target=delayed_shutdown, daemon=True).start()

    def _json_response(self, status, data):
        body = json.dumps(data).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Suppress default request logging
        pass


def main():
    global OUTPUT_FILE, HTML_PATH

    parser = argparse.ArgumentParser(description='Token input web server')
    parser.add_argument('--port', type=int, default=18088)
    parser.add_argument('--output', default='/tmp/tg_token_received')
    args = parser.parse_args()

    OUTPUT_FILE = args.output
    HTML_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'token-page.html')

    server = HTTPServer(('127.0.0.1', args.port), TokenHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
