"""Safety regressions using fake HID/DDC tools; never switch real hardware."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MacSwitchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='desk switch tests ')
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'scripts', self.root / 'scripts')
        self.calls = self.root / 'calls.jsonl'
        fake = self.root / 'fake-hid'
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args == ['--help']:
    print('--expect-name'); sys.exit(0)
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\\n')
slot = args[args.index('--device') + 1] if '--device' in args else ''
if '--receiver-info' in args and slot == os.environ.get('FAIL_INFO'):
    sys.exit(1)
if '--receiver-change-host' in args and slot == os.environ.get('FAIL_SWITCH'):
    sys.exit(1)
sys.exit(0)
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, HID_SEND=str(fake), CALLS=str(self.calls),
                        INTER_DEVICE_DELAY='0', LOG_PATH=str(self.root / 'run.log'),
                        DDC_COMMAND="printf 'display\\n' >> \"$CALLS\"")
        for key in ['LOGI_TRANSPORT', 'DRY_RUN', 'KEYBOARD_SLOT', 'MOUSE_SLOT',
                    'MOUSE_VIDPID', 'MOUSE_FEATURE_INDEX', 'LOGI_COMMAND']:
            self.env.pop(key, None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, outer=False):
        name = 'switch-to-windows-now.sh' if outer else 'switch-logitech-to-windows-macos.sh'
        return subprocess.run(['/bin/zsh', str(self.root / 'scripts' / name), *args],
                              env=self.env, capture_output=True, text=True)

    def recorded(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_dry_run_has_new_mouse_and_no_io(self):
        self.env.pop('DDC_COMMAND')
        self.env['DDC_BACKEND'] = 'm1ddc'
        result = self.run_script('--dry-run', outer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('MX\\ Master\\ 4', result.stdout)
        self.assertIn('--device 3', result.stdout)
        self.assertIn('input-alt 208', result.stdout)
        self.assertNotIn('B034', result.stdout)
        self.assertEqual(self.recorded(), [])

    def test_check_only_queries_two_devices(self):
        self.assertEqual(self.run_script('--check').returncode, 0)
        calls = [json.loads(x) for x in self.recorded()]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('--receiver-info' in c for c in calls))

    def test_success_checks_both_then_switches_then_display(self):
        result = self.run_script(outer=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = self.recorded()
        self.assertEqual(lines[-1], 'display')
        calls = [json.loads(x) for x in lines[:-1]]
        self.assertEqual([c[0] for c in calls], ['--receiver-info'] * 2 + ['--receiver-change-host'] * 2)
        self.assertEqual([c[c.index('--device') + 1] for c in calls], ['2', '3', '2', '3'])
        self.assertEqual(calls[-1][calls[-1].index('--expect-name') + 1], 'MX Master 4')

    def test_wrong_mouse_stops_before_any_switch(self):
        self.env['FAIL_INFO'] = '3'
        self.assertNotEqual(self.run_script(outer=True).returncode, 0)
        self.assertFalse(any('change-host' in x or x == 'display' for x in self.recorded()))

    def test_keyboard_switch_failure_stops_mouse_and_display(self):
        self.env['FAIL_SWITCH'] = '2'
        self.assertNotEqual(self.run_script(outer=True).returncode, 0)
        self.assertEqual(len(self.recorded()), 3)
        self.assertNotIn('display', self.recorded())

    def test_mouse_switch_failure_stops_display(self):
        self.env['FAIL_SWITCH'] = '3'
        self.assertNotEqual(self.run_script(outer=True).returncode, 0)
        self.assertNotIn('display', self.recorded())

    def test_unconfigured_bluetooth_sends_nothing(self):
        self.assertNotEqual(self.run_script('--transport', 'bluetooth').returncode, 0)
        self.assertEqual(self.recorded(), [])

    def test_auto_does_not_fall_back_to_old_mouse(self):
        self.env['FAIL_INFO'] = '3'
        self.assertNotEqual(self.run_script('--transport', 'auto').returncode, 0)
        self.assertTrue(all('--receiver-info' in x for x in self.recorded()))

    def test_probe_dry_run_sends_nothing(self):
        self.assertEqual(self.run_script('--probe-receiver', '--dry-run').returncode, 0)
        self.assertEqual(self.recorded(), [])

    def test_invalid_arguments_send_nothing(self):
        for args in [('--target-channel', '0'), ('--target-channel', 'foo'),
                     ('--keyboard-slot', '3'), ('--mouse-slot', '7'),
                     ('--hidpp-timeout-ms', '0'), ('--inter-delay', '-1'), ('--transport',)]:
            with self.subTest(args=args):
                self.assertEqual(self.run_script(*args).returncode, 2)
        self.assertEqual(self.recorded(), [])


if __name__ == '__main__':
    unittest.main()
