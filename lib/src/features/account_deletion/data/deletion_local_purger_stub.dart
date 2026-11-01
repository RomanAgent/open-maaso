import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

Future<void> purgeDeletedAccountScope(AccountStorageScope scope) async {
  throw UnsupportedError(
    'Local account erasure is unavailable on this platform.',
  );
}
