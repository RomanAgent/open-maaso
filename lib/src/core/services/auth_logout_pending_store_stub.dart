import 'auth_logout_pending_store.dart';

AuthLogoutPendingStore createPlatformAuthLogoutPendingStore() =>
    _UnsupportedAuthLogoutPendingStore();

final class _UnsupportedAuthLogoutPendingStore
    implements AuthLogoutPendingStore {
  Never _unsupported() =>
      throw UnsupportedError('Durable logout fencing is unavailable.');

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async =>
      _unsupported();

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async => _unsupported();

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) async => _unsupported();
}
