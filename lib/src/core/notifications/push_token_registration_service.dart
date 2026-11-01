import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_bootstrap_service.dart';
import 'notification_preferences_service.dart';

// Keep revisions exactly representable in JSON on every Flutter target.
const int _maxPushTokenBindingRevision = 0x1fffffffffffff;
const int _maxPushTokenResponseBytes = 16 * 1024;

DateTime? _strictUtcTimestamp(Object? source) {
  if (source is! String ||
      source != source.trim() ||
      source.length > 40 ||
      !source.endsWith('Z')) {
    return null;
  }
  final parsed = DateTime.tryParse(source);
  return parsed != null && parsed.isUtc ? parsed : null;
}

class PushTokenBinding {
  PushTokenBinding({
    required this.firebaseProjectId,
    required this.token,
    required this.accountUuid,
    required this.environmentKey,
    required this.installationId,
    required this.platform,
    required this.baseUri,
    required this.bindingRevision,
    String? tokenSha256,
  }) : tokenSha256 =
           tokenSha256 ?? sha256.convert(utf8.encode(token)).toString();

  final String firebaseProjectId;
  final String token;
  final String tokenSha256;
  final String accountUuid;
  final String environmentKey;
  final String installationId;
  final String platform;
  final Uri baseUri;
  final int bindingRevision;

  Map<String, Object?> toJson() => <String, Object?>{
    'firebaseProjectId': firebaseProjectId,
    'token': token,
    'tokenSha256': tokenSha256,
    'accountUuid': accountUuid,
    'environmentKey': environmentKey,
    'installationId': installationId,
    'platform': platform,
    'bindingRevision': bindingRevision,
  };

  /// Revocation is conditional and never needs the raw FCM registration token.
  ///
  /// The backend contract is intentionally strict: the row is uniquely owned
  /// by (firebaseProjectId, environmentKey, installationId), upsert atomically
  /// transfers that row to the authenticated account at the greatest
  /// bindingRevision, revoke only removes the expected account/revision/hash,
  /// records a revision tombstone, and inactive rows/tombstones expire by TTL.
  /// This prevents a late timed-out request from reviving or deleting a newer
  /// installation binding.
  Map<String, Object?> toRemovalJson() => <String, Object?>{
    'firebaseProjectId': firebaseProjectId,
    'tokenSha256': tokenSha256,
    'accountUuid': accountUuid,
    'environmentKey': environmentKey,
    'bindingRevision': bindingRevision,
  };

  Map<String, Object?> toPersistentJson() => <String, Object?>{
    'firebaseProjectId': firebaseProjectId,
    'tokenSha256': tokenSha256,
    'accountUuid': accountUuid,
    'environmentKey': environmentKey,
    'installationId': installationId,
    'platform': platform,
    'bindingRevision': bindingRevision,
  };

  bool sameRegistration(PushTokenBinding other) =>
      firebaseProjectId == other.firebaseProjectId &&
      tokenSha256 == other.tokenSha256 &&
      accountUuid == other.accountUuid &&
      environmentKey == other.environmentKey &&
      installationId == other.installationId &&
      platform == other.platform &&
      baseUri == other.baseUri;

  bool sameServerScope(PushTokenBinding other) =>
      firebaseProjectId == other.firebaseProjectId &&
      environmentKey == other.environmentKey &&
      installationId == other.installationId &&
      baseUri == other.baseUri;

  String get revocationKey =>
      '$firebaseProjectId|$environmentKey|$installationId|$accountUuid|'
      '$bindingRevision|$tokenSha256';

  static PushTokenBinding? fromPersistentJson(
    Object? source, {
    required String expectedInstallationId,
  }) {
    if (source is! Map) return null;
    final json = source.cast<Object?, Object?>();
    final firebaseProjectId = json['firebaseProjectId']?.toString() ?? '';
    final tokenSha256 = json['tokenSha256']?.toString() ?? '';
    final accountUuid = json['accountUuid']?.toString().trim() ?? '';
    final environmentKey = json['environmentKey']?.toString() ?? '';
    final installationId = json['installationId']?.toString() ?? '';
    final platform = json['platform']?.toString() ?? '';
    final revisionValue = json['bindingRevision'];
    final bindingRevision = revisionValue is num
        ? revisionValue.toInt()
        : int.tryParse('$revisionValue');
    MaasoEnvironment? environment;
    for (final candidate in MaasoEnvironment.values) {
      if (candidate.key == environmentKey) environment = candidate;
    }
    if (firebaseProjectId != FirebaseProjectContract.projectId ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(tokenSha256) ||
        accountUuid.isEmpty ||
        environment == null ||
        installationId != expectedInstallationId ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,24}$').hasMatch(platform) ||
        bindingRevision == null ||
        bindingRevision <= 0 ||
        bindingRevision > _maxPushTokenBindingRevision) {
      return null;
    }
    return PushTokenBinding(
      firebaseProjectId: firebaseProjectId,
      token: '',
      tokenSha256: tokenSha256,
      accountUuid: accountUuid,
      environmentKey: environmentKey,
      installationId: installationId,
      platform: platform,
      baseUri: Uri.parse('${environment.baseUrl}/'),
      bindingRevision: bindingRevision,
    );
  }
}

abstract interface class PushTokenRegistrar {
  Future<PushTokenBindingLease> upsert(
    PushTokenBinding binding, {
    required String accessToken,
  });

  Future<void> remove(PushTokenBinding binding, {required String accessToken});
}

class PushTokenBindingLease {
  const PushTokenBindingLease({required this.expiresAt});

  final DateTime expiresAt;
}

/// A recoverable server conflict that proves the same scoped registration was
/// tombstoned only because its TTL elapsed. Generic conflicts, explicit
/// revocations, and other account/token scopes never carry this hint.
class PushTokenRevisionConflict implements Exception {
  const PushTokenRevisionConflict(this.minimumBindingRevision);

  final int minimumBindingRevision;
}

class _PushTokenOperationException implements Exception {
  const _PushTokenOperationException(this.reason);

  final String reason;
}

class _PushTokenHttpResponse {
  const _PushTokenHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
  });

  final int statusCode;
  final List<int> bodyBytes;
}

