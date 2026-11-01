import 'package:maaso/src/core/models/account_device_lease.dart';

enum AccountHandoffState {
  prepared,
  targetReady,
  accepted,
  completed,
  cancelled,
  expired;

  String get wireName => this == targetReady ? 'target_ready' : name;

  static AccountHandoffState parse(Object? value) => values.firstWhere(
    (state) => state.wireName == value,
    orElse: () => throw const FormatException('invalid_handoff_state'),
  );
}

final class HandoffAvatarIdentity {
  HandoffAvatarIdentity({
    required this.modelId,
    required this.revision,
    this.sha256 = '',
  }) {
    _text(modelId, 'modelId', maximum: 128);
    _text(revision, 'revision', maximum: 64);
    if (sha256.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('invalid_handoff_avatar_hash');
    }
  }

  factory HandoffAvatarIdentity.fromJson(Object? value) {
    final json = _object(value, const {'modelId', 'revision', 'sha256'});
    if (json['sha256'] is! String) {
      throw const FormatException('invalid_handoff_avatar_hash');
    }
    return HandoffAvatarIdentity(
      modelId: _text(json['modelId'], 'modelId', maximum: 128),
      revision: _text(json['revision'], 'revision', maximum: 64),
      sha256: json['sha256'] as String,
    );
  }

  final String modelId;
  final String revision;
  final String sha256;

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'revision': revision,
    'sha256': sha256,
  };

  // Each platform can have a different reviewed asset for the same identity.
  bool matches(HandoffAvatarIdentity other) =>
      modelId == other.modelId && revision == other.revision;
}

final class AccountDeviceHandoff {
  const AccountDeviceHandoff({
    required this.handoffId,
    required this.agentId,
    required this.state,
    required this.sourceLeaseId,
    required this.sourceEpoch,
    required this.sourcePresenceSessionId,
    required this.sourceRuntimeInstanceId,
    required this.targetPresenceSessionId,
    required this.targetRuntimeInstanceId,
    required this.avatarModel,
    required this.createdAt,
    required this.expiresAt,
    required this.remainingTtl,
    this.lease,
  });

  factory AccountDeviceHandoff.fromJson(Object? value) {
    final json = _object(value, const {
      'handoffId',
      'agentId',
      'state',
      'sourceLeaseId',
      'sourceEpoch',
      'sourcePresenceSessionId',
      'sourceRuntimeInstanceId',
      'targetPresenceSessionId',
      'targetRuntimeInstanceId',
      'avatarModel',
      'createdAt',
      'expiresAt',
      'remainingTtlMs',
      'lease',
    });
    final state = AccountHandoffState.parse(json['state']);
    final lease = json['lease'] == null
        ? null
        : AccountDeviceLeaseReceipt.fromJson(json['lease']);
    final result = AccountDeviceHandoff(
      handoffId: handoffIdentifier(json['handoffId']),
      agentId: _text(json['agentId'], 'agentId', maximum: 64),
      state: state,
      sourceLeaseId: handoffIdentifier(json['sourceLeaseId']),
      sourceEpoch: _integer(json['sourceEpoch'], minimum: 1),
      sourcePresenceSessionId: handoffIdentifier(
        json['sourcePresenceSessionId'],
      ),
      sourceRuntimeInstanceId: handoffIdentifier(
        json['sourceRuntimeInstanceId'],
      ),
      targetPresenceSessionId: handoffIdentifier(
        json['targetPresenceSessionId'],
      ),
      targetRuntimeInstanceId: handoffIdentifier(
        json['targetRuntimeInstanceId'],
      ),
      avatarModel: HandoffAvatarIdentity.fromJson(json['avatarModel']),
      createdAt: _date(json['createdAt']),
      expiresAt: _date(json['expiresAt']),
      remainingTtl: Duration(milliseconds: _integer(json['remainingTtlMs'])),
      lease: lease,
    );
    if (result.agentId != 'self' ||
        result.targetPresenceSessionId == result.sourcePresenceSessionId ||
        !result.expiresAt.isAfter(result.createdAt) ||
        (lease != null &&
            (!result.isCommitted ||
                lease.agentId != result.agentId ||
                lease.epoch != result.sourceEpoch + 1 ||
                lease.presenceSessionId != result.targetPresenceSessionId ||
                lease.runtimeInstanceId != result.targetRuntimeInstanceId))) {
      throw const FormatException('inconsistent_handoff_authority');
    }
    return result;
  }

