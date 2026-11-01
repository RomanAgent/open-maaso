import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// One discovered peripheral the UI / agent can choose to connect to.
class BleScanEntry {
  BleScanEntry({required this.device, required this.rssi, this.label, this.sn});

  final BluetoothDevice device;
  final int rssi;

  /// Human label (advertised name) and a device-decoded serial, when known.
  final String? label;
  final String? sn;

  String get id => device.remoteId.str;
}

/// What a per-device protocol needs the transport to know: which GATT
/// service/characteristics to bind, how to recognise the product while
/// scanning, and how to pull a serial out of its advertisement.
class BleDeviceProfile {
  const BleDeviceProfile({
    required this.serviceId,
    required this.writeId,
    required this.notifyId,
    required this.advertisedName,
    this.manufacturerId,
    this.snFromManufacturerData,
  });

  final String serviceId;
  final String writeId;
  final String notifyId;
  final String advertisedName;

  /// Manufacturer-specific data id used to filter our product (e.g. 0xAA55).
  final int? manufacturerId;

  /// Decode a serial from the manufacturer payload (optional).
  final String? Function(List<int> data)? snFromManufacturerData;
}

/// Account ownership state of the process-global BLE stack.
enum BleAccountLifecycleState { inactive, active, retiring }

/// A BLE operation attempted without a mounted account, or while the previous
/// account is still being drained.
final class BleAccountUnavailable implements Exception {
  const BleAccountUnavailable(this.state);

  final BleAccountLifecycleState state;

  @override
  String toString() => 'BLE account runtime is ${state.name}.';
}

/// An admitted operation whose account generation was retired while it was
/// waiting for the platform.
final class BleAccountOperationCancelled implements Exception {
  const BleAccountOperationCancelled();

  @override
  String toString() => 'BLE operation belongs to a retired account runtime.';
}

final class BleCapabilityUnavailable implements Exception {
  const BleCapabilityUnavailable(this.code);

  const BleCapabilityUnavailable.denied() : code = 'capability_unavailable';

  const BleCapabilityUnavailable.stale() : code = 'capability_snapshot_stale';

  final String code;

  @override
  String toString() => code;
}

/// Exact snapshot authority for one admitted Bluetooth operation.
final class BleCapabilityAuthority {
  const BleCapabilityAuthority._(this._snapshots, this._lease);

  final AppCapabilitySnapshotService _snapshots;
  final AppCapabilitySnapshotLease _lease;

  Future<void> get whenInvalidated => _lease.whenInvalidated;

  void requireCurrent() {
    try {
      _snapshots.requireCurrent(_lease);
    } on StateError {
      throw const BleCapabilityUnavailable.stale();
    }
  }
}

/// A raw notification together with the account generation that admitted its
/// platform subscription. Consumers must match this before correlating ACKs.
final class BleNotificationFrame {
  const BleNotificationFrame({required this.generation, required this.bytes});

  final int generation;
  final List<int> bytes;
}

/// Testable boundary around flutter_blue_plus. Production uses the default
/// implementation below; focused lifecycle tests inject a deterministic
/// driver without touching a host Bluetooth adapter.
abstract interface class BleTransportDriver {
  Stream<BluetoothAdapterState> get adapterStates;
  BluetoothAdapterState get adapterStateNow;
  Stream<bool> get scanStates;
  Stream<List<ScanResult>> get scanResults;
  bool get isScanningNow;

  Future<bool> isSupported();
  Future<void> turnOn();
  Future<void> startScan(BleDeviceProfile profile, Duration timeout);
  Future<void> stopScan();
  Future<BleTransportConnection> connect(
    BluetoothDevice device,
    BleDeviceProfile profile,
  );

  /// Disconnects a device before GATT discovery has produced a connection.
  Future<void> disconnectDevice(BluetoothDevice device);
}

/// One discovered and notification-enabled BLE connection.
abstract interface class BleTransportConnection {
  BluetoothDevice get device;
  int get mtu;
  Stream<BluetoothConnectionState> get states;
  Stream<List<int>> get notifications;

  Future<void> write(List<int> bytes, {bool allowLongWrite = false});
  Future<void> disconnect();
}

final class _PendingBleConnection {
  _PendingBleConnection(this.device);

  final BluetoothDevice device;
  BleTransportConnection? connection;
  bool rawDisconnectSucceeded = false;
  bool operationSettled = false;
  bool claimedByOperation = false;
}

