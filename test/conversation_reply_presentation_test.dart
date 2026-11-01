import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  testWidgets('each durable utterance replaces the shared current bubble', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    final shown = <String>[];
    final subscription = service.changes.listen(
      (snapshot) => shown.add(snapshot.text),
    );
    addTearDown(subscription.cancel);

    service.presentConversationUtterance('turn-a', '今天呀，嗯，我想想。');
    await tester.pump();
    final firstGeneration = service.snapshot.generation;
    service.presentConversationUtterance('turn-a', '猪脚饭？');
    await tester.pump();
    expect(service.snapshot.text, '猪脚饭？');
    expect(service.snapshot.generation, greaterThan(firstGeneration));
    service.presentConversationUtterance('turn-a', '或者看你想吃啥，我都行。');
    await tester.pump();

    expect(shown, ['今天呀，嗯，我想想。', '猪脚饭？', '或者看你想吃啥，我都行。']);
    expect(service.snapshot.text, shown.last);
    expect(service.snapshot.text, isNot(contains('猪脚饭')));
  });

  testWidgets('speaking false during a conversation gap never dismisses it', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance(
      'turn-gap',
      '猪脚饭？',
      utteranceId: 'unit-0',
    );
    service.setConversationSpeechActivity(
      'turn-gap',
      'unit-0',
      isSpeaking: true,
    );
    await tester.pump();
    expect(service.snapshot.isSpeaking, isTrue);
    service.setConversationSpeechActivity(
      'turn-gap',
      'unit-0',
      isSpeaking: false,
    );
    await tester.pump();
    expect(service.snapshot.isSpeaking, isFalse);

    // Exceeds both the old spoken dismissal and the fallback TTL, but the
    // optional invitation is still part of this open logical turn.
    await tester.pump(const Duration(seconds: 6));
    expect(service.snapshot.text, '猪脚饭？');
    expect(service.snapshot.isVisible, isTrue);

    service.presentConversationUtterance('turn-gap', '或者吃点别的也可以。');
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    await tester.pump(const Duration(seconds: 2));
    expect(service.snapshot.text, '或者吃点别的也可以。');
    expect(service.snapshot.isVisible, isTrue);
  });

  testWidgets('the fallback TTL starts only when the whole turn completes', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance('turn-complete', '第一句。');
    await tester.pump(const Duration(seconds: 5));
    expect(service.snapshot.isVisible, isTrue);
    service.presentConversationUtterance('turn-complete', '最后这一句。');
    await tester.pump(const Duration(seconds: 5));
    expect(service.snapshot.text, '最后这一句。');

    service.completeConversationTurn('turn-complete', cancelled: false);
    await tester.pump(const Duration(milliseconds: 999));
    expect(service.snapshot.text, '最后这一句。');
    await tester.pump(const Duration(milliseconds: 1));
    expect(service.snapshot.isVisible, isFalse);
  });

  testWidgets('cancelling an older turn cannot clear the current utterance', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance('old-turn', '旧问题的回答。');
    service.presentConversationUtterance('new-turn', '正在回应新问题。');
    final currentGeneration = service.snapshot.generation;
    service.completeConversationTurn('old-turn', cancelled: true);
    EventBus().fire(
      AgentReplyAbortedEvent(turnId: 'old-turn', agentId: 'self'),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(service.snapshot.text, '正在回应新问题。');
    expect(service.snapshot.generation, currentGeneration);

    service.completeConversationTurn('new-turn', cancelled: true);
    expect(service.snapshot.isVisible, isFalse);
    expect(service.snapshot.isSpeaking, isFalse);
  });

  testWidgets('a compatibility aggregate cannot publish a fourth bubble', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    final shown = <String>[];
    final subscription = service.changes.listen(
      (snapshot) => shown.add(snapshot.text),
    );
    addTearDown(subscription.cancel);
    for (final text in ['今天呀，嗯，我想想。', '猪脚饭？', '或者看你想吃啥，我都行。']) {
      service.presentConversationUtterance('three-parts', text);
      await tester.pump();
    }
    final expected = List<String>.of(shown);
    const aggregate = '今天呀，嗯，我想想。猪脚饭？或者看你想吃啥，我都行。';
    EventBus().fire(
      AgentReplyCompletedEvent(
        aggregate,
        turnId: 'three-parts',
        agentId: 'self',
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(shown, expected);
    expect(service.snapshot.text, '或者看你想吃啥，我都行。');
    expect(service.snapshot.isVisible, isTrue);

    service.completeConversationTurn('three-parts', cancelled: false);
    await tester.pump(const Duration(milliseconds: 500));
    EventBus().fire(
      AgentReplyCompletedEvent(
        aggregate,
        turnId: 'three-parts',
        agentId: 'self',
      ),
    );
    await tester.pump();
    expect(shown, expected);
    await tester.pump(const Duration(milliseconds: 500));
    expect(service.snapshot.isVisible, isFalse);
  });

  testWidgets(
    'the previous turn TTL cannot dismiss a newer open conversation',
    (tester) async {
      final service = _service();
      addTearDown(service.closeLifecycle);
      service.presentConversationUtterance('finished-turn', '旧回合结束了。');
      service.completeConversationTurn('finished-turn', cancelled: false);
      await tester.pump(const Duration(milliseconds: 900));

      service.presentConversationUtterance('active-turn', '新回合正在等待回应。');
      service.completeConversationTurn('finished-turn', cancelled: false);
      await tester.pump(const Duration(seconds: 2));
      expect(service.snapshot.text, '新回合正在等待回应。');
      expect(service.snapshot.isVisible, isTrue);
    },
  );

  testWidgets('only matching utterance speech can change the current bubble', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance(
      'turn-a',
      'first',
      utteranceId: 'unit-0',
    );
    service.setConversationSpeechActivity('turn-a', 'unit-0', isSpeaking: true);
    expect(service.snapshot.isSpeaking, isTrue);
    service.presentConversationUtterance(
      'turn-a',
      'second',
      utteranceId: 'unit-1',
    );
    expect(service.snapshot.isSpeaking, isFalse);
    service.setConversationSpeechActivity('turn-a', 'unit-0', isSpeaking: true);
    expect(service.snapshot.isSpeaking, isFalse);
    service.setConversationSpeechActivity('turn-a', 'unit-1', isSpeaking: true);
    service.setConversationSpeechActivity(
      'turn-a',
      'unit-0',
      isSpeaking: false,
    );
    service.setConversationSpeechActivity(
      'older-turn',
      'unit-1',
      isSpeaking: false,
    );
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    EventBus().fire(
      AgentSpeechQueuedEvent('unidentified speech', agentId: 'self'),
    );
    await tester.pump();
    expect(service.snapshot.text, 'second');
    expect(service.snapshot.isSpeaking, isTrue);
    service.setConversationSpeechActivity(
      'turn-a',
      'unit-1',
      isSpeaking: false,
    );
    expect(service.snapshot.isSpeaking, isFalse);
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    await tester.pump();
    expect(service.snapshot.isSpeaking, isFalse);
  });

  testWidgets('late audio cannot extend the completed conversation TTL', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance(
      'turn-a',
      'last',
      utteranceId: 'unit-0',
    );
    service.setConversationSpeechActivity('turn-a', 'unit-0', isSpeaking: true);
    service.setConversationSpeechActivity(
      'turn-a',
      'unit-0',
      isSpeaking: false,
    );
    service.completeConversationTurn('turn-a', cancelled: false);
    await tester.pump(const Duration(milliseconds: 999));
    service.setConversationSpeechActivity('turn-a', 'unit-0', isSpeaking: true);
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    await tester.pump();
    expect(service.snapshot.isSpeaking, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(service.snapshot.isVisible, isFalse);
  });

  testWidgets('clear rejects old typed audio and preserves standalone speech', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.closeLifecycle);
    service.presentConversationUtterance(
      'turn-a',
      'cancelled',
      utteranceId: 'unit-0',
    );
    service.completeConversationTurn('turn-a', cancelled: true);
    service.setConversationSpeechActivity('turn-a', 'unit-0', isSpeaking: true);
    expect(service.snapshot.isVisible, isFalse);
    service.presentStandaloneReply('standalone');
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    await tester.pump();
    expect(service.snapshot.text, 'standalone');
    expect(service.snapshot.isSpeaking, isTrue);
    service.setConversationSpeechActivity(
      'turn-a',
      'unit-0',
      isSpeaking: false,
    );
    expect(service.snapshot.isSpeaking, isTrue);
    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(service.snapshot.isVisible, isFalse);
  });
}

AgentReplyPresentationService _service() => AgentReplyPresentationService(
  spokenDismissDelay: const Duration(milliseconds: 50),
  minimumFallbackTtl: const Duration(seconds: 1),
  maximumFallbackTtl: const Duration(seconds: 1),
);
