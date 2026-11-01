import 'dart:async';

import 'avatar_phone_interaction.dart';
import 'unity_avatar_transport.dart';

/// Native transport delivery is not an animation completion receipt.
class UnityAvatarPhoneInteractions {
  UnityAvatarPhoneInteractions(this.transport, this.isReady);

  final UnityAvatarTransport transport;
  final bool Function() isReady;
  final _pending =
      <
        String,
        ({String interactionId, String phase, Completer<void> receipt})
      >{};
  int _sequence = 0;
  bool _closed = false;

  Future<void> run({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) async {
    if (!RegExp(
      r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
    ).hasMatch(interactionId)) {
      throw const AvatarPhoneInteractionException('invalid_interaction_id');
    }
    if (_closed || !isReady()) {
      throw AvatarPhoneInteractionException(
        _closed ? 'runtime_closed' : 'not_ready',
      );
    }
    final sequence = ++_sequence;
    final requestId = 'phone-$sequence';
    final receipt = Completer<void>();
    _pending[requestId] = (
      interactionId: interactionId,
      phase: phase.name,
      receipt: receipt,
    );
    final packet = <String, Object>{
      'requestId': requestId,
      'interactionId': interactionId,
      'phase': phase.name,
      'sequence': sequence,
      'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5000,
    };
    final timer = Timer(const Duration(seconds: 5), () {
      if (receipt.isCompleted) return;
      receipt.completeError(const AvatarPhoneInteractionException('timeout'));
      // A late stop only matches this interaction. It cannot hide a newer phone.
      unawaited(
        transport
            .invokeMethod<void>('setPhoneInteraction', {
              ...packet,
              'requestId': 'phone-timeout-${++_sequence}',
              'phase': 'none',
              'sequence': _sequence,
              'expiresAtMs': DateTime.now().millisecondsSinceEpoch + 5000,
            })
            .catchError((Object _) {}),
      );
    });
    unawaited(
      transport.invokeMethod<void>('setPhoneInteraction', packet).catchError((
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
      _pending.remove(requestId);
    }
  }

  bool handleResult(Map<String, dynamic> result) {
    final pending = _pending[result['requestId']];
    if (pending == null ||
        pending.receipt.isCompleted ||
        result['interactionId'] != pending.interactionId ||
        result['phase'] != pending.phase) {
      return false;
    }
    if (result['ok'] == true) {
      pending.receipt.complete();
    } else {
      pending.receipt.completeError(
        AvatarPhoneInteractionException(
          result['code'] is String
              ? result['code'] as String
              : 'phone_interaction_failed',
        ),
      );
    }
    return true;
  }

  void invalidate(String reason) {
    for (final pending in _pending.values) {
      if (!pending.receipt.isCompleted) {
        pending.receipt.completeError(AvatarPhoneInteractionException(reason));
      }
    }
    _pending.clear();
  }

  void close() {
    _closed = true;
    invalidate('runtime_closed');
  }
}
