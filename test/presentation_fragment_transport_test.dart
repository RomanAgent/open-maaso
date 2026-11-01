import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_generator.dart';
import 'package:maaso/src/features/agent/application/intent/creation_intent.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/presentation_stream_limits.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _done = LLMStreamEvent(event: 'done', data: '[DONE]');
const _messages = <Message>[];

String _createEnvelope(String requirements) => jsonEncode({
  'reply': 'I will work out your idea.',
  'actions': [
    {
      'type': 'creation.intent',
      'mode': 'create',
      'kind': 'game',
      'requirements': requirements,
    },
  ],
});

String _sizedEnvelope(int length) {
  final base = _createEnvelope('');
  final raw = _createEnvelope(List.filled(length - base.length, 'x').join());
  expect(raw.length, length);
  return raw;
}

LLMStreamEvent _delta(String value) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': value}));

List<LLMStreamEvent> _characters(String raw) => [
  for (final character in raw.codeUnits) _delta(String.fromCharCode(character)),
];

class _EventClient extends LLMClient implements PresentationStreamingLLMClient {
  _EventClient(this.events);

  final List<LLMStreamEvent> events;
  int presentationCalls = 0;
  int ordinaryCalls = 0;

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    presentationCalls += 1;
    return Stream.fromIterable(events);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    ordinaryCalls += 1;
    throw StateError('unexpected_ordinary_stream');
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected_chat');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected_json_request');
}

class _FakeProxy extends LLMProxyService {
  _FakeProxy(this.client);

  final LLMClient client;
  int resolutions = 0;

