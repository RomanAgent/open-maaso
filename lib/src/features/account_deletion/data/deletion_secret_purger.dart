import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import '../domain/deletion_models.dart';

/// Removes the existing account-scoped secure Agent credential. Environment
/// login credentials are removed by signOutAndUnmount. Unscoped BYOK settings
/// have no attributable owner and are deliberately not claimed by this account.
Future<void> purgeDeletedAccountSecrets(
  AccountStorageScope scope,
  SecureStorageService storage,
) async {
  final key = '${scope.storageNamespace}.secure.agent_token';
  if (!await storage.delete(key) || await storage.readStrict(key) != null) {
    throw const DeletionException('local_cleanup_pending');
  }
}
