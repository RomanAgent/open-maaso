import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_generator.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _timeout = Duration(seconds: 3);
const _done = LLMStreamEvent(event: 'done', data: '[DONE]');

void main() {
  test(
    'admits safe units before protocol done with optional lookahead',
    () async {
      final transport = StreamController<LLMStreamEvent>(sync: true);
      final client = _PresentationClient(transport.stream);
      final generator = ConversationReplyGenerator(client);
      final admitted = <ConversationUtteranceDraft>[];
      final admittedBeforeDone = <bool>[];
      var protocolDone = false;
      var completed = false;
      final result = generator.generate(
        messages: [Message.user('今天吃什么？')],
        cancelled: Completer<void>().future,
        requireRawEnvelopeForTypedEvents: true,
        onUtterance: (unit) {
          admitted.add(unit);
          admittedBeforeDone.add(!protocolDone);
        },
      )..then((_) => completed = true);

      final actions = _actions();
      final firstPrefix = '{"actions":[${jsonEncode(actions[0])}';
      for (final codeUnit in firstPrefix.codeUnits) {
        transport.add(_delta(String.fromCharCode(codeUnit)));
      }
      transport.add(_typed(actions[0]));
      await _flush();
      expect(client.presentationCalls, 1);
      expect(client.standardCalls, 0);
      expect(admitted.map((unit) => unit.text), ['今天呀，嗯，我想想']);
      expect(completed, isFalse);

      transport.add(_delta(',${jsonEncode(actions[1])}'));
      transport.add(_typed(actions[1]));
      await _flush();
      expect(
        admitted,
        hasLength(1),
        reason: 'optional needs terminal lookahead',
      );

      transport.add(_delta(',${jsonEncode(actions[2])}'));
      transport.add(_typed(actions[2]));
      await _flush();
      expect(admitted.map((unit) => unit.text), ['今天呀，嗯，我想想', '猪脚饭？']);
      expect(completed, isFalse, reason: 'terminal remains provisional');

      transport.add(_delta('],"reply":${jsonEncode(_aggregate(actions))}}'));
      await _flush();
      expect(
        completed,
        isFalse,
        reason: 'transport close is not protocol done',
      );
      protocolDone = true;
      transport.add(_done);

      final reply = await result.timeout(_timeout);
      expect(reply!.utterances, hasLength(3));
      expect(admitted.map((unit) => unit.text), actions.map((a) => a['text']));
      expect(admittedBeforeDone, [true, true, false]);
      await generator.drained.timeout(_timeout);
      await transport.close();
    },
  );

  test('typed event before its raw ordinal mirror is rejected', () async {
    final harness = _Harness();
    final result = harness.start();
    harness.events.add(_typed(_actions().first));

    await expectLater(
      result,
      throwsA(_protocolCode('typed_before_raw_mirror')),
    );
    expect(harness.admitted, isEmpty);
    await harness.close();
  });

  test('duplicate typed event cannot replay an admitted prefix', () async {
    final harness = _Harness();
    final result = harness.start();
    final first = _actions().first;
    harness.events.add(_delta('{"actions":[${jsonEncode(first)}'));
    harness.events.add(_typed(first));
    await _flush();
    expect(harness.admitted.map((unit) => unit.text), [first['text']]);

    harness.events.add(_typed(first));
    await expectLater(
      result,
      throwsA(_protocolCode('typed_before_raw_mirror')),
    );
    expect(harness.admitted.map((unit) => unit.text), [first['text']]);
    await harness.close();
  });

  test(
    'wrong typed ordinal rejects without changing the proved raw prefix',
    () async {
      final harness = _Harness();
      final result = harness.start();
      final actions = _actions();
      harness.events.add(_delta('{"actions":[${jsonEncode(actions[0])}'));
      harness.events.add(_typed(actions[1]));

      await expectLater(result, throwsA(_protocolCode('conflicting_formats')));
      expect(harness.admitted.map((unit) => unit.text), [actions[0]['text']]);
      expect(
        harness.admitted.map((unit) => unit.text),
        isNot(contains(actions[1]['text'])),
      );
      await harness.close();
    },
  );

  test('EOF without explicit done preserves only the safe prefix', () async {
    final harness = _Harness();
    final result = harness.start();
    final actions = [
      _actions().first,
      {'type': 'reply.utterance', 'text': '最后一句', 'after': 'finish'},
    ];
    harness.events.add(_delta('{"actions":[${jsonEncode(actions[0])}'));
    harness.events.add(_typed(actions[0]));
    harness.events.add(_delta(',${jsonEncode(actions[1])}'));
    harness.events.add(_typed(actions[1]));
    harness.events.add(_delta('],"reply":${jsonEncode(_aggregate(actions))}}'));
    final expectation = expectLater(
      result,
      throwsA(_protocolCode('presentation_stream_truncated')),
    );
    await harness.events.close();

    await expectation;
    expect(harness.admitted.map((unit) => unit.text), [actions.first['text']]);
    await harness.generator.drained.timeout(_timeout);
  });

  test('malformed done marker cannot release a terminal unit', () async {
    final harness = _Harness();
    final result = harness.start();
    final terminal = {
      'type': 'reply.utterance',
      'text': '终止句',
      'after': 'finish',
    };
    harness.events.add(
      _delta('{"actions":[${jsonEncode(terminal)}],"reply":"终止句"}'),
    );
    harness.events.add(_typed(terminal));
    harness.events.add(const LLMStreamEvent(event: 'done', data: 'not-[DONE]'));

    await expectLater(
      result,
      throwsA(_protocolCode('invalid_presentation_done')),
    );
    expect(harness.admitted, isEmpty);
    await harness.close();
  });

  test(
    'invalid or duplicate current raw prefix never admits typed text',
    () async {
      final action = _actions().first;
      final typed = _typed(action);
      final invalidPrefixes = <String>[
        '{"x":oops,"actions":[${jsonEncode(action)}',
        '{"actions":[${jsonEncode(action)}],'
            '"actions":[${jsonEncode(action)}],"reply":"x"}',
        '{"actions":[{"type":"reply.utterance",'
            '"type":"reply.utterance","text":"${action['text']}",'
            '"after":"continue"}',
      ];

      for (final raw in invalidPrefixes) {
        final harness = _Harness();
        final result = harness.start();
        harness.events.add(_delta(raw));
        harness.events.add(typed);
        await expectLater(
          result,
          throwsA(isA<ConversationReplyProtocolException>()),
          reason: raw,
        );
        expect(harness.admitted, isEmpty, reason: raw);
        await harness.close();
      }
    },
  );

  test('deep raw JSON nesting is bounded before typed admission', () async {
    final harness = _Harness();
    final result = harness.start();
    final nested =
        '${List.filled(70, '[').join()}"calm"'
        '${List.filled(70, ']').join()}';
    harness.events.add(
      _delta(
        '{"actions":[{"type":"reply.utterance","text":"safe",'
        '"after":"continue","body":{"mood":$nested}}',
      ),
    );
    harness.events.add(
      _typed({
        'type': 'reply.utterance',
        'text': 'safe',
        'after': 'continue',
        'body': {'mood': 'calm'},
      }),
    );

    await expectLater(
      result,
      throwsA(_protocolCode('invalid_raw_action_prefix')),
    );
    expect(harness.admitted, isEmpty);
    await harness.close();
  });

  test(
    'a malformed suffix keeps one committed-safe prefix without replay',
    () async {
      final harness = _Harness();
      final result = harness.start();
      final first = _actions().first;
      harness.events.add(_delta('{"actions":[${jsonEncode(first)}'));
      harness.events.add(_typed(first));
      await _flush();
      harness.events.add(_delta(',{"type":oops'));
      harness.events.add(_typed(_actions()[1]));

      await expectLater(
        result,
        throwsA(_protocolCode('invalid_raw_action_prefix')),
      );
      expect(harness.admitted.map((unit) => unit.text), [first['text']]);
      await harness.close();
    },
  );

  test(
    '256 raw fragments plus typed and done fit the bounded stream',
    () async {
      final harness = _Harness();
      final result = harness.start();
      final terminal = {
        'type': 'reply.utterance',
        'text': List.filled(320, 'x').join(),
        'after': 'finish',
      };
      final raw = jsonEncode({
        'actions': [terminal],
        'reply': terminal['text'],
      });
      final fragments = _splitInto(raw, 256);
      expect(fragments, hasLength(256));
      for (final fragment in fragments) {
        harness.events.add(_delta(fragment));
      }
      harness.events.add(_typed(terminal));
      harness.events.add(_done);

      final reply = await result.timeout(_timeout);
      expect(reply!.utterances.single.text, terminal['text']);
      expect(harness.admitted, hasLength(1));
      await harness.close();
    },
  );

  test(
    'reply-first v2 holds until actions arrive and remains compatible',
    () async {
      final harness = _Harness();
      final result = harness.start();
      final terminal = {
        'type': 'reply.utterance',
        'text': '键顺序不影响协议。',
        'after': 'finish',
      };
      harness.events.add(_delta('{"reply":"键顺序不影响协议。","actions":['));
      await _flush();
      expect(harness.admitted, isEmpty);
      harness.events.add(_delta('${jsonEncode(terminal)}]}'));
      harness.events.add(_typed(terminal));
      await _flush();
      expect(harness.admitted, isEmpty, reason: 'terminal waits for done');
      harness.events.add(_done);

      final reply = await result.timeout(_timeout);
      expect(reply!.utterances.single.text, terminal['text']);
      expect(harness.admitted.single.text, terminal['text']);
      await harness.close();
    },
  );

  test('cancellation fences all late typed and raw events', () async {
    final cancelled = Completer<void>();
    final harness = _Harness(cancelled: cancelled.future);
    final result = harness.start();
    final first = _actions().first;
    harness.events.add(_delta('{"actions":[${jsonEncode(first)}'));
    harness.events.add(_typed(first));
    await _flush();
    expect(harness.admitted, hasLength(1));

    cancelled.complete();
    expect(await result.timeout(_timeout), isNull);
    harness.events.add(_delta(',${jsonEncode(_actions()[1])}'));
    harness.events.add(_typed(_actions()[1]));
    harness.events.add(_done);
    await _flush();
    expect(harness.admitted, hasLength(1));
    await harness.close();
  });
}

