"""Reject incomplete or mismatched benchmark evidence before publishing comparisons."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('compare_memory', Path(__file__).with_name('compare-memory.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

VIEWPORT = {'width': 1280, 'height': 760}
ENVIRONMENT = {'osVersion': 'testOS', 'physicalMemoryBytes': 16 * 1024**3, 'cpuCount': 10,
               'thermalState': 'nominal', 'sessionAvailable': True, 'screenLocked': False, 'lowPowerMode': False}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def make_batch(directory, version, engine='pageglass', multiplier=1):
    source = {key: key for key in ['hardwareModel', 'runnerSHA256', 'serverSHA256',
                                  'environmentHelperSHA256', 'processMetricsSHA256']}
    source['memoryFixture'] = {'version': 3, 'viewport': VIEWPORT, 'sha256': 'fixture'}
    source['browsers'] = {engine: {'version': version, 'executableSHA256': 'a' * 64}}
    runs = []
    for tabs in [1, 5, 10]:
        for number in range(3):
            name = f'{engine}-{tabs}-{number}'
            # Distinct samples and rounds make incorrect aggregation observable.
            values = [multiplier * (tabs * 1000 + number * 10 + offset) for offset in range(5)]
            runs.append({'run': name, 'engine': engine, 'workload': 'memory', 'tabs': tabs,
                         'viewport': VIEWPORT, 'physicalFootprintBytes': values[2]})
            raw = {'status': 'completed', 'engine': engine, 'measuredViewport': VIEWPORT,
                   'environment': [ENVIRONMENT], 'elapsedSeconds': 12,
                   'tabs': {str(i): {'tab': i, 'ready': True, 'seenVisible': True, 'visible': i == 0,
                                    'rows': 1000, 'viewport': VIEWPORT, 'containerViewport': VIEWPORT}
                            for i in range(tabs)},
                   'memorySamples': [
                       {'engine': engine, 'rootPID': 100, 'physicalFootprintBytes': value,
                        'processes': [{'pid': 100, 'name': 'Browser', 'attribution': 'browser root',
                                       'physicalFootprintBytes': value - 20},
                                      {'pid': 101, 'name': 'Renderer', 'attribution': 'child',
                                       'physicalFootprintBytes': 25}]}
                       for value in values]}
            write_json(directory / name / 'result.json', raw)
    write_json(directory / 'summary.json', {'status': 'completed', 'source': source, 'runs': runs})
    write_json(directory / 'preflight.json', {'source': source, 'environment': ENVIRONMENT})


class MemoryComparisonTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.baseline, self.candidate, self.chrome = [root / name for name in ['baseline', 'candidate', 'chrome']]
        make_batch(self.baseline, '0.7.0-beta.1')
        make_batch(self.candidate, '0.8.0-alpha.1')

    def compare(self):
        return module.compare(self.baseline, self.candidate)

    def mutate(self, relative, action):
        path = self.candidate / relative
        value = json.loads(path.read_text())
        action(value)
        write_json(path, value)

    def test_current_versions_and_deduplicated_aggregate(self):
        result = self.compare()
        self.assertFalse(result['chromeIncluded'])
        self.assertEqual(result['builds']['candidate']['label'], 'Pageglass 0.8.0-alpha.1')
        self.assertEqual(len(result['runs']), 18)
        row = result['summary'][0]
        self.assertEqual(row['runMediansBytes'], [1002, 1012, 1022])
        self.assertEqual(row['medianBytes'], 1012)
        # The per-process sum is larger than the deduplicated aggregate by design.
        self.assertEqual(result['regressionInvestigationRequiredForTabs'], [])

    def test_optional_chrome_requires_its_own_complete_batch(self):
        make_batch(self.chrome, '154.0', engine='chrome')
        result = module.compare(self.baseline, self.candidate, self.chrome)
        self.assertTrue(result['chromeIncluded'])
        self.assertEqual(len(result['runs']), 27)
        self.assertEqual(result['builds']['chrome']['label'], 'Chrome 154.0')

    def test_regressions_are_reported_without_suppressing_results(self):
        make_batch(self.candidate, '0.8.0-alpha.1', multiplier=1.2)
        result = self.compare()
        self.assertEqual(result['regressionInvestigationRequiredForTabs'], [1, 5, 10])
        self.assertAlmostEqual(result['summary'][3]['changeFromBaselinePercent'], 20)

    def test_reject_incomplete_rounds_and_duplicate_identifiers(self):
        path = self.candidate / 'summary.json'
        original = json.loads(path.read_text())
        for mode in ['incomplete', 'few_rounds', 'duplicate', 'wrong_workload', 'unsafe_path']:
            with self.subTest(mode=mode):
                value = copy.deepcopy(original)
                if mode == 'incomplete': value['status'] = 'failed'
                if mode == 'few_rounds': value['runs'].pop()
                if mode == 'duplicate': value['runs'][1]['run'] = value['runs'][0]['run']
                if mode == 'wrong_workload': value['runs'][0]['workload'] = 'speedometer'
                if mode == 'unsafe_path': value['runs'][0]['run'] = '../outside'
                write_json(path, value)
                with self.assertRaises(ValueError): self.compare()

    def test_reject_raw_measurement_failures(self):
        path = self.candidate / 'pageglass-5-0/result.json'
        original = json.loads(path.read_text())
        mutations = {
            'unfinished': lambda v: v.update(status='failed'),
            'wrong_engine': lambda v: v.update(engine='chrome'),
            'unvisited_tab': lambda v: v['tabs']['4'].update(seenVisible=False),
            'wrong_tab': lambda v: v['tabs']['4'].update(tab=3),
            'missing_tab': lambda v: v['tabs'].pop('4'),
            'wrong_viewport': lambda v: v['tabs']['2'].update(viewport={'width': 800, 'height': 600}),
            'wrong_measured_viewport': lambda v: v.update(measuredViewport={'width': 800, 'height': 600}),
            'clipped': lambda v: v['tabs']['0'].update(containerViewport={'width': 1200, 'height': 760}),
            'wrong_foreground_tab': lambda v: v['tabs']['1'].update(visible=True),
            'fair_temperature': lambda v: v['environment'][0].update(thermalState='fair'),
            'locked': lambda v: v['environment'][0].update(screenLocked=True),
            'no_environment': lambda v: v.update(environment=[]),
            'short_samples': lambda v: v['memorySamples'].pop(),
            'zero_memory': lambda v: v['memorySamples'][0].update(physicalFootprintBytes=0),
            'nonfinite_memory': lambda v: v['memorySamples'][0].update(physicalFootprintBytes=float('nan')),
            'missing_root': lambda v: v['memorySamples'][0].update(rootPID=999),
            'missing_attribution': lambda v: v['memorySamples'][0]['processes'][1].update(attribution=''),
            'duplicate_pid': lambda v: v['memorySamples'][0]['processes'][1].update(pid=100),
        }
        for mode, mutation in mutations.items():
            with self.subTest(mode=mode):
                value = copy.deepcopy(original)
                mutation(value)
                write_json(path, value)
                with self.assertRaises(ValueError): self.compare()

    def test_summary_must_match_raw_samples(self):
        self.mutate('summary.json', lambda value: value['runs'][0].update(physicalFootprintBytes=1))
        with self.assertRaisesRegex(ValueError, 'summary does not match'): self.compare()

    def test_provenance_must_match_preflight_and_other_batch(self):
        self.mutate('summary.json', lambda value: value['source'].update(runnerSHA256='other'))
        with self.assertRaisesRegex(ValueError, 'provenance'): self.compare()
        self.mutate('preflight.json', lambda value: value['source'].update(runnerSHA256='other'))
        with self.assertRaisesRegex(ValueError, 'different workload'): self.compare()


if __name__ == '__main__':
    unittest.main()
