import 'dart:async';

import '../domain/content_engagement.dart';

/// Serializes server-issued evidence sessions. Hints are never coins or proof of
/// qualification; the server independently decides whether review can release it.
class ContentConsumptionController {
  ContentConsumptionController({
    required this.gateway,
    required this.target,
    this.automaticTicks = true,
    DateTime Function()? now,
  }) : _contextKey = gateway.contextKey,
       _now = now ?? DateTime.now;

  final ContentEngagementGateway gateway;
  final ContentConsumptionTarget target;
  final bool automaticTicks;
  final String _contextKey;
  final DateTime Function() _now;
  Future<void> _tail = Future<void>.value();
  Timer? _timer;
  ContentConsumptionSession? _session;
  String? _startRequestId;
  ({int sequence, String event, int progress})? _pendingPulse;
  int _progress = 0;
  int _sentProgress = 0;
  bool _operation = false;
  bool _visible = false;
  bool _closed = false;
  DateTime? _lastInteraction;
  Object? lastFailure;

  ContentConsumptionSession? get session => _session;
  bool get _current => !_closed && gateway.contextKey == _contextKey;

  Future<void> setVisible(bool visible) {
    if (_closed) return Future<void>.value();
    if (visible == _visible) return _tail;
    _visible = visible;
    _timer?.cancel();
    _timer = null;
    if (visible) {
      _lastInteraction = _now();
      if (automaticTicks) {
        _timer = Timer.periodic(const Duration(seconds: 10), (_) {
          unawaited(tick());
        });
      }
    }
    return _enqueue(() => _reconcile(pulse: false));
  }

  /// Games supply their actual runtime progress callback. Merely opening a game
  /// does not call this method.
  void recordProgress(int progress) {
    if (!_current ||
        !_visible ||
        target.kind == ContentConsumptionKind.applet ||
        progress < 0 ||
        progress > 10000) {
      return;
    }
    if (progress > _progress) _progress = progress;
    _lastInteraction = _now();
  }

  /// Called only by a handled utility operation, never by passive pointer taps.
  void recordOperation() {
    if (!_current ||
        !_visible ||
        target.kind != ContentConsumptionKind.applet) {
      return;
    }
    _operation = true;
    _lastInteraction = _now();
  }

  Future<void> tick() => _enqueue(() => _reconcile(pulse: true));

  Future<void> _enqueue(Future<void> Function() action) {
    _tail = _tail.then((_) async {
      if (!_current) return;
      try {
        await action();
        lastFailure = null;
      } catch (error) {
        lastFailure = error;
      }
    });
    return _tail;
  }

  Future<void> _reconcile({required bool pulse}) async {
    if (!_current) return;
    final interaction = _lastInteraction;
    final active =
        _visible &&
        interaction != null &&
        _now().difference(interaction) <= const Duration(seconds: 45);
    if (!active) {
      await _finish();
      return;
    }
    if (_session == null) {
      _startRequestId ??= newContentRequestId();
      final started = await gateway.start(target, _startRequestId!);
      if (!_current) return;
      if (started.state != 'active') {
        _startRequestId = null;
        throw const ContentEngagementException('CONTENT_SESSION_CONFLICT');
      }
      _session = started;
      if (!_visible) await _finish();
      return;
    }
    if (!pulse) return;
    await _sendPulse();
  }

  Future<void> _sendPulse() async {
    final current = _session;
    if (current == null || !_current) return;
    final pending = _pendingPulse ??= (
      sequence: current.sequence + 1,
      event: _operation
          ? 'applet_operation'
          : _progress > _sentProgress
          ? 'game_progress'
          : 'heartbeat',
      progress: _progress > _sentProgress ? _progress : 0,
    );
    ContentConsumptionSession updated;
    try {
      updated = await gateway.pulse(
        current.sessionId,
        pending.sequence,
        pending.event,
        pending.progress,
      );
    } on ContentEngagementException catch (error) {
      if (error.code != 'CONTENT_SESSION_CONFLICT') rethrow;
      if (!_current) return;
      // A definite rejection did not admit this pulse. Close the last confirmed
      // sequence; replaying an expired pulse would otherwise prevent cleanup.
      _pendingPulse = null;
      await _finish();
      return;
    }
    if (!_current) return;
    if (updated.sessionId != current.sessionId ||
        updated.sequence != pending.sequence ||
        updated.state != 'active') {
      throw const ContentEngagementException('CONTENT_SESSION_CONFLICT');
    }
    _session = updated;
    _pendingPulse = null;
    if (pending.event == 'applet_operation') _operation = false;
    if (pending.progress > _sentProgress) _sentProgress = pending.progress;
  }

  Future<void> _finish() async {
    if (!_current || _session == null) return;
    if (_pendingPulse != null) await _sendPulse();
    final current = _session;
    if (!_current || current == null) return;
    ContentConsumptionSession finished;
    try {
      finished = await gateway.finish(current.sessionId, current.sequence + 1);
    } on ContentEngagementException catch (error) {
      if (error.code != 'CONTENT_SESSION_CONFLICT') rethrow;
      // A replaced lease or changed publication cannot be closed by this
      // controller. Release local state so the next activity can start afresh.
      if (_current) _clearSession();
      return;
    }
    if (!_current) return;
    if (finished.sessionId != current.sessionId ||
        finished.sequence != current.sequence + 1 ||
        finished.state == 'active') {
      throw const ContentEngagementException('CONTENT_SESSION_CONFLICT');
    }
    _clearSession();
  }

  void _clearSession() {
    _session = null;
    _startRequestId = null;
    _pendingPulse = null;
    _progress = _sentProgress = 0;
    _operation = false;
  }

  Future<void> close() async {
    if (_closed) return;
    _visible = false;
    _timer?.cancel();
    _timer = null;
    await _enqueue(_finish);
    _closed = true;
  }
}
