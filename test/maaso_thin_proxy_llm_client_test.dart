import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';

void main() {
  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    appServices.put(SecureStorageService());
  });

  tearDown(appServices.reset);

  test(
    'each provider dispatch carries a fresh server admission identity',
    () async {
      final ids = <String>{};
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test'),
        model: 'doubao-seed-evolving',
        accessTokenProvider: () async => 'synthetic-test-token',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final id = body['turnId'];
          // Mirror the server admission boundary that rejected the old client
          // before the first model token was requested.
          if (id is! String || id.trim().isEmpty) {
            return http.Response('{"code":"MODEL_REQUEST_ID_REQUIRED"}', 400);
          }
          expect(
            id,
            matches(
              RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
              ),
            ),
          );
          expect(
            ids.add(id),
            isTrue,
            reason: 'independent calls must not collide',
          );
          return http.Response(
            'event: reply.delta\ndata: {"delta":"ok"}\n\n'
            'event: done\ndata: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final messages = [Message.user('synthetic hello')];
      expect(await client.chat(messages), 'ok');
      expect(await client.chat(messages), 'ok');
      expect(await client.generateJson('synthetic JSON operation'), 'ok');
      final presentation = await client
          .streamPresentationChatEvents(messages)
          .toList();
      expect(presentation.last.isDone, isTrue);
      expect(ids, hasLength(4));
    },
  );

  test('streamChat posts to backend thin proxy with bearer token', () async {
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test'),
      model: 'doubao-seed-2-1-turbo-260628',
      accessTokenProvider: () async => 'access-token-1',
      httpClient: _StreamingClientFake((request) {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/proxy/llm/stream');
        expect(request.headers['authorization'], 'Bearer access-token-1');
        expect(request.headers['accept'], 'text/event-stream');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'doubao-seed-2-1-turbo-260628');
        expect((body['messages'] as List).last['content'], 'hello');
        expect(body['streamProtocol'], 'maaso.sse.v1');
        return Stream<List<int>>.fromIterable([
          utf8.encode('event: reply.delta\n'),
          utf8.encode('data: {"delta":"hi"}\n\n'),
          utf8.encode('event: reply.delta\n'),
          utf8.encode('data: {"delta":" there"}\n\n'),
          utf8.encode('event: done\ndata: [DONE]\n\n'),
        ]);
      }),
    );

    final chunks = await client.streamChat([Message.user('hello')]).toList();

    expect(chunks, ['hi', ' there']);
  });

  test('chat collects streamChat chunks', () async {
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'doubao-seed-2-1-pro-260628',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake((_) {
        return Stream<List<int>>.fromIterable([
          utf8.encode('event: reply.delta\ndata: {"delta":"one"}\n\n'),
          utf8.encode('event: reply.delta\ndata: {"delta":" two"}\n\n'),
          utf8.encode('event: done\ndata: [DONE]\n\n'),
        ]);
      }),
    );

    final reply = await client.chat([Message.user('go')]);

    expect(reply, 'one two');
  });

  test('streamChatEvents preserves SSE event names and payloads', () async {
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'doubao-seed-2-1-turbo-260628',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake((_) {
        return Stream<List<int>>.fromIterable([
          utf8.encode('event: reply.delta\n'),
          utf8.encode('data: {"delta":"你好"}\n\n'),
          utf8.encode('event: body.intent\n'),
          utf8.encode('data: {"mood":"playful","gesture":"small_wave"}\n\n'),
          utf8.encode('event: done\ndata: [DONE]\n\n'),
        ]);
      }),
    );

    final events = await client.streamChatEvents([Message.user('hi')]).toList();

    expect(events.map((event) => event.event), ['reply.delta', 'body.intent']);
    expect(events.first.deltaText, '你好');
    expect(events.last.jsonPayload?['gesture'], 'small_wave');
  });

  test(
    'presentation stream opts into v2 and exposes typed plus done',
    () async {
      late Map<String, dynamic> sentBody;
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test/'),
        model: 'model',
        accessTokenProvider: () async => null,
        httpClient: _StreamingClientFake((request) {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return Stream<List<int>>.value(
            utf8.encode(
              'event: reply.delta\n'
              'data: {"delta":"{\\"actions\\":[],'
              '\\"reply\\":\\"ok\\"}"}\n\n'
              'event: reply.utterance\n'
              'data: {"type":"reply.utterance","text":"ok",'
              '"after":"finish"}\n\n'
              'event: done\ndata: [DONE]\n\n',
            ),
          );
        }),
      );

      final events = await client.streamPresentationChatEvents([
        Message.user('hi'),
      ]).toList();

      expect(sentBody['streamProtocol'], 'maaso.sse.v2.presentation');
      expect(events.map((event) => event.event), [
        'reply.delta',
        'reply.utterance',
        'done',
      ]);
      expect(events.last.data, '[DONE]');
    },
  );

  test('presentation EOF without done and malformed done both fail', () async {
    for (final body in [
      'event: reply.delta\ndata: {"delta":"ok"}\n\n',
      'event: done\ndata: later\n\n',
    ]) {
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test/'),
        model: 'model',
        accessTokenProvider: () async => null,
        httpClient: _StreamingClientFake(
          (_) => Stream<List<int>>.value(utf8.encode(body)),
        ),
      );
      await expectLater(
        client.streamPresentationChatEvents([Message.user('hi')]).drain<void>(),
        throwsStateError,
        reason: body,
      );
    }
  });

  test('coalesced HTTP chunk may contain many bounded SSE events', () async {
    final payload = StringBuffer();
    for (var index = 0; index < 1500; index++) {
      payload.write('event: reply.delta\ndata: {"delta":"x"}\n\n');
    }
    payload.write('event: done\ndata: [DONE]\n\n');
    expect(payload.length, greaterThan(32768));
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'model',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake(
        (_) => Stream<List<int>>.value(utf8.encode(payload.toString())),
      ),
    );

    final events = await client.streamChatEvents([Message.user('hi')]).toList();
    expect(events, hasLength(1500));
  });

  test('SSE event limit counts UTF-8 bytes for multibyte text', () async {
    final oversized =
        'event: reply.delta\ndata: ${List.filled(90000, '你').join()}\n\n';
    expect(oversized.length, lessThan(256 * 1024));
    expect(utf8.encode(oversized).length, greaterThan(256 * 1024));
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'model',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake(
        (_) => Stream<List<int>>.value(utf8.encode(oversized)),
      ),
    );

    await expectLater(
      client.streamPresentationChatEvents([Message.user('hi')]).drain<void>(),
      throwsStateError,
    );
  });

  test(
    'unterminated oversized SSE line fails and cancels open input',
    () async {
      final cancelled = Completer<void>();
      final input = StreamController<List<int>>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test/'),
        model: 'model',
        accessTokenProvider: () async => null,
        httpClient: _StreamingClientFake((_) => input.stream),
      );
      final result = client.streamPresentationChatEvents([
        Message.user('hi'),
      ]).drain<void>();
      input.add(List<int>.filled(256 * 1024 + 1, 0x61));

      await expectLater(
        result.timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
      await input.close();
    },
  );

  test('Live presentation call sends v2 in the real HTTP body', () async {
    late Map<String, dynamic> sentBody;
    final thin = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'model',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake((request) {
        sentBody = jsonDecode(request.body) as Map<String, dynamic>;
        return Stream<List<int>>.value(
          utf8.encode(
            'event: reply.delta\n'
            'data: {"delta":"{\\"actions\\":[],\\"reply\\":\\"ok\\"}"}\n\n'
            'event: done\ndata: [DONE]\n\n',
          ),
        );
      }),
    );
    final live = _FixedProxyService(thin).liveClient;

    final events = await live.streamPresentationChatEvents([
      Message.user('hello'),
    ]).toList();

    expect(sentBody['streamProtocol'], 'maaso.sse.v2.presentation');
    expect(events.last, isA<LLMStreamEvent>());
    expect(events.last.event, 'done');
    expect(events.last.data, '[DONE]');
  });

  test(
    'Live presentation requires real v2 done but closes legacy fallback',
    () async {
      final truncatedV2 = _EventClient(
        presentationEvents: const [
          LLMStreamEvent(event: 'reply.delta', data: '{"delta":"partial"}'),
        ],
      );
      final v2Live = _FixedProxyService(truncatedV2).liveClient;

      await expectLater(
        v2Live.streamPresentationChatEvents([
          Message.user('hello'),
        ]).drain<void>(),
        throwsStateError,
      );

      final legacy = _LegacyEventClient(
        events: const [
          LLMStreamEvent(event: 'reply.delta', data: '{"delta":"complete"}'),
        ],
      );
      final legacyEvents = await _FixedProxyService(legacy).liveClient
          .streamPresentationChatEvents([Message.user('hello')])
          .toList();

      expect(legacyEvents.map((event) => event.event), ['reply.delta', 'done']);
      expect(legacyEvents.last.data, '[DONE]');
    },
  );

  test('low-latency persona prompt uses a small max token ceiling', () async {
    for (final locale in <AppLocale>[AppLocale.en, AppLocale.zh]) {
      late Map<String, dynamic> sentBody;
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test/'),
        model: 'doubao-seed-2-1-turbo-260628',
        accessTokenProvider: () async => null,
        httpClient: _StreamingClientFake((request) {
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          return Stream<List<int>>.fromIterable([
            utf8.encode('event: reply.delta\ndata: {"delta":"ok"}\n\n'),
            utf8.encode('event: done\ndata: [DONE]\n\n'),
          ]);
        }),
      );
      final personaPrompt = AgentPromptCatalog.text(
        'runtime.persona.system',
        locale: locale,
        params: <String, Object?>{
          'nickname': 'Mika',
          'language_rule': locale == AppLocale.zh ? '使用中文。' : 'Use English.',
          'route': 'local',
          'mood': 'calm',
          'task': 'none',
          'traits': locale == AppLocale.zh ? '温暖' : 'warm',
        },
      );

      await client.streamChat([
        Message.system(personaPrompt),
        Message.user(locale == AppLocale.zh ? '为什么天空是蓝色的？' : 'Hello'),
      ]).drain<void>();

      expect(
        sentBody['maxTokens'],
        384,
        reason: '${locale.name} persona must keep the low-latency ceiling',
      );
    }
  });

  test('rejects legacy provider-compatible SSE without Maaso event names', () {
    final client = MaasoThinProxyLLMClient(
      baseUri: Uri.parse('https://api.example.test/'),
      model: 'doubao-seed-2-1-turbo-260628',
      accessTokenProvider: () async => null,
      httpClient: _StreamingClientFake((_) {
        return Stream<List<int>>.fromIterable([
          utf8.encode('data: {"choices":[{"delta":{"content":"legacy"}}]}\n\n'),
          utf8.encode('data: [DONE]\n\n'),
        ]);
      }),
    );

    expect(
      client.streamChatEvents([Message.user('hi')]).drain<void>(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('missing Maaso SSE event name'),
        ),
      ),
    );
  });
}

class _StreamingClientFake extends http.BaseClient {
  _StreamingClientFake(this.handler);

  final Stream<List<int>> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    return http.StreamedResponse(
      handler(req),
      200,
      headers: {'content-type': 'text/event-stream'},
      request: request,
    );
  }
}

class _FixedProxyService extends LLMProxyService {
  _FixedProxyService(this.client);

  final LLMClient client;

  @override
  Future<LLMClient?> ensureClient() async => client;
}

class _LegacyEventClient extends LLMClient {
  _LegacyEventClient({required this.events});

  final List<LLMStreamEvent> events;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async => '';

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '';

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => Stream<LLMStreamEvent>.fromIterable(events);
}

final class _EventClient extends _LegacyEventClient
    implements PresentationStreamingLLMClient {
  _EventClient({required this.presentationEvents}) : super(events: const []);

  final List<LLMStreamEvent> presentationEvents;

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => Stream<LLMStreamEvent>.fromIterable(presentationEvents);
}
