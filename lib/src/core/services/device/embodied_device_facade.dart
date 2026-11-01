enum EmbodiedDeviceCapability {
  status,
  health,
  sense,
  face,
  move,
  nod,
  shake,
  home,
  stop,
}

enum EmbodiedPermissionTier { readOnly, consequentialMotion, emergencySafety }

extension EmbodiedDeviceCapabilityPolicy on EmbodiedDeviceCapability {
  EmbodiedPermissionTier get permissionTier => switch (this) {
    EmbodiedDeviceCapability.status ||
    EmbodiedDeviceCapability.health ||
    EmbodiedDeviceCapability.sense => EmbodiedPermissionTier.readOnly,
    EmbodiedDeviceCapability.face ||
    EmbodiedDeviceCapability.move ||
    EmbodiedDeviceCapability.nod ||
    EmbodiedDeviceCapability.shake ||
    EmbodiedDeviceCapability.home => EmbodiedPermissionTier.consequentialMotion,
    EmbodiedDeviceCapability.stop => EmbodiedPermissionTier.emergencySafety,
  };
}

enum EmbodiedUnit {
  none,
  boolean,
  normalized,
  meters,
  degrees,
  metersPerSecond,
  milliseconds,
}

enum EmbodiedFreshness { fresh, stale, unknown }

enum EmbodiedResultStatus { ok, unsupported, denied, failed }

enum EmbodiedSenseKind { distance, orientation, obstacle, battery }

sealed class EmbodiedResultValue {
  const EmbodiedResultValue();
}

final class EmbodiedBooleanValue extends EmbodiedResultValue {
  const EmbodiedBooleanValue(this.value);

  final bool value;
}

final class EmbodiedNumericValue extends EmbodiedResultValue {
  const EmbodiedNumericValue(this.value);

  final double value;
}

final class EmbodiedCapabilitySnapshot {
  const EmbodiedCapabilitySnapshot({
    required this.capability,
    required this.supported,
    required this.unit,
    required this.capturedAt,
    required this.freshness,
    required this.accountId,
    required this.facadeGeneration,
  });

  final EmbodiedDeviceCapability capability;
  final bool supported;
  final EmbodiedUnit unit;
  final DateTime capturedAt;
  final EmbodiedFreshness freshness;
  final String accountId;
  final int facadeGeneration;
}

final class EmbodiedDeviceTelemetry {
  const EmbodiedDeviceTelemetry({
    required this.unit,
    required this.capturedAt,
    required this.freshness,
    required this.accountId,
    required this.facadeGeneration,
    required this.connected,
    required this.backgrounded,
    this.value,
  });

  final EmbodiedUnit unit;
  final DateTime capturedAt;
  final EmbodiedFreshness freshness;
  final String accountId;
  final int facadeGeneration;
  final bool connected;
  final bool backgrounded;
  final EmbodiedResultValue? value;
}

final class EmbodiedDeviceResult {
  const EmbodiedDeviceResult({
    required this.capability,
    required this.status,
    required this.unit,
    required this.capturedAt,
    required this.freshness,
    required this.accountId,
    required this.facadeGeneration,
    this.value,
    this.diagnostic,
  });

  final EmbodiedDeviceCapability capability;
  final EmbodiedResultStatus status;
  final EmbodiedUnit unit;
  final DateTime capturedAt;
  final EmbodiedFreshness freshness;
  final String accountId;
  final int facadeGeneration;
  final EmbodiedResultValue? value;
  final String? diagnostic;
}

final class EmbodiedSenseRequest {
  const EmbodiedSenseRequest({required this.kind, required this.unit});

  final EmbodiedSenseKind kind;
  final EmbodiedUnit unit;
}

/// A semantic physical intent. Values are untrusted until bounded by
/// `PhysicalMotionPolicy`.
final class EmbodiedMotionRequest {
  const EmbodiedMotionRequest({
    required this.capability,
    this.distanceMeters = 0,
    this.angleDegrees = 0,
    this.speedMetersPerSecond = 0.25,
    this.duration = const Duration(milliseconds: 500),
  });

  final EmbodiedDeviceCapability capability;
  final double distanceMeters;
  final double angleDegrees;
  final double speedMetersPerSecond;
  final Duration duration;
}

