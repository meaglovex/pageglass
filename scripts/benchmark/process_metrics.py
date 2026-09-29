#!/usr/bin/env python3
"""Read-only macOS process attribution + physical footprint. Never equate RSS with footprint."""
import argparse, ctypes, json, os, re, subprocess, tempfile
from pathlib import Path


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=20).stdout


def cpu_time(pid):
    """Public proc_pid_rusage/RUSAGE_INFO_V0; convert Mach ticks to seconds.

    The layout is defined by the macOS SDK's sys/resource.h. XNU fills these
    counters from task_power_info's Mach time, so Apple Silicon needs timebase
    conversion (Intel's usual 1:1 timebase can mask that error). Do not use ps's
    centisecond-formatted TIME for small idle CPU differences across many helpers.
    """
    class Usage(ctypes.Structure):
        _fields_ = [('uuid', ctypes.c_uint8 * 16), ('user', ctypes.c_uint64),
                    ('system', ctypes.c_uint64), ('remaining', ctypes.c_uint64 * 8)]
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    timebase = Timebase()
    if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
        raise RuntimeError('Mach clock timebase unavailable')
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    usage = Usage()
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        error = ctypes.get_errno()
        raise OSError(error, 'proc_pid_rusage failed for an attributed process: ' + os.strerror(error))
    nanoseconds = (usage.user + usage.system) * timebase.numer // timebase.denom
    return {'seconds': nanoseconds / 1_000_000_000, 'startTicks': usage.remaining[6],
            'timebase': {'numer': timebase.numer, 'denom': timebase.denom}}


def process_group(root, engine, profile=None):
    rows = command('/bin/ps', '-axo', 'pid=,ppid=,comm=')
    processes = {}
    for row in rows.splitlines():
        values = row.strip().split(None, 2)
        if len(values) == 3:
            processes[int(values[0])] = {'parent': int(values[1]), 'executable': values[2]}
    if root not in processes:
        raise RuntimeError('browser process has exited')
    wanted = 'Pageglass' if engine == 'pageglass' else 'Google Chrome'
    if Path(processes[root]['executable']).name != wanted:
        raise RuntimeError('root PID is not the expected browser executable')
    selected = {root: 'browser root'}
    # Chromium renderers/GPU are ordinary descendants. Include descendants of XPC jobs too.
    if engine == 'pageglass':
        domain = command('/bin/launchctl', 'print', f'pid/{root}')
        creator = re.search(r'^\s*creator = .*\[(\d+)\]$', domain, re.M)
        if not creator or int(creator[1]) != root:
            raise RuntimeError('no dedicated launchd domain for this Pageglass process; launch using LaunchServices')
        service_block = re.search(r'\n\s*services = \{(.*?)\n\s*\}', domain, re.S)
        if not service_block:
            raise RuntimeError('launchd service attribution unavailable')
        for match in re.finditer(r'^\s*(\d+)\s+\S+\s+(\S+)\s*$', service_block[1], re.M):
            pid, name = int(match[1]), match[2]
            if pid and pid in processes:
                selected[pid] = 'launchd:' + name
    elif profile:
        # Crashpad can reparent to launchd. Only include commands naming this exact test profile.
        for row in command('/bin/ps', '-axo', 'pid=,args=').splitlines():
            values = row.strip().split(None, 1)
            if len(values) == 2 and str(profile) in values[1]:
                pid = int(values[0])
                if pid in processes and ('Google Chrome' in processes[pid]['executable'] or 'chrome_crashpad_handler' in processes[pid]['executable']):
                    selected[pid] = 'isolated test profile'
    changed = True
    while changed:
        changed = False
        for pid, record in processes.items():
            if pid not in selected and record['parent'] in selected:
                selected[pid] = 'descendant:' + str(record['parent']); changed = True
    return [{'pid': pid, 'name': Path(processes[pid]['executable']).name, 'attribution': why} for pid, why in sorted(selected.items())]


def measure(root, engine, profile=None):
    group = process_group(root, engine, profile)
    with tempfile.TemporaryDirectory(prefix='pageglass-footprint-') as directory:
        output = Path(directory) / 'footprint.json'
        args = ['/usr/bin/footprint', '--noCategories', '-j', str(output)]
        for item in group: args += ['-p', str(item['pid'])]
        subprocess.run(args, check=True, text=True, capture_output=True, timeout=30)
        raw = json.loads(output.read_text())
    if raw.get('errors'):
        raise RuntimeError('footprint reported errors: ' + json.dumps(raw['errors']))
    by_pid = {p['pid']: p for p in raw.get('processes', [])}
    if set(by_pid) != {p['pid'] for p in group}:
        missing=[p['name'] for p in group if p['pid'] not in by_pid]
        unexpected=list(set(by_pid)-{p['pid'] for p in group})
        raise RuntimeError('process group changed during sample; missing='+repr(missing)+'; unexpected='+repr(unexpected))
    for item in group:
        item['physicalFootprintBytes'] = by_pid[item['pid']]['footprint']
        item['translated'] = by_pid[item['pid']].get('translated')
    return {'engine': engine, 'rootPID': root, 'processes': group,
            'physicalFootprintBytes': raw['total footprint'],
            'sampleTime': raw.get('start_time', {}).get('date'), 'warnings': raw.get('warnings', []),
            'metric': 'macOS footprint aggregate; includes attributed browser helpers and WebKit services'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--engine', choices=['pageglass', 'chrome'], required=True)
    parser.add_argument('--profile', type=Path)
    args = parser.parse_args()
    print(json.dumps(measure(args.pid, args.engine, args.profile), ensure_ascii=False, indent=2))
