import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

import '../data/deletion_local_purger.dart';
import '../data/deletion_receipt_store.dart';
import '../data/deletion_secret_purger.dart';
import '../domain/deletion_models.dart';
import 'account_deletion_service.dart';

/// Installed when routing is created, including a signed-out cold start. No
/// network request or account-owned runtime is created by this registration.
void ensureAccountDeletionHost() {
  if (appServices.isRegistered<AccountDeletionService>()) return;
  final auth = appServices.maybeFind<AuthSessionService>();
  final environment = appServices.maybeFind<AppEnvironmentService>();
  final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
  final storage = appServices.maybeFind<SecureStorageService>();
  if (auth == null ||
      environment == null ||
      lifecycle == null ||
      storage == null) {
    return;
  }
  String accountId() {
    final selected = environment.environment.value;
    final candidate = auth.candidate;
    if (candidate != null && candidate.environment == selected) {
      return candidate.session.accountUuid;
    }
    final mounted = lifecycle.activeScope;
    if (mounted?.environmentKey == selected.key &&
        auth.session.value?.accountUuid == mounted?.accountUuid) {
      return mounted?.accountUuid ?? '';
    }
    return '';
  }

  final service = appServices.put(
    AccountDeletionService(
      baseUri: () => environment.baseUri,
      accountId: accountId,
      receipts: SecureDeletionReceiptStore(storage),
      requestEmailCode: (email) => auth.issueEmailCaptcha(email: email),
      closeCapturedAccount: (baseUri, account) async {
        final selected = MaasoEnvironment.values
            .where((value) => Uri.parse('${value.baseUrl}/') == baseUri)
            .firstOrNull;
        if (selected == null) {
          throw const DeletionException('receipt_environment_mismatch');
        }
        final scope = AccountStorageScope(
          environmentKey: selected.key,
          accountUuid: account,
        );
        // Both ownership validation and local erasure run inside the lifecycle
        // queue. A queued login cannot replace this account between the check,
        // teardown and file deletion.
        await lifecycle.signOutAndUnmount(
          expectedScope: scope,
          afterSignOut: () async {
            await purgeDeletedAccountSecrets(scope, storage);
            await purgeDeletedAccountScope(scope);
          },
        );
      },
    ),
    permanent: true,
  );
  appServices.put(
    _AccountDeletionHost(service, auth, environment, lifecycle),
    permanent: true,
  );
}

final class _AccountDeletionHost extends AppService {
  _AccountDeletionHost(
    this.service,
    this.auth,
    this.environment,
    this.lifecycle,
  );
  final AccountDeletionService service;
  final AuthSessionService auth;
  final AppEnvironmentService environment;
  final AccountSessionLifecycleService lifecycle;
  final List<Worker> _workers = [];
  @override
  void onInit() {
    super.onInit();
    _workers.addAll([
      ever(auth.session, (_) => service.contextChanged()),
      ever(environment.environment, (_) => service.contextChanged()),
    ]);
    lifecycle.addListener(service.contextChanged);
    service.contextChanged();
  }

  @override
  void onClose() {
    for (final worker in _workers) {
      worker.dispose();
    }
    lifecycle.removeListener(service.contextChanged);
    super.onClose();
  }
}
