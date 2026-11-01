import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/account_deletion/data/deletion_secret_purger.dart';
import 'package:maaso/src/features/account_deletion/domain/deletion_models.dart';

class _Storage extends SecureStorageService {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<bool> delete(String key) async {
    if (fail) return false;
    data.remove(key);
    return true;
  }

  @override
  Future<String?> readPlatformValue(String key) async => data[key];
}

void main() {
  test(
    'removes only the captured account secret and preserves shared keys and receipt',
    () async {
      final a = AccountStorageScope(environmentKey: 'test', accountUuid: 'a'),
          b = AccountStorageScope(environmentKey: 'test', accountUuid: 'b');
      final key = '${a.storageNamespace}.secure.agent_token',
          other = '${b.storageNamespace}.secure.agent_token';
      final s = _Storage()
        ..data.addAll({
          key: 'private-a',
          other: 'private-b',
          'maaso.account.deletion.receipt.v1': 'receipt',
          'llm_direct_cloud_config_v1': 'shared-unattributed',
        });
      await purgeDeletedAccountSecrets(a, s);
      expect(s.data.containsKey(key), false);
      expect(s.data[other], 'private-b');
      expect(s.data.length, 3);
    },
  );
  test('failed secret deletion cannot be reported as completed', () async {
    final s = _Storage()..fail = true;
    final scope = AccountStorageScope(environmentKey: 'test', accountUuid: 'a');
    await expectLater(
      purgeDeletedAccountSecrets(scope, s),
      throwsA(isA<DeletionException>()),
    );
  });
}
