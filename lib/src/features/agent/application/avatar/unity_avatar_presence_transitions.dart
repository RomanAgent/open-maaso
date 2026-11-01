import 'dart:async';

import 'avatar_presence_transition.dart';
import 'unity_avatar_transport.dart';

/// Waits for Unity's rendered completion, not the native send acknowledgement.
class UnityAvatarPresenceTransitions {
  UnityAvatarPresenceTransitions(this.transport, this.isReady);

  final UnityAvatarTransport transport;
  final bool Function() isReady;
  final _pending =
      <String, ({AvatarPresenceTransition request, Completer<void> receipt})>{};
  final _usedRequestIds = <String>{};
  int _sequence = 0;
  bool _closed = false;

  Future<void> run(AvatarPresenceTransition request) async {
    request.validate();
    if (_closed || !isReady()) {
      throw AvatarPresenceTransitionException(
        _closed ? 'runtime_closed' : 'not_ready',
      );
    }
    if (!_usedRequestIds.add(request.requestId)) {
      throw const AvatarPresenceTransitionException('duplicate_request');
    }
    final receipt = Completer<void>();
    _pending[request.requestId] = (request: request, receipt: receipt);
    final timeout = Duration(milliseconds: request.durationMs + 5000);
    final deadline =
        DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds;
    final packet = <String, Object>{
      ...request.toJson(),
      'sequence': ++_sequence,
      'expiresAtMs': deadline,
    };
    final timer = Timer(timeout, () {
      if (receipt.isCompleted) return;
      receipt.completeError(const AvatarPresenceTransitionException('timeout'));
      // Fence a queued/late movement as well as the visible one. Ambiguous
      // handoffs stay hidden until the account coordinator decides recovery.
      unawaited(
        transport
            .invokeMethod<void>('transitionPresence', {
              ...packet,
              'requestId': 'presence-timeout-${_sequence + 1}',
              'phase': 'holdHidden',
              'sequence': ++_sequence,
              'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5000,
            })
            .catchError((Object _) {}),
      );
    });
    unawaited(
      transport.invokeMethod<void>('transitionPresence', packet).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (!receipt.isCompleted) receipt.completeError(error, stack);
      }),
    );
    try {
      await receipt.future;
    } finally {
      timer.cancel();
      _pending.remove(request.requestId);
    }
  }

  bool handleResult(Map<String, dynamic> result) {
    final pending = _pending[result['requestId']];
    if (pending == null ||
        pending.receipt.isCompleted ||
        result['transitionId'] != pending.request.transitionId ||
        result['phase'] != pending.request.phase.name) {
      return false;
    }
    if (result['ok'] == true) {
      pending.receipt.complete();
    } else {
      pending.receipt.completeError(
        AvatarPresenceTransitionException(
          result['code'] is String
              ? result['code'] as String
              : 'transition_failed',
        ),
      );
    }
    return true;
  }

  void invalidate(String reason) {
    for (final pending in _pending.values) {
      if (!pending.receipt.isCompleted) {
        pending.receipt.completeError(
          AvatarPresenceTransitionException(reason),
        );
      }
    }
    _pending.clear();
  }

  void close() {
    _closed = true;
    invalidate('runtime_closed');
  }
}
