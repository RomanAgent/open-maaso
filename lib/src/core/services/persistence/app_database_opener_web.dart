import 'package:sembast_web/sembast_web.dart';

import 'account_storage_scope_service.dart';

Future<Database> openDefaultAppDatabase() {
  return databaseFactoryWeb.openDatabase('maaso.db');
}

Future<Database> openScopedAppDatabase(AccountStorageScope scope) {
  return databaseFactoryWeb.openDatabase(scope.webDatabaseName);
}
