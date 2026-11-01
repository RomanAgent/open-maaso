import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test(
    'compile-time policy exposes only environments allowed by the build',
    () {
      final storage = _MemorySecureStorageService();
      appServices.put<SecureStorageService>(storage);

      final service = AppEnvironmentService();

      expect(
        service.allowedEnvironments,
        kMaasoStoreInternalBuild
            ? const <MaasoEnvironment>[MaasoEnvironment.test]
            : MaasoEnvironment.values,
      );
    },
  );

  test(
    'restoring a stored production choice fails closed in internal builds',
    () async {
      final storage = _MemorySecureStorageService()
        ..values[GlobalConstant.keyMaasoEnvironment] =
            MaasoEnvironment.production.key;
      appServices.put<SecureStorageService>(storage);

      final service = AppEnvironmentService();
      await service.init();

      if (kMaasoStoreInternalBuild) {
        expect(service.environment.value, MaasoEnvironment.test);
        expect(
          storage.values[GlobalConstant.keyMaasoEnvironment],
          MaasoEnvironment.test.key,
        );
      } else {
        expect(service.environment.value, MaasoEnvironment.production);
        expect(
          storage.values[GlobalConstant.keyMaasoEnvironment],
          MaasoEnvironment.production.key,
        );
      }
    },
  );

  test('production switching follows the compile-time build policy', () async {
    final storage = _MemorySecureStorageService();
    appServices.put<SecureStorageService>(storage);

    final service = AppEnvironmentService();
    await service.init();

    if (kMaasoStoreInternalBuild) {
      await expectLater(
        service.setEnvironment(MaasoEnvironment.production),
        throwsA(isA<StateError>()),
      );
      expect(service.environment.value, MaasoEnvironment.test);
      expect(
        storage.values[GlobalConstant.keyMaasoEnvironment],
        isNot(MaasoEnvironment.production.key),
      );
    } else {
      await service.setEnvironment(MaasoEnvironment.production);
      expect(service.environment.value, MaasoEnvironment.production);
      expect(
        storage.values[GlobalConstant.keyMaasoEnvironment],
        MaasoEnvironment.production.key,
      );
    }
  });
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];
}
