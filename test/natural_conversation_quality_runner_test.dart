import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_quality.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_quality_catalog.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_quality_runner.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

void main() {
  test(
    'runner preserves context and captures semantic pause and body cue',
    () async {
      final client = _QualityClient(
        Stream.fromIterable([
          LLMStreamEvent(
            event: 'reply.delta',
            data: jsonEncode({
              'delta': jsonEncode({
                'reply': '先吃点清淡的。要不要看看附近的粥店？',
                'actions': [
                  {
                    'type': 'reply.utterance',
                    'text': '先吃点清淡的。',
                    'after': 'continue',
                    'pause': 'brief',
                    'body': {
                      'mood': 'calm',
                      'gesture': 'none',
                      'gaze': 'user',
                      'style': 'subtle',
                    },
                  },
                  {
                    'type': 'reply.utterance',
                    'text': '要不要看看附近的粥店？',
                    'after': 'yield',
                  },
                ],
              }),
            }),
          ),
          const LLMStreamEvent(event: 'done', data: '[DONE]'),
        ]),
      );
      final scenario = naturalConversationQualityScenarios.singleWhere(
        (item) => item.id == 'zh.corrected_preference',
      );

      final observation = await NaturalConversationModelScenarioRunner(
        client,
      ).run(scenario, timeout: const Duration(seconds: 1));

      expect(observation.outcome, NaturalConversationQualityOutcome.completed);
      expect(observation.usesUtteranceProtocol, isTrue);
      expect(observation.utterances, hasLength(2));
      expect(observation.utterances.first.pause, 'brief');
      expect(observation.utterances.first.body?['gesture'], 'none');
      expect(client.messages!.last.content, scenario.userText);
      expect(
        client.messages!.any(
          (message) => message.content.contains('我今天想吃点辣的。'),
        ),
        isTrue,
      );
      expect(
        client.messages!
            .where((message) => message.role == 'system')
            .last
            .content,
        contains('用户不必下达动作命令'),
      );
    },
  );

  test('suite times out and cancels the active provider stream', () async {
    var cancellationObserved = false;
    final controller = StreamController<LLMStreamEvent>(
      onCancel: () => cancellationObserved = true,
    );
    final runner = NaturalConversationModelScenarioRunner(
      _QualityClient(controller.stream),
    );
    final result = await const NaturalConversationQualitySuite(
      scenarioTimeout: Duration(milliseconds: 20),
      cleanupTimeout: Duration(milliseconds: 100),
    ).run(runner, scenarios: [naturalConversationQualityScenarios.first]);

    expect(
      result.samples.single.observation.outcome,
      NaturalConversationQualityOutcome.timedOut,
    );
    expect(cancellationObserved, isTrue);
    await controller.close();
  });

  test('sanitized receipt omits reply and body tokens', () async {
    const privateReply = 'private reply marker';
    const privateGesture = 'private_gesture_marker';
    final result = await const NaturalConversationQualitySuite().run(
      _StaticRunner(
        NaturalConversationQualityObservation.completed(
          aggregateReply: privateReply,
          usesUtteranceProtocol: true,
          utterances: [
            NaturalConversationQualityUtterance(
              text: privateReply,
              after: 'finish',
              pause: 'brief',
              body: const {'gesture': privateGesture},
            ),
          ],
        ),
      ),
      scenarios: [naturalConversationQualityScenarios.first],
    );

    final sanitized = jsonEncode(result.toSanitizedJson());
    final human = jsonEncode(result.toHumanReviewJson());
    expect(sanitized, isNot(contains(privateReply)));
    expect(sanitized, isNot(contains(privateGesture)));
    expect(sanitized, contains('"semanticPauseCount":1'));
    expect(human, contains(privateReply));
  });
}

class _QualityClient extends LLMClient {
  _QualityClient(this.events);

  final Stream<LLMStreamEvent> events;
  List<Message>? messages;

  @override
  Duration get defaultTimeout => const Duration(seconds: 2);

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    this.messages = messages;
    return events;
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected chat');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected generateJson');
}

class _StaticRunner implements NaturalConversationQualityScenarioRunner {
  _StaticRunner(this.observation);

  final NaturalConversationQualityObservation observation;

  @override
  Future<NaturalConversationQualityObservation> run(
    NaturalConversationQualityScenario scenario, {
    required Duration timeout,
  }) async => observation;

  @override
  Future<void> cancelAndDrain() async {}
}