/// A one-use capability minted by the supervisor's exclusive issuer.
///
/// Construction and payload are private. A facade accepts it only through the
/// paired verifier that was created with the issuer and consumes it once.
final class EmbodiedMotionCapability {
  // These initializers deliberately live outside the public API surface. The
  // adapter can inspect the bounded plan only after its paired verifier has
  // consumed the capability.
  EmbodiedMotionCapability._opaque({
    required Object authority,
    required String id,
    required String accountId,
    required int facadeGeneration,
    required EmbodiedDeviceCapability capability,
    required double distanceMeters,
    required double angleDegrees,
    required double speedMetersPerSecond,
    required Duration duration,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) : _authority = authority,
       _id = id,
       _accountId = accountId,
       _facadeGeneration = facadeGeneration,
       _capability = capability,
       _distanceMeters = distanceMeters,
       _angleDegrees = angleDegrees,
       _speedMetersPerSecond = speedMetersPerSecond,
       _duration = duration,
       _issuedAt = issuedAt,
       _expiresAt = expiresAt;

  final Object _authority;
  final String _id;
  final String _accountId;
  final int _facadeGeneration;
  final EmbodiedDeviceCapability _capability;
  final double _distanceMeters;
  final double _angleDegrees;
  final double _speedMetersPerSecond;
  final Duration _duration;
  final DateTime _issuedAt;
  final DateTime _expiresAt;
  bool _consumed = false;

  /// Correlation only; the bounded motion payload remains verifier-private.
  String get id => _id;
}

final class EmbodiedMotionAuthorityPair {
  EmbodiedMotionAuthorityPair._(this.issuer, this.verifier);

  final EmbodiedMotionCapabilityIssuer issuer;
  final EmbodiedMotionCapabilityVerifier verifier;
}

EmbodiedMotionAuthorityPair createEmbodiedMotionAuthorityPair() {
  final authority = Object();
  return EmbodiedMotionAuthorityPair._(
    EmbodiedMotionCapabilityIssuer._(authority),
    EmbodiedMotionCapabilityVerifier._(authority),
  );
}

/// The supervisor claims this issuer once using its private object identity.
final class EmbodiedMotionCapabilityIssuer {
  EmbodiedMotionCapabilityIssuer._(this._authority);

  final Object _authority;
  Object? _owner;
  var _sequence = 0;

  void claim(Object owner) {
    final current = _owner;
    if (current != null && !identical(current, owner)) {
      throw StateError('embodied_motion_issuer_already_claimed');
    }
    _owner = owner;
  }

  EmbodiedMotionCapability issue({
    required Object owner,
    required String accountId,
    required int facadeGeneration,
    required EmbodiedDeviceCapability capability,
    required double distanceMeters,
    required double angleDegrees,
    required double speedMetersPerSecond,
    required Duration duration,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) {
    if (!identical(_owner, owner)) {
      throw StateError('embodied_motion_issuer_not_owned');
    }
    _sequence += 1;
    return EmbodiedMotionCapability._opaque(
      authority: _authority,
      id: 'opaque-motion-$facadeGeneration-$_sequence',
      accountId: accountId,
      facadeGeneration: facadeGeneration,
      capability: capability,
      distanceMeters: distanceMeters,
      angleDegrees: angleDegrees,
      speedMetersPerSecond: speedMetersPerSecond,
      duration: duration,
      issuedAt: issuedAt.toUtc(),
      expiresAt: expiresAt.toUtc(),
    );
  }
}

final class EmbodiedDeadManReceipt {
  EmbodiedDeadManReceipt._({
    required Object authority,
    required String capabilityId,
    required int monotonicArmedAtMicros,
    required int monotonicExpiresAtMicros,
  }) : _authority = authority,
       _capabilityId = capabilityId,
       _monotonicArmedAtMicros = monotonicArmedAtMicros,
       _monotonicExpiresAtMicros = monotonicExpiresAtMicros;

