#!/usr/bin/env python3
"""Compare named Pageglass builds, optionally Chrome, using complete matching memory runs."""
import argparse
import json
import math
import statistics
from pathlib import Path


def require(value, message):
    if not value:
        raise ValueError(message)


def positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def compare(baseline, candidate, chrome=None):
    inputs = [('baseline', Path(baseline), 'pageglass'), ('candidate', Path(candidate), 'pageglass')]
    if chrome is not None:
        inputs.append(('chrome', Path(chrome), 'chrome'))
    rows, runs, builds, identities = [], [], {}, []
    for role, directory, engine in inputs:
        summary = json.loads((directory / 'summary.json').read_text())
        preflight = json.loads((directory / 'preflight.json').read_text())
        require(summary['status'] == 'completed', 'incomplete benchmark')
        source, fixture = summary['source'], summary['source']['memoryFixture']
        require(source == preflight['source'], 'summary provenance differs from preflight')
        require(fixture['version'] == 3 and fixture['viewport'] == {'width': 1280, 'height': 760}, 'unknown memory workload')
        identity = {key: source[key] for key in ['hardwareModel', 'runnerSHA256', 'serverSHA256', 'environmentHelperSHA256', 'processMetricsSHA256']}
        identity['fixture'] = fixture
        identity['system'] = {key: preflight['environment'][key] for key in ['osVersion', 'physicalMemoryBytes', 'cpuCount']}
        identities.append(identity)
        require(all(item == identities[0] for item in identities), 'different workload, runner, system or hardware')
        build = source['browsers'][engine]
        version = build['version']
        require(isinstance(version, str) and version, 'missing measured browser version')
        label = ('Chrome ' if engine == 'chrome' else 'Pageglass ') + version
        builds[role] = {'label': label, **{key: build[key] for key in ['version', 'executableSHA256']}}
        selected = [run for run in summary['runs'] if run['engine'] == engine]
        require(len({run['run'] for run in selected}) == len(selected), 'duplicate run identifiers')
        require(all(run['workload'] == 'memory' and run['tabs'] in [1, 5, 10] for run in selected), 'unexpected workload')
        for tabs in [1, 5, 10]:
            group = [run for run in selected if run['tabs'] == tabs]
            require(len(group) >= 3, 'at least three runs required for every tab count')
            values = []
            for run in group:
                require(Path(run['run']).name == run['run'] and run['run'] not in ['', '.', '..'], 'unsafe run path')
                raw = json.loads((directory / run['run'] / 'result.json').read_text())
                require(raw['status'] == 'completed' and raw['engine'] == engine, 'incomplete or wrong-engine run')
                reports, samples, states = raw['tabs'], raw['memorySamples'], raw['environment']
                require(set(reports) == {str(i) for i in range(tabs)}, 'missing or duplicate fixture tabs')
                require(all(t['tab'] == int(key) and t['ready'] and t.get('seenVisible') and t['rows'] == 1000 and t['viewport'] == fixture['viewport'] for key, t in reports.items()), 'not every fixture was loaded and visited at the same viewport')
                visible = [t for t in reports.values() if t.get('visible')]
                require(len(visible) == 1 and visible[0]['tab'] == 0, 'sampling must return to the first tab')
                require(visible[0]['containerViewport']['width'] >= 1280 and visible[0]['containerViewport']['height'] >= 760, 'fixture clipped by browser chrome')
                require(run['viewport'] == raw['measuredViewport'] == fixture['viewport'], 'measured viewport differs from fixture')
                require(states and all(s['thermalState'] == 'nominal' and s['sessionAvailable'] and not s['screenLocked'] and not s['lowPowerMode'] for s in states), 'invalid measurement environment')
                require(len(samples) == 5, 'five complete physical-footprint samples required')
                for sample in samples:
                    require(sample['engine'] == engine and positive(sample['physicalFootprintBytes']), 'invalid memory sample')
                    processes = sample['processes']
                    require(processes and len({p['pid'] for p in processes}) == len(processes) and sample['rootPID'] in {p['pid'] for p in processes}, 'incomplete process attribution')
                    require(all(positive(p['physicalFootprintBytes']) and p['name'] and p['attribution'] for p in processes), 'invalid attributed process')
                # footprint's aggregate deduplicates shared pages; do not replace it with summed RSS or per-process bytes.
                value = statistics.median(s['physicalFootprintBytes'] for s in samples)
                require(value == run['physicalFootprintBytes'], 'summary does not match raw physical-footprint samples')
                values.append(value)
                runs.append({'role': role, 'browser': label, 'run': run['run'], 'tabs': tabs,
                             'fixtureReports': reports, 'environment': states, 'memorySamples': samples,
                             'discardedSamples': raw.get('discardedSamples', []), 'elapsedSeconds': raw['elapsedSeconds']})
            rows.append({'role': role, 'browser': label, 'tabs': tabs, 'medianBytes': statistics.median(values),
                         'minBytes': min(values), 'maxBytes': max(values), 'runMediansBytes': values})
    regressions = []
    for tabs in [1, 5, 10]:
        before = next(row for row in rows if row['role'] == 'baseline' and row['tabs'] == tabs)
        after = next(row for row in rows if row['role'] == 'candidate' and row['tabs'] == tabs)
        change = (after['medianBytes'] / before['medianBytes'] - 1) * 100
        after['changeFromBaselinePercent'] = change
        if change > 10:
            regressions.append(tabs)
    return {'scope': 'Controlled same-origin PM fixture memory only; five attributed physical-footprint samples per run, at least three runs per tab count. Not a general browser performance claim.',
            'chromeIncluded': chrome is not None, 'measurementIdentity': identities[0], 'builds': builds,
            'summary': rows, 'regressionInvestigationRequiredForTabs': regressions, 'runs': runs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--chrome', type=Path, help='optional complete Chrome batch; omitted means no Chrome comparison')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = compare(args.baseline, args.candidate, args.chrome)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('| Browser | Tabs | Median MiB | Range MiB |\n|---|---:|---:|---:|')
    for row in report['summary']:
        print(f"| {row['browser']} | {row['tabs']} | {row['medianBytes']/1048576:.1f} | {row['minBytes']/1048576:.1f}–{row['maxBytes']/1048576:.1f} |")
    print('Regression investigation required:', report['regressionInvestigationRequiredForTabs'])


if __name__ == '__main__':
    main()
