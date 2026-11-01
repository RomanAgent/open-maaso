import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shared agent reply events drive one bounded presentation snapshot',
    () async {
      final service = AgentReplyPresentationService(
        minimumFallbackTtl: const Duration(milliseconds: 30),
        maximumFallbackTtl: const Duration(milliseconds: 30),
        maximumCharacters: 5,
      );
      addTearDown(service.closeLifecycle);

      EventBus().fire(
        AgentReplyStartedEvent(
          turnId: 'turn-1',
          origin: 'user',
          agentId: 'self',
        ),
      );
      EventBus().fire(
        AgentReplyDeltaEvent('abcdef', turnId: 'turn-1', agentId: 'self'),
      );
      await _flushEvents();

      expect(service.snapshot.text, 'bcdef');
      expect(service.snapshot.isVisible, isTrue);

      EventBus().fire(
        AgentReplyCompletedEvent('final', turnId: 'turn-1', agentId: 'self'),
      );
      await _flushEvents();
      expect(service.snapshot.text, 'final');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.snapshot.isVisible, isFalse);
    },
  );

  test('speaking keeps the bubble visible until TTS has ended', () async {
    final service = AgentReplyPresentationService(
      spokenDismissDelay: const Duration(milliseconds: 12),
      minimumFallbackTtl: const Duration(milliseconds: 20),
      maximumFallbackTtl: const Duration(milliseconds: 20),
    );
    addTearDown(service.closeLifecycle);

    EventBus().fire(
      AgentReplyStartedEvent(turnId: 'turn-2', origin: 'user', agentId: 'self'),
    );
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    EventBus().fire(
      AgentReplyCompletedEvent(
        'still speaking',
        turnId: 'turn-2',
        agentId: 'self',
      ),
    );
    await _flushEvents();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(service.snapshot.text, 'still speaking');
    expect(service.snapshot.isSpeaking, isTrue);

    EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
    await _flushEvents();
    expect(service.snapshot.isSpeaking, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.snapshot.isVisible, isFalse);
  });

  test('queued speech supplies text before the turn has completed', () async {
    final service = AgentReplyPresentationService(
      spokenDismissDelay: const Duration(milliseconds: 12),
    );
    addTearDown(service.closeLifecycle);

    EventBus().fire(
      AgentReplyStartedEvent(
        turnId: 'voice-action-turn',
        origin: 'user',
        agentId: 'self',
      ),
    );
    EventBus().fire(AgentSpeechQueuedEvent('spoken action', agentId: 'self'));
    EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
    await _flushEvents();

    expect(service.snapshot.text, 'spoken action');
    expect(service.snapshot.isSpeaking, isTrue);
  });

  test('events for another agent never replace the self bubble', () async {
    final service = AgentReplyPresentationService();
    addTearDown(service.closeLifecycle);

    EventBus().fire(
      AgentReplyStartedEvent(
        turnId: 'peer-turn',
        origin: 'user',
        agentId: 'peer',
      ),
    );
    EventBus().fire(
      AgentReplyCompletedEvent(
        'peer reply',
        turnId: 'peer-turn',
        agentId: 'peer',
      ),
    );
    await _flushEvents();

    expect(service.snapshot.isVisible, isFalse);
  });

  test(
    'late events from an older turn cannot overwrite the active reply',
    () async {
      final service = AgentReplyPresentationService();
      addTearDown(service.closeLifecycle);

      EventBus().fire(
        AgentReplyStartedEvent(
          turnId: 'old-turn',
          origin: 'proactive',
          agentId: 'self',
        ),
      );
      EventBus().fire(
        AgentReplyDeltaEvent('old', turnId: 'old-turn', agentId: 'self'),
      );
      EventBus().fire(
        AgentReplyStartedEvent(
          turnId: 'new-turn',
          origin: 'user',
          agentId: 'self',
        ),
      );
      EventBus().fire(
        AgentReplyDeltaEvent('new', turnId: 'new-turn', agentId: 'self'),
      );
      EventBus().fire(
        AgentReplyCompletedEvent(
          'stale final',
          turnId: 'old-turn',
          agentId: 'self',
        ),
      );
      await _flushEvents();

      expect(service.snapshot.text, 'new');
    },
  );

  test('aborted active turn clears partial reply text', () async {
    final service = AgentReplyPresentationService();
    addTearDown(service.closeLifecycle);

    EventBus().fire(
      AgentReplyStartedEvent(
        turnId: 'failed-turn',
        origin: 'user',
        agentId: 'self',
      ),
    );
    EventBus().fire(
      AgentReplyDeltaEvent('partial', turnId: 'failed-turn', agentId: 'self'),
    );
    EventBus().fire(
      AgentReplyAbortedEvent(turnId: 'failed-turn', agentId: 'self'),
    );
    EventBus().fire(
      AgentReplyCompletedEvent(
        'late stale final',
        turnId: 'failed-turn',
        agentId: 'self',
      ),
    );
    await _flushEvents();

    expect(service.snapshot.isVisible, isFalse);
  });

  test(
    'standalone fallback text joins the same TTS bubble lifecycle',
    () async {
      final service = AgentReplyPresentationService(
        spokenDismissDelay: const Duration(milliseconds: 12),
        minimumFallbackTtl: const Duration(milliseconds: 80),
        maximumFallbackTtl: const Duration(milliseconds: 80),
      );
      addTearDown(service.closeLifecycle);

      service.presentStandaloneReply('fallback reply');
      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await _flushEvents();

      expect(service.snapshot.text, 'fallback reply');
      expect(service.snapshot.isSpeaking, isTrue);

      EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
      await _flushEvents();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.snapshot.isVisible, isFalse);
    },
  );
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);