  @override
  Future<LLMClient?> ensureClient() async {
    resolutions += 1;
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put(SecureStorageService());
  });
  tearDown(appServices.reset);

  test(
    'LiveLLMClient forwards more than 1000 character fragments and done intact',
    () async {
      final raw = _createEnvelope(List.filled(1800, 'x').join());
      final fragments = _characters(raw);
      expect(fragments.length, greaterThanOrEqualTo(1000));
      expect(
        raw.length,
        lessThan(PresentationStreamLimits.maxContentCharacters),
      );
      final client = _EventClient([...fragments, _done]);
      final proxy = _FakeProxy(client);
      final forwarded = await LiveLLMClient(
        proxy,
      ).streamPresentationChatEvents(_messages).toList();
      expect(forwarded, orderedEquals([...fragments, _done]));
      expect(forwarded.last, same(_done));
      expect(forwarded.map((event) => event.deltaText).join(), raw);
      expect(client.presentationCalls, 1);
      expect(client.ordinaryCalls, 0);
      expect(proxy.resolutions, 1);
    },
  );

  test(
    'LiveLLMClient accepts the complete logical boundary including metadata',
    () async {
      final raw = _sizedEnvelope(PresentationStreamLimits.maxContentCharacters);
      final client = _EventClient([_delta(raw), _done]);
      final forwarded = await LiveLLMClient(
        _FakeProxy(client),
      ).streamPresentationChatEvents(_messages).toList();
      expect(forwarded.map((event) => event.deltaText).join(), raw);
      expect(forwarded.last, same(_done));
    },
  );

  test(
    'actual logical overflow is rejected before the overflowing delta forwards',
    () async {
      final raw = _sizedEnvelope(
        PresentationStreamLimits.maxContentCharacters + 1,
      );
      final client = _EventClient([_delta(raw), _done]);
      final forwarded = <LLMStreamEvent>[];
      await expectLater(
        LiveLLMClient(
          _FakeProxy(client),
        ).streamPresentationChatEvents(_messages).forEach(forwarded.add),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            'Presentation content exceeded its bounds.',
          ),
        ),
      );
      expect(forwarded, isEmpty);
    },
  );

  test(
    'wire overflow is rejected even when logical content is only one character',
    () async {
      final oversized = LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({
          'delta': 'x',
          'padding': List.filled(
            PresentationStreamLimits.maxWireCharacters,
            'w',
          ).join(),
        }),
      );
      expect(oversized.deltaText, 'x');
      expect(
        oversized.data.length,
        greaterThan(PresentationStreamLimits.maxWireCharacters),
      );
      final client = _EventClient([oversized, _done]);
      final forwarded = <LLMStreamEvent>[];
      await expectLater(
        LiveLLMClient(
          _FakeProxy(client),
        ).streamPresentationChatEvents(_messages).forEach(forwarded.add),
        _transportBoundsFailure,
      );
      expect(forwarded, isEmpty);
    },
  );

  test(
    'aggregate wire overflow rejects below the control-event ceiling',
    () async {
      final events = <LLMStreamEvent>[
        _delta(_createEnvelope('A complete arbitrary interactive idea.')),
        for (var index = 0; index < 256; index++)
          LLMStreamEvent(event: 'usage', data: List.filled(1300, 'w').join()),
        _done,
      ];
      expect(
        events.length,
        lessThan(PresentationStreamLimits.maxControlEvents),
      );
      expect(
        events.fold<int>(0, (length, event) => length + event.data.length),
        greaterThan(PresentationStreamLimits.maxWireCharacters),
      );
      final client = _EventClient(events);
      final forwarded = <LLMStreamEvent>[];
      await expectLater(
        LiveLLMClient(
          _FakeProxy(client),
        ).streamPresentationChatEvents(_messages).forEach(forwarded.add),
        _transportBoundsFailure,
      );
      expect(forwarded.any((event) => event.isDone), isFalse);
    },
  );

  for (final emptyReplyDelta in [false, true]) {
    test(
      '${emptyReplyDelta ? 'empty reply delta' : 'control event'} flood cannot spend the content-fragment allowance',
      () async {
        final client = _EventClient([
          for (
            var index = 0;
            index <= PresentationStreamLimits.maxControlEvents;
            index++
          )
            emptyReplyDelta
                ? _delta('')
                : const LLMStreamEvent(event: 'ping', data: ''),
          _done,
        ]);
        final forwarded = <LLMStreamEvent>[];
        await expectLater(
          LiveLLMClient(
            _FakeProxy(client),
          ).streamPresentationChatEvents(_messages).forEach(forwarded.add),
          _transportBoundsFailure,
        );
        expect(forwarded, hasLength(PresentationStreamLimits.maxControlEvents));
        expect(forwarded.any((event) => event.isDone), isFalse);
        expect(forwarded.every((event) => event.deltaText.isEmpty), isTrue);
      },
    );
  }

  test(
    'control boundary counts done independently from content fragmentation',
    () async {
      final raw = _createEnvelope(List.filled(1200, 'x').join());
      final events = <LLMStreamEvent>[
        for (
          var index = 0;
          index < PresentationStreamLimits.maxControlEvents - 1;
          index++
        )
          const LLMStreamEvent(event: 'heartbeat', data: ''),
        ..._characters(raw),
        _done,
      ];
      final forwarded = await LiveLLMClient(
        _FakeProxy(_EventClient(events)),
      ).streamPresentationChatEvents(_messages).toList();
      expect(forwarded, orderedEquals(events));
      expect(forwarded.map((event) => event.deltaText).join(), raw);
    },
  );

  test(
    'LiveLLMClient and ConversationReplyGenerator decode a fragmented create end to end',
    () async {
      final requirements = List.filled(600, '自由想法').join();
      final raw = _createEnvelope(requirements);
      final fragments = _characters(raw);
      expect(fragments.length, greaterThan(1000));
      final client = _EventClient([...fragments, _done]);
      final proxy = _FakeProxy(client);
      final generator = ConversationReplyGenerator(LiveLLMClient(proxy));
      final visible = <String>[];
      final admitted = <ConversationUtteranceDraft>[];
      final result = await generator.generate(
        messages: [Message.user('Choose an idea and make it for me.')],
        cancelled: Completer<void>().future,
        onReplyTextDelta: visible.add,
        onUtterance: admitted.add,
        allowRawPrefixes: true,
      );
      await generator.drained;
      expect(result, isNotNull);
      expect(result!.creationIntent!.mode, CreationIntentMode.create);
      expect(result.creationIntent!.kind, CreationIntentKind.game);
      expect(result.creationIntent!.requirements, requirements);
      expect(visible.join(), 'I will work out your idea.');
      expect(admitted.single.text, visible.join());
      expect(client.presentationCalls, 1);
      expect(client.ordinaryCalls, 0);
      expect(proxy.resolutions, 1);
    },
  );
}

Matcher get _transportBoundsFailure => throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'reason',
    'Presentation stream exceeded its bounds.',
  ),
);
