#!/usr/bin/env python3
"""Native experience probe, built from a named commit in an isolated temporary source copy.

Never modifies dist/ or the checkout. --diagnostic validates the harness only and
cannot produce accepted performance scores. Formal runs require >=3 clean rounds.
"""
import argparse
import difflib
import hashlib
import io
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import statistics
import subprocess
import tarfile
import tempfile
import time
import uuid

from process_metrics import cpu_time, measure, process_group
from run import blockers, environment

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
RUNNER_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
STARTUP_HOOK = '''        if let index = args.firstIndex(of:"--experience-plan"),args.count > index+1 {
            Task { @MainActor in await ExperienceProbe.run(path:args[index+1],delegate:self) }; return
        }
'''


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(ref):
    commit = subprocess.check_output(['git', 'rev-parse', '--verify', ref + '^{commit}'], cwd=ROOT, text=True).strip()
    build = Path(tempfile.mkdtemp(prefix='pageglass-experience-build-', dir='/tmp')).resolve()
    source = build / 'source'; source.mkdir()
    archive = subprocess.check_output(['git', 'archive', '--format=tar', commit], cwd=ROOT)
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        bundle.extractall(source, filter='data')
    delegate = source / 'Sources/Browser/AppDelegate.swift'
    original = delegate.read_text()
    anchor = '        makeMenus(); let args = CommandLine.arguments\n'
    if original.count(anchor) != 1:
        raise RuntimeError('unknown AppDelegate startup hook; inspect before instrumentation')
    modified = original.replace(anchor, anchor + STARTUP_HOOK)
    delegate.write_text(modified)
    (build / 'startup-hook.patch').write_text(''.join(difflib.unified_diff(original.splitlines(True), modified.splitlines(True), fromfile='AppDelegate.swift', tofile='AppDelegate.swift')))
    (source / 'Sources/Browser/ExperienceProbe.swift').write_bytes((HERE / 'ExperienceProbe.swift').read_bytes())
    subprocess.run(['zsh', 'scripts/build.sh'], cwd=source, check=True)
    app = source / 'dist/Pageglass.app'
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = 'dev.pageglass.experience.' + commit[:12]
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    manifest = {'sourceCommit': commit, 'probeSHA256': digest(HERE / 'ExperienceProbe.swift'),
                'fixtureSHA256': digest(HERE / 'experience.html'), 'startupHookSHA256': digest(build / 'startup-hook.patch'),
                'executableSHA256': digest(app / 'Contents/MacOS/Pageglass'), 'version': info['CFBundleShortVersionString'],
                'app': str(app), 'scope': 'instrumented release source snapshot; not the distributed executable'}
    save(build / 'build.json', manifest)
    return build, manifest


def cpu_seconds(pid):
    group = process_group(pid, 'pageglass')
    return {item['pid']: cpu_time(item['pid']) for item in group}


def owned_pid(app, plan):
    marker = str(app / 'Contents/MacOS/Pageglass') + ' --benchmark-plan ' + str(plan) + ' --experience-plan ' + str(plan)
    for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == marker:
            return int(parts[0])
    return None


