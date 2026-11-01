const int maxAccountDeviceLeaseJsonInteger = 0x1fffffffffffff;

const Set<String> _supportedDevicePlatforms = <String>{
  'ios',
  'android',
  'macos',
  'windows',
  'linux',
  'web',
  'unknown',
};

class AccountDeviceIdentity {
  const AccountDeviceIdentity({
    required this.installationId,
    required this.runtimeInstanceId,
  });

  final String installationId;
  final String runtimeInstanceId;

  @override
  String toString() =>
      'AccountDeviceIdentity(installationId: $installationId, '
      'runtimeInstanceId: $runtimeInstanceId)';
}

class AccountDeviceLeaseHolder {
  const AccountDeviceLeaseHolder({
    required this.installationId,
    required this.runtimeInstanceId,
    required this.presenceSessionId,
    required this.deviceLabel,
    required this.platform,
    required this.lastSeenAt,
  });

  final String installationId;
  final String runtimeInstanceId;
  final String presenceSessionId;
  final String deviceLabel;
  final String platform;
  final DateTime lastSeenAt;

  factory AccountDeviceLeaseHolder.fromJson(Object? source) {
    final json = _requiredMap(source, 'lease holder');
    _requireExactKeys(json, const <String>{
      'installationId',
      'runtimeInstanceId',
      'presenceSessionId',
      'deviceLabel',
      'platform',
      'lastSeenAt',
    }, 'lease holder');
    _rejectSecretFields(json, 'lease holder');
    return AccountDeviceLeaseHolder(
      installationId: _requiredOpaqueId(json, 'installationId'),
      runtimeInstanceId: _requiredOpaqueId(json, 'runtimeInstanceId'),
      presenceSessionId: _requiredOpaqueId(json, 'presenceSessionId'),
      deviceLabel: _requiredDeviceLabel(json, 'deviceLabel'),
      platform: _requiredPlatform(json, 'platform'),
      lastSeenAt: _requiredUtcTimestamp(json, 'lastSeenAt'),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'installationId': installationId,
    'runtimeInstanceId': runtimeInstanceId,
    'presenceSessionId': presenceSessionId,
    'deviceLabel': deviceLabel,
    'platform': platform,
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
  };
}

class AccountDevicePresenceReceipt {
  const AccountDevicePresenceReceipt({
    required this.agentId,
    required this.installationId,
    required this.runtimeInstanceId,
    required this.presenceSessionId,
    required this.generation,
    required this.deviceLabel,
    required this.platform,
    required this.appVersion,
    required this.openedAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.remainingTtl,
    required this.renewAfter,
  });

  final String agentId;
  final String installationId;
  final String runtimeInstanceId;
  final String presenceSessionId;
  final int generation;
  final String deviceLabel;
  final String platform;
  final String appVersion;
  final DateTime openedAt;
  final DateTime lastSeenAt;
  final DateTime expiresAt;
  final Duration remainingTtl;
  final Duration renewAfter;

  factory AccountDevicePresenceReceipt.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime presence');
    _requireExactKeys(json, const <String>{
      'agentId',
      'installationId',
      'runtimeInstanceId',
      'presenceSessionId',
      'generation',
      'deviceLabel',
      'platform',
      'appVersion',
      'openedAt',
      'lastSeenAt',
      'expiresAt',
      'remainingTtlMs',
      'renewAfterMs',
    }, 'runtime presence');
    _rejectSecretFields(json, 'runtime presence');
    final remainingTtl = _requiredMilliseconds(
      json,
      'remainingTtlMs',
      allowZero: false,
    );
    final renewAfter = _requiredMilliseconds(json, 'renewAfterMs');
    if (renewAfter > remainingTtl) {
      throw const FormatException(
        'runtime presence renewAfterMs exceeds remainingTtlMs',
      );
    }
    return AccountDevicePresenceReceipt(
      agentId: _requiredAgentId(json),
      installationId: _requiredOpaqueId(json, 'installationId'),
      runtimeInstanceId: _requiredOpaqueId(json, 'runtimeInstanceId'),
      presenceSessionId: _requiredOpaqueId(json, 'presenceSessionId'),
      generation: _requiredJsonInteger(json, 'generation', minimum: 1),
      deviceLabel: _requiredDeviceLabel(json, 'deviceLabel'),
      platform: _requiredPlatform(json, 'platform'),
      appVersion: _optionalAscii(json, 'appVersion', maximumLength: 64),
      openedAt: _requiredUtcTimestamp(json, 'openedAt'),
      lastSeenAt: _requiredUtcTimestamp(json, 'lastSeenAt'),
      expiresAt: _requiredUtcTimestamp(json, 'expiresAt'),
      remainingTtl: remainingTtl,
      renewAfter: renewAfter,
    );
  }

