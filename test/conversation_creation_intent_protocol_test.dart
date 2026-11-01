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
  const decoder = ConversationReplyDecoder();

  test('creation intent preserves three presentation units and ordering', () {
    final actions = _utterances();
    final intent = _create();
    final draft = decoder.decode(jsonEncode(_envelope([...actions, intent])));

    expect(draft.creationIntent!.toJson(), intent);
    expect(draft.usesUtteranceProtocol, isTrue);
    expect(
      draft.utterances.map((unit) => unit.text),
      actions.map((action) => action['text']),
    );
    expect(draft.utterances.map((unit) => unit.after), [
      ConversationAfter.continueReply,
      ConversationAfter.optional,
      ConversationAfter.finish,
    ]);
  });

  test('all intent modes pass data without executing or publishing it', () {
    for (final intent in <Map<String, Object?>>[
      {'type': 'creation.intent', 'mode': 'none'},
      _create(),
      {..._create(), 'mode': 'propose'},
      {
        'type': 'creation.intent',
        'mode': 'confirm',
        'proposalId': 'proposal-from-host',
      },
      {
        'type': 'creation.intent',
        'mode': 'edit',
        'projectId': 'existing-project',
        'requirements': '每次触摸时把声音对应的色彩留在画布上。',
      },
      {'type': 'creation.intent', 'mode': 'cancel', 'taskId': 'existing-task'},
    ]) {
      final draft = decoder.decodeEnvelope(_envelope([_terminal(), intent]));
      expect(draft.creationIntent!.toJson()['mode'], intent['mode']);
      expect(draft.utterances.single.text, _terminal()['text']);
      expect(draft.reply, isNot(contains('creation.intent')));
    }
  });

  test(
    'intent-only action with plain reply remains one presentation draft',
    () {
      final draft = decoder.decodeEnvelope({
        'reply': '我按刚才确定的想法来做。',
        'actions': [_create()],
      });

      expect(draft.usesUtteranceProtocol, isFalse);
      expect(draft.utterances.single.text, draft.reply);
      expect(draft.creationIntent!.toJson(), _create());
    },
  );

  test('legacy reply retains a null creation intent', () {
    for (final raw in [
      '普通对话。',
      '{"reply":"普通对话。","actions":[]}',
      jsonEncode(_envelope([_terminal()])),
    ]) {
      expect(decoder.decode(raw).creationIntent, isNull);
    }
  });

  test('invalid intents, duplicates, ordering and unknown actions reject', () {
    for (final actions in <List<Map<String, Object?>>>[
      [_create(), _terminal()],
      [_terminal(), _create(), _create()],
      [
        _terminal(),
        {'type': 'creation.intent', 'mode': 'create'},
      ],
      [
        _terminal(),
        {..._create(), 'mode': 'unknown'},
      ],
      [
        _terminal(),
        {..._create(), 'unexpected': 'value'},
      ],
      [
        _terminal(),
        {'type': 'creation.intent', 'mode': 'confirm'},
      ],
      [
        _terminal(),
        {'type': 'creation.intent', 'mode': 'cancel'},
      ],
      [
        _terminal(),
        {'type': 'skill.call', 'name': 'not-admitted'},
      ],
      [
        _terminal(),
        _create(),
        {'type': 'unknown.action'},
      ],
    ]) {
      expect(
        () => decoder.decodeEnvelope(_envelope(actions)),
        throwsA(isA<ConversationReplyProtocolException>()),
        reason: jsonEncode(actions),
      );
    }
  });

  test('intent trailer never changes utterance bounds or terminal rules', () {
    for (final actions in <List<Map<String, Object?>>>[
      [
        for (var index = 0; index < 4; index++)
          {
            'type': 'reply.utterance',
            'text': '段 $index',
            'after': index == 3 ? 'finish' : 'continue',
          },
        _create(),
      ],
      [
        {..._terminal(), 'after': 'continue'},
        _create(),
      ],
      [_terminal(), _terminal(), _create()],
    ]) {
      expect(
        () => decoder.decodeEnvelope(_envelope(actions)),
        throwsA(isA<ConversationReplyProtocolException>()),
      );
    }
  });

  test(
    'closed continue is admitted while intent trailer is still pending',
    () async {
      final harness = _Harness(presentation: true);
      var completed = false;
      final result = harness.start()..then((_) => completed = true);
      final units = _utterances();

      harness.events.add(_delta('{"actions":[${jsonEncode(units[0])}'));
      harness.events.add(_typed(units[0]));
      await _flush();
      expect(harness.admitted.map((unit) => unit.text), [units[0]['text']]);
      expect(completed, isFalse);
      expect(harness.client.calls, 1);

      harness.events.add(_delta(',${jsonEncode(units[1])}'));
      harness.events.add(_typed(units[1]));
      await _flush();
      expect(harness.admitted, hasLength(1));
      harness.events.add(_delta(',${jsonEncode(units[2])}'));
      harness.events.add(_typed(units[2]));
      await _flush();
      expect(harness.admitted, hasLength(2));
      expect(completed, isFalse);

      // There is deliberately no separate executable intent event.
      harness.events.add(_delta(',${jsonEncode(_create())}'));
      await _flush();
      expect(completed, isFalse);
      expect(harness.admitted, hasLength(2));
      harness.events.add(_delta('],"reply":"理解了，按刚才的想法来做。"}'));
      await _flush();
      expect(completed, isFalse, reason: 'closed JSON still waits for done');
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.creationIntent!.toJson(), _create());
      expect(
        harness.admitted.map((unit) => unit.text),
        units.map((action) => action['text']),
      );
      expect(harness.client.calls, 1);
      await harness.close();
    },
  );

  test(
    'generic raw response stays private until its complete envelope',
    () async {
      final harness = _Harness(presentation: false);
      var completed = false;
      final result = harness.start()..then((_) => completed = true);
      final raw = jsonEncode(_envelope([_terminal(), _create()]));
      harness.events.add(_delta(raw));
      await _flush();
      expect(harness.admitted, isEmpty);
      expect(completed, isFalse);
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.creationIntent!.toJson(), _create());
      expect(harness.admitted, hasLength(1));
      expect(harness.client.calls, 1);
      await harness.close();
    },
  );

  test(
    'raw-only presentation transport admits continue before intent or done',
    () async {
      final harness = _Harness(presentation: true);
      var completed = false;
      final result = harness.start()..then((_) => completed = true);
      final units = _utterances();
      harness.events.add(_delta('{"actions":[${jsonEncode(units[0])}'));
      await _flush();
      expect(harness.admitted.map((unit) => unit.text), [units[0]['text']]);
      expect(completed, isFalse);

      harness.events.add(_delta(',${jsonEncode(units[1])}'));
      await _flush();
      expect(harness.admitted, hasLength(1));
      harness.events.add(_delta(',${jsonEncode(units[2])}'));
      await _flush();
      expect(harness.admitted, hasLength(2));
      expect(completed, isFalse);
      harness.events.add(
        _delta(',${jsonEncode(_create())}],"reply":"按这个想法来做。"}'),
      );
      await _flush();
      expect(completed, isFalse);
      expect(harness.admitted, hasLength(2));
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.creationIntent!.toJson(), _create());
      expect(harness.admitted, hasLength(3));
      expect(harness.client.calls, 1);
      await harness.close();
    },
  );

  test('semantic generic stream opts into proven raw prefixes', () async {
    final harness = _Harness(presentation: false, allowRawPrefixes: true);
    var completed = false;
    final result = harness.start()..then((_) => completed = true);
    final first = _utterances().first;
    harness.events.add(_delta('{"actions":[${jsonEncode(first)}'));
    await _flush();
    expect(harness.admitted.single.text, first['text']);
    expect(completed, isFalse);
    harness.events.add(
      _delta(
        ',${jsonEncode(_terminal())},'
        '${jsonEncode(_create())}],"reply":"理解了。"}',
      ),
    );
    await _flush();
    expect(harness.admitted, hasLength(1));
    expect(completed, isFalse);
    harness.events.add(_done);

    final draft = await result.timeout(_timeout);
    expect(draft!.creationIntent!.toJson(), _create());
    expect(harness.admitted, hasLength(2));
    expect(harness.client.calls, 1);
    await harness.close();
  });

  test(
    'raw intent-only response requires complete JSON and protocol done',
    () async {
      final harness = _Harness(presentation: true);
      final result = harness.start();
      harness.events.add(
        _delta(
          jsonEncode({
            'actions': [_create()],
            'reply': '我来做。',
          }),
        ),
      );
      await _flush();
      expect(harness.admitted, isEmpty);
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.creationIntent!.toJson(), _create());
      expect(harness.admitted.single.text, '我来做。');
      await harness.close();
    },
  );

  test('invalid trailer cannot release terminal or return an intent', () async {
    final harness = _Harness(presentation: true);
    final result = harness.start();
    final units = [_utterances().first, _terminal()];
    harness.events.add(_delta('{"actions":[${jsonEncode(units[0])}'));
    harness.events.add(_typed(units[0]));
    harness.events.add(_delta(',${jsonEncode(units[1])}'));
    harness.events.add(_typed(units[1]));
    harness.events.add(
      _delta(
        ',{"type":"creation.intent","mode":"create"}],'
        '"reply":"我来做。"}',
      ),
    );
    harness.events.add(_done);

    await expectLater(
      result,
      throwsA(isA<ConversationReplyProtocolException>()),
    );
    expect(harness.admitted.map((unit) => unit.text), [units[0]['text']]);
    await harness.close();
  });

  test(
    'standalone intent SSE cannot bypass the complete raw envelope',
    () async {
      for (final eventName in ['creation.intent', 'task.handoff']) {
        final harness = _Harness(presentation: true);
        final result = harness.start();
        harness.events.add(
          LLMStreamEvent(event: eventName, data: jsonEncode(_create())),
        );

        await expectLater(
          result,
          throwsA(isA<ConversationReplyProtocolException>()),
        );
        expect(harness.admitted, isEmpty);
        await harness.close();
      }
    },
  );

  test('truncated stream returns no intent and holds the terminal', () async {
    final harness = _Harness(presentation: true);
    final result = harness.start();
    harness.events.add(_delta(jsonEncode(_envelope([_terminal(), _create()]))));
    harness.events.add(_typed(_terminal()));
    final expectation = expectLater(
      result,
      throwsA(isA<ConversationReplyProtocolException>()),
    );
    await harness.events.close();
    await expectation;
    expect(harness.admitted, isEmpty);
    await harness.generator.drained.timeout(_timeout);
  });

  test(
    'cancellation discards a complete intent while done is pending',
    () async {
      final cancelled = Completer<void>();
      final harness = _Harness(presentation: true, cancelled: cancelled.future);
      final result = harness.start();
      harness.events.add(
        _delta(jsonEncode(_envelope([_terminal(), _create()]))),
      );
      harness.events.add(_typed(_terminal()));
      cancelled.complete();

      expect(await result.timeout(_timeout), isNull);
      harness.events.add(_done);
      await _flush();
      expect(harness.admitted, isEmpty);
      await harness.close();
    },
  );

  test(
    'duplicate raw intent fields reject before decoding can fold them',
    () async {
      for (final presentation in [false, true]) {
        final harness = _Harness(presentation: presentation);
        final result = harness.start();
        harness.events.add(
          _delta(
            '{"actions":[{"type":"creation.intent",'
            '"mode":"none","mode":"create","kind":"game",'
            '"requirements":"任意想法"}],"reply":"我来做。"}',
          ),
        );
        harness.events.add(_done);

        await expectLater(
          result,
          throwsA(isA<ConversationReplyProtocolException>()),
        );
        expect(harness.admitted, isEmpty);
        await harness.close();
      }
    },
  );
  test(
    'reply text streams before intent metadata without admitting the task',
    () async {
      for (final presentation in [false, true]) {
        final harness = _Harness(presentation: presentation);
        var completed = false;
        final text = <String>[];
        final result = harness.start(onReplyTextDelta: text.add)
          ..then((_) => completed = true);
        harness.events.add(_delta('{"reply":"理解了。'));
        await _flush();
        expect(text, ['理解了。']);
        expect(harness.admitted, isEmpty);
        expect(completed, isFalse);
        harness.events.add(_delta('我按你的想法来做。","actions":['));
        await _flush();
        expect(text.join(), '理解了。我按你的想法来做。');
        expect(completed, isFalse);
        harness.events.add(_delta('${jsonEncode(_create())}]}'));
        await _flush();
        expect(completed, isFalse);
        expect(text.join(), isNot(contains('requirements')));
        harness.events.add(_done);

        final draft = await result.timeout(_timeout);
        expect(draft!.creationIntent!.toJson(), _create());
        expect(draft.utterances.single.text, text.join());
        expect(harness.client.calls, 1);
        await harness.close();
      }
    },
  );

  test(
    'reply-first text callback handles partial escaped characters',
    () async {
      final harness = _Harness(presentation: false);
      final text = <String>[];
      final result = harness.start(onReplyTextDelta: text.add);
      harness.events.add(_delta(r'{"reply":"\u4'));
      await _flush();
      expect(text, isEmpty);
      harness.events.add(_delta(r'f60\u597d。\uD83D'));
      await _flush();
      expect(text.join(), '你好。');
      harness.events.add(
        _delta(
          r'\uDE42","actions":[{"type":"creation.intent","mode":"none"}]}',
        ),
      );
      await _flush();
      expect(text.join(), '你好。🙂');
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.reply, text.join());
      await harness.close();
    },
  );

  test(
    'actions-first and nested or quoted fake keys never enter text callback',
    () async {
      final harness = _Harness(presentation: true);
      final text = <String>[];
      final result = harness.start(onReplyTextDelta: text.add);
      harness.events.add(
        _delta(
          jsonEncode({
            'actions': [
              {..._terminal(), 'text': '{"reply":"quoted text only"}'},
              _create(),
            ],
            'reply': '{"reply":"quoted text only"}',
          }),
        ),
      );
      await _flush();
      expect(text, isEmpty);
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.creationIntent!.toJson(), _create());
      expect(text, isEmpty);
      await harness.close();
    },
  );

  test(
    'duplicate reply root is rejected without streaming the second text',
    () async {
      final harness = _Harness(presentation: false);
      final text = <String>[];
      final result = harness.start(onReplyTextDelta: text.add);
      harness.events.add(_delta('{"reply":"first",'));
      await _flush();
      expect(text, ['first']);
      harness.events.add(_delta('"reply":"never publish","actions":[]}'));
      harness.events.add(_done);

      await expectLater(
        result,
        throwsA(isA<ConversationReplyProtocolException>()),
      );
      expect(text, ['first']);
      expect(harness.admitted, isEmpty);
      await harness.close();
    },
  );

  test(
    'cancelled transient text cannot publish remaining metadata or reply',
    () async {
      final cancelled = Completer<void>();
      final harness = _Harness(presentation: true, cancelled: cancelled.future);
      final text = <String>[];
      final result = harness.start(onReplyTextDelta: text.add);
      harness.events.add(_delta('{"reply":"正在听你说。'));
      await _flush();
      cancelled.complete();
      expect(await result.timeout(_timeout), isNull);
      harness.events.add(
        _delta('这是旧消息。","actions":[${jsonEncode(_create())}]}'),
      );
      harness.events.add(_done);
      await _flush();

      expect(text, ['正在听你说。']);
      expect(harness.admitted, isEmpty);
      await harness.close();
    },
  );

  test(
    'reply completion flushes a short sentence before intent metadata',
    () async {
      final harness = _Harness(presentation: false);
      final steps = <String>[];
      var completed = false;
      var textCompletions = 0;
      final result = harness.start(
        onReplyTextDelta: (delta) => steps.add('text:$delta'),
        onReplyTextComplete: () {
          textCompletions++;
          steps.add('text-complete');
        },
      )..then((_) => completed = true);
      harness.events.add(_delta('{"reply":"Hi'));
      await _flush();
      expect(steps, ['text:Hi']);
      expect(textCompletions, 0);
      harness.events.add(_delta('","actions":['));
      await _flush();
      expect(steps, ['text:Hi', 'text-complete']);
      expect(textCompletions, 1);
      expect(completed, isFalse);
      expect(harness.admitted, isEmpty);
      harness.events.add(_delta('{"type":"creation.intent","mode":"none"}]}'));
      await _flush();
      expect(textCompletions, 1);
      expect(completed, isFalse);
      harness.events.add(_done);

      final draft = await result.timeout(_timeout);
      expect(draft!.reply, 'Hi');
      expect(textCompletions, 1);
      await harness.close();
    },
  );
}

