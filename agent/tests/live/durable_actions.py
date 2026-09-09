"""Disposable localhost side-effect fixture with a durable log and lost responses."""
import argparse
import json
import socket
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def serve(store, port=0):
    with sqlite3.connect(store) as db:
        db.execute('CREATE TABLE IF NOT EXISTS actions (sequence INTEGER PRIMARY KEY, action_id TEXT NOT NULL, value TEXT NOT NULL)')
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if self.path != '/actions':
                self.send_error(404)
                return
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096:
                self.send_error(413)
                return
            try:
                value = json.loads(self.rfile.read(length))
                if not isinstance(value.get('action_id'), str) or not isinstance(value.get('value'), str):
                    raise ValueError('Invalid action')
            except (ValueError, AttributeError):
                self.send_error(422)
                return
            # Intentionally no deduplication: a repeated client mutation must
            # appear twice so recovery cannot hide behind server idempotency.
            with sqlite3.connect(store) as db:
                db.execute('PRAGMA synchronous=FULL')
                sequence = db.execute('INSERT INTO actions(action_id,value) VALUES(?,?)', (value['action_id'], value['value'])).lastrowid
            if self.headers.get('X-Drop-Response') == 'after-commit':
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            self.reply({'sequence': sequence})

        def do_GET(self):
            if self.path != '/actions':
                self.send_error(404)
                return
            with sqlite3.connect(store) as db:
                rows = db.execute('SELECT sequence,action_id,value FROM actions ORDER BY sequence').fetchall()
            self.reply({'actions': [{'sequence': row[0], 'action_id': row[1], 'value': row[2]} for row in rows]})

        def reply(self, value):
            data = json.dumps(value).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'http://127.0.0.1:{server.server_port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--store', required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    serve(args.store, args.port)
