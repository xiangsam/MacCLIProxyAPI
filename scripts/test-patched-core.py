#!/usr/bin/env python3
"""Exercise the real model API and native Responses against a loopback mock only."""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

binary = str(pathlib.Path(sys.argv[1]).resolve())
received = []

class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        received.append((self.path, body))
        result = {'id': 'resp_test', 'object': 'response', 'status': 'completed',
                  'model': 'native-model', 'output': [],
                  'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
        payload = ('event: response.completed\ndata: ' + json.dumps(
            {'type': 'response.completed', 'response': result}) + '\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
threading.Thread(target=upstream.serve_forever, daemon=True).start()

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def call(port, path, data=None, key='test-client', method=None):
    request = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path),
        data=None if data is None else json.dumps(data).encode(), method=method,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)

try:
    for layout in ('legacy', 'v8'):
        with tempfile.TemporaryDirectory(prefix='maccli-core-smoke-') as directory:
            port = free_port()
            providers = [
                {'api-key': 'fake-deepseek', 'base-url': 'https://api.deepseek.com/v1',
                 'models': [{'name': 'deepseek-v4-flash', 'alias': 'deepseek-fast'}]},
                {'api-key': 'fake-local', 'base-url': 'http://127.0.0.1:%d/v1' % upstream.server_port,
                 'models': [{'name': 'native-model', 'alias': 'native-test', 'owned-by': 'deepseek'}]},
            ]
            common = {'plugins': {'enabled': False}, 'routing': {'strategy': 'fill-first'}}
            if layout == 'legacy':
                config = dict(common, **{'host': '127.0.0.1', 'port': port,
                    'auth-dir': directory + '/oauth', 'api-keys': ['test-client'],
                    'remote-management': {'secret-key': 'test-management', 'disable-control-panel': True},
                    'disable-image-generation': 'chat', 'codex-api-key': providers})
            else:
                groups = []
                for index, provider in enumerate(providers):
                    groups.append({'name': 'provider-%d' % index, 'base-url': provider['base-url'],
                        'models': provider['models'], 'keys': [{'api-key': provider['api-key']}]})
                config = dict(common, **{'config-version': 8, 'server': {'host': '127.0.0.1', 'port': port},
                    'oauth': {'auth-dir': directory + '/oauth'}, 'access': {'api-keys': ['test-client']},
                    'management': {'secret-key': 'test-management', 'disable-control-panel': True},
                    'multimedia': {'disable-image-generation': 'chat'}, 'api-keys': {'codex': groups}})
            path = pathlib.Path(directory, 'config.yaml')
            path.write_text(json.dumps(config))
            with open(pathlib.Path(directory, 'core.log'), 'w+') as log:
                process = subprocess.Popen([binary, '-config', str(path), '-local-model'],
                    cwd=directory, stdout=log, stderr=subprocess.STDOUT)
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            log.seek(0)
                            raise AssertionError('Core exited: ' + log.read()[-4000:])
                        try:
                            models = call(port, '/v1/models')['data']
                            if any(m['id'] == 'deepseek-fast' for m in models): break
                        except (OSError, urllib.error.URLError):
                            pass
                        time.sleep(.1)
                    else:
                        raise AssertionError('Model registration timed out')
                    indexed = {m['id']: m for m in models}
                    assert indexed['deepseek-fast']['owned_by'] == 'deepseek', indexed
                    assert indexed['native-test']['owned_by'] == 'deepseek', indexed
                    try:
                        call(port, '/v1/models', key='wrong-key')
                        raise AssertionError('Model endpoint accepted invalid authentication')
                    except urllib.error.HTTPError as error:
                        assert error.code == 401
                    tools = [{'type': 'custom', 'name': 'apply_patch', 'description': 'test'}]
                    response = call(port, '/v1/responses', {
                        'model': 'native-test', 'input': [{'role': 'user', 'content': 'test'}],
                        'tools': tools, 'stream': False})
                    assert response['id'] == 'resp_test', response
                    forwarded_path, forwarded_body = received[-1]
                    assert forwarded_path == '/v1/responses', forwarded_path
                    assert forwarded_body['model'] == 'native-model', forwarded_body
                    assert forwarded_body['tools'] == tools, forwarded_body
                    # v0 provider endpoints must stay usable with both on-disk layouts.
                    payload = call(port, '/v0/management/codex-api-key', key='test-management')
                    rows = payload['codex-api-key']
                    assert len(rows) == 2, payload
                    assert rows[1]['models'][0]['owned-by'] == 'deepseek', rows
                    call(port, '/v0/management/codex-api-key', rows,
                         key='test-management', method='PUT')
                    assert call(port, '/v1/models')['data']
                    print(layout + ': model ownership, authentication, native Responses and v0 management passed')
                finally:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
finally:
    upstream.shutdown()
    upstream.server_close()
