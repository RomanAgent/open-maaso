import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// A platform seam verifies the actual keychain options passed by the plugin.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:maaso/src/offline/offline_credentials.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FlutterSecureStoragePlatform original;
  late _VaultPlatform platform;
  setUp(() {
    original = FlutterSecureStoragePlatform.instance;
    platform = _VaultPlatform();
    FlutterSecureStoragePlatform.instance = platform;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    FlutterSecureStoragePlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'provider keys are isolated and never sync through iCloud keychain',
    () async {
      final vault = OfflineCredentials();
      await vault.write('openai', ' fixture-one ');
      await vault.write('deepseek', 'fixture-two');
      expect(await vault.read('openai'), 'fixture-one');
      expect(await vault.read('deepseek'), 'fixture-two');
      expect(platform.lastOptions['synchronizable'], 'false');
      expect(platform.lastOptions['accessibility'], 'first_unlock_this_device');
      expect(
        platform.values.keys,
        everyElement(startsWith(OfflineCredentials.keyPrefix)),
      );
    },
  );

  test(
    'clear touches only offline credential slots and reads no other secrets',
    () async {
      final vault = OfflineCredentials();
      platform.values['another_app_setting'] = 'keep';
      await vault.write('openai', 'fixture-one');
      await vault.write('deepseek', 'fixture-two');
      await vault.clear();
      expect(platform.values, {'another_app_setting': 'keep'});
      expect(platform.readAllCalls, 0);
      expect(platform.deleteAllCalls, 0);
    },
  );

  test(
    'empty key deletes and storage failures expose a fixed diagnostic',
    () async {
      final vault = OfflineCredentials();
      await vault.write('openai', 'fixture-one');
      await vault.write('openai', '');
      expect(await vault.read('openai'), isNull);
      platform.fail = true;
      await expectLater(
        vault.write('openai', 'fixture-one'),
        throwsA(
          isA<OfflineCredentialException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('sensitive-platform-detail')),
          ),
        ),
      );
      platform.fail = false;
      await vault.write('openai', 'fixture-new');
      expect(
        await vault.read('openai'),
        'fixture-new',
        reason: 'a failed write must not poison the serialization tail',
      );
    },
  );

  test('invalid header content never reaches secure storage', () async {
    final vault = OfflineCredentials();
    await expectLater(
      vault.write('openai', 'fixture\nheader'),
      throwsA(isA<OfflineCredentialException>()),
    );
    expect(platform.values, isEmpty);
  });
}

class _VaultPlatform extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  Map<String, String> lastOptions = {};
  bool fail = false;
  int readAllCalls = 0, deleteAllCalls = 0;
  void check(Map<String, String> options) {
    lastOptions = options;
    if (fail) throw StateError('sensitive-platform-detail');
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    check(options);
    values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    check(options);
    return values[key];
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    check(options);
    values.remove(key);
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => values.containsKey(key);
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    readAllCalls++;
    return values;
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    deleteAllCalls++;
    values.clear();
  }
}
