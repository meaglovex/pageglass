#!/usr/bin/env python3
"""Export matching complete Speedometer runs without profiles or browser logs."""
import argparse
import json
import math
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['baseline', 'candidate', 'chrome', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    reference, viewport, system, test_counts = None, None, None, None
    sources, rows, runs = {}, [], []
    for label, directory, engine in [('Pageglass 0.6', args.baseline, 'pageglass'),
                                      ('Pageglass 0.7', args.candidate, 'pageglass'),
                                      ('Chrome', args.chrome, 'chrome')]:
        summary = json.loads((directory / 'summary.json').read_text())
        assert summary['status'] == 'completed' and 'medianScore' in summary, 'complete Speedometer batch required'
        source = summary['source']
        identity = {key: source[key] for key in ['commit', 'treeSHA256', 'archiveSHA256', 'adapterSHA256', 'serverSHA256',
                                                'runnerSHA256', 'environmentHelperSHA256', 'hardwareModel']}
        if reference is None: reference = identity
        assert identity == reference, 'different benchmark, runner or hardware'
        sources[label] = source['browsers'][engine]
        if label != 'Chrome':
            assert sources[label]['version'].startswith(label.split()[-1] + '.'), 'browser version does not match report label'
        selected = [run for run in summary['runs'] if run['engine'] == engine]
        assert len(selected) >= 3 and all(run['workload'] == 'speedometer' for run in selected)
        scores = []
        for run in selected:
            raw = json.loads((directory / run['run'] / 'result.json').read_text())
            assert raw['status'] == 'completed' and not raw['invalid'] and raw['engine'] == engine
            assert run['iterations'] >= 10 and len(raw['score']['values']) == run['iterations']
            values = raw['score']['values']
            assert all(math.isfinite(value) and value > 0 for value in values)
            assert math.isclose(statistics.mean(values), raw['score']['mean'], rel_tol=1e-9)
            assert raw['score']['mean'] == run['score']
            assert all(state['thermalState'] == 'nominal' and not state['screenLocked'] and not state['lowPowerMode'] for state in raw['environment'])
            configuration = (raw['suitesCount'], raw['finishedTests'], run['iterations'])
            assert configuration[0] > 0 and configuration[1] > 0
            current_system = {key: raw['environment'][0][key] for key in ['osVersion', 'cpuCount', 'physicalMemoryBytes']}
            if viewport is None: viewport, system, test_counts = raw['viewport'], current_system, configuration
            assert (raw['viewport'], current_system, configuration) == (viewport, system, test_counts), 'different viewport, system or selected tests'
            totals = {name: metric['values'] for name, metric in raw['metrics'].items()
                      if '/' not in name and not name.startswith('Iteration-')}
            scores.append(run['score'])
            runs.append({'browser': label, 'run': run['run'], 'iterationScores': values,
                         'scoreMean': run['score'], 'metricTotals': totals, 'suitesCount': raw['suitesCount'],
                         'finishedTests': raw['finishedTests'], 'elapsedSeconds': raw['elapsedSeconds'],
                         'viewport': raw['viewport'], 'environment': raw['environment']})
        rows.append({'browser': label, 'medianScore': statistics.median(scores),
                     'minScore': min(scores), 'maxScore': max(scores), 'roundScores': scores})
    baseline, candidate, chrome = [row['medianScore'] for row in rows]
    change = (candidate / baseline - 1) * 100
    report = {'scope': 'Speedometer 3.1 only. Higher is better. Not browser startup, memory or overall experience.',
              'source': reference, 'environment': system, 'browsers': sources, 'summary': rows, 'runs': runs,
              'candidateChangeFromBaselinePercent': change, 'candidateToChromeRatio': candidate / chrome,
              'regressionInvestigationRequired': change < -10}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in report.items() if key != 'runs'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
