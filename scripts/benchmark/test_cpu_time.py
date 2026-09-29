"""Cross-check the native counter against independent getrusage on the current host."""
import os
import resource
import time
import unittest

from process_metrics import cpu_time


class CPUTimeTests(unittest.TestCase):
    def test_mach_counter_matches_getrusage_cpu_seconds(self):
        before = cpu_time(os.getpid())
        usage = resource.getrusage(resource.RUSAGE_SELF)
        start = usage.ru_utime + usage.ru_stime
        deadline = time.process_time() + .06
        while time.process_time() < deadline:
            sum(value * value for value in range(1000))
        after = cpu_time(os.getpid())
        usage = resource.getrusage(resource.RUSAGE_SELF)
        expected = usage.ru_utime + usage.ru_stime - start
        actual = after['seconds'] - before['seconds']
        self.assertEqual(before['startTicks'], after['startTicks'])
        self.assertGreater(actual, .05)
        self.assertLess(abs(actual - expected), .005)
        self.assertGreater(before['timebase']['denom'], 0)


if __name__ == '__main__':
    unittest.main()