class HttpPushTokenRegistrar implements PushTokenRegistrar {
  HttpPushTokenRegistrar({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  @override
  Future<PushTokenBindingLease> upsert(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    if (binding.token.trim().isEmpty) {
      throw const _PushTokenOperationException(
        'push token upsert requires a token',
      );
    }
    final response = await _send(
      action: 'bind',
      binding: binding,
      accessToken: accessToken,
      body: binding.toJson(),
    );
    if (response.statusCode == 409) {
      final minimum = _minimumBindingRevision(response, binding);
      if (minimum != null) throw PushTokenRevisionConflict(minimum);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _PushTokenOperationException(
        'push token upsert failed: HTTP ${response.statusCode}',
      );
    }
    final lease = _bindingLease(response, binding);
    if (lease == null) {
      throw const _PushTokenOperationException(
        'push token upsert response is invalid',
      );
    }
    return lease;
  }

  @override
  Future<void> remove(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    final response = await _send(
      action: 'revoke',
      binding: binding,
      accessToken: accessToken,
      body: binding.toRemovalJson(),
    );
    if ((response.statusCode < 200 || response.statusCode >= 300) &&
        response.statusCode != 404) {
      throw _PushTokenOperationException(
        'push token removal failed: HTTP ${response.statusCode}',
      );
    }
  }

  Future<_PushTokenHttpResponse> _send({
    required String action,
    required PushTokenBinding binding,
    required String accessToken,
    required Map<String, Object?> body,
  }) async {
    final credential = accessToken.trim();
    if (credential.isEmpty) {
      throw const _PushTokenOperationException(
        'push token request requires authentication',
      );
    }
    final uri = _endpoint(binding, action);
    final request = http.Request('POST', uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $credential',
        'Content-Type': 'application/json; charset=utf-8',
      })
      ..body = jsonEncode(body);
    final response = await _client.send(request).timeout(requestTimeout);
    final bodyBytes = await _readResponseBytes(
      response,
    ).timeout(requestTimeout);
    return _PushTokenHttpResponse(
      statusCode: response.statusCode,
      bodyBytes: bodyBytes,
    );
  }

  Future<List<int>> _readResponseBytes(http.StreamedResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (chunk.length > _maxPushTokenResponseBytes - bytes.length) {
        throw const _PushTokenOperationException(
          'push token response exceeded the size limit',
        );
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  int? _minimumBindingRevision(
    _PushTokenHttpResponse response,
    PushTokenBinding binding,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['code'] != 'CONFLICT') return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final minimum = data['minimumBindingRevision'];
      if (minimum is! int ||
          minimum <= binding.bindingRevision ||
          minimum > _maxPushTokenBindingRevision) {
        return null;
      }
      return minimum;
    } catch (_) {
      return null;
    }
  }

  PushTokenBindingLease? _bindingLease(
    _PushTokenHttpResponse response,
    PushTokenBinding binding,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['code'] != 'OK') return null;
      final data = decoded['data'];
      if (data is! Map ||
          data['accepted'] != true ||
          data['bindingRevision'] != binding.bindingRevision) {
        return null;
      }
      final expiresAt = _strictUtcTimestamp(data['expiresAt']);
      if (expiresAt == null) return null;
      return PushTokenBindingLease(expiresAt: expiresAt);
    } catch (_) {
      return null;
    }
  }

  Uri _endpoint(PushTokenBinding binding, String action) {
    final baseUri = binding.baseUri;
    if (baseUri.scheme != 'https' || baseUri.host.isEmpty) {
      throw const _PushTokenOperationException(
        'push token endpoint must use HTTPS',
      );
    }
    return baseUri.resolve(
      'v1/notifications/push-tokens/'
      '${Uri.encodeComponent(binding.installationId)}/$action',
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

class _PendingPushTokenRevocation {
  const _PendingPushTokenRevocation({
    required this.binding,
    required this.recordedAt,
  });

  final PushTokenBinding binding;
  final DateTime recordedAt;

  Map<String, Object?> toPersistentJson() => <String, Object?>{
    'binding': binding.toPersistentJson(),
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };
}

class _PushScopeSnapshot {
  const _PushScopeSnapshot({
    required this.generation,
    required this.session,
    required this.environment,
    required this.preferences,
  });

  final int generation;
  final MaasoAuthSession? session;
  final MaasoEnvironment environment;
  final NotificationPreferences preferences;

  bool get hasValidSession =>
      session != null &&
      session!.isValid &&
      session!.accountUuid.trim().isNotEmpty;
}

/// Binds an FCM installation to the currently authenticated account and API
/// environment. It observes AuthSessionService; it never mutates that service.
class PushTokenRegistrationService extends AppService {
  PushTokenRegistrationService({
    required FirebaseMessagingGateway messaging,
    required NotificationPreferencesService preferences,
    AppReactiveValue<MaasoAuthSession?>? session,
    AppReactiveValue<MaasoEnvironment>? environmentSignal,
    AuthSessionService? auth,
    AppEnvironmentService? environment,
    AppInstallationIdentityService? installationIdentity,
    PushTokenRegistrar? registrar,
    SharedPreferences? sharedPreferences,
    Future<bool> Function(String key, String value)? bindingStateWriter,
    this.operationTimeout = const Duration(seconds: 10),
    this.apnsWaitTimeout = const Duration(seconds: 5),
    this.apnsPollInterval = const Duration(milliseconds: 250),
    this.retryBaseDelay = const Duration(seconds: 5),
    this.maxRetryAttempts = 2,
    this.bindingRenewalLeadTime = const Duration(days: 7),
    this.bindingRenewalJitterWindow = const Duration(days: 1),
    this.bindingRenewalRetryDelay = const Duration(hours: 6),
    String? platformOverride,
    DateTime Function()? clock,
  }) : _messaging = messaging,
       _preferences = preferences,
       _session =
           session ?? (auth ?? appServices.find<AuthSessionService>()).session,
       _environmentSignal =
           environmentSignal ??
           (environment ?? appServices.find<AppEnvironmentService>())
               .environment,
       _installationIdentity = installationIdentity,
       _registrar = registrar ?? HttpPushTokenRegistrar(),
       _sharedPreferences = sharedPreferences,
       _bindingStateWriter = bindingStateWriter,
       _platform =
           platformOverride ?? (kIsWeb ? 'web' : defaultTargetPlatform.name),
       _clock = clock ?? DateTime.now;

  static const _bindingStateKey = 'maaso.notification.push-binding.v1';
  static const _pendingRetention = Duration(days: 35);
  static const _maxPendingRevocations = 8;
  static const _maximumBindingLease = Duration(days: 36);
  static const _bindingRenewalExpiryGuard = Duration(hours: 1);

  final FirebaseMessagingGateway _messaging;
  final NotificationPreferencesService _preferences;
  final AppReactiveValue<MaasoAuthSession?> _session;
  final AppReactiveValue<MaasoEnvironment> _environmentSignal;
  AppInstallationIdentityService? _installationIdentity;
  final PushTokenRegistrar _registrar;
  final Duration operationTimeout;
  final Duration apnsWaitTimeout;
  final Duration apnsPollInterval;
  final Duration retryBaseDelay;
  final int maxRetryAttempts;
  final Duration bindingRenewalLeadTime;
  final Duration bindingRenewalJitterWindow;
  final Duration bindingRenewalRetryDelay;
  final String _platform;
  final DateTime Function() _clock;
  final Future<bool> Function(String key, String value)? _bindingStateWriter;
  SharedPreferences? _sharedPreferences;

  final isRegistered = false.obs;
  final error = RxnString();

  Worker? _sessionWorker;
  Worker? _environmentWorker;
  Worker? _preferenceWorker;
  StreamSubscription<String>? _tokenSubscription;
  Timer? _retryTimer;
  Timer? _apnsCleanupRetryTimer;
  Timer? _bindingRenewalTimer;
  String? _installationId;
  String? _token;
  PushTokenBinding? _activeBinding;
  DateTime? _activeLeaseExpiresAt;
  String? _renewalAttemptKey;
  final List<_PendingPushTokenRevocation> _pendingRevocations =
      <_PendingPushTokenRevocation>[];
  final Set<Future<void>> _admittedOperations = <Future<void>>{};
  String? _lastAccessToken;
  Future<void>? _syncFuture;
  Future<void>? _accountDrainFuture;
  bool _syncAgain = false;
  bool _awaitingSessionForEnvironment = false;
  bool _bindingConfirmedThisRun = false;
  bool _tokenNeedsRotation = false;
  bool _messagingDeactivated = false;
  bool _bindingStateUntrusted = true;
  bool _localTokenCleanupRequired = true;
  bool _accountActive = false;
  bool _accountActivationCleanupPending = false;
  bool _forceFreshTokenRead = false;
  bool _accountDrainRequired = false;
  bool _accountDrainInProgress = false;
  bool _closed = false;
  int _scopeGeneration = 0;
  int _lastIssuedRevision = 0;
  int _retryAttempts = 0;
  String? _observedAccountUuid;
  MaasoEnvironment? _observedEnvironment;

  Future<PushTokenRegistrationService> init() async {
    _sharedPreferences ??= await SharedPreferences.getInstance();
    final preferences = _sharedPreferences;
    if (preferences == null) {
      throw const _PushTokenOperationException(
        'push token preferences are unavailable',
      );
    }
    final identity =
        await (_installationIdentity ??= AppInstallationIdentityService(
          sharedPreferences: preferences,
        )).init();
    _installationId = identity.installationId;
    await _restoreBindingState();
    _observedAccountUuid = _validAccountUuid(_session.value);
    _observedEnvironment = _environmentSignal.value;
    // Tests and embedders may construct this service after publishing a
    // session. Production starts signed out and explicitly activates only
    // after the account teardown gate has admitted a new mount.
    _accountActive = _observedAccountUuid != null;
    final restored = _activeBinding;
    if (restored != null &&
        (restored.accountUuid != _observedAccountUuid ||
            restored.environmentKey != _observedEnvironment?.key)) {
      _tokenNeedsRotation = true;
    }
    _sessionWorker = _session.listen(_handleSessionChanged);
    _environmentWorker = _environmentSignal.listen(_handleEnvironmentChanged);
    _preferenceWorker = _preferences.state.listen((_) {
      _cancelBindingRenewal();
      _scopeGeneration++;
      unawaited(sync());
    });
    _listenForTokenRefreshes();
    // Token generation and registration remain off the first-frame path.
    unawaited(sync());
    return this;
  }

  /// Opens push-token admission for a newly mounted account.
  ///
  /// A prior account's strict drain, including every real Firebase platform
  /// operation hidden behind a timed wrapper, must settle before this method
  /// succeeds. The one exception is Apple's explicit APNs-token-not-ready
  /// prerequisite: messaging stays disabled, cleanup remains journaled, and
  /// registration is gated until APNs becomes ready. Callers must await this
  /// method before publishing the new session.
  Future<void> activateAccount({
    required String environmentKey,
    required String accountUuid,
  }) async {
    if (_closed) {
      throw StateError('Push token registration service is closed.');
    }
    _cancelApnsCleanupRetry();
    final drain = _accountDrainFuture;
    if (drain != null) await drain;
    if (_accountDrainRequired || _accountDrainInProgress) {
      throw StateError(
        'Push token registration cannot activate before account cleanup.',
      );
    }
    final syncFuture = _syncFuture;
    if (syncFuture != null) await syncFuture;
    await _waitForAdmittedOperations();
    final normalizedAccountUuid = accountUuid.trim();
    final normalizedEnvironmentKey = environmentKey.trim();
    if (normalizedAccountUuid.isEmpty ||
        normalizedEnvironmentKey != _environmentSignal.value.key) {
      throw StateError('Push token activation scope is invalid.');
    }
    final localTokenBaselineReady = await _prepareBindingStateForActivation(
      environmentKey: normalizedEnvironmentKey,
      accountUuid: normalizedAccountUuid,
    );
    if (_accountDrainRequired || _accountDrainInProgress) {
      throw StateError(
        'Push token registration account cleanup is incomplete.',
      );
    }
    if (localTokenBaselineReady) _listenForTokenRefreshes();
    _accountActive = true;
    _accountActivationCleanupPending = !localTokenBaselineReady;
    _accountDrainFuture = null;
    _observedAccountUuid = normalizedAccountUuid;
    _observedEnvironment = _environmentSignal.value;
    _awaitingSessionForEnvironment = false;
    _tokenNeedsRotation = false;
    _retryAttempts = 0;
    _scopeGeneration++;
    if (!localTokenBaselineReady) _scheduleApnsCleanupRetry();
  }

  /// Fences the old account and strictly disables its local FCM identity.
  /// If Apple has not delivered an APNs token yet, the pending local deletion
  /// is journaled and every later registration remains blocked until it runs.
  ///
  /// The returned Future is shared by concurrent callers. A failed attempt is
  /// retryable, but activation remains blocked until a later attempt succeeds.
  Future<void> deactivateAccountAndDrain() {
    if (_closed) return Future<void>.value();
    final existing = _accountDrainFuture;
    if (existing != null) return existing;

    _accountActive = false;
    _accountActivationCleanupPending = false;
    _forceFreshTokenRead = true;
    _accountDrainRequired = true;
    _accountDrainInProgress = true;
    _scopeGeneration++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempts = 0;
    _cancelApnsCleanupRetry();
    _cancelBindingRenewal();
    final activeAtFence = _activeBinding;
    final transientAccessToken = _lastAccessToken;
    _lastAccessToken = null;
    _localTokenCleanupRequired = true;

    final next = _deactivateAccountOnce(
      activeAtFence: activeAtFence,
      transientAccessToken: transientAccessToken,
    );
    _accountDrainFuture = next;
    return next;
  }

  Future<void> _deactivateAccountOnce({
    required PushTokenBinding? activeAtFence,
    required String? transientAccessToken,
  }) async {
    var completed = false;
    try {
      // Cancel the old subscription before draining sync so a queued A token
      // refresh cannot be observed by the subscription later installed for B.
      await _cancelTokenRefreshSubscription();
      final syncFuture = _syncFuture;
      if (syncFuture != null) await syncFuture;
      // `.timeout` does not cancel the underlying FlutterFire Future. Wait for
      // those real operations before issuing the final disable/delete pair.
      await _waitForAdmittedOperations();

      Object? firstError;
      StackTrace? firstStackTrace;
      try {
        await _retireActiveBinding(
          _snapshot(),
          accessToken: transientAccessToken,
          requirePersistence: true,
        );
        if (activeAtFence != null &&
            _pendingRevocations.any(
              (entry) =>
                  entry.binding.revocationKey == activeAtFence.revocationKey,
            )) {
          await _tryRemovePending(
            activeAtFence,
            _snapshot(),
            accessToken: transientAccessToken,
          );
        }
        // Even if an earlier best-effort sync already moved the binding into
        // memory, the exact no-secret revoke receipt must be durable before B.
        if (!await _persistBindingState()) {
          throw const _PushTokenOperationException(
            'push token revocation receipt was not persisted',
          );
        }
      } catch (exception, stackTrace) {
        firstError = exception;
        firstStackTrace = stackTrace;
      }

      var localCleanupSucceeded = false;
      try {
        localCleanupSucceeded = await _strictDisableAndDeleteToken();
      } catch (exception, stackTrace) {
        firstError ??= exception;
        firstStackTrace ??= stackTrace;
      }
      if (localCleanupSucceeded) {
        _localTokenCleanupRequired = false;
        try {
          if (!await _persistBindingState()) {
            throw const _PushTokenOperationException(
              'push token cleanup proof was not persisted',
            );
          }
        } catch (exception, stackTrace) {
          _localTokenCleanupRequired = true;
          firstError ??= exception;
          firstStackTrace ??= stackTrace;
        }
      } else {
        _localTokenCleanupRequired = true;
        _defer(
          'delete local FCM token',
          const FirebaseMessagingApnsTokenUnavailable(),
        );
        try {
          if (!await _persistBindingState()) {
            throw const _PushTokenOperationException(
              'pending push token cleanup was not persisted',
            );
          }
        } catch (exception, stackTrace) {
          firstError ??= exception;
          firstStackTrace ??= stackTrace;
        }
      }
      isRegistered.value = false;
      _bindingConfirmedThisRun = false;
      _lastAccessToken = null;
      await _waitForAdmittedOperations();
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
      _accountDrainRequired = false;
      completed = true;
    } finally {
      _lastAccessToken = null;
      _accountDrainInProgress = false;
      if (!completed) _accountDrainFuture = null;
    }
  }

  void _listenForTokenRefreshes() {
    if (_closed || _tokenSubscription != null) return;
    try {
      _tokenSubscription = _messaging.tokenRefreshes.listen(
        (token) {
          final normalized = token.trim();
          if (normalized.isEmpty) return;
          _cancelBindingRenewal();
          _scopeGeneration++;
          if (_accountActive && !_forceFreshTokenRead) {
            _token = normalized;
          }
          unawaited(sync());
        },
        onError: (Object exception, StackTrace stackTrace) {
          _defer('FCM token refresh stream', exception);
        },
      );
    } catch (exception) {
      _defer('FCM token refresh subscription', exception);
      rethrow;
    }
  }

  Future<void> _cancelTokenRefreshSubscription() async {
    final subscription = _tokenSubscription;
    if (subscription == null) return;
    await subscription.cancel();
    if (identical(_tokenSubscription, subscription)) {
      _tokenSubscription = null;
    }
  }

  Future<T> _trackAdmittedOperation<T>(Future<T> Function() start) {
    final operation = start();
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _admittedOperations.remove(tracked));
    _admittedOperations.add(tracked);
    return operation;
  }

  Future<void> _waitForAdmittedOperations() async {
    while (_admittedOperations.isNotEmpty) {
      await Future.wait<void>(_admittedOperations.toList(growable: false));
    }
  }

  Future<bool> _strictDisableAndDeleteToken() async {
    _forceFreshTokenRead = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await _trackAdmittedOperation(() => _messaging.setAutoInitEnabled(false));
    } catch (exception, stackTrace) {
      firstError = exception;
      firstStackTrace = stackTrace;
    }
    try {
      await _trackAdmittedOperation(_messaging.deleteToken);
      _token = null;
    } on FirebaseMessagingApnsTokenUnavailable {
      // Keep push fail-closed without blocking authentication. No token may be
      // read or registered for the next account until a later cleanup succeeds.
      _token = null;
      _messagingDeactivated = false;
      _localTokenCleanupRequired = true;
      if (firstError == null) return false;
    } catch (exception, stackTrace) {
      firstError ??= exception;
      firstStackTrace ??= stackTrace;
    }
    _messagingDeactivated = firstError == null;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
    return true;
  }

  Future<bool> _prepareBindingStateForActivation({
    required String environmentKey,
    required String accountUuid,
  }) async {
    final active = _activeBinding;
    final scopeMismatch =
        active != null &&
        (active.accountUuid != accountUuid ||
            active.environmentKey != environmentKey);
    if (!_bindingStateUntrusted &&
        !_localTokenCleanupRequired &&
        !scopeMismatch) {
      return true;
    }
    // Missing or corrupt local authority cannot prove which account owns the
    // current FCM token. Delete it strictly before enabling registration, then
    // persist an empty trusted baseline. A normal failure keeps activation
    // retryable; Apple's APNs-not-ready prerequisite leaves registration gated
    // while allowing the unrelated account runtime to finish mounting.
    if (scopeMismatch) {
      await _retireActiveBinding(_snapshot(), requirePersistence: true);
    }
    await _cancelTokenRefreshSubscription();
    final localCleanupSucceeded = await _strictDisableAndDeleteToken();
    await _waitForAdmittedOperations();
    if (!localCleanupSucceeded) {
      _localTokenCleanupRequired = true;
      if (!await _persistBindingState()) {
        throw const _PushTokenOperationException(
          'pending push token cleanup was not persisted',
        );
      }
      _defer(
        'delete local FCM token',
        const FirebaseMessagingApnsTokenUnavailable(),
      );
      return false;
    }
    _localTokenCleanupRequired = false;
    if (!await _persistBindingState()) {
      _localTokenCleanupRequired = true;
      throw const _PushTokenOperationException(
        'push token trusted baseline was not persisted',
      );
    }
    _bindingStateUntrusted = false;
    return true;
  }

  void _handleSessionChanged(MaasoAuthSession? next) {
    if (!identical(next, _session.value)) return;
    _cancelBindingRenewal();
    final nextAccount = _validAccountUuid(next);
    if (_observedAccountUuid != nextAccount) _tokenNeedsRotation = true;
    _observedAccountUuid = nextAccount;
    _awaitingSessionForEnvironment = false;
    _scopeGeneration++;
    unawaited(sync());
  }

  void _handleEnvironmentChanged(MaasoEnvironment next) {
    if (next != _environmentSignal.value) return;
    _cancelBindingRenewal();
    if (_observedEnvironment != next) _tokenNeedsRotation = true;
    _observedEnvironment = next;
    // AppEnvironmentService changes before AuthSessionService finishes
    // activating the newly scoped session. Never bind the previous session.
    _awaitingSessionForEnvironment = true;
    _scopeGeneration++;
    unawaited(sync());
  }

  Future<void> sync() {
    if (_closed) return Future<void>.value();
    if (_accountDrainInProgress) {
      return _accountDrainFuture ?? Future<void>.value();
    }
    final inFlight = _syncFuture;
    if (inFlight != null) {
      _syncAgain = true;
      return inFlight;
    }

    final next = _drainSyncQueue();
    _syncFuture = next;
    return next;
  }

  Future<void> _drainSyncQueue() async {
    try {
      do {
        _syncAgain = false;
        try {
          await _performSync();
        } catch (exception) {
          _defer('push token sync', exception);
        }
      } while (_syncAgain && !_closed);
    } finally {
      _syncFuture = null;
    }
  }

  Future<void> _performSync() async {
    final snapshot = _snapshot();
    if (!_accountActive ||
        _awaitingSessionForEnvironment ||
        !snapshot.preferences.canNotify ||
        !snapshot.hasValidSession) {
      await _deactivate(snapshot);
      return;
    }

    if (_accountActivationCleanupPending) {
      if (_requiresApnsToken && !await _waitForApnsToken(snapshot)) return;
      if (!_isCurrent(snapshot)) return;
      final localTokenBaselineReady = await _prepareBindingStateForActivation(
        environmentKey: snapshot.environment.key,
        accountUuid: snapshot.session!.accountUuid.trim(),
      );
      if (!_isCurrent(snapshot) || !localTokenBaselineReady) return;
      _accountActivationCleanupPending = false;
      _cancelApnsCleanupRetry();
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryAttempts = 0;
    }

    if (_tokenNeedsRotation) {
      await _retireActiveBinding(snapshot);
      if (!_isCurrent(snapshot)) return;
      final rotated = await _disableAndDeleteToken(snapshot);
      if (!_isCurrent(snapshot) || !rotated) return;
      _tokenNeedsRotation = false;
    }

    try {
      await _trackAdmittedOperation(
        () => _messaging.setAutoInitEnabled(true),
      ).timeout(operationTimeout);
    } catch (exception) {
      _defer('enable Firebase Messaging auto-init', exception);
      return;
    }
    if (!_isCurrent(snapshot)) return;
    _messagingDeactivated = false;

    if (_requiresApnsToken && !await _waitForApnsToken(snapshot)) return;
    if (!_isCurrent(snapshot)) return;

    String? token;
    try {
      final cachedToken = _forceFreshTokenRead ? null : _token;
      token =
          (cachedToken ??
                  await _trackAdmittedOperation(
                    _messaging.getToken,
                  ).timeout(operationTimeout))
              ?.trim();
    } catch (exception) {
      _defer('read FCM token', exception);
      return;
    }
    if (!_isCurrent(snapshot) || token == null || token.isEmpty) {
      if (token == null || token.isEmpty) {
        _defer(
          'read FCM token',
          const _PushTokenOperationException('FCM token unavailable'),
        );
      }
      return;
    }
    _token = token;
    _forceFreshTokenRead = false;
    _listenForTokenRefreshes();

    final probe = PushTokenBinding(
      firebaseProjectId: FirebaseProjectContract.projectId,
      token: token,
      accountUuid: snapshot.session!.accountUuid.trim(),
      environmentKey: snapshot.environment.key,
      installationId: _installationId!,
      platform: _platform,
      baseUri: Uri.parse('${snapshot.environment.baseUrl}/'),
      bindingRevision: 1,
    );
    if (_activeBinding?.sameRegistration(probe) == true) {
      await _tryPendingRevocations(snapshot, current: probe);
      if (!_isCurrent(snapshot)) return;
      if (_bindingConfirmedThisRun &&
          _lastAccessToken == snapshot.session!.accessToken) {
        final leaseExpiresAt = _activeLeaseExpiresAt;
        if (leaseExpiresAt != null) {
          final renewalDelay = _bindingRenewalDelay(probe, leaseExpiresAt);
          if (renewalDelay != null) {
            _scheduleBindingRenewal(probe, leaseExpiresAt, renewalDelay);
            _markSuccess(snapshot);
            return;
          }
        }
        _bindingConfirmedThisRun = false;
      }
    } else {
      await _retireActiveBinding(snapshot);
      if (!_isCurrent(snapshot)) return;
      await _tryPendingRevocations(snapshot, current: probe);
      if (!_isCurrent(snapshot)) return;
    }

    var binding = await _bindingForUpsert(probe);
    if (!_isCurrent(snapshot)) return;
    late PushTokenBindingLease lease;
    late Duration renewalDelay;
    try {
      try {
        lease = await _trackAdmittedOperation(
          () => _registrar.upsert(
            binding,
            accessToken: snapshot.session!.accessToken,
          ),
        ).timeout(operationTimeout);
      } on PushTokenRevisionConflict catch (conflict) {
        final minimum = conflict.minimumBindingRevision;
        if (!_isCurrent(snapshot) ||
            minimum <= binding.bindingRevision ||
            minimum > _maxPushTokenBindingRevision) {
          rethrow;
        }
        // Only the authenticated backend can issue this exact-scope TTL hint.
        // Persist the high-water mark before the one allowed retry so a timeout
        // or cold restart reuses this revision instead of minting repeatedly.
        _lastIssuedRevision = max(_lastIssuedRevision, minimum);
        binding = _bindingAtRevision(binding, minimum);
        if (!await _persistBindingState()) {
          throw const _PushTokenOperationException(
            'push token revision high-water was not persisted',
          );
        }
        if (!_isCurrent(snapshot)) {
          isRegistered.value = false;
          return;
        }
        lease = await _trackAdmittedOperation(
          () => _registrar.upsert(
            binding,
            accessToken: snapshot.session!.accessToken,
          ),
        ).timeout(operationTimeout);
      }
      final candidateRenewalDelay = _bindingRenewalDelay(
        binding,
        lease.expiresAt,
      );
      if (candidateRenewalDelay == null) {
        throw const _PushTokenOperationException(
          'push token binding lease is invalid',
        );
      }
      renewalDelay = candidateRenewalDelay;
    } catch (exception) {
      final wasLeaseRenewal =
          _renewalAttemptKey == binding.revocationKey &&
          _activeBinding?.revocationKey == binding.revocationKey;
      _addPending(binding);
      await _persistBindingState();
      _defer('push token upsert', exception);
      if (wasLeaseRenewal) _scheduleBindingRenewalRetry(binding);
      return;
    }
    if (!_isCurrent(snapshot)) {
      // The request may have committed after its owning account/environment
      // changed. Preserve a conditional revocation receipt; the next scoped
      // sync rotates the local FCM token before registering again.
      _addPending(binding);
      await _persistBindingState();
      isRegistered.value = false;
      return;
    }

    _activeBinding = binding;
    _activeLeaseExpiresAt = lease.expiresAt;
    _lastAccessToken = snapshot.session!.accessToken;
    _bindingConfirmedThisRun = true;
    _localTokenCleanupRequired = false;
    _pendingRevocations.removeWhere(
      (pending) =>
          pending.binding.sameServerScope(binding) &&
          pending.binding.bindingRevision <= binding.bindingRevision,
    );
    if (!await _persistBindingState()) {
      _bindingConfirmedThisRun = false;
      _defer(
        'persist push token binding lease',
        const _PushTokenOperationException('binding lease was not persisted'),
      );
      return;
    }
    _scheduleBindingRenewal(binding, lease.expiresAt, renewalDelay);
    _markSuccess(snapshot);
  }

  Future<void> _deactivate(_PushScopeSnapshot snapshot) async {
    _cancelBindingRenewal();
    final hadActiveBinding = _activeBinding != null;
    await _retireActiveBinding(snapshot);
    if (!_isCurrent(snapshot)) return;
    // A failed first revoke moves the binding into the durable pending list.
    // On later deactivation syncs there is no active binding left, so explicitly
    // drain that list while the former account credential is still available.
    if (!hadActiveBinding) {
      await _tryPendingRevocations(snapshot);
      if (!_isCurrent(snapshot)) return;
    }
    final deactivated = await _disableAndDeleteToken(snapshot);
    if (!_isCurrent(snapshot)) return;
    isRegistered.value = false;
    final hasRetryableRevocation = _hasRetryablePendingRevocation(snapshot);
    if (deactivated && !hasRetryableRevocation) {
      _retryAttempts = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    } else if (hasRetryableRevocation) {
      // Local FCM deletion must not cancel the remote revoke retry. The pending
      // receipt stays persisted without secrets. A credential is borrowed only
      // from a currently published matching account and is never retained.
      _scheduleRetry();
    }
  }

  Future<bool> _disableAndDeleteToken(_PushScopeSnapshot snapshot) async {
    if (_messagingDeactivated && _token == null) return true;
    var success = true;
    try {
      await _trackAdmittedOperation(
        () => _messaging.setAutoInitEnabled(false),
      ).timeout(operationTimeout);
    } catch (exception) {
      success = false;
      _defer('disable Firebase Messaging auto-init', exception);
    }
    if (!_isCurrent(snapshot)) return false;
    try {
      await _trackAdmittedOperation(
        _messaging.deleteToken,
      ).timeout(operationTimeout);
      _token = null;
    } catch (exception) {
      success = false;
      _defer('delete local FCM token', exception);
    }
    if (_isCurrent(snapshot) && success) {
      _messagingDeactivated = true;
      _localTokenCleanupRequired = false;
      if (!await _persistBindingState()) {
        _localTokenCleanupRequired = true;
        success = false;
        _defer(
          'persist push token cleanup proof',
          const _PushTokenOperationException(
            'push token cleanup proof was not persisted',
          ),
        );
      }
    }
    return success;
  }

  Future<bool> _waitForApnsToken(_PushScopeSnapshot snapshot) async {
    try {
      final available = await (() async {
        while (_isCurrent(snapshot)) {
          final token = await _trackAdmittedOperation(_messaging.getAPNSToken);
          if (token?.trim().isNotEmpty == true) return true;
          await Future<void>.delayed(apnsPollInterval);
        }
        return false;
      })().timeout(apnsWaitTimeout);
      if (!available && _isCurrent(snapshot)) {
        _defer(
          'wait for APNs token',
          const _PushTokenOperationException('APNs token unavailable'),
        );
      }
      return available;
    } catch (exception) {
      if (_isCurrent(snapshot)) _defer('wait for APNs token', exception);
      return false;
    }
  }

  Future<void> _retireActiveBinding(
    _PushScopeSnapshot snapshot, {
    String? accessToken,
    bool requirePersistence = false,
  }) async {
    _cancelBindingRenewal();
    final binding = _activeBinding;
    if (binding == null) return;
    final transientCredential = accessToken ?? _lastAccessToken;
    _activeBinding = null;
    _activeLeaseExpiresAt = null;
    _lastAccessToken = null;
    _bindingConfirmedThisRun = false;
    _localTokenCleanupRequired = true;
    _addPending(binding);
    final persisted = await _persistBindingState();
    if (!persisted) {
      const failure = _PushTokenOperationException(
        'push token revocation receipt was not persisted',
      );
      if (requirePersistence) throw failure;
      _defer('persist push token revocation receipt', failure);
      return;
    }
    await _tryRemovePending(
      binding,
      snapshot,
      accessToken: transientCredential,
    );
  }

  Future<void> _tryPendingRevocations(
    _PushScopeSnapshot snapshot, {
    PushTokenBinding? current,
  }) async {
    final pending = List<_PendingPushTokenRevocation>.from(_pendingRevocations);
    for (final entry in pending) {
      if (!_isCurrent(snapshot)) return;
      final binding = entry.binding;
      if (current != null && binding.sameRegistration(current)) continue;
      await _tryRemovePending(binding, snapshot);
    }
  }

  bool _hasRetryablePendingRevocation(_PushScopeSnapshot snapshot) {
    return _pendingRevocations.any(
      (entry) => _credentialFor(entry.binding, snapshot) != null,
    );
  }

  Future<void> _tryRemovePending(
    PushTokenBinding binding,
    _PushScopeSnapshot snapshot, {
    String? accessToken,
  }) async {
    final explicitCredential = accessToken?.trim();
    final credential = explicitCredential?.isNotEmpty == true
        ? explicitCredential
        : _credentialFor(binding, snapshot);
    if (credential == null) return;
    try {
      await _trackAdmittedOperation(
        () => _registrar.remove(binding, accessToken: credential),
      ).timeout(operationTimeout);
      _pendingRevocations.removeWhere(
        (entry) => entry.binding.revocationKey == binding.revocationKey,
      );
      await _persistBindingState();
    } catch (exception) {
      _defer('push token revocation', exception);
    }
  }

  String? _credentialFor(
    PushTokenBinding binding,
    _PushScopeSnapshot snapshot,
  ) {
    final session = snapshot.session;
    if (snapshot.hasValidSession &&
        session!.accountUuid.trim() == binding.accountUuid &&
        snapshot.environment.key == binding.environmentKey) {
      return session.accessToken;
    }
    return null;
  }

  Future<PushTokenBinding> _bindingForUpsert(PushTokenBinding probe) async {
    final active = _activeBinding;
    if (active?.sameRegistration(probe) == true) {
      return _bindingAtRevision(
        probe,
        max(active!.bindingRevision, _lastIssuedRevision),
      );
    }
    final matchingPending = _pendingRevocations
        .where((entry) => entry.binding.sameRegistration(probe))
        .map((entry) => entry.binding)
        .toList();
    if (matchingPending.isNotEmpty) {
      matchingPending.sort(
        (a, b) => b.bindingRevision.compareTo(a.bindingRevision),
      );
      final previous = matchingPending.first;
      return _bindingAtRevision(
        probe,
        max(previous.bindingRevision, _lastIssuedRevision),
      );
    }
    if (_lastIssuedRevision >= _maxPushTokenBindingRevision) {
      throw const _PushTokenOperationException(
        'push token binding revision is exhausted',
      );
    }
    final previousRevision = _lastIssuedRevision;
    _lastIssuedRevision++;
    if (!await _persistBindingState()) {
      _lastIssuedRevision = previousRevision;
      throw const _PushTokenOperationException(
        'push token revision high-water was not persisted',
      );
    }
    return _bindingAtRevision(probe, _lastIssuedRevision);
  }

  PushTokenBinding _bindingAtRevision(
    PushTokenBinding source,
    int bindingRevision,
  ) => PushTokenBinding(
    firebaseProjectId: source.firebaseProjectId,
    token: source.token,
    tokenSha256: source.tokenSha256,
    accountUuid: source.accountUuid,
    environmentKey: source.environmentKey,
    installationId: source.installationId,
    platform: source.platform,
    baseUri: source.baseUri,
    bindingRevision: bindingRevision,
  );

  Duration? _bindingRenewalDelay(PushTokenBinding binding, DateTime expiresAt) {
    if (!expiresAt.isUtc ||
        bindingRenewalLeadTime.inMilliseconds <= 0 ||
        bindingRenewalJitterWindow.inMilliseconds < 0) {
      return null;
    }
    final now = _clock().toUtc();
    if (!expiresAt.isAfter(now) ||
        expiresAt.isAfter(now.add(_maximumBindingLease))) {
      return null;
    }
    final jitter = _deterministicRenewalJitter(binding);
    final target = expiresAt.subtract(bindingRenewalLeadTime + jitter);
    final delay = target.difference(now);
    return delay > Duration.zero ? delay : null;
  }

  Duration _deterministicRenewalJitter(PushTokenBinding binding) {
    final windowMillis = bindingRenewalJitterWindow.inMilliseconds;
    if (windowMillis <= 0) return Duration.zero;
    final bytes = sha256
        .convert(
          utf8.encode(
            '${binding.firebaseProjectId}|${binding.environmentKey}|'
            '${binding.installationId}|${binding.accountUuid}',
          ),
        )
        .bytes;
    var seed = 0;
    for (final byte in bytes.take(6)) {
      seed = (seed << 8) | byte;
    }
    return Duration(milliseconds: seed % (windowMillis + 1));
  }

  void _scheduleBindingRenewal(
    PushTokenBinding binding,
    DateTime expiresAt,
    Duration delay,
  ) {
    _cancelBindingRenewal();
    if (_closed || delay <= Duration.zero) return;
    final revocationKey = binding.revocationKey;
    _bindingRenewalTimer = Timer(delay, () {
      _bindingRenewalTimer = null;
      final active = _activeBinding;
      if (_closed ||
          active == null ||
          active.revocationKey != revocationKey ||
          _activeLeaseExpiresAt != expiresAt) {
        return;
      }
      _renewalAttemptKey = revocationKey;
      _bindingConfirmedThisRun = false;
      unawaited(sync());
    });
  }

  void _scheduleBindingRenewalRetry(PushTokenBinding binding) {
    _bindingRenewalTimer?.cancel();
    _bindingRenewalTimer = null;
    final expiresAt = _activeLeaseExpiresAt;
    final revocationKey = binding.revocationKey;
    if (_closed ||
        bindingRenewalRetryDelay.inMilliseconds <= 0 ||
        expiresAt == null ||
        _activeBinding?.revocationKey != revocationKey) {
      return;
    }
    final now = _clock().toUtc();
    final latest = expiresAt.subtract(_bindingRenewalExpiryGuard);
    if (!latest.isAfter(now)) return;
    final requested = now.add(bindingRenewalRetryDelay);
    final target = requested.isBefore(latest) ? requested : latest;
    final delay = target.difference(now);
    if (delay <= Duration.zero) return;
    _renewalAttemptKey = revocationKey;
    _bindingRenewalTimer = Timer(delay, () {
      _bindingRenewalTimer = null;
      if (_closed ||
          _activeBinding?.revocationKey != revocationKey ||
          _activeLeaseExpiresAt != expiresAt) {
        return;
      }
      _renewalAttemptKey = revocationKey;
      _bindingConfirmedThisRun = false;
      unawaited(sync());
    });
  }

  void _cancelBindingRenewal() {
    _bindingRenewalTimer?.cancel();
    _bindingRenewalTimer = null;
    _renewalAttemptKey = null;
  }

  void _addPending(PushTokenBinding binding) {
    _pendingRevocations.removeWhere(
      (entry) => entry.binding.revocationKey == binding.revocationKey,
    );
    _pendingRevocations.add(
      _PendingPushTokenRevocation(binding: binding, recordedAt: _clock()),
    );
    _prunePending();
  }

  void _prunePending() {
    final cutoff = _clock().subtract(_pendingRetention);
    _pendingRevocations.removeWhere(
      (entry) => entry.recordedAt.isBefore(cutoff),
    );
    _pendingRevocations.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (_pendingRevocations.length > _maxPendingRevocations) {
      _pendingRevocations.removeRange(
        0,
        _pendingRevocations.length - _maxPendingRevocations,
      );
    }
  }

  Future<void> _restoreBindingState() async {
    final raw = _sharedPreferences?.getString(_bindingStateKey);
    if (raw == null || raw.isEmpty) {
      // The shared installation identity is never owned by the Push journal.
      // A server revision conflict can recover its lost high-water mark after
      // the strict local token cleanup below establishes a trusted baseline.
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('state is not a map');
      final state = decoded.cast<Object?, Object?>();
      final version = state['version'];
      if (version != 1 && version != 2) {
        throw const FormatException('unsupported binding state version');
      }
      final revisionValue = state['lastIssuedRevision'];
      if (revisionValue is! num ||
          revisionValue.toInt() != revisionValue ||
          revisionValue < 0 ||
          revisionValue > _maxPushTokenBindingRevision) {
        throw const FormatException('invalid binding revision');
      }
      final restoredRevision = revisionValue.toInt();
      PushTokenBinding? restoredActive;
      DateTime? restoredActiveExpiresAt;
      if (state.containsKey('active')) {
        restoredActive = PushTokenBinding.fromPersistentJson(
          state['active'],
          expectedInstallationId: _installationId!,
        );
        restoredActiveExpiresAt = _strictUtcTimestamp(state['activeExpiresAt']);
        if (restoredActive == null || restoredActiveExpiresAt == null) {
          throw const FormatException('invalid active binding');
        }
      } else if (state.containsKey('activeExpiresAt')) {
        throw const FormatException('orphan active lease');
      }
      final pending = state['pendingRevocations'];
      if (pending is! List) {
        throw const FormatException('invalid pending revocations');
      }
      final restoredPending = <_PendingPushTokenRevocation>[];
      for (final item in pending) {
        if (item is! Map) {
          throw const FormatException('invalid revocation receipt');
        }
        final entry = item.cast<Object?, Object?>();
        final binding = PushTokenBinding.fromPersistentJson(
          entry['binding'],
          expectedInstallationId: _installationId!,
        );
        final recordedAt = DateTime.tryParse(
          entry['recordedAt']?.toString() ?? '',
        );
        if (binding == null || recordedAt == null) {
          throw const FormatException('invalid revocation receipt');
        }
        restoredPending.add(
          _PendingPushTokenRevocation(binding: binding, recordedAt: recordedAt),
        );
      }
      final cleanupRequired = switch (version) {
        1 => true,
        2 when state['localTokenCleanupRequired'] is bool =>
          state['localTokenCleanupRequired']! as bool,
        _ => throw const FormatException('missing local cleanup proof'),
      };
      _lastIssuedRevision = restoredRevision;
      _activeBinding = restoredActive;
      _activeLeaseExpiresAt = restoredActiveExpiresAt;
      _pendingRevocations
        ..clear()
        ..addAll(restoredPending);
      _localTokenCleanupRequired = cleanupRequired;
      final knownMax = <int>[
        _lastIssuedRevision,
        if (_activeBinding case final binding?) binding.bindingRevision,
        ..._pendingRevocations.map((entry) => entry.binding.bindingRevision),
      ].reduce(max);
      _lastIssuedRevision = knownMax;
      _prunePending();
      // SharedPreferences is recovery context, not a crash-durable proof that
      // FlutterFire deleted the prior process's token. The first account
      // activation in every process therefore remains untrusted until its own
      // strict platform cleanup and baseline write both succeed.
    } catch (_) {
      _activeBinding = null;
      _activeLeaseExpiresAt = null;
      _pendingRevocations.clear();
      _lastIssuedRevision = 0;
      _localTokenCleanupRequired = true;
      _bindingStateUntrusted = true;
    }
  }

  Future<bool> _persistBindingState() async {
    _prunePending();
    final preferences = _sharedPreferences;
    if (preferences == null) return false;
    final value = jsonEncode(<String, Object?>{
      'version': 2,
      'lastIssuedRevision': _lastIssuedRevision,
      'localTokenCleanupRequired': _localTokenCleanupRequired,
      if (_activeBinding case final binding?)
        'active': binding.toPersistentJson(),
      if (_activeBinding != null && _activeLeaseExpiresAt != null)
        'activeExpiresAt': _activeLeaseExpiresAt!.toUtc().toIso8601String(),
      'pendingRevocations': _pendingRevocations
          .map((entry) => entry.toPersistentJson())
          .toList(growable: false),
    });
    return _bindingStateWriter?.call(_bindingStateKey, value) ??
        preferences.setString(_bindingStateKey, value);
  }

  _PushScopeSnapshot _snapshot() => _PushScopeSnapshot(
    generation: _scopeGeneration,
    session: _session.value,
    environment: _environmentSignal.value,
    preferences: _preferences.state.value,
  );

  bool _isCurrent(_PushScopeSnapshot snapshot) =>
      !_closed &&
      snapshot.generation == _scopeGeneration &&
      identical(snapshot.session, _session.value) &&
      snapshot.environment == _environmentSignal.value &&
      snapshot.preferences == _preferences.state.value;

  String? _validAccountUuid(MaasoAuthSession? session) =>
      session != null &&
          session.isValid &&
          session.accountUuid.trim().isNotEmpty
      ? session.accountUuid.trim()
      : null;

  bool get _requiresApnsToken => _platform == 'ios' || _platform == 'macos';

  void _markSuccess(_PushScopeSnapshot snapshot) {
    isRegistered.value = true;
    if (_hasRetryablePendingRevocation(snapshot)) {
      _scheduleRetry();
      return;
    }
    error.value = null;
    _retryAttempts = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _defer(String operation, Object exception) {
    final reason = exception is TimeoutException
        ? 'timed out'
        : exception is FirebaseMessagingApnsTokenUnavailable
        ? 'APNs token unavailable'
        : exception is _PushTokenOperationException
        ? exception.reason
        : exception.runtimeType.toString();
    final message = '$operation deferred: $reason';
    isRegistered.value = false;
    error.value = message;
    Log.w('[Notifications] $message');
    if (_accountActivationCleanupPending &&
        (exception is FirebaseMessagingApnsTokenUnavailable ||
            operation == 'wait for APNs token')) {
      _scheduleApnsCleanupRetry();
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleApnsCleanupRetry() {
    if (_closed ||
        !_accountActive ||
        !_accountActivationCleanupPending ||
        _apnsCleanupRetryTimer?.isActive == true) {
      return;
    }
    final delay = retryBaseDelay > Duration.zero
        ? retryBaseDelay
        : const Duration(milliseconds: 250);
    _apnsCleanupRetryTimer = Timer(delay, () {
      _apnsCleanupRetryTimer = null;
      if (_closed || !_accountActive || !_accountActivationCleanupPending) {
        return;
      }
      final inFlight = _syncFuture;
      if (inFlight != null) {
        unawaited(inFlight.whenComplete(_scheduleApnsCleanupRetry));
        return;
      }
      unawaited(
        sync().whenComplete(() {
          if (_accountActivationCleanupPending) {
            _scheduleApnsCleanupRetry();
          }
        }),
      );
    });
  }

  void _cancelApnsCleanupRetry() {
    _apnsCleanupRetryTimer?.cancel();
    _apnsCleanupRetryTimer = null;
  }

  void _scheduleRetry() {
    if (_closed ||
        !_accountActive ||
        maxRetryAttempts <= 0 ||
        _retryAttempts >= maxRetryAttempts ||
        _retryTimer?.isActive == true) {
      return;
    }
    final multiplier = 1 << _retryAttempts;
    _retryAttempts++;
    _retryTimer = Timer(
      Duration(milliseconds: retryBaseDelay.inMilliseconds * multiplier),
      () {
        _retryTimer = null;
        unawaited(sync());
      },
    );
  }

  @override
  void onClose() {
    _closed = true;
    _scopeGeneration++;
    _retryTimer?.cancel();
    _cancelApnsCleanupRetry();
    _cancelBindingRenewal();
    _sessionWorker?.dispose();
    _environmentWorker?.dispose();
    _preferenceWorker?.dispose();
    unawaited(_tokenSubscription?.cancel());
    if (_registrar is HttpPushTokenRegistrar) {
      _registrar.close();
    }
    super.onClose();
  }
}