  AccountDeviceLeaseHolder toHolder() => AccountDeviceLeaseHolder(
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
    deviceLabel: deviceLabel,
    platform: platform,
    lastSeenAt: lastSeenAt,
  );

  Map<String, Object> toJson() => <String, Object>{
    'agentId': agentId,
    'installationId': installationId,
    'runtimeInstanceId': runtimeInstanceId,
    'presenceSessionId': presenceSessionId,
    'generation': generation,
    'deviceLabel': deviceLabel,
    'platform': platform,
    'appVersion': appVersion,
    'openedAt': openedAt.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'remainingTtlMs': remainingTtl.inMilliseconds,
    'renewAfterMs': renewAfter.inMilliseconds,
  };
}

/// A proof-free, read-only view of one active runtime presence.
class AccountDevicePresenceView {
  const AccountDevicePresenceView({
    required this.agentId,
    required this.installationId,
    required this.runtimeInstanceId,
    required this.presenceSessionId,
    required this.deviceLabel,
    required this.platform,
    required this.appVersion,
    required this.openedAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.isCurrentHolder,
  });

  final String agentId;
  final String installationId;
  final String runtimeInstanceId;
  final String presenceSessionId;
  final String deviceLabel;
  final String platform;
  final String appVersion;
  final DateTime openedAt;
  final DateTime lastSeenAt;
  final DateTime expiresAt;
  final bool isCurrentHolder;

  factory AccountDevicePresenceView.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime presence view');
    _requireExactKeys(json, const <String>{
      'agentId',
      'installationId',
      'runtimeInstanceId',
      'presenceSessionId',
      'deviceLabel',
      'platform',
      'appVersion',
      'openedAt',
      'lastSeenAt',
      'expiresAt',
      'isCurrentHolder',
    }, 'runtime presence view');
    _rejectSecretFields(json, 'runtime presence view');
    final isCurrentHolder = json['isCurrentHolder'];
    if (isCurrentHolder is! bool) {
      throw const FormatException(
        'runtime authority isCurrentHolder is invalid',
      );
    }
    return AccountDevicePresenceView(
      agentId: _requiredAgentId(json),
      installationId: _requiredOpaqueId(json, 'installationId'),
      runtimeInstanceId: _requiredOpaqueId(json, 'runtimeInstanceId'),
      presenceSessionId: _requiredOpaqueId(json, 'presenceSessionId'),
      deviceLabel: _requiredDeviceLabel(json, 'deviceLabel'),
      platform: _requiredPlatform(json, 'platform'),
      appVersion: _optionalAscii(json, 'appVersion', maximumLength: 64),
      openedAt: _requiredUtcTimestamp(json, 'openedAt'),
      lastSeenAt: _requiredUtcTimestamp(json, 'lastSeenAt'),
      expiresAt: _requiredUtcTimestamp(json, 'expiresAt'),
      isCurrentHolder: isCurrentHolder,
    );
  }
}

