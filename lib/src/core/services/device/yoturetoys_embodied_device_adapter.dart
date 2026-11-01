import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';

typedef YoturetoysAdapterClock = DateTime Function();
typedef YoturetoysBackgroundReader = bool Function();
typedef YoturetoysAdapterAuthorityReader =
    bool Function(String accountId, int facadeGeneration);
typedef YoturetoysMonotonicClock = int Function();

/// Semantic, account-scoped view of the process-global Yoturetoys projector.
///
/// The current projector protocol has no locomotion or physical-stop command.
/// This adapter therefore exposes only status/health and returns `unsupported`
/// for every motion/stop operation. It never translates a motion into a BLE
/// write and never claims a dead-man SLA the hardware cannot satisfy.
final class YoturetoysEmbodiedDeviceAdapter implements EmbodiedDeviceFacade {
  YoturetoysEmbodiedDeviceAdapter({
    required YoturetoysDevice device,
    required String accountId,
    required int facadeGeneration,
    required YoturetoysAdapterAuthorityReader authorityIsCurrent,
    required EmbodiedMotionCapabilityVerifier motionCapabilityVerifier,
    String deviceId = YoturetoysDevice.productName,
    YoturetoysAdapterClock? clock,
    YoturetoysMonotonicClock? monotonicClock,
    YoturetoysBackgroundReader? backgrounded,
  }) : _device = device,
       deviceId = _validatedDeviceId(deviceId),
       accountId = _validatedAccountId(accountId),
       facadeGeneration = _validatedGeneration(facadeGeneration),
       _authorityIsCurrent = authorityIsCurrent,
       _motionCapabilityVerifier = motionCapabilityVerifier,
       _clock = clock ?? DateTime.now,
       _monotonicClock = monotonicClock ?? _processMonotonicMicros,
       _backgrounded = backgrounded ?? _foreground;

  final YoturetoysDevice _device;
  final YoturetoysAdapterClock _clock;
  final YoturetoysMonotonicClock _monotonicClock;
  final YoturetoysBackgroundReader _backgrounded;
  final YoturetoysAdapterAuthorityReader _authorityIsCurrent;
  final EmbodiedMotionCapabilityVerifier _motionCapabilityVerifier;
  final Set<Future<void>> _operations = <Future<void>>{};
  bool _retired = false;
  Future<void>? _retireFuture;

  @override
  final String deviceId;

  @override
  final String accountId;

  @override
  final int facadeGeneration;

  @override
  Future<List<EmbodiedCapabilitySnapshot>> capabilities() =>
      _runAccountOperation(() async {
        final now = _clock().toUtc();
        return List<EmbodiedCapabilitySnapshot>.unmodifiable(
          <EmbodiedCapabilitySnapshot>[
            for (final capability in EmbodiedDeviceCapability.values)
              EmbodiedCapabilitySnapshot(
                capability: capability,
                supported:
                    capability == EmbodiedDeviceCapability.status ||
                    capability == EmbodiedDeviceCapability.health,
                unit:
                    capability == EmbodiedDeviceCapability.status ||
                        capability == EmbodiedDeviceCapability.health
                    ? EmbodiedUnit.boolean
                    : EmbodiedUnit.none,
                capturedAt: now,
                freshness: EmbodiedFreshness.fresh,
                accountId: accountId,
                facadeGeneration: facadeGeneration,
              ),
          ],
        );
      });

  /// Dynamic telemetry seam consumed by [EmbodiedDeviceSupervisor].
  ///
  /// This is deliberately an adapter method rather than raw transport access.
  @override
  Future<EmbodiedDeviceTelemetry> telemetry() => _runAccountOperation(() async {
    final connected = _device.isConnected.value;
    return EmbodiedDeviceTelemetry(
      unit: EmbodiedUnit.boolean,
      capturedAt: _clock().toUtc(),
      freshness: EmbodiedFreshness.fresh,
      accountId: accountId,
      facadeGeneration: facadeGeneration,
      connected: connected,
      backgrounded: _backgrounded(),
      value: EmbodiedBooleanValue(connected),
    );
  });

  @override
  Future<EmbodiedDeviceResult> status() => _runAccountOperation(
    () async => _connectionResult(EmbodiedDeviceCapability.status),
  );

  @override
  Future<EmbodiedDeviceResult> health() => _runAccountOperation(
    () async => _connectionResult(EmbodiedDeviceCapability.health),
  );

  @override
  Future<EmbodiedDeviceResult> sense(EmbodiedSenseRequest request) =>
      _unsupported(EmbodiedDeviceCapability.sense);

  @override
  EmbodiedDeadManArmOperation armDeadMan(EmbodiedMotionCapability capability) {
    _requireCurrentAuthority();
    return _YoturetoysDeadManArmOperation(
      result: Future<EmbodiedDeadManArmResult>.value(
        const EmbodiedDeadManArmResult(
          status: EmbodiedDeadManArmStatus.unsupported,
        ),
      ),
    );
  }

