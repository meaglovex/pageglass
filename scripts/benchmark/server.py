#!/usr/bin/env python3
"""Pinned Speedometer source served locally; measured benchmark files remain unmodified."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import argparse, hashlib, json, re, threading
from urllib.parse import urlsplit

class BenchmarkServer(ThreadingHTTPServer):
    def __init__(self, source, output):
        self.source, self.output, self.results = Path(source), Path(output), {}
        self.adapter = Path(__file__).with_name('adapter.js').read_bytes()
        self.results_lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), Handler)

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(args[2].source),**kwargs)
    def log_message(self,*args): pass
    def do_GET(self):
        path = urlsplit(self.path).path
        memory=re.fullmatch(r'/memory/([0-9a-f]{32})/(\d)\.html',path)
        if memory:
            data=(f'<!doctype html><title>PM workspace memory fixture</title><style>html,body{{margin:0}}iframe{{display:block;border:0;width:1280px;height:760px}}</style><iframe title="Fixed viewport workspace" src="/memory-content/{memory[1]}/{memory[2]}.html"></iframe>').encode()
            self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(data);return
        memory=re.fullmatch(r'/memory-content/([0-9a-f]{32})/(\d)\.html',path)
        if memory:
            data=Path(__file__).with_name('memory.html').read_text().replace('%%RUN%%',memory[1]).replace('%%TAB%%',memory[2]).encode()
            self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(data);return
        if path == '/__bench/adapter.js':
            self.send_response(200);self.send_header('Content-Type','text/javascript');self.end_headers();self.wfile.write(self.server.adapter);return
        match = re.match(r'^/run/([0-9a-f]{32})/(.*)$',path)
        if match:
            run,relative = match.groups()
            if relative in ('','index.html'):
                content = (self.server.source/'index.html').read_text()
                # Install diagnostics before module loading; the benchmark still starts after load.
                content = content.replace('<head>',f'<head><script src="/__bench/adapter.js?run={run}"></script>',1)
                data=content.encode(); self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(data);return
            self.path = '/' + relative
        super().do_GET()
    def do_POST(self):
        match=re.fullmatch(r'/__bench/result/([0-9a-f]{32})',urlsplit(self.path).path)
        size=int(self.headers.get('Content-Length','0'))
        if not match or size > 8*1024*1024 or size <= 0: self.send_error(400);return
        try:
            value=json.loads(self.rfile.read(size));run=match[1]
            if not isinstance(value,dict):raise ValueError()
            with self.server.results_lock:
                if value.get('kind')=='memory':
                    tab=value.get('tab')
                    if not isinstance(tab,int) or not 0<=tab<10:raise ValueError()
                    aggregate=self.server.results.get(run,{'status':'loading','tabs':{}})
                    aggregate['tabs'][str(tab)]=value;value=aggregate
                self.server.results[run]=value
                folder=self.server.output/run;folder.mkdir(parents=True,exist_ok=True)
                temporary=folder/'result.tmp';temporary.write_text(json.dumps(value,indent=2));temporary.replace(folder/'result.json')
            self.send_response(204);self.end_headers()
        except (ValueError,OSError):self.send_error(400)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    server=BenchmarkServer(a.source,a.output)
    print(json.dumps({'url':f'http://127.0.0.1:{server.server_port}'}),flush=True);server.serve_forever()