Matcher _protocolCode(String code) => isA<ConversationReplyProtocolException>()
    .having((error) => error.code, 'code', code);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

String _aggregate(List<Map<String, Object?>> actions) =>
    actions.map((action) => action['text']).join();

List<String> _splitInto(String input, int count) {
  assert(input.length >= count);
  final output = <String>[];
  var offset = 0;
  for (var remaining = count; remaining > 0; remaining--) {
    final available = input.length - offset;
    final length = (available / remaining).ceil();
    output.add(input.substring(offset, offset + length));
    offset += length;
  }
  return output;
}

LLMStreamEvent _delta(String text) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text}));

LLMStreamEvent _typed(Map<String, Object?> action) =>
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action));

List<Map<String, Object?>> _actions() => [
  {
    'type': 'reply.utterance',
    'text': '今天呀，嗯，我想想',
    'after': 'continue',
    'body': {'mood': 'thinking', 'gesture': 'none'},
  },
  {
    'type': 'reply.utterance',
    'text': '猪脚饭？',
    'after': 'optional',
    'pause': 'invite',
  },
  {'type': 'reply.utterance', 'text': '或者看你想吃啥，我都行', 'after': 'finish'},
];

class _Harness {
  _Harness({Future<void>? cancelled})
    : cancelled = cancelled ?? Completer<void>().future,
      events = StreamController<LLMStreamEvent>(sync: true) {
    generator = ConversationReplyGenerator(_PresentationClient(events.stream));
  }

  final Future<void> cancelled;
  final StreamController<LLMStreamEvent> events;
  final admitted = <ConversationUtteranceDraft>[];
  late final ConversationReplyGenerator generator;

  Future<ConversationReplyDraft?> start() => generator.generate(
    messages: [Message.user('question')],
    cancelled: cancelled,
    requireRawEnvelopeForTypedEvents: true,
    onUtterance: admitted.add,
  );

  Future<void> close() async {
    if (!events.isClosed) await events.close();
    await generator.drained.timeout(_timeout);
  }
}

class _PresentationClient extends LLMClient
    implements PresentationStreamingLLMClient {
  _PresentationClient(this.events);

  final Stream<LLMStreamEvent> events;
  int standardCalls = 0;
  int presentationCalls = 0;

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    presentationCalls++;
    return events;
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    standardCalls++;
    return const Stream<LLMStreamEvent>.empty();
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected aggregate path');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected JSON path');
}
