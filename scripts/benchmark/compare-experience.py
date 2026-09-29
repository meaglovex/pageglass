#!/usr/bin/env python3
"""Validate matching native probes and export synthetic measurements, not local profiles."""
import argparse
import collections
import json
import math
from pathlib import Path
import statistics


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def load(directory):
    summary = json.loads((directory / 'summary.json').read_text())
    preflight = json.loads((directory / 'preflight.json').read_text())
    assert summary['status'] == 'completed' and summary['accepted'] and summary['rounds'] >= 3, 'formal complete rounds required'
    samples = []
    for number in range(1, summary['rounds'] + 1):
        result = json.loads((directory / str(number) / 'result.json').read_text())
        assert result['accepted'] and not result['diagnostic'] and result['status'] == 'completed'
        assert result['closedWebViewsReleased'] and result['remainingWebViews'] == result['remainingTabs'] == 1
        assert all(state['thermalState'] == 'nominal' and not state['screenLocked'] and not state['lowPowerMode'] for state in result['environment'])
        switches = [item['milliseconds'] for item in result['switches']]
        intervals = result['scroll']['intervalsMilliseconds']
        assert len(switches) == 30 and len(intervals) > 60 and result['scroll']['scrollY'] > 5000
        assert all(math.isfinite(v) and v > 0 for v in switches + intervals)
        memory = result['samples']
        footprints = {phase: memory[phase]['physicalFootprintBytes'] for phase in ['loaded', 'before-capture', 'after-element', 'released']}
        footprints['afterPage'] = [{'seconds': sample['secondsAfterCheckpoint'], 'bytes': sample['physicalFootprintBytes']} for sample in memory['after-page']]
        assert len(footprints['afterPage']) == 3 and all(sample['bytes'] > 0 for sample in footprints['afterPage'])
        assert memory['idleCPU']['durationSeconds'] >= 10
        assert memory['idleCPU'].get('counter') == 'proc_pid_rusage Mach ticks converted by mach_timebase_info', 'CPU counter units must be verified'
        assert memory['idleCPU']['timebase']['numer'] > 0 and memory['idleCPU']['timebase']['denom'] > 0
        names = {str(process['pid']): process['name'] for process in memory['loaded']['processes']}
        cpu_by_name = collections.defaultdict(float)
        for pid, after in memory['idleCPU']['after'].items():
            cpu_by_name[names.get(pid, 'process exited after CPU sample')] += after - memory['idleCPU']['before'][pid]
        # Explicit whitelist: never publish profiles, capture paths, logs or the whole temporary build.
        samples.append({'round': number, 'viewport': result['viewport'], 'screenMaximumFPS': result['startup']['screenMaximumFPS'],
                        'launchMilliseconds': result['launchToEditableAddressMilliseconds'], 'switchMilliseconds': switches,
                        'scrollIntervalsMilliseconds': intervals, 'scrollDistance': result['scroll']['scrollY'],
                        'idleCPUPercentOfOneCore': memory['idleCPU']['percentOfOneCore'],
                        'idleCPUSeconds': memory['idleCPU']['cpuSeconds'], 'idleSampleSeconds': memory['idleCPU']['durationSeconds'],
                        'idleCPUCounter': memory['idleCPU']['counter'], 'machTimebase': memory['idleCPU']['timebase'],
                        'idleCPUSecondsByProcessName': dict(cpu_by_name),
                        'elementCaptureMilliseconds': result['elementCapture']['milliseconds'],
                        'pageCaptureMilliseconds': result['pageCapture']['milliseconds'],
                        'captureScreenshots': {mode: result[mode + 'Capture']['screenshot'] for mode in ['element', 'page']},
                        'physicalFootprintBytes': footprints, 'closedWebViewsReleased': True})
    return summary, preflight, samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    baseline, base_preflight, base_samples = load(args.baseline)
    candidate, candidate_preflight, candidate_samples = load(args.candidate)
    for key in ['probeSHA256', 'fixtureSHA256', 'startupHookCodeSHA256']:
        assert baseline['provenance'][key] == candidate['provenance'][key], 'different probe or workload: ' + key
    for key in ['runnerSHA256', 'environmentHelperSHA256', 'hardwareModel']:
        assert base_preflight[key] == candidate_preflight[key], 'different measurement runner or hardware'
    assert base_preflight['processMetricsSHA256'] == candidate_preflight['processMetricsSHA256'], 'different process counter implementation'
    for key in ['osVersion', 'physicalMemoryBytes', 'cpuCount']:
        assert base_preflight['environment'][key] == candidate_preflight['environment'][key]
    assert len({json.dumps((sample['viewport'], sample['screenMaximumFPS']), sort_keys=True) for sample in base_samples + candidate_samples}) == 1, 'different viewport or refresh rate'
    metrics = {
        'launchMilliseconds': lambda s: s['launchMilliseconds'],
        'tabSwitchMedianMilliseconds': lambda s: statistics.median(s['switchMilliseconds']),
        'tabSwitchP95Milliseconds': lambda s: percentile(s['switchMilliseconds'], .95),
        'scrollRAFP95Milliseconds': lambda s: percentile(s['scrollIntervalsMilliseconds'], .95),
        'idleCPUPercentOfOneCore': lambda s: s['idleCPUPercentOfOneCore'],
        'elementCaptureMilliseconds': lambda s: s['elementCaptureMilliseconds'],
        'pageCaptureMilliseconds': lambda s: s['pageCaptureMilliseconds']}
    rows, investigations = [], []
    for name, evaluate in metrics.items():
        left, right = [evaluate(s) for s in base_samples], [evaluate(s) for s in candidate_samples]
        before, after = statistics.median(left), statistics.median(right)
        change = (after / before - 1) * 100 if before else None
        if change is not None and change > 10: investigations.append(name)
        rows.append({'metric': name, 'baselineSamples': left, 'candidateSamples': right,
                     'baselineMedian': before, 'candidateMedian': after, 'changePercent': change})
    keys = ['sourceCommit', 'probeSHA256', 'fixtureSHA256', 'startupHookSHA256', 'startupHookCodeSHA256', 'executableSHA256', 'version']
    report = {'scope': 'Instrumented native Pageglass probe. Process-cold launch with OS caches intact; activation to two rAF callbacks; scripted scroll cadence; service capture to files. Not physical input/display latency.',
              'hardwareModel': base_preflight['hardwareModel'], 'runnerSHA256': base_preflight['runnerSHA256'],
              'processMetricsSHA256': base_preflight['processMetricsSHA256'],
              'environmentHelperSHA256': base_preflight['environmentHelperSHA256'],
              'environment': {key: base_preflight['environment'][key] for key in ['osVersion', 'physicalMemoryBytes', 'cpuCount']},
              'builds': {label: {key: source['provenance'][key] for key in keys} for label, source in [('baseline', baseline), ('candidate', candidate)]},
              'summary': rows, 'regressionInvestigationRequired': investigations,
              'baselineRaw': base_samples, 'candidateRaw': candidate_samples}
    args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({'summary': rows, 'regressionInvestigationRequired': investigations}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
