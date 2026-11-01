import 'package:sembast/sembast.dart';

import 'account_storage_scope_service.dart';
import 'app_database_opener_stub.dart'
    if (dart.library.io) 'app_database_opener_io.dart'
    if (dart.library.js_interop) 'app_database_opener_web.dart'
    as implementation;

/// Opens the app's production database using the current platform backend.
Future<Database> openDefaultAppDatabase() {
  return implementation.openDefaultAppDatabase();
}

/// Opens the database owned by [scope] without consulting legacy storage.
Future<Database> openScopedAppDatabase(AccountStorageScope scope) {
  return implementation.openScopedAppDatabase(scope);
}
