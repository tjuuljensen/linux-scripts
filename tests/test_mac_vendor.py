#!/usr/bin/env python3
"""Differential tests: python3 tests/test_mac_vendor.py [repository-directory].

Runs on Linux; needs Bash, awk, curl and Python 3. No external network needed.
Both implementations receive identical fixtures. Test-only download doubles
exercise refresh behavior without changing the production registry endpoints.
"""
import csv
import io
import json
import os
from pathlib import Path
import pty
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
HEADER = ['prefix', 'bits', 'registry', 'organization', 'address']
ROWS = [
    ['001122', 24, 'MA-L', 'Parent Company', 'Parent Road'],
    ['0011223', 28, 'MA-M', 'Medium Company', 'Medium Road'],
    ['001122334', 36, 'MA-S', 'Small "Quoted", ÆØÅ 公司', 'First\tSecond\nThird\r\nFourth'],
    ['001122334', 36, 'IAB', 'Ignored duplicate', ''],
    ['001122335', 36, 'IAB', 'Legacy', ''],
    ['021122', 24, 'MA-L', 'Local vendor', ''],
    ['011122', 24, 'MA-L', 'Group vendor', ''],
    ['031122', 24, 'MA-L', 'Both flags', ''],
    ['AABBCC', 24, 'MA-L', 'C:\\vendor\\name\b\f\x01', ''],
    ['ABCDEF', 'bogus', 'MA-L', 'Bad bits', ''],
    ['ABCDEF', 32, 'MA-L', 'Unsupported bits', ''],
    ['FFFFFE', 24, 'MA-L', '', ''],
]
PATHS = ['oui/oui.csv', 'oui28/mam.csv', 'oui36/oui36.csv', 'iab/iab.csv']

def tsv(rows):
    out = io.StringIO(newline='')
    writer = csv.writer(out, delimiter='\t', lineterminator='\n')
    writer.writerow(HEADER)
    writer.writerows(rows)
    return out.getvalue().encode()

DOWNLOAD_DOUBLE = r'''#!/usr/bin/env python3
import io, json, os, pathlib, runpy, sys, urllib.error, urllib.request
def download(url, timeout):
    with open(os.environ['TEST_LOG'], 'a') as log:
        log.write(json.dumps({'url': url, 'timeout': str(timeout)}) + '\n')
    if os.environ.get('TEST_FAIL') in (url, 'all'):
        raise urllib.error.URLError('fixture network failure')
    relative = url.split('standards-oui.ieee.org/', 1)[1]
    return (pathlib.Path(os.environ['TEST_FIXTURES']) / relative).read_bytes()
if pathlib.Path(sys.argv[0]).name == 'curl':
    args = sys.argv[1:]
    try:
        content = download(args[-1], args[args.index('--connect-timeout')+1])
        pathlib.Path(args[args.index('--output')+1]).write_bytes(content)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(22)
else:
    urllib.request.urlopen = lambda request, timeout: io.BytesIO(download(request.full_url, timeout))
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name='__main__')
'''

