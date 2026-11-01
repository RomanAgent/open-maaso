import 'dart:convert';

import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

final class RealtimeActionCursorKey {
  RealtimeActionCursorKey({
    required String sessionId,
    required this.leaseEpoch,
    required this.rtcGeneration,
  }) : sessionId = _opaqueId(sessionId, 'sessionId') {
    _positiveJsonInteger(leaseEpoch, 'leaseEpoch');
    _positiveJsonInteger(rtcGeneration, 'rtcGeneration');
  }

  final String sessionId;
  final int leaseEpoch;
  final int rtcGeneration;

  String get storageKey =>
      jsonEncode(<Object>[sessionId, leaseEpoch, rtcGeneration]);

  @override
  bool operator ==(Object other) =>
      other is RealtimeActionCursorKey &&
      other.sessionId == sessionId &&
      other.leaseEpoch == leaseEpoch &&
      other.rtcGeneration == rtcGeneration;

  @override
  int get hashCode => Object.hash(sessionId, leaseEpoch, rtcGeneration);

  @override
  String toString() =>
      'RealtimeActionCursorKey(sessionId: $sessionId, '
      'leaseEpoch: $leaseEpoch, rtcGeneration: $rtcGeneration)';
}

abstract interface class RealtimeActionCursorStore {
  Future<int> read(RealtimeActionCursorKey key);

  /// Atomically reserves [sequence] before the corresponding effect starts.
  ///
  /// A `false` result means this or a later sequence was already claimed.
  /// Advancing before effect intentionally provides durable at-most-once
  /// delivery: a crash may drop the claimed event, but can never replay it.
  Future<bool> claim(RealtimeActionCursorKey key, int sequence);

  Future<void> commit(RealtimeActionCursorKey key, int sequence);
}

/// Persists cursors inside the already account-scoped Sembast database.
///
/// The record key includes the logical session, lease epoch, and RTC
/// generation so a newer holder/session can never inherit an older cursor.
final class SembastRealtimeActionCursorStore
    implements RealtimeActionCursorStore {
  SembastRealtimeActionCursorStore({required DBService accountDatabase})
    : _accountDatabase = accountDatabase;

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('realtime_action_cursors.v1');

  final DBService _accountDatabase;

  @override
  Future<int> read(RealtimeActionCursorKey key) async {
    final stored = await _store
        .record(key.storageKey)
        .get(_accountDatabase.raw);
    if (stored == null) return 0;
    return _validatedStoredSequence(key, stored);
  }

  @override
  Future<bool> claim(RealtimeActionCursorKey key, int sequence) async {
    _positiveJsonInteger(sequence, 'sequence');
    return _accountDatabase.raw.transaction((transaction) async {
      final record = _store.record(key.storageKey);
      final stored = await record.get(transaction);
      final current = stored == null
          ? 0
          : _validatedStoredSequence(key, stored);
      if (sequence <= current) return false;
      await record.put(transaction, <String, Object?>{
        'sessionId': key.sessionId,
        'leaseEpoch': key.leaseEpoch,
        'rtcGeneration': key.rtcGeneration,
        'sequence': sequence,
      });
      return true;
    });
  }

  @override
  Future<void> commit(RealtimeActionCursorKey key, int sequence) async {
    await claim(key, sequence);
  }

  static int _validatedStoredSequence(
    RealtimeActionCursorKey key,
    Map<String, Object?> stored,
  ) {
    if (stored.length != 4 ||
        !stored.keys.toSet().containsAll(const <String>{
          'sessionId',
          'leaseEpoch',
          'rtcGeneration',
          'sequence',
        }) ||
        stored['sessionId'] != key.sessionId ||
        stored['leaseEpoch'] != key.leaseEpoch ||
        stored['rtcGeneration'] != key.rtcGeneration) {
      throw const FormatException('realtime action cursor is corrupt');
    }
    final sequence = stored['sequence'];
    if (sequence is! int ||
        sequence < 0 ||
        sequence > maxAccountDeviceLeaseJsonInteger) {
      throw const FormatException('realtime action cursor is invalid');
    }
    return sequence;
  }
}

int _positiveJsonInteger(int value, String field) {
  if (value <= 0 || value > maxAccountDeviceLeaseJsonInteger) {
    throw ArgumentError.value(value, field, 'must be a positive JSON integer');
  }
  return value;
}

String _opaqueId(String value, String field) {
  if (value != value.trim() ||
      value.length < 8 ||
      value.length > 64 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    throw FormatException('realtime action cursor $field is invalid');
  }
  return value;
}
