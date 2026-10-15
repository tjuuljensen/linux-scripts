#!/usr/bin/env python3
"""Compare Bash/JSON behavior with gnome-keybindings.py using fake gsettings.

Run on Linux: python3 tests/test_gnome_keybindings.py [repository-directory].
Requires Bash, jq, Python 3 and standard Unix tools. An isolated PATH contains
only a mock gsettings; no real desktop settings are read or written. Copy a
Windows-hosted checkout into the WSL Linux filesystem before running.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
TOOLS = {name: shutil.which(name) for name in ['jq', 'cat', 'date', 'mktemp', 'rm']}
if not BASH or not all(TOOLS.values()):
    raise SystemExit('Tests require Bash, jq, Python 3, cat, date, mktemp and rm.')
WM = 'org.gnome.desktop.wm.keybindings'
POWER = 'org.gnome.settings-daemon.plugins.power'
MEDIA = 'org.gnome.settings-daemon.plugins.media-keys'
CUSTOM = MEDIA + '.custom-keybinding'
PATHS = ['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom7/',
         '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom9/']

MOCK = r'''#!PYTHON_PATH
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['MOCK_CALLS'], 'a', encoding='utf-8') as stream:
    stream.write(json.dumps(args, ensure_ascii=False) + '\n')
fixture = json.loads(pathlib.Path(os.environ['MOCK_FIXTURE']).read_text())
for failure in fixture.get('failures', []):
    if args[:len(failure['args'])] == failure['args']:
        print(failure['error'], file=sys.stderr)
        raise SystemExit(1)
if args == ['list-schemas']:
    print('\n'.join(fixture['schemas']))
elif args == ['list-relocatable-schemas']:
    print('\n'.join(fixture['relocatable']))
elif args[0] == 'list-recursively':
    print('\n'.join(fixture['rows'].get(args[1], [])))
elif args[0] == 'get':
    print(fixture['values'][args[1]][args[2]])
elif args[0] == 'set':
    pass
else:
    raise SystemExit('Unexpected mock invocation: ' + repr(args))
'''.replace('PYTHON_PATH', sys.executable)


def fixture():
    return {
        'schemas': [WM, POWER, MEDIA], 'relocatable': [CUSTOM],
        'rows': {
            WM: [f"{WM} switch-windows ['<Alt>Tab']", f"{WM} disabled ['disabled']",
                 f"{WM} blank ['']", f"{WM} empty []", f'{WM} integer 5',
                 f'{WM} bool false', f'{WM} typed @as []', f'{WM} double "ignored"'],
            POWER: [f"{POWER} button-power 'interactive'", f"{POWER} unrelated 'ignored'",
                    f'{POWER} button-number 1'],
            MEDIA: [f'{MEDIA} custom-keybindings ' + repr(PATHS),
                    f"{MEDIA} volume-up ['XF86AudioRaiseVolume']"],
        },
        'values': {
            CUSTOM + ':' + PATHS[0]: {
                'name': "'Terminal ÆØÅ 公司'",
                'command': "'sh -c \"echo \\\'hello\\\'; echo $(touch DO_NOT_CREATE)\"'",
                'binding': "'<Super>Return'",
            },
            CUSTOM + ':' + PATHS[1]: {
                'name': "'Second'", 'command': "'printf \\\"%s\\\" path\\\\name'", 'binding': "''",
            },
        },
        'failures': [],
    }


class Parity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gnome-keybindings-tests-')
        self.base = Path(self.temp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name, path in TOOLS.items():
            (self.bin / name).symlink_to(path)
        mock = self.bin / 'gsettings'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        self.fixture_path = self.base / 'fixture.json'
        self.calls = self.base / 'calls.jsonl'
        self.data = fixture()
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ['BASH_ENV', 'ENV', 'PYTHONPATH', 'PYTHONHOME']}
        self.env.update(PATH=str(self.bin), MOCK_FIXTURE=str(self.fixture_path), MOCK_CALLS=str(self.calls),
                        LC_ALL='C.UTF-8', PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(self.base))

    def tearDown(self):
        self.temp.cleanup()

    def run_one(self, implementation, args=(), stdin=''):
        self.fixture_path.write_text(json.dumps(self.data))
        self.calls.unlink(missing_ok=True)
        command = ([sys.executable, str(ROOT / 'gnome-keybindings.py')] if implementation == 'python'
                   else [BASH, str(ROOT / 'gnome-keybindings.sh')])
        result = subprocess.run(command + list(args), input=stdin, capture_output=True, text=True,
                                cwd=self.base, env=self.env, timeout=30)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        self.assertFalse((self.base / 'DO_NOT_CREATE').exists(), 'Command text was executed!')
        return result, calls

    def compare_export(self, args=()):
        py, py_calls = self.run_one('python', args)
        sh, sh_calls = self.run_one('bash', args)
        self.assertEqual(py.returncode, 0, py.stderr)
        self.assertEqual(sh.returncode, 0, sh.stderr)
        self.assertEqual(py.stderr, sh.stderr)
        self.assertEqual(py_calls, sh_calls)
        left, right = json.loads(py.stdout), json.loads(sh.stdout)
        for value in [left, right]:
            self.assertTrue(value.pop('exported_at').endswith('+00:00'))
            value.pop('tool')
        self.assertEqual(left, right)
        return right

    def export_document(self):
        result, _ = self.run_one('python', ['--export'])
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def compare_import(self, data, args=(), status=0):
        contents = json.dumps(data, ensure_ascii=False)
        py, py_calls = self.run_one('python', ['--import', *args], contents)
        sh, sh_calls = self.run_one('bash', ['--import', *args], contents)
        self.assertEqual(py.returncode, status, py.stderr)
        self.assertEqual((sh.returncode, sh.stdout, sh.stderr), (py.returncode, py.stdout, py.stderr))
        self.assertEqual(py_calls, sh_calls)
        return sh, sh_calls

    def test_export_and_normalization(self):
        for args in [[], ['--export'], ['-e', '--format=json'], ['--normalize-disabled'],
                     ['--export', '--dry-run'], ['--exp', '--norm']]:
            with self.subTest(args=args):
                data = self.compare_export(args)
                self.assertEqual(len(data['items']), 8)

    def test_import_flags_and_exact_gsettings_arguments(self):
        data = self.export_document()
        for flags in [[], ['--preserve-custom-paths'], ['--no-replace-custom'],
                      ['--preserve-custom-paths', '--no-replace-custom'], ['--format', 'json']]:
            with self.subTest(flags=flags):
                _, calls = self.compare_import(data, flags)
                self.assertTrue(all(call[0] == 'set' for call in calls))
                final = calls[-1]
                self.assertEqual(final[:3], ['set', MEDIA, 'custom-keybindings'])
                self.assertEqual(any(call == ['set', MEDIA, 'custom-keybindings', '[]'] for call in calls),
                                 '--no-replace-custom' not in flags)

    def test_dry_run_quotes_and_control_characters(self):
        data = self.export_document()
        data['items'][0]['value'] = "'quotes \\\' \\\" $HOME $(touch DO_NOT_CREATE) `true`\t\n終\n'"
        data['items'][-1]['path'] = "/odd/'quote\\slash/"
        for flags in [['--dry-run'], ['--dry-run', '--preserve-custom-paths', '--no-replace-custom']]:
            with self.subTest(flags=flags):
                result, calls = self.compare_import(data, flags)
                self.assertIn('DRY-RUN:', result.stdout)
                self.assertEqual(calls, [])
        self.compare_import(data, ['--preserve-custom-paths'])

    def test_empty_custom_lists_and_no_custom_import(self):
        for value in ['[]', '@as []', '']:
            with self.subTest(value=value):
                self.data['rows'][MEDIA][0] = f'{MEDIA} custom-keybindings {value}'
                data = self.compare_export()
                _, calls = self.compare_import(data)
                self.assertFalse(any(call[1:3] == [MEDIA, 'custom-keybindings'] for call in calls))
        self.compare_import({'format': 'gnome-keybindings', 'items': []})

    def test_escaped_custom_path_array(self):
        for value, paths in [
            ('''@as ["/double/", '/single/',]''', ['/double/', '/single/']),
            (r'''['/quote\'slash\\/', '/unicode\u00c6\U0001f600/', '/tab\tnewline\n/']''',
             ["/quote'slash\\/", '/unicodeÆ😀/', '/tab\tnewline\n/']),
            (r'''['/hex\x41/', '/literal$(touch DO_NOT_CREATE)/']''', ['/hexA/', '/literal$(touch DO_NOT_CREATE)/']),
            (r'''['/octal\101/']''', ['/octalA/']),
        ]:
            with self.subTest(value=value):
                self.data['rows'][MEDIA][0] = f'{MEDIA} custom-keybindings {value}'
                self.data['values'] = {CUSTOM + ':' + path: {'name': "'Name'", 'command': "'true'", 'binding': "''"}
                                       for path in paths}
                self.compare_export()

    def test_schema_warnings_and_failed_custom_reads(self):
        self.data['schemas'].remove(POWER)
        self.data['relocatable'] = []
        self.data['failures'] = [{'args': ['get', CUSTOM + ':' + PATHS[0], 'command'], 'error': ' denied '}]
        data = self.compare_export()
        self.assertEqual(sum(item['type'] == 'custom' for item in data['items']), 1)
        self.data['failures'].append({'args': ['list-relocatable-schemas'], 'error': 'unsupported'})
        self.compare_export()
        self.data['failures'].append({'args': ['list-recursively', WM], 'error': 'unavailable'})
        self.compare_export()

    def test_set_failures_continue_and_return_one(self):
        data = self.export_document()
        self.data['failures'] = [{'args': ['set', WM, 'switch-windows'], 'error': 'locked'},
                                 {'args': ['set', MEDIA, 'custom-keybindings'], 'error': 'denied'}]
        result, calls = self.compare_import(data, status=1)
        self.assertEqual(sum('ERROR:' in line for line in result.stderr.splitlines()), 3)
        self.assertEqual(calls[-1][1:3], [MEDIA, 'custom-keybindings'])

    def test_unknown_item_types(self):
        data = self.export_document()
        data['items'].insert(1, {'type': 'future'})
        data['items'].insert(2, {})
        self.compare_import(data)

    def test_file_io_and_action_inference(self):
        path = self.base / 'keys with spaces.json'
        for implementation in ['python', 'bash']:
            path.unlink(missing_ok=True)
            result, calls = self.run_one(implementation, [str(path)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertTrue(path.is_file())
            result, calls = self.run_one(implementation, [str(path), '--dry-run'])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('DRY-RUN:', result.stdout)
            self.assertEqual(calls, [])
            result, calls = self.run_one(implementation, ['--export', str(path)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(['list-schemas'], calls)
            result, calls = self.run_one(implementation, ['--import', str(path)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(all(call[0] == 'set' for call in calls))
        self.compare_export(['--', '-'])

    def test_cli_validation(self):
        for args in [['--export', '--import'], ['-ei'], ['--format'], ['--format=yaml'],
                     ['--unknown'], ['one', 'two'], ['--dry-run=yes'], ['--no']]:
            with self.subTest(args=args):
                for implementation in ['python', 'bash']:
                    result, calls = self.run_one(implementation, args)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(calls, [])
        for implementation in ['python', 'bash']:
            for arg in ['--help', '--version']:
                result, calls = self.run_one(implementation, [arg])
                self.assertEqual(result.returncode, 0)
                self.assertEqual(calls, [])
        result, calls = self.run_one('bash', ['--format', 'tsv'])
        self.assertEqual(result.returncode, 2)
        self.assertIn('TSV is not supported', result.stderr)
        self.assertEqual(calls, [])

    def test_empty_and_invalid_imports(self):
        for text, expected in [('', 'Import file is empty.'), ('  \n\t', 'Import file is empty.'),
                               ('{}', 'JSON file is not a gnome-keybindings export.'),
                               ('{"format":"gnome-keybindings"}', 'JSON import file has no items list.')]:
            for implementation in ['python', 'bash']:
                result, calls = self.run_one(implementation, ['--import'], text)
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)
                self.assertEqual(calls, [])
        for text in ['{invalid', '{} {}', 'custom\tname\tcommand\tbinding', 'null', '[]']:
            result, calls = self.run_one('bash', ['--import'], text)
            self.assertEqual(result.returncode, 1, text)
            self.assertEqual(calls, [])

    def test_malformed_items_rejected_before_writes(self):
        for bad in [{'type': 'setting', 'schema': WM}, {'type': 'custom', 'name': 42}, None,
                    {'type': 'setting', 'schema': WM, 'key': 'test', 'value': 'bad\x00value'}]:
            data = self.export_document()
            data['items'].append(bad)
            result, calls = self.run_one('bash', ['--import'], json.dumps(data))
            self.assertEqual(result.returncode, 1)
            self.assertIn('Invalid import item', result.stderr)
            self.assertEqual(calls, [])

    def test_export_errors(self):
        self.data['failures'] = [{'args': ['list-schemas'], 'error': 'test failure'}]
        for implementation in ['python', 'bash']:
            result, _ = self.run_one(implementation)
            self.assertEqual(result.returncode, 1)
            self.assertIn('gsettings list-schemas failed: test failure', result.stderr)
            self.assertEqual(result.stdout, '')
        self.data['failures'] = []
        for value in ['not-an-array', '[1]', "['unterminated]", "['a'] junk", "[__import__('os').system('touch DO_NOT_CREATE')]"]:
            self.data['rows'][MEDIA][0] = f'{MEDIA} custom-keybindings {value}'
            for implementation in ['python', 'bash']:
                result, _ = self.run_one(implementation)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')

    def test_missing_dependencies(self):
        (self.bin / 'gsettings').unlink()
        for implementation in ['python', 'bash']:
            result, calls = self.run_one(implementation)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Required command not found: gsettings', result.stderr)
            self.assertEqual(calls, [])
        mock = self.bin / 'gsettings'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        (self.bin / 'jq').unlink()
        result, calls = self.run_one('bash')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Required command not found: jq', result.stderr)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
