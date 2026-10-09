#!/usr/bin/env python3
"""Compile isolated actual BrowserStore/TabButton/PNG paths with fixed scaffolding.
Not an end-to-end browser benchmark. No user profiles or visible windows.
"""
import argparse,hashlib,json,subprocess,tempfile,time,statistics
from pathlib import Path
from run import environment,blockers
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
STUB='''import AppKit
struct QAProfile { static let current:QAProfile? = nil; let directory:URL }
@MainActor final class BrowserTab:NSObject {
 let id=UUID();var title="新标签页";var url:URL?;var favicon:NSImage?
 init(url:URL? = nil) { self.url=url }
}
'''
LEGACY='''import AppKit
enum CapturePNG {
 @MainActor static func encode(_ image:NSImage) async throws -> Data {
  guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else { throw NSError(domain:"LegacyPNG",code:1) }
  return png
 }
}
'''
def digest(data):return hashlib.sha256(data).hexdigest()
def source(ref,path):
 return subprocess.check_output(['git','show',ref+':'+path],cwd=ROOT) if ref else (ROOT/path).read_bytes()
def prepare(folder,ref):
 folder.mkdir()
 files=['Sources/Browser/BrowserStore.swift','Sources/Browser/TabButton.swift','Sources/Browser/BrowserStyle.swift']
 hashes={}
 for path in files:
  data=source(ref,path);hashes[path]=digest(data)
  if path.endswith('BrowserStyle.swift'):
   # Actual shared native control/style code; exclude BrowserWindow extensions.
   data=data.split(b'extension BrowserWindow {',1)[0]
  (folder/Path(path).name).write_bytes(data)
 try:png=source(ref,'Sources/Browser/CapturePNG.swift');mode='CapturePNG source'
 except subprocess.CalledProcessError:
  original=source(ref,'Sources/Browser/CaptureService.swift')
  if b'image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:])' not in original:raise RuntimeError('unknown legacy encoding path')
  hashes['Sources/Browser/CaptureService.swift']=digest(original);png=LEGACY.encode();mode='legacy TIFF expression extracted from verified CaptureService path'
 hashes['Sources/Browser/CapturePNG.swift']=digest(png)
 (folder/'CapturePNG.swift').write_bytes(png)
 (folder/'Scaffolding.swift').write_text(STUB)
 (folder/'HotPathsProbe.swift').write_bytes((HERE/'HotPathsProbe.swift').read_bytes())
 executable=folder/'hotpaths'
 subprocess.run(['swiftc','-O','-parse-as-library','-o',str(executable),*map(str,sorted(folder.glob('*.swift')))],check=True,capture_output=True,text=True)
 return {'ref':ref or 'working-tree','sourceHashes':hashes,'encoderMode':mode,'executableSHA256':digest(executable.read_bytes()),'executable':str(executable)}
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--baseline-ref',required=True);parser.add_argument('--candidate-ref');args=parser.parse_args()
 output=Path(tempfile.mkdtemp(prefix='pageglass-hotpaths-',dir='/tmp')).resolve()
 print(json.dumps({'output':str(output)}),flush=True)
 builds={name:prepare(output/name,ref) for name,ref in [('baseline',args.baseline_ref),('candidate',args.candidate_ref)]}
 helper=ROOT/'qa-output/benchmark-environment'
 preflight={'builds':builds,'runnerSHA256':digest(Path(__file__).read_bytes()),'probeSHA256':digest((HERE/'HotPathsProbe.swift').read_bytes()),'scaffoldingSHA256':digest(STUB.encode()),'environment':environment(helper),'scope':'release microbenchmarks with actual source; stub only the unused BrowserTab fields and QAProfile; no WebKit, visible rendering, network or browser-wide performance claim'}
 (output/'preflight.json').write_text(json.dumps(preflight,indent=2))
 results=[]
 for number in range(3):
  for mode in ['search','tabs','png']:
   for name in (['baseline','candidate'] if number%2==0 else ['candidate','baseline']):
    before=environment(helper)
    if blockers(before):raise RuntimeError('measurement blocked: '+str(blockers(before)))
    record=subprocess.run([builds[name]['executable'],mode,str(output/f'profile-{name}-{number}')],capture_output=True,text=True,check=True,timeout=90)
    after=environment(helper)
    value={'build':name,'round':number+1,'result':json.loads(record.stdout),'environmentBefore':before,'environmentAfter':after}
    results.append(value);(output/'samples.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
    if blockers(after):raise RuntimeError('measurement invalidated: '+str(blockers(after)))
    print(json.dumps({'round':number+1,'build':name,'mode':mode}),flush=True)
 # Equivalence is checked independently of speed.
 for mode in ['search','tabs','png']:
  samples=[v['result'] for v in results if v['result']['mode']==mode]
  keys=['queries'] if mode=='search' else ['selected','firstTitle'] if mode=='tabs' else ['pixelSHA256','width','height','logicalWidth','logicalHeight']
  if mode=='search':
   values=[[(q['query'],q['urls'],q['checksum']) for q in s['queries']] for s in samples]
  else:values=[{k:s[k] for k in keys} for s in samples]
  if not all(v==values[0] for v in values):raise RuntimeError('output equivalence failed: '+mode)
 (output/'summary.json').write_text(json.dumps({'status':'completed','preflight':preflight,'samples':results},indent=2,ensure_ascii=False))
 print(json.dumps({'status':'completed','output':str(output)}),flush=True)
if __name__=='__main__':
 try:main()
 except subprocess.CalledProcessError as e:print(e.stderr,flush=True);raise
