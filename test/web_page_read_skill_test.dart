import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/core/services/web_search_diagnostics_service.dart';
import 'package:maaso/src/features/agent/application/skills/web_search_skill.dart';
import 'package:sembast/sembast_memory.dart';

const _page = '''<!doctype html><html><head><title>Observed conditions</title>
<script>secret_script()</script></head><body><nav>Menu only</nav>
<main><h1>Current observation</h1><p>Temperature: 28°C.</p>
<p>Observed at 14:30 UTC; source date 2026-10-15.</p></main>
<footer>Footer only</footer></body></html>''';

http.Response _html(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

Future<Map<String, dynamic>> _read(
  WebSearchSkill skill,
  List<dynamic> args,
) async =>
    jsonDecode(await skill.methods['readPage']!(args) as String)
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'readPage returns full public text through the real Skill handler',
    () async {
      var requests = 0;
      final skill = WebSearchSkill(
        networkRegionProvider: () => const NetworkRegionResolution(
          region: NetworkRegion.mainlandChina,
          source: NetworkRegionSource.authorizedLocation,
        ),
        now: () => DateTime.utc(2026, 10, 15, 6),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.toString(), 'https://example.org/conditions');
          expect(request.followRedirects, isFalse);
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains(anyOf('cookie', 'authorization'))),
          );
          return _html(_page);
        }),
      );
      final result = await _read(skill, [
        {'url': 'https://example.org/conditions'},
      ]);
      expect(requests, 1);
      expect(result['status'], 'ok');
      expect(result['source'], 'public_page');
      expect(result['sourceHost'], 'example.org');
      expect(result['networkRegion'], 'china_mainland');
      expect(result['regionSource'], 'authorized_location');
      expect(result['title'], 'Observed conditions');
      expect(result['text'], contains('Temperature: 28°C.'));
      expect(result['text'], contains('14:30 UTC'));
      expect(result['text'], isNot(contains('secret_script')));
      expect(result['text'], isNot(contains('Menu only')));
      expect(result['text'], isNot(contains('Footer only')));
      expect(result['fetchedAtUtc'], '2026-10-15T06:00:00.000Z');
      expect(result['truncated'], isFalse);
      expect(result['elapsedMs'], greaterThanOrEqualTo(0));
    },
  );

  for (final args in [
    ['https://example.org/long', 256],
    [
      jsonEncode({'url': 'https://example.org/long', 'maxChars': 256}),
    ],
    [
      {'url': 'https://example.org/long', 'maxChars': 0},
    ],
  ]) {
    test(
      'URL and structured argument forms keep bounded page text: $args',
      () async {
        final skill = WebSearchSkill(
          httpClient: MockClient(
            (_) async => _html('<main>${'x' * 2000}</main>'),
          ),
        );
        final result = await _read(skill, args);
        expect(result['status'], 'ok');
        expect(result['text'].length, lessThanOrEqualTo(256));
        expect(result['text'], isNotEmpty);
        expect(result['truncated'], isTrue);
      },
    );
  }

  test('maxChars cannot exceed the reader upper limit', () async {
    final skill = WebSearchSkill(
      httpClient: MockClient((_) async => _html('<main>${'x' * 25000}</main>')),
    );
    final result = await _read(skill, [
      {'url': 'https://example.org/long', 'maxChars': 999999},
    ]);
    expect(result['status'], 'ok');
    expect(result['text'].length, lessThanOrEqualTo(20000));
    expect(result['truncated'], isTrue);
  });

  for (final url in [
    'http://example.org/plain',
    'https://localhost/private',
    'https://127.0.0.1/private',
    'https://user:secret@example.org/private',
  ]) {
    test(
      'readPage cannot access unsafe targets through Skill argument parsing: $url',
      () async {
        final skill = WebSearchSkill(
          httpClient: MockClient(
            (_) async => fail('unsafe target must not send'),
          ),
        );
        final result = await _read(skill, [url]);
        expect(result['status'], 'failed');
        expect(result['failureStage'], 'url');
        expect(result['error'], isNot('timeout'));
        expect(result.toString(), isNot(contains('secret')));
      },
    );
  }

  test('missing page URLs do not send requests', () async {
    final skill = WebSearchSkill(
      httpClient: MockClient((_) async => fail('missing URL must not send')),
    );
    expect((await _read(skill, []))['error'], 'missing_url');
    expect((await _read(skill, [' ']))['error'], 'empty_url');
    expect(
      (await _read(skill, [
        {'maxChars': 256},
      ]))['error'],
      'empty_url',
    );
  });

  test('readPage receipt keeps HTTP errors distinct from timeouts', () async {
    final skill = WebSearchSkill(
      httpClient: MockClient((_) async => http.Response('Unavailable', 503)),
    );
    final result = await _read(skill, ['https://example.org/current']);
    expect(result['status'], 'failed');
    expect(result['error'], 'http_error');
    expect(result['httpStatus'], 503);
    expect(result['failureStage'], 'response_headers');
  });

  test(
    'page read body timeout aborts the request and retains its stage',
    () async {
      final aborts = <Future<void>>[];
      final skill = WebSearchSkill(
        searchTimeout: const Duration(milliseconds: 10),
        httpClient: MockClient.streaming((request, _) async {
          aborts.add((request as http.AbortableRequest).abortTrigger!);
          return http.StreamedResponse(
            (() async* {
              yield utf8.encode('<main>');
              await Future<void>.delayed(const Duration(milliseconds: 40));
              yield utf8.encode('late</main>');
            })(),
            200,
            headers: {'content-type': 'text/html'},
          );
        }),
      );
      final result = await _read(skill, ['https://example.org/current']);
      expect(result['status'], 'failed');
      expect(result['error'], 'timeout');
      expect(result['failureStage'], 'response_body');
      expect(result['httpStatus'], 200);
      await Future.wait(aborts);
    },
  );

  test(
    'search and page receipts use pinned account diagnostics without storing body or query',
    () async {
      final oldDb = await databaseFactoryMemory.openDatabase(
        'old-search-diagnostic',
      );
      final newDb = await databaseFactoryMemory.openDatabase(
        'new-search-diagnostic',
      );
      final oldOwner = WebSearchDiagnosticsService(
        database: oldDb,
        isCurrent: () => true,
      );
      final newOwner = WebSearchDiagnosticsService(
        database: newDb,
        isCurrent: () => true,
      );
      appServices.put<WebSearchDiagnosticsService>(oldOwner);
      addTearDown(() async {
        await appServices.delete<WebSearchDiagnosticsService>(force: true);
        await oldOwner.deactivateAndDrain();
        await newOwner.deactivateAndDrain();
        await oldDb.close();
        await newDb.close();
      });
      final skill = WebSearchSkill(
        httpClient: MockClient(
          (request) async => request.url.host == 'example.org'
              ? _html(_page)
              : http.Response(
                  '<div class="result"><a class="result__a" href="https://example.org/current">Current</a><div class="result__snippet">secret query answer</div></div>',
                  200,
                ),
        ),
      );
      await _read(skill, [
        'https://example.org/conditions?query=private-query',
      ]);
      await skill.methods['webSearch']!(['private-query']);
      await oldOwner.whenSettled;
      final first = await oldOwner.recent();
      expect(first, hasLength(2));
      final encoded = jsonEncode(first);
      expect(encoded, contains('readPage'));
      expect(encoded, contains('webSearch'));
      expect(encoded, isNot(contains('28°C')));
      expect(encoded, isNot(contains('private-query')));
      expect(encoded, isNot(contains('secret query answer')));
      await oldOwner.deactivateAndDrain();
      appServices.put<WebSearchDiagnosticsService>(
        newOwner,
        overrideAbstract: true,
      );
      await _read(skill, ['https://example.org/conditions']);
      await newOwner.whenSettled;
      expect(
        await newOwner.recent(),
        isEmpty,
        reason:
            'an old Skill cannot borrow the next account diagnostics service',
      );
    },
  );
}