  final String handoffId;
  final String agentId;
  final AccountHandoffState state;
  final String sourceLeaseId;
  final int sourceEpoch;
  final String sourcePresenceSessionId;
  final String sourceRuntimeInstanceId;
  final String targetPresenceSessionId;
  final String targetRuntimeInstanceId;
  final HandoffAvatarIdentity avatarModel;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Duration remainingTtl;
  final AccountDeviceLeaseReceipt? lease;

  bool get isCommitted =>
      state == AccountHandoffState.accepted ||
      state == AccountHandoffState.completed;
  bool get isCancelled =>
      state == AccountHandoffState.cancelled ||
      state == AccountHandoffState.expired;
  bool get isTerminal => isCancelled || state == AccountHandoffState.completed;

  bool isSource(AccountDevicePresenceReceipt presence) =>
      presence.agentId == agentId &&
      presence.presenceSessionId == sourcePresenceSessionId &&
      presence.runtimeInstanceId == sourceRuntimeInstanceId;

  bool isTarget(AccountDevicePresenceReceipt presence) =>
      presence.agentId == agentId &&
      presence.presenceSessionId == targetPresenceSessionId &&
      presence.runtimeInstanceId == targetRuntimeInstanceId;
}

final class AccountHandoffResult {
  const AccountHandoffResult({required this.handoff, required this.replayed});

  factory AccountHandoffResult.fromJson(Object? value) {
    final json = _object(value, const {'handoff', 'replayed'});
    if (json['replayed'] is! bool) {
      throw const FormatException('invalid_handoff_replay');
    }
    return AccountHandoffResult(
      handoff: json['handoff'] == null
          ? null
          : AccountDeviceHandoff.fromJson(json['handoff']),
      replayed: json['replayed'] as bool,
    );
  }

  final AccountDeviceHandoff? handoff;
  final bool replayed;

  AccountDeviceHandoff get requiredHandoff =>
      handoff ?? (throw StateError('handoff_not_found'));
}

final class AccountHandoffDrainResult {
  const AccountHandoffDrainResult({
    required this.ready,
    required this.pendingSessionCount,
    required this.replayed,
  });

  factory AccountHandoffDrainResult.fromJson(Object? value) {
    final json = _object(value, const {
      'ready',
      'pendingSessionCount',
      'replayed',
    });
    if (json['ready'] is! bool || json['replayed'] is! bool) {
      throw const FormatException('invalid_handoff_drain');
    }
    final count = _integer(json['pendingSessionCount']);
    final ready = json['ready'] as bool;
    if (ready != (count == 0)) {
      throw const FormatException('inconsistent_handoff_drain');
    }
    return AccountHandoffDrainResult(
      ready: ready,
      pendingSessionCount: count,
      replayed: json['replayed'] as bool,
    );
  }

  final bool ready;
  final int pendingSessionCount;
  final bool replayed;
}

String handoffIdentifier(Object? value) {
  final result = _text(value, 'identifier', maximum: 96);
  if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(result)) {
    throw const FormatException('invalid_handoff_identifier');
  }
  return result;
}

Map<String, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      value.keys.any((key) => key is! String || !keys.contains(key))) {
    throw const FormatException('invalid_handoff_object');
  }
  return Map<String, Object?>.from(value);
}

String _text(Object? value, String field, {required int maximum}) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.length > maximum ||
      value.contains(RegExp(r'[\x00-\x1f]'))) {
    throw FormatException('invalid_handoff_$field');
  }
  return value;
}

int _integer(Object? value, {int minimum = 0}) {
  if (value is! int ||
      value < minimum ||
      value > maxAccountDeviceLeaseJsonInteger) {
    throw const FormatException('invalid_handoff_integer');
  }
  return value;
}

DateTime _date(Object? value) {
  final date = value is String ? DateTime.tryParse(value) : null;
  if (date == null || !date.isUtc) {
    throw const FormatException('invalid_handoff_date');
  }
  return date;
}