  final Object _authority;
  final String _capabilityId;
  final int _monotonicArmedAtMicros;
  final int _monotonicExpiresAtMicros;
}

final class VerifiedEmbodiedMotion {
  const VerifiedEmbodiedMotion._({
    required this.id,
    required this.accountId,
    required this.facadeGeneration,
    required this.capability,
    required this.distanceMeters,
    required this.angleDegrees,
    required this.speedMetersPerSecond,
    required this.duration,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String id;
  final String accountId;
  final int facadeGeneration;
  final EmbodiedDeviceCapability capability;
  final double distanceMeters;
  final double angleDegrees;
  final double speedMetersPerSecond;
  final Duration duration;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

/// Held only by the facade implementation; never by runtime or UI callers.
final class EmbodiedMotionCapabilityVerifier {
  EmbodiedMotionCapabilityVerifier._(this._authority);

  final Object _authority;

  bool recognizes(EmbodiedMotionCapability capability) =>
      identical(capability._authority, _authority) && !capability._consumed;

  EmbodiedDeadManReceipt recordHardwareDeadManArmed({
    required EmbodiedMotionCapability capability,
    required int monotonicArmedAtMicros,
    required int monotonicExpiresAtMicros,
  }) {
    final maximumTtlMicros = capability._expiresAt
        .difference(capability._issuedAt)
        .inMicroseconds;
    if (!recognizes(capability) ||
        maximumTtlMicros <= 0 ||
        monotonicArmedAtMicros < 0 ||
        monotonicExpiresAtMicros <= monotonicArmedAtMicros ||
        monotonicExpiresAtMicros - monotonicArmedAtMicros > maximumTtlMicros) {
      throw StateError('embodied_dead_man_arm_invalid');
    }
    return EmbodiedDeadManReceipt._(
      authority: _authority,
      capabilityId: capability._id,
      monotonicArmedAtMicros: monotonicArmedAtMicros,
      monotonicExpiresAtMicros: monotonicExpiresAtMicros,
    );
  }

  VerifiedEmbodiedMotion consume(
    EmbodiedMotionCapability capability,
    EmbodiedDeadManReceipt receipt, {
    required int monotonicNowMicros,
  }) {
    if (!recognizes(capability) ||
        !identical(receipt._authority, _authority) ||
        receipt._capabilityId != capability._id ||
        monotonicNowMicros < receipt._monotonicArmedAtMicros ||
        monotonicNowMicros >= receipt._monotonicExpiresAtMicros) {
      throw StateError('embodied_motion_capability_invalid');
    }
    capability._consumed = true;
    return VerifiedEmbodiedMotion._(
      id: capability._id,
      accountId: capability._accountId,
      facadeGeneration: capability._facadeGeneration,
      capability: capability._capability,
      distanceMeters: capability._distanceMeters,
      angleDegrees: capability._angleDegrees,
      speedMetersPerSecond: capability._speedMetersPerSecond,
      duration: capability._duration,
      issuedAt: capability._issuedAt,
      expiresAt: capability._expiresAt,
    );
  }
}

enum EmbodiedDeadManArmStatus { armed, unsupported, failed }

final class EmbodiedDeadManArmResult {
  const EmbodiedDeadManArmResult({required this.status, this.receipt});

  final EmbodiedDeadManArmStatus status;
  final EmbodiedDeadManReceipt? receipt;

  bool get isArmed =>
      status == EmbodiedDeadManArmStatus.armed && receipt != null;
}

abstract interface class EmbodiedDeadManArmOperation {
  /// Completion means the adapter's arm transport has settled. After either
  /// [result] or [cancelAndDrain], no late arm can enable an expired attempt.
  Future<EmbodiedDeadManArmResult> get result;

  Future<void> cancelAndDrain();
}

/// One transport-linearized consequential motion attempt.
///
/// Calling [cancelAndDrain] must synchronously fence any dispatch that has not
/// reached the physical transport. Its returned future completes only after no
/// write belonging to this operation can occur. [result] completion carries
/// the same drain guarantee. Both operations must be idempotent and ordered in
/// the same transport lane as [EmbodiedDeviceFacade.stop].
abstract interface class EmbodiedMotionOperation {
  String get capabilityId;

  Future<EmbodiedDeviceResult> get result;

  Future<void> cancelAndDrain();
}

abstract interface class EmbodiedStopOperation {
  /// Completion means the physical stop transport lane has settled. After
  /// either [result] or [cancelAndDrain], no write from this operation may
  /// arrive in a later facade generation.
  Future<EmbodiedDeviceResult> get result;

  Future<void> cancelAndDrain();
}

/// Transport-independent semantic surface for embodied devices.
///
/// Implementations may translate these operations internally, but callers get
/// no transport primitives or unrestricted write surface.
abstract interface class EmbodiedDeviceFacade {
  String get deviceId;

  String get accountId;

  int get facadeGeneration;

  Future<List<EmbodiedCapabilitySnapshot>> capabilities();

  Future<EmbodiedDeviceResult> status();

  Future<EmbodiedDeviceResult> health();

  Future<EmbodiedDeviceTelemetry> telemetry();

  Future<EmbodiedDeviceResult> sense(EmbodiedSenseRequest request);

  /// Arms an adapter/hardware monotonic TTL before any physical movement.
  EmbodiedDeadManArmOperation armDeadMan(EmbodiedMotionCapability capability);

  /// Starts a cancellable motion after successful hardware dead-man arming.
  EmbodiedMotionOperation beginMotion(
    EmbodiedMotionCapability capability,
    EmbodiedDeadManReceipt deadManReceipt,
  );

  /// Emergency stop, ordered with motion and cancellable on timeout.
  EmbodiedStopOperation beginStop();

  /// Permanently fences admission and drains every transport operation.
  Future<void> retireAndDrain();
}
