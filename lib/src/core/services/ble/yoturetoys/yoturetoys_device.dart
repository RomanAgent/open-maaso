import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_codec.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Decoded device identity (0x21 push).
class YoturetoysInfo {
  YoturetoysInfo({
    required this.sn,
    required this.firmwareVersion,
    required this.deviceId,
  });

  final String sn;
  final String firmwareVersion;
  final int deviceId;
}

/// High-level facade for the **Yoturetoys AI Drawing Projector**.
///
/// The facade is process-global but account-inactive by default. It owns the
/// protocol operation fence and generation-scoped ACK table, while
/// [BleTransportService] owns physical radio cleanup. Both must finish draining
/// before another account can activate the facade.
class YoturetoysDevice extends AppService {
  YoturetoysDevice(this._transport);

  final BleTransportService _transport;
  static final Object _bluetoothCapabilityZoneKey = Object();

  static const String productName = 'Yoturetoys AI Drawing Projector';

  /// Physical panel resolution. Every projected image is fitted to this before
  /// it goes over the wire.
  static const int displayWidth = 320;
  static const int displayHeight = 240;

  /// GATT + advertisement fingerprint of this product.
  static const BleDeviceProfile profile = BleDeviceProfile(
    serviceId: 'FF00',
    writeId: 'FF01',
    notifyId: 'FF02',
    advertisedName: 'TFY_BLE',
    manufacturerId: 0xAA55,
    snFromManufacturerData: YoturetoysCodec.snFromManufacturerData,
  );

  // —— observable state (the applet binds these) ——
  final Rxn<YoturetoysInfo> info = Rxn<YoturetoysInfo>();
  final RxBool isTransferring = false.obs;
  final RxDouble transferProgress = 0.0.obs;

  RxBool get isConnected => _transport.isConnected;
  RxMap<String, BleScanEntry> get found => _transport.found;
  RxBool get isScanning => _transport.isScanning;
  bool get bluetoothAvailable => _transport.bluetoothAvailable;

  final Map<int, _PendingAck> _acks = <int, _PendingAck>{};
  final Set<Future<void>> _accountOperations = <Future<void>>{};
  StreamSubscription<BleNotificationFrame>? _notifySub;
  Worker? _connectionWorker;
  BleAccountLifecycleState _accountState = BleAccountLifecycleState.inactive;
  String? _activeScopeKey;
  int _accountGeneration = 0;
  Future<void>? _drainInFlight;

  BleAccountLifecycleState get accountState => _accountState;

  @override
  void onInit() {
    super.onInit();
    _notifySub = _transport.notifications.listen(_onFrame);
    _connectionWorker = ever<bool>(_transport.isConnected, (connected) {
      if (!connected) info.value = null;
    });
  }

