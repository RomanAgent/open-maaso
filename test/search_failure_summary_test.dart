import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/intent/search_failure_summary.dart';

String receipt(Map<String, Object?> data) =>
    'skill.call skill_websearch_websearch => ${jsonEncode(data)}';

void main() {
  for (final locale in [AppLocale.zh, AppLocale.en]) {
    test('only actual timeouts can produce a timeout explanation: $locale', () {
      final message = searchFailureSummary([
        receipt({
          'status': 'failed',
          'error': 'search_failed',
          'results': [],
          'attempts': [
            {'source': 'duckduckgo', 'error': 'timeout'},
            {'source': 'bing_rss', 'error': 'timeout'},
          ],
        }),
      ], locale)!;
      expect(message, contains(locale == AppLocale.zh ? '超时' : 'timed out'));
    });
    test('challenge and HTTP failure cannot become timeout: $locale', () {
      final message = searchFailureSummary([
        receipt({
          'status': 'failed',
          'error': 'search_failed',
          'results': [],
          'attempts': [
            {'source': 'duckduckgo', 'error': 'challenge', 'httpStatus': 202},
            {'source': 'bing_rss', 'error': 'http_error', 'httpStatus': 503},
          ],
        }),
      ], locale)!;
      expect(message, isNot(contains('超时')));
      expect(message, isNot(contains('timed out')));
      expect(message, contains(locale == AppLocale.zh ? '验证' : 'verification'));
    });
    test('empty completed lookup is reported as no result: $locale', () {
      final message = searchFailureSummary([
        receipt({'status': 'no_results', 'results': [], 'note': 'no_results'}),
      ], locale)!;
      expect(message, contains(locale == AppLocale.zh ? '没有找到' : 'no results'));
      expect(message, isNot(contains('超时')));
      expect(message, isNot(contains('timed out')));
    });
  }
  test('a usable result preserves the model answer path', () {
    expect(
      searchFailureSummary([
        receipt({'status': 'failed', 'error': 'search_failed', 'results': []}),
        receipt({
          'status': 'ok',
          'results': [
            {'title': 'Actual source'},
          ],
        }),
      ], AppLocale.en),
      isNull,
    );
  });
  test('malformed and unrelated receipts cannot assert network failure', () {
    for (final value in [
      'skill.call skill_todo_add => {"error":"timeout"}',
      'skill.call skill_websearch_imagesearch => {"error":"image_search_failed"}',
      'skill.call skill_websearch_websearch => not json',
    ]) {
      expect(searchFailureSummary([value], AppLocale.zh), isNull);
    }
  });
}