class AccountDevicePresenceListResult {
  const AccountDevicePresenceListResult({
    required this.presences,
    required this.snapshotAt,
    required this.eventSequence,
    required this.truncated,
  });

  final List<AccountDevicePresenceView> presences;
  final DateTime snapshotAt;
  final int eventSequence;
  final bool truncated;

  factory AccountDevicePresenceListResult.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime presence list');
    _requireExactKeys(json, const <String>{
      'presences',
      'snapshotAt',
      'eventSequence',
      'truncated',
    }, 'runtime presence list');
    _rejectSecretFields(json, 'runtime presence list');
    final rawPresences = json['presences'];
    final truncated = json['truncated'];
    if (rawPresences is! List ||
        rawPresences.length > 100 ||
        truncated is! bool) {
      throw const FormatException('runtime presence list is invalid');
    }
    final presences = rawPresences
        .map(AccountDevicePresenceView.fromJson)
        .toList(growable: false);
    if (presences.map((item) => item.presenceSessionId).toSet().length !=
            presences.length ||
        presences.where((item) => item.isCurrentHolder).length > 1) {
      throw const FormatException('runtime presence list is inconsistent');
    }
    return AccountDevicePresenceListResult(
      presences: presences,
      snapshotAt: _requiredUtcTimestamp(json, 'snapshotAt'),
      eventSequence: _requiredJsonInteger(json, 'eventSequence', minimum: 0),
      truncated: truncated,
    );
  }
}

const Set<String> accountRuntimeLifecycleEventTypes = <String>{
  'presence.opened',
  'presence.closed',
  'presence.superseded',
  'presence.expired',
  'lease.acquired',
  'lease.released',
  'lease.revoked',
  'lease.expired',
  'handoff.prepared',
  'handoff.target_ready',
  'handoff.source_exited',
  'handoff.accepted',
  'handoff.completed',
  'handoff.cancelled',
  'handoff.expired',
};

class AccountRuntimeLifecycleEvent {
  const AccountRuntimeLifecycleEvent({
    required this.eventId,
    required this.sequence,
    required this.type,
    required this.leaseEpoch,
    required this.createdAt,
  });

  final String eventId;
  final int sequence;
  final String type;
  final int leaseEpoch;
  final DateTime createdAt;

  factory AccountRuntimeLifecycleEvent.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime lifecycle event');
    _requireExactKeys(json, const <String>{
      'eventId',
      'sequence',
      'type',
      'leaseEpoch',
      'createdAt',
    }, 'runtime lifecycle event');
    _rejectSecretFields(json, 'runtime lifecycle event');
    final type = _requiredTrimmed(json, 'type', maximumLength: 48);
    if (!accountRuntimeLifecycleEventTypes.contains(type)) {
      throw const FormatException('runtime lifecycle event type is invalid');
    }
    return AccountRuntimeLifecycleEvent(
      eventId: _requiredOpaqueId(json, 'eventId'),
      sequence: _requiredJsonInteger(json, 'sequence', minimum: 1),
      type: type,
      leaseEpoch: _requiredJsonInteger(json, 'leaseEpoch', minimum: 0),
      createdAt: _requiredUtcTimestamp(json, 'createdAt'),
    );
  }
}

class AccountRuntimeLifecycleEventPage {
  const AccountRuntimeLifecycleEventPage({
    required this.events,
    required this.nextSequence,
    required this.highWaterSequence,
    required this.hasMore,
  });

  final List<AccountRuntimeLifecycleEvent> events;
  final int nextSequence;
  final int highWaterSequence;
  final bool hasMore;

