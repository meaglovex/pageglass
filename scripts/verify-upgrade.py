#!/usr/bin/env python3
"""Verify an existing local profile through a private copy; never mutate or publish the source."""
import argparse, hashlib, json, os, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--profile',type=Path,default=Path.home()/'Library/Application Support/Pageglass')
args = parser.parse_args()
source = args.profile
if not source.is_dir() or source.is_symlink() or (source/'browser.json').is_symlink():
    parser.error('expected a regular profile directory containing browser.json')
output = ROOT/'qa-output'/('upgrade-copy-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6])
output.mkdir(parents=True,mode=0o700)
files = [source/'browser.json']
captures = source/'Captures'
if captures.is_dir() and not captures.is_symlink():
    files += [p for p in captures.rglob('*') if p.is_file() and not p.is_symlink() and not any(a.is_symlink() for a in p.parents if a!=source)]
manifest = []
for file in files:
    data = file.read_bytes();relative = file.relative_to(source)
    target = output/relative;target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(data)
    manifest.append({'relative':str(relative),'sha256':hashlib.sha256(data).hexdigest()})
(output/'source-hashes.json').write_text(json.dumps(manifest))
env = os.environ.copy();env['PAGEGLASS_UPGRADE_COPY'] = str(output)
result = subprocess.run(['swift','test','--filter','UpgradeCopyTests'],cwd=ROOT,env=env)
unchanged = all(hashlib.sha256((source/item['relative']).read_bytes()).hexdigest()==item['sha256'] for item in manifest)
report = {'testExitCode':result.returncode,'sourceUnchanged':unchanged,'scope':'isolated profile save/reload and read-only capture compatibility'}
(output/'verification.json').write_text(json.dumps(report,indent=2))
print(json.dumps({'copy':str(output),**report}),flush=True)
raise SystemExit(result.returncode if unchanged else 1)
