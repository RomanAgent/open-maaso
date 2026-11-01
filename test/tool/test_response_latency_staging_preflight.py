import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest

PATH = Path(__file__).resolve().parents[2] / 'tool/response_latency/staging_preflight.py'
spec = importlib.util.spec_from_file_location('staging_preflight', PATH)
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe
spec.loader.exec_module(probe)
ACCOUNT = '11111111-2222-4333-8444-555555555555'
DIGEST = hashlib.sha256(ACCOUNT.encode()).hexdigest()


def session(*, update=None, account=ACCOUNT, alg='RS256'):
    claims = {'sub': ACCOUNT, 'app_id': 'maaso', 'aud': ['maaso-agent'],
              'scope': ['maaso:user'], 'exp': 2000}
    claims.update(update or {})
    def enc(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    token = enc({'alg': alg}) + '.' + enc(claims) + '.synthetic_signature'
    return json.dumps({'account_uuid': account, 'access_token': token}).encode()


class Tests(unittest.TestCase):
    def test_session_binding_is_not_authentication(self):
        parsed = probe.parse_session(session(), DIGEST, now=1000)
        self.assertNotIn('synthetic_signature', repr(parsed))

    def test_wrong_account_never_reaches_server(self):
        with self.assertRaisesRegex(probe.PreflightError, 'account_binding_mismatch'):
            probe.parse_session(session(), '0' * 64, now=1000)

    def test_issuer_audience_expiry_and_subject_must_match(self):
        for update in [{'app_id': 'app007'}, {'aud': ['other']}, {'scope': []},
                       {'exp': 999}, {'exp': True}, {'exp': float('nan')},
                       {'exp': float('inf')}, {'sub': 'different'}]:
            with self.subTest(update=update), self.assertRaises(probe.PreflightError):
                probe.parse_session(session(update=update), DIGEST, now=1000)
        with self.assertRaises(probe.PreflightError):
            probe.parse_session(session(alg='none'), DIGEST, now=1000)

    def test_rejects_extra_credentials_and_duplicate_keys(self):
        data = json.loads(session())
        data['refresh_token'] = 'must-not-read-or-refresh'
        with self.assertRaisesRegex(probe.PreflightError, 'session_shape_invalid'):
            probe.parse_session(json.dumps(data).encode(), DIGEST, now=1000)
        with self.assertRaisesRegex(probe.PreflightError, 'duplicate_json_key'):
            probe.decode(b'{"data":1,"data":2}')

    def test_preflight_reads_only_policy_and_presence_and_never_admits_batch(self):
        paths = []
        def reader(path, value):
            paths.append(path)
            if path == probe.POLICY_PATH:
                return {'mode': 'enforce', 'revision': 7, 'remainingTtlMs': 1000}
            return {'presences': []}
        result = probe.check(probe.parse_session(session(), DIGEST, now=1000), reader=reader)
        self.assertEqual(paths, [probe.POLICY_PATH, probe.PRESENCES_PATH])
        self.assertEqual(result['status'], 'authenticated_preflight_only')
        self.assertFalse(result['benchmarkAllowed'])
        self.assertEqual(result['dedicatedAccountPurpose'], 'unverified')

    def test_presence_output_redacts_identity_and_does_not_take_over(self):
        def reader(path, value):
            if path == probe.POLICY_PATH:
                return {'mode': 'shadow', 'revision': 2, 'remainingTtlMs': 1000}
            return {'presences': [{'deviceLabel': 'PRIVATE PHONE', 'holderProof': 'SECRET'}]}
        result = probe.check(probe.Session('token'), reader=reader)
        self.assertEqual(result['activePresenceCount'], 1)
        raw = json.dumps(result)
        self.assertNotIn('PRIVATE', raw)
        self.assertNotIn('SECRET', raw)
        self.assertNotIn(ACCOUNT, raw)

    def test_invalid_policy_aborts_before_presence(self):
        calls = []
        def reader(path, value):
            calls.append(path)
            return {'mode': 'unknown', 'revision': 1, 'remainingTtlMs': 1000}
        with self.assertRaises(probe.PreflightError):
            probe.check(probe.Session('token'), reader=reader)
        self.assertEqual(calls, [probe.POLICY_PATH])

    def test_arbitrary_routes_and_redirects_cannot_receive_bearer(self):
        with self.assertRaisesRegex(probe.PreflightError, 'route_not_allowed'):
            probe.get_json('https://elsewhere.test', probe.Session('secret'))
        self.assertIsNone(probe._NoRedirect().redirect_request(
            None, None, 302, '', {}, 'https://elsewhere.test'))

    def test_oversize_secret_input_is_not_echoed(self):
        with self.assertRaisesRegex(probe.PreflightError, '^payload_too_large$'):
            probe.decode(b'sensitive' * probe.MAX_BYTES)


if __name__ == '__main__':
    unittest.main()
