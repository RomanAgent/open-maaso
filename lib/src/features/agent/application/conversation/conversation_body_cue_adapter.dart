import 'dart:async';

import 'package:maaso/src/core/services/turn_trace.dart';

import '../avatar/avatar_behavior_director.dart';
import '../body/avatar_body_intent_policy.dart';
import 'conversation_reply_coordinator.dart';

typedef ApplyConversationBodyCue =
    Future<AvatarBehaviorResult> Function(
      AvatarAct act,
      bool Function() shouldContinue,
    );

/// One turn's optional expression cues, bound to committed utterance identities.
///
/// Speech callers notify only after real playback starts; a synthesis result or
/// queue acknowledgement is insufficient. Text-only callers notify after the
/// committed unit becomes visible. Already submitted renderer work cannot be
/// recalled, but every later asynchronous step checks the same ownership guard.
class ConversationBodyCueAdapter {
  ConversationBodyCueAdapter({
    required this.turnId,
    required bool Function() isCurrent,
    String agentId = 'self',
    ApplyConversationBodyCue? applyCue,
    this.dispatchTimeout = const Duration(seconds: 2),
  }) : assert(dispatchTimeout > Duration.zero),
       _isCurrent = isCurrent,
       _applyCue = applyCue ?? _directorDispatch(agentId);

  final String turnId;
  final Duration dispatchTimeout;
  final bool Function() _isCurrent;
  final ApplyConversationBodyCue _applyCue;
  final Map<String, ConversationUtterance> _published = {};
  final Set<String> _started = {};
  final Set<String> _seen = {};
  final Completer<void> _closedSignal = Completer<void>();
  Future<void> _tail = Future<void>.value();
  Future<void>? _finishFuture;
  bool _closed = false;
  bool _finishing = false;
  int _lastStartedSequence = -1;
  int _revision = 0;

  bool get _active => !_closed && _isCurrent();
  bool get _accepting => !_finishing && _active;

  /// Call after persistence commits, never while a draft is still pending.
  void registerPublished(ConversationUtterance utterance) {
    if (!_accepting ||
        utterance.turnId != turnId ||
        utterance.utteranceId.isEmpty ||
        utterance.sequence < 0 ||
        utterance.sequence > 2 ||
        _published.containsKey(utterance.utteranceId) ||
        _published.values.any((item) => item.sequence == utterance.sequence)) {
      return;
    }
    _published[utterance.utteranceId] = utterance;
  }

  void onSpeechStarted(ConversationUtterance utterance) => _start(utterance);

  void onTextDelivered(ConversationUtterance utterance) => _start(utterance);

  void _start(ConversationUtterance notification) {
    if (!_accepting || notification.turnId != turnId) return;
    final utterance = _published[notification.utteranceId];
    if (utterance == null ||
        utterance.sequence != notification.sequence ||
        _started.contains(utterance.utteranceId) ||
        utterance.sequence <= _lastStartedSequence) {
      return;
    }
    _started.add(utterance.utteranceId);
    _lastStartedSequence = utterance.sequence;
    // Even a sentence without a cue retires pending steps from the previous one.
    final revision = ++_revision;
    final body = utterance.draft.body;
    final payload = AvatarBodyIntentPolicy.normalize(
      body == null ? null : Map<String, dynamic>.from(body),
    );
    if (payload == null) return;
    final signature = AvatarBodyIntentPolicy.signature(payload);
    if (_seen.contains(signature) || _seen.length >= 2) return;
    _seen.add(signature);
    final act = AvatarAct.fromJson(payload);
    bool shouldContinue() => _active && _revision == revision;
    _tail = _tail.then((_) async {
      if (!shouldContinue()) return;
      try {
        await Future.any<void>([
          Future<AvatarBehaviorResult>.sync(
            () => _applyCue(act, shouldContinue),
          ).then((_) {}),
          _closedSignal.future,
        ]).timeout(dispatchTimeout);
      } on TimeoutException {
        // A stalled bridge must not release a queued cue seconds after its
        // sentence started. Retire the optional performance for this turn.
        close();
        TurnTrace.event(
          'conversation.body_cue.timeout',
          details: 'dispatch_limit_ms=${dispatchTimeout.inMilliseconds}',
        );
      } catch (_) {
        TurnTrace.event(
          'conversation.body_cue.failed',
          details: 'handler_failed=true',
        );
      }
    });
  }

  /// Invalidates pending callbacks synchronously, without waiting on a renderer.
  void close() {
    if (_closed) return;
    _closed = true;
    _revision++;
    _closedSignal.complete();
  }

  /// Optional performance must not hold a completed conversation turn open.
  Future<void> finish() => _finishFuture ??= _finish();

  Future<void> _finish() async {
    _finishing = true;
    try {
      await _tail.timeout(dispatchTimeout);
    } on TimeoutException {
      TurnTrace.event(
        'conversation.body_cue.timeout',
        details: 'drain_limit_ms=${dispatchTimeout.inMilliseconds}',
      );
    } finally {
      close();
    }
  }

  static ApplyConversationBodyCue _directorDispatch(String agentId) {
    final director = AvatarBehaviorDirector(agentId: agentId);
    return (act, shouldContinue) =>
        director.applyAct(act, shouldContinue: shouldContinue);
  }
}
