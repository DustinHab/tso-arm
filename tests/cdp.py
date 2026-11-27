#!/usr/bin/env python3
"""What a Chromium or Electron program started with --remote-debugging-port=PORT shows: its targets (list.json) and,
for each page, its address, how far it loaded, its title and the start of its text (page-N.json) and a screenshot
(page-N.png). Python's standard library only (a WebSocket client of its own).
    tests/cdp.py PORT OUTDIR"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.request

port, out = int(sys.argv[1]), sys.argv[2]
os.makedirs(out, exist_ok=True)


def http(path):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}', timeout=10) as r:
        return r.read()


class WS:
    def __init__(self, url):
        rest = url.split('://', 1)[1]
        hostport, path = rest.split('/', 1)
        host, p = hostport.rsplit(':', 1)
        self.s = socket.create_connection((host, int(p)), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        head = b''
        while b'\r\n\r\n' not in head:
            c = self.s.recv(1)
            if not c:
                raise OSError('closed during the handshake')
            head += c
        if b' 101 ' not in head.split(b'\r\n', 1)[0]:
            raise OSError(head.split(b'\r\n', 1)[0].decode())
        self.n = 0

    def _read(self, k):
        b = b''
        while len(b) < k:
            c = self.s.recv(k - len(b))
            if not c:
                raise OSError('closed')
            b += c
        return b

    def send(self, method, params=None):
        self.n += 1
        data = json.dumps({'id': self.n, 'method': method, 'params': params or {}}).encode()
        mask = os.urandom(4)
        h = bytes([0x81])
        if len(data) < 126:
            h += bytes([0x80 | len(data)])
        elif len(data) < 65536:
            h += bytes([0x80 | 126]) + struct.pack('>H', len(data))
        else:
            h += bytes([0x80 | 127]) + struct.pack('>Q', len(data))
        self.s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
        while True:
            m = json.loads(self.message())
            if m.get('id') == self.n:
                return m

    def message(self):
        payload = b''
        while True:
            b0, b1 = self._read(2)
            k = b1 & 0x7f
            if k == 126:
                k = struct.unpack('>H', self._read(2))[0]
            elif k == 127:
                k = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            d = self._read(k)
            if mask:
                d = bytes(b ^ mask[i % 4] for i, b in enumerate(d))
            if b0 & 0x0f == 8:
                raise OSError('closed by the program')
            if b0 & 0x0f in (9, 10):
                continue
            payload += d
            if b0 & 0x80:
                return payload


targets = json.loads(http('/json/list'))
with open(os.path.join(out, 'list.json'), 'w') as f:
    json.dump(targets, f, indent=1)
expr = ('JSON.stringify({href: location.href, ready: document.readyState, title: document.title, '
        'visibility: document.visibilityState, text: document.body ? document.body.innerText.slice(0, 800) : null})')
for i, t in enumerate(x for x in targets if x.get('type') == 'page' and x.get('webSocketDebuggerUrl')):
    info = {'url': t.get('url'), 'title': t.get('title')}
    try:
        ws = WS(t['webSocketDebuggerUrl'])
        r = ws.send('Runtime.evaluate', {'expression': expr, 'returnByValue': True, 'timeout': 5000})
        info['page'] = r.get('result', {}).get('result', {}).get('value') or r
        r = ws.send('Page.captureScreenshot', {'format': 'png'})
        if 'result' in r:
            with open(os.path.join(out, f'page-{i}.png'), 'wb') as f:
                f.write(base64.b64decode(r['result']['data']))
        else:
            info['screenshot'] = r
    except Exception as e:  # noqa: BLE001 - recorded, the check goes on
        info['error'] = repr(e)
    with open(os.path.join(out, f'page-{i}.json'), 'w') as f:
        json.dump(info, f, indent=1)
    print(f"cdp: page {i}: {info.get('url')}: {str(info.get('page', info.get('error')))[:200]}")
