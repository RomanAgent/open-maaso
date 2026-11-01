import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_generator.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/presentation_stream_limits.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _done = LLMStreamEvent(event: 'done', data: '[DONE]');

void main() {
  test(
    'a legal one-character stream may exceed 272 fragments and 16KiB wire',
    () async {
      final raw = _replyEnvelope(requirements: List.filled(700, '自由想法').join());
      final deltas = [
        for (final code in raw.codeUnits) _delta(String.fromCharCode(code)),
      ];
      expect(deltas.length, greaterThan(272));
      expect(
        deltas.fold<int>(0, (count, event) => count + event.data.length),
        greaterThan(PresentationStreamLimits.maxContentCharacters),
      );
      expect(
        raw.length,
        lessThan(PresentationStreamLimits.maxContentCharacters),
      );
      final client = _PresentationClient(
        Stream.fromIterable([...deltas, _done]),
      );
      final generator = ConversationReplyGenerator(client);
      final text = <String>[];
      final admitted = <ConversationUtteranceDraft>[];
      final value = await generator.generate(
        messages: [Message.user('Choose an idea and make it for me.')],
        cancelled: Completer<void>().future,
        onReplyTextDelta: text.add,
        onUtterance: admitted.add,
      );
      await generator.drained;

      expect(value!.creationIntent!.toJson()['mode'], 'create');
      expect(
        value.creationIntent!.requirements,
        List.filled(700, '自由想法').join(),
      );
      expect(text.join(), 'I will work out your idea.');
      expect(admitted.single.text, text.join());
      expect(client.calls, 1);
    },
  );

  test(
    'a complete JSON envelope exactly at the logical limit is accepted',
    () async {
      final raw = _sizedEnvelope(PresentationStreamLimits.maxContentCharacters);
      final value = await _generate([_delta(raw), _done]);
      expect(value!.creationIntent!.toJson()['mode'], 'create');
    },
  );

  test(
    'real logical overflow fails before its text or metadata is admitted',
    () async {
      final raw = _sizedEnvelope(
        PresentationStreamLimits.maxContentCharacters + 1,
      );
      final admitted = <ConversationUtteranceDraft>[];
      final text = <String>[];
      await expectLater(
        _generate([_delta(raw), _done], admitted: admitted, text: text),
        _tooLarge,
      );
      expect(admitted, isEmpty);
      expect(text, isEmpty);
    },
  );

  test(
    'raw envelope and typed mirror have independent content budgets',
    () async {
      final action = {
        'type': 'reply.utterance',
        'text': List.filled(9000, 'x').join(),
        'after': 'finish',
      };
      final raw = jsonEncode({
        'actions': [
          action,
          {'type': 'creation.intent', 'mode': 'none'},
        ],
        'reply': '',
      });
      final mirror = _typed(action);
      expect(
        raw.length + mirror.data.length,
        greaterThan(PresentationStreamLimits.maxContentCharacters),
      );
      expect(
        raw.length,
        lessThan(PresentationStreamLimits.maxContentCharacters),
      );
      expect(
        mirror.data.length,
        lessThan(PresentationStreamLimits.maxContentCharacters),
      );
      final admitted = <ConversationUtteranceDraft>[];
      final value = await _generate([
        _delta(raw),
        mirror,
        _done,
      ], admitted: admitted);
      expect(value!.utterances.single.text, action['text']);
      expect(value.creationIntent!.toJson()['mode'], 'none');
      expect(admitted, hasLength(1));
    },
  );

  test('a genuinely oversized typed mirror is rejected', () async {
    final action = {
      'type': 'reply.utterance',
      'text': List.filled(
        PresentationStreamLimits.maxContentCharacters,
        'x',
      ).join(),
      'after': 'finish',
    };
    await expectLater(_generate([_typed(action), _done]), _tooLarge);
  });

  test(
    'the control budget includes done but not content fragmentation',
    () async {
      final value = await _generate([
        for (
          var index = 0;
          index < PresentationStreamLimits.maxControlEvents - 1;
          index++
        )
          const LLMStreamEvent(event: 'ping', data: ''),
        for (final code in _replyEnvelope(requirements: '完整实现自由想法').codeUnits)
          _delta(String.fromCharCode(code)),
        _done,
      ]);
      expect(value!.creationIntent!.toJson()['mode'], 'create');
    },
  );

  test('transport metadata floods retain a separate event ceiling', () async {
    final admitted = <ConversationUtteranceDraft>[];
    await expectLater(
      _generate([
        _delta(_replyEnvelope(requirements: '完整互动作品')),
        for (
          var index = 0;
          index <= PresentationStreamLimits.maxControlEvents;
          index++
        )
          const LLMStreamEvent(event: 'heartbeat', data: ''),
        _done,
      ], admitted: admitted),
      _tooLarge,
    );
    expect(admitted, isEmpty);
  });

  test(
    'empty reply delta floods cannot spend the logical content allowance',
    () async {
      await expectLater(
        _generate([
          for (
            var index = 0;
            index <= PresentationStreamLimits.maxControlEvents;
            index++
          )
            _delta(''),
          _done,
        ]),
        _tooLarge,
      );
    },
  );

  test('a single oversized wire event is rejected', () async {
    await expectLater(
      _generate([
        LLMStreamEvent(
          event: 'trace',
          data: List.filled(
            PresentationStreamLimits.maxWireCharacters + 1,
            'x',
          ).join(),
        ),
        _done,
      ]),
      _tooLarge,
    );
  });

  test(
    'aggregate wire overflow is rejected below the control event limit',
    () async {
      await expectLater(
        _generate([
          _delta(_replyEnvelope(requirements: '完整互动作品')),
          for (var index = 0; index < 256; index++)
            LLMStreamEvent(event: 'usage', data: List.filled(1300, 'x').join()),
          _done,
        ]),
        _tooLarge,
      );
    },
  );

  test(
    'unknown behavioral events remain forbidden despite relaxed fragmentation',
    () async {
      await expectLater(
        _generate([
          _delta(_replyEnvelope(requirements: List.filled(800, 'x').join())),
          const LLMStreamEvent(
            event: 'creation.intent',
            data: '{"mode":"create"}',
          ),
          _done,
        ]),
        throwsA(
          isA<ConversationReplyProtocolException>().having(
            (error) => error.code,
            'code',
            'non_presentation_event',
          ),
        ),
      );
    },
  );
}

