#!/usr/bin/env python3
"""Network-free behavior tests for whois-rdap.sh."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "whois-rdap.sh"

KRNIC = """query : 211.46.181.148

# ENGLISH
[ Network Information ]
IPv4 Address       : 211.46.180.0 - 211.46.183.255 (/22)
Organization Name  : Korea Telecom
Service Name       : KORNET
E-Mail             : kornet_ip@kt.com

More specific assignment information is as follows.
[ Network Information ]
IPv4 Address       : 211.46.181.0 - 211.46.181.255 (/24)
Organization Name  : KT
Network Type       : CUSTOMER
E-Mail             : kornet_ip@kt.com
- KISA/KRNIC WHOIS Service -
"""

APNIC = """% [whois.apnic.net]
inetnum: 211.46.180.0 - 211.46.183.255
netname: KORNET-KR
remarks: This information has been partially mirrored by APNIC from
remarks: KRNIC. To obtain more specific information, please use the
remarks: KRNIC whois server at whois.kisa.or.kr.
"""

RDAP = {
    "objectClassName": "ip network",
    "name": "KORNET-KR",
    "handle": "211.46.180.0 - 211.46.183.255",
    "startAddress": "211.46.180.0",
    "endAddress": "211.46.183.255",
    "type": "ALLOCATED PORTABLE",
    "country": "KR",
    "status": ["active"],
    "remarks": [{"title": "description", "description": ["Korea Telecom"]}],
    "entities": [
        {
            "roles": ["abuse"],
            "handle": "IRT-KRNIC-KR",
            "vcardArray": ["vcard", [
                ["fn", {}, "text", "IRT-KRNIC-KR"],
                ["email", {}, "text", "hostmaster@nic.or.kr"],
            ]],
        },
        {
            "roles": ["technical"],
            "handle": "IM9-KR",
            "vcardArray": ["vcard", [
                ["fn", {}, "text", "IP Manager"],
                ["email", {}, "text", "kornet_ip@kt.com"],
                ["tel", {}, "text", "+82-2-500-6630"],
            ]],
        },
    ],
    "links": [{"rel": "self", "href": "https://krnic.rdap.apnic.net/ip/211.46.180.0/22"}],
}

WHOIS_MOCK = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write('whois ' + ' '.join(args) + '\n')
host = args[1] if len(args) > 2 and args[0] == '-h' else ''
mode = os.environ.get('TEST_DEFAULT', 'krnic')
if not host and mode == 'fail':
    print('simulated WHOIS failure', file=sys.stderr)
    sys.exit(7)
if not host and mode == 'empty':
    sys.exit(0)
if host == 'whois.kisa.or.kr' and os.environ.get('TEST_REFERRAL_FAIL') == '1':
    print('simulated referral failure', file=sys.stderr)
    sys.exit(7)
if mode == 'chain':
    if host == 'whois.alpha.net':
        print('refer: whois.beta.net')
    elif host == 'whois.beta.net':
        print('refer: whois.alpha.net')
    else:
        print('refer: whois.alpha.net')
elif mode == 'invalid' and not host:
    print('refer: whois://127.0.0.1')
elif host == 'whois.apnic.net' or (not host and mode == 'apnic'):
    print(os.environ['TEST_APNIC'])
elif host == 'whois.kisa.or.kr' or not host:
    print(os.environ['TEST_KRNIC'])
else:
    print('inetnum: 211.46.180.0 - 211.46.183.255')
'''

CURL_MOCK = r'''#!/usr/bin/env python3
import os, sys
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write('curl ' + sys.argv[-1] + '\n')
print(os.environ['TEST_RDAP'])
'''


class WhoisRdapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="whois-rdap-tests-")
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls"
        for name, script in (("whois", WHOIS_MOCK), ("curl", CURL_MOCK)):
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, *args, **settings):
        env = dict(os.environ)
        env.update(
            PATH=str(self.bin) + os.pathsep + env["PATH"],
            TEST_CALLS=str(self.calls),
            TEST_KRNIC=KRNIC,
            TEST_APNIC=APNIC,
            TEST_RDAP=json.dumps(RDAP),
            PYTHONDONTWRITEBYTECODE="1",
            LC_ALL="C.UTF-8",
        )
        env.update(settings)
        self.calls.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            cwd=self.base, env=env, text=True, capture_output=True, timeout=15,
        )

    def call_lines(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_malformed_ips_fail_before_io(self):
        invalid = (
            "211.46.181.999", "211.46.181", "999.999.999.999",
            "2001:db8::gg", "[2001:db8::gg]",
            "[2001:db8::1]junk", "211.46.181.148:abc",
            "https://211.46.181.999/path", "https://[2001:db8::gg]/",
        )
        for index, target in enumerate(invalid):
            with self.subTest(target=target):
                output = self.base / f"saved-{index}"
                result = self.run_script("--save", "--output-dir", str(output), target)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.count("ERROR:"), 1)
                self.assertIn("malformed IP address", result.stderr)
                self.assertFalse(output.exists())
                self.assertEqual(self.call_lines(), [])

    def test_valid_ip_forms_and_domain(self):
        cases = (
            ("211.46.181.148", "ip", "211.46.181.148"),
            ("2001:db8::1", "ip", "2001:db8::1"),
            ("[2001:db8::1]", "ip", "2001:db8::1"),
            ("https://[2001:db8::1]/path", "ip", "2001:db8::1"),
            ("https://211.46.181.148/path", "ip", "211.46.181.148"),
            ("www.example.com", "domain", "www.example.com"),
        )
        for target, kind, normalized in cases:
            with self.subTest(target=target):
                result = self.run_script("--dry-run", "--format", "json", target)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(result.stdout)
                self.assertEqual(data["target"]["type"], kind)
                self.assertEqual(data["target"]["normalized"], normalized)
                self.assertEqual(self.call_lines(), [])

    def test_ip_text_is_useful_summary_without_refetching_krnic(self):
        result = self.run_script("--no-hints", "211.46.181.148")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WHOIS:          collected", result.stdout)
        self.assertIn("211.46.181.0 - 211.46.181.255 (/24)", result.stdout)
        self.assertIn("Organizations:\n    - KT\n    - Korea Telecom", result.stdout)
        self.assertIn("Network name:   KORNET", result.stdout)
        self.assertIn("Network type:   CUSTOMER", result.stdout)
        self.assertIn("Registry type:  ALLOCATED PORTABLE", result.stdout)
        self.assertIn("Contact email:  kornet_ip@kt.com", result.stdout)
        self.assertIn("Network range:  211.46.180.0 - 211.46.183.255", result.stdout)
        self.assertIn("abuse: IRT-KRNIC-KR <hostmaster@nic.or.kr>", result.stdout)
        self.assertIn("technical: IP Manager <kornet_ip@kt.com> (+82-2-500-6630)", result.stdout)
        self.assertNotIn("Raw WHOIS", result.stdout)
        self.assertNotIn("Raw RDAP", result.stdout)
        self.assertNotIn('"entities"', result.stdout)
        self.assertEqual(len(self.call_lines()), 2)
        self.assertEqual(self.call_lines()[0], "whois 211.46.181.148")

        raw = self.run_script("--raw", "--no-hints", "211.46.181.148")
        self.assertEqual(raw.returncode, 0, raw.stderr)
        self.assertIn("Raw WHOIS", raw.stdout)
        self.assertIn("Organization Name  : KT", raw.stdout)
        self.assertIn('"startAddress": "211.46.180.0"', raw.stdout)
        self.assertIn('"entities"', raw.stdout)

    def test_network_type_uses_most_specific_matching_record(self):
        parent_type = KRNIC.replace(
            "Service Name       : KORNET",
            "Network Type       : INFRA\nService Name       : KORNET",
        )
        result = self.run_script(
            "--no-rdap", "--no-hints", "211.46.181.148", TEST_KRNIC=parent_type,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Network type:   CUSTOMER", result.stdout)
        self.assertNotIn("Network type:   INFRA", result.stdout)

        child_without_type = parent_type.replace("Network Type       : CUSTOMER\n", "")
        result = self.run_script(
            "--no-hints", "211.46.181.148",
            TEST_KRNIC=child_without_type,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Network type:", result.stdout)
        self.assertIn("Registry type:  ALLOCATED PORTABLE", result.stdout)

        conflicting = KRNIC + "\nIPv4 Address       : 211.46.181.0 - 211.46.181.255 (/24)\nNetwork Type       : INFRA\n"
        result = self.run_script(
            "--no-rdap", "--no-hints", "211.46.181.148", TEST_KRNIC=conflicting,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Network types (conflicting):\n    - CUSTOMER\n    - INFRA", result.stdout)

    def test_domain_raw_remains_opt_in(self):
        result = self.run_script("--no-hints", "example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Raw WHOIS", result.stdout)
        raw = self.run_script("--raw", "--no-hints", "example.com")
        self.assertEqual(raw.returncode, 0, raw.stderr)
        self.assertIn("Raw WHOIS", raw.stdout)

    def test_ip_referral_and_json_evidence(self):
        result = self.run_script("--format", "json", "211.46.181.148", TEST_DEFAULT="apnic")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["collection"]["whois"], "collected")
        self.assertIsNone(data["collection"]["whoisError"])
        self.assertIn("WHOIS referral: whois.kisa.or.kr", data["data"]["whoisRaw"])
        self.assertIn("211.46.181.0 - 211.46.181.255 (/24)", data["data"]["whoisRaw"])
        self.assertEqual(data["data"]["rdap"], RDAP)
        self.assertEqual(self.call_lines()[:2], [
            "whois 211.46.181.148",
            "whois -h whois.kisa.or.kr 211.46.181.148",
        ])
        self.assertEqual(len(self.call_lines()), 3)

    def test_referral_limit_and_loop(self):
        limited = self.run_script("--max-referrals", "0", "--no-rdap", "211.46.181.148", TEST_DEFAULT="apnic")
        self.assertEqual(limited.returncode, 0, limited.stderr)
        self.assertEqual(self.call_lines(), ["whois 211.46.181.148"])

        loop = self.run_script("--max-referrals", "5", "--no-rdap", "211.46.181.148", TEST_DEFAULT="chain")
        self.assertEqual(loop.returncode, 0, loop.stderr)
        self.assertEqual(self.call_lines(), [
            "whois 211.46.181.148",
            "whois -h whois.alpha.net 211.46.181.148",
            "whois -h whois.beta.net 211.46.181.148",
        ])

        invalid = self.run_script("--no-rdap", "211.46.181.148", TEST_DEFAULT="invalid")
        self.assertEqual(invalid.returncode, 0, invalid.stderr)
        self.assertIn("Ignoring invalid WHOIS referral server", invalid.stderr)
        self.assertEqual(self.call_lines(), ["whois 211.46.181.148"])

    def test_save_includes_referral_record(self):
        output = self.base / "saved"
        result = self.run_script(
            "--save", "--output-dir", str(output), "--format", "json",
            "211.46.181.148", TEST_DEFAULT="apnic",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        saved = [Path(path) for path in data["collection"]["whoisFiles"]]
        self.assertEqual(len(saved), 2)
        self.assertTrue(all(path.is_file() for path in saved))
        self.assertIn("(/24)", saved[1].read_text())
        self.assertTrue(Path(data["collection"]["rdapFile"]).is_file())

        summary = self.run_script(
            "--save", "--output-dir", str(self.base / "summary-saved"),
            "--no-hints", "211.46.181.148",
        )
        self.assertEqual(summary.returncode, 0, summary.stderr)
        self.assertNotIn("Raw WHOIS", summary.stdout)
        self.assertNotIn("Raw RDAP", summary.stdout)
        self.assertTrue((self.base / "summary-saved" / "whois-default.txt").is_file())
        self.assertTrue((self.base / "summary-saved" / "rdap.json").is_file())

    def test_rir_all_skips_krnic_referral_when_already_collected(self):
        result = self.run_script("--rir-all", "--no-rdap", "211.46.181.148")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.call_lines()), 6)
        self.assertFalse(any("-h whois.kisa.or.kr" in line for line in self.call_lines()))

    def test_whois_failure_and_partial_status(self):
        failed = self.run_script("--format", "json", "--no-rdap", "211.46.181.148", TEST_DEFAULT="fail")
        self.assertEqual(failed.returncode, 0, failed.stderr)
        data = json.loads(failed.stdout)
        self.assertEqual(data["collection"]["whois"], "unavailable")
        self.assertIn("simulated WHOIS failure", data["collection"]["whoisError"])

        partial = self.run_script(
            "--format", "json", "--no-rdap", "211.46.181.148",
            TEST_DEFAULT="apnic", TEST_REFERRAL_FAIL="1",
        )
        self.assertEqual(partial.returncode, 0, partial.stderr)
        data = json.loads(partial.stdout)
        self.assertEqual(data["collection"]["whois"], "partial")
        self.assertIn("simulated referral failure", data["collection"]["whoisError"])


if __name__ == "__main__":
    unittest.main()