  /// Admit both the protocol facade and its shared transport for one account.
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
      if (_activeScopeKey == normalized) {
        _transport.activateAccount(accountScopeKey: normalized);
        return;
      }
      throw const BleAccountUnavailable(BleAccountLifecycleState.active);
    }

    _transport.activateAccount(accountScopeKey: normalized);
    _activeScopeKey = normalized;
    _accountGeneration++;
    _accountState = BleAccountLifecycleState.active;
    _clearPublishedState();
  }

  /// Keep non-BLE preparation (for example a gallery picker, download, or
  /// scan-settle delay) inside the same account generation as the eventual
  /// device command. Account teardown waits for this whole callback, and a
  /// callback that resumes after retirement cannot enter account B's radio.
  Future<T> runAccountOperation<T>(Future<T> Function() operation) {
    late final BleCapabilityAuthority? capabilityAuthority;
    try {
      capabilityAuthority = _inheritedOrAcquireBluetoothAuthority();
      capabilityAuthority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
    return _runAccountOperation(
      (generation) => runZoned<Future<T>>(
        () async {
          capabilityAuthority?.requireCurrent();
          final result = await operation();
          capabilityAuthority?.requireCurrent();
          _requireCurrent(generation);
          return result;
        },
        zoneValues: <Object, Object?>{
          _bluetoothCapabilityZoneKey: capabilityAuthority,
        },
      ),
    );
  }

  void _onFrame(BleNotificationFrame notification) {
    if (_accountState != BleAccountLifecycleState.active ||
        !_transport.isCurrentGeneration(notification.generation)) {
      return;
    }
    final frame = YoturetoysCodec.parse(notification.bytes);
    if (frame == null) return;
    final command = frame['cmd'] as int;
    if (command == 0x21) {
      info.value = YoturetoysInfo(
        sn: frame['sn'] as String? ?? '',
        firmwareVersion: frame['firmwareVersion'] as String? ?? '',
        deviceId: frame['deviceId'] as int? ?? 0,
      );
      return;
    }
    final pending = _acks[command];
    if (pending == null ||
        pending.facadeGeneration != _accountGeneration ||
        pending.transportGeneration != notification.generation) {
      return;
    }
    _acks.remove(command);
    if (!pending.completer.isCompleted) {
      pending.completer.complete(frame['status'] as int? ?? 0);
    }
  }

  // —————————————————— connection ——————————————————

  /// Scan for the projector. Results land in [found].
  Future<void> scan({int seconds = 10}) {
    return _runBluetoothAccountOperation((generation, authority) async {
      await _transport.scan(
        profile,
        seconds: seconds,
        capabilityAuthority: authority,
      );
      authority?.requireCurrent();
      _requireCurrent(generation);
    });
  }

  Future<void> stopScan() {
    return _runAccountOperation((generation) async {
      await _transport.stopScan();
      _requireCurrent(generation);
    });
  }

  Future<void> connect(BluetoothDevice device) {
    return _runBluetoothAccountOperation((generation, authority) async {
      await _transport.connect(device, capabilityAuthority: authority);
      authority?.requireCurrent();
      _requireCurrent(generation);
    });
  }

  /// Scan, then auto-connect when exactly one projector is found. Returns the
  /// connected entry, or null if none / ambiguous (UI then lets the user pick).
  Future<BleScanEntry?> scanAndAutoConnect({int seconds = 8}) {
    return _runBluetoothAccountOperation((generation, authority) async {
      await _transport.scan(
        profile,
        seconds: seconds,
        capabilityAuthority: authority,
      );
      authority?.requireCurrent();
      _requireCurrent(generation);
      final deadline = DateTime.now().add(Duration(seconds: seconds + 1));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        authority?.requireCurrent();
        _requireCurrent(generation);
        if (found.length == 1) {
          final entry = found.values.first;
          await _transport.connect(
            entry.device,
            capabilityAuthority: authority,
          );
          authority?.requireCurrent();
          _requireCurrent(generation);
          return entry;
        }
        if (!isScanning.value) break;
      }
      return null;
    });
  }

  Future<void> disconnect() {
    return _runAccountOperation((generation) async {
      await _transport.disconnect();
      _requireCurrent(generation);
      info.value = null;
    });
  }

  // —————————————————— operations ——————————————————

  Future<int> _sendAck(
    int command,
    List<int> content, {
    required int facadeGeneration,
    required BleCapabilityAuthority? capabilityAuthority,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    capabilityAuthority?.requireCurrent();
    _requireCurrent(facadeGeneration);
    final transportGeneration = _transport.accountGeneration;
    final previous = _acks[command];
    if (previous != null) {
      throw StateError(
        'command 0x${command.toRadixString(16)} is already pending',
      );
    }
    final completer = Completer<int>();
    final pending = _PendingAck(
      facadeGeneration: facadeGeneration,
      transportGeneration: transportGeneration,
      completer: completer,
    );
    _acks[command] = pending;
    // Attach an error observer immediately. Retirement can fail the completer
    // while the platform write below is still pending.
    unawaited(
      completer.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      await _transport.write(
        YoturetoysCodec.encode(command, content),
        capabilityAuthority: capabilityAuthority,
      );
      capabilityAuthority?.requireCurrent();
      _requireCurrent(facadeGeneration);
      final pendingAck = completer.future.timeout(
        timeout,
        onTimeout: () {
          if (identical(_acks[command], pending)) _acks.remove(command);
          throw TimeoutException(
            'no ack for cmd 0x${command.toRadixString(16)}',
          );
        },
      );
      final status = capabilityAuthority == null
          ? await pendingAck
          : await Future.any<int>(<Future<int>>[
              pendingAck,
              capabilityAuthority.whenInvalidated.then<int>((_) {
                capabilityAuthority.requireCurrent();
                throw const BleCapabilityUnavailable.stale();
              }),
            ]);
      capabilityAuthority?.requireCurrent();
      return status;
    } catch (error, stackTrace) {
      if (identical(_acks[command], pending)) _acks.remove(command);
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
      rethrow;
    }
  }

  /// Project a single image. [bytes] is any common image format; it is fitted
  /// to the panel, announced via 0x27, then streamed in 0x28 chunks.
  Future<void> projectImage(List<int> bytes, {int quality = 80}) {
    return _runBluetoothAccountOperation((generation, authority) async {
      authority?.requireCurrent();
      if (!_transport.isReady) throw StateError('projector not connected');
      if (isTransferring.value) {
        throw StateError('a transfer is already running');
      }
      isTransferring.value = true;
      transferProgress.value = 0;
      try {
        final jpeg = YoturetoysCodec.toJpeg(
          bytes,
          quality: quality,
          targetWidth: displayWidth,
          targetHeight: displayHeight,
        );
        authority?.requireCurrent();
        _requireCurrent(generation);
        final status = await _sendAck(
          0x27,
          YoturetoysCodec.generate0x27(imageSize: jpeg.length),
          facadeGeneration: generation,
          capabilityAuthority: authority,
        );
        authority?.requireCurrent();
        _requireCurrent(generation);
        if (status != 0) {
          throw StateError('device rejected image (0x27 status $status)');
        }

        final chunkSize = (_transport.mtu - 11).clamp(20, 512);
        for (var offset = 0; offset < jpeg.length; offset += chunkSize) {
          authority?.requireCurrent();
          _requireCurrent(generation);
          final end = (offset + chunkSize < jpeg.length)
              ? offset + chunkSize
              : jpeg.length;
          await _transport.write(
            YoturetoysCodec.encode(0x28, jpeg.sublist(offset, end)),
            capabilityAuthority: authority,
          );
          authority?.requireCurrent();
          _requireCurrent(generation);
          transferProgress.value = end / jpeg.length;
        }
        Log.i('🔵 [Yoturetoys] projected ${jpeg.length}B image');
      } finally {
        if (_isCurrent(generation)) isTransferring.value = false;
      }
    });
  }

  /// Switch the device to a stored artwork (0x22).
  Future<void> projectArtwork({required int artworkId, int artworkIndex = 0}) {
    return _runBluetoothAccountOperation((generation, authority) async {
      await _sendAck(
        0x22,
        YoturetoysCodec.generate0x22(
          artworkId: artworkId,
          artworkIndex: artworkIndex,
        ),
        facadeGeneration: generation,
        capabilityAuthority: authority,
      );
      authority?.requireCurrent();
      _requireCurrent(generation);
    });
  }

  /// Toggle the device's voice (0x26).
  Future<void> setVoice(bool enable) {
    return _runBluetoothAccountOperation((generation, authority) async {
      await _sendAck(
        0x26,
        YoturetoysCodec.generate0x26(enable: enable),
        facadeGeneration: generation,
        capabilityAuthority: authority,
      );
      authority?.requireCurrent();
      _requireCurrent(generation);
    });
  }

  /// Fence protocol work and ACKs synchronously. A cleanup failure leaves both
  /// facade and transport retiring so account B cannot use account A's link.
  Future<void> deactivateAccountAndDrain() {
    if (_accountState == BleAccountLifecycleState.inactive) {
      return Future<void>.value();
    }
    if (_accountState == BleAccountLifecycleState.active) {
      _accountState = BleAccountLifecycleState.retiring;
      _activeScopeKey = null;
      _accountGeneration++;
      _cancelPendingAcks();
      _clearPublishedState();
    }
    return _drainInFlight ??= _drainAccountOnce().whenComplete(() {
      _drainInFlight = null;
    });
  }

  Future<void> _drainAccountOnce() async {
    final transportDrain = _transport.deactivateAccountAndDrain();
    await Future.wait<void>(<Future<void>>[
      _waitForAccountOperations(),
      transportDrain,
    ], eagerError: false);
    _clearPublishedState();
    _accountState = BleAccountLifecycleState.inactive;
  }

  void _cancelPendingAcks() {
    final pending = _acks.values.toList(growable: false);
    _acks.clear();
    for (final ack in pending) {
      if (!ack.completer.isCompleted) {
        ack.completer.completeError(const BleAccountOperationCancelled());
      }
    }
  }

  void _clearPublishedState() {
    info.value = null;
    isTransferring.value = false;
    transferProgress.value = 0;
  }

  Future<void> _waitForAccountOperations() async {
    while (_accountOperations.isNotEmpty) {
      await Future.wait<void>(
        _accountOperations.toList(growable: false),
        eagerError: false,
      );
    }
  }

  BleCapabilityAuthority? _inheritedOrAcquireBluetoothAuthority() {
    final inherited = Zone.current[_bluetoothCapabilityZoneKey];
    if (inherited is BleCapabilityAuthority) return inherited;
    return _transport.acquireBluetoothAuthority();
  }

  Future<T> _runBluetoothAccountOperation<T>(
    Future<T> Function(
      int generation,
      BleCapabilityAuthority? capabilityAuthority,
    )
    operation,
  ) {
    late final BleCapabilityAuthority? capabilityAuthority;
    try {
      capabilityAuthority = _inheritedOrAcquireBluetoothAuthority();
      capabilityAuthority?.requireCurrent();
    } catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }

    return _runAccountOperation(
      (generation) => runZoned<Future<T>>(
        () async {
          capabilityAuthority?.requireCurrent();
          final result = await operation(generation, capabilityAuthority);
          capabilityAuthority?.requireCurrent();
          _requireCurrent(generation);
          return result;
        },
        zoneValues: <Object, Object?>{
          _bluetoothCapabilityZoneKey: capabilityAuthority,
        },
      ),
    );
  }

  Future<T> _runAccountOperation<T>(
    Future<T> Function(int generation) operation,
  ) {
    if (_accountState != BleAccountLifecycleState.active) {
      return Future<T>.error(BleAccountUnavailable(_accountState));
    }
    final generation = _accountGeneration;
    final result = Future<T>.sync(() => operation(generation));
    late final Future<void> tracked;
    tracked = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _accountOperations.remove(tracked));
    _accountOperations.add(tracked);
    return result;
  }

  bool _isCurrent(int generation) =>
      _accountState == BleAccountLifecycleState.active &&
      generation == _accountGeneration;

  void _requireCurrent(int generation) {
    if (!_isCurrent(generation)) {
      throw const BleAccountOperationCancelled();
    }
  }

  @override
  void onClose() {
    unawaited(
      deactivateAccountAndDrain().catchError((Object error) {
        Log.w('🔵 [Yoturetoys] final drain failed: $error');
      }),
    );
    unawaited(_notifySub?.cancel() ?? Future<void>.value());
    _connectionWorker?.dispose();
    super.onClose();
  }
}

final class _PendingAck {
  const _PendingAck({
    required this.facadeGeneration,
    required this.transportGeneration,
    required this.completer,
  });

  final int facadeGeneration;
  final int transportGeneration;
  final Completer<int> completer;
}