  factory AccountRuntimeLifecycleEventPage.fromJson(
    Object? source, {
    required int afterSequence,
  }) {
    if (afterSequence < 0 || afterSequence > maxAccountDeviceLeaseJsonInteger) {
      throw const FormatException('runtime lifecycle cursor is invalid');
    }
    final json = _requiredMap(source, 'runtime lifecycle event page');
    _requireExactKeys(json, const <String>{
      'events',
      'nextSequence',
      'highWaterSequence',
      'hasMore',
    }, 'runtime lifecycle event page');
    _rejectSecretFields(json, 'runtime lifecycle event page');
    final rawEvents = json['events'];
    final hasMore = json['hasMore'];
    if (rawEvents is! List || rawEvents.length > 100 || hasMore is! bool) {
      throw const FormatException('runtime lifecycle event page is invalid');
    }
    final events = rawEvents
        .map(AccountRuntimeLifecycleEvent.fromJson)
        .toList(growable: false);
    final nextSequence = _requiredJsonInteger(json, 'nextSequence', minimum: 0);
    final highWaterSequence = _requiredJsonInteger(
      json,
      'highWaterSequence',
      minimum: 0,
    );
    var previous = afterSequence;
    for (final event in events) {
      if (event.sequence <= previous || event.sequence > nextSequence) {
        throw const FormatException(
          'runtime lifecycle event sequence is inconsistent',
        );
      }
      previous = event.sequence;
    }
    if (nextSequence < afterSequence ||
        nextSequence > highWaterSequence ||
        (hasMore && nextSequence == afterSequence) ||
        hasMore != (nextSequence < highWaterSequence)) {
      throw const FormatException('runtime lifecycle cursor is inconsistent');
    }
    return AccountRuntimeLifecycleEventPage(
      events: events,
      nextSequence: nextSequence,
      highWaterSequence: highWaterSequence,
      hasMore: hasMore,
    );
  }
}

class AccountDeviceLeaseReceipt {
  const AccountDeviceLeaseReceipt({
    required this.agentId,
    required this.leaseId,
    required this.epoch,
    required this.installationId,
    required this.runtimeInstanceId,
    required this.presenceSessionId,
    required this.expiresAt,
    required this.remainingTtl,
    required this.renewAfter,
    required this.holder,
  });

  final String agentId;
  final String leaseId;
  final int epoch;
  final String installationId;
  final String runtimeInstanceId;
  final String presenceSessionId;
  final DateTime expiresAt;
  final Duration remainingTtl;
  final Duration renewAfter;
  final AccountDeviceLeaseHolder holder;

  factory AccountDeviceLeaseReceipt.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime lease');
    _requireExactKeys(json, const <String>{
      'agentId',
      'leaseId',
      'epoch',
      'installationId',
      'runtimeInstanceId',
      'presenceSessionId',
      'expiresAt',
      'remainingTtlMs',
      'renewAfterMs',
      'holder',
    }, 'runtime lease');
    _rejectSecretFields(json, 'runtime lease');
    final remainingTtl = _requiredMilliseconds(
      json,
      'remainingTtlMs',
      allowZero: false,
    );
    final renewAfter = _requiredMilliseconds(json, 'renewAfterMs');
    if (renewAfter > remainingTtl) {
      throw const FormatException(
        'runtime lease renewAfterMs exceeds remainingTtlMs',
      );
    }
    final installationId = _requiredOpaqueId(json, 'installationId');
    final runtimeInstanceId = _requiredOpaqueId(json, 'runtimeInstanceId');
    final presenceSessionId = _requiredOpaqueId(json, 'presenceSessionId');
    final holder = AccountDeviceLeaseHolder.fromJson(json['holder']);
    if (holder.installationId != installationId ||
        holder.runtimeInstanceId != runtimeInstanceId ||
        holder.presenceSessionId != presenceSessionId) {
      throw const FormatException(
        'runtime lease holder does not match the lease identity',
      );
    }
    return AccountDeviceLeaseReceipt(
      agentId: _requiredAgentId(json),
      leaseId: _requiredOpaqueId(json, 'leaseId'),
      epoch: _requiredJsonInteger(json, 'epoch', minimum: 1),
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: _requiredUtcTimestamp(json, 'expiresAt'),
      remainingTtl: remainingTtl,
      renewAfter: renewAfter,
      holder: holder,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'agentId': agentId,
    'leaseId': leaseId,
    'epoch': epoch,
    'installationId': installationId,
    'runtimeInstanceId': runtimeInstanceId,
    'presenceSessionId': presenceSessionId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'remainingTtlMs': remainingTtl.inMilliseconds,
    'renewAfterMs': renewAfter.inMilliseconds,
    'holder': holder.toJson(),
  };

