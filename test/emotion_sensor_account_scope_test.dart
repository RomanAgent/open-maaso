import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'camera opt-in is account scoped and legacy state stays quarantined',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{
        'emotion_sensor.user_enabled': true,
      });
      const rawAccountA = 'private-owner-a@example.test';
      const rawAccountB = 'private-owner-b@example.test';
      final prefixA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: rawAccountA,
      ).agent('self').storageNamespace;
      final prefixB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: rawAccountB,
      ).agent('self').storageNamespace;

      final accountA = EmotionSensorService(
        storageKeyPrefix: prefixA,
        cameraLoader: () async => const [],
      );
      await accountA.start();
      expect(accountA.userEnabled.value, isTrue);

      final accountB = EmotionSensorService(storageKeyPrefix: prefixB);
      accountB.onInit();
      await Future<void>.delayed(Duration.zero);
      expect(accountB.userEnabled.value, isFalse);

      final restoredA = EmotionSensorService(storageKeyPrefix: prefixA);
      restoredA.onInit();
      await Future<void>.delayed(Duration.zero);
      expect(restoredA.userEnabled.value, isTrue);

      final legacy = EmotionSensorService();
      legacy.onInit();
      await Future<void>.delayed(Duration.zero);
      expect(legacy.userEnabled.value, isTrue);

      final keys = (await SharedPreferences.getInstance()).getKeys();
      expect(keys.every((key) => !key.contains(rawAccountA)), isTrue);
      expect(keys.every((key) => !key.contains(rawAccountB)), isTrue);
      expect(keys.where((key) => key.contains(prefixA)), hasLength(1));
      expect(keys.where((key) => key.contains(prefixB)), isEmpty);

      accountB.onClose();
      restoredA.onClose();
      legacy.onClose();
    },
  );
}