class Parity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mac-vendor-tests-')
        self.base = Path(self.temp.name)
        self.cache = self.base / 'cache'
        self.cache.mkdir()
        self.cfile = self.cache / 'ieee-mac-vendors.tsv'
        self.cfile.write_bytes(tsv(ROWS))
        self.fixtures = self.base / 'fixtures'
        for index, path in enumerate(PATHS):
            dest = self.fixtures / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            assignment = ['001122', '0011223', '001122334', '001122334'][index]
            # Includes BOM, CRLF, quoted multiline data, aliases, duplicates,
            # empty organizations and assignments longer than the registry size.
            dest.write_bytes(('\ufeffAssignment,Organization,Address\r\n'
                              f'{assignment},"Zed, Inc.","One\r\nTwo"\r\n'
                              f'{assignment},"Acme ""Quoted"" ÆØÅ","Tab\there"\r\n'
                              f'{assignment}FFFF,Longer,Somewhere\r\n'
                              'xyz,Invalid,Ignored\r\n'
                              f'{assignment},,Ignored\r\n').encode())
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for path in [self.bin / 'curl', self.base / 'reference.py']:
            path.write_text(DOWNLOAD_DOUBLE)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        TEST_FIXTURES=str(self.fixtures), TEST_LOG=str(self.base / 'network.log'),
                        PYTHONDONTWRITEBYTECODE='1', LC_ALL='C.UTF-8')

    def tearDown(self):
        self.temp.cleanup()

    def command(self, implementation, args):
        if implementation == 'python':
            return [sys.executable, str(self.base / 'reference.py'), str(ROOT / 'mac-vendor.py'), *args]
        return ['bash', str(ROOT / 'mac-vendor.sh'), *args]

    def run_one(self, implementation, args, stdin='', env=None):
        return subprocess.run(self.command(implementation, args), input=stdin,
                              text=True, capture_output=True, env=env or self.env, cwd=self.base, timeout=30)

    def normalized(self, result):
        return (result.returncode, result.stdout.replace('mac-vendor.py', 'mac-vendor.sh'),
                result.stderr.replace('mac-vendor.py', 'mac-vendor.sh'))

    def compare(self, args, stdin='', status=0):
        args = ['--cache-dir', str(self.cache), *args]
        py = self.run_one('python', args, stdin)
        sh = self.run_one('bash', args, stdin)
        self.assertEqual(self.normalized(py), self.normalized(sh), args)
        self.assertEqual(py.returncode, status, py.stderr)
        return sh

    def test_formats_prefixes_flags_and_unknown(self):
        queries = ['00:11:22:33:44:55', '00-11-22-33-44-55', '0011.2233.4455',
                   '001122334455', '001122', '0011223', '00112233', '001122335ABC',
                   '021122334455', '011122334455', '031122334455', 'FFFFFF', '000000',
                   'junk: 00!11!22', 'aabbcc', ' 001122 ', '001122\t', '001122\n']
        for options in [[], ['--quiet'], ['--show-address'], ['--json'], ['--json', '-s']]:
            with self.subTest(options=options):
                self.compare(['--offline', *options, *queries])

    def test_invalid_queries_and_no_partial_output(self):
        for query in ['', 'xyz', '12345', '00112233445566', "'", '"', "'\"", '\t\n', '\b\f\x01']:
            with self.subTest(query=query):
                result = self.compare(['--offline', '--json', '001122', query], status=1)
                self.assertEqual(result.stdout, '')

    def test_quiet_json_organization_only(self):
        queries = ['001122', '001122334455', 'FFFFFF', 'AABBCC']
        expected = [{'organization': value} for value in
                    ['Parent Company', ROWS[2][3], None, ROWS[8][3]]]
        for flags in [['--quiet', '--json'], ['--json', '-s', '--show-address']]:
            with self.subTest(flags=flags):
                result = self.compare(['--offline', *flags, *queries])
                self.assertEqual(json.loads(result.stdout), expected)
                self.assertEqual(result.stderr, '')
        result = self.compare(['--offline', '-s', '--json'], '\n'.join(queries))
        self.assertEqual(json.loads(result.stdout), expected)
        result = self.compare(['--offline', '-s', '--json', queries[0]])
        self.assertEqual(json.loads(result.stdout), expected[:1])
        self.assertEqual(self.compare(['--offline', '-s', 'FFFFFF']).stdout, 'Unknown\n')
        self.assertIn('normalized', json.loads(self.compare(['--offline', '--json', queries[0]]).stdout)[0])
        result = self.compare(['--offline', '-s', '--json', queries[0], 'invalid'], status=1)
        self.assertEqual(result.stdout, '')

    def test_update_offline_conflict_has_no_side_effects(self):
        original = self.cfile.read_bytes()
        stamp = self.cfile.stat().st_mtime_ns
        for flags in [['--update', '--offline'], ['--offline', '--update'], ['-su', '--offline']]:
            with self.subTest(flags=flags):
                result = self.compare([*flags, '001122'], status=2)
                self.assertEqual(result.stdout, '')
                self.assertIn('--update and --offline cannot be combined', result.stderr)
                self.assertEqual(self.cfile.read_bytes(), original)
                self.assertEqual(self.cfile.stat().st_mtime_ns, stamp)
                self.assertFalse((self.base / 'network.log').exists())
                self.assertFalse((self.cache / 'metadata.json').exists())
        self.cfile.unlink()
        self.cache.rmdir()
        result = self.compare(['--update', '--offline'], status=2)
        self.assertIn('--update and --offline cannot be combined', result.stderr)
        self.assertFalse(self.cache.exists())
        self.assertFalse((self.base / 'network.log').exists())

    def test_stdin(self):
        for data in [' \n\t\n  001122\r\n001122334455\n', '001122', '\u00a0001122\u3000\n',
                     '001122\ninvalid\n']:
            with self.subTest(data=data):
                self.compare(['--offline', '--json'], data, status=1 if 'invalid' in data else 0)
        self.compare(['--offline'], ' \n\t\n', status=2)
        self.compare(['--offline'], '', status=2)
        self.compare(['--offline', '001122'], 'invalid stdin ignored')

    def test_cli(self):
        good = [['--version'], ['--off', '--js', '001122'], ['--offline', '-ss', '001122'],
                ['--offline', '--timeout=+03', '--max-age-days=1_000', '001122'],
                ['--offline', '--timeout', '-1', '--max-age-days', '-2', '001122'],
                ['--offline', '--', '-001122'], ['001122', '--offline'],
                ['--offline', '--timeout', ' 30 ', '001122']]
        for args in good:
            with self.subTest(args=args): self.compare(args)
        bad = [['--nonsense'], ['--jsoon', '001122'], ['--timeout'], ['--cache-dir'],
               ['--timeout=abc'], ['--max-age-days=1.5'], ['--json=true'],
               ['--quiet=false'], ['--s'], ['--timeout', '--offline'],
               ['001122', '--offline', '0011223']]
        for args in bad:
            with self.subTest(args=args): self.compare(args, status=2)
        for implementation in ['python', 'bash']:
            result = self.run_one(implementation, ['--help'])
            self.assertEqual(result.returncode, 0)
            for flag in ['--offline', '--show-address', '--max-age-days', '--timeout']:
                self.assertIn(flag, result.stdout)

    def test_default_and_relative_cache_locations(self):
        for xdg in [True, False]:
            env = dict(self.env, HOME=str(self.base / 'home'))
            env.pop('XDG_CACHE_HOME', None)
            if xdg:
                env['XDG_CACHE_HOME'] = str(self.base / 'xdg')
                directory = Path(env['XDG_CACHE_HOME']) / 'mac-vendor'
            else:
                directory = Path(env['HOME']) / '.cache/mac-vendor'
            directory.mkdir(parents=True)
            (directory / self.cfile.name).write_bytes(tsv(ROWS))
            py = self.run_one('python', ['--offline', '--json', '001122'], env=env)
            sh = self.run_one('bash', ['--offline', '--json', '001122'], env=env)
            self.assertEqual(self.normalized(py), self.normalized(sh))
            self.assertEqual(sh.returncode, 0)
        for path in ['cache', './cache//.', '']:
            if not path: (self.base / self.cfile.name).write_bytes(tsv(ROWS))
            args = ['--cache-dir', path, '--offline', '001122']
            self.assertEqual(self.normalized(self.run_one('python', args)),
                             self.normalized(self.run_one('bash', args)))

    def test_missing_empty_and_malformed_cache(self):
        self.cfile.unlink()
        self.compare(['--offline', '001122'], status=1)
        self.cfile.touch()
        self.compare(['--offline', '001122'], status=1)
        for content in [b'wrong\theader\nfoo\tbar\n', tsv([]), tsv(ROWS + [['001122', 24, '', 'Last', '']])]:
            self.cfile.write_bytes(content)
            self.compare(['--offline', '--json', '001122', 'ABCDEF', 'FFFFFE'])

    def test_fresh_and_stale_offline_do_not_download(self):
        self.compare(['001122'])
        old = time.time() - 30 * 86400
        os.utime(self.cfile, (old, old))
        self.compare(['--offline', '001122'])
        self.assertFalse((self.base / 'network.log').exists())

    def test_future_cache_and_symlink_freshness(self):
        target = self.cache / 'target.tsv'
        self.cfile.rename(target)
        self.cfile.symlink_to(target)
        future = time.time() + 86400
        os.utime(target, (future, future))
        old = time.time() - 30 * 86400
        os.utime(self.cfile, (old, old), follow_symlinks=False)
        self.compare(['001122'])
        self.assertFalse((self.base / 'network.log').exists())

    def refresh_pair(self, args, *, old=False, missing=False, stdin='', fail=None):
        results = []
        for implementation in ['python', 'bash']:
            self.cfile.write_bytes(tsv(ROWS))
            meta = self.cache / 'metadata.json'
            meta.unlink(missing_ok=True)
            if old:
                stamp = time.time() - 9 * 86400
                os.utime(self.cfile, (stamp, stamp))
            if missing: self.cfile.unlink()
            log = self.base / 'network.log'
            log.unlink(missing_ok=True)
            env = dict(self.env)
            if fail: env['TEST_FAIL'] = fail
            result = self.run_one(implementation, ['--cache-dir', str(self.cache), *args], stdin, env)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            metadata = json.loads(meta.read_text()) if meta.exists() else None
            if metadata:
                self.assertIn('updated_at', metadata)
                metadata.pop('updated_at')
                metadata['tool'] = 'mac-vendor.sh'
            results.append((result, self.cfile.read_bytes() if self.cfile.exists() else None, calls, metadata))
        py, sh = results
        self.assertEqual(py[0].returncode, sh[0].returncode)
        self.assertEqual(py[0].stdout, sh[0].stdout)
        if not fail: self.assertEqual(py[0].stderr.replace('mac-vendor.py', 'mac-vendor.sh'), sh[0].stderr)
        self.assertEqual(py[1:], sh[1:])
        self.assertFalse(list(self.cache.glob('.mac-vendor.*')))
        return sh

    def test_downloads_and_shared_cache(self):
        for args, old, missing in [(['--update', '--json', '001122334455'], False, False),
                                   (['--update', '-s', '--json', '001122'], False, False),
                                   (['001122'], True, False), (['001122'], False, True),
                                   (['--update'], False, False),
                                   (['--max-age-days=-1', '--update', '001122'], False, False),
                                   (['--max-age-days=0', '--update', '001122'], False, False)]:
            with self.subTest(args=args):
                result = self.refresh_pair(args, old=old, missing=missing)
                expected = 8 if '--max-age-days=-1' in args or '--max-age-days=0' in args else 4
                self.assertEqual(len(result[2]), expected)
                self.assertEqual(result[3]['record_count'], 12)
                self.assertEqual(self.cfile.stat().st_mode & 0o777, 0o644)
                self.compare(['--offline', '--json', '001122334455'])

    def test_failed_download_preserves_old_cache(self):
        for failure in ['all', 'https://standards-oui.ieee.org/oui36/oui36.csv']:
            with self.subTest(failure=failure):
                result = self.refresh_pair(['--update', '001122'], fail=failure)
                self.assertEqual(result[0].returncode, 1)
                self.assertEqual(result[1], tsv(ROWS))
                self.assertIsNone(result[3])
                self.assertIn('ERROR: Could not download', result[0].stderr)

    def test_csv_header_errors_and_aliases(self):
        first = self.fixtures / PATHS[0]
        for text in ['', '\nAssignment,Organization\n001122,Ignored\n']:
            first.write_text(text)
            result = self.refresh_pair(['--update', '001122'])
            self.assertEqual(result[0].returncode, 1)
            self.assertIn('CSV has no header row', result[0].stderr)
        first.write_text('Assignment,Company Name,Organization Address\n001122,Alias vendor,Address\n')
        result = self.refresh_pair(['--update', '-s', '001122'])
        self.assertEqual(result[0].stdout, 'Alias vendor\n')

    def run_tty(self, implementation, args, line=None):
        master, slave = pty.openpty()
        process = subprocess.Popen(self.command(implementation, ['--cache-dir', str(self.cache), *args]),
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, cwd=self.base)
        os.close(slave)
        try:
            if line is not None: os.write(master, line.encode())
            out, err = process.communicate(timeout=30)
            return process.returncode, out.decode(), err.decode()
        finally:
            os.close(master)
            if process.poll() is None: process.kill(); process.wait()

    def test_interactive_prompt_and_update(self):
        for args, line in [(['--offline'], ' 001122 \n'), (['--offline'], ' \n'),
                           (['--update', '-s'], None)]:
            with self.subTest(args=args, line=line):
                py = self.run_tty('python', args, line)
                sh = self.run_tty('bash', args, line)
                self.assertEqual(py[0:2], sh[0:2])
                self.assertEqual(py[2].replace('mac-vendor.py', 'mac-vendor.sh'), sh[2])

    def test_interrupt(self):
        prompt = b'MAC address or prefix: '
        for implementation in ['python', 'bash']:
            master, slave = pty.openpty()
            process = subprocess.Popen(self.command(implementation, ['--cache-dir', str(self.cache), '--offline']),
                                       stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env, cwd=self.base)
            os.close(slave)
            try:
                self.assertEqual(process.stdout.read(len(prompt)), prompt)
                process.send_signal(signal.SIGINT)
                out, err = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 130)
                self.assertEqual(err, b'Interrupted.\n')
            finally:
                os.close(master)
                if process.poll() is None: process.kill(); process.wait()


if __name__ == '__main__':
    unittest.main(verbosity=2)
