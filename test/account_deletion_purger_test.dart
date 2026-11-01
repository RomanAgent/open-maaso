import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/account_deletion/data/deletion_local_purger_io.dart';

void main() {
  test(
    'erases only captured account directory and preserves other account and legacy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maaso-deletion-fixture-',
      );
      addTearDown(() => root.delete(recursive: true));
      final a = AccountStorageScope(
            environmentKey: 'test',
            accountUuid: 'owner-a',
          ),
          b = AccountStorageScope(
            environmentKey: 'test',
            accountUuid: 'owner-b',
          );
      final mine = Directory('${root.path}/${a.nativeRelativeDirectory}'),
          other = Directory('${root.path}/${b.nativeRelativeDirectory}');
      await mine.create(recursive: true);
      await other.create(recursive: true);
      await File('${mine.path}/state.db').writeAsString('private-a');
      await File('${other.path}/state.db').writeAsString('private-b');
      await File('${root.path}/maaso.db').writeAsString('legacy');
      await purgeDeletedAccountScope(a, applicationSupportRoot: root);
      expect(await mine.exists(), false);
      expect(await File('${other.path}/state.db').readAsString(), 'private-b');
      expect(await File('${root.path}/maaso.db').readAsString(), 'legacy');
      await purgeDeletedAccountScope(a, applicationSupportRoot: root);
    },
  );
  test(
    'refuses symbolic links instead of following another account path',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maaso-deletion-fixture-',
      );
      addTearDown(() => root.delete(recursive: true));
      final a = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner-a',
      );
      final other = await Directory('${root.path}/other').create();
      await File('${other.path}/safe.txt').writeAsString('keep');
      final mine = Directory('${root.path}/${a.nativeRelativeDirectory}');
      await mine.parent.create(recursive: true);
      await Link(mine.path).create(other.path);
      expect(
        () => purgeDeletedAccountScope(a, applicationSupportRoot: root),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('${other.path}/safe.txt').readAsString(), 'keep');
    },
  );
}
