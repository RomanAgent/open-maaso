import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/localization/server_error_localization.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/auth_credential_transaction_lock.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

export 'package:maaso/src/core/services/auth_logout_pending_store.dart';

const String _sessionCommitKey = 'maaso_session_record_commit_v2';
const String _sessionOwnerKey = 'maaso_session_record_owner_v1';
const String _sessionCommitPrefix = 'v2:';
const String _invalidSessionCommit = 'v2:invalid';
const int _credentialRecordIdentitySchema = 1;
const String _credentialOwnerFingerprintDomain =
    'maaso.auth.credential-owner.v1';
final Object _signOutOperationZoneKey = Object();

final class AuthCredentialCleanupFailure implements Exception {
  const AuthCredentialCleanupFailure({
    required this.cause,
    required this.causeStackTrace,
    required this.environment,
    required this.operationEpoch,
  });

  final Object cause;
  final StackTrace causeStackTrace;
  final MaasoEnvironment environment;
  final int operationEpoch;

  @override
  String toString() => 'Authentication credential cleanup is still pending.';
}

/// The previous credential owner cannot be safely recovered from this
/// installation. Only a newly validated login may replace the retained state.
final class AuthCredentialReauthenticationRequired extends StateError {
  AuthCredentialReauthenticationRequired()
    : super('Pending credential cleanup owner cannot be recovered.');

  AuthCredentialReauthenticationRequired.activeRecord()
    : super('Pending active credential cleanup owner cannot be recovered.');
}

final class _MemoryAuthLogoutPendingStore implements AuthLogoutPendingStore {
  final Map<String, AuthLogoutPendingSnapshot> _states =
      <String, AuthLogoutPendingSnapshot>{};

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async =>
      _states[environmentKey] ??
      const AuthLogoutPendingSnapshot(
        pending: true,
        revision: 0,
        token: 'memory:missing',
      );

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async {
    final current = await read(environmentKey);
    final next = AuthLogoutPendingSnapshot(
      pending: true,
      revision: current.revision + 1,
      token: 'memory:${current.revision + 1}:pending',
      ownerFingerprint: ownerFingerprint,
    );
    _states[environmentKey] = next;
    return next;
  }

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) async {
    final current = await read(environmentKey);
    if (!current.sameVersion(expected)) return null;
    final next = AuthLogoutPendingSnapshot(
      pending: false,
      revision: current.revision + 1,
      token: 'memory:${current.revision + 1}:cleared',
    );
    _states[environmentKey] = next;
    return next;
  }
}

class MaasoAuthSession {
  const MaasoAuthSession({
    required this.accountUuid,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accountUuid;
  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  bool get isValid =>
      accessToken.trim().isNotEmpty &&
      expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)));
}

/// A durable, environment-bound session that is ready to mount but has not
/// necessarily been published to runtime consumers yet.
class MaasoAuthCandidate {
  const MaasoAuthCandidate({
    required this.environment,
    required this.session,
    required this.operationEpoch,
    required this.logoutFence,
  });

  final MaasoEnvironment environment;
  final MaasoAuthSession session;
  final int operationEpoch;
  final AuthLogoutPendingSnapshot logoutFence;
}

