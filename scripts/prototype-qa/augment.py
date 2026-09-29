#!/usr/bin/env python3
"""Build a scoped, editable demo from a capture packet, never from the original app source."""
import argparse, hashlib, json, re, shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('capture', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
source = args.capture.resolve()
metadata = json.loads((source/'capture.json').read_text())
html = (source/'reference.html').read_text()
timeline = json.loads((source/'interaction-history/timeline.json').read_text())
assert metadata['mode'] == 'page' and 'id="metric-card"' in html, 'Use the owned dashboard QA capture.'
assert any(step.get('before', {}).get('selector') == '#new-request' and step.get('before', {}).get('expanded') == 'false' and step.get('after', {}).get('expanded') == 'true' for step in timeline['steps']), 'Observed expand/collapse state is required.'
assert not re.search(r'<script\b', html, re.I), 'Only sanitized capture HTML is accepted.'
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
(output/'reference.html').write_text(html)
if (source/'assets').exists():
    shutil.copytree(source/'assets', output/'assets')
nonce = 'pageglass-owned-prototype-example'
# The only executable code is written below; captured website scripts remain excluded.
html = html.replace("default-src 'none';", f"default-src 'none'; script-src 'nonce-{nonce}';", 1)
css = '''<style>
#metric-card{position:relative}
#prototype-details{position:absolute;right:16px;top:16px;box-sizing:border-box;border:1px solid #cfddd5;border-radius:6px;background:#f4f8f5;color:#275e49;-webkit-text-fill-color:currentColor;padding:4px 8px;font:12px/18px -apple-system,sans-serif;cursor:pointer}
#prototype-details:focus-visible{outline:2px solid #275e49;outline-offset:3px}
#prototype-dialog{box-sizing:border-box;border:1px solid #dce5df;border-radius:16px;padding:28px;width:420px;max-width:calc(100vw - 40px);color:#263341;background:#fff;font:14px/1.6 -apple-system,sans-serif;box-shadow:0 18px 80px #102b2430}
#prototype-dialog::backdrop{background:#172d2444;backdrop-filter:blur(3px)}
#prototype-dialog,#prototype-dialog *{-webkit-text-fill-color:currentColor}
#prototype-dialog h2{font-size:20px;margin:0 0 12px}#prototype-dialog p{margin:10px 0}
#prototype-close{background:#275e49;color:#fff;border:0;border-radius:8px;font:14px -apple-system,sans-serif;padding:10px 18px;cursor:pointer}
#prototype-dialog .prototype-note{color:#7b8691;font-size:12px}
</style>'''
html = html.replace('</head>', css+'</head>')
addon = f'''<dialog id="prototype-dialog" aria-labelledby="prototype-dialog-title"><h2 id="prototype-dialog-title">本月活跃用户</h2><p>12,840 位用户，较上月增长 18.6%。</p><p class="prototype-note">本地交互原型 · 数据来自捕获画面，不连接真实业务系统。</p><button id="prototype-close">关闭详情</button></dialog>
<script nonce="{nonce}">
const card=document.querySelector('#metric-card');
const details=document.createElement('button');details.id='prototype-details';details.type='button';details.textContent='查看详情';details.setAttribute('aria-haspopup','dialog');details.setAttribute('aria-controls','prototype-dialog');card.appendChild(details);
const dialog=document.querySelector('#prototype-dialog');
details.addEventListener('click',()=>dialog.showModal());
document.querySelector('#prototype-close').addEventListener('click',()=>dialog.close());
const observedButton=document.querySelector('#new-request'),notice=document.querySelector('#notice');
observedButton.addEventListener('click',()=>{{const expanded=observedButton.getAttribute('aria-expanded')!=='true';observedButton.setAttribute('aria-expanded',String(expanded));notice.style.display=expanded?'':'none';}});
</script>'''
html = html.replace('</body></html>', addon+'</body></html>')
(output/'prototype.html').write_text(html)
record = {'capture':str(source),'referenceSHA256':hashlib.sha256((source/'reference.html').read_bytes()).hexdigest(),'screenshotSHA256':hashlib.sha256((source/'screenshot.png').read_bytes()).hexdigest(),'implementation':'Captured DOM/CSS + explicitly written details dialog and observed expand/collapse behavior. No original page JS.','scope':'Owned fixture only; fixed captured viewport, not a general website recreation claim.'}
(output/'provenance.json').write_text(json.dumps(record,ensure_ascii=False,indent=2))
print(output/'prototype.html')