Matcher get _tooLarge => throwsA(
  isA<ConversationReplyProtocolException>().having(
    (error) => error.code,
    'code',
    'response_too_large',
  ),
);

String _replyEnvelope({required String requirements}) => jsonEncode({
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
  final empty = _replyEnvelope(requirements: '');
  final result = _replyEnvelope(
    requirements: List.filled(length - empty.length, 'x').join(),
  );
  expect(result.length, length);
  return result;
}

Future<ConversationReplyDraft?> _generate(
  List<LLMStreamEvent> events, {
  List<ConversationUtteranceDraft>? admitted,
  List<String>? text,
}) async {
  final generator = ConversationReplyGenerator(
    _PresentationClient(Stream.fromIterable(events)),
  );
  try {
    return await generator.generate(
      messages: [Message.user('current message')],
      cancelled: Completer<void>().future,
      requireRawEnvelopeForTypedEvents: true,
      onUtterance: admitted?.add,
      onReplyTextDelta: text?.add,
    );
  } finally {
    await generator.drained;
  }
}

LLMStreamEvent _delta(String text) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text}));

LLMStreamEvent _typed(Map<String, Object?> action) =>
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action));

class _PresentationClient extends LLMClient
    implements PresentationStreamingLLMClient {
  _PresentationClient(this.events);
  final Stream<LLMStreamEvent> events;
  var calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 30);
  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls++;
    return events;
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => throw StateError('Unexpected second model path');
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('Unexpected second model path');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected second model path');
}
