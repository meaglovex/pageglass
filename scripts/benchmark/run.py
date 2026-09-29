#!/usr/bin/env python3
"""Repeatable local Speedometer 3.1 comparison; --run requires an unlocked foreground desktop."""
import argparse, hashlib, json, math, os, plistlib, signal, statistics, subprocess, sys, threading, time, uuid, zipfile
from pathlib import Path
import urllib.request
from process_metrics import measure
from server import BenchmarkServer

ROOT=Path(__file__).resolve().parents[2]
COMMIT='1386415be8fef2f6b6bbdbe1828872471c5d802a'
CHROME=Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
APP=ROOT/'dist/Pageglass.app'


def prepare():
    archive=ROOT/'qa-output/Speedometer-3.1.zip'
    if not archive.exists():
        archive.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(['curl','--fail','-L','--connect-timeout','10','--max-time','120',f'https://codeload.github.com/WebKit/Speedometer/zip/{COMMIT}','-o',str(archive)],check=True)
    with zipfile.ZipFile(archive) as z:
        if z.comment.decode()!=COMMIT: raise RuntimeError('Speedometer archive does not match pinned commit')
        first=Path(z.namelist()[0]).parts[0]
        for entry in z.namelist():
            path=Path(entry)
            if path.is_absolute() or '..' in path.parts:raise RuntimeError('unsafe archive path')
        source=ROOT/'qa-output'/first
        # Verify every extracted byte against the archive; do not overwrite local edits.
        if not source.exists():z.extractall(ROOT/'qa-output')
        digest=hashlib.sha256()
        for name in sorted(z.namelist()):
            if name.endswith('/'):continue
            expected=z.read(name);file=ROOT/'qa-output'/name
            if not file.exists() or file.read_bytes()!=expected:raise RuntimeError('benchmark source changed: '+name)
            digest.update(name.encode());digest.update(expected)
    helper=ROOT/'qa-output/benchmark-environment'
    swift=Path(__file__).with_name('environment.swift')
    if not helper.exists() or helper.stat().st_mtime<swift.stat().st_mtime:
        subprocess.run(['swiftc',str(swift),'-o',str(helper)],check=True)
    return source,helper,{'benchmark':'Speedometer 3.1','commit':COMMIT,'treeSHA256':digest.hexdigest(),'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'source':'https://github.com/WebKit/Speedometer/tree/'+COMMIT}


def environment(helper):return json.loads(subprocess.check_output([str(helper)],text=True))
def blockers(state):
    reasons=[]
    if not state['sessionAvailable'] or state['screenLocked']:reasons.append('desktop locked or session unavailable')
    if state['thermalState']!='nominal':reasons.append('thermal state is not nominal')
    if state['lowPowerMode']:reasons.append('low power mode enabled')
    return reasons


def terminate_owned(pid,plan):
    # PID reuse or a stale file must never cause an unrelated browser to be terminated.
    result=subprocess.run(['/bin/ps','-p',str(pid),'-o','args='],capture_output=True,text=True)
    if result.returncode==0 and '--benchmark-plan' in result.stdout and str(plan) in result.stdout:os.kill(pid,signal.SIGTERM)


def run_one(engine,server,helper,output,iterations,workload="speedometer",tabs=1,chrome_height=860):
    run=uuid.uuid4().hex;folder=output/run;folder.mkdir()
    url=f'http://127.0.0.1:{server.server_port}/run/{run}/index.html?iterationCount={iterations}&viewport=800x600'
    urls=[url] if workload=='speedometer' else [f'http://127.0.0.1:{server.server_port}/memory/{run}/{i}.html' for i in range(tabs)]
    state=environment(helper)
    if blockers(state):raise RuntimeError('; '.join(blockers(state)))
    profile=folder/'chrome-profile';pid=None;process=None;plan=folder/'plan.json'
    if engine=='pageglass':
        plan.write_text(json.dumps({'urls':urls,'output':folder.as_uri(),'websiteDataID':str(uuid.uuid4())}))
        subprocess.run(['/usr/bin/open','-n',str(APP),'--args','--benchmark-plan',str(plan)],check=True)
    else:
        log=(folder/'chrome.log').open('w')
        process=subprocess.Popen([str(CHROME),'--user-data-dir='+str(profile),'--no-first-run','--no-default-browser-check','--new-window',f'--window-size=1280,{chrome_height}',*urls],stdout=log,stderr=log)
        log.close();pid=process.pid
    started=time.monotonic();states=[state]
    try:
        while time.monotonic()-started<600:
            if engine=='pageglass' and pid is None and (folder/'native-state.json').exists():pid=json.loads((folder/'native-state.json').read_text())['pid']
            with server.results_lock: result=json.loads(json.dumps(server.results.get(run)))
            if (folder/'native-error.json').exists():raise RuntimeError((folder/'native-error.json').read_text())
            if result is not None and (workload=='speedometer' or len(result.get('tabs',{}))==tabs):break
            if process is not None and process.poll() is not None:raise RuntimeError('Chrome exited before a result')
            time.sleep(5);state=environment(helper);states.append(state)
            if blockers(state):raise RuntimeError('measurement invalidated: '+'; '.join(blockers(state)))
            if pid is not None and state['frontmostPID']!=pid:raise RuntimeError('measurement invalidated: browser not foreground')
        else:raise RuntimeError('benchmark timeout (no completion report)')
        state=environment(helper);states.append(state)
        if blockers(state):raise RuntimeError('measurement invalidated at finish')
        if workload=='speedometer' and (result.get('status')!='completed' or result.get('invalid')):raise RuntimeError('invalid benchmark: '+str(result.get('error') or result.get('invalid')))
        score=result.get('score',{})
        values=score.get('values',[])
        if workload=='speedometer' and (len(values)!=iterations or any(not isinstance(v,(float,int)) or not math.isfinite(v) or v<=0 for v in values)):raise RuntimeError('incomplete score samples')
        if pid is None:raise RuntimeError('native browser PID not reported')
        samples=[]
        if workload=='memory':
            if any(t.get('rows')!=1000 or not t.get('ready') for t in result['tabs'].values()):raise RuntimeError('not all memory fixture tabs loaded')
            time.sleep(5)
            # Loading bars can resize the page after load; use settled viewport reports.
            with server.results_lock: result=json.loads(json.dumps(server.results[run]))
            visible=[t for t in result['tabs'].values() if t.get('visible')]
            if len(visible)!=1:raise RuntimeError('memory fixture must have exactly one visible tab')
            viewport=visible[0]['viewport']
            for _ in range(5):
                state=environment(helper);states.append(state)
                if blockers(state) or state['frontmostPID']!=pid:raise RuntimeError('memory sample invalidated: desktop state or foreground changed')
                samples.append(measure(pid,engine,profile if engine=='chrome' else None));time.sleep(1)
            with server.results_lock: settled=json.loads(json.dumps(server.results[run]))
            if [t['viewport'] for t in settled['tabs'].values() if t.get('visible')]!=[viewport]:raise RuntimeError('memory sample invalidated: visible viewport changed')
            result=settled;result['measuredViewport']=viewport
            result['memorySamples']=samples;result['status']='completed'
        memory=samples[-1] if samples else measure(pid,engine,profile if engine=='chrome' else None)
        result.update({'engine':engine,'environment':states,'memoryAfterBenchmark':memory,'elapsedSeconds':time.monotonic()-started})
        (folder/'result.json').write_text(json.dumps(result,indent=2))
        return {'run':run,'engine':engine,'workload':workload,'tabs':tabs,'score':score.get('mean'),'iterations':iterations if workload=='speedometer' else None,'viewport':result.get('measuredViewport',result.get('viewport')),'physicalFootprintBytes':statistics.median(s['physicalFootprintBytes'] for s in samples) if samples else memory['physicalFootprintBytes']}
    finally:
        (folder/'environment.json').write_text(json.dumps(states,indent=2))
        if process is not None:
            if process.poll() is None:process.terminate()
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:raise RuntimeError('owned test Chrome did not exit; inspect it before another run')
        elif pid is not None:terminate_owned(pid,plan)


def main():
    global APP
    parser=argparse.ArgumentParser();parser.add_argument('--run',action='store_true');parser.add_argument('--rounds',type=int,default=3);parser.add_argument('--iterations',type=int,default=10);parser.add_argument('--workload',choices=['speedometer','memory'],default='speedometer');parser.add_argument('--pageglass-app',type=Path,default=APP);parser.add_argument('--engines',choices=['both','pageglass','chrome'],default='both');parser.add_argument('--chrome-window-height',type=int,default=860);args=parser.parse_args()
    APP=args.pageglass_app.resolve()
    engines=['pageglass','chrome'] if args.engines=='both' else [args.engines]
    if not 640 <= args.chrome_window_height <= 2160:parser.error('Chrome window height must be between 640 and 2160')
    if args.rounds<3 or args.iterations<10:parser.error('comparison requires at least 3 rounds and 10 iterations')
    source,helper,provenance=prepare()
    output=ROOT/'qa-output'/('benchmark-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]);output.mkdir()
    env=environment(helper)
    versions={}
    for name,executable,plist in [('pageglass',APP/'Contents/MacOS/Pageglass',APP/'Contents/Info.plist'),('chrome',CHROME,CHROME.parents[1]/'Info.plist')]:
        if plist.exists() and executable.exists():versions[name]={'version':plistlib.loads(plist.read_bytes()).get('CFBundleShortVersionString'),'executableSHA256':hashlib.sha256(executable.read_bytes()).hexdigest()}
    provenance['browsers']=versions
    provenance['engines']=engines
    provenance['chromeWindowHeight']=args.chrome_window_height
    provenance['hardwareModel']=subprocess.check_output(['sysctl','-n','hw.model'],text=True).strip()
    preflight={'environment':env,'blockers':blockers(env),'source':provenance,'mode':'run' if args.run else 'prepare-only'}
    (output/'preflight.json').write_text(json.dumps(preflight,indent=2));print(json.dumps({'output':str(output),**preflight}),flush=True)
    if not args.run:return
    if preflight['blockers']:print('Benchmark not started: '+'; '.join(preflight['blockers']),file=sys.stderr);sys.exit(2)
    if not CHROME.is_file() or not APP.is_dir():raise RuntimeError('build Pageglass and install official Chrome first')
    server=BenchmarkServer(source,output);threading.Thread(target=server.serve_forever,daemon=True).start()
    results=[]
    try:
        for round_number in range(args.rounds):
            for engine in (engines if round_number%2==0 else list(reversed(engines))):
                for tabs in ([1,5,10] if args.workload=='memory' else [1]):
                    result=run_one(engine,server,helper,output,args.iterations,args.workload,tabs,args.chrome_window_height);results.append(result)
                    print(json.dumps(result),flush=True);(output/'runs.json').write_text(json.dumps(results,indent=2))
        if args.workload=='speedometer':
            means={e:statistics.median(r['score'] for r in results if r['engine']==e) for e in engines}
            comparison={'medianScore':means,'pageglassToChromeScoreRatio':means['pageglass']/means['chrome'] if len(engines)==2 else None,'scope':'Speedometer 3.1 responsiveness only; post-benchmark footprint is not a multi-tab memory comparison'}
        else:
            comparison={'medianPhysicalFootprintBytes':{str(tabs):{e:statistics.median(r['physicalFootprintBytes'] for r in results if r['engine']==e and r['tabs']==tabs) for e in engines} for tabs in [1,5,10]},'scope':'1/5/10 fully loaded same-origin PM fixture tabs; not representative of all websites; compare recorded viewports before acceptance'}
        if args.workload=='memory' and len({json.dumps(r['viewport'],sort_keys=True) for r in results})!=1:
            raise RuntimeError('viewports differ; calibrate window heights before accepting a comparison (raw samples retained)')
        report={'status':'completed','source':provenance,'runs':results,**comparison}
        (output/'summary.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
    finally:server.shutdown();server.server_close()

if __name__=='__main__':
    try:main()
    except (RuntimeError,OSError,subprocess.SubprocessError) as error:print('BENCHMARK FAILED: '+str(error),file=sys.stderr);sys.exit(1)