  @override
  EmbodiedMotionOperation beginMotion(
    EmbodiedMotionCapability capability,
    EmbodiedDeadManReceipt deadManReceipt,
  ) {
    _requireCurrentAuthority();
    late final Future<EmbodiedDeviceResult> result;
    try {
      final motion = _motionCapabilityVerifier.consume(
        capability,
        deadManReceipt,
        monotonicNowMicros: _monotonicClock(),
      );
      final identityMatches =
          motion.accountId == accountId &&
          motion.facadeGeneration == facadeGeneration;
      result = identityMatches
          ? _unsupported(motion.capability)
          : Future<EmbodiedDeviceResult>.error(
              StateError('embodied_adapter_capability_stale'),
            );
    } on Object catch (error, stackTrace) {
      result = Future<EmbodiedDeviceResult>.error(error, stackTrace);
    }
    return _YoturetoysMotionOperation(
      capabilityId: capability.id,
      result: result,
    );
  }

  @override
  EmbodiedStopOperation beginStop() {
    _requireCurrentAuthority();
    return _YoturetoysStopOperation(
      _unsupported(EmbodiedDeviceCapability.stop),
    );
  }

  @override
  Future<void> retireAndDrain() {
    final existing = _retireFuture;
    if (existing != null) return existing;
    // Fence every public adapter operation before yielding to the device
    // account lane. Retirement is intentionally independent from the storage
    // mount authority: AccountSessionLifecycleService invalidates that mount
    // before closing the owned runtime, while the permanent device account
    // lane remains available until its later drain barrier.
    _retired = true;
    final retiring = _waitForOperations();
    _retireFuture = retiring;
    return retiring;
  }

  EmbodiedDeviceResult _connectionResult(EmbodiedDeviceCapability capability) {
    final connected = _device.isConnected.value;
    return EmbodiedDeviceResult(
      capability: capability,
      status: EmbodiedResultStatus.ok,
      unit: EmbodiedUnit.boolean,
      capturedAt: _clock().toUtc(),
      freshness: EmbodiedFreshness.fresh,
      accountId: accountId,
      facadeGeneration: facadeGeneration,
      value: EmbodiedBooleanValue(connected),
    );
  }

  Future<EmbodiedDeviceResult> _unsupported(
    EmbodiedDeviceCapability capability,
  ) => _runAccountOperation(
    () async => EmbodiedDeviceResult(
      capability: capability,
      status: EmbodiedResultStatus.unsupported,
      unit: EmbodiedUnit.none,
      capturedAt: _clock().toUtc(),
      freshness: EmbodiedFreshness.fresh,
      accountId: accountId,
      facadeGeneration: facadeGeneration,
      diagnostic: 'capability_unsupported',
    ),
  );

  Future<T> _runAccountOperation<T>(Future<T> Function() operation) {
    try {
      _requireCurrentAuthority();
    } on Object catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
    final result = _device.runAccountOperation(() async {
      _requireCurrentAuthority();
      final result = await operation();
      _requireCurrentAuthority();
      return result;
    });
    late final Future<void> tracked;
    tracked = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
    return result;
  }

  Future<void> _waitForOperations() async {
    while (_operations.isNotEmpty) {
      await Future.wait<void>(
        _operations.toList(growable: false),
        eagerError: false,
      );
    }
  }

  void _requireCurrentAuthority() {
    if (_retired) throw StateError('embodied_adapter_retired');
    _requireAccountAuthority();
  }

  void _requireAccountAuthority() {
    var current = false;
    try {
      current = _authorityIsCurrent(accountId, facadeGeneration);
    } on Object {
      current = false;
    }
    if (!current) throw StateError('embodied_adapter_authority_stale');
  }

  static String _validatedAccountId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 256) {
      throw ArgumentError.value(value, 'accountId');
    }
    return normalized;
  }

  static String _validatedDeviceId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw ArgumentError.value(value, 'deviceId');
    }
    return normalized;
  }

  static int _validatedGeneration(int value) {
    if (value < 1) throw ArgumentError.value(value, 'facadeGeneration');
    return value;
  }

  static bool _foreground() => false;

  static final Stopwatch _processMonotonic = Stopwatch()..start();
  static int _processMonotonicMicros() => _processMonotonic.elapsedMicroseconds;
}

final class _YoturetoysMotionOperation implements EmbodiedMotionOperation {
  const _YoturetoysMotionOperation({
    required this.capabilityId,
    required this.result,
  });

  @override
  final String capabilityId;

  @override
  final Future<EmbodiedDeviceResult> result;

  @override
  Future<void> cancelAndDrain() => Future<void>.value();
}

final class _YoturetoysDeadManArmOperation
    implements EmbodiedDeadManArmOperation {
  const _YoturetoysDeadManArmOperation({required this.result});

  @override
  final Future<EmbodiedDeadManArmResult> result;

  @override
  Future<void> cancelAndDrain() => Future<void>.value();
}

final class _YoturetoysStopOperation implements EmbodiedStopOperation {
  const _YoturetoysStopOperation(this.result);

  @override
  final Future<EmbodiedDeviceResult> result;

  @override
  Future<void> cancelAndDrain() => Future<void>.value();
}
