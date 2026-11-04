"""Release uploader checks against a local HTTP server; no real publication."""
import contextlib
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / '.github/scripts/publish-rocks.py'
PREFIX = 'lua-leanjson-0.1.0-1'


class PublishRocksTests(unittest.TestCase):
    @contextlib.contextmanager
    def environment(self, existing=False, mismatch=False):
        state = {'posts': [], 'files': {}, 'existing': existing}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            spec = b'package = "lua-leanjson"\nversion = "0.1.0-1"\n'
            (root / (PREFIX + '.rockspec')).write_bytes(spec)
            for arch in ('src', 'linux-x86_64', 'linux-aarch64'):
                with zipfile.ZipFile(root / (PREFIX + '.' + arch + '.rock'), 'w') as archive:
                    archive.writestr(PREFIX + '.rockspec', spec)
            if existing:
                state['files'] = {p.name: p.read_bytes() for p in root.iterdir()}
            if mismatch:
                state['files'][PREFIX + '.linux-aarch64.rock'] = b'different published bytes'

            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass

                def respond(self, payload, code=200):
                    self.send_response(code)
                    self.end_headers()
                    self.wfile.write(payload if isinstance(payload, bytes) else json.dumps(payload).encode())

                def do_GET(self):
                    if self.path.startswith('/api/'):
                        if self.headers.get('Authorization') != 'Bearer test-key':
                            self.respond({'errors': ['bad auth']}, 401)
                        else:
                            self.respond({'version': {'id': 42} if existing else None})
                    elif self.path[1:] in state['files']:
                        self.respond(state['files'][self.path[1:]])
                    else:
                        self.respond(b'not found', 404)

                def do_POST(self):
                    if self.headers.get('Authorization') != 'Bearer test-key':
                        self.respond({'errors': ['bad auth']}, 401)
                        return
                    body = self.rfile.read(int(self.headers['Content-Length']))
                    state['posts'].append((self.path, body))
                    if self.path.endswith('/upload'):
                        self.respond({'version': {'id': 42}, 'module_url': 'https://example.test/module',
                                      'manifests': [{'name': 'root'}]})
                    else:
                        self.respond({'rock': {'id': 7}})

            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                yield root, state, 'http://127.0.0.1:' + str(server.server_port)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

    def publish(self, root, server):
        import os
        env = dict(os.environ, LUAROCKS_API_KEY='test-key')
        return subprocess.run(['python3', str(SCRIPT), str(root), '--version', '0.1.0', '--server', server],
                              env=env, text=True, capture_output=True)

    def test_publishes_source_and_both_binaries_to_one_version(self):
        with self.environment() as (root, state, server):
            result = self.publish(root, server)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([path for path, _ in state['posts']],
                             ['/api/1/bearer/upload'] + ['/api/1/bearer/upload_rock/42'] * 3)
            self.assertIn((PREFIX + '.src.rock').encode(), state['posts'][1][1])

    def test_identical_existing_version_is_not_overwritten(self):
        with self.environment(existing=True) as (root, state, server):
            result = self.publish(root, server)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(state['posts'], [])

    def test_different_published_bytes_abort_before_any_upload(self):
        with self.environment(existing=True, mismatch=True) as (root, state, server):
            result = self.publish(root, server)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('different', result.stderr)
            self.assertEqual(state['posts'], [])

    def test_mixed_version_rockspec_is_rejected_before_upload(self):
        with self.environment() as (root, state, server):
            with zipfile.ZipFile(root / (PREFIX + '.linux-aarch64.rock'), 'w') as archive:
                archive.writestr(PREFIX + '.rockspec', b'wrong rockspec')
            result = self.publish(root, server)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('rockspec', result.stderr)
            self.assertEqual(state['posts'], [])


if __name__ == '__main__':
    unittest.main()
