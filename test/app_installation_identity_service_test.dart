import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'migrates the legacy Push installation key without rotating it',
    () async {
      const legacyInstallationId = '0123456789abcdef0123456789abcdef';
      SharedPreferences.setMockInitialValues(<String, Object>{
        AppInstallationIdentityService.preferencesKey: legacyInstallationId,
        // A corrupt Push journal is deliberately unrelated to app identity.
        'maaso.notification.push-binding.v1': '{not-json',
      });
      final preferences = await SharedPreferences.getInstance();
      final service = AppInstallationIdentityService(
        sharedPreferences: preferences,
        randomBytes: (length) => List<int>.filled(length, 0x2a),
      );

      await service.init();

      expect(service.installationId, legacyInstallationId);
      expect(service.runtimeInstanceId, List<String>.filled(16, '2a').join());
      expect(
        preferences.getString(AppInstallationIdentityService.preferencesKey),
        legacyInstallationId,
      );
      expect(
        preferences.getString('maaso.notification.push-binding.v1'),
        '{not-json',
      );
    },
  );

  test(
    'persists installation identity but rotates runtime identity per boot',
    () async {
      final preferences = await SharedPreferences.getInstance();
      var firstSeed = 1;
      final firstBoot = AppInstallationIdentityService(
        sharedPreferences: preferences,
        randomBytes: (length) => List<int>.filled(length, firstSeed++),
      );
      await firstBoot.init();

      final secondBoot = AppInstallationIdentityService(
        sharedPreferences: preferences,
        randomBytes: (length) => List<int>.filled(length, 9),
      );
      await secondBoot.init();

      expect(firstBoot.installationId, List<String>.filled(16, '01').join());
      expect(firstBoot.runtimeInstanceId, List<String>.filled(16, '02').join());
      expect(secondBoot.installationId, firstBoot.installationId);
      expect(
        secondBoot.runtimeInstanceId,
        List<String>.filled(16, '09').join(),
      );
      expect(secondBoot.runtimeInstanceId, isNot(firstBoot.runtimeInstanceId));
    },
  );

  test('fails closed when the random source returns malformed bytes', () async {
    final preferences = await SharedPreferences.getInstance();
    final service = AppInstallationIdentityService(
      sharedPreferences: preferences,
      randomBytes: (length) => <int>[0],
    );

    await expectLater(service.init(), throwsStateError);
    expect(service.isInitialized, isFalse);
  });

  test(
    'init is single-flight and publishes only after durable read-back',
    () async {
      final store = _GatedIdentityStore();
      var seed = 1;
      final service = AppInstallationIdentityService(
        store: store,
        randomBytes: (length) => List<int>.filled(length, seed++),
      );

      final first = service.init();
      final second = service.init();

      expect(identical(first, second), isTrue);
      expect(service.isInitialized, isFalse);
      expect(() => service.identity, throwsStateError);

      store.firstRead.complete(null);
      await store.writeStarted.future;
      expect(service.isInitialized, isFalse);
      expect(store.writtenValue, List<String>.filled(16, '01').join());

      store.writeResult.complete(true);
      await store.confirmReadStarted.future;
      expect(service.isInitialized, isFalse);

      store.confirmRead.complete(store.writtenValue);
      final initialized = await first;

      expect(identical(initialized, service), isTrue);
      expect(identical(await second, service), isTrue);
      expect(service.isInitialized, isTrue);
      expect(service.installationId, List<String>.filled(16, '01').join());
      expect(service.runtimeInstanceId, List<String>.filled(16, '02').join());
      expect(store.readCount, 2);
      expect(store.writeCount, 1);
    },
  );

  test('failed durable confirmation leaves init retryable', () async {
    final store = _ReadbackMismatchOnceStore();
    var seed = 1;
    final service = AppInstallationIdentityService(
      store: store,
      randomBytes: (length) => List<int>.filled(length, seed++),
    );

    final failed = service.init();
    await expectLater(failed, throwsStateError);
    expect(service.isInitialized, isFalse);

    final retried = service.init();
    expect(identical(retried, failed), isFalse);
    await retried;

    expect(service.isInitialized, isTrue);
    expect(service.installationId, List<String>.filled(16, '01').join());
    expect(service.runtimeInstanceId, List<String>.filled(16, '02').join());
    expect(store.writeCount, 1);
  });
}

class _GatedIdentityStore implements AppInstallationIdentityStore {
  final Completer<String?> firstRead = Completer<String?>();
  final Completer<void> writeStarted = Completer<void>();
  final Completer<bool> writeResult = Completer<bool>();
  final Completer<void> confirmReadStarted = Completer<void>();
  final Completer<String?> confirmRead = Completer<String?>();

  int readCount = 0;
  int writeCount = 0;
  String? writtenValue;

  @override
  Future<String?> read(String key) {
    readCount++;
    if (readCount == 1) return firstRead.future;
    confirmReadStarted.complete();
    return confirmRead.future;
  }

  @override
  Future<bool> write(String key, String value) {
    writeCount++;
    writtenValue = value;
    writeStarted.complete();
    return writeResult.future;
  }
}

class _ReadbackMismatchOnceStore implements AppInstallationIdentityStore {
  String? value;
  int readCount = 0;
  int writeCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    if (readCount == 2) {
      return 'ffffffffffffffffffffffffffffffff';
    }
    return value;
  }

  @override
  Future<bool> write(String key, String newValue) async {
    writeCount++;
    value = newValue;
    return true;
  }
}
