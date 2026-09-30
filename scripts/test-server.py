#!/usr/bin/env python3
"""仅回环的浏览器实机验收站：跳转、下载、上传和存储；不记录请求内容。"""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import argparse, json, time, struct, zlib, threading

ROOT = Path(__file__).resolve().parents[1] / 'Sources/Browser/Resources'
slow_requests = set()
slow_lock = threading.Lock()
class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(ROOT),**kwargs)
    def log_message(self,*args): pass
    def send_fixture(self,data,mime):
        self.send_response(200); self.send_header('Content-Type',mime); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith('/extension-page'):
            self.send_fixture(b'<!doctype html><meta charset=utf-8><title>Extension fixture</title><h1>Site permissions probe</h1><p>Owned local fixture.</p>','text/html'); return
        if self.path.startswith(('/extension-allowed','/extension-blocked')):
            self.send_fixture(b'fixture request','text/plain'); return
        if self.path.startswith('/escape-page/'):
            self.send_fixture(b'<!doctype html><title>Escape loading fixture</title><h1>Escape loading fixture</h1><input id=draft value=loading-draft><img src="/slow-image/escape">','text/html'); return
        if self.path.startswith('/slow-state/'):
            with slow_lock: active = self.path.removeprefix('/slow-state/') in slow_requests
            self.send_fixture(json.dumps({'active':active}).encode(),'application/json'); return
        if self.path.startswith('/slow-image/'):
            token = self.path.removeprefix('/slow-image/')
            with slow_lock: slow_requests.add(token)
            try:
                self.send_response(200); self.send_header('Content-Type','image/png'); self.send_header('Cache-Control','no-store'); self.send_header('Content-Length','1024'); self.end_headers()
                self.wfile.write(b'\x89PNG\r\n\x1a\n'); self.wfile.flush()
                time.sleep(5)
                self.wfile.write(b'0'*1016)
            except (BrokenPipeError,ConnectionResetError): pass
            finally:
                with slow_lock: slow_requests.discard(token)
            return
        if self.path.startswith('/broken-navigation'):
            self.close_connection = True
            self.connection.close()
            return
        if self.path.startswith('/fixture.png'):
            def chunk(kind,data): return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
            pixels = b''.join(b'\x00'+bytes([20,110,230,255])*64 for _ in range(48))
            data = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',64,48,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
            self.send_fixture(data,'image/png'); return
        if self.path.startswith('/fixture.svg'):
            self.send_fixture(b'<svg xmlns="http://www.w3.org/2000/svg" width="64" height="48"><rect width="64" height="48" fill="#ef6949"/><script>throw new Error("must not run")</script></svg>','image/svg+xml'); return
        if self.path.startswith('/fixture.ttf'):
            self.send_fixture(Path('/System/Library/Fonts/Supplemental/Arial.ttf').read_bytes(),'font/ttf'); return
        if self.path.startswith('/not-an-image'):
            self.send_fixture(b'<!doctype html><script>alert(1)</script>','image/png'); return
        if self.path.startswith('/oversized'):
            self.send_response(200); self.send_header('Content-Type','image/png'); self.send_header('Content-Length',str(3*1024*1024)); self.end_headers(); return

        if self.path.startswith('/slow-download'):
            self.send_response(200); self.send_header('Content-Type','application/octet-stream'); self.send_header('Content-Disposition','attachment; filename="pageglass-slow-test.bin"'); self.send_header('Content-Length',str(16*1024*1024)); self.end_headers()
            try:
                for _ in range(256):
                    self.wfile.write(b'P'*65536); self.wfile.flush(); time.sleep(0.25)
            except (BrokenPipeError,ConnectionResetError): pass
            return
        if self.path.startswith('/download'):
            data = b'Pageglass download verification\n' * 128
            self.send_response(200); self.send_header('Content-Type','application/octet-stream'); self.send_header('Content-Disposition','attachment; filename="pageglass-test.txt"'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        if self.path.startswith('/redirect'):
            self.send_response(302); self.send_header('Location','/demo.html'); self.end_headers(); return
        if self.path.startswith('/browser-test'):
            data = b'''<!doctype html><meta charset=utf-8><title>Browser QA</title><h1>Browser QA</h1><a href=/demo.html>Open demo</a><p><a href=/download>Download test file</a> <a href=/slow-download>Slow download for cancellation</a></p><form method=post enctype=multipart/form-data><input type=file name=file><button>Upload test file</button></form><button onclick="document.querySelector('output').textContent=confirm('Confirm test')?'confirmed':'cancelled'">Confirm dialog</button><output></output>'''
            self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data); return
        super().do_GET()
    def do_POST(self):
        size = int(self.headers.get('Content-Length','0'))
        if size > 1024 * 1024: self.send_error(413); return
        self.rfile.read(size)
        data = f'<!doctype html><title>Upload received</title><h1>Upload received</h1><p>{size} bytes</p>'.encode()
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(data)
if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=0); args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    print(json.dumps({'url':f'http://127.0.0.1:{server.server_port}','pid':__import__('os').getpid()}),flush=True)
    server.serve_forever()
