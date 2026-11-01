import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/web_search_diagnostics_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late Database database;
  late WebSearchDiagnosticsService service;
  var current = true;

  setUp(() async {
    current = true;
    database = await databaseFactoryMemory.openDatabase('search-diagnostics');
    service = WebSearchDiagnosticsService(
      database: database,
      isCurrent: () => current,
      now: () => DateTime.utc(2026, 10, 15, 5),
    );
  });
  tearDown(() async {
    await service.deactivateAndDrain();
    await database.close();
    await databaseFactoryMemory.deleteDatabase('search-diagnostics');
  });

  test(
    'persists only bounded transport evidence, never query or page data',
    () async {
      service.record('webSearch', {
        'query': 'private query marker',
        'status': 'ok',
        'networkRegion': 'china_mainland',
        'regionSource': 'authorized_location',
        'sourceSelection': 'alternate',
        'headers': {'Authorization': 'private credential marker'},
        'latitude': 31.23456,
        'results': [
          {
            'url': 'https://example.com/private',
            'snippet': 'private content marker',
          },
        ],
        'attempts': [
          {
            'source': 'duckduckgo',
            'sourceHost': 'html.duckduckgo.com',
            'httpStatus': 200,
            'elapsedMs': 325,
            'timeoutMs': 8000,
            'status': 'ok',
            'query': 'private attempt marker',
          },
        ],
      });
      final records = await service.recent();
      final stored = jsonEncode(records);
      expect(stored, isNot(contains('private')));
      expect(stored, isNot(contains('31.23456')));
      expect(stored, isNot(contains('Authorization')));
      final first = records.single as Map;
      expect(first['atUtc'], '2026-10-15T05:00:00.000Z');
      expect(first['resultCount'], 1);
      expect(first['sourceSelection'], 'alternate');
      expect((first['attempts'] as List).single, {
        'source': 'duckduckgo',
        'sourceHost': 'html.duckduckgo.com',
        'httpStatus': 200,
        'elapsedMs': 325,
        'timeoutMs': 8000,
        'status': 'ok',
      });
    },
  );

  test('page diagnostics preserve DNS and body failure stages', () async {
    for (final stage in ['dns', 'response_body']) {
      service.record('readPage', {
        'status': 'failed',
        'source': 'public_page',
        'sourceHost': 'example.com',
        'failureStage': stage,
        'error': stage == 'dns' ? 'non_public_address' : 'timeout',
        'elapsedMs': 8000,
        'httpStatus': 200,
        'url': 'https://example.com/private',
        'text': 'private page content',
      });
    }
    final records = await service.recent();
    expect(records, hasLength(2));
    expect(jsonEncode(records), isNot(contains('private')));
    expect(
      ((records.first as Map)['attempts'] as List).single['failureStage'],
      'dns',
    );
    expect(
      ((records.last as Map)['attempts'] as List).single['error'],
      'timeout',
    );
  });

  test('keeps only newest twenty records and at most three attempts', () async {
    for (var i = 0; i < 27; i++) {
      service.record('webSearch', {
        'status': 'ok',
        'attempts': List.generate(8, (_) => {'status': 'ok', 'elapsedMs': i}),
      });
    }
    final records = await service.recent();
    expect(records, hasLength(20));
    final attempts = (records.first as Map)['attempts'] as List;
    expect(attempts, hasLength(3));
    expect((attempts.first as Map)['elapsedMs'], 7);
  });

  test('unknown fields and hostile diagnostic values are redacted', () async {
    service.record('readPage', {
      'status': 'private status marker',
      'sourceHost': 'example.com/path?private=1',
      'error': 'Bearer private token',
      'failureStage': 'response_headers',
      'httpStatus': 900,
      'elapsedMs': -1,
      'timeoutMs': 999999999,
    });
    final records = await service.recent();
    final stored = jsonEncode(records);
    expect(stored, isNot(contains('private')));
    final attempt = ((records.single as Map)['attempts'] as List).single as Map;
    expect(attempt['error'], 'unknown');
    expect(attempt['elapsedMs'], 0);
    expect(attempt['timeoutMs'], 600000);
    expect(attempt.containsKey('sourceHost'), isFalse);
    expect(attempt.containsKey('httpStatus'), isFalse);
  });

  test(
    'retirement drops queued observations and never borrows a new account',
    () async {
      service.record('webSearch', {'status': 'failed'});
      current = false;
      await service.deactivateAndDrain();
      final stored = await StoreRef<String, List<Object?>>(
        'web_search_diagnostics.v1',
      ).record('recent').get(database);
      expect(stored, isNull);
      final replacement = WebSearchDiagnosticsService(
        database: database,
        isCurrent: () => true,
      );
      replacement.record('readPage', {'status': 'ok'});
      service.record('webSearch', {'status': 'failed'});
      expect(await replacement.recent(), hasLength(1));
      await replacement.deactivateAndDrain();
    },
  );

  test(
    'unknown operations and unavailable account supplier are harmless',
    () async {
      service.record('untrusted-operation', {'status': 'ok'});
      expect(await service.recent(), isEmpty);
      final stale = WebSearchDiagnosticsService(
        database: database,
        isCurrent: () => throw StateError('retired'),
      );
      expect(
        () => stale.record('webSearch', {'status': 'ok'}),
        returnsNormally,
      );
      expect(await stale.recent(), isEmpty);
      await stale.deactivateAndDrain();
    },
  );
}
