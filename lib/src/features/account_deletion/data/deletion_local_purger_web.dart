import 'package:sembast_web/sembast_web.dart';
import 'package:web/web.dart' as web;
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

Future<void> purgeDeletedAccountScope(AccountStorageScope scope) async {
  await databaseFactoryWeb.deleteDatabase(scope.webDatabaseName);
  final storage = web.window.localStorage;
  final keys = <String>[];
  for (var i = 0; i < storage.length; i++) {
    final key = storage.key(i);
    if (key != null &&
        (key == scope.webKeyPrefix ||
            key.startsWith('${scope.webKeyPrefix}.') ||
            key.startsWith('flutter.${scope.webKeyPrefix}.'))) {
      keys.add(key);
    }
  }
  for (final key in keys) {
    storage.removeItem(key);
  }
}