/// Device-agnostic BLE transport shared by every Bluetooth sub-skill and the
/// official applets. It is process-global but account-inactive by default.
/// Every radio operation is admitted against an account generation, and
/// account teardown retains the retiring state until all physical resources
/// have been stopped successfully.
class BleTransportService extends AppService {
  BleTransportService({BleTransportDriver? driver})
    : _driver = driver ?? _FlutterBlueTransportDriver();

  final BleTransportDriver _driver;

  // —— observable state (drives applet UI + skill status) ——
  final Rx<BluetoothAdapterState> adapterState = Rx<BluetoothAdapterState>(
    BluetoothAdapterState.unknown,
  );
  final RxBool isScanning = false.obs;
  final RxBool isConnected = false.obs;
  final RxMap<String, BleScanEntry> found = <String, BleScanEntry>{}.obs;
  final Rxn<BluetoothDevice> connected = Rxn<BluetoothDevice>();

  BleDeviceProfile? _profile;
  BleTransportConnection? _connection;
  final Set<BleTransportConnection> _connectionsToClose =
      <BleTransportConnection>{};
  final Set<_PendingBleConnection> _pendingConnections =
      <_PendingBleConnection>{};

  final StreamController<BleNotificationFrame> _notifications =
      StreamController<BleNotificationFrame>.broadcast();

  /// Raw inbound notification frames tagged with their admitted account
  /// generation. The device facade performs the final ACK correlation check.
  Stream<BleNotificationFrame> get notifications => _notifications.stream;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  BleAccountLifecycleState _accountState = BleAccountLifecycleState.inactive;
  String? _activeScopeKey;
  int _accountGeneration = 0;
  final Set<Future<void>> _accountOperations = <Future<void>>{};
  Future<void> _radioOperationTail = Future<void>.value();
  Future<void>? _drainInFlight;
  BleCapabilityAuthority? _activeCapabilityAuthority;
  BleCapabilityAuthority? _capabilityCleanupAuthority;
  Future<void>? _capabilityCleanupInFlight;

