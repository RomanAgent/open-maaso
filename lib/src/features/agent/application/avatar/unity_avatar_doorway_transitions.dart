import 'dart:async';
import 'avatar_doorway_transition.dart';
import 'unity_avatar_transport.dart';

/// Correlates actual rendered phase receipts; a native enqueue ack is not ready.
final class UnityAvatarDoorwayTransitions {
  UnityAvatarDoorwayTransitions(this.transport, this.isReady);
  final UnityAvatarTransport transport;
  final bool Function() isReady;
  final _pending =
      <String, ({AvatarDoorwayTransition request, Completer<void> receipt})>{};
  final _used = <String>{};
  var _sequence = 0;
  var _closed = false;

  Future<void> run(AvatarDoorwayTransition request) async {
    request.validate();
    if (_closed || !isReady()) {
      throw const AvatarDoorwayTransitionException('not_ready');
    }
    if (!_used.add(request.requestId)) {
      throw const AvatarDoorwayTransitionException('duplicate_request');
    }
    final receipt = Completer<void>();
    _pending[request.requestId] = (request: request, receipt: receipt);
    // Framing can continue through the reviewed bedroom doorway. Its native
    // path is bounded to 12 seconds plus actual sliding-door readiness.
    final timeout = Duration(
      milliseconds:
          request.durationMs +
          (request.phase == AvatarDoorwayPhase.frame ? 15000 : 5000),
    );
    final packet = <String, Object>{
      ...request.toJson(),
      'sequence': ++_sequence,
      'expiresAtMs':
          DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds,
    };
    final timer = Timer(timeout, () {
      if (!receipt.isCompleted) {
        receipt.completeError(
          const AvatarDoorwayTransitionException('timeout'),
        );
      }
      unawaited(
        transport
            .invokeMethod<void>('transitionLoginDoorway', {
              ...packet,
              'requestId': 'doorway-timeout-${++_sequence}',
              'phase': 'cancel',
              'sequence': _sequence,
              'durationMs': 0,
              'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5000,
            })
            .catchError((Object _) {}),
      );
    });
    unawaited(
      transport.invokeMethod<void>('transitionLoginDoorway', packet).catchError(
        (Object error, StackTrace stack) {
          if (!receipt.isCompleted) receipt.completeError(error, stack);
        },
      ),
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
        AvatarDoorwayTransitionException(
          result['code'] is String
              ? result['code'] as String
              : 'presentation_failed',
        ),
      );
    }
    return true;
  }

  void invalidate(String reason) {
    for (final pending in _pending.values) {
      if (!pending.receipt.isCompleted) {
        pending.receipt.completeError(AvatarDoorwayTransitionException(reason));
      }
    }
    _pending.clear();
  }

  void close() {
    _closed = true;
    invalidate('runtime_closed');
  }
}
