import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

/// Local DTO initialization happens inside the mount transaction, before the
/// session is published. Use only the exact validated candidate captured by
/// that mount; never publish credentials early to make initialization work.
String localMountAccessToken({
  required AuthSessionService auth,
  required MaasoAuthCandidate candidate,
  required AccountStorageScopeMount mount,
  required AccountStorageScopeService scopes,
}) {
  scopes.requireCurrent(mount);
  if (!identical(auth.candidate, candidate) ||
      !candidate.session.isValid ||
      candidate.environment.key != mount.scope.environmentKey ||
      candidate.session.accountUuid != mount.scope.accountUuid) {
    throw StateError('Local account mount credentials changed.');
  }
  return candidate.session.accessToken;
}