  @override
  String toString() =>
      'AccountDeviceLeaseReceipt(agentId: $agentId, leaseId: $leaseId, '
      'epoch: $epoch, installationId: $installationId, '
      'runtimeInstanceId: $runtimeInstanceId, '
      'presenceSessionId: $presenceSessionId, expiresAt: $expiresAt)';
}

enum AccountDeviceLeaseRemoteState { inactive, active }

class AccountDeviceLeaseSnapshot {
  const AccountDeviceLeaseSnapshot({required this.state, this.lease});

  final AccountDeviceLeaseRemoteState state;
  final AccountDeviceLeaseReceipt? lease;

  factory AccountDeviceLeaseSnapshot.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime lease snapshot');
    _requireExactKeys(json, const <String>{
      'state',
      'lease',
    }, 'runtime lease snapshot');
    _rejectSecretFields(json, 'runtime lease snapshot');
    if (!json.containsKey('lease')) {
      throw const FormatException('runtime lease snapshot is missing lease');
    }
    final state = switch (json['state']) {
      'inactive' => AccountDeviceLeaseRemoteState.inactive,
      'active' => AccountDeviceLeaseRemoteState.active,
      _ => throw const FormatException('runtime lease state is invalid'),
    };
    final rawLease = json['lease'];
    if ((state == AccountDeviceLeaseRemoteState.inactive && rawLease != null) ||
        (state == AccountDeviceLeaseRemoteState.active && rawLease == null)) {
      throw const FormatException(
        'runtime lease snapshot state and receipt do not match',
      );
    }
    return AccountDeviceLeaseSnapshot(
      state: state,
      lease: rawLease == null
          ? null
          : AccountDeviceLeaseReceipt.fromJson(rawLease),
    );
  }
}

class AccountDevicePresenceOperationResult {
  const AccountDevicePresenceOperationResult({
    required this.presence,
    required this.replayed,
  });

  final AccountDevicePresenceReceipt presence;
  final bool replayed;
}

class AccountDevicePresenceCloseResult {
  const AccountDevicePresenceCloseResult({
    required this.closed,
    required this.stale,
    required this.generation,
  });

  final bool closed;
  final bool stale;
  final int generation;
}

class AccountDeviceLeaseOperationResult {
  const AccountDeviceLeaseOperationResult({
    required this.lease,
    required this.replayed,
  });

  final AccountDeviceLeaseReceipt lease;
  final bool replayed;
}

class AccountDeviceLeaseReleaseResult {
  const AccountDeviceLeaseReleaseResult({
    required this.released,
    required this.stale,
    required this.epoch,
  });

  final bool released;
  final bool stale;
  final int epoch;
}

class AccountDeviceLeaseConflict implements Exception {
  const AccountDeviceLeaseConflict({
    required this.observedEpoch,
    required this.holder,
    required this.expiresAt,
    required this.remainingTtl,
  });

  final int observedEpoch;
  final AccountDeviceLeaseHolder holder;
  final DateTime expiresAt;
  final Duration remainingTtl;

