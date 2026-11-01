import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

class AgentReplyPresentationSnapshot {
  const AgentReplyPresentationSnapshot({
    required this.text,
    required this.isSpeaking,
    required this.generation,
  });

  const AgentReplyPresentationSnapshot.empty()
    : text = '',
      isSpeaking = false,
      generation = 0;

  final String text;
  final bool isSpeaking;
  final int generation;

  bool get isVisible => text.trim().isNotEmpty;
}

/// Account-scoped presentation lifecycle for the self agent's current reply.
///
/// It observes the single shared [EventBus] turn/TTS lifecycle. Consumers only
/// render the snapshot; they never issue another `AgentRuntime.chat()` call.
class AgentReplyPresentationService extends AppService {
  AgentReplyPresentationService({
    EventBus? eventBus,
    Duration spokenDismissDelay = const Duration(milliseconds: 900),
    Duration minimumFallbackTtl = const Duration(seconds: 4),
    Duration maximumFallbackTtl = const Duration(seconds: 12),
    int maximumCharacters = 480,
  }) : _eventBus = eventBus ?? EventBus(),
       _spokenDismissDelay = spokenDismissDelay,
       _minimumFallbackTtl = minimumFallbackTtl,
       _maximumFallbackTtl = maximumFallbackTtl,
       _maximumCharacters = maximumCharacters {
    _subscriptions.addAll(<StreamSubscription<ClawEvent>>[
      _eventBus.on<AgentReplyStartedEvent>().listen(_handleStarted),
      _eventBus.on<AgentReplyDeltaEvent>().listen(_handleDelta),
      _eventBus.on<AgentReplyCompletedEvent>().listen(_handleCompleted),
      _eventBus.on<AgentReplyAbortedEvent>().listen(_handleAborted),
      _eventBus.on<AgentSpeechQueuedEvent>().listen(_handleSpeechQueued),
      _eventBus.on<SpeakingStatusEvent>().listen(_handleSpeaking),
    ]);
  }

  static const String agentId = 'self';

  final EventBus _eventBus;
  final Duration _spokenDismissDelay;
  final Duration _minimumFallbackTtl;
  final Duration _maximumFallbackTtl;
  final int _maximumCharacters;
  final List<StreamSubscription<ClawEvent>> _subscriptions =
      <StreamSubscription<ClawEvent>>[];
  final StreamController<AgentReplyPresentationSnapshot> _changes =
      StreamController<AgentReplyPresentationSnapshot>.broadcast();

  AgentReplyPresentationSnapshot _snapshot =
      const AgentReplyPresentationSnapshot.empty();
  Timer? _dismissTimer;
  bool _replyOpen = false;
  bool _sawSpeech = false;
  bool _speechEnded = false;
  int _generation = 0;
  int _standaloneSerial = 0;
  String? _activeTurnId;
  String? _conversationTurnId;
  String? _conversationUtteranceId;
  bool _conversationOpen = false;

  AgentReplyPresentationSnapshot get snapshot => _snapshot;
  Stream<AgentReplyPresentationSnapshot> get changes => _changes.stream;

  /// Presents text produced outside `AgentRuntime.chat()` (boot/fallback).
  ///
  /// The following [SpeakingStatusEvent] still owns the spoken lifetime when
  /// TTS starts; otherwise the bounded fallback timer dismisses the bubble.
  void presentStandaloneReply(String text) {
    final normalized = _bounded(text.trim());
    if (normalized.isEmpty) return;
    _conversationTurnId = null;
    _conversationUtteranceId = null;
    _conversationOpen = false;
    _activeTurnId = 'standalone:${++_standaloneSerial}';
    _generation += 1;
    _replyOpen = true;
    _sawSpeech = false;
    _speechEnded = false;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _publish(text: normalized, isSpeaking: false);
    _scheduleDismiss(_fallbackTtl(normalized));
  }

  /// A durable utterance replaces the current bubble while its logical turn
  /// remains open across reading pauses and the bounded invitation window.
  void presentConversationUtterance(
    String turnId,
    String text, {
    String? utteranceId,
  }) {
    final normalized = _bounded(text.trim());
    if (normalized.isEmpty) return;
    _conversationTurnId = turnId;
    _conversationUtteranceId = utteranceId;
    _activeTurnId = turnId;
    _conversationOpen = true;
    _replyOpen = true;
    _sawSpeech = false;
    _speechEnded = false;
    _generation += 1;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _publish(text: normalized, isSpeaking: false);
  }

  /// The speech handle's real start/terminal updates only its own visible unit.
  /// Global speaking events have no identity and cannot safely drive this path.
  void setConversationSpeechActivity(
    String turnId,
    String utteranceId, {
    required bool isSpeaking,
  }) {
    if (!_conversationOpen ||
        _conversationTurnId != turnId ||
        _conversationUtteranceId != utteranceId) {
      return;
    }
    if (isSpeaking) _sawSpeech = true;
    _speechEnded = !isSpeaking;
    _publish(isSpeaking: isSpeaking);
  }

