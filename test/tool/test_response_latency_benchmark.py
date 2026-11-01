import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('response_bench', ROOT / 'tool/response_latency/benchmark.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class ResponseLatencyBenchmarkTest(unittest.TestCase):
    def plan(self):
        value = bench.make_plan()
        value['conditions'] = {key: 'fixed' for key in bench.CONDITIONS}
        value['conditions']['providerEnvironment'] = 'isolated_test'
        return value

    def rows(self, plan, value):
        return [{'schemaVersion': 1, 'caseId': row['id'], 'cohortId': row['cohortId'],
                 'fixtureSha256': row['fixtureSha256'], 'source': 'isolated_device_probe',
                 'sourceRevision': ('a' if value >= 1000 else 'b') * 40, 'conditions': plan['conditions'],
                 'outcome': 'completed', 'quality': 'passed', 'responseKind': 'answer',
                 'measurements': {'firstVisibleMs': value, 'completedMs': value * 2},
                 'boundaries': bench.REQUIRED_BOUNDARIES} for row in plan['cases']]

    def test_plan_is_deterministic_and_has_100_per_primary_path(self):
        plan = self.plan()
        self.assertEqual(len(plan['cases']), 500)
        self.assertEqual(bench.make_plan(), bench.make_plan())
        self.assertTrue(plan['requiredExecution']['productionSessionForbidden'])
        self.assertEqual(len({row['id'] for row in plan['cases']}), 500)

    def test_paired_complete_evidence_can_pass_without_averaging_cohorts(self):
        plan = self.plan()
        result = bench.compare(plan, self.rows(plan, 1000), self.rows(plan, 650))
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(len(result['comparisons']), 5)

    def test_missing_duplicates_and_surrogate_boundaries_remain_incomplete(self):
        plan = self.plan()
        rows = self.rows(plan, 600)
        rows[0]['boundaries'] = {'firstVisibleMs': 'published', 'completedMs': 'goal_terminal'}
        result = bench.compare(plan, self.rows(plan, 1000), rows[1:] + [rows[2]])
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(result['candidate']['duplicateCases'], 1)
        self.assertEqual(bench.compare(plan, self.rows(plan, 1000), rows)['status'], 'incomplete')

    def test_acknowledgement_and_unreviewed_quality_do_not_qualify(self):
        plan = self.plan()
        for field, value in [('responseKind', 'acknowledgement'), ('quality', 'unreviewed')]:
            rows = self.rows(plan, 500)
            rows[0][field] = value
            self.assertEqual(bench.compare(plan, self.rows(plan, 1000), rows)['status'], 'incomplete')

    def test_failure_or_quality_regression_cannot_be_hidden_by_fast_success(self):
        plan = self.plan()
        rows = self.rows(plan, 500)
        rows[0]['outcome'] = 'failed'
        result = bench.compare(plan, self.rows(plan, 1000), rows)
        self.assertIn('ordinary_short.zh.text.warm.stable:failure_rate_increased', result['failedReasons'])
        rows = self.rows(plan, 500)
        rows[0]['quality'] = 'failed'
        self.assertEqual(bench.compare(plan, self.rows(plan, 1000), rows)['status'], 'failed')

    def test_cancellation_or_zero_baseline_cannot_manufacture_speedup(self):
        plan = self.plan()
        rows = self.rows(plan, 500)
        rows[0]['outcome'] = 'cancelled'
        result = bench.compare(plan, self.rows(plan, 1000), rows)
        self.assertIn('ordinary_short.zh.text.warm.stable:cancellation_rate_increased', result['failedReasons'])
        self.assertEqual(bench.compare(plan, self.rows(plan, 0), self.rows(plan, 0))['status'], 'incomplete')

    def test_manifest_cannot_inject_arbitrary_cohort_or_fixture_text_into_report(self):
        plan = self.plan()
        plan['cases'][0]['cohortId'] = 'unsafe-secret'
        with self.assertRaises(ValueError):
            bench.compare(plan, [], [])

    def test_trace_audit_never_copies_content_or_infers_visible_audio(self):
        result = bench.audit_trace([
            'secret should never be echoed',
            '[Trace outer] conversation.response.first_text turn=t1 boundary=published elapsed_us=1000',
            '[Trace wrong] conversation.response.completed turn=t1 outcome=completed elapsed_us=2000 first_text_us=1000 first_audio_us=unavailable',
        ])
        self.assertEqual(result['publishedMs']['p95'], 1)
        self.assertIsNone(result['firstVisibleMs'])
        self.assertEqual(result['playbackHandleStartedMs']['samples'], 0)
        self.assertNotIn('secret', str(result))
        self.assertEqual(result['status'], 'incomplete')

    def test_nonisolated_or_unknown_receipt_fields_never_qualify(self):
        plan = self.plan()
        rows = self.rows(plan, 500)
        rows[0]['authorization'] = 'never_export'
        result = bench.compare(plan, self.rows(plan, 1000), rows)
        self.assertEqual(result['status'], 'incomplete')
        self.assertNotIn('never_export', str(result))
        plan['conditions']['providerEnvironment'] = 'production'
        self.assertEqual(bench.compare(plan, self.rows(plan, 1000), self.rows(plan, 500))['status'], 'incomplete')


if __name__ == '__main__':
    unittest.main()