  static final Set<AppCapabilityKey> bluetoothCapabilityKeys =
      Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
        AppCapabilityKey.platformAction(AppActionCapability.bluetooth),
      });

  BleAccountLifecycleState get accountState => _accountState;
  int get accountGeneration => _accountGeneration;
  bool get isReady => _connection != null;
  int get mtu => _connection?.mtu ?? 23;

  bool get bluetoothAvailable {
    final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
    if (snapshots == null) return true;
    if (snapshots.isClosed) return false;
    return snapshots.value.rejected(bluetoothCapabilityKeys).isEmpty;
  }

  BleCapabilityAuthority? acquireBluetoothAuthority() {
    final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
    if (snapshots == null) return null;
    if (snapshots.isClosed) {
      throw const BleCapabilityUnavailable.denied();
    }
    final acquisition = snapshots.acquireLease(
      bluetoothCapabilityKeys,
      requireVisible: true,
    );
    final lease = acquisition.lease;
    if (lease == null) throw const BleCapabilityUnavailable.denied();
    return BleCapabilityAuthority._(snapshots, lease);
  }

  bool isCurrentGeneration(int generation) =>
      _accountState == BleAccountLifecycleState.active &&
      generation == _accountGeneration;

  @override
  void onInit() {
    super.onInit();
    adapterState.value = _driver.adapterStateNow;
    _adapterSub = _driver.adapterStates.listen(
      (state) => adapterState.value = state,
      onError: (Object error) =>
          Log.w('🔵 [BLE] adapter stream failed: $error'),
    );
  }

  /// Admit the process-global radio stack for one account storage namespace.
  /// Re-entry for that exact namespace is idempotent; a different account is
  /// rejected until strict teardown reaches [BleAccountLifecycleState.inactive].
  void activateAccount({required String accountScopeKey}) {
    final normalized = accountScopeKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        accountScopeKey,
        'accountScopeKey',
        'must not be empty',
      );
    }
    if (_accountState == BleAccountLifecycleState.retiring) {
      throw const BleAccountUnavailable(BleAccountLifecycleState.retiring);
    }
    if (_accountState == BleAccountLifecycleState.active) {
      if (_activeScopeKey == normalized) return;
      throw const BleAccountUnavailable(BleAccountLifecycleState.active);
    }

    _activeScopeKey = normalized;
    _accountGeneration++;
    _accountState = BleAccountLifecycleState.active;
    _clearPublishedState();
  }

  /// Turn the radio on (Android only) and confirm it is available.
  Future<bool> ensureOn({BleCapabilityAuthority? capabilityAuthority}) {
    late final BleCapabilityAuthority? authority;
    try {
      authority = capabilityAuthority ?? acquireBluetoothAuthority();
      authority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<bool>.error(error, stackTrace);
    }
    return _runAccountOperation(
      (generation) => _ensureOn(generation, authority),
    );
  }

  Future<bool> _ensureOn(
    int generation,
    BleCapabilityAuthority? capabilityAuthority,
  ) async {
    capabilityAuthority?.requireCurrent();
    if (!await _driver.isSupported()) return false;
    capabilityAuthority?.requireCurrent();
    _requireCurrent(generation);
    if (Platform.isAndroid &&
        _driver.adapterStateNow != BluetoothAdapterState.on) {
      try {
        await _driver.turnOn();
      } catch (error) {
        Log.w('🔵 [BLE] turnOn failed: $error');
      }
      capabilityAuthority?.requireCurrent();
      _requireCurrent(generation);
    }
    return _driver.adapterStateNow == BluetoothAdapterState.on;
  }

  /// Scan for peripherals matching [profile] for [seconds]. Results accumulate
  /// into [found]. All result callbacks are fenced to this account generation.
  Future<void> scan(
    BleDeviceProfile profile, {
    int seconds = 10,
    BleCapabilityAuthority? capabilityAuthority,
  }) {
    late final BleCapabilityAuthority? authority;
    try {
      authority = capabilityAuthority ?? acquireBluetoothAuthority();
      authority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _runAccountOperation((generation) async {
      try {
        authority?.requireCurrent();
        _profile = profile;
        if (_driver.isScanningNow) return;
        if (!await _ensureOn(generation, authority)) {
          Log.w('🔵 [BLE] adapter not on; scan aborted');
          return;
        }
        authority?.requireCurrent();
        _requireCurrent(generation);
        await _activateCapabilityAuthority(authority);
        found.clear();
        await _replaceScanSubscriptions(profile, generation, authority);
        authority?.requireCurrent();
        _requireCurrent(generation);
        await _awaitCapabilityAuthority(
          _driver.startScan(profile, Duration(seconds: seconds)),
          authority,
        );
        authority?.requireCurrent();
        _requireCurrent(generation);
      } on BleCapabilityUnavailable {
        _scheduleCapabilityCleanup(authority);
        rethrow;
      }
    });
  }

  Future<void> _replaceScanSubscriptions(
    BleDeviceProfile profile,
    int generation,
    BleCapabilityAuthority? capabilityAuthority,
  ) async {
    await _cancelScanSubscriptions();
    _scanningSub = _driver.scanStates.listen((scanning) {
      if (isCurrentGeneration(generation) &&
          _isCapabilityAuthorityCurrent(capabilityAuthority)) {
        isScanning.value = scanning;
      }
    }, onError: (Object error) => Log.w('🔵 [BLE] scan state failed: $error'));
    _scanSub = _driver.scanResults.listen((results) {
      if (!isCurrentGeneration(generation) ||
          !_isCapabilityAuthorityCurrent(capabilityAuthority)) {
        return;
      }
      for (final result in results) {
        if (connected.value != null) continue;
        String? sn;
        final manufacturer = result.advertisementData.manufacturerData;
        if (profile.manufacturerId != null &&
            manufacturer.containsKey(profile.manufacturerId)) {
          sn = profile.snFromManufacturerData?.call(
            manufacturer[profile.manufacturerId]!,
          );
        }
        final name = result.advertisementData.advName;
        if (name != profile.advertisedName &&
            (profile.manufacturerId != null && sn == null)) {
          continue;
        }
        found[result.device.remoteId.str] = BleScanEntry(
          device: result.device,
          rssi: result.rssi,
          label: name.isNotEmpty ? name : profile.advertisedName,
          sn: sn,
        );
      }
    }, onError: (Object error) => Log.e('🔵 [BLE] scan failed: $error'));
  }

  Future<void> stopScan() {
    return _runAccountOperation((generation) async {
      await _driver.stopScan();
      _requireCurrent(generation);
      isScanning.value = false;
    });
  }

  /// Connect to [device], discover the active profile, and subscribe to its
  /// frames. A connection that finishes after retirement is retained solely
  /// for strict physical cleanup and is never published.
  Future<void> connect(
    BluetoothDevice device, {
    BleCapabilityAuthority? capabilityAuthority,
  }) {
    late final BleCapabilityAuthority? authority;
    try {
      authority = capabilityAuthority ?? acquireBluetoothAuthority();
      authority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _runAccountOperation((generation) async {
      authority?.requireCurrent();
      final profile = _profile;
      if (profile == null) throw StateError('scan() must run before connect()');
      await _driver.stopScan();
      authority?.requireCurrent();
      _requireCurrent(generation);
      await _disconnectPublishedConnection();
      authority?.requireCurrent();
      _requireCurrent(generation);
      await _activateCapabilityAuthority(authority);

      BleTransportConnection? candidate;
      final pending = _PendingBleConnection(device);
      var observesDriverConnection = false;
      try {
        authority?.requireCurrent();
        _pendingConnections.add(pending);
        final connectFuture = _driver.connect(device, profile);
        _observePendingConnection(
          pending,
          connectFuture,
          generation,
          authority,
        );
        observesDriverConnection = true;
        final connectedCandidate = await _awaitCapabilityAuthority(
          connectFuture,
          authority,
        );
        candidate = connectedCandidate;
        _connectionsToClose.add(connectedCandidate);
        authority?.requireCurrent();
        _requireCurrent(generation);
        pending.claimedByOperation = true;
        _connection = connectedCandidate;
        _connSub = connectedCandidate.states.listen(
          (state) {
            if (!_isCapabilityAuthorityCurrent(authority)) return;
            if (state == BluetoothConnectionState.disconnected) {
              _onDisconnected(connectedCandidate, generation);
            }
          },
          onError: (Object error) =>
              Log.w('🔵 [BLE] connection state failed: $error'),
        );
        _notifySub = connectedCandidate.notifications.listen(
          (bytes) {
            if (!isCurrentGeneration(generation) ||
                !_isCapabilityAuthorityCurrent(authority) ||
                _notifications.isClosed) {
              return;
            }
            _notifications.add(
              BleNotificationFrame(
                generation: generation,
                bytes: List<int>.unmodifiable(bytes),
              ),
            );
          },
          onError: (Object error) =>
              Log.w('🔵 [BLE] notification stream failed: $error'),
        );
        connected.value = connectedCandidate.device;
        isConnected.value = true;
      } catch (error) {
        Log.e('🔵 [BLE] connect failed: $error');
        if (candidate != null && !identical(_connection, candidate)) {
          try {
            await candidate.disconnect();
            _connectionsToClose.remove(candidate);
          } catch (_) {
            // The retained candidate is retried by account teardown.
          }
        }
        if (identical(_connection, candidate)) {
          await _disconnectPublishedConnection();
        }
        rethrow;
      } finally {
        pending.operationSettled = true;
        if (!observesDriverConnection) _pendingConnections.remove(pending);
      }
    });
  }

  /// Write one framed command. [allowLongWrite] is used for payloads above one
  /// MTU. Completion is checked again before returning to the device facade.
  Future<void> write(
    List<int> bytes, {
    bool allowLongWrite = false,
    BleCapabilityAuthority? capabilityAuthority,
  }) {
    late final BleCapabilityAuthority? authority;
    try {
      authority = capabilityAuthority ?? acquireBluetoothAuthority();
      authority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _runAccountOperation((generation) async {
      authority?.requireCurrent();
      await _activateCapabilityAuthority(authority);
      final connection = _connection;
      if (connection == null) throw StateError('not connected');
      await connection.write(bytes, allowLongWrite: allowLongWrite);
      authority?.requireCurrent();
      _requireCurrent(generation);
    });
  }

  Future<void> disconnect() {
    return _runAccountOperation((generation) async {
      await _disconnectPublishedConnection();
      _requireCurrent(generation);
    });
  }

  void _onDisconnected(BleTransportConnection connection, int generation) {
    if (!isCurrentGeneration(generation) ||
        !identical(_connection, connection)) {
      return;
    }
    Log.i('🔵 [BLE] device disconnected');
    _connectionsToClose.remove(connection);
    _connection = null;
    connected.value = null;
    isConnected.value = false;
    unawaited(
      _cancelConnectionSubscriptions().catchError((Object error) {
        Log.w('🔵 [BLE] disconnected subscription cleanup failed: $error');
      }),
    );
  }

  /// Fence new work synchronously, drain admitted work, then strictly stop the
  /// scan, subscriptions, and every connection. Any failure leaves the service
  /// retiring so the account lifecycle can retry without admitting account B.
  Future<void> deactivateAccountAndDrain() {
    if (_accountState == BleAccountLifecycleState.inactive) {
      return Future<void>.value();
    }
    if (_accountState == BleAccountLifecycleState.active) {
      _accountState = BleAccountLifecycleState.retiring;
      _activeScopeKey = null;
      _accountGeneration++;
      _activeCapabilityAuthority = null;
      _profile = null;
      _clearPublishedState();
    }
    return _drainInFlight ??= _drainAccountOnce().whenComplete(() {
      _drainInFlight = null;
    });
  }

  Future<void> _drainAccountOnce() async {
    // Interrupt an active scan before waiting for admitted work. A second
    // strict stop below closes the race with a startScan already in flight.
    try {
      await _driver.stopScan();
    } catch (_) {}

    await _waitForAccountOperations();
    final capabilityCleanup = _capabilityCleanupInFlight;
    if (capabilityCleanup != null) await capabilityCleanup;

    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(_cancelScanSubscriptions);
    await attempt(_cancelConnectionSubscriptions);
    await attempt(_driver.stopScan);
    await attempt(_disconnectPendingConnectionDevices);
    await attempt(_disconnectRetainedConnections);
    _clearPublishedState();

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    _accountState = BleAccountLifecycleState.inactive;
  }

  Future<void> _waitForAccountOperations() async {
    while (_accountOperations.isNotEmpty) {
      await Future.wait<void>(
        _accountOperations.toList(growable: false),
        eagerError: false,
      );
    }
  }

  Future<void> _cancelScanSubscriptions() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final scan = _scanSub;
    if (scan != null) {
      try {
        await scan.cancel();
        if (identical(_scanSub, scan)) _scanSub = null;
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    final scanning = _scanningSub;
    if (scanning != null) {
      try {
        await scanning.cancel();
        if (identical(_scanningSub, scanning)) _scanningSub = null;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    isScanning.value = false;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _cancelConnectionSubscriptions() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final connection = _connSub;
    if (connection != null) {
      try {
        await connection.cancel();
        if (identical(_connSub, connection)) _connSub = null;
      } catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    final notifications = _notifySub;
    if (notifications != null) {
      try {
        await notifications.cancel();
        if (identical(_notifySub, notifications)) _notifySub = null;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _disconnectPublishedConnection() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _cancelConnectionSubscriptions();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await _disconnectRetainedConnections();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _clearPublishedState();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _disconnectRetainedConnections() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final connection in _connectionsToClose.toList(growable: false)) {
      try {
        await connection.disconnect();
        _connectionsToClose.remove(connection);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _disconnectPendingConnectionDevices() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final pending in _pendingConnections.toList(growable: false)) {
      if (pending.connection != null || pending.rawDisconnectSucceeded) {
        continue;
      }
      try {
        await _driver.disconnectDevice(pending.device);
        pending.rawDisconnectSucceeded = true;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _clearPublishedState() {
    _connection = null;
    connected.value = null;
    isConnected.value = false;
    isScanning.value = false;
    found.clear();
  }

  Future<void> _activateCapabilityAuthority(
    BleCapabilityAuthority? authority,
  ) async {
    if (authority == null) return;
    authority.requireCurrent();
    final active = _activeCapabilityAuthority;
    if (active != null && !identical(active, authority)) {
      try {
        active.requireCurrent();
      } on BleCapabilityUnavailable {
        await _ensureCapabilityCleanup(active);
      }
    }
    authority.requireCurrent();
    if (identical(_activeCapabilityAuthority, authority)) return;
    _activeCapabilityAuthority = authority;
    unawaited(
      authority.whenInvalidated
          .then((_) {
            _fenceCapabilityRuntime(authority);
            return _ensureCapabilityCleanup(authority);
          })
          .catchError((Object error) {
            Log.w('🔵 [BLE] capability cleanup failed: $error');
          }),
    );
  }

  void _fenceCapabilityRuntime(BleCapabilityAuthority authority) {
    if (!identical(_activeCapabilityAuthority, authority)) return;
    _profile = null;
    _clearPublishedState();
  }

  Future<T> _awaitCapabilityAuthority<T>(
    Future<T> operation,
    BleCapabilityAuthority? authority,
  ) {
    if (authority == null) return operation;
    return Future.any<T>(<Future<T>>[
      operation,
      authority.whenInvalidated.then<T>((_) {
        throw const BleCapabilityUnavailable.stale();
      }),
    ]);
  }

  void _scheduleCapabilityCleanup(BleCapabilityAuthority? authority) {
    if (authority == null) return;
    unawaited(
      _ensureCapabilityCleanup(authority).catchError((Object error) {
        Log.w('🔵 [BLE] capability cleanup failed: $error');
      }),
    );
  }

  Future<void> _ensureCapabilityCleanup(BleCapabilityAuthority authority) {
    final inFlight = _capabilityCleanupInFlight;
    if (inFlight != null) {
      if (identical(_capabilityCleanupAuthority, authority)) return inFlight;
      return inFlight.then((_) => _ensureCapabilityCleanup(authority));
    }

    _capabilityCleanupAuthority = authority;
    late final Future<void> tracked;
    tracked = _retryCapabilityCleanup(authority).whenComplete(() {
      if (identical(_capabilityCleanupInFlight, tracked)) {
        _capabilityCleanupInFlight = null;
        _capabilityCleanupAuthority = null;
      }
    });
    _capabilityCleanupInFlight = tracked;
    return tracked;
  }

  Future<void> _retryCapabilityCleanup(BleCapabilityAuthority authority) async {
    var retryDelay = const Duration(milliseconds: 10);
    while (_accountState == BleAccountLifecycleState.active &&
        identical(_activeCapabilityAuthority, authority)) {
      try {
        await _revokeBluetoothRuntime(authority);
        return;
      } catch (error) {
        Log.w('🔵 [BLE] capability cleanup will retry: $error');
        if (_accountState != BleAccountLifecycleState.active ||
            !identical(_activeCapabilityAuthority, authority)) {
          return;
        }
        await Future<void>.delayed(retryDelay);
        final nextMilliseconds = retryDelay.inMilliseconds * 2;
        retryDelay = Duration(
          milliseconds: nextMilliseconds > 250 ? 250 : nextMilliseconds,
        );
      }
    }
  }

  void _observePendingConnection(
    _PendingBleConnection pending,
    Future<BleTransportConnection> connectionFuture,
    int generation,
    BleCapabilityAuthority? authority,
  ) {
    unawaited(
      connectionFuture
          .then<void>((connection) async {
            pending.connection = connection;
            _connectionsToClose.add(connection);
            _pendingConnections.remove(pending);
            if (pending.operationSettled &&
                !pending.claimedByOperation &&
                (!isCurrentGeneration(generation) ||
                    !_isCapabilityAuthorityCurrent(authority))) {
              await _disconnectConnectionUntilSuccessful(connection);
            }
          })
          .catchError((Object error) {
            _pendingConnections.remove(pending);
            Log.w('🔵 [BLE] provisional connection failed: $error');
          }),
    );
  }

  bool _isCapabilityAuthorityCurrent(BleCapabilityAuthority? authority) {
    if (authority == null) return true;
    try {
      authority.requireCurrent();
      return true;
    } on BleCapabilityUnavailable {
      return false;
    }
  }

  Future<void> _disconnectConnectionUntilSuccessful(
    BleTransportConnection connection,
  ) async {
    var retryDelay = const Duration(milliseconds: 10);
    while (_connectionsToClose.contains(connection)) {
      try {
        await connection.disconnect();
        _connectionsToClose.remove(connection);
      } catch (error) {
        Log.w('🔵 [BLE] late connection cleanup will retry: $error');
        await Future<void>.delayed(retryDelay);
        final nextMilliseconds = retryDelay.inMilliseconds * 2;
        retryDelay = Duration(
          milliseconds: nextMilliseconds > 250 ? 250 : nextMilliseconds,
        );
      }
    }
  }

  Future<void> _revokeBluetoothRuntime(
    BleCapabilityAuthority? authority,
  ) async {
    if (!identical(_activeCapabilityAuthority, authority)) return;
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(_disconnectPendingConnectionDevices);
    await attempt(_disconnectPublishedConnection);
    await attempt(_driver.stopScan);
    await attempt(_cancelScanSubscriptions);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    if (identical(_activeCapabilityAuthority, authority)) {
      _activeCapabilityAuthority = null;
    }
  }

  Future<T> _runAccountOperation<T>(
    Future<T> Function(int generation) operation,
  ) {
    if (_accountState != BleAccountLifecycleState.active) {
      return Future<T>.error(BleAccountUnavailable(_accountState));
    }
    final generation = _accountGeneration;
    final result = _radioOperationTail.then<T>((_) {
      _requireCurrent(generation);
      return operation(generation);
    });
    final completion = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _radioOperationTail = completion;
    late final Future<void> tracked;
    tracked = completion.whenComplete(() => _accountOperations.remove(tracked));
    _accountOperations.add(tracked);
    return result;
  }

  void _requireCurrent(int generation) {
    if (!isCurrentGeneration(generation)) {
      throw const BleAccountOperationCancelled();
    }
  }

  @override
  void onClose() {
    _activeCapabilityAuthority = null;
    final drain = deactivateAccountAndDrain().catchError((Object error) {
      Log.w('🔵 [BLE] final drain failed: $error');
    });
    final adapter = _adapterSub?.cancel() ?? Future<void>.value();
    unawaited(
      Future.wait<void>(<Future<void>>[
        drain,
        adapter,
      ], eagerError: false).then((_) => _notifications.close()),
    );
    super.onClose();
  }
}

final class _FlutterBlueTransportDriver implements BleTransportDriver {
  @override
  Stream<BluetoothAdapterState> get adapterStates =>
      FlutterBluePlus.adapterState;

  @override
  BluetoothAdapterState get adapterStateNow => FlutterBluePlus.adapterStateNow;

  @override
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  @override
  Stream<bool> get scanStates => FlutterBluePlus.isScanning;

  @override
  bool get isScanningNow => FlutterBluePlus.isScanningNow;

  @override
  Future<bool> isSupported() => FlutterBluePlus.isSupported;

  @override
  Future<void> turnOn() => FlutterBluePlus.turnOn(timeout: 15);

  @override
  Future<void> startScan(BleDeviceProfile profile, Duration timeout) {
    return FlutterBluePlus.startScan(
      withNames: <String>[profile.advertisedName],
      withServices: <Guid>[Guid(profile.serviceId)],
      timeout: timeout,
    );
  }

  @override
  Future<void> stopScan() async {
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
  }

  @override
  Future<void> disconnectDevice(BluetoothDevice device) => device.disconnect();

  @override
  Future<BleTransportConnection> connect(
    BluetoothDevice device,
    BleDeviceProfile profile,
  ) async {
    try {
      await device.connect(
        timeout: const Duration(seconds: 10),
        // Preserve the app's existing flutter_blue_plus license selection.
        // ignore: deprecated_member_use
        license: License.free,
      );
      BluetoothCharacteristic? writeCharacteristic;
      BluetoothCharacteristic? notifyCharacteristic;
      final services = await device.discoverServices();
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == Guid(profile.notifyId)) {
            notifyCharacteristic = characteristic;
          } else if (characteristic.uuid == Guid(profile.writeId)) {
            writeCharacteristic = characteristic;
          }
        }
      }
      if (writeCharacteristic == null || notifyCharacteristic == null) {
        throw StateError('device missing expected GATT characteristics');
      }
      await notifyCharacteristic.setNotifyValue(true);
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(247);
        } catch (_) {
          // MTU negotiation is best effort; framed writes still use mtuNow.
        }
      }
      return _FlutterBlueTransportConnection(
        device: device,
        writeCharacteristic: writeCharacteristic,
        notifyCharacteristic: notifyCharacteristic,
      );
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {}
      rethrow;
    }
  }
}

final class _FlutterBlueTransportConnection implements BleTransportConnection {
  const _FlutterBlueTransportConnection({
    required this.device,
    required BluetoothCharacteristic writeCharacteristic,
    required BluetoothCharacteristic notifyCharacteristic,
  }) : _writeCharacteristic = writeCharacteristic,
       _notifyCharacteristic = notifyCharacteristic;

  @override
  final BluetoothDevice device;
  final BluetoothCharacteristic _writeCharacteristic;
  final BluetoothCharacteristic _notifyCharacteristic;

  @override
  int get mtu => device.mtuNow;

  @override
  Stream<List<int>> get notifications => _notifyCharacteristic.onValueReceived;

  @override
  Stream<BluetoothConnectionState> get states => device.connectionState;

  @override
  Future<void> write(List<int> bytes, {bool allowLongWrite = false}) {
    return _writeCharacteristic.write(bytes, allowLongWrite: allowLongWrite);
  }

  @override
  Future<void> disconnect() => device.disconnect();
}
