import 'package:sembast/sembast.dart';

import 'account_storage_scope_service.dart';

Future<Database> openDefaultAppDatabase() {
  throw UnsupportedError('No Sembast backend is available on this platform.');
}

Future<Database> openScopedAppDatabase(AccountStorageScope scope) {
  throw UnsupportedError(
    'No scoped Sembast backend is available on this platform.',
  );
}
