import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_codec.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(appServices.reset);
  tearDown(appServices.reset);

  test(
    'capability denial prevents every Bluetooth radio side effect',
    () async {
      appServices.put(_capabilitySnapshots(AppHostPlatform.web));
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);

      await expectLater(
        fixture.device.scan(seconds: 0),
        throwsA(
          isA<BleCapabilityUnavailable>().having(
            (error) => error.code,
            'code',
            'capability_unavailable',
          ),
        ),
      );
      await expectLater(
        fixture.transport.ensureOn(),
        throwsA(isA<BleCapabilityUnavailable>()),
      );
      await expectLater(
        fixture.transport.write(const <int>[0x01]),
        throwsA(isA<BleCapabilityUnavailable>()),
      );

      expect(fixture.driver.startScanCalls, 0);
      expect(fixture.driver.stopScanCalls, 0);
      expect(fixture.driver.connectCalls, 0);
    },
  );

  test(
    'snapshot refresh stops a scan whose start future remains hung',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final startGate = Completer<void>();
      fixture.driver.startScanGate = startGate;

      final scan = fixture.device.scan(seconds: 1);
      final scanExpectation = expectLater(
        scan,
        throwsA(
          isA<BleCapabilityUnavailable>().having(
            (error) => error.code,
            'code',
            'capability_snapshot_stale',
          ),
        ),
      );
      await _waitUntil(() => fixture.driver.startScanCalls == 1);

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      await _waitUntil(() => fixture.driver.stopScanCalls >= 1);
      await scanExpectation;

      expect(startGate.isCompleted, isFalse);
      expect(fixture.driver.stopScanCalls, greaterThanOrEqualTo(1));
      expect(fixture.transport.isScanning.value, isFalse);
      expect(fixture.transport.isConnected.value, isFalse);
    },
  );

  test(
    'snapshot refresh disconnects a provisional connection while discovery hangs',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      await fixture.device.scan(seconds: 0);
      final connectGate = Completer<BleTransportConnection>();
      fixture.driver.connectGate = connectGate;
      final device = BluetoothDevice.fromId('provisional-a');

      final connecting = fixture.device.connect(device);
      final expectation = expectLater(
        connecting,
        throwsA(
          isA<BleCapabilityUnavailable>().having(
            (error) => error.code,
            'code',
            'capability_snapshot_stale',
          ),
        ),
      );
      await _waitUntil(() => fixture.driver.connectCalls == 1);

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      await _waitUntil(
        () => fixture.driver.disconnectedDeviceIds.contains('provisional-a'),
      );
      await expectation;

      expect(connectGate.isCompleted, isFalse);
      expect(fixture.transport.connected.value, isNull);
      expect(fixture.transport.isConnected.value, isFalse);

      final lateConnection = _FakeConnection('provisional-a');
      connectGate.complete(lateConnection);
      await _waitUntil(() => lateConnection.disconnectCalls >= 1);
    },
  );

  test(
    'capability cleanup retries a failed active disconnect before releasing ownership',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final connection = _FakeConnection('retry-a')..disconnectFailures = 1;
      fixture.driver.nextConnection = connection;
      await fixture.device.scan(seconds: 0);
      await fixture.device.connect(connection.device);

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      await _waitUntil(() => connection.disconnectCalls == 2);

      expect(connection.disconnectFailures, 0);
      expect(fixture.transport.connected.value, isNull);
      expect(fixture.transport.isConnected.value, isFalse);
    },
  );

  test(
    'revocation clears published state and fences late scan callbacks while disconnect hangs',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      await fixture.device.scan(seconds: 0);
      fixture.driver.emitScanResults(<ScanResult>[
        _scanResult('visible-before-revoke'),
      ]);
      await _waitUntil(
        () => fixture.transport.found.containsKey('visible-before-revoke'),
      );

      final connection = _FakeConnection('scan-fence-a');
      fixture.driver.nextConnection = connection;
      await fixture.device.connect(connection.device);
      final disconnectGate = Completer<void>();
      connection.disconnectGate = disconnectGate;
      addTearDown(() {
        if (!disconnectGate.isCompleted) disconnectGate.complete();
      });

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      await _waitUntil(() => connection.disconnectCalls == 1);

      expect(fixture.transport.connected.value, isNull);
      expect(fixture.transport.isConnected.value, isFalse);
      expect(fixture.transport.found, isEmpty);

      fixture.driver.emitScanResults(<ScanResult>[
        _scanResult('late-after-revoke'),
      ]);
      fixture.driver.emitScanState(true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.transport.found, isEmpty);
      expect(fixture.transport.isScanning.value, isFalse);

      disconnectGate.complete();
    },
  );

  test(
    'queued notification after revocation never reaches transport or Yoturetoys',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final connection = _FakeConnection('notify-fence-a');
      fixture.driver.nextConnection = connection;
      await fixture.device.scan(seconds: 0);
      await fixture.device.connect(connection.device);
      final frames = <BleNotificationFrame>[];
      final subscription = fixture.transport.notifications.listen(frames.add);
      addTearDown(subscription.cancel);

      connection.emit(YoturetoysCodec.encode(0x21, List<int>.filled(14, 1)));
      await _waitUntil(() => fixture.device.info.value != null);
      frames.clear();

      connection.emit(YoturetoysCodec.encode(0x21, List<int>.filled(14, 2)));
      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(frames, isEmpty);
      expect(fixture.device.info.value, isNull);
      expect(fixture.transport.connected.value, isNull);
      expect(fixture.transport.isConnected.value, isFalse);
    },
  );

  test('revocation while stopping scan prevents physical connect', () async {
    final snapshots = appServices.put(
      _capabilitySnapshots(AppHostPlatform.macos),
    );
    final fixture = _BleFixture()..activate('account-a');
    addTearDown(fixture.close);
    await fixture.device.scan(seconds: 0);
    final stopScanGate = Completer<void>();
    fixture.driver.stopScanGate = stopScanGate;

    final connecting = fixture.device.connect(
      BluetoothDevice.fromId('must-not-connect'),
    );
    final expectation = expectLater(
      connecting,
      throwsA(
        isA<BleCapabilityUnavailable>().having(
          (error) => error.code,
          'code',
          'capability_snapshot_stale',
        ),
      ),
    );
    await _waitUntil(() => fixture.driver.stopScanCalls == 1);
    snapshots.refresh(
      snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
    );
    stopScanGate.complete();
    await expectation;

    expect(fixture.driver.connectCalls, 0);
    expect(fixture.transport.isConnected.value, isFalse);
  });

  test(
    'one authority fences gallery prework and the eventual command',
    () async {
      final snapshots = appServices.put(
        _capabilitySnapshots(AppHostPlatform.macos),
      );
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final preworkGate = Completer<void>();

      final operation = fixture.device.runAccountOperation(() async {
        await preworkGate.future;
        await fixture.device.setVoice(true);
      });
      final operationExpectation = expectLater(
        operation,
        throwsA(isA<BleCapabilityUnavailable>()),
      );
      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.web),
      );
      preworkGate.complete();
      await operationExpectation;

      expect(fixture.driver.startScanCalls, 0);
      expect(fixture.driver.connectCalls, 0);
    },
  );

  test(
    'inactive transport and facade reject direct account operations',
    () async {
      final fixture = _BleFixture();
      addTearDown(fixture.close);

      await expectLater(
        fixture.device.scan(seconds: 0),
        throwsA(isA<BleAccountUnavailable>()),
      );
      await expectLater(
        fixture.transport.scan(YoturetoysDevice.profile, seconds: 0),
        throwsA(isA<BleAccountUnavailable>()),
      );
      await expectLater(
        fixture.transport.disconnect(),
        throwsA(isA<BleAccountUnavailable>()),
      );

      expect(fixture.driver.startScanCalls, 0);
      expect(fixture.driver.connectCalls, 0);
    },
  );

  test(
    'account drain owns external prework before the first BLE call',
    () async {
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final preworkGate = Completer<void>();
      var reachedDeviceCommand = false;

      final operation = fixture.device.runAccountOperation(() async {
        await preworkGate.future;
        reachedDeviceCommand = true;
        await fixture.device.setVoice(true);
      });
      final operationExpectation = expectLater(
        operation,
        throwsA(
          anyOf(
            isA<BleAccountUnavailable>(),
            isA<BleAccountOperationCancelled>(),
          ),
        ),
      );
      final drain = fixture.device.deactivateAccountAndDrain();
      var drainCompleted = false;
      unawaited(drain.then((_) => drainCompleted = true));
      await Future<void>.delayed(Duration.zero);

      expect(drainCompleted, isFalse);
      expect(
        () => fixture.device.activateAccount(accountScopeKey: 'account-b'),
        throwsA(isA<BleAccountUnavailable>()),
      );
      preworkGate.complete();
      await operationExpectation;
      await drain;

      expect(reachedDeviceCommand, isTrue);
      expect(fixture.driver.connectCalls, 0);
      fixture.activate('account-b');
      expect(fixture.device.accountState, BleAccountLifecycleState.active);
    },
  );

  test(
    'late scan completion cannot publish after account retirement',
    () async {
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final startGate = Completer<void>();
      fixture.driver.startScanGate = startGate;

      final scan = fixture.device.scan(seconds: 1);
      final scanExpectation = expectLater(
        scan,
        throwsA(isA<BleAccountOperationCancelled>()),
      );
      await _waitUntil(() => fixture.driver.startScanCalls == 1);

      final drain = fixture.device.deactivateAccountAndDrain();
      startGate.complete();
      await scanExpectation;
      await drain;

      expect(fixture.transport.accountState, BleAccountLifecycleState.inactive);
      expect(fixture.transport.found, isEmpty);
      expect(fixture.transport.isScanning.value, isFalse);
      fixture.activate('account-b');
      expect(fixture.transport.found, isEmpty);
    },
  );

  test(
    'late connection is disconnected and never published to account B',
    () async {
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      await fixture.device.scan(seconds: 0);

      final connection = _FakeConnection('late-a');
      final connectGate = Completer<BleTransportConnection>();
      fixture.driver.connectGate = connectGate;
      final connect = fixture.device.connect(connection.device);
      final connectExpectation = expectLater(
        connect,
        throwsA(isA<BleAccountOperationCancelled>()),
      );
      await _waitUntil(() => fixture.driver.connectCalls == 1);

      final drain = fixture.device.deactivateAccountAndDrain();
      connectGate.complete(connection);
      await connectExpectation;
      await drain;

      expect(connection.disconnectCalls, 1);
      expect(fixture.transport.connected.value, isNull);
      expect(fixture.transport.isConnected.value, isFalse);
      fixture.activate('account-b');
      connection.emit(YoturetoysCodec.encode(0x21, List<int>.filled(14, 1)));
      await Future<void>.delayed(Duration.zero);
      expect(fixture.device.info.value, isNull);
    },
  );

  test(
    'disconnect failure retains retiring fence until retry succeeds',
    () async {
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final connection = _FakeConnection('connected-a')..disconnectFailures = 1;
      fixture.driver.nextConnection = connection;
      await fixture.device.scan(seconds: 0);
      await fixture.device.connect(connection.device);

      await expectLater(
        fixture.device.deactivateAccountAndDrain(),
        throwsA(isA<StateError>()),
      );
      expect(fixture.device.accountState, BleAccountLifecycleState.retiring);
      expect(fixture.transport.accountState, BleAccountLifecycleState.retiring);
      expect(
        () => fixture.device.activateAccount(accountScopeKey: 'account-b'),
        throwsA(isA<BleAccountUnavailable>()),
      );

      await fixture.device.deactivateAccountAndDrain();
      expect(connection.disconnectCalls, 2);
      fixture.activate('account-b');
      expect(fixture.device.accountState, BleAccountLifecycleState.active);
    },
  );

  test(
    'retirement stops an in-flight image before another chunk is written',
    () async {
      final fixture = _BleFixture()..activate('account-a');
      addTearDown(fixture.close);
      final connection = _FakeConnection('projector-a');
      fixture.driver.nextConnection = connection;
      await fixture.device.scan(seconds: 0);
      await fixture.device.connect(connection.device);

      final chunkGate = Completer<void>();
      connection.chunkWriteGate = chunkGate;
      final png = image.encodePng(image.Image(width: 1, height: 1));
      final transfer = fixture.device.projectImage(png);
      final transferExpectation = expectLater(
        transfer,
        throwsA(isA<BleAccountOperationCancelled>()),
      );
      await _waitUntil(() => connection.commands.contains(0x27));
      connection.emit(YoturetoysCodec.encode(0x27, const <int>[0]));
      await _waitUntil(() => connection.commands.contains(0x28));

      final writesAtRetirement = connection.writes.length;
      final drain = fixture.device.deactivateAccountAndDrain();
      expect(fixture.device.isTransferring.value, isFalse);
      expect(fixture.device.transferProgress.value, 0);
      chunkGate.complete();
      await transferExpectation;
      await drain;

      expect(connection.writes.length, writesAtRetirement);
      fixture.activate('account-b');
      expect(fixture.device.info.value, isNull);
      expect(fixture.device.transferProgress.value, 0);
    },
  );

  test('old generation ACK cannot complete account B command', () async {
    final transport = _ManualTransport();
    final device = YoturetoysDevice(transport)..initializeLifecycle();
    addTearDown(() async {
      if (device.accountState != BleAccountLifecycleState.inactive) {
        await device.deactivateAccountAndDrain();
      }
      device.closeLifecycle();
      await transport.closeController();
    });

    device.activateAccount(accountScopeKey: 'account-a');
    final generationA = transport.accountGeneration;
    final commandA = device.setVoice(true);
    final commandAExpectation = expectLater(
      commandA,
      throwsA(isA<BleAccountOperationCancelled>()),
    );
    await Future<void>.delayed(Duration.zero);
    await device.deactivateAccountAndDrain();
    await commandAExpectation;

    device.activateAccount(accountScopeKey: 'account-b');
    final generationB = transport.accountGeneration;
    var commandBCompleted = false;
    final commandB = device.setVoice(false)
      ..then((_) => commandBCompleted = true);
    await Future<void>.delayed(Duration.zero);

    transport.emit(
      BleNotificationFrame(
        generation: generationA,
        bytes: YoturetoysCodec.encode(0x26, const <int>[0]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(commandBCompleted, isFalse);

    transport.emit(
      BleNotificationFrame(
        generation: generationB,
        bytes: YoturetoysCodec.encode(0x26, const <int>[0]),
      ),
    );
    await commandB;
    expect(commandBCompleted, isTrue);
  });
}

final class _BleFixture {
  _BleFixture() {
    driver = _FakeDriver();
    transport = BleTransportService(driver: driver)..initializeLifecycle();
    device = YoturetoysDevice(transport)..initializeLifecycle();
  }

  late final _FakeDriver driver;
  late final BleTransportService transport;
  late final YoturetoysDevice device;

  void activate(String scope) {
    device.activateAccount(accountScopeKey: scope);
  }

  Future<void> close() async {
    if (device.accountState != BleAccountLifecycleState.inactive) {
      while (device.accountState != BleAccountLifecycleState.inactive) {
        try {
          await device.deactivateAccountAndDrain();
        } catch (_) {}
      }
    }
    device.closeLifecycle();
    transport.closeLifecycle();
    await driver.close();
  }
}

final class _FakeDriver implements BleTransportDriver {
  static final BleTransportDriver placeholder = _FakeDriver();

  final StreamController<BluetoothAdapterState> _adapterStates =
      StreamController<BluetoothAdapterState>.broadcast();
  final StreamController<bool> _scanStates = StreamController<bool>.broadcast();
  final StreamController<List<ScanResult>> _scanResults =
      StreamController<List<ScanResult>>.broadcast();

  @override
  BluetoothAdapterState adapterStateNow = BluetoothAdapterState.on;
  @override
  bool isScanningNow = false;
  int startScanCalls = 0;
  int stopScanCalls = 0;
  int connectCalls = 0;
  final List<String> disconnectedDeviceIds = <String>[];
  Completer<void>? startScanGate;
  Completer<void>? stopScanGate;
  Completer<BleTransportConnection>? connectGate;
  BleTransportConnection? nextConnection;

  @override
  Stream<BluetoothAdapterState> get adapterStates => _adapterStates.stream;
  @override
  Stream<bool> get scanStates => _scanStates.stream;
  @override
  Stream<List<ScanResult>> get scanResults => _scanResults.stream;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<void> turnOn() async {
    adapterStateNow = BluetoothAdapterState.on;
    _adapterStates.add(adapterStateNow);
  }

  @override
  Future<void> startScan(BleDeviceProfile profile, Duration timeout) async {
    startScanCalls++;
    isScanningNow = true;
    _scanStates.add(true);
    await startScanGate?.future;
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    isScanningNow = false;
    _scanStates.add(false);
    await stopScanGate?.future;
  }

  void emitScanResults(List<ScanResult> results) {
    _scanResults.add(results);
  }

  void emitScanState(bool scanning) {
    _scanStates.add(scanning);
  }

  @override
  Future<BleTransportConnection> connect(
    BluetoothDevice device,
    BleDeviceProfile profile,
  ) async {
    connectCalls++;
    final gate = connectGate;
    if (gate != null) return gate.future;
    return nextConnection ?? (throw StateError('fake connection missing'));
  }

  @override
  Future<void> disconnectDevice(BluetoothDevice device) async {
    disconnectedDeviceIds.add(device.remoteId.str);
  }

  Future<void> close() async {
    await _adapterStates.close();
    await _scanStates.close();
    await _scanResults.close();
  }
}

final class _FakeConnection implements BleTransportConnection {
  _FakeConnection(String id) : device = BluetoothDevice.fromId(id);

  final StreamController<BluetoothConnectionState> _states =
      StreamController<BluetoothConnectionState>.broadcast();
  final StreamController<List<int>> _notifications =
      StreamController<List<int>>.broadcast();

  @override
  final BluetoothDevice device;
  @override
  int mtu = 64;
  final List<List<int>> writes = <List<int>>[];
  int disconnectCalls = 0;
  int disconnectFailures = 0;
  Completer<void>? chunkWriteGate;
  Completer<void>? disconnectGate;

  List<int> get commands => writes
      .where((bytes) => bytes.length > 3)
      .map((bytes) => bytes[3])
      .toList(growable: false);

  @override
  Stream<List<int>> get notifications => _notifications.stream;
  @override
  Stream<BluetoothConnectionState> get states => _states.stream;

  void emit(List<int> bytes) => _notifications.add(bytes);

  @override
  Future<void> write(List<int> bytes, {bool allowLongWrite = false}) async {
    writes.add(List<int>.from(bytes));
    if (bytes.length > 3 && bytes[3] == 0x28) {
      await chunkWriteGate?.future;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (disconnectFailures > 0) {
      disconnectFailures--;
      throw StateError('disconnect failed');
    }
    await disconnectGate?.future;
    _states.add(BluetoothConnectionState.disconnected);
  }
}

final class _ManualTransport extends BleTransportService {
  _ManualTransport() : super(driver: _FakeDriver.placeholder);

  final StreamController<BleNotificationFrame> _frames =
      StreamController<BleNotificationFrame>.broadcast();
  BleAccountLifecycleState _state = BleAccountLifecycleState.inactive;
  int _generation = 0;

  @override
  Stream<BleNotificationFrame> get notifications => _frames.stream;
  @override
  BleAccountLifecycleState get accountState => _state;
  @override
  int get accountGeneration => _generation;
  @override
  bool get isReady => true;

  @override
  bool isCurrentGeneration(int generation) =>
      _state == BleAccountLifecycleState.active && generation == _generation;

  @override
  void activateAccount({required String accountScopeKey}) {
    if (_state == BleAccountLifecycleState.retiring) {
      throw const BleAccountUnavailable(BleAccountLifecycleState.retiring);
    }
    if (_state == BleAccountLifecycleState.inactive) {
      _generation++;
      _state = BleAccountLifecycleState.active;
    }
  }

  @override
  Future<void> deactivateAccountAndDrain() async {
    if (_state == BleAccountLifecycleState.active) {
      _state = BleAccountLifecycleState.retiring;
      _generation++;
    }
    _state = BleAccountLifecycleState.inactive;
  }

  @override
  Future<void> write(
    List<int> bytes, {
    bool allowLongWrite = false,
    BleCapabilityAuthority? capabilityAuthority,
  }) async {}

  void emit(BleNotificationFrame frame) => _frames.add(frame);

  Future<void> closeController() => _frames.close();
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

ScanResult _scanResult(String id) => ScanResult(
  device: BluetoothDevice.fromId(id),
  advertisementData: AdvertisementData(
    advName: YoturetoysDevice.profile.advertisedName,
    txPowerLevel: null,
    appearance: null,
    connectable: true,
    manufacturerData: const <int, List<int>>{},
    serviceData: const <Guid, List<int>>{},
    serviceUuids: const <Guid>[],
  ),
  rssi: -40,
  timeStamp: DateTime.now(),
);

AppCapabilitySnapshotService _capabilitySnapshots(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{'projector'},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );
