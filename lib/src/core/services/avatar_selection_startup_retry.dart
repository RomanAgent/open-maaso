import 'package:maaso/src/core/services/avatar_config_service.dart';

/// Shares the complete startup pass, including its bounded retry delays, with
/// explicit recovery requests for the same mounted account's Avatar config.
/// A read-only state can be published before catalog/fallback work finishes;
/// callers must await that work instead of starting another reconciliation.
final class AvatarSelectionStartupRetry {
  factory AvatarSelectionStartupRetry.forConfig(AvatarConfigService config) =>
      _instances[config] ??= AvatarSelectionStartupRetry._(config);

  AvatarSelectionStartupRetry._(this._config);

  static final _instances = Expando<AvatarSelectionStartupRetry>();
  final AvatarConfigService _config;
  Future<void>? _inFlight;
  Future<void> Function()? _boundReconcile;
  void Function()? _boundRequireCurrentMount;

  bool get hasBoundRetry =>
      _boundReconcile != null && _boundRequireCurrentMount != null;

  /// Reuses the account/mount-fenced startup pass supplied by its owner. A
  /// Home retry joins a pass already running for the same configuration.
  Future<void> retryBound() {
    final reconcile = _boundReconcile;
    final requireCurrentMount = _boundRequireCurrentMount;
    if (reconcile == null || requireCurrentMount == null) {
      return Future<void>.error(StateError('avatar_startup_retry_unbound'));
    }
    return run(reconcile: reconcile, requireCurrentMount: requireCurrentMount);
  }

  Future<void> run({
    required Future<void> Function() reconcile,
    required void Function() requireCurrentMount,
  }) async {
    requireCurrentMount();
    _boundReconcile = reconcile;
    _boundRequireCurrentMount = requireCurrentMount;
    final existing = _inFlight;
    if (existing != null) {
      await existing;
      requireCurrentMount();
      return;
    }
    final operation = Future<void>.microtask(
      () => _run(reconcile, requireCurrentMount),
    );
    _inFlight = operation;
    try {
      await operation;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _run(
    Future<void> Function() reconcile,
    void Function() requireCurrentMount,
  ) async {
    try {
      requireCurrentMount();
      await reconcile();
      requireCurrentMount();
    } catch (_) {
      // A generic transport/catalog failure otherwise leaves synchronizing
      // forever. Only this still-current owner may make it retryable; a stale
      // account must not mutate a replacement account or its old renderer.
      try {
        requireCurrentMount();
        if (_config.selectionAuthorityState.value ==
            AvatarSelectionAuthorityState.synchronizing) {
          _config.markAuthoritativeSelectionReadOnly();
        }
      } catch (_) {
        // Preserve the original failure when the account/owner has changed.
      }
      rethrow;
    }
  }
}
