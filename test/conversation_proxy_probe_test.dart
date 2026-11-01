import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_proxy_probe.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

void main() {
  const probe = ConversationProxyProbe();
  const fixture = ConversationProxyProbe.expectedResponse;

  test(
    'uses one fixed request and validates fragmented three-utterance JSON',
    () async {
      final client = _ProbeClient(
        Stream.fromIterable([
          _delta(fixture.substring(0, 71)),
          _delta(fixture.substring(71, 190)),
          _delta(fixture.substring(190)),
          const LLMStreamEvent(event: 'done', data: '[DONE]'),
        ]),
      );

      final result = await probe.run(client);

      expect(client.calls, 1);
      expect(client.messages!.map((message) => message.role), [
        'system',
        'user',
      ]);
      expect(
        client.messages!.first.content,
        contains('[maaso_mode:low_latency_voice]'),
      );
      expect(client.messages!.last.content, fixture);
      expect(client.timeout, const Duration(seconds: 30));
      expect(result.status, ConversationProxyProbeStatus.jsonSupported);
      expect(result.supportsContract, isTrue);
      expect(result.utteranceCount, 3);
      expect(result.deltaEvents, 3);
      expect(result.doneObserved, isTrue);
      expect(result.streamClosed, isFalse);
    },
  );

  test(
    'records EOF without claiming the client exposed a done event',
    () async {
      final result = await probe.run(
        _ProbeClient(Stream.value(_delta(fixture))),
      );

      expect(result.status, ConversationProxyProbeStatus.jsonSupported);
      expect(result.doneObserved, isFalse);
      expect(result.streamClosed, isTrue);
    },
  );

  test(
    'validates direct typed utterances with and without redundant type',
    () async {
      final actions = _fixtureActions();
      actions[1].remove('type');
      final result = await probe.run(
        _ProbeClient(Stream.fromIterable(actions.map(_typed))),
      );

      expect(result.status, ConversationProxyProbeStatus.typedSupported);
      expect(result.typedEvents, 3);
      expect(result.utteranceCount, 3);
      expect(result.supportsContract, isTrue);
    },
  );

  test(
    'accepts typed events alongside only the matching aggregate delta',
    () async {
      final result = await probe.run(
        _ProbeClient(
          Stream.fromIterable([
            _delta('Alpha.Beta?Gamma.'),
            ..._fixtureActions().map(_typed),
          ]),
        ),
      );

      expect(result.status, ConversationProxyProbeStatus.typedSupported);
    },
  );

  test(
    'drops only transport metadata and returns no payload, headers, or exception text',
    () async {
      const privateMarker = 'private-token-header-and-response-marker';
      final result = await probe.run(
        _ProbeClient(
          Stream.fromIterable([
            const LLMStreamEvent(event: 'trace', data: privateMarker),
            const LLMStreamEvent(event: 'usage', data: privateMarker),
            const LLMStreamEvent(event: 'ping', data: privateMarker),
            const LLMStreamEvent(event: 'heartbeat', data: privateMarker),
            _delta(fixture),
          ]),
        ),
      );

      expect(result.supportsContract, isTrue);
      expect(result.ignoredEvents, 4);
      final receipt = jsonEncode(result.toJson());
      expect(receipt, isNot(contains(privateMarker)));
      expect(receipt, isNot(contains('Alpha.')));
      expect(receipt, isNot(contains('thinking')));
      expect(
        result.toJson().keys,
        unorderedEquals([
          'status',
          'supportsContract',
          'doneObserved',
          'streamClosed',
          'deltaEvents',
          'typedEvents',
          'ignoredEvents',
          'utteranceCount',
        ]),
      );
    },
  );

  test(
    'behavioral mixed streams fail without exposing their payloads',
    () async {
      const privateMarker = 'private-behavior-payload';
      for (final eventName in [
        'body.intent',
        'task.handoff',
        'task.signal',
        'skill.call',
        'unknown.behavior',
      ]) {
        for (final payloadEvents in [
          [_delta(fixture)],
          _fixtureActions().map(_typed).toList(),
        ]) {
          final result = await probe.run(
            _ProbeClient(
              Stream.fromIterable([
                ...payloadEvents,
                LLMStreamEvent(event: eventName, data: privateMarker),
                const LLMStreamEvent(event: 'done', data: '[DONE]'),
              ]),
            ),
          );

          expect(result.status, ConversationProxyProbeStatus.invalidResponse);
          expect(result.supportsContract, isFalse);
          expect(result.errorCode, 'non_presentation_event');
          expect(result.ignoredEvents, 0);
          expect(result.utteranceCount, 0);
          final receipt = jsonEncode(result.toJson());
          expect(receipt, isNot(contains(privateMarker)));
          expect(receipt, isNot(contains('Alpha.')));
          expect(receipt, isNot(contains(eventName)));
        }
      }
    },
  );

  test('a behavioral done payload cannot end validation early', () async {
    final result = await probe.run(
      _ProbeClient(
        Stream.fromIterable([
          _delta(fixture),
          const LLMStreamEvent(event: 'body.intent', data: '[DONE]'),
        ]),
      ),
    );

    expect(result.supportsContract, isFalse);
    expect(result.errorCode, 'non_presentation_event');
    expect(result.doneObserved, isFalse);
  });

  test(
    'server error after a valid payload cannot pass and leaks no detail',
    () async {
      final result = await probe.run(
        _ProbeClient(
          Stream.fromIterable([
            _delta(fixture),
            const LLMStreamEvent(
              event: 'error',
              data: '{"code":"secret-server-code","message":"private-body"}',
            ),
          ]),
        ),
      );

      expect(result.status, ConversationProxyProbeStatus.serverError);
      expect(result.errorCode, 'server_error');
      expect(result.supportsContract, isFalse);
      expect(jsonEncode(result.toJson()), isNot(contains('private-body')));
      expect(
        jsonEncode(result.toJson()),
        isNot(contains('secret-server-code')),
      );
    },
  );

  test('transport error is reduced to a fixed code', () async {
    final result = await probe.run(
      _ProbeClient(Stream.error(StateError('Authorization: private-body'))),
    );

    expect(result.status, ConversationProxyProbeStatus.transportError);
    expect(result.errorCode, 'transport_error');
    expect(jsonEncode(result.toJson()), isNot(contains('private-body')));
  });

  test(
    'total deadline cancels a stream with no events',
    () async {
      var canceled = false;
      final stream = StreamController<LLMStreamEvent>(
        onCancel: () => canceled = true,
      );
      final result = await probe.run(
        _ProbeClient(stream.stream),
        timeout: const Duration(milliseconds: 20),
      );

      expect(result.status, ConversationProxyProbeStatus.timedOut);
      expect(result.errorCode, 'total_timeout');
      expect(canceled, isTrue);
      await stream.close();
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

  test(
    'metadata and a complete payload do not extend total deadline',
    () async {
      final stream = StreamController<LLMStreamEvent>();
      final future = probe.run(
        _ProbeClient(stream.stream),
        timeout: const Duration(milliseconds: 30),
      );
      stream.add(_delta(fixture));
      stream.add(const LLMStreamEvent(event: 'trace', data: 'still-active'));
      final activity = Timer.periodic(const Duration(milliseconds: 5), (_) {
        stream.add(const LLMStreamEvent(event: 'trace', data: 'still-active'));
      });
      try {
        final result = await future;
        expect(result.status, ConversationProxyProbeStatus.timedOut);
        expect(result.supportsContract, isFalse);
        expect(result.ignoredEvents, greaterThanOrEqualTo(1));
      } finally {
        activity.cancel();
        await stream.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

  test(
    'stuck provider cancellation cannot hold the receipt past deadline',
    () async {
      final releaseCancellation = Completer<void>();
      var cancellationStarted = false;
      final stream = StreamController<LLMStreamEvent>(
        onCancel: () {
          cancellationStarted = true;
          return releaseCancellation.future;
        },
      );
      try {
        final result = await probe.run(
          _ProbeClient(stream.stream),
          timeout: const Duration(milliseconds: 20),
        );
        expect(result.status, ConversationProxyProbeStatus.timedOut);
        expect(cancellationStarted, isTrue);
      } finally {
        releaseCancellation.complete();
        await stream.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

  for (final raw in [
    '{"reply":"Alpha.',
    '{"reply":,"actions":[]}',
    fixture.substring(0, fixture.length - 2),
  ]) {
    test('malformed or truncated JSON never passes: $raw', () async {
      final result = await probe.run(_ProbeClient(Stream.value(_delta(raw))));

      expect(
        result.status,
        ConversationProxyProbeStatus.invalidOrTruncatedResponse,
      );
      expect(result.supportsContract, isFalse);
      expect(result.utteranceCount, 0);
    });
  }

  test(
    'aggregate reply alone is not proof actions survived the proxy',
    () async {
      final result = await probe.run(
        _ProbeClient(
          Stream.value(_delta('{"reply":"Alpha.Beta?Gamma.","actions":[]}')),
        ),
      );

      expect(result.status, ConversationProxyProbeStatus.invalidResponse);
      expect(result.errorCode, 'fixture_mismatch');
    },
  );

  test('missing third typed utterance cannot pass', () async {
    final result = await probe.run(
      _ProbeClient(Stream.fromIterable(_fixtureActions().take(2).map(_typed))),
    );

    expect(result.supportsContract, isFalse);
    expect(result.utteranceCount, 0);
  });

  test('body metadata loss is a fixture mismatch', () async {
    final actions = _fixtureActions();
    actions.first.remove('body');
    final result = await probe.run(
      _ProbeClient(Stream.fromIterable(actions.map(_typed))),
    );

    expect(result.status, ConversationProxyProbeStatus.invalidResponse);
    expect(result.errorCode, 'fixture_mismatch');
  });

  test('typed protocol cannot smuggle another action type', () async {
    final actions = _fixtureActions();
    actions.first['type'] = 'skill.call';
    final result = await probe.run(
      _ProbeClient(Stream.fromIterable(actions.map(_typed))),
    );

    expect(result.supportsContract, isFalse);
  });

  test(
    'typed events reject invalid JSON and more than three actions',
    () async {
      for (final events in [
        [const LLMStreamEvent(event: 'reply.utterance', data: '{broken')],
        [..._fixtureActions().map(_typed), _typed(_fixtureActions().last)],
      ]) {
        final result = await probe.run(
          _ProbeClient(Stream.fromIterable(events)),
        );
        expect(result.status, ConversationProxyProbeStatus.invalidResponse);
        expect(result.errorCode, 'invalid_typed_payload');
      }
    },
  );

  test('response and metadata event budgets are bounded', () async {
    final oversized = await probe.run(
      _ProbeClient(
        Stream.value(
          _delta('x' * ConversationProxyProbe.maxResponseCharacters),
        ),
      ),
    );
    final tooManyEvents = await probe.run(
      _ProbeClient(
        Stream.fromIterable(
          List.filled(
            ConversationProxyProbe.maxEvents + 1,
            const LLMStreamEvent(event: 'trace', data: ''),
          ),
        ),
      ),
    );

    expect(oversized.status, ConversationProxyProbeStatus.responseLimit);
    expect(oversized.errorCode, 'response_limit');
    expect(tooManyEvents.status, ConversationProxyProbeStatus.responseLimit);
    expect(tooManyEvents.errorCode, 'event_limit');
  });

  test('empty stream and timeout outside bounds are explicit', () async {
    final client = _ProbeClient(const Stream.empty());
    final result = await probe.run(client);
    expect(result.status, ConversationProxyProbeStatus.emptyResponse);
    expect(
      () => probe.run(client, timeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => probe.run(client, timeout: const Duration(seconds: 31)),
      throwsArgumentError,
    );
    expect(client.calls, 1);
  });
}

LLMStreamEvent _delta(String text) =>
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': text}));

LLMStreamEvent _typed(Map<String, Object?> action) =>
    LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action));

List<Map<String, Object?>> _fixtureActions() =>
    ((jsonDecode(ConversationProxyProbe.expectedResponse) as Map)['actions']
            as List)
        .map((action) => Map<String, Object?>.from(action as Map))
        .toList();

class _ProbeClient extends LLMClient {
  _ProbeClient(this.events);

  final Stream<LLMStreamEvent> events;
  int calls = 0;
  List<Message>? messages;
  Duration? timeout;

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls++;
    this.messages = messages;
    this.timeout = timeout;
    return events;
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('Probe must use only streamChatEvents.');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Probe must use only streamChatEvents.');
}