class AuthSessionService extends AppService {
  AuthSessionService({
    http.Client? httpClient,
    AuthLogoutPendingStore? logoutPendingStore,
    AuthCredentialTransactionLock? credentialTransactionLock,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _logoutPendingStore =
           logoutPendingStore ??
           (appServices.testMode
               ? _MemoryAuthLogoutPendingStore()
               : createDefaultAuthLogoutPendingStore()),
       _credentialTransactionLock =
           credentialTransactionLock ??
           (appServices.testMode
               ? InProcessAuthCredentialTransactionLock()
               : createDefaultAuthCredentialTransactionLock());

  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();
  final AppEnvironmentService _environment = appServices
      .find<AppEnvironmentService>();
  final http.Client _httpClient;
  final bool _ownsClient;
  final AuthLogoutPendingStore _logoutPendingStore;
  final AuthCredentialTransactionLock _credentialTransactionLock;
  final Object _credentialTransactionZoneKey = Object();

  final session = Rxn<MaasoAuthSession>();
  final isLoading = false.obs;
  final error = RxnString();

  MaasoAuthCandidate? _candidate;
  MaasoEnvironment? _publishedEnvironment;
  int _operationEpoch = 0;
  Future<void> _pendingCredentialCleanup = Future<void>.value();
  Future<void> _logoutPendingOperationTail = Future<void>.value();
  Future<void> _secureStorageOperationTail = Future<void>.value();
  _CredentialCleanupLease? _retryableCredentialCleanup;
  final Expando<bool> _credentialReauthentication = Expando<bool>();

  /// UI recovery guidance for the current retained cleanup only. This metadata
  /// never authorizes credential writes or changes lifecycle admission.
  bool get requiresCredentialReauthentication {
    final lease = _retryableCredentialCleanup;
    return lease != null &&
        lease.environment == _environment.environment.value &&
        _credentialReauthentication[lease] == true;
  }

  /// Pure in-memory evidence of the standard durable publish path. This does
  /// not restore, migrate, refresh or inspect secure-storage credentials.
  bool hasCommittedSessionForEnvironment(MaasoEnvironment environment) =>
      _publishedEnvironment == environment &&
      _environment.environment.value == environment &&
      _candidate?.environment == environment &&
      session.value != null &&
      identical(_candidate?.session, session.value);

  Future<void> waitForPendingCredentialCleanup() => _pendingCredentialCleanup;

  /// The environment-bound credentials that an account lifecycle may mount.
  /// Runtime token consumers must continue to read [session], which is only
  /// updated after [publishCandidate] commits the active record.
  MaasoAuthCandidate? get candidate => _candidate;

  /// Optional async boundary invoked before credentials or the active session
  /// are cleared. Account-scoped runtimes use this to finish teardown before a
  /// refresh failure or explicit sign-out can cross the account boundary.
  Future<void> Function()? beforeCredentialsCleared;

  /// Called when deferred refresh cleanup fails after the refresh Future has
  /// already failed closed. Account lifecycle ownership uses this to publish a
  /// retryable fault instead of leaving cleanup failure as a log-only event.
  Future<void> Function(AuthCredentialCleanupFailure failure)?
  credentialCleanupFailureObserver;

  bool isCredentialCleanupFailureCurrent(
    AuthCredentialCleanupFailure failure,
  ) =>
      failure.operationEpoch == _operationEpoch &&
      failure.environment == _environment.environment.value;

  Future<AuthSessionService> init() async {
    await activateCurrentEnvironment();
    return this;
  }

  Future<void> activateCurrentEnvironment() async {
    final env = _environment.environment.value;
    final operation = _beginOperation(env);
    session.value = null;
    _publishedEnvironment = null;
    _candidate = null;
    AuthLogoutPendingSnapshot? observedFence;
    _CredentialCleanupTargets? cleanupTargets;
    try {
      await _runCredentialTransaction(operation, () async {
        final logoutFence = await _readLogoutPending(operation);
        observedFence = logoutFence;
        if (logoutFence.pending) {
          cleanupTargets = await _capturePendingEnvironmentCleanupTargets(
            operation,
            logoutFence,
          );
          await _clearCredentialRecords(operation, cleanupTargets!);
          await _clearLogoutPending(operation, expected: logoutFence);
          return;
        }
        var stored = await _readScopedCredentialRecord(
          env,
          operation: operation,
        );
        _requireCurrent(operation);
        if (stored != null) {
          stored = await _ensureCredentialIdentityForScopedRecord(
            stored,
            operation,
          );
          _candidate = MaasoAuthCandidate(
            environment: env,
            session: stored.session,
            operationEpoch: operation.epoch,
            logoutFence: logoutFence,
          );
        }
      });
      _retryableCredentialCleanup = null;
    } on _StaleAuthOperation {
      rethrow;
    } on _SupersededAuthTransaction {
      _retryableCredentialCleanup = null;
      return;
    } catch (error, stackTrace) {
      if (error is AuthCredentialCleanupFailure) rethrow;
      if (error is _CredentialIdentityMigrationFailure) {
        cleanupTargets = error.cleanupTargets;
      }
      final failure = _credentialCleanupFailure(
        operation,
        error,
        stackTrace,
        lease: _CredentialCleanupLease(
          environment: operation.environment,
          priorFence: observedFence,
          pendingFence: observedFence?.pending == true ? observedFence : null,
          credentialOwner: null,
          cleanupTargets: cleanupTargets,
          retryActivation:
              observedFence?.pending != true && cleanupTargets == null,
        ),
      );
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<bool> restoreOrRefresh() async {
    final env = _environment.environment.value;
    final published = session.value;
    if (published == null || _publishedEnvironment != env) return false;
    if (published.isValid) return true;
    return refresh();
  }

  /// Restores or refreshes credentials without exposing them to runtime token
  /// consumers. Account lifecycle code mounts the scoped runtime first, then
  /// calls [publishCandidate].
  Future<bool> restoreCandidate() async {
    await activateCurrentEnvironment();
    final current = _candidate?.session;
    if (current == null) return false;
    if (current.isValid) return true;
    return _refreshCandidate(publish: false);
  }

  Future<void> login({required String email, required String password}) async {
    await _postAuth(
      '/v1/login/email',
      {'email': email.trim(), 'password': password, ..._appClaims()},
      fallbackMessage: 'auth.login_failed'.tr,
      publish: true,
    );
  }

  Future<void> loginCandidate({
    required String email,
    required String password,
  }) async {
    await _postAuth(
      '/v1/login/email',
      {'email': email.trim(), 'password': password, ..._appClaims()},
      fallbackMessage: 'auth.login_failed'.tr,
      publish: false,
    );
  }

  Future<int> issueEmailCaptcha({required String email}) async {
    final operation = _beginOperation(_environment.environment.value);
    final payload = await _postJson(
      '/v1/login/email/captcha',
      {'email': email.trim()},
      fallbackMessage: 'auth.code_request_failed'.tr,
      operation: operation,
    );
    final codeId = _intAt(payload, ['codeId']) ?? _intAt(payload, ['code_id']);
    if (codeId == null || codeId <= 0) {
      Log.w('[AuthSession] captcha response missing code id');
      final message = 'auth.code_response_invalid'.tr;
      error.value = message;
      throw StateError(message);
    }
    return codeId;
  }

  Future<void> signup({
    required String email,
    required String password,
    required int codeId,
    required String code,
  }) async {
    await _postAuth(
      '/v1/login/email/signup',
      {
        'email': email.trim(),
        'password': password,
        'codeId': codeId,
        'code': code.trim(),
        ..._appClaims(),
      },
      fallbackMessage: 'auth.signup_failed'.tr,
      publish: true,
    );
  }

  Future<void> signupCandidate({
    required String email,
    required String password,
    required int codeId,
    required String code,
  }) async {
    await _postAuth(
      '/v1/login/email/signup',
      {
        'email': email.trim(),
        'password': password,
        'codeId': codeId,
        'code': code.trim(),
        ..._appClaims(),
      },
      fallbackMessage: 'auth.signup_failed'.tr,
      publish: false,
    );
  }

  Future<bool> refresh() async {
    final env = _environment.environment.value;
    final published = session.value;
    if (published == null || _publishedEnvironment != env) return false;
    return _refreshSession(published, publish: true);
  }

  Future<bool> _refreshCandidate({required bool publish}) async {
    final current = _candidate?.session;
    return _refreshSession(current, publish: publish);
  }

  Future<bool> _refreshSession(
    MaasoAuthSession? current, {
    required bool publish,
  }) async {
    if (current == null || current.refreshToken.trim().isEmpty) return false;
    try {
      await _postAuth(
        '/v1/login/refresh',
        {'refresh_token': current.refreshToken, ..._appClaims()},
        fallbackMessage: 'auth.refresh_failed'.tr,
        publish: publish,
        refreshSession: current,
      );
      return publish
          ? session.value?.isValid ?? false
          : _candidate?.session.isValid ?? false;
    } on _StaleAuthOperation {
      return false;
    } on _SupersededAuthTransaction {
      return false;
    } on _RefreshAuthUpdateFailure catch (failure) {
      _scheduleRefreshFailureCleanup(
        failure.cause,
        credentialOwner: current,
        credentialOwnerIdentity: failure.credentialOwnerIdentity,
      );
      return false;
    } catch (error) {
      _scheduleRefreshFailureCleanup(error, credentialOwner: current);
      return false;
    }
  }

  /// Commits the current candidate to the active record before publishing it
  /// in memory. A failed secure-storage operation always leaves [session]
  /// unpublished and the active record invalid.
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    final current = _candidate;
    if (current == null) {
      throw StateError('No authentication candidate is available.');
    }
    if (expected != null && !_sameCandidate(current, expected)) {
      throw StateError('The authentication candidate changed before publish.');
    }
    if (current.environment != _environment.environment.value) {
      throw StateError('The authentication candidate environment is stale.');
    }
    final operation = _AuthOperation(
      epoch: current.operationEpoch,
      environment: current.environment,
    );
    _requireCurrent(operation);
    await _runCredentialTransaction(
      operation,
      () => _publishCandidateLocked(current, operation),
    );
  }

  Future<void> _publishCandidateLocked(
    MaasoAuthCandidate current,
    _AuthOperation operation,
  ) async {
    var persisted = await _readScopedCredentialRecord(
      current.environment,
      operation: operation,
    );
    if (persisted == null ||
        !_sameSession(persisted.session, current.session)) {
      throw const _SupersededAuthTransaction(
        'The authentication candidate is not durably committed.',
      );
    }
    await _requireLogoutFenceCurrent(operation, current.logoutFence);
    persisted = await _ensureCredentialIdentityForScopedRecord(
      persisted,
      operation,
    );
    final identity = persisted.identity!;

    session.value = null;
    _publishedEnvironment = null;
    await _writeActiveSession(
      current.session,
      operation: operation,
      identity: identity,
    );
    _requireCurrent(operation);
    try {
      await _requireLogoutFenceCurrent(operation, current.logoutFence);
    } catch (_) {
      await _clearActiveSession(operation: operation);
      rethrow;
    }
    _publishedEnvironment = current.environment;
    session.value = current.session;
  }

  /// Removes runtime-visible credentials while retaining the scoped candidate
  /// so a later lifecycle mount can explicitly publish it again.
  Future<void> unpublishSession() async {
    final inherited = Zone.current[_signOutOperationZoneKey];
    final operation = inherited is _AuthOperation
        ? inherited
        : _beginOperation(_environment.environment.value);
    _requireCurrent(operation);
    final environment = operation.environment;
    final retained = _candidate;
    final published = session.value;
    final publishedEnvironment = _publishedEnvironment;
    session.value = null;
    _publishedEnvironment = null;
    _candidate =
        inherited is _AuthOperation ||
            retained == null ||
            retained.environment != environment
        ? null
        : MaasoAuthCandidate(
            environment: retained.environment,
            session: retained.session,
            operationEpoch: operation.epoch,
            logoutFence: retained.logoutFence,
          );
    if (published == null || publishedEnvironment != environment) return;
    await _runCredentialTransaction(operation, () async {
      final active = await _readSessionRecord(
        _SessionRecordKeys.active(),
        operation: operation,
      );
      if (active != null && _sameSession(active, published)) {
        await _clearActiveSession(operation: operation);
      }
    });
  }

  Future<void> signOut() {
    final publishedOwner = session.value;
    final credentialOwner = publishedOwner ?? _candidate?.session;
    final operation = _beginOperation(_environment.environment.value);
    _failCloseInMemory();
    return runZoned(
      () => _finishSignOut(
        operation,
        credentialOwner: credentialOwner,
        preferActiveOwner: publishedOwner != null,
      ),
      zoneValues: <Object, Object>{_signOutOperationZoneKey: operation},
    );
  }

  /// Retries only durable credential cleanup. Runtime teardown is owned by
  /// [AccountSessionLifecycleService] and is retained alongside this retry in
  /// its fault lease.
  Future<void> retryCredentialCleanup() {
    final retainedLease = _retryableCredentialCleanup;
    if (retainedLease == null) return Future<void>.value();
    if (retainedLease.retryActivation) {
      if (retainedLease.environment != _environment.environment.value) {
        _retryableCredentialCleanup = null;
        return Future<void>.value();
      }
      final retry = activateCurrentEnvironment();
      _trackPendingCredentialCleanup(retry);
      return retry;
    }
    final operation = _beginOperation(_environment.environment.value);
    _failCloseInMemory();
    final cleanup = _runCredentialTransaction(
      operation,
      () => _clearCredentialsWithTombstone(operation, retainedLease),
    );
    _trackPendingCredentialCleanup(cleanup);
    return cleanup;
  }

  Future<void> _finishSignOut(
    _AuthOperation operation, {
    required MaasoAuthSession? credentialOwner,
    _CredentialRecordIdentity? credentialOwnerIdentity,
    bool preferActiveOwner = false,
  }) async {
    _requireCurrent(operation);
    session.value = null;
    _publishedEnvironment = null;
    _candidate = null;

    AuthLogoutPendingSnapshot? priorFence;
    AuthLogoutPendingSnapshot? markedFence;
    _CredentialCleanupTargets? cleanupTargets;
    try {
      // Persist the non-secret fence before runtime teardown and before either
      // secure-storage deletion starts. Runtime teardown still completes before
      // credentials are removed.
      markedFence = await _runCredentialTransaction(operation, () async {
        priorFence = await _readLogoutPending(operation);
        if (credentialOwner == null) return null;
        cleanupTargets = await _captureOwnedCredentialCleanupTargets(
          operation,
          credentialOwner,
          expectedIdentity: credentialOwnerIdentity,
          preferActiveOwner: preferActiveOwner,
        );
        if (cleanupTargets == null) {
          return null;
        }
        try {
          final ownerFingerprint = cleanupTargets!.fenceOwnerFingerprint;
          if (ownerFingerprint == null) {
            throw StateError('Credential cleanup owner is unavailable.');
          }
          return await _markLogoutPending(
            operation,
            ownerFingerprint: ownerFingerprint,
          );
        } catch (markError, markStackTrace) {
          try {
            // A fence backend failure cannot leave a valid committed secure
            // record that a later restart could restore. Keep this best-effort
            // invalidation inside the same device-wide credential transaction.
            await _clearCredentialRecords(operation, cleanupTargets!);
          } catch (recordError, recordStackTrace) {
            Error.throwWithStackTrace(
              _CredentialFenceAndRecordFailure(
                fenceError: markError,
                recordError: recordError,
                recordStackTrace: recordStackTrace,
              ),
              markStackTrace,
            );
          }
          Error.throwWithStackTrace(markError, markStackTrace);
        }
      });
    } on _StaleAuthOperation {
      rethrow;
    } on _SupersededAuthTransaction {
      markedFence = null;
    } catch (error, stackTrace) {
      final failure = _credentialCleanupFailure(
        operation,
        error,
        stackTrace,
        lease: _CredentialCleanupLease(
          environment: operation.environment,
          priorFence: priorFence,
          pendingFence: null,
          credentialOwner: credentialOwner,
          credentialOwnerIdentity: credentialOwnerIdentity,
          preferActiveOwner: preferActiveOwner,
          cleanupTargets: cleanupTargets,
        ),
      );
      Error.throwWithStackTrace(failure, stackTrace);
    }

    Object? boundaryError;
    StackTrace? boundaryStackTrace;
    try {
      await beforeCredentialsCleared?.call();
    } catch (error, stackTrace) {
      boundaryError = error;
      boundaryStackTrace = stackTrace;
    }

    Object? credentialError;
    StackTrace? credentialStackTrace;
    final logoutFence = markedFence;
    if (logoutFence != null) {
      try {
        await _runCredentialTransaction(operation, () async {
          final currentFence = await _readLogoutPending(operation);
          if (!currentFence.pending || !currentFence.sameVersion(logoutFence)) {
            // A newer login committed under the same device-global lock and
            // superseded this logout. Its credentials must not be removed.
            return;
          }
          await _clearCredentialRecords(operation, cleanupTargets!);
          await _clearLogoutPending(operation, expected: logoutFence);
        });
      } on _SupersededAuthTransaction {
        // The newer transaction owns both the fence and secure records.
      } catch (error, stackTrace) {
        credentialError = error;
        credentialStackTrace = stackTrace;
      }
    }

    _requireCurrent(operation);
    if (credentialError != null) {
      final failure = _credentialCleanupFailure(
        operation,
        credentialError,
        credentialStackTrace!,
        lease: _CredentialCleanupLease(
          environment: operation.environment,
          priorFence: priorFence,
          pendingFence: markedFence,
          credentialOwner: credentialOwner,
          credentialOwnerIdentity: credentialOwnerIdentity,
          preferActiveOwner: preferActiveOwner,
          cleanupTargets: cleanupTargets,
        ),
      );
      Error.throwWithStackTrace(failure, credentialStackTrace);
    }
    _retryableCredentialCleanup = null;
    if (boundaryError != null) {
      Error.throwWithStackTrace(boundaryError, boundaryStackTrace!);
    }
  }

  void _failCloseInMemory() {
    session.value = null;
    _publishedEnvironment = null;
    _candidate = null;
  }

  void _scheduleRefreshFailureCleanup(
    Object error, {
    required MaasoAuthSession credentialOwner,
    _CredentialRecordIdentity? credentialOwnerIdentity,
  }) {
    final operation = _beginOperation(_environment.environment.value);
    _failCloseInMemory();
    final completion = Completer<void>();
    _trackPendingCredentialCleanup(completion.future);
    // Escape any AgentRuntime/account-operation tracking zone before teardown.
    // A refresh can fail inside a tracked chat; inheriting that zone would make
    // registry shutdown wait for the very turn that is awaiting refresh.
    Zone.root.run(() {
      Timer.run(() async {
        if (!_isCurrent(operation)) {
          completion.complete();
          return;
        }
        try {
          await runZoned(
            () => _finishSignOut(
              operation,
              credentialOwner: credentialOwner,
              credentialOwnerIdentity: credentialOwnerIdentity,
            ),
            zoneValues: <Object, Object>{_signOutOperationZoneKey: operation},
          );
          completion.complete();
        } catch (cleanupError, cleanupStackTrace) {
          if (cleanupError is _StaleAuthOperation || !_isCurrent(operation)) {
            completion.complete();
            return;
          }
          Log.w(
            '[AuthSession] deferred refresh cleanup failed: $cleanupError '
            '(refresh error: $error)',
          );
          if (cleanupError is AuthCredentialCleanupFailure) {
            try {
              await credentialCleanupFailureObserver?.call(cleanupError);
            } catch (observerError) {
              Log.w(
                '[AuthSession] cleanup failure observer failed: '
                '$observerError',
              );
            }
          }
          if (!_isCurrent(operation)) {
            completion.complete();
            return;
          }
          completion.completeError(cleanupError, cleanupStackTrace);
        }
      });
    });
  }

  Future<void> _postAuth(
    String path,
    Map<String, dynamic> body, {
    required String fallbackMessage,
    required bool publish,
    MaasoAuthSession? refreshSession,
  }) async {
    final operation = _beginOperation(_environment.environment.value);
    _CredentialRecordIdentity? refreshCleanupIdentity;
    try {
      // Capture the durable fence under the device-global lock, but never hold
      // that lock across network I/O.
      final observedLogoutFence = await _runCredentialTransaction(
        operation,
        () => _readLogoutPending(operation),
      );
      final payload = await _postJson(
        path,
        body,
        fallbackMessage: fallbackMessage,
        operation: operation,
      );
      _requireCurrent(operation);
      final env = operation.environment;
      final previous = _candidate?.environment == env
          ? _candidate?.session
          : (_publishedEnvironment == env ? session.value : null);
      final parsed = _parseSession(payload, fallbackAccount: previous);
      if (refreshSession != null) {
        _requireRefreshAccountInvariant(
          payload: payload,
          parsed: parsed,
          expectedAccountUuid: refreshSession.accountUuid,
        );
      }
      await _runCredentialTransaction(operation, () async {
        final currentLogoutFence = await _readLogoutPending(operation);
        if (currentLogoutFence.pending != observedLogoutFence.pending ||
            !currentLogoutFence.sameVersion(observedLogoutFence)) {
          throw const _SupersededAuthTransaction();
        }
        if (refreshSession != null && currentLogoutFence.pending) {
          throw const _SupersededAuthTransaction();
        }
        final identity = refreshSession == null
            ? _CredentialRecordIdentity.fresh(env)
            : await _credentialIdentityForRefresh(operation, refreshSession);
        if (refreshSession != null) refreshCleanupIdentity = identity;
        await _writeScopedSession(
          env,
          parsed,
          operation: operation,
          identity: identity,
        );
        _requireCurrent(operation);
        // Login/signup may supersede a failed logout, but the tombstone can be
        // cleared only after the complete scoped record has committed.
        final committedLogoutFence = refreshSession == null
            ? await _clearLogoutPending(
                operation,
                expected: observedLogoutFence,
              )
            : await _requireLogoutFenceCurrent(operation, observedLogoutFence);
        final next = MaasoAuthCandidate(
          environment: env,
          session: parsed,
          operationEpoch: operation.epoch,
          logoutFence: committedLogoutFence,
        );
        _candidate = next;
        if (publish) await _publishCandidateLocked(next, operation);
        _retryableCredentialCleanup = null;
      });
    } on _StaleAuthOperation {
      rethrow;
    } on _SupersededAuthTransaction {
      rethrow;
    } catch (e, stackTrace) {
      Log.w('[AuthSession] session update failed path=$path: $e');
      error.value ??= fallbackMessage;
      final identity = refreshCleanupIdentity;
      if (refreshSession != null && identity != null) {
        Error.throwWithStackTrace(
          _RefreshAuthUpdateFailure(
            cause: e,
            credentialOwnerIdentity: identity,
          ),
          stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    required String fallbackMessage,
    required _AuthOperation operation,
  }) async {
    _requireCurrent(operation);
    isLoading.value = true;
    error.value = null;
    final elapsed = Stopwatch()..start();
    final uri = Uri.parse('${operation.environment.baseUrl}/').resolve(path);
    Log.i(
      '[AuthSession] request start operation=${operation.epoch} '
      'environment=${operation.environment.key} host=${uri.host} '
      'method=POST path=${uri.path}',
    );
    try {
      late final http.Response response;
      try {
        response = await _httpClient.post(
          uri,
          headers: const {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode(body),
        );
      } catch (requestError, requestStackTrace) {
        final category = _authTransportFailureCategory(requestError);
        ServerRequestFailureLog.transport(
          source: 'AuthSession',
          method: 'POST',
          uri: uri,
          error: '${requestError.runtimeType}:$category',
          stackTrace: requestStackTrace,
        );
        Log.w(
          '[AuthSession] request transport failed '
          'operation=${operation.epoch} environment=${operation.environment.key} '
          'path=${uri.path} elapsedMs=${elapsed.elapsedMilliseconds} '
          'errorType=${requestError.runtimeType} category=$category',
        );
        rethrow;
      }
      _requireCurrent(operation);
      Log.i(
        '[AuthSession] response received operation=${operation.epoch} '
        'environment=${operation.environment.key} path=${uri.path} '
        'status=${response.statusCode} bytes=${response.bodyBytes.length} '
        'elapsedMs=${elapsed.elapsedMilliseconds}',
      );
      Object? decoded;
      Object? decodeError;
      StackTrace? decodeStackTrace;
      if (response.body.trim().isEmpty) {
        decoded = const <String, dynamic>{};
      } else {
        try {
          decoded = jsonDecode(response.body);
        } catch (error, stackTrace) {
          decodeError = error;
          decodeStackTrace = stackTrace;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded is Map ? decoded['code']?.toString() : null;
        final serverMessage =
            _stringAt(decoded, ['message']) ?? _stringAt(decoded, ['error']);
        final message = code == null
            ? fallbackMessage
            : localizedServerErrorCode(code) ?? fallbackMessage;
        Log.w(
          '[AuthSession] request rejected operation=${operation.epoch} '
          'environment=${operation.environment.key} path=${uri.path} '
          'status=${response.statusCode} code=$code '
          'responseFormat=${decodeError == null ? 'json' : 'non_json'} '
          'serverMessagePresent=${serverMessage?.trim().isNotEmpty == true} '
          'elapsedMs=${elapsed.elapsedMilliseconds}',
        );
        error.value = message;
        throw StateError(message);
      }
      if (decodeError != null) {
        Log.w(
          '[AuthSession] response decode failed operation=${operation.epoch} '
          'environment=${operation.environment.key} path=${uri.path} '
          'status=${response.statusCode} bytes=${response.bodyBytes.length} '
          'elapsedMs=${elapsed.elapsedMilliseconds} '
          'errorType=${decodeError.runtimeType}',
          stackTrace: decodeStackTrace,
        );
        Error.throwWithStackTrace(decodeError, decodeStackTrace!);
      }
      if (decoded is! Map<String, dynamic>) {
        Log.w(
          '[AuthSession] invalid response envelope '
          'operation=${operation.epoch} environment=${operation.environment.key} '
          'path=${uri.path} decodedType=${decoded.runtimeType} '
          'elapsedMs=${elapsed.elapsedMilliseconds}',
        );
        error.value = fallbackMessage;
        throw StateError(fallbackMessage);
      }
      final code = decoded['code']?.toString();
      if (code != null && code.isNotEmpty && code != 'OK') {
        final serverMessage =
            _stringAt(decoded, ['message']) ?? _stringAt(decoded, ['error']);
        final message = localizedServerErrorCode(code) ?? fallbackMessage;
        Log.w(
          '[AuthSession] request failed operation=${operation.epoch} '
          'environment=${operation.environment.key} path=${uri.path} '
          'status=${response.statusCode} code=$code '
          'serverMessagePresent=${serverMessage?.trim().isNotEmpty == true} '
          'elapsedMs=${elapsed.elapsedMilliseconds}',
        );
        error.value = message;
        throw StateError(message);
      }
      final payload = decoded['data'] is Map<String, dynamic>
          ? decoded['data'] as Map<String, dynamic>
          : decoded;
      return payload;
    } on _StaleAuthOperation {
      rethrow;
    } catch (e, stackTrace) {
      _requireCurrent(operation);
      Log.w(
        '[AuthSession] request error operation=${operation.epoch} '
        'environment=${operation.environment.key} path=${uri.path} '
        'elapsedMs=${elapsed.elapsedMilliseconds} errorType=${e.runtimeType}',
        stackTrace: stackTrace,
      );
      error.value ??= fallbackMessage;
      rethrow;
    } finally {
      elapsed.stop();
      if (_isCurrent(operation)) isLoading.value = false;
    }
  }

  MaasoAuthSession _parseSession(
    Map<String, dynamic> payload, {
    MaasoAuthSession? fallbackAccount,
  }) {
    final accessToken = _stringAny(payload, [
      'access_token',
      'accessToken',
      'token',
    ]);
    final refreshToken = _stringAny(payload, ['refresh_token', 'refreshToken']);
    final accountUuid =
        _stringAny(payload, ['account_uuid', 'accountUuid', 'account_id']) ??
        _stringAt(payload, ['user', 'account_uuid']) ??
        _stringAt(payload, ['user', 'accountUuid']) ??
        _stringAt(payload, ['user', 'id']) ??
        fallbackAccount?.accountUuid ??
        '';
    final expiresAt = _expiresAt(payload);
    if (accessToken == null || accessToken.trim().isEmpty) {
      Log.w('[AuthSession] auth response missing access token');
      throw StateError('common.request_failed'.tr);
    }
    if (accountUuid.trim().isEmpty) {
      Log.w('[AuthSession] auth response missing account identity');
      throw StateError('common.request_failed'.tr);
    }
    return MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: accessToken,
      refreshToken: refreshToken ?? '',
      expiresAt: expiresAt,
    );
  }

  void _requireRefreshAccountInvariant({
    required Map<String, dynamic> payload,
    required MaasoAuthSession parsed,
    required String expectedAccountUuid,
  }) {
    final expected = expectedAccountUuid.trim();
    final explicit =
        _stringAny(payload, ['account_uuid', 'accountUuid', 'account_id']) ??
        _stringAt(payload, ['user', 'account_uuid']) ??
        _stringAt(payload, ['user', 'accountUuid']) ??
        _stringAt(payload, ['user', 'id']);
    final proven = explicit?.trim().isNotEmpty == true
        ? explicit!.trim()
        : _accountClaimFromJwt(parsed.accessToken);
    if (expected.isEmpty || proven == null || proven != expected) {
      throw StateError('Refresh response account identity did not match.');
    }
    if (parsed.accountUuid.trim() != expected) {
      throw StateError('Refresh session account identity changed.');
    }
  }

  String? _accountClaimFromJwt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (payload is! Map) return null;
      for (final key in const <String>[
        'account_uuid',
        'accountUuid',
        'account_id',
        'sub',
      ]) {
        final value = payload[key];
        if (value == null || value is Map || value is Iterable) continue;
        final text = value.toString().trim();
        if (text.isNotEmpty) return text;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  DateTime _expiresAt(Map<String, dynamic> payload) {
    final direct = _stringAny(payload, ['expires_at', 'expiresAt']);
    if (direct != null) {
      final parsed = DateTime.tryParse(direct);
      if (parsed != null) return parsed;
      final millis = int.tryParse(direct);
      if (millis != null) return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    final expiresIn = payload['expires_in'] ?? payload['expiresIn'];
    if (expiresIn is num) {
      return DateTime.now().add(Duration(seconds: expiresIn.toInt()));
    }
    if (expiresIn is String) {
      final seconds = int.tryParse(expiresIn);
      if (seconds != null) {
        return DateTime.now().add(Duration(seconds: seconds));
      }
    }
    return DateTime.now().add(const Duration(hours: 12));
  }

  Map<String, dynamic> _appClaims() => const {
    'app_id': 'maaso',
    'aud': 'maaso-agent',
    'scope': ['maaso:user'],
  };

  Future<void> _clearCredentialsWithTombstone(
    _AuthOperation operation,
    _CredentialCleanupLease retainedLease,
  ) async {
    if (retainedLease.environment != operation.environment) {
      if (identical(_retryableCredentialCleanup, retainedLease)) {
        _retryableCredentialCleanup = null;
      }
      return;
    }
    var activeLease = retainedLease;
    try {
      final currentFence = await _readLogoutPending(operation);
      AuthLogoutPendingSnapshot? cleanupFence;
      var cleanupTargets = retainedLease.cleanupTargets;
      final expectedPending = retainedLease.pendingFence;
      final expectedPrior = retainedLease.priorFence;
      if (expectedPending != null) {
        if (!currentFence.pending ||
            !currentFence.sameVersion(expectedPending)) {
          _retryableCredentialCleanup = null;
          return;
        }
        cleanupFence = currentFence;
      } else if (expectedPrior != null) {
        if (currentFence.pending != expectedPrior.pending ||
            !currentFence.sameVersion(expectedPrior)) {
          _retryableCredentialCleanup = null;
          return;
        }
        if (currentFence.pending) {
          cleanupFence = currentFence;
        } else {
          if (cleanupTargets == null) {
            final credentialOwner = retainedLease.credentialOwner;
            if (credentialOwner == null) {
              throw StateError('Credential cleanup owner is unavailable.');
            }
            cleanupTargets = await _captureOwnedCredentialCleanupTargets(
              operation,
              credentialOwner,
              expectedIdentity: retainedLease.credentialOwnerIdentity,
              preferActiveOwner: retainedLease.preferActiveOwner,
            );
            if (cleanupTargets == null) {
              _retryableCredentialCleanup = null;
              return;
            }
          }
          cleanupFence = await _markLogoutPending(
            operation,
            ownerFingerprint:
                cleanupTargets.fenceOwnerFingerprint ??
                (throw StateError('Credential cleanup owner is unavailable.')),
          );
        }
      } else {
        // A startup read failure has no safe cleared baseline. A recovered
        // cleared fence means a newer login won; only a still-pending fence may
        // be repaired by this retry.
        if (!currentFence.pending) {
          _retryableCredentialCleanup = null;
          return;
        }
        cleanupFence = currentFence;
      }
      cleanupTargets ??= retainedLease.credentialOwner == null
          ? await _capturePendingEnvironmentCleanupTargets(
              operation,
              cleanupFence,
            )
          : await _captureOwnedCredentialCleanupTargets(
                  operation,
                  retainedLease.credentialOwner!,
                  expectedIdentity: retainedLease.credentialOwnerIdentity,
                  preferActiveOwner: retainedLease.preferActiveOwner,
                ) ??
                const _CredentialCleanupTargets();
      activeLease = _CredentialCleanupLease(
        environment: retainedLease.environment,
        priorFence: retainedLease.priorFence,
        pendingFence: cleanupFence,
        credentialOwner: retainedLease.credentialOwner,
        credentialOwnerIdentity: retainedLease.credentialOwnerIdentity,
        preferActiveOwner: retainedLease.preferActiveOwner,
        cleanupTargets: cleanupTargets,
      );
      _retryableCredentialCleanup = activeLease;
      await _clearCredentialRecords(operation, cleanupTargets);
      await _clearLogoutPending(operation, expected: cleanupFence);
      if (identical(_retryableCredentialCleanup, activeLease)) {
        _retryableCredentialCleanup = null;
      }
    } on _SupersededAuthTransaction {
      _retryableCredentialCleanup = null;
    } on _StaleAuthOperation {
      rethrow;
    } catch (error, stackTrace) {
      final failure = _credentialCleanupFailure(
        operation,
        error,
        stackTrace,
        lease: activeLease,
      );
      Error.throwWithStackTrace(failure, stackTrace);
    }
  }

  Future<void> _clearCredentialRecords(
    _AuthOperation operation,
    _CredentialCleanupTargets targets,
  ) async {
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    final scopedTarget = targets.scoped;
    if (scopedTarget != null) {
      try {
        await _clearSessionRecordIfTarget(
          _SessionRecordKeys.scoped(operation.environment),
          scopedTarget,
          operation,
        );
      } catch (error, stackTrace) {
        cleanupError = error;
        cleanupStackTrace = stackTrace;
      }
    }
    final activeTarget = targets.active;
    if (activeTarget != null) {
      try {
        await _clearSessionRecordIfTarget(
          _SessionRecordKeys.active(),
          activeTarget,
          operation,
        );
      } catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      }
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
    }
  }

  Future<_CredentialCleanupTargets?> _captureOwnedCredentialCleanupTargets(
    _AuthOperation operation,
    MaasoAuthSession owner, {
    _CredentialRecordIdentity? expectedIdentity,
    bool preferActiveOwner = false,
  }) async {
    final scopedKeys = _SessionRecordKeys.scoped(operation.environment);
    final activeKeys = _SessionRecordKeys.active();
    if (expectedIdentity != null) {
      _requireCredentialIdentityEnvironment(expectedIdentity, operation);
      final scopedIdentity = await _readCredentialRecordIdentityMetadata(
        scopedKeys,
        operation,
      );
      final activeIdentity = await _readCredentialRecordIdentityMetadata(
        activeKeys,
        operation,
      );
      final targets = _CredentialCleanupTargets(
        scoped:
            scopedIdentity != null && scopedIdentity.sameOwner(expectedIdentity)
            ? _CredentialRecordCleanupTarget(expectedIdentity: expectedIdentity)
            : null,
        active:
            activeIdentity != null && activeIdentity.sameOwner(expectedIdentity)
            ? _CredentialRecordCleanupTarget(expectedIdentity: expectedIdentity)
            : null,
        fenceOwnerFingerprint: expectedIdentity.ownerFingerprint,
      );
      return targets.isEmpty ? null : targets;
    }
    var scoped = await _readCommittedCredentialRecord(scopedKeys, operation);
    var active = await _readCommittedCredentialRecord(activeKeys, operation);
    final ownsScoped = scoped != null && _sameSession(scoped.session, owner);
    final ownsActive =
        active != null &&
        _sameSession(active.session, owner) &&
        (active.identity == null ||
            active.identity!.environmentKey == operation.environment.key);
    if (!ownsScoped && !ownsActive) return null;

    for (final record in <_CommittedCredentialRecord?>[
      if (ownsScoped) scoped,
      if (ownsActive) active,
    ]) {
      final recordIdentity = record?.identity;
      if (recordIdentity != null) {
        _requireCredentialIdentityEnvironment(recordIdentity, operation);
      }
    }
    final preferred = preferActiveOwner
        ? (ownsActive ? active : null)
        : (ownsScoped ? scoped : null);
    final fallback = preferActiveOwner
        ? (ownsScoped ? scoped : null)
        : (ownsActive ? active : null);
    final identity =
        preferred?.identity ??
        fallback?.identity ??
        _CredentialRecordIdentity.fresh(operation.environment);
    if (ownsScoped && scoped.identity == null) {
      await _writeSessionRecord(
        scopedKeys,
        scoped.session,
        operation: operation,
        identity: identity,
      );
      scoped = _CommittedCredentialRecord(
        session: scoped.session,
        identity: identity,
      );
    }
    if (ownsActive && active.identity == null) {
      await _writeSessionRecord(
        activeKeys,
        active.session,
        operation: operation,
        identity: identity,
      );
      active = _CommittedCredentialRecord(
        session: active.session,
        identity: identity,
      );
    }
    final targets = _CredentialCleanupTargets(
      scoped:
          scoped == null || (ownsScoped && scoped.identity!.sameOwner(identity))
          ? _CredentialRecordCleanupTarget(
              expectedIdentity: identity,
              expectedLegacyOwner: owner,
            )
          : null,
      active:
          active == null || (ownsActive && active.identity!.sameOwner(identity))
          ? _CredentialRecordCleanupTarget(
              expectedIdentity: identity,
              expectedLegacyOwner: owner,
            )
          : null,
      fenceOwnerFingerprint: identity.ownerFingerprint,
    );
    return targets.isEmpty ? null : targets;
  }

  Future<_CredentialCleanupTargets> _capturePendingEnvironmentCleanupTargets(
    _AuthOperation operation,
    AuthLogoutPendingSnapshot fence,
  ) async {
    final scopedKeys = _SessionRecordKeys.scoped(operation.environment);
    final activeKeys = _SessionRecordKeys.active();
    final scopedIdentity = await _readCredentialRecordIdentityMetadata(
      scopedKeys,
      operation,
    );
    final activeIdentity = await _readCredentialRecordIdentityMetadata(
      activeKeys,
      operation,
    );
    final scopedHasSecrets = await _sessionRecordHasSecretPayload(
      scopedKeys,
      operation,
    );
    final activeHasSecrets = await _sessionRecordHasSecretPayload(
      activeKeys,
      operation,
    );
    final ownerFingerprint = fence.ownerFingerprint;
    if (ownerFingerprint == null) {
      // A missing/legacy fence is the first-install fail-closed baseline. It
      // may clean unidentified legacy payload only in this environment's
      // scoped slot. A self-describing same-environment record is newer than
      // that unknown fence and must never authorize itself for deletion.
      if (scopedIdentity != null ||
          activeIdentity?.environmentKey == operation.environment.key) {
        throw AuthCredentialReauthenticationRequired();
      }
      final scopedRecord = await _readCommittedCredentialRecord(
        scopedKeys,
        operation,
      );
      final activeRecord = await _readCommittedCredentialRecord(
        activeKeys,
        operation,
      );
      _CredentialRecordCleanupTarget? activeTarget;
      if (activeIdentity == null && activeHasSecrets) {
        if (scopedRecord == null ||
            activeRecord == null ||
            scopedRecord.identity != null ||
            activeRecord.identity != null ||
            !_sameSession(scopedRecord.session, activeRecord.session)) {
          throw AuthCredentialReauthenticationRequired.activeRecord();
        }
        activeTarget = _CredentialRecordCleanupTarget(
          expectedLegacyOwner: scopedRecord.session,
        );
      }
      return _CredentialCleanupTargets(
        scoped: scopedHasSecrets
            ? _CredentialRecordCleanupTarget(
                expectedLegacyOwner: scopedRecord?.session,
                allowUnidentifiedRecord: true,
              )
            : null,
        active: activeTarget,
      );
    }
    final expectedIdentity = _CredentialRecordIdentity(
      environmentKey: operation.environment.key,
      ownerFingerprint: ownerFingerprint,
    );
    final scopedMatches =
        scopedIdentity != null && scopedIdentity.sameOwner(expectedIdentity);
    final activeMatches =
        activeIdentity != null && activeIdentity.sameOwner(expectedIdentity);
    if (scopedIdentity == null && scopedHasSecrets) {
      throw StateError('Scoped credential owner metadata is unavailable.');
    }
    if (activeIdentity == null && activeHasSecrets) {
      throw StateError('Active credential owner metadata is unavailable.');
    }
    return _CredentialCleanupTargets(
      scoped: scopedMatches
          ? _CredentialRecordCleanupTarget(expectedIdentity: expectedIdentity)
          : null,
      active: activeMatches
          ? _CredentialRecordCleanupTarget(expectedIdentity: expectedIdentity)
          : null,
      fenceOwnerFingerprint: ownerFingerprint,
    );
  }

  Future<void> _clearSessionRecordIfTarget(
    _SessionRecordKeys keys,
    _CredentialRecordCleanupTarget target,
    _AuthOperation operation,
  ) async {
    final currentIdentity = await _readCredentialRecordIdentityMetadata(
      keys,
      operation,
    );
    final expectedIdentity = target.expectedIdentity;
    if (currentIdentity != null) {
      if (expectedIdentity == null ||
          !currentIdentity.sameOwner(expectedIdentity)) {
        return;
      }
    } else if (await _sessionRecordHasSecretPayload(keys, operation)) {
      final legacy = await _readCommittedCredentialRecord(keys, operation);
      final expectedLegacyOwner = target.expectedLegacyOwner;
      if (legacy == null ||
          legacy.identity != null ||
          expectedLegacyOwner == null ||
          !_sameSession(legacy.session, expectedLegacyOwner)) {
        if (!target.allowUnidentifiedRecord) {
          throw StateError('Credential owner metadata is unavailable.');
        }
      }
    }
    await _clearSessionRecord(keys, operation: operation);
  }

  Future<_CredentialRecordIdentity> _credentialIdentityForRefresh(
    _AuthOperation operation,
    MaasoAuthSession expected,
  ) async {
    final scopedKeys = _SessionRecordKeys.scoped(operation.environment);
    final activeKeys = _SessionRecordKeys.active();
    final scoped = await _readCommittedCredentialRecord(scopedKeys, operation);
    final active = await _readCommittedCredentialRecord(activeKeys, operation);
    final records = <(_SessionRecordKeys, _CommittedCredentialRecord)>[
      if (scoped != null) (scopedKeys, scoped),
      if (active != null) (activeKeys, active),
    ];
    if (records.isEmpty) throw const _SupersededAuthTransaction();

    _CredentialRecordIdentity? identity;
    for (final record in records) {
      if (!_sameSession(record.$2.session, expected)) {
        throw const _SupersededAuthTransaction();
      }
      final candidateIdentity = record.$2.identity;
      if (candidateIdentity == null) continue;
      _requireCredentialIdentityEnvironment(candidateIdentity, operation);
      if (identity != null && !identity.sameOwner(candidateIdentity)) {
        throw const _SupersededAuthTransaction(
          'Credential owner metadata changed during refresh.',
        );
      }
      identity = candidateIdentity;
    }
    identity ??= _CredentialRecordIdentity.fresh(operation.environment);
    for (final record in records) {
      if (record.$2.identity == null) {
        await _writeSessionRecord(
          record.$1,
          record.$2.session,
          operation: operation,
          identity: identity,
        );
      }
    }
    return identity;
  }

  Future<_CommittedCredentialRecord?> _readCommittedCredentialRecord(
    _SessionRecordKeys keys,
    _AuthOperation operation,
  ) => _readSessionRecordEnvelope(
    keys,
    operation: operation,
    invalidateMarkerless: false,
  );

  Future<_CredentialRecordIdentity?> _readCredentialRecordIdentityMetadata(
    _SessionRecordKeys keys,
    _AuthOperation operation,
  ) async {
    final encoded = await _readCurrent(keys.owner, operation);
    if (encoded == null) return null;
    final identity = _CredentialRecordIdentity.tryParse(encoded);
    if (identity == null) {
      throw StateError('Secure credential owner metadata is corrupt.');
    }
    return identity;
  }

  Future<bool> _sessionRecordHasSecretPayload(
    _SessionRecordKeys keys,
    _AuthOperation operation,
  ) async {
    for (final key in keys.secretPayloadKeys) {
      if (await _readCurrent(key, operation) != null) return true;
    }
    return false;
  }

  Future<_CommittedCredentialRecord?> _readSessionRecordEnvelope(
    _SessionRecordKeys keys, {
    required _AuthOperation operation,
    required bool invalidateMarkerless,
  }) async {
    final markerBefore = await _readCurrent(keys.commit, operation);
    if (markerBefore == _invalidSessionCommit) {
      // An invalid marker is a durable aborted-write tombstone. Retrying its
      // idempotent cleanup prevents partially written access/refresh tokens
      // from surviving a crash between the failed write and its rollback.
      await _clearSessionRecord(keys, operation: operation);
      return null;
    }
    if (markerBefore != null &&
        !markerBefore.startsWith(_sessionCommitPrefix)) {
      return null;
    }
    final accessToken = await _readCurrent(keys.accessToken, operation);
    final refreshToken = await _readCurrent(keys.refreshToken, operation);
    final accountUuid = await _readCurrent(keys.accountUuid, operation);
    final expiresAt = await _readCurrent(keys.expiresAt, operation);
    final encodedIdentity = await _readCurrent(keys.owner, operation);
    final parsed = _strictSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accountUuid: accountUuid,
      expiresAt: expiresAt,
    );
    if (markerBefore == null) {
      if (invalidateMarkerless) {
        await _clearSessionRecord(keys, operation: operation);
      }
      return null;
    }
    if (parsed == null) return null;
    final identity = _CredentialRecordIdentity.tryParse(encodedIdentity);
    if (encodedIdentity != null && identity == null) return null;
    final markerAfter = await _readCurrent(keys.commit, operation);
    if (markerAfter != markerBefore) return null;
    if (markerBefore !=
        _sessionCommit(keys.namespace, parsed, identity: identity)) {
      return null;
    }
    return _CommittedCredentialRecord(session: parsed, identity: identity);
  }

  Future<AuthLogoutPendingSnapshot> _readLogoutPending(
    _AuthOperation operation,
  ) async {
    _requireCurrent(operation);
    final snapshot = await _runLogoutPendingStore(
      () => _logoutPendingStore.read(operation.environment.key),
    );
    _requireCurrent(operation);
    return snapshot;
  }

  Future<AuthLogoutPendingSnapshot> _markLogoutPending(
    _AuthOperation operation, {
    required String ownerFingerprint,
  }) async {
    _requireCurrent(operation);
    final persisted = await _runLogoutPendingStore(
      () => _logoutPendingStore.markPending(
        operation.environment.key,
        ownerFingerprint: ownerFingerprint,
      ),
    );
    _requireCurrent(operation);
    if (!persisted.pending) {
      throw StateError('Logout-pending credential fence could not be stored.');
    }
    return persisted;
  }

  Future<AuthLogoutPendingSnapshot> _clearLogoutPending(
    _AuthOperation operation, {
    required AuthLogoutPendingSnapshot expected,
  }) async {
    _requireCurrent(operation);
    final cleared = await _runLogoutPendingStore(
      () => _logoutPendingStore.clearPending(
        operation.environment.key,
        expected: expected,
      ),
    );
    _requireCurrent(operation);
    if (cleared == null || cleared.pending) {
      if (cleared == null) throw const _SupersededAuthTransaction();
      throw StateError('Logout-pending credential fence could not be cleared.');
    }
    return cleared;
  }

  Future<AuthLogoutPendingSnapshot> _requireLogoutFenceCurrent(
    _AuthOperation operation,
    AuthLogoutPendingSnapshot expected,
  ) async {
    final current = await _readLogoutPending(operation);
    if (current.pending || !current.sameVersion(expected)) {
      throw const _SupersededAuthTransaction();
    }
    return current;
  }

  Future<T> _runCredentialTransaction<T>(
    _AuthOperation operation,
    Future<T> Function() action,
  ) {
    _requireCurrent(operation);
    if (identical(Zone.current[_credentialTransactionZoneKey], this)) {
      return _runCredentialTransactionAction(operation, action);
    }
    return _credentialTransactionLock.synchronized(
      () => runZoned<Future<T>>(
        () => _runCredentialTransactionAction(operation, action),
        zoneValues: <Object, Object>{_credentialTransactionZoneKey: this},
      ),
    );
  }

  Future<T> _runCredentialTransactionAction<T>(
    _AuthOperation operation,
    Future<T> Function() action,
  ) async {
    _requireCurrent(operation);
    final result = await Future<T>.sync(action);
    _requireCurrent(operation);
    return result;
  }

  Future<T> _runLogoutPendingStore<T>(Future<T> Function() operation) {
    final completion = Completer<T>();
    _logoutPendingOperationTail = _logoutPendingOperationTail.then((_) async {
      try {
        completion.complete(await operation());
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  Future<T> _runSecureStorageOperation<T>(
    _AuthOperation operation,
    Future<T> Function() action,
  ) {
    final completion = Completer<T>();
    _secureStorageOperationTail = _secureStorageOperationTail.then((_) async {
      try {
        // The CAS before dispatch prevents a queued stale operation from ever
        // mutating storage. The CAS after completion cannot undo an already
        // dispatched platform write, but retaining this tail until it returns
        // ensures a newer operation cannot read or write ahead of it.
        _requireCurrent(operation);
        final result = await action();
        _requireCurrent(operation);
        completion.complete(result);
      } catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      }
    });
    return completion.future;
  }

  void _trackPendingCredentialCleanup(Future<void> cleanup) {
    _pendingCredentialCleanup = cleanup;
    // Keep Timer-scheduled cleanup errors observable through
    // waitForPendingCredentialCleanup without reporting them as an unhandled
    // asynchronous error when the lifecycle observer is the active consumer.
    unawaited(cleanup.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  AuthCredentialCleanupFailure _credentialCleanupFailure(
    _AuthOperation operation,
    Object cause,
    StackTrace stackTrace, {
    required _CredentialCleanupLease lease,
  }) {
    _retryableCredentialCleanup = lease;
    if (cause is AuthCredentialReauthenticationRequired) {
      _credentialReauthentication[lease] = true;
    }
    return AuthCredentialCleanupFailure(
      cause: cause,
      causeStackTrace: stackTrace,
      environment: operation.environment,
      operationEpoch: operation.epoch,
    );
  }

  Future<_CommittedCredentialRecord?> _readScopedCredentialRecord(
    MaasoEnvironment env, {
    required _AuthOperation operation,
  }) {
    return _readSessionRecordEnvelope(
      _SessionRecordKeys.scoped(env),
      operation: operation,
      invalidateMarkerless: true,
    );
  }

  Future<_CommittedCredentialRecord> _ensureCredentialIdentityForScopedRecord(
    _CommittedCredentialRecord scoped,
    _AuthOperation operation,
  ) async {
    final scopedKeys = _SessionRecordKeys.scoped(operation.environment);
    final activeKeys = _SessionRecordKeys.active();
    final active = await _readCommittedCredentialRecord(activeKeys, operation);
    final matchingActive =
        active != null && _sameSession(active.session, scoped.session)
        ? active
        : null;
    final scopedIdentity = scoped.identity;
    final activeIdentity = matchingActive?.identity;
    if (scopedIdentity != null) {
      _requireCredentialIdentityEnvironment(scopedIdentity, operation);
    }
    // A fresh scoped login is authoritative even when the backend returns the
    // exact same credential values as an older active record. Owner identity,
    // not token equality, distinguishes those two login transactions.
    final identity =
        scopedIdentity ??
        (activeIdentity?.environmentKey == operation.environment.key
            ? activeIdentity
            : null) ??
        _CredentialRecordIdentity.fresh(operation.environment);
    if (scopedIdentity == null) {
      final cleanupTargets = _CredentialCleanupTargets(
        scoped: _CredentialRecordCleanupTarget(
          expectedIdentity: identity,
          expectedLegacyOwner: scoped.session,
          allowUnidentifiedRecord: true,
        ),
        fenceOwnerFingerprint: identity.ownerFingerprint,
      );
      try {
        await _writeSessionRecord(
          scopedKeys,
          scoped.session,
          operation: operation,
          identity: identity,
        );
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          _CredentialIdentityMigrationFailure(
            cause: error,
            cleanupTargets: cleanupTargets,
          ),
          stackTrace,
        );
      }
    }
    return _CommittedCredentialRecord(
      session: scoped.session,
      identity: identity,
    );
  }

  void _requireCredentialIdentityEnvironment(
    _CredentialRecordIdentity identity,
    _AuthOperation operation,
  ) {
    if (identity.environmentKey != operation.environment.key) {
      throw StateError('Credential owner environment does not match.');
    }
  }

  Future<void> _writeScopedSession(
    MaasoEnvironment env,
    MaasoAuthSession next, {
    required _AuthOperation operation,
    required _CredentialRecordIdentity identity,
  }) async {
    await _writeSessionRecord(
      _SessionRecordKeys.scoped(env),
      next,
      operation: operation,
      identity: identity,
    );
  }

  Future<void> _writeActiveSession(
    MaasoAuthSession next, {
    required _AuthOperation operation,
    required _CredentialRecordIdentity identity,
  }) async {
    await _writeSessionRecord(
      _SessionRecordKeys.active(),
      next,
      operation: operation,
      identity: identity,
    );
  }

  Future<void> _clearActiveSession({required _AuthOperation operation}) async {
    await _clearSessionRecord(
      _SessionRecordKeys.active(),
      operation: operation,
    );
  }

  Future<MaasoAuthSession?> _readSessionRecord(
    _SessionRecordKeys keys, {
    required _AuthOperation operation,
  }) async => (await _readSessionRecordEnvelope(
    keys,
    operation: operation,
    invalidateMarkerless: true,
  ))?.session;

  Future<void> _writeSessionRecord(
    _SessionRecordKeys keys,
    MaasoAuthSession next, {
    required _AuthOperation operation,
    required _CredentialRecordIdentity identity,
  }) async {
    _requireCurrent(operation);
    final markerInvalidated = await _runSecureStorageOperation(
      operation,
      () => _storage.write(keys.commit, _invalidSessionCommit),
    );
    _requireCurrent(operation);
    if (!markerInvalidated) {
      final failure = StateError(
        'Secure credential write failed for ${keys.commit}.',
      );
      await _recoverFailedSessionWrite(
        keys,
        next,
        identity,
        operation,
        failure,
        StackTrace.current,
      );
    }
    try {
      // Owner metadata precedes every secret payload write. If a later write
      // fails, the durable invalid marker plus this identity can authorize an
      // exact, restart-safe cleanup without relying on token equality.
      await _requireWrite(keys.owner, identity.encode(), operation);
      await _requireWrite(keys.accessToken, next.accessToken, operation);
      await _requireWrite(keys.refreshToken, next.refreshToken, operation);
      await _requireWrite(keys.accountUuid, next.accountUuid, operation);
      await _requireWrite(
        keys.expiresAt,
        next.expiresAt.toIso8601String(),
        operation,
      );
      await _requireWrite(
        keys.commit,
        _sessionCommit(keys.namespace, next, identity: identity),
        operation,
      );
    } on _StaleAuthOperation {
      rethrow;
    } catch (error, stackTrace) {
      await _recoverFailedSessionWrite(
        keys,
        next,
        identity,
        operation,
        error,
        stackTrace,
      );
    }
  }

  Future<Never> _recoverFailedSessionWrite(
    _SessionRecordKeys keys,
    MaasoAuthSession attemptedSession,
    _CredentialRecordIdentity attemptedIdentity,
    _AuthOperation operation,
    Object writeError,
    StackTrace writeStackTrace,
  ) async {
    try {
      await _clearSessionRecord(keys, operation: operation);
    } on _StaleAuthOperation {
      rethrow;
    } catch (cleanupError, cleanupStackTrace) {
      var recoveryIdentity = attemptedIdentity;
      try {
        final durableIdentity = await _readCredentialRecordIdentityMetadata(
          keys,
          operation,
        );
        if (durableIdentity != null &&
            durableIdentity.environmentKey == operation.environment.key) {
          recoveryIdentity = durableIdentity;
        }
      } catch (_) {
        // The invalid commit marker still prevents restoration. A strict
        // activation read retries record cleanup even if owner recovery fails.
      }

      final recoveryTarget = _CredentialRecordCleanupTarget(
        expectedIdentity: recoveryIdentity,
        expectedLegacyOwner: attemptedSession,
        allowUnidentifiedRecord: true,
      );
      final cleanupTargets = _CredentialCleanupTargets(
        scoped: recoveryTarget,
        active: recoveryTarget,
        fenceOwnerFingerprint: recoveryIdentity.ownerFingerprint,
      );
      AuthLogoutPendingSnapshot? priorFence;
      AuthLogoutPendingSnapshot? pendingFence;
      Object failureCause = cleanupError;
      StackTrace failureStackTrace = cleanupStackTrace;
      try {
        priorFence = await _readLogoutPending(operation);
        if (priorFence.pending) {
          if (priorFence.ownerFingerprint ==
              recoveryIdentity.ownerFingerprint) {
            pendingFence = priorFence;
          }
        } else {
          pendingFence = await _markLogoutPending(
            operation,
            ownerFingerprint: recoveryIdentity.ownerFingerprint,
          );
        }
      } catch (fenceError, fenceStackTrace) {
        failureCause = _CredentialFenceAndRecordFailure(
          fenceError: fenceError,
          recordError: cleanupError,
          recordStackTrace: cleanupStackTrace,
        );
        failureStackTrace = fenceStackTrace;
      }

      final failure = _credentialCleanupFailure(
        operation,
        failureCause,
        failureStackTrace,
        lease: _CredentialCleanupLease(
          environment: operation.environment,
          priorFence: priorFence,
          pendingFence: pendingFence,
          credentialOwner: attemptedSession,
          credentialOwnerIdentity: recoveryIdentity,
          cleanupTargets: cleanupTargets,
          retryActivation: pendingFence == null,
        ),
      );
      Error.throwWithStackTrace(failure, failureStackTrace);
    }
    Error.throwWithStackTrace(writeError, writeStackTrace);
  }

  Future<void> _clearSessionRecord(
    _SessionRecordKeys keys, {
    required _AuthOperation operation,
  }) async {
    _requireCurrent(operation);
    var markerInvalidated = await _runSecureStorageOperation(
      operation,
      () => _storage.write(keys.commit, _invalidSessionCommit),
    );
    _requireCurrent(operation);
    if (markerInvalidated &&
        await _readCurrent(keys.commit, operation) != _invalidSessionCommit) {
      markerInvalidated = false;
    }
    String? failedSecretKey;
    for (final key in keys.secretPayloadKeys) {
      _requireCurrent(operation);
      if (!await _runSecureStorageOperation(
        operation,
        () => _storage.delete(key),
      )) {
        failedSecretKey ??= key;
      } else if (await _readCurrent(key, operation) != null) {
        failedSecretKey ??= key;
      }
      _requireCurrent(operation);
    }
    String? failedOwnerKey;
    if (markerInvalidated && failedSecretKey == null) {
      if (!await _runSecureStorageOperation(
        operation,
        () => _storage.delete(keys.owner),
      )) {
        failedOwnerKey = keys.owner;
      } else if (await _readCurrent(keys.owner, operation) != null) {
        failedOwnerKey = keys.owner;
      }
      _requireCurrent(operation);
    }
    if (!markerInvalidated) {
      throw StateError('Secure credential write failed for ${keys.commit}.');
    }
    if (failedSecretKey != null) {
      throw StateError('Secure credential delete failed for $failedSecretKey.');
    }
    if (failedOwnerKey != null) {
      throw StateError('Secure credential delete failed for $failedOwnerKey.');
    }
  }

  Future<void> _requireWrite(
    String key,
    String value,
    _AuthOperation operation,
  ) async {
    _requireCurrent(operation);
    if (!await _runSecureStorageOperation(
      operation,
      () => _storage.write(key, value),
    )) {
      throw StateError('Secure credential write failed for $key.');
    }
    _requireCurrent(operation);
  }

  Future<String?> _readCurrent(String key, _AuthOperation operation) async {
    _requireCurrent(operation);
    final value = await _runSecureStorageOperation(
      operation,
      () => _storage.readStrict(key),
    );
    _requireCurrent(operation);
    return value;
  }

  MaasoAuthSession? _strictSession({
    required String? accessToken,
    required String? refreshToken,
    required String? accountUuid,
    required String? expiresAt,
  }) {
    final parsedExpiry = DateTime.tryParse(expiresAt ?? '');
    if (accessToken == null ||
        accessToken.trim().isEmpty ||
        refreshToken == null ||
        accountUuid == null ||
        accountUuid.trim().isEmpty ||
        parsedExpiry == null) {
      return null;
    }
    return MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: parsedExpiry,
    );
  }

  String _sessionCommit(
    String namespace,
    MaasoAuthSession value, {
    _CredentialRecordIdentity? identity,
  }) {
    final canonical = jsonEncode(<String>[
      namespace,
      value.accountUuid,
      value.accessToken,
      value.refreshToken,
      value.expiresAt.toIso8601String(),
      if (identity != null) identity.environmentKey,
      if (identity != null) identity.ownerFingerprint,
    ]);
    return '$_sessionCommitPrefix${sha256.convert(utf8.encode(canonical))}';
  }

  _AuthOperation _beginOperation(MaasoEnvironment environment) =>
      _AuthOperation(epoch: ++_operationEpoch, environment: environment);

  bool _isCurrent(_AuthOperation operation) =>
      operation.epoch == _operationEpoch &&
      operation.environment == _environment.environment.value;

  void _requireCurrent(_AuthOperation operation) {
    if (!_isCurrent(operation)) throw const _StaleAuthOperation();
  }

  bool _sameCandidate(MaasoAuthCandidate a, MaasoAuthCandidate b) =>
      a.operationEpoch == b.operationEpoch &&
      a.environment == b.environment &&
      a.logoutFence.sameVersion(b.logoutFence) &&
      _sameSession(a.session, b.session);

  bool _sameSession(MaasoAuthSession a, MaasoAuthSession b) =>
      a.accountUuid == b.accountUuid &&
      a.accessToken == b.accessToken &&
      a.refreshToken == b.refreshToken &&
      a.expiresAt.toUtc() == b.expiresAt.toUtc();

  String? _stringAt(Object? source, List<String> path) {
    Object? value = source;
    for (final part in path) {
      if (value is! Map) return null;
      value = value[part];
    }
    if (value is Map || value is Iterable) return null;
    return value?.toString();
  }

  String? _stringAny(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value == null || value is Map || value is Iterable) continue;
      final text = value.toString();
      if (text.trim().isNotEmpty) return text;
    }
    return null;
  }

  int? _intAt(Object? source, List<String> path) {
    final value = _stringAt(source, path);
    if (value == null || value.trim().isEmpty) return null;
    return int.tryParse(value);
  }

  @override
  void onClose() {
    if (_ownsClient) _httpClient.close();
    super.onClose();
  }
}

class _AuthOperation {
  const _AuthOperation({required this.epoch, required this.environment});

  final int epoch;
  final MaasoEnvironment environment;
}

String _authTransportFailureCategory(Object error) {
  final message = error.toString().toLowerCase();
  if (message.contains('timed out') || message.contains('timeout')) {
    return 'timeout';
  }
  if (message.contains('handshake') ||
      message.contains('certificate') ||
      message.contains('tls')) {
    return 'tls';
  }
  if (message.contains('failed host lookup') ||
      message.contains('name or service not known') ||
      message.contains('dns')) {
    return 'dns';
  }
  if (message.contains('connection refused')) return 'connection_refused';
  if (message.contains('network is unreachable') ||
      message.contains('no route to host')) {
    return 'network_unreachable';
  }
  if (message.contains('connection reset') || message.contains('broken pipe')) {
    return 'connection_reset';
  }
  return 'transport';
}

class _StaleAuthOperation implements Exception {
  const _StaleAuthOperation();

  @override
  String toString() => 'Authentication operation was superseded.';
}

class _SupersededAuthTransaction implements Exception {
  const _SupersededAuthTransaction([
    this.message = 'Authentication transaction was superseded.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class _RefreshAuthUpdateFailure implements Exception {
  const _RefreshAuthUpdateFailure({
    required this.cause,
    required this.credentialOwnerIdentity,
  });

  final Object cause;
  final _CredentialRecordIdentity credentialOwnerIdentity;

  @override
  String toString() => cause.toString();
}

class _CredentialIdentityMigrationFailure implements Exception {
  const _CredentialIdentityMigrationFailure({
    required this.cause,
    required this.cleanupTargets,
  });

  final Object cause;
  final _CredentialCleanupTargets cleanupTargets;

  @override
  String toString() => cause.toString();
}

class _CredentialCleanupLease {
  const _CredentialCleanupLease({
    required this.environment,
    required this.priorFence,
    required this.pendingFence,
    required this.credentialOwner,
    required this.cleanupTargets,
    this.credentialOwnerIdentity,
    this.preferActiveOwner = false,
    this.retryActivation = false,
  });

  final MaasoEnvironment environment;
  final AuthLogoutPendingSnapshot? priorFence;
  final AuthLogoutPendingSnapshot? pendingFence;
  final MaasoAuthSession? credentialOwner;
  final _CredentialCleanupTargets? cleanupTargets;
  final _CredentialRecordIdentity? credentialOwnerIdentity;
  final bool preferActiveOwner;
  final bool retryActivation;
}

class _CredentialCleanupTargets {
  const _CredentialCleanupTargets({
    this.scoped,
    this.active,
    this.fenceOwnerFingerprint,
  });

  final _CredentialRecordCleanupTarget? scoped;
  final _CredentialRecordCleanupTarget? active;
  final String? fenceOwnerFingerprint;

  bool get isEmpty => scoped == null && active == null;
}

class _CredentialRecordCleanupTarget {
  const _CredentialRecordCleanupTarget({
    this.expectedIdentity,
    this.expectedLegacyOwner,
    this.allowUnidentifiedRecord = false,
  });

  final _CredentialRecordIdentity? expectedIdentity;
  final MaasoAuthSession? expectedLegacyOwner;
  final bool allowUnidentifiedRecord;
}

class _CommittedCredentialRecord {
  const _CommittedCredentialRecord({required this.session, this.identity});

  final MaasoAuthSession session;
  final _CredentialRecordIdentity? identity;
}

class _CredentialRecordIdentity {
  const _CredentialRecordIdentity({
    required this.environmentKey,
    required this.ownerFingerprint,
  });

  factory _CredentialRecordIdentity.fresh(MaasoEnvironment environment) {
    final random = Random.secure();
    final nonce = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '$_credentialOwnerFingerprintDomain\u0000${environment.key}'
            '\u0000$nonce',
          ),
        )
        .toString();
    return _CredentialRecordIdentity(
      environmentKey: environment.key,
      ownerFingerprint: fingerprint,
    );
  }

  final String environmentKey;
  final String ownerFingerprint;

  bool sameOwner(_CredentialRecordIdentity other) =>
      environmentKey == other.environmentKey &&
      ownerFingerprint == other.ownerFingerprint;

  String encode() {
    final body = <String, Object>{
      'environment': environmentKey,
      'owner': ownerFingerprint,
      'schema': _credentialRecordIdentitySchema,
    };
    return jsonEncode(<String, Object>{
      ...body,
      'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
    });
  }

  static _CredentialRecordIdentity? tryParse(String? encoded) {
    if (encoded == null || encoded.length > 1024) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != _credentialRecordIdentitySchema ||
          decoded['environment'] is! String ||
          (decoded['environment'] as String).trim().isEmpty ||
          decoded['owner'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(decoded['owner'] as String) ||
          decoded['checksum'] is! String) {
        return null;
      }
      final body = <String, Object>{
        'environment': decoded['environment'] as String,
        'owner': decoded['owner'] as String,
        'schema': _credentialRecordIdentitySchema,
      };
      final expected = sha256.convert(utf8.encode(jsonEncode(body))).toString();
      if (decoded['checksum'] != expected) return null;
      return _CredentialRecordIdentity(
        environmentKey: decoded['environment'] as String,
        ownerFingerprint: decoded['owner'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

class _CredentialFenceAndRecordFailure implements Exception {
  const _CredentialFenceAndRecordFailure({
    required this.fenceError,
    required this.recordError,
    required this.recordStackTrace,
  });

  final Object fenceError;
  final Object recordError;
  final StackTrace recordStackTrace;

  @override
  String toString() =>
      'Credential fence and secure-record cleanup both failed: '
      '$fenceError; $recordError';
}

class _SessionRecordKeys {
  const _SessionRecordKeys({
    required this.namespace,
    required this.accessToken,
    required this.refreshToken,
    required this.accountUuid,
    required this.expiresAt,
    required this.owner,
    required this.commit,
  });

  factory _SessionRecordKeys.active() => const _SessionRecordKeys(
    namespace: 'active',
    accessToken: GlobalConstant.keyMaasoAccessToken,
    refreshToken: GlobalConstant.keyMaasoRefreshToken,
    accountUuid: GlobalConstant.keyMaasoAccountUuid,
    expiresAt: GlobalConstant.keyMaasoAccessTokenExpiresAt,
    owner: _sessionOwnerKey,
    commit: _sessionCommitKey,
  );

  factory _SessionRecordKeys.scoped(MaasoEnvironment environment) {
    String scoped(String key) => '${key}_${environment.key}';
    return _SessionRecordKeys(
      namespace: 'environment:${environment.key}',
      accessToken: scoped(GlobalConstant.keyMaasoAccessToken),
      refreshToken: scoped(GlobalConstant.keyMaasoRefreshToken),
      accountUuid: scoped(GlobalConstant.keyMaasoAccountUuid),
      expiresAt: scoped(GlobalConstant.keyMaasoAccessTokenExpiresAt),
      owner: scoped(_sessionOwnerKey),
      commit: scoped(_sessionCommitKey),
    );
  }

  final String namespace;
  final String accessToken;
  final String refreshToken;
  final String accountUuid;
  final String expiresAt;
  final String owner;
  final String commit;

  List<String> get secretPayloadKeys => <String>[
    accessToken,
    refreshToken,
    accountUuid,
    expiresAt,
  ];

  List<String> get payloadKeys => <String>[...secretPayloadKeys, owner];
}
