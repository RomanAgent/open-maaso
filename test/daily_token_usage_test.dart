import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/metered_llm_http_client.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/openai_provider.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/identity/presentation/daily_token_usage_card.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse Function(http.BaseRequest) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 12, 9);
  const usage = ReportedTokenUsage(input: 100, output: 40, total: 140);

  test('actual on-disk ledger survives database close and reopening', () async {
    final folder = await Directory.systemTemp.createTemp('maaso-token-ledger-');
    addTearDown(() => folder.delete(recursive: true));
    final path = '${folder.path}/usage.db';
    final db = await databaseFactoryIo.openDatabase(path);
    final first = await DailyTokenUsageService(
      database: db,
      accountScopeDigest: 'account',
      isCurrent: () => true,
      now: () => day,
    ).init(observeLifecycle: false);
    await first.record(requestId: 'persisted', dispatchedAt: day, usage: usage);
    await first.shutdown();
    await db.close();
    final reopened = await databaseFactoryIo.openDatabase(path);
    final restored = await DailyTokenUsageService(
      database: reopened,
      accountScopeDigest: 'account',
      isCurrent: () => true,
      now: () => day,
    ).init(observeLifecycle: false);
    expect(restored.today.value.total, 140);
    await restored.record(
      requestId: 'persisted',
      dispatchedAt: day,
      usage: usage,
    );
    expect(restored.today.value.total, 140);
    await restored.shutdown();
    await reopened.close();
  });

  test(
    'pre-publication mount loads; late old-account response cannot write new generation',
    () async {
      final db = await databaseFactoryMemory.openDatabase('mount-ledger');
      addTearDown(db.close);
      final scopes = AccountStorageScopeService();
      final oldMount = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'a'),
      );
      final reply = Completer<http.Response>();
      final old = await DailyTokenUsageService(
        database: db,
        accountScopeDigest: oldMount.scope.accountDigest,
        isCurrent: () => scopes.isCurrent(oldMount),
        now: () => day,
        clientFactory: () => MockClient((_) => reply.future),
      ).init(observeLifecycle: false);
      expect(old.loading.value, isFalse);
      expect(old.isCurrent, isTrue);
      final client = old.createClient();
      final inFlight = client.get(Uri.parse('https://example.test'));
      await Future<void>.delayed(Duration.zero);
      scopes.unmount(oldMount);
      final nextMount = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'b'),
      );
      final next = await DailyTokenUsageService(
        database: db,
        accountScopeDigest: nextMount.scope.accountDigest,
        isCurrent: () => scopes.isCurrent(nextMount),
        now: () => day,
      ).init(observeLifecycle: false);
      reply.complete(
        http.Response(
          '{"usage":{"prompt_tokens":100,"completion_tokens":40,"total_tokens":140}}',
          200,
        ),
      );
      await inFlight;
      await next.refresh();
      expect(next.today.value.total, 0);
      expect(next.today.value.reportedRequests, 0);
      await expectLater(
        client.get(Uri.parse('https://example.test')),
        throwsStateError,
      );
      await old.shutdown();
      await next.shutdown();
    },
  );

  test(
    'real cloud health probe contributes usage without changing its request strategy',
    () async {
      await appServices.reset();
      SharedPreferences.setMockInitialValues({});
      final db = await databaseFactoryMemory.openDatabase('health-ledger');
      addTearDown(db.close);
      Map? requestBody;
      final ledger = await DailyTokenUsageService(
        database: db,
        accountScopeDigest: 'account',
        isCurrent: () => true,
        now: () => day,
        clientFactory: () => MockClient((request) async {
          requestBody = jsonDecode(request.body) as Map;
          return http.Response(
            '{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}',
            200,
          );
        }),
      ).init(observeLifecycle: false);
      appServices.put(ledger);
      final health = CloudLLMHealthService();
      final session = health.activateAccount(accountScopeKey: 'test-account');
      await health.checkNow(
        session: session,
        config: const CloudLLMHealthProbeConfig(
          enabled: true,
          apiKey: 'test-only',
          baseUrl: 'https://example.test/v1',
          model: 'test',
        ),
      );
      await ledger.whenSettled;
      expect(ledger.today.value.total, 11);
      expect(requestBody!['max_tokens'], 3);
      expect(health.health.value.status, CloudLLMStatus.available);
      await health.deactivateAccountAndDrain(session: session);
      await ledger.shutdown();
      await appServices.reset();
    },
  );

  test(
    'provider totals include reasoning and cache once; malformed counts are unknown',
    () {
      final actual = ReportedTokenUsage.fromPayload({
        'usage': {
          'prompt_tokens': 100,
          'completion_tokens': 40,
          'total_tokens': 140,
          'prompt_tokens_details': {'cached_tokens': 70},
          'completion_tokens_details': {'reasoning_tokens': 20},
        },
      })!;
      expect([actual.input, actual.output, actual.total], [100, 40, 140]);
      final gemini = ReportedTokenUsage.fromPayload({
        'usageMetadata': {
          'promptTokenCount': 100,
          'candidatesTokenCount': 20,
          'thoughtsTokenCount': 20,
          'totalTokenCount': 140,
          'cachedContentTokenCount': 70,
        },
      })!;
      expect([gemini.input, gemini.output, gemini.total], [100, 40, 140]);
      expect(
        ReportedTokenUsage.fromPayload({
          'usageMetadata': {
            'promptTokenCount': 100,
            'candidatesTokenCount': 20,
            'totalTokenCount': 105,
          },
        }),
        isNull,
      );
      expect(
        ReportedTokenUsage.fromPayload({
          'usage': {'total_tokens': 17},
        })!.input,
        isNull,
      );
      for (final bad in [
        null,
        {'prompt_tokens': -1, 'completion_tokens': 2, 'total_tokens': 1},
        {'prompt_tokens': 100, 'completion_tokens': 40, 'total_tokens': 100},
        {'prompt_tokens': '100', 'completion_tokens': 40, 'total_tokens': 140},
        {'prompt_tokens': 1.5, 'completion_tokens': 40},
      ]) {
        expect(ReportedTokenUsage.fromPayload({'usage': bad}), isNull);
      }
    },
  );

  test(
    'daily totals survive restart, deduplicate, isolate accounts and reset at midnight',
    () async {
      final db = await databaseFactoryMemory.openDatabase('daily-usage');
      addTearDown(db.close);
      var now = day;
      var current = true;
      DailyTokenUsageService service(String owner) => DailyTokenUsageService(
        database: db,
        accountScopeDigest: owner,
        isCurrent: () => current,
        now: () => now,
      );
      final first = await service('a').init(observeLifecycle: false);
      await Future.wait([
        first.record(requestId: 'same', dispatchedAt: day, usage: usage),
        first.record(requestId: 'same', dispatchedAt: day, usage: usage),
        first.record(requestId: 'retry', dispatchedAt: day, usage: usage),
        first.record(requestId: 'unknown', dispatchedAt: day, usage: null),
      ]);
      expect(first.today.value.total, 280);
      expect(first.today.value.reportedRequests, 2);
      expect(first.today.value.unreportedRequests, 1);
      expect(first.today.value.partial, isTrue);
      await first.shutdown();
      final restored = await service('a').init(observeLifecycle: false);
      final other = await service('b').init(observeLifecycle: false);
      expect(restored.today.value.total, 280);
      expect(other.today.value.total, 0);
      now = DateTime(2026, 10, 13, 0, 1);
      await restored.refresh();
      expect(restored.today.value.day, '2026-10-13');
      expect(restored.today.value.total, 0);
      await restored.record(
        requestId: 'cross-midnight',
        dispatchedAt: day,
        usage: usage,
      );
      expect(restored.today.value.total, 0);
      now = day;
      await restored.refresh();
      expect(restored.today.value.total, 420);
      current = false;
      await restored.record(
        requestId: 'stale',
        dispatchedAt: day,
        usage: usage,
      );
      expect(restored.today.value.total, 420);
      restored.onClose();
      other.onClose();
    },
  );

  test('estimated metadata must be absent or explicitly boolean false', () {
    const counts = {
      'prompt_tokens': 4,
      'completion_tokens': 8,
      'total_tokens': 12,
    };
    expect(ReportedTokenUsage.fromPayload({'usage': counts})!.total, 12);
    expect(
      ReportedTokenUsage.fromPayload({
        'usage': {...counts, 'estimated': false},
      })!.total,
      12,
    );
    for (final estimated in [true, 'false', 'true', 0, 1, null, {}, []]) {
      expect(
        ReportedTokenUsage.fromPayload({
          'usage': {...counts, 'estimated': estimated},
        }),
        isNull,
      );
    }
  });

  testWidgets('estimated HTTP usage remains unknown in the daily card', (
    tester,
  ) async {
    final stats = await tester.runAsync(() async {
      final db = await databaseFactoryMemory.openDatabase('estimated-http');
      final ledger = await DailyTokenUsageService(
        database: db,
        accountScopeDigest: 'account',
        isCurrent: () => true,
        now: () => day,
      ).init(observeLifecycle: false);
      final client = MeteredLlmHttpClient(
        inner: MockClient(
          (_) async => http.Response(
            '{"usage":{"prompt_tokens":4,"completion_tokens":8,"total_tokens":12,"estimated":true}}',
            200,
          ),
        ),
        record: ledger.record,
        now: () => day,
      );
      await client.get(Uri.parse('https://example.test'));
      await ledger.whenSettled;
      final stats = ledger.today.value;
      expect(stats.reportedRequests, 0);
      expect(stats.unreportedRequests, 1);
      expect(stats.total, 0);
      client.close();
      await ledger.shutdown();
      await db.close();
      return stats;
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DailyTokenUsageCard(usage: stats)),
      ),
    );
    expect(find.text('12'), findsNothing);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('This device · Usage not reported'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-daily-token-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.text('Some requests did not report usage. This is a partial total.'),
      findsOneWidget,
    );
  });

  test(
    'stream usage snapshots count once per HTTP attempt and preserve bytes',
    () async {
      final receipts = <({String id, ReportedTokenUsage? usage})>[];
      final sse =
          'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
          'data: {"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}\n\n'
          'data: {"usage":{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18}}\n\n'
          'data: [DONE]\n\n';
      final client = MeteredLlmHttpClient(
        inner: _StreamClient(
          (_) => http.StreamedResponse(
            Stream.fromIterable(utf8.encode(sse).map((b) => [b])),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async {
              receipts.add((id: requestId, usage: usage));
            },
      );
      addTearDown(client.close);
      for (var i = 0; i < 2; i++) {
        final response = await client.send(
          http.Request('POST', Uri.parse('https://example.test')),
        );
        expect(await response.stream.bytesToString(), sse);
      }
      expect(receipts.length, 2);
      expect(receipts.map((r) => r.usage!.total), [18, 18]);
      expect(receipts.first.id, isNot(receipts.last.id));
    },
  );

  for (final interruption in [
    'cancel',
    'transport error',
    'error event',
    'silent EOF',
  ]) {
    testWidgets(
      'known usage followed by $interruption remains a partial card total',
      (tester) async {
        final stats = await tester.runAsync(() async {
          final db = await databaseFactoryMemory.openDatabase(
            'partial-$interruption',
          );
          final ledger = await DailyTokenUsageService(
            database: db,
            accountScopeDigest: 'account',
            isCurrent: () => true,
            now: () => day,
          ).init(observeLifecycle: false);
          final chunks = StreamController<List<int>>();
          final transport = MeteredLlmHttpClient(
            inner: _StreamClient(
              (_) => http.StreamedResponse(
                chunks.stream,
                200,
                headers: {'content-type': 'text/event-stream'},
              ),
            ),
            record: ledger.record,
            now: () => day,
          );
          final response = await transport.send(
            http.Request('POST', Uri.parse('https://example.test')),
          );
          final delivered = Completer<void>();
          final terminalError = Completer<void>();
          final subscription = response.stream.listen(
            (_) {
              if (!delivered.isCompleted) delivered.complete();
            },
            onError: (Object _, StackTrace _) {
              if (!terminalError.isCompleted) terminalError.complete();
            },
          );
          chunks.add(
            utf8.encode(
              'data: {"usage":{"prompt_tokens":4,"completion_tokens":8,"total_tokens":12}}\n\n',
            ),
          );
          await delivered.future;
          if (interruption == 'transport error') {
            chunks.addError(StateError('interrupted'));
            await terminalError.future;
          } else if (interruption == 'error event') {
            chunks.add(
              utf8.encode('event:error\ndata: {"code":"provider_failed"}\n\n'),
            );
            await Future<void>.delayed(Duration.zero);
          }
          if (interruption == 'error event' || interruption == 'silent EOF') {
            final done = subscription.asFuture<void>();
            await chunks.close();
            await done;
          } else {
            await subscription.cancel();
            await chunks.close();
          }
          await ledger.whenSettled;
          await ledger.refresh();
          final stats = ledger.today.value;
          expect(stats.total, 12);
          expect(stats.incompleteRequests, 1);
          expect(stats.partial, isTrue);
          transport.close();
          await ledger.shutdown();
          await db.close();
          return stats;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DailyTokenUsageCard(usage: stats)),
          ),
        );
        expect(find.text('12'), findsOneWidget);
        expect(find.text('This device · Partial total'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('profile-daily-token-toggle')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Some requests ended before usage was finalized. This is a partial total.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('SSE DONE and complete JSON body finalize known usage once', () async {
    for (final sse in [true, false]) {
      final reports = <ReportedTokenUsage?>[];
      final client = MeteredLlmHttpClient(
        inner: _StreamClient(
          (_) => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                sse
                    ? 'data: {"usage":{"prompt_tokens":4,"completion_tokens":8,"total_tokens":12}}\n\ndata: [DONE]\n\n'
                    : '{"usage":{"prompt_tokens":4,"completion_tokens":8,"total_tokens":12}}',
              ),
            ),
            200,
            headers: {
              'content-type': sse ? 'text/event-stream' : 'application/json',
            },
          ),
        ),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async {
              reports.add(usage);
            },
      );
      final response = await client.get(Uri.parse('https://example.test'));
      expect(response.statusCode, 200);
      expect(reports.length, 1);
      expect(reports.single!.incomplete, isFalse);
      client.close();
    }
  });

  test(
    'unknown response, stream errors and cancellation never fabricate usage',
    () async {
      final receipts = <ReportedTokenUsage?>[];
      final chunks = StreamController<List<int>>();
      final client = MeteredLlmHttpClient(
        inner: _StreamClient(
          (_) => http.StreamedResponse(
            chunks.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async {
              receipts.add(usage);
            },
      );
      final response = await client.send(
        http.Request('POST', Uri.parse('https://example.test')),
      );
      final subscription = response.stream.listen((_) {});
      chunks.add(utf8.encode('data: {"choices":[]}\n\n'));
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(receipts, [null]);
      await chunks.close();
      client.close();
      final broken = MeteredLlmHttpClient(
        inner: _StreamClient(
          (_) => http.StreamedResponse(Stream.error(StateError('broken')), 200),
        ),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async {
              receipts.add(usage);
            },
      );
      final failed = await broken.send(
        http.Request('POST', Uri.parse('https://example.test')),
      );
      await expectLater(failed.stream.toList(), throwsStateError);
      expect(receipts, [null, null]);
      broken.close();
    },
  );

  test(
    'telemetry failures cannot retry or fail a valid model response',
    () async {
      var calls = 0;
      final client = MeteredLlmHttpClient(
        inner: MockClient((_) async {
          calls++;
          return http.Response(
            '{"usage":{"prompt_tokens":2,"completion_tokens":3}}',
            200,
          );
        }),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async => throw StateError('disk'),
      );
      final response = await client.get(Uri.parse('https://example.test'));
      expect(response.statusCode, 200);
      expect(calls, 1);
      client.close();
    },
  );

  test('a waiting telemetry write never blocks response completion', () async {
    final held = Completer<void>();
    final client = MeteredLlmHttpClient(
      inner: MockClient(
        (_) async => http.Response(
          '{"usage":{"prompt_tokens":2,"completion_tokens":3}}',
          200,
        ),
      ),
      record: ({required requestId, required dispatchedAt, required usage}) =>
          held.future,
    );
    final response = await client
        .get(Uri.parse('https://example.test'))
        .timeout(const Duration(seconds: 1));
    expect(response.statusCode, 200);
    held.complete();
    client.close();
  });

  test(
    'OpenAI chat, tools and streamed source share actual usage observer',
    () async {
      final reports = <ReportedTokenUsage?>[];
      final transport = MeteredLlmHttpClient(
        inner: MockClient((request) async {
          expect(request.headers.containsKey('X-Maaso-Usage'), isFalse);
          final payload = jsonDecode(request.body) as Map;
          const u =
              '{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18}';
          if (payload['stream'] == true) {
            return http.Response(
              'data: {"choices":[{"delta":{"content":"code"}}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: {"choices":[],"usage":$u}\n\ndata: [DONE]\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.Response(
            '{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}],"usage":$u}',
            200,
          );
        }),
        record:
            ({
              required requestId,
              required dispatchedAt,
              required usage,
            }) async {
              reports.add(usage);
            },
      );
      addTearDown(transport.close);
      final provider = OpenAIProvider(
        apiKey: 'test-only',
        baseUrl: 'https://example.test/v1',
        httpClient: transport,
      );
      final messages = [Message.user('hello')];
      expect(await provider.chat(messages), 'hi');
      expect((await provider.chatWithTools(messages, [])).content, 'hi');
      expect((await provider.streamChat(messages).toList()).join(), 'code');
      expect(
        (await provider.generateProjectSource(messages)).visibleText,
        'code',
      );
      expect(reports.length, 4);
      expect(reports.every((usage) => usage?.total == 18), isTrue);
    },
  );

  for (final mode in ['chat', 'json', 'source', 'presentation']) {
    test(
      'Maaso proxy $mode consumes usage without protocol/action authority',
      () async {
        final reports = <ReportedTokenUsage?>[];
        final transport = MeteredLlmHttpClient(
          inner: MockClient((request) async {
            expect(request.headers['X-Maaso-Usage'], 'provider-v1');
            return http.Response(
              'event: reply.delta\ndata: {"delta":"hi"}\n\nevent: usage\ndata: {"usage":{"prompt_tokens":10,"completion_tokens":8,"total_tokens":18}}\n\n'
              '${mode == 'json' || mode == 'source' ? 'event: completion\ndata: {"finishReason":"stop","status":"complete"}\n\n' : ''}'
              'event: done\ndata: [DONE]\n\n',
              200,
              headers: {
                'content-type': 'text/event-stream',
                'x-maaso-output-format': 'json_object',
                'x-maaso-generation-mode': 'project_source',
              },
            );
          }),
          record:
              ({
                required requestId,
                required dispatchedAt,
                required usage,
              }) async {
                reports.add(usage);
              },
        );
        addTearDown(transport.close);
        final client = MaasoThinProxyLLMClient(
          baseUri: Uri.parse('https://example.test'),
          model: 'test',
          accessTokenProvider: () async => 'test-only',
          httpClient: transport,
        );
        final messages = [Message.user('hello')];
        if (mode == 'json') {
          expect(await client.chatJsonObject(messages), 'hi');
        } else if (mode == 'source') {
          expect(
            (await client.generateProjectSource(messages)).visibleText,
            'hi',
          );
        } else if (mode == 'presentation') {
          final events = await client
              .streamPresentationChatEvents(messages)
              .toList();
          expect(events.map((e) => e.event), ['reply.delta', 'done']);
        } else {
          expect(await client.chat(messages), 'hi');
        }
        expect(reports.length, 1);
        expect(reports.single!.total, 18);
      },
    );
  }

  testWidgets(
    'usage disclosure is keyboard accessible and reports interaction',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var interactions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DailyTokenUsageCard(
              usage: const DailyTokenUsage(
                day: '2026-10-12',
                input: 100,
                output: 40,
                total: 140,
                reportedRequests: 1,
              ),
              onInteraction: () => interactions++,
            ),
          ),
        ),
      );
      final toggle = find.byKey(const ValueKey('profile-daily-token-toggle'));
      final details = find.byKey(const ValueKey('profile-daily-token-details'));
      expect(find.text('140'), findsOneWidget);
      expect(find.text('This device · Reported total'), findsOneWidget);
      expect(details, findsNothing);
      expect(find.text('Input  100'), findsNothing);
      expect(
        tester.getSemantics(toggle).flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(interactions, 1);
      expect(details, findsOneWidget);
      expect(find.text('Input  100'), findsOneWidget);
      expect(find.text('Output  40'), findsOneWidget);
      expect(
        tester.getSemantics(toggle).flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(interactions, 2);
      expect(details, findsNothing);
      expect(find.text('140'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('a confirmed empty day shows zero without an unknown warning', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(usage: DailyTokenUsage(day: '2026-10-12')),
        ),
      ),
    );
    expect(find.text('0'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('This device · Reported total'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-daily-token-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Input  0'), findsOneWidget);
    expect(find.text('Output  0'), findsOneWidget);
  });

  for (final partial in [
    (
      'unreported request',
      const DailyTokenUsage(
        day: '2026-10-12',
        input: 100,
        output: 40,
        total: 140,
        reportedRequests: 1,
        unreportedRequests: 1,
      ),
      '100',
      '40',
    ),
    (
      'missing input',
      const DailyTokenUsage(
        day: '2026-10-12',
        output: 40,
        total: 140,
        reportedRequests: 1,
        missingInput: 1,
      ),
      '—',
      '40',
    ),
    (
      'missing output',
      const DailyTokenUsage(
        day: '2026-10-12',
        input: 100,
        total: 140,
        reportedRequests: 1,
        missingOutput: 1,
      ),
      '100',
      '—',
    ),
  ]) {
    testWidgets('collapsed ${partial.$1} keeps partial warning visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DailyTokenUsageCard(usage: partial.$2)),
        ),
      );
      expect(find.text('140'), findsOneWidget);
      expect(find.text('This device · Partial total'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-daily-token-details')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Input  ${partial.$3}'), findsOneWidget);
      expect(find.text('Output  ${partial.$4}'), findsOneWidget);
      expect(find.text('140'), findsOneWidget);
    });
  }

  for (final state in ['loading', 'unavailable', 'absent']) {
    testWidgets('$state never retains old totals or details', (tester) async {
      const stats = DailyTokenUsage(
        day: '2026-10-12',
        input: 100,
        output: 40,
        total: 140,
        reportedRequests: 1,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: DailyTokenUsageCard(usage: stats)),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Input  100'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DailyTokenUsageCard(
              usage: state == 'absent' ? null : stats,
              loading: state == 'loading',
              unavailable: state == 'unavailable',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('140'), findsNothing);
      expect(find.text('Input  100'), findsNothing);
      expect(find.text('Output  40'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(
        find.text(
          state == 'loading'
              ? 'This device · Loading…'
              : 'This device · Unavailable',
        ),
        findsOneWidget,
      );
      if (state != 'loading') {
        expect(
          find.byKey(const ValueKey('profile-daily-token-details')),
          findsNothing,
        );
      }
    });
  }

  testWidgets('disabled disclosure closes and cannot invoke interaction', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const stats = DailyTokenUsage(day: '2026-10-12');
    var interactions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(
            usage: stats,
            onInteraction: () => interactions++,
          ),
        ),
      ),
    );
    final toggle = find.byKey(const ValueKey('profile-daily-token-toggle'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(interactions, 1);
    expect(
      find.byKey(const ValueKey('profile-daily-token-details')),
      findsOneWidget,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(
            usage: stats,
            enabled: false,
            onInteraction: () => interactions++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile-daily-token-details')),
      findsNothing,
    );
    expect(
      tester.getSemantics(toggle).flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    await tester.tap(toggle);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(interactions, 1);
    semantics.dispose();
  });

  testWidgets('a new day starts collapsed with the new daily total', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(
            usage: DailyTokenUsage(
              day: '2026-10-12',
              input: 100,
              output: 40,
              total: 140,
              reportedRequests: 1,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('profile-daily-token-toggle')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(usage: DailyTokenUsage(day: '2026-10-13')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(find.text('140'), findsNothing);
    expect(
      find.byKey(const ValueKey('profile-daily-token-details')),
      findsNothing,
    );
  });

  for (final layout in [
    (320.0, Brightness.light),
    (320.0, Brightness.dark),
    (680.0, Brightness.light),
  ]) {
    testWidgets('daily token card fits $layout and large text', (tester) async {
      tester.view.physicalSize = Size(layout.$1, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: layout.$2),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: DailyTokenUsageCard(
                usage: DailyTokenUsage(
                  day: '2026-10-12',
                  input: 12345,
                  output: 6789,
                  total: 19134,
                  reportedRequests: 2,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('19,134'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('profile-daily-token-details')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('profile-daily-token-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Input  12,345'), findsOneWidget);
      expect(find.text('Output  6,789'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('unreported requests show unknown rather than zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DailyTokenUsageCard(
            usage: DailyTokenUsage(day: '2026-10-12', unreportedRequests: 1),
          ),
        ),
      ),
    );
    expect(find.text('—'), findsOneWidget);
    expect(find.text('This device · Usage not reported'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-daily-token-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Input  —'), findsOneWidget);
    expect(
      find.text('Some requests did not report usage. This is a partial total.'),
      findsOneWidget,
    );
  });
}
