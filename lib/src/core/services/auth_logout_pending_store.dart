import 'auth_logout_pending_store_stub.dart'
    if (dart.library.io) 'auth_logout_pending_store_io.dart'
    if (dart.library.js_interop) 'auth_logout_pending_store_web.dart'
    as implementation;

/// A versioned view of the device-global logout fence.
///
/// [pending] is deliberately true for missing, corrupt, or mismatched durable
/// records. [revision] and [token] form the compare-and-swap version used to
/// ensure an older process or browser tab cannot clear a newer logout.
final class AuthLogoutPendingSnapshot {
  const AuthLogoutPendingSnapshot({
    required this.pending,
    required this.revision,
    required this.token,
    this.ownerFingerprint,
  });

  final bool pending;
  final int revision;
  final String token;
  final String? ownerFingerprint;

  bool sameVersion(AuthLogoutPendingSnapshot other) =>
      revision == other.revision && token == other.token;
}

/// Crash-durable, non-secret evidence that credential deletion is incomplete.
///
/// This store must be independent of the secure credential backend. A missing
/// or unreadable record is never equivalent to a cleared record.
abstract interface class AuthLogoutPendingStore {
  Future<AuthLogoutPendingSnapshot> read(String environmentKey);

  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  });

  /// Replaces [expected] with a durable cleared record.
  ///
  /// Returns null when another process or tab changed the fence after
  /// [expected] was observed.
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  });
}

AuthLogoutPendingStore createDefaultAuthLogoutPendingStore() =>
    implementation.createPlatformAuthLogoutPendingStore();
