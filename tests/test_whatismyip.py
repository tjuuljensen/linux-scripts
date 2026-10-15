#!/usr/bin/env python3
"""Network-free tests: python3 tests/test_whatismyip.py [repository-directory].

Run on Linux with Bash, jq and standard Unix tools installed. Each test uses
an isolated PATH: omitted dependencies really are absent, and provider commands
are local doubles. Windows checkouts should be copied into the WSL filesystem.
"""
import itertools
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
TOOLS = {name: shutil.which(name) for name in ['awk', 'sed', 'head', 'sort', 'wc', 'cat', 'jq', 'timeout']}
if not BASH or not all(TOOLS.values()):
    raise SystemExit('Tests require Bash, jq, timeout, awk, sed, head, sort, wc and cat.')

PROVIDER_DOUBLE = r'''#!BASH_PATH
name=${0##*/}
printf '%s' "$name" >> "$TEST_CALLS"
printf ' %s' "$@" >> "$TEST_CALLS"
printf '\n' >> "$TEST_CALLS"
case $name in
  dig)
    case " $* " in
      *myip.opendns.com*) value=${TEST_OPENDNS4:-203.0.113.10} ;;
      *' -4 '*) value=${TEST_GOOGLE4:-203.0.113.10} ;;
      *) value=${TEST_GOOGLE6:-2001:db8::10} ;;
    esac ;;
  curl)
    case " $* " in
      *https://api.ipify.org*) value=${TEST_IPIFY4:-203.0.113.10} ;;
      *) value=${TEST_IPIFY6:-2001:db8::10} ;;
    esac ;;
  ip)
    case " $* " in
      *' -4 '*) value=${TEST_ROUTE4:-192.168.1.10} ;;
      *) value=${TEST_ROUTE6:-fd00::10} ;;
    esac
    [[ $value != fail ]] || exit 1
    printf 'destination dev eth0 src %s metric 100\n' "$value"
    exit 0 ;;
esac
[[ $value != fail ]] || exit 1
printf '%s\n' "$value"
'''.replace('BASH_PATH', BASH)


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='whatismyip-tests-')
        self.base = Path(self.temp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.calls = self.base / 'calls'

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, args=(), *, dig=True, curl=True, ip=True, jq=True, timeout=True, **responses):
        for path in self.bin.iterdir():
            path.unlink()
        for name, executable in TOOLS.items():
            if (name == 'jq' and not jq) or (name == 'timeout' and not timeout):
                continue
            (self.bin / name).symlink_to(executable)
        for name, enabled in [('dig', dig), ('curl', curl), ('ip', ip)]:
            if enabled:
                path = self.bin / name
                path.write_text(PROVIDER_DOUBLE)
                path.chmod(0o755)
        self.calls.unlink(missing_ok=True)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('TEST_') and key not in ('BASH_ENV', 'ENV')}
        env.update(PATH=str(self.bin), TEST_CALLS=str(self.calls), LC_ALL='C')
        env.update(responses)
        return subprocess.run([BASH, str(ROOT / 'whatismyip.sh'), *args],
                              capture_output=True, text=True, cwd=self.base, env=env, timeout=15)

    def parsed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout)

    def assert_summary(self, value, count, status, consistent):
        self.assertEqual(value['providerCount'], count)
        self.assertEqual(value['status'], status)
        self.assertIs(value['consistent'], consistent)

    def test_dependency_matrix(self):
        for dig, curl, ip in itertools.product([False, True], repeat=3):
            with self.subTest(dig=dig, curl=curl, ip=ip):
                result = self.run_script(['--json', '--debug'], dig=dig, curl=curl, ip=ip)
                if not dig and not curl:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('No public-IP provider available', result.stderr)
                    self.assertEqual(result.stdout, '')
                    self.assertFalse(self.calls.exists())
                    continue
                data = self.parsed(result)
                for family, dns_count in [('ipv4', 2), ('ipv6', 1)]:
                    count = dns_count * dig + curl
                    self.assert_summary(data[family], count,
                                        'consistent' if count >= 2 else 'single_provider',
                                        True if count >= 2 else None)
                    providers = data[family]['providers']
                    self.assertEqual(providers['googleDnsTxt']['status'], 'ok' if dig else 'skipped')
                    self.assertEqual(providers['ipifyHttps']['status'], 'ok' if curl else 'skipped')
                    self.assertEqual(providers['localRoute']['status'], 'ok' if ip else 'skipped')
                calls = self.calls.read_text()
                for name, installed in [('dig', dig), ('curl', curl), ('ip', ip)]:
                    self.assertEqual(any(line.startswith(name + ' ') for line in calls.splitlines()), installed)

    def test_no_dns_text_and_debug_warnings(self):
        result = self.run_script(dig=False, ip=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count('single provider'), 2)
        self.assertNotIn('consistent', result.stdout)
        self.assertIn('OpenDNS:         skipped', result.stdout)
        self.assertIn('Local route:     skipped', result.stdout)
        self.assertIn('dig not found', result.stderr)
        self.assertIn('ip not found', result.stderr)
        data = self.parsed(self.run_script(['--json', '--debug'], dig=False, ip=False))
        self.assertTrue(any('dig not found' in warning for warning in data['warnings']))
        self.assertTrue(any('ip not found' in warning for warning in data['warnings']))

    def test_no_dns_standard_json(self):
        data = self.parsed(self.run_script(['--json', '--verbose'], dig=False))
        self.assertNotIn('warnings', data)
        for family in ['ipv4', 'ipv6']:
            self.assert_summary(data[family], 1, 'single_provider', None)
            self.assertIsNone(data[family]['providers']['googleDnsTxt'])

    def test_quiet_modes_stay_clean(self):
        for families, expected in [([], {'ipv4': '203.0.113.10', 'ipv6': '2001:db8::10'}),
                                   (['-4'], {'ipv4': '203.0.113.10'}),
                                   (['-6'], {'ipv6': '2001:db8::10'})]:
            with self.subTest(families=families):
                result = self.run_script([*families, '-q', '--verbose'], dig=False, ip=False)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout, ''.join(value + '\n' for value in expected.values()))
                data = self.parsed(self.run_script([*families, '-q', '--json', '--debug'], dig=False, ip=False))
                self.assertEqual(data, expected)

    def test_https_disable_aliases_without_dns_fail(self):
        for flag in ['--no-https', '--no-ipify', '--no-curl-fallback']:
            with self.subTest(flag=flag):
                result = self.run_script([flag, '--json', '-q'], dig=False)
                self.assertEqual(result.returncode, 1)
                self.assertIn('No public-IP provider available', result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertFalse(self.calls.exists())

    def test_https_disable_aliases_with_dns(self):
        for flag in ['--no-https', '--no-ipify', '--no-curl-fallback']:
            with self.subTest(flag=flag):
                data = self.parsed(self.run_script([flag, '--json', '--debug']))
                self.assert_summary(data['ipv4'], 2, 'consistent', True)
                self.assert_summary(data['ipv6'], 1, 'single_provider', None)
                self.assertEqual(data['ipv4']['providers']['ipifyHttps']['status'], 'skipped')
                self.assertNotIn('curl ', self.calls.read_text())

    def test_missing_jq_only_blocks_json(self):
        result = self.run_script(['--json'], jq=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn('jq is required', result.stderr)
        self.assertFalse(self.calls.exists())
        result = self.run_script(['-4', '-q'], dig=False, ip=False, jq=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '203.0.113.10\n')

    def test_missing_timeout_uses_provider_timeouts(self):
        data = self.parsed(self.run_script(['--json', '--debug', '--timeout', '3'], timeout=False))
        self.assertTrue(any('timeout command not found' in warning for warning in data['warnings']))
        calls = self.calls.read_text()
        self.assertIn('+time=3', calls)
        self.assertIn('--max-time 3', calls)
        self.assert_summary(data['ipv4'], 3, 'consistent', True)

    def test_single_success_among_failed_providers(self):
        data = self.parsed(self.run_script(['--json', '--debug'], TEST_OPENDNS4='fail',
                                          TEST_GOOGLE4='fail', TEST_GOOGLE6='fail'))
        for family in ['ipv4', 'ipv6']:
            self.assert_summary(data[family], 1, 'single_provider', None)
            self.assertEqual(data[family]['providers']['googleDnsTxt']['status'], 'unavailable')
            self.assertEqual(data[family]['providers']['localRoute']['status'], 'ok')

    def test_all_providers_fail_without_counting_local_routes(self):
        responses = dict(TEST_OPENDNS4='fail', TEST_GOOGLE4='fail', TEST_GOOGLE6='fail',
                         TEST_IPIFY4='fail', TEST_IPIFY6='fail')
        data = self.parsed(self.run_script(['--json', '--debug'], **responses))
        for family in ['ipv4', 'ipv6']:
            self.assert_summary(data[family], 0, 'unavailable', None)
            self.assertIsNone(data[family]['public'])
            self.assertEqual(data[family]['providers']['localRoute']['status'], 'ok')
        result = self.run_script(['-q'], **responses)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
        self.assertEqual(self.parsed(self.run_script(['-q', '--json'], **responses)), {})

    def test_disagreement_and_agreement_in_both_json_shapes(self):
        for mode in [['--json'], ['--json', '--debug']]:
            with self.subTest(mode=mode):
                data = self.parsed(self.run_script(mode))
                self.assert_summary(data['ipv4'], 3, 'consistent', True)
                self.assert_summary(data['ipv6'], 2, 'consistent', True)
                self.assertEqual(len(data['ipv4']['values']), 1)
                data = self.parsed(self.run_script(mode, TEST_IPIFY4='203.0.113.11', TEST_IPIFY6='2001:db8::11'))
                self.assert_summary(data['ipv4'], 3, 'provider_mismatch', False)
                self.assert_summary(data['ipv6'], 2, 'provider_mismatch', False)
        result = self.run_script(TEST_IPIFY4='203.0.113.11', TEST_IPIFY6='2001:db8::11')
        self.assertEqual(result.stdout.count('provider mismatch'), 2)

    def test_family_selection(self):
        for option, family in [('-4', 'ipv4'), ('-6', 'ipv6')]:
            with self.subTest(option=option):
                data = self.parsed(self.run_script([option, '--json'], dig=False, ip=False))
                self.assertEqual(set(data), {family})
                self.assert_summary(data[family], 1, 'single_provider', None)

    def test_help_and_version_need_no_providers(self):
        for flag in ['--help', '--version']:
            result = self.run_script([flag], dig=False, curl=False, ip=False, jq=False, timeout=False)
            self.assertEqual(result.returncode, 0)
            self.assertIn('1.4.0', result.stdout)
            self.assertFalse(self.calls.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
