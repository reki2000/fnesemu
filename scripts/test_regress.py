import contextlib
import importlib.util
import io
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('regress', Path(__file__).with_name('regress.py'))
regress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(regress)


class RegressionRunnerTest(unittest.TestCase):
    def test_default_is_quick_and_does_not_load_rom_cases(self):
        with patch.object(regress, 'load_cases', side_effect=AssertionError('ROM cases accessed')):
            with patch.object(regress, 'run_quick', return_value=True) as quick:
                with self.assertRaises(SystemExit) as result:
                    regress.main(['run'])
        self.assertEqual(result.exception.code, 0)
        quick.assert_called_once_with(55.0)

    def test_full_and_all_select_every_rom_case(self):
        cases = {'normal': {'name': 'normal'}, 'extended': {'name': 'extended', 'full': True}}
        for suite in ['full', 'all']:
            with patch.object(regress, 'load_cases', return_value=cases):
                with patch.object(regress, 'run', return_value=True) as run:
                    with contextlib.redirect_stdout(io.StringIO()):
                        with self.assertRaises(SystemExit) as result:
                            regress.main(['run', suite])
            self.assertEqual(result.exception.code, 0)
            self.assertEqual([call.args[0] for call in run.call_args_list], list(cases.values()))

    def test_quick_executes_all_suites_and_reports_failures(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(regress.run_quick(2, [
                ('one', regress.ROOT, [sys.executable, '-c', 'print("one")']),
                ('two', regress.ROOT, [sys.executable, '-c', 'print("two")']),
            ]))
            self.assertFalse(regress.run_quick(2, [
                ('failure', regress.ROOT, [sys.executable, '-c', 'raise SystemExit(3)']),
            ]))

    def test_budget_is_total_and_timeout_is_failure(self):
        started = time.monotonic()
        with contextlib.redirect_stdout(io.StringIO()):
            result = regress.run_quick(0.15, [
                ('first', regress.ROOT, [sys.executable, '-c', 'import time; time.sleep(0.05)']),
                ('slow', regress.ROOT, [sys.executable, '-c', 'import time; time.sleep(5)']),
            ])
        self.assertFalse(result)
        self.assertLess(time.monotonic() - started, 2)

    def test_missing_baseline_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(regress, 'BASE', Path(directory)):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertFalse(regress.compare({'core': 'fixture', 'name': 'missing'}, directory))


if __name__ == '__main__':
    unittest.main()