def one_round(app, folder, helper, diagnostic):
    folder.mkdir()
    fixture = folder / 'fixture.html'; fixture.write_bytes((HERE / 'experience.html').read_bytes())
    plan = folder / 'plan.json'
    save(plan, {'fixture': fixture.as_uri(), 'output': folder.as_uri(), 'websiteDataID': str(uuid.uuid4())})
    states, samples, completed_phases = [], {}, set()
    pid = None
    def check():
        state = environment(helper); states.append(state)
        reasons = blockers(state)
        if pid is not None and (folder / 'startup.json').exists() and state['frontmostPID'] != pid:
            reasons.append('browser not foreground')
        if reasons and not diagnostic:
            raise RuntimeError('measurement invalidated: ' + '; '.join(reasons))
    def wait(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            time.sleep(max(0, min(1, deadline - time.monotonic()))); check()
    def footprint():
        for attempt in range(3):
            check()
            try:
                value = measure(pid, 'pageglass'); check(); return value
            except RuntimeError as error:
                if not any(text in str(error) for text in ['process group changed during sample', 'footprint reported errors:']):
                    raise
                samples.setdefault('discarded', []).append({'attempt': attempt + 1, 'reason': str(error)})
                if attempt == 2: raise
                wait(1)
    try:
        check()
        launch_at = time.time()
        subprocess.run(['open', '-n', str(app), '--args', '--benchmark-plan', str(plan), '--experience-plan', str(plan)], check=True)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            pid = owned_pid(app, plan)
            if pid is None:
                if time.time() - launch_at > 15: raise RuntimeError('owned probe process did not start or has exited')
                time.sleep(.25); continue
            check()
            result_file = folder / 'experience.json'
            if result_file.exists():
                result = json.loads(result_file.read_text())
                if result.get('status') != 'completed': raise RuntimeError(result.get('error', 'probe failed'))
                expected = {'idle', 'loaded', 'before-capture', 'after-element', 'after-page', 'released'}
                if completed_phases != expected or result['remainingTabs'] != 1 or result['remainingWebViews'] != 1 or not result['closedWebViewsReleased']:
                    raise RuntimeError('incomplete experience or release checks')
                values = [item['milliseconds'] for item in result['switches']]
                if len(values) != 30 or any(not math.isfinite(value) or value <= 0 for value in values):
                    raise RuntimeError('invalid tab activation samples')
                startup = json.loads((folder / 'startup.json').read_text())
                elapsed = (startup['addressReadyAt'] - launch_at) * 1000
                if not 0 < elapsed < 15000: raise RuntimeError('invalid launch-to-editor timestamp')
                result.update({'launchToEditableAddressMilliseconds': elapsed, 'startup': startup,
                               'samples': samples, 'environment': states, 'accepted': not diagnostic,
                               'diagnostic': diagnostic})
                save(folder / 'result.json', result); return result
            checkpoint_file = folder / 'checkpoint.json'
            if checkpoint_file.exists():
                phase = json.loads(checkpoint_file.read_text())['phase']
                if phase not in completed_phases:
                    if phase == 'idle':
                        wait(5)
                        before = cpu_seconds(pid); started = time.monotonic()
                        wait(10)
                        after = cpu_seconds(pid); duration = time.monotonic() - started
                        if before.keys() != after.keys(): raise RuntimeError('process group changed during idle CPU measurement')
                        if any(before[p]['startTicks'] != after[p]['startTicks'] for p in before): raise RuntimeError('attributed PID was reused during CPU sample')
                        delta = sum(after[p]['seconds'] - before[p]['seconds'] for p in before)
                        if delta < 0: raise RuntimeError('CPU counters decreased')
                        samples['idleCPU'] = {'durationSeconds': duration, 'cpuSeconds': delta,
                                              'percentOfOneCore': delta / duration * 100,
                                              'counter': 'proc_pid_rusage Mach ticks converted by mach_timebase_info',
                                              'timebase': next(iter(before.values()))['timebase'],
                                              'before': {p: value['seconds'] for p, value in before.items()},
                                              'after': {p: value['seconds'] for p, value in after.items()}}
                    elif phase in ['loaded', 'before-capture', 'after-element', 'released']:
                        samples[phase] = footprint()
                        (folder / (phase + '.ack')).touch()
                    elif phase == 'after-page':
                        started = time.monotonic(); series = []
                        for offset in [0, 5, 15]:
                            remaining = offset - (time.monotonic() - started)
                            if remaining > 0: wait(remaining)
                            value = footprint(); value['secondsAfterCheckpoint'] = time.monotonic() - started
                            series.append(value)
                        samples[phase] = series
                        (folder / (phase + '.ack')).touch()
                    else: raise RuntimeError('unknown checkpoint: ' + phase)
                    completed_phases.add(phase)
                    save(folder / 'samples.json', samples)
                    print(json.dumps({'round': folder.name, 'phase': phase}), flush=True)
            time.sleep(.2)
        raise RuntimeError('experience probe timed out')
    finally:
        save(folder / 'environment.json', states)
        current = owned_pid(app, plan)
        if current is not None:
            os.kill(current, signal.SIGTERM)
            for _ in range(100):
                if owned_pid(app, plan) is None: break
                time.sleep(.1)
            else: raise RuntimeError('owned probe did not exit; inspect before another run')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-ref', default='HEAD')
    parser.add_argument('--build', type=Path, help='reuse a previously prepared build.json directory')
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--diagnostic', action='store_true', help='harness validation only, never accepted as performance')
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if args.rounds < (1 if args.diagnostic else 3): parser.error('formal comparison requires at least 3 rounds')
    if args.build:
        build = args.build.resolve(); manifest = json.loads((build / 'build.json').read_text())
    else:
        build, manifest = prepare(args.source_ref)
    app = Path(manifest['app'])
    patch = build / 'startup-hook.patch'
    hook = ''.join(line[1:] for line in patch.read_text().splitlines(True) if line.startswith('+') and not line.startswith('+++'))
    if digest(patch) != manifest['startupHookSHA256'] or hook != STARTUP_HOOK:
        raise RuntimeError('startup hook differs from the reviewed instrumentation')
    manifest['startupHookCodeSHA256'] = hashlib.sha256(hook.encode()).hexdigest()
    if digest(app / 'Contents/MacOS/Pageglass') != manifest['executableSHA256'] or digest(HERE / 'ExperienceProbe.swift') != manifest['probeSHA256'] or digest(HERE / 'experience.html') != manifest['fixtureSHA256']:
        raise RuntimeError('probe build or fixture changed; prepare a new build')
    print(json.dumps({'build': str(build), 'provenance': manifest}), flush=True)
    if not args.run: return
    helper = ROOT / 'qa-output/benchmark-environment'
    swift = HERE / 'environment.swift'
    if not helper.exists() or helper.stat().st_mtime < swift.stat().st_mtime:
        helper.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', str(swift), '-o', str(helper)], check=True)
    output = Path(tempfile.mkdtemp(prefix='pageglass-experience-results-', dir='/tmp')).resolve()
    preflight = {'environment': environment(helper), 'provenance': manifest, 'diagnostic': args.diagnostic,
                 'runnerSHA256': RUNNER_SHA256, 'environmentHelperSHA256': digest(helper),
                 'processMetricsSHA256': digest(HERE / 'process_metrics.py'),
                 'hardwareModel': subprocess.check_output(['sysctl', '-n', 'hw.model'], text=True).strip()}
    save(output / 'preflight.json', preflight)
    print(json.dumps({'output': str(output), 'preflight': preflight}), flush=True)
    if blockers(preflight['environment']) and not args.diagnostic:
        raise RuntimeError('formal probe not started: ' + '; '.join(blockers(preflight['environment'])))
    results = []
    try:
        for number in range(args.rounds):
            results.append(one_round(app, output / str(number + 1), helper, args.diagnostic))
        if len({json.dumps(r['viewport'], sort_keys=True) for r in results}) != 1:
            raise RuntimeError('experience viewport changed across rounds')
        summary = {'status': 'diagnostic-completed' if args.diagnostic else 'completed', 'accepted': not args.diagnostic,
                   'provenance': manifest, 'rounds': args.rounds,
                   'scope': 'clean-profile process launch, native activation to two requestAnimationFrame callbacks, scripted scroll cadence, service capture to files; not physical input/display latency or OS-cache-cold launch'}
        if not args.diagnostic:
            summary['median'] = {
                'launchToEditableAddressMilliseconds': statistics.median(r['launchToEditableAddressMilliseconds'] for r in results),
                'tabActivationMilliseconds': statistics.median(statistics.median(s['milliseconds'] for s in r['switches']) for r in results),
                'idleCPUPercentOfOneCore': statistics.median(r['samples']['idleCPU']['percentOfOneCore'] for r in results),
                'elementCaptureMilliseconds': statistics.median(r['elementCapture']['milliseconds'] for r in results),
                'pageCaptureMilliseconds': statistics.median(r['pageCapture']['milliseconds'] for r in results)}
        save(output / 'summary.json', summary); print(json.dumps(summary), flush=True)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        save(output / 'incomplete.json', {'status': 'incomplete', 'error': str(error), 'accepted': False})
        raise


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit('EXPERIENCE PROBE FAILED: ' + str(error))
