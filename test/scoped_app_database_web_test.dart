@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast_web/sembast_web.dart';

void main() {
  test(
    'DBService scoped IndexedDB ignores legacy and isolates accounts',
    () async {
      final runId = DateTime.now().microsecondsSinceEpoch;
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'web-account-a-$runId',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'web-account-b-$runId',
      );
      final store = stringMapStoreFactory.store('scope_probe');
      final recordKey = 'self-$runId';

      addTearDown(() async {
        await databaseFactoryWeb.deleteDatabase(accountA.webDatabaseName);
        await databaseFactoryWeb.deleteDatabase(accountB.webDatabaseName);
        final legacy = await databaseFactoryWeb.openDatabase(
          LegacyAccountStorageQuarantine.databaseName,
        );
        await store.record(recordKey).delete(legacy);
        await legacy.close();
      });

      final legacy = await databaseFactoryWeb.openDatabase(
        LegacyAccountStorageQuarantine.databaseName,
      );
      await store.record(recordKey).put(legacy, <String, Object?>{
        'owner': 'legacy',
      });
      await legacy.close();

      final firstA = await DBService().init(scope: accountA);
      expect(await store.record(recordKey).get(firstA.raw), isNull);
      await store.record(recordKey).put(firstA.raw, <String, Object?>{
        'owner': 'account-a',
      });
      await firstA.close();

      final firstB = await DBService().init(scope: accountB);
      expect(await store.record(recordKey).get(firstB.raw), isNull);
      await firstB.close();

      final restoredA = await DBService().init(scope: accountA);
      expect(
        await store.record(recordKey).get(restoredA.raw),
        <String, Object?>{'owner': 'account-a'},
      );
      await restoredA.close();
    },
  );
}