  factory AccountDeviceLeaseConflict.fromJson(Object? source) {
    final json = _requiredMap(source, 'runtime lease conflict');
    _requireExactKeys(json, const <String>{
      'observedEpoch',
      'holder',
      'expiresAt',
      'remainingTtlMs',
    }, 'runtime lease conflict');
    _rejectSecretFields(json, 'runtime lease conflict');
    return AccountDeviceLeaseConflict(
      observedEpoch: _requiredJsonInteger(json, 'observedEpoch', minimum: 1),
      holder: AccountDeviceLeaseHolder.fromJson(json['holder']),
      expiresAt: _requiredUtcTimestamp(json, 'expiresAt'),
      remainingTtl: _requiredMilliseconds(
        json,
        'remainingTtlMs',
        allowZero: false,
      ),
    );
  }

  @override
  String toString() =>
      'AccountDeviceLeaseConflict(observedEpoch: $observedEpoch, '
      'expiresAt: $expiresAt)';
}

Map<String, Object?> _requiredMap(Object? source, String name) {
  if (source is! Map) throw FormatException('$name is invalid');
  return Map<String, Object?>.from(source);
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String name,
) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('$name contains an unknown field');
  }
}

void _rejectSecretFields(Map<String, Object?> json, String name) {
  const forbidden = <String>{
    'holderProof',
    'holderProofHash',
    'proof',
    'proofHash',
    'accessToken',
    'refreshToken',
    'rtcToken',
  };
  if (json.keys.any(forbidden.contains)) {
    throw FormatException('$name contains a forbidden secret field');
  }
}

String _requiredAgentId(Map<String, Object?> json) {
  final value = _requiredTrimmed(json, 'agentId', maximumLength: 64);
  if (value != 'self') {
    throw const FormatException('runtime authority agentId is invalid');
  }
  return value;
}

String _requiredOpaqueId(Map<String, Object?> json, String key) {
  final value = _requiredTrimmed(json, key, maximumLength: 128);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('runtime authority $key is invalid');
  }
  return value;
}

String _requiredDeviceLabel(Map<String, Object?> json, String key) {
  final value = _requiredTrimmed(json, key, maximumLength: 80);
  if (value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw FormatException('runtime authority $key is invalid');
  }
  return value;
}

String _requiredPlatform(Map<String, Object?> json, String key) {
  final value = _requiredTrimmed(json, key, maximumLength: 16);
  if (!_supportedDevicePlatforms.contains(value)) {
    throw FormatException('runtime authority $key is invalid');
  }
  return value;
}

String _requiredTrimmed(
  Map<String, Object?> json,
  String key, {
  required int maximumLength,
}) {
  final source = json[key];
  if (source is! String ||
      source != source.trim() ||
      source.isEmpty ||
      source.runes.length > maximumLength) {
    throw FormatException('runtime authority $key is invalid');
  }
  return source;
}

String _optionalAscii(
  Map<String, Object?> json,
  String key, {
  required int maximumLength,
}) {
  final source = json[key];
  if (source == null) return '';
  if (source is! String ||
      source != source.trim() ||
      source.runes.length > maximumLength ||
      source.codeUnits.any((value) => value < 0x20 || value > 0x7e)) {
    throw FormatException('runtime authority $key is invalid');
  }
  return source;
}

int _requiredJsonInteger(
  Map<String, Object?> json,
  String key, {
  required int minimum,
}) {
  final source = json[key];
  if (source is! int ||
      source < minimum ||
      source > maxAccountDeviceLeaseJsonInteger) {
    throw FormatException('runtime authority $key is invalid');
  }
  return source;
}

Duration _requiredMilliseconds(
  Map<String, Object?> json,
  String key, {
  bool allowZero = true,
}) {
  final value = _requiredJsonInteger(json, key, minimum: allowZero ? 0 : 1);
  return Duration(milliseconds: value);
}

DateTime _requiredUtcTimestamp(Map<String, Object?> json, String key) {
  final source = json[key];
  if (source is! String ||
      source != source.trim() ||
      source.length > 40 ||
      !source.endsWith('Z')) {
    throw FormatException('runtime authority $key is invalid');
  }
  final parsed = DateTime.tryParse(source);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('runtime authority $key is invalid');
  }
  return parsed;
}