Map<String, Object?> _create() => {
  'type': 'creation.intent',
  'mode': 'create',
  'kind': 'utility',
  'requirements': '把我的声音变成可触摸的色彩记忆，可以保存和再次打开。',
};

Map<String, Object?> _terminal() => {
  'type': 'reply.utterance',
  'text': '我按刚才的想法来做。',
  'after': 'finish',
};

List<Map<String, Object?>> _utterances() => [
  {'type': 'reply.utterance', 'text': '理解了。', 'after': 'continue'},
  {'type': 'reply.utterance', 'text': '我按这个想法来做。', 'after': 'optional'},
  _terminal(),
];

Map<String, Object?> _envelope(List<Map<String, Object?>> actions) => {
  'actions': actions,
  'reply': '理解了，按刚才的想法来做。',
};

LLMStreamEvent _delta(String text) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text}));

LLMStreamEvent _typed(Map<String, Object?> action) =>
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action));

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _Harness {
  _Harness({
    required bool presentation,
    Future<void>? cancelled,
    this.allowRawPrefixes = false,
  }) : cancelled = cancelled ?? Completer<void>().future {
    client = presentation
        ? _PresentationClient(events.stream)
        : _RawClient(events.stream);
    generator = ConversationReplyGenerator(client);
  }

  final events = StreamController<LLMStreamEvent>(sync: true);
  final admitted = <ConversationUtteranceDraft>[];
  final Future<void> cancelled;
  final bool allowRawPrefixes;
  late final _RawClient client;
  late final ConversationReplyGenerator generator;

  Future<ConversationReplyDraft?> start({
    void Function(String)? onReplyTextDelta,
    void Function()? onReplyTextComplete,
  }) => generator.generate(
    messages: [Message.user('按你刚刚提的想法来做')],
    cancelled: cancelled,
    onUtterance: admitted.add,
    requireRawEnvelopeForTypedEvents: true,
    allowRawPrefixes: allowRawPrefixes,
    onReplyTextDelta: onReplyTextDelta,
    onReplyTextComplete: onReplyTextComplete,
  );

  Future<void> close() async {
    if (!events.isClosed) await events.close();
    await generator.drained.timeout(_timeout);
  }
}

class _RawClient extends LLMClient {
  _RawClient(this.events);

  final Stream<LLMStreamEvent> events;
  int calls = 0;

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls++;
    return events;
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('Unexpected second model request');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected second model request');
}

class _PresentationClient extends _RawClient
    implements PresentationStreamingLLMClient {
  _PresentationClient(super.events);

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
  }) => throw StateError('Unexpected second model request');
}