  void completeConversationTurn(String turnId, {required bool cancelled}) {
    if (_conversationTurnId != turnId || !_conversationOpen) return;
    _conversationOpen = false;
    if (cancelled) {
      clear();
    } else if (_snapshot.isVisible) {
      _scheduleDismiss(_fallbackTtl(_snapshot.text));
    }
  }

  void _handleStarted(AgentReplyStartedEvent event) {
    if (!_isSelf(event)) return;
    _conversationTurnId = null;
    _conversationUtteranceId = null;
    _conversationOpen = false;
    _activeTurnId = event.turnId;
    _generation += 1;
    _replyOpen = true;
    _sawSpeech = false;
    _speechEnded = false;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _publish(text: '', isSpeaking: false);
  }

  void _handleDelta(AgentReplyDeltaEvent event) {
    if (!_isSelf(event) || event.delta.isEmpty) return;
    if (!_replyOpen || event.turnId != _activeTurnId) return;
    _publish(text: _bounded('${_snapshot.text}${event.delta}'));
  }

  void _handleCompleted(AgentReplyCompletedEvent event) {
    if (!_isSelf(event)) return;
    if (event.turnId == _conversationTurnId) return;
    if (!_replyOpen || event.turnId != _activeTurnId) return;
    final text = _bounded(event.text.trim());
    _publish(text: text);
    if (text.isEmpty) {
      clear();
      return;
    }
    if (_sawSpeech) {
      if (_speechEnded) _scheduleDismiss(_spokenDismissDelay);
    } else {
      _scheduleDismiss(_fallbackTtl(text));
    }
  }

  void _handleAborted(AgentReplyAbortedEvent event) {
    if (!_isSelf(event) || event.turnId != _activeTurnId) return;
    clear();
  }

  void _handleSpeechQueued(AgentSpeechQueuedEvent event) {
    if (!_isSelf(event)) return;
    if (_conversationTurnId != null) return;
    final text = _bounded(event.text.trim());
    if (text.isEmpty) return;
    if (!_replyOpen) {
      presentStandaloneReply(text);
      return;
    }
    if (!_snapshot.isVisible) _publish(text: text);
  }

  void _handleSpeaking(SpeakingStatusEvent event) {
    if (!_isSelf(event)) return;
    if (_conversationTurnId != null) return;
    if (event.isSpeaking) {
      if (!_replyOpen) return;
      _sawSpeech = true;
      _speechEnded = false;
      _dismissTimer?.cancel();
      _dismissTimer = null;
      _publish(isSpeaking: true);
      return;
    }

    _publish(isSpeaking: false);
    if (_conversationOpen) return;
    if (!_replyOpen || !_sawSpeech) return;
    _speechEnded = true;
    if (_snapshot.isVisible) _scheduleDismiss(_spokenDismissDelay);
  }

  void clear() {
    _conversationTurnId = null;
    _conversationUtteranceId = null;
    _conversationOpen = false;
    _generation += 1;
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _replyOpen = false;
    _sawSpeech = false;
    _speechEnded = false;
    _activeTurnId = null;
    _publish(text: '', isSpeaking: false);
  }

  void _publish({String? text, bool? isSpeaking}) {
    if (_changes.isClosed) return;
    _snapshot = AgentReplyPresentationSnapshot(
      text: text ?? _snapshot.text,
      isSpeaking: isSpeaking ?? _snapshot.isSpeaking,
      generation: _generation,
    );
    _changes.add(_snapshot);
  }

  void _scheduleDismiss(Duration delay) {
    final expectedGeneration = _generation;
    _dismissTimer?.cancel();
    _dismissTimer = Timer(delay, () {
      if (expectedGeneration != _generation || !_replyOpen) return;
      clear();
    });
  }

  Duration _fallbackTtl(String text) {
    final minMs = _minimumFallbackTtl.inMilliseconds;
    final maxMs = _maximumFallbackTtl.inMilliseconds;
    final milliseconds = (minMs + text.runes.length * 45).clamp(minMs, maxMs);
    return Duration(milliseconds: milliseconds);
  }

  String _bounded(String value) {
    final runes = value.runes.toList(growable: false);
    if (runes.length <= _maximumCharacters) return value;
    return String.fromCharCodes(
      runes.sublist(runes.length - _maximumCharacters),
    );
  }

  static bool _isSelf(ClawEvent event) =>
      event.agentId == null || event.agentId == agentId;

  @override
  void onClose() {
    _dismissTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_changes.close());
    super.onClose();
  }
}
