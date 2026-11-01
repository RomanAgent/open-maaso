import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_generator.dart';
import 'package:maaso/src/features/agent/application/intent/creation_intent.dart';
import 'package:maaso/src/features/agent/application/intent/lookup_intent.dart';
import 'package:maaso/src/features/agent/application/intent/lookup_intent_prompt.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

const _none = <String, Object?>{'type': 'creation.intent', 'mode': 'none'};
const _search = <String, Object?>{
  'type': 'lookup.intent',
  'mode': 'search',
  'query': '杭州今天的天气',
};
const _clarify = <String, Object?>{
  'type': 'lookup.intent',
  'mode': 'clarify',
  'question': '你想查哪个城市的天气？',
};
const _done = LLMStreamEvent(event: 'done', data: '[DONE]');

void main() {
  const decoder = ConversationReplyDecoder();

  test('search and clarification preserve bounded, normalized data', () {
    final search = LookupIntent.fromJson({
      ..._search,
      'query': '  weather now  ',
    });
    expect(search.mode, LookupIntentMode.search);
    expect(search.query, 'weather now');
    expect(search.question, isEmpty);
    expect(search.toJson(), {..._search, 'query': 'weather now'});
    final clarify = LookupIntent.fromJson(_clarify);
    expect(clarify.mode, LookupIntentMode.clarify);
    expect(clarify.query, isEmpty);
    expect(clarify.question, _clarify['question']);
    expect(clarify.toJson(), _clarify);
    expect(
      LookupIntent.fromJson({
        ..._search,
        'query': 'q' * LookupIntent.maxQueryCharacters,
      }).query.length,
      LookupIntent.maxQueryCharacters,
    );
  });

  test('current location is bounded query data, never a permission grant', () {
    final lookup = LookupIntent.fromJson({
      ..._search,
      'useCurrentLocation': true,
    });
    expect(lookup.useCurrentLocation, isTrue);
    expect(lookup.toJson(), {..._search, 'useCurrentLocation': true});
    expect(LookupIntent.fromJson(_search).useCurrentLocation, isFalse);
    final reply = decoder.decode(
      _envelope([
        {..._search, 'useCurrentLocation': true},
      ]),
    );
    expect(reply.lookupIntent!.useCurrentLocation, isTrue);
  });

  final invalid = <Map<String, Object?>>[
    {..._search, 'mode': 'none'},
    {..._search, 'query': ''},
    {..._search, 'query': '  '},
    {..._search, 'query': 3},
    {..._search, 'query': 'q' * (LookupIntent.maxQueryCharacters + 1)},
    {..._search, 'query': 'weather\u0000'},
    {..._search, 'question': 'where?'},
    {..._search, 'confirmed': true},
    {..._clarify, 'question': ''},
    {..._clarify, 'question': 'q' * (LookupIntent.maxQuestionCharacters + 1)},
    {..._clarify, 'query': 'weather'},
    {..._search, 'useCurrentLocation': null},
    {..._search, 'useCurrentLocation': 'true'},
    {..._clarify, 'useCurrentLocation': true},
    {..._search, 'latitude': 31.2, 'longitude': 121.4},
  ];
  for (var index = 0; index < invalid.length; index++) {
    test('rejects malformed or authority-like lookup data $index', () {
      expect(
        () => LookupIntent.fromJson(invalid[index]),
        throwsFormatException,
      );
      expect(
        () => decoder.decode(_envelope([invalid[index]])),
        throwsA(_conversationCode('invalid_lookup_intent')),
      );
      expect(
        () => AgentActionEnvelope.parse(_envelope([invalid[index]])),
        throwsA(_actionCode('lookup_intent_invalid')),
      );
    });
  }

  for (final intent in [_search, _clarify]) {
    test('lookup ${intent['mode']} is optional data before creation.none', () {
      final raw = _envelope([intent, _none]);
      final value = decoder.decode(raw);
      expect(value.lookupIntent!.toJson(), intent);
      expect(value.creationIntent!.mode, CreationIntentMode.none);
      expect(value.utterances.single.text, 'reply');
      expect(value.usesUtteranceProtocol, isFalse);
      final actionEnvelope = AgentActionEnvelope.parse(raw);
      expect(actionEnvelope.validateLookupIntentActions()!.toJson(), intent);
    });
  }

  test(
    'lookup follows all presentation units and preserves their ordering',
    () {
      final reply = decoder.decode(
        _envelope([
          {'type': 'reply.utterance', 'text': 'Which city?', 'after': 'yield'},
          _clarify,
          _none,
        ]),
      );
      expect(reply.usesUtteranceProtocol, isTrue);
      expect(reply.utterances.single.after, ConversationAfter.yieldToUser);
      expect(reply.lookupIntent!.mode, LookupIntentMode.clarify);
    },
  );

  test(
    'ordinary conversation and quoted lookup examples never create intent',
    () {
      for (final raw in [
        _envelope([], reply: '今天心情不错'),
        _envelope([_none], reply: 'hello'),
        _envelope([], reply: jsonEncode(_search)),
      ]) {
        expect(decoder.decode(raw).lookupIntent, isNull);
        expect(
          AgentActionEnvelope.parse(raw).validateLookupIntentActions(),
          isNull,
        );
      }
    },
  );

  test('rejects duplicate metadata and presentation after metadata', () {
    expect(
      () => decoder.decode(_envelope([_search, _clarify])),
      throwsA(_conversationCode('duplicate_lookup_intent')),
    );
    expect(
      () => AgentActionEnvelope.parse(_envelope([_search, _search])),
      throwsA(_actionCode('lookup_intent_duplicate')),
    );
    final misplaced = _envelope([
      _search,
      {'type': 'reply.utterance', 'text': 'later text', 'after': 'finish'},
    ]);
    expect(
      () => decoder.decode(misplaced),
      throwsA(_conversationCode('presentation_after_lookup_intent')),
    );
    expect(
      () => AgentActionEnvelope.parse(misplaced),
      throwsA(_actionCode('lookup_intent_not_terminal')),
    );
    expect(
      () => decoder.decode(_envelope([_none, _search])),
      throwsA(_conversationCode('creation_intent_must_be_last')),
    );
  });

  test('active creation and lookup cannot share admission data', () {
    final create = <String, Object?>{
      'type': 'creation.intent',
      'mode': 'create',
      'kind': 'game',
      'requirements': 'Make a game',
    };
    for (final lookup in [_search, _clarify]) {
      final raw = _envelope([lookup, create]);
      expect(
        () => decoder.decode(raw),
        throwsA(_conversationCode('conflicting_semantic_intents')),
      );
      expect(
        () => AgentActionEnvelope.parse(raw),
        throwsA(_actionCode('conflicting_semantic_intents')),
      );
    }
    expect(
      decoder.decode(_envelope([create])).creationIntent!.mode,
      CreationIntentMode.create,
    );
  });

  for (final scope in [
    AgentActionScope.proactivePresence,
    AgentActionScope.notificationInteraction,
  ]) {
    test('${scope.name} cannot carry an executable lookup request', () {
      expect(scope.allowsActionType('lookup.intent'), isFalse);
      expect(
        () => AgentActionEnvelope.parse(_envelope([_search]), scope: scope),
        throwsA(_actionCode('lookup_intent_scope_not_allowed')),
      );
      final direct = AgentActionEnvelope(
        reply: 'hello',
        actions: const [AgentAction(type: 'lookup.intent', data: _search)],
        scope: scope,
      );
      expect(
        direct.validateLookupIntentActions,
        throwsA(_actionCode('lookup_intent_scope_not_allowed')),
      );
    });
  }

  for (final text in ['我来查杭州的实时天气。', 'I will check the weather in Hangzhou.']) {
    test(
      'reply streams before lookup metadata using one request: $text',
      () async {
        final events = StreamController<LLMStreamEvent>(sync: true);
        final client = _PresentationClient(events.stream);
        final generator = ConversationReplyGenerator(client);
        final deltas = <String>[];
        var complete = false;
        final result = generator.generate(
          messages: [Message.user('weather')],
          cancelled: Completer<void>().future,
          requireRawEnvelopeForTypedEvents: true,
          onReplyTextDelta: deltas.add,
        )..then((_) => complete = true);
        final encodedReply = jsonEncode(text);
        events.add(_delta('{"reply":${encodedReply.substring(0, 3)}'));
        await Future<void>.delayed(Duration.zero);
        expect(deltas.join(), text.substring(0, 2));
        expect(complete, isFalse);
        events.add(_delta('${encodedReply.substring(3)},"actions":['));
        events.add(_delta('${jsonEncode(_search)},${jsonEncode(_none)}]}'));
        await Future<void>.delayed(Duration.zero);
        expect(deltas.join(), text);
        expect(
          complete,
          isFalse,
          reason: 'metadata needs the protocol done marker',
        );
        events.add(_done);
        final reply = await result;
        expect(reply!.lookupIntent!.query, _search['query']);
        expect(client.calls, 1);
        await generator.drained;
        await events.close();
      },
    );
  }

  test(
    'cancelling before protocol done never exposes lookup metadata',
    () async {
      final events = StreamController<LLMStreamEvent>(sync: true);
      final cancelled = Completer<void>();
      final generator = ConversationReplyGenerator(
        _PresentationClient(events.stream),
      );
      final result = generator.generate(
        messages: [Message.user('weather')],
        cancelled: cancelled.future,
      );
      events.add(_delta(_envelope([_search, _none])));
      cancelled.complete();
      expect(await result, isNull);
      await generator.drained;
      await events.close();
    },
  );

  test(
    'typed presentation mirrors do not drop the verified raw lookup',
    () async {
      final events = StreamController<LLMStreamEvent>(sync: true);
      final generator = ConversationReplyGenerator(
        _PresentationClient(events.stream),
      );
      final result = generator.generate(
        messages: [Message.user('weather')],
        cancelled: Completer<void>().future,
        requireRawEnvelopeForTypedEvents: true,
      );
      final utterance = <String, Object?>{
        'type': 'reply.utterance',
        'text': 'Which city?',
        'after': 'yield',
      };
      events.add(
        _delta('{"reply":"Which city?","actions":[${jsonEncode(utterance)}'),
      );
      events.add(
        LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(utterance)),
      );
      events.add(_delta(',${jsonEncode(_clarify)},${jsonEncode(_none)}]}'));
      events.add(_done);
      final reply = await result;
      expect(reply!.lookupIntent!.mode, LookupIntentMode.clarify);
      expect(reply.utterances.single.text, 'Which city?');
      await generator.drained;
      await events.close();
    },
  );

  for (final event in [
    LLMStreamEvent(event: 'lookup.intent', data: jsonEncode(_search)),
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(_search)),
  ]) {
    test('unverified typed ${event.event} cannot admit lookup', () async {
      final events = StreamController<LLMStreamEvent>(sync: true);
      final generator = ConversationReplyGenerator(
        _PresentationClient(events.stream),
      );
      final result = generator.generate(
        messages: [Message.user('weather')],
        cancelled: Completer<void>().future,
      );
      final rejected = expectLater(
        result,
        throwsA(isA<ConversationReplyProtocolException>()),
      );
      events.add(event);
      await rejected;
      await generator.drained;
      await events.close();
    });
  }

  test(
    'a complete raw lookup without done is still a truncated response',
    () async {
      final events = StreamController<LLMStreamEvent>(sync: true);
      final generator = ConversationReplyGenerator(
        _PresentationClient(events.stream),
      );
      final result = generator.generate(
        messages: [Message.user('weather')],
        cancelled: Completer<void>().future,
      );
      final rejected = expectLater(
        result,
        throwsA(_conversationCode('presentation_stream_truncated')),
      );
      events.add(_delta(_envelope([_search, _none])));
      await events.close();
      await rejected;
      await generator.drained;
    },
  );

  test(
    'both language contracts keep optional metadata after streamed reply',
    () {
      for (final locale in [AppLocale.zh, AppLocale.en]) {
        final policy = lookupIntentPolicyPrompt(locale);
        final contract = lookupIntentOutputContract(locale);
        expect(policy, contains('lookup.intent'));
        expect(policy, contains('clarify'));
        expect(contract, contains('"reply"'));
        expect(contract, contains('2048'));
        expect(contract, contains('400'));
        expect(contract, contains('creation.intent'));
        expect(contract, contains('none'));
        final natural = lookupIntentOutputContract(locale, replyFirst: false);
        expect(natural, contains('actions-first'));
        expect(natural, contains('{"actions":[...],"reply":"..."}'));
        expect(natural, contains('reply.utterance'));
        expect(natural, isNot(contains('{"reply":"...","actions":[...]}')));
      }
    },
  );
}

String _envelope(
  List<Map<String, Object?>> actions, {
  String reply = 'reply',
}) => jsonEncode({'reply': reply, 'actions': actions});

Matcher _conversationCode(String code) =>
    isA<ConversationReplyProtocolException>().having(
      (e) => e.code,
      'code',
      code,
    );

Matcher _actionCode(String code) =>
    isA<AgentActionProtocolException>().having((e) => e.code, 'code', code);

LLMStreamEvent _delta(String value) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': value}));

class _PresentationClient extends LLMClient
    implements PresentationStreamingLLMClient {
  _PresentationClient(this.events);
  final Stream<LLMStreamEvent> events;
  var calls = 0;

  @override
  Duration get defaultTimeout => const Duration(seconds: 3);

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls++;
    return events;
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected extra model request');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected classifier request');
}
