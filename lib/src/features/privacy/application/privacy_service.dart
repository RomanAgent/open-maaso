import 'dart:async';
import 'dart:math';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

import '../data/privacy_fence_store.dart';
import '../domain/privacy_models.dart';

/// Mounted per account (or per anonymous policy page). Construction never makes
/// a network request. Only a human UI calls the two declaration methods.
final class PrivacyService extends AppService {
  PrivacyService({
    required PrivacyGateway gateway,
    void Function()? closeGateway,
    String Function()? requestKey,
    Future<PrivacyFenceStore>? fenceStore,
    String? fenceScopeKey,
  }) : _gateway = gateway,
       _closeGateway = closeGateway,
       _requestKey = requestKey ?? _newRequestKey,
       boundContextKey = gateway.requestContextKey,
       _fenceScopeKey = fenceScopeKey {
    if ((fenceStore == null) != (fenceScopeKey == null)) {
      throw ArgumentError('privacy_fence_scope_required');
    }
    _fencesHydrated.value = fenceStore == null;
    _fenceHydration = fenceStore == null
        ? Future<void>.value()
        : _hydrateFences(fenceStore);
  }

  final PrivacyGateway _gateway;
  final void Function()? _closeGateway;
  final String Function() _requestKey;
  final String boundContextKey;
  final String? _fenceScopeKey;
  PrivacyFenceStore? _fenceStore;
  late final Future<void> _fenceHydration;
  final RxBool _fencesHydrated = false.obs;
  final RxInt _fenceChanges = 0.obs;
  final Completer<void> _retirement = Completer<void>();
  Future<void> _writeTail = Future<void>.value();
  Future<void>? _drain;
  bool _fenceLoadFailed = false;
  bool _fenceWriteFailed = false;
  final Rxn<PrivacyPublicPolicy> _publicPolicy = Rxn<PrivacyPublicPolicy>();
  final Rxn<PrivacySnapshot> _snapshot = Rxn<PrivacySnapshot>();
  final RxBool _saving = false.obs;
  final RxInt _loading = 0.obs;
  Future<void> _tail = Future<void>.value();
  bool _retired = false;
  int _authorizationEpoch = 0;
  int _minimumRevision = 0;
  final Set<String> _localRevocations = <String>{};
  final Map<String, int> _localRevocationRevisions = {};
  final Set<String> _observedRevocations = <String>{};
  final Map<String, int> _observedRevocationRevisions = {};
  final Map<String, Set<String>> _revokedOrigins = {};
  final RxBool _knownAgeIneligible = false.obs;
  int? _ageIneligibleRevision;
  PrivacyPolicy? _lastDisclosedPolicy;
  final _revocations = StreamController<PrivacyRevocation>.broadcast(
    sync: true,
  );
  final List<PrivacyRevocation> _revocationQueue = [];
  bool _dispatchingRevocations = false;
  bool _closeRevocationsRequested = false;

  Stream<PrivacyRevocation> get revocations => _revocations.stream;

  bool get isCurrent =>
      !_retired && boundContextKey == _gateway.requestContextKey;
  bool get hasAccount => isCurrent && _gateway.hasAccount;
  PrivacyPublicPolicy? get publicPolicy =>
      isCurrent ? _publicPolicy.value : null;
  PrivacySnapshot? get snapshot =>
      isCurrent && !_saving.value ? _snapshot.value : null;

  /// Diagnostic admission from already-loaded policy only. No fetch or consent
  /// mutation; the server still enforces current policy on the actual request.
  bool allowsLoadedConsent({
    required String recipientId,
    required String scope,
  }) =>
      hasAccount &&
      _fencesHydrated.value &&
      PrivacyScopes.all.contains(scope) &&
      RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(recipientId) &&
      (isInternalTest || !_knownAgeIneligible.value) &&
      !_denied(recipientId, scope);

  bool get loading => isCurrent && _loading.value > 0;
  bool get saving => isCurrent && _saving.value;
  bool get ageEligible => snapshot?.ageEligible ?? false;
  bool get usesDefaultAvailability =>
      isCurrent &&
      (publicPolicy?.ready != true ||
          snapshot?.ready != true ||
          snapshot?.ageStatus == 'unconfirmed');

  /// Explicit internal QA build only, bound to the test API for this owner.
  /// A test exemption is never stored as a policy, birth date or user consent.
  bool get isInternalTest =>
      const bool.fromEnvironment('MAASO_INTERNAL_PRIVACY_TEST') &&
      kMaasoStoreInternalBuild &&
      isCurrent &&
      boundContextKey.startsWith('${MaasoEnvironment.test.baseUrl}/|');

  bool get canEnterOnlineFeatures =>
      hasAccount && (isInternalTest || !_knownAgeIneligible.value);

  bool _denied(String recipientId, String scope) {
    // Observe snapshot changes for reactive settings without treating absence
    // of a snapshot as absence of a previously observed withdrawal.
    _snapshot.value;
    _fenceChanges.value;
    final key = '$recipientId|$scope';
    return _localRevocations.contains(key) ||
        _observedRevocations.contains(key);
  }

  void _rememberWithdrawal(String recipientId, String scope) {
    final key = '$recipientId|$scope';
    final origins = _revokedOrigins.putIfAbsent(key, () => <String>{});
    for (final policy in [publicPolicy?.policy, _lastDisclosedPolicy]) {
      origins.addAll(
        policy?.recipient(recipientId, scope)?.apiOrigins ?? const [],
      );
    }
  }

  void _checkKnownAge() {
    if (_knownAgeIneligible.value) {
      throw const PrivacyException('PRIVACY_AGE_INELIGIBLE');
    }
  }

  /// Missing operator configuration and failed policy reads are availability
  /// fallbacks. Account changes and authentication failures remain distinct.
  Future<void> _readForAccess() async {
    _check();
    if (!hasAccount) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
    if (publicPolicy?.ready == false) return;
    try {
      await _read();
    } on PrivacyException catch (error) {
      _check();
      if (error.code == 'PRIVACY_AUTHENTICATION_REQUIRED' ||
          error.code == 'PRIVACY_CONTEXT_CHANGED' ||
          error.code == 'PRIVACY_CONSENT_REQUIRED' ||
          error.code == 'PRIVACY_AGE_INELIGIBLE') {
        rethrow;
      }
    } catch (_) {
      _check();
    }
  }

  bool _useInternalTestAccess() {
    if (!isInternalTest) return false;
    if (!hasAccount) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
    return true;
  }

  void _check() {
    if (!isCurrent) throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    Future<T> admitted() {
      _check();
      return action();
    }

    final result = _tail.then((_) {
      if (_fencesHydrated.value) return admitted();
      return _fenceHydration.then((_) => admitted());
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<PrivacySnapshot?> refresh() async {
    _check();
    if (isInternalTest) return null;
    _loading.value++;
    try {
      return await _serial(() async {
        try {
          final policy = await _whileCurrent(
            _gateway.policy(expectedContextKey: boundContextKey),
          );
          _check();
          await _acceptPolicy(policy);
          if (!policy.ready || !hasAccount) {
            _snapshot.value = null;
            return null;
          }
          return await _read();
        } catch (_) {
          _check();
          _snapshot.value = null;
          rethrow;
        }
      });
    } finally {
      if (!_retired) _loading.value--;
    }
  }

  /// This fresh server read is intentionally not coalesced with an earlier
  /// dispatch: revocation and policy changes must be observed on every call.
  Future<void> requireCloud({
    required Uri origin,
    required String scope,
  }) async {
    _check();
    if (!PrivacyScopes.all.contains(scope) ||
        origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasFragment) {
      throw const PrivacyException('PRIVACY_UNAVAILABLE');
    }
    if (_useInternalTestAccess()) return;
    final epoch = _authorizationEpoch;
    if (saving) throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
    await _serial(() async {
      await _readForAccess();
      _checkAuthorization(epoch);
      _checkKnownAge();
      final policy = publicPolicy?.policy ?? _lastDisclosedPolicy;
      final recipients = (policy?.recipients ?? const <PrivacyRecipient>[])
          .where(
            (r) =>
                r.apiOrigins.any((o) => Uri.parse(o).origin == origin.origin) &&
                r.scopes.contains(scope),
          );
      for (final recipient in recipients) {
        if (_denied(recipient.id, scope)) {
          throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
        }
      }
      for (final key in {..._localRevocations, ..._observedRevocations}) {
        if (!key.endsWith('|$scope')) continue;
        final origins = _revokedOrigins[key] ?? const <String>{};
        if (origins.isEmpty || origins.contains(origin.origin)) {
          throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
        }
      }
      _checkAuthorization(epoch);
    });
  }

  Future<void> requireConsent({
    required String recipientId,
    required String scope,
  }) async {
    _check();
    if (!PrivacyScopes.all.contains(scope) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(recipientId)) {
      throw const PrivacyException('PRIVACY_UNAVAILABLE');
    }
    if (_useInternalTestAccess()) return;
    final epoch = _authorizationEpoch;
    if (saving) throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
    await _serial(() async {
      await _readForAccess();
      _checkAuthorization(epoch);
      _checkKnownAge();
      if (_denied(recipientId, scope)) {
        throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
      }
      _checkAuthorization(epoch);
    });
  }

  Future<void> requireAge() async {
    _check();
    if (_useInternalTestAccess()) return;
    final epoch = _authorizationEpoch;
    await _serial(() async {
      await _readForAccess();
      _checkAuthorization(epoch);
      _checkKnownAge();
    });
  }

  void _checkAuthorization(int epoch) {
    _check();
    if (_authorizationEpoch != epoch || saving) {
      throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
    }
  }

  static void _checkAge(PrivacySnapshot value) {
    if (value.ageStatus == 'ineligible') {
      throw const PrivacyException('PRIVACY_AGE_INELIGIBLE');
    }
  }

  Future<PrivacySnapshot> _read() async {
    _check();
    if (!hasAccount) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
    try {
      final value = await _whileCurrent(
        _gateway.read(expectedContextKey: boundContextKey),
      );
      _check();
      await _acceptSnapshot(value);
      return value;
    } catch (_) {
      _check();
      _snapshot.value = null;
      rethrow;
    }
  }

  Future<PrivacySnapshot> humanDeclareAge({
    required PrivacySnapshot reviewed,
    required String birthDate,
  }) async {
    _checkReview(reviewed);
    _validateBirthDate(birthDate);
    return _human(
      reviewed,
      () => _gateway.declareAge(
        expectedContextKey: boundContextKey,
        requestKey: _requestKey(),
        expectedRevision: reviewed.revision,
        expectedPolicyVersion: reviewed.policy!.version,
        expectedPolicyHash: reviewed.policyHash!,
        birthDate: birthDate,
      ),
    );
  }

  Future<PrivacySnapshot> humanSetConsent({
    required PrivacySnapshot reviewed,
    required String recipientId,
    required String scope,
    required bool allow,
  }) async {
    _checkReview(reviewed);
    if (reviewed.policy!.recipient(recipientId, scope) == null) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
    if (allow) _checkAge(reviewed);
    final consentKey = '$recipientId|$scope';
    if (!allow) {
      _localRevocations.add(consentKey);
      _localRevocationRevisions[consentKey] = reviewed.revision;
      _rememberWithdrawal(recipientId, scope);
      _emitRevocation(
        PrivacyRevocation(recipientId: recipientId, scope: scope),
      );
    }
    // Enqueue the local restriction immediately, independently of a possibly
    // stalled earlier network read. Retirement drains this captured DB write.
    final persistedWithdrawal = !allow && _fenceScopeKey != null
        ? _persistFence(_captureFence())
        : null;
    return _human(
      reviewed,
      () => _gateway.setConsent(
        expectedContextKey: boundContextKey,
        requestKey: _requestKey(),
        expectedRevision: reviewed.revision,
        expectedPolicyVersion: reviewed.policy!.version,
        expectedPolicyHash: reviewed.policyHash!,
        recipientId: recipientId,
        scope: scope,
        allow: allow,
      ),
      beforeMutation: persistedWithdrawal,
      verifyResult: (result) =>
          result.explicitChoice(recipientId, scope) == allow,
      clearPendingKey: allow ? consentKey : null,
    );
  }

  Future<PrivacySnapshot> _human(
    PrivacySnapshot reviewed,
    Future<PrivacySnapshot> Function() mutate, {
    Future<void>? beforeMutation,
    bool Function(PrivacySnapshot)? verifyResult,
    String? clearPendingKey,
  }) async {
    _checkReview(reviewed);
    if (saving) throw const PrivacyException('PRIVACY_BUSY');
    _saving.value = true;
    _authorizationEpoch++;
    // An uncertain mutation must never leave a cached allow/eligible state.
    _snapshot.value = null;
    try {
      return await _serial(() async {
        _checkPolicyReview(reviewed);
        if (beforeMutation != null) await beforeMutation;
        _check();
        final result = await _whileCurrent(mutate());
        _check();
        if (result.revision <= reviewed.revision ||
            verifyResult?.call(result) == false) {
          throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
        }
        await _acceptSnapshot(
          result,
          clearPendingKey: clearPendingKey,
          requireDurable: true,
        );
        return result;
      });
    } catch (_) {
      _check();
      _snapshot.value = null;
      rethrow;
    } finally {
      if (!_retired) _saving.value = false;
    }
  }

  void _checkPolicyReview(PrivacySnapshot reviewed) {
    _check();
    final current = publicPolicy;
    if (current == null || !current.ready || !reviewed.ready) {
      throw const PrivacyException('PRIVACY_UNAVAILABLE');
    }
    if (reviewed.policy!.version != current.policy!.version ||
        reviewed.policyHash != current.policyHash) {
      throw const PrivacyException('PRIVACY_POLICY_CHANGED');
    }
  }

  void _checkReview(PrivacySnapshot reviewed) {
    _checkPolicyReview(reviewed);
    if (!hasAccount) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
    if (saving) throw const PrivacyException('PRIVACY_BUSY');
    if (snapshot == null || snapshot!.revision != reviewed.revision) {
      throw const PrivacyException('PRIVACY_REVISION_CONFLICT');
    }
  }

  void _validatePolicy(PrivacyPublicPolicy policy) {
    final previous = _publicPolicy.value;
    if (policy.ready && previous?.ready == true) {
      if ((policy.policy!.version == previous!.policy!.version &&
              policy.policyHash != previous.policyHash) ||
          policy.policy!.effectiveAt.isBefore(previous.policy!.effectiveAt)) {
        throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
      }
    }
  }

  Future<void> _acceptPolicy(PrivacyPublicPolicy policy) async {
    _validatePolicy(policy);
    _publicPolicy.value = policy;
    if (policy.ready) _lastDisclosedPolicy = policy.policy;
    final next = _withPolicyOrigins(_captureFence(), policy.policy);
    _applyFence(next);
    // An unreadable local cache is unknown, not a user denial. Do not overwrite
    // it with defaults; genuine in-memory restrictions remain in force.
    if (!_fenceLoadFailed) await _persistFence(next);
  }

  Future<void> _acceptSnapshot(
    PrivacySnapshot value, {
    String? clearPendingKey,
    bool requireDurable = false,
  }) async {
    if (value.revision < _minimumRevision) {
      throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
    }
    for (final consent in value.consents) {
      final revokedAt =
          _observedRevocationRevisions['${consent.recipientId}|${consent.scope}'];
      if (consent.explicitChoice == true &&
          revokedAt != null &&
          value.revision <= revokedAt) {
        throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
      }
    }
    if (_ageIneligibleRevision != null &&
        value.ageStatus == 'eligible' &&
        value.revision <= _ageIneligibleRevision!) {
      throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
    }
    // Validate the whole response before changing any remembered restriction.
    _validatePolicy(value.publicPolicy);
    final previous = _captureFence();
    final denials = Map<String, PrivacyFenceDenial>.of(
      _withPolicyOrigins(previous, value.policy).denials,
    );
    for (final consent in value.consents) {
      final key = '${consent.recipientId}|${consent.scope}';
      final old = denials[key];
      if (consent.explicitChoice == false) {
        denials[key] = PrivacyFenceDenial(
          observedRevision: value.revision,
          pendingRevision: old?.pendingRevision,
          origins: {
            ...?old?.origins,
            ...?_lastDisclosedPolicy
                ?.recipient(consent.recipientId, consent.scope)
                ?.apiOrigins,
            ...?value.policy
                ?.recipient(consent.recipientId, consent.scope)
                ?.apiOrigins,
          },
        );
      } else if (consent.explicitChoice == true) {
        if (old?.pendingRevision == null || key == clearPendingKey) {
          if (key == clearPendingKey &&
              old?.pendingRevision != null &&
              value.revision <= old!.pendingRevision!) {
            throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
          }
          denials.remove(key);
        } else {
          denials[key] = PrivacyFenceDenial(
            pendingRevision: old!.pendingRevision,
            origins: old.origins,
          );
        }
      }
    }
    var next = PrivacyFenceState(
      minimumRevision: value.revision,
      ageIneligibleRevision: value.ageStatus == 'unconfirmed'
          ? previous.ageIneligibleRevision
          : value.ageStatus == 'ineligible'
          ? value.revision
          : null,
      denials: denials,
    );
    // New restrictions take effect synchronously. Grants become effective only
    // after durable write success; a failed write leaves the conservative union.
    _applyFence(_unionFences(previous, next));
    if (_fenceLoadFailed && !requireDurable) {
      // Retain known restrictions while exposing only this actual server
      // snapshot. Unknown local storage cannot become blanket cloud denial.
      _check();
      _publicPolicy.value = value.publicPolicy;
      if (value.ready) _lastDisclosedPolicy = value.policy;
      _snapshot.value = value;
      return;
    }
    var epoch = _authorizationEpoch;
    while (true) {
      await _persistFence(next);
      _check();
      if (epoch == _authorizationEpoch) break;
      next = _withPolicyOrigins(
        _retainPending(next, except: clearPendingKey),
        value.policy,
      );
      epoch = _authorizationEpoch;
    }
    _applyFence(next);
    _publicPolicy.value = value.publicPolicy;
    if (value.ready) _lastDisclosedPolicy = value.policy;
    _snapshot.value = value;
  }

  /// Mount waits for hydration without turning unknown local/operator state
  /// into a navigation or cloud denial. Explicit restrictions remain separate.
  Future<void> hydrateFences() => _fenceHydration;

  Future<T> _whileCurrent<T>(Future<T> future) => Future.any<T>([
    future,
    _retirement.future.then<T>(
      (_) => throw const PrivacyException('PRIVACY_CONTEXT_CHANGED'),
    ),
  ]);

  Future<void> _hydrateFences(Future<PrivacyFenceStore> future) async {
    try {
      final store = await _whileCurrent(future);
      _check();
      if (store.scopeKey != _fenceScopeKey) {
        throw const PrivacyException('PRIVACY_LOCAL_STATE_UNAVAILABLE');
      }
      final state = await _whileCurrent(store.read());
      _check();
      _fenceStore = store;
      // The store validates the entire record before returning any restriction.
      if (state != null) _applyFence(state);
    } catch (_) {
      if (isCurrent) _fenceLoadFailed = true;
    } finally {
      if (!_retired) _fencesHydrated.value = true;
    }
  }

  Future<void> _persistFence(PrivacyFenceState state) {
    // A synchronous revocation listener may retire this service before the
    // caller reaches persistence. Only writes already queued may outlive it.
    _check();
    if (_fenceScopeKey == null) return Future<void>.value();
    final store = _fenceStore;
    if (store == null || store.scopeKey != _fenceScopeKey) {
      throw const PrivacyException('PRIVACY_LOCAL_STATE_UNAVAILABLE');
    }
    // Capture this store and this immutable state now. Once authorized, a
    // withdrawal write finishes against the old account DB even after retire.
    final write = _writeTail.then((_) async {
      try {
        await store.write(state);
      } catch (_) {
        throw const PrivacyException('PRIVACY_LOCAL_STATE_UNAVAILABLE');
      }
    });
    _writeTail = write.then<void>(
      (_) => _fenceWriteFailed = false,
      onError: (Object _, StackTrace _) => _fenceWriteFailed = true,
    );
    return write;
  }

  PrivacyFenceState _captureFence() => PrivacyFenceState(
    minimumRevision: _minimumRevision,
    ageIneligibleRevision: _ageIneligibleRevision,
    denials: {
      for (final key in {..._localRevocations, ..._observedRevocations})
        key: PrivacyFenceDenial(
          observedRevision: _observedRevocationRevisions[key],
          pendingRevision: _localRevocationRevisions[key],
          origins: _revokedOrigins[key] ?? const {},
        ),
    },
  );

  PrivacyFenceState _withPolicyOrigins(
    PrivacyFenceState state,
    PrivacyPolicy? policy,
  ) => PrivacyFenceState(
    minimumRevision: state.minimumRevision,
    ageIneligibleRevision: state.ageIneligibleRevision,
    denials: {
      for (final entry in state.denials.entries)
        entry.key: PrivacyFenceDenial(
          observedRevision: entry.value.observedRevision,
          pendingRevision: entry.value.pendingRevision,
          origins: {
            ...entry.value.origins,
            ...?policy
                ?.recipient(
                  entry.key.split('|').first,
                  entry.key.split('|').last,
                )
                ?.apiOrigins,
          },
        ),
    },
  );

  static int? _newerRevision(int? a, int? b) => a == null
      ? b
      : b == null
      ? a
      : max(a, b);

  static PrivacyFenceState _unionFences(
    PrivacyFenceState a,
    PrivacyFenceState b,
  ) => PrivacyFenceState(
    minimumRevision: max(a.minimumRevision, b.minimumRevision),
    ageIneligibleRevision: _newerRevision(
      a.ageIneligibleRevision,
      b.ageIneligibleRevision,
    ),
    denials: {
      for (final key in {...a.denials.keys, ...b.denials.keys})
        key: PrivacyFenceDenial(
          observedRevision: _newerRevision(
            a.denials[key]?.observedRevision,
            b.denials[key]?.observedRevision,
          ),
          pendingRevision: _newerRevision(
            a.denials[key]?.pendingRevision,
            b.denials[key]?.pendingRevision,
          ),
          origins: {...?a.denials[key]?.origins, ...?b.denials[key]?.origins},
        ),
    },
  );

  PrivacyFenceState _retainPending(PrivacyFenceState state, {String? except}) {
    final current = _captureFence();
    return _unionFences(
      state,
      PrivacyFenceState(
        minimumRevision: current.minimumRevision,
        denials: {
          for (final entry in current.denials.entries)
            if (entry.key != except && entry.value.pendingRevision != null)
              entry.key: PrivacyFenceDenial(
                pendingRevision: entry.value.pendingRevision,
                origins: entry.value.origins,
              ),
        },
      ),
    );
  }

  void _applyFence(PrivacyFenceState state) {
    final oldDenials = {..._localRevocations, ..._observedRevocations};
    final oldAge = _knownAgeIneligible.value;
    _localRevocations.clear();
    _localRevocationRevisions.clear();
    _observedRevocations.clear();
    _observedRevocationRevisions.clear();
    _revokedOrigins.clear();
    for (final entry in state.denials.entries) {
      final denial = entry.value;
      if (denial.pendingRevision != null) {
        _localRevocations.add(entry.key);
        _localRevocationRevisions[entry.key] = denial.pendingRevision!;
      }
      if (denial.observedRevision != null) {
        _observedRevocations.add(entry.key);
        _observedRevocationRevisions[entry.key] = denial.observedRevision!;
      }
      _revokedOrigins[entry.key] = Set.of(denial.origins);
    }
    _minimumRevision = state.minimumRevision;
    _ageIneligibleRevision = state.ageIneligibleRevision;
    _knownAgeIneligible.value = state.ageIneligibleRevision != null;
    _fenceChanges.value++;
    for (final key in state.denials.keys) {
      if (_retired) return;
      if (!oldDenials.contains(key)) {
        final parts = key.split('|');
        _emitRevocation(
          PrivacyRevocation(recipientId: parts.first, scope: parts.last),
        );
      }
    }
    if (!_retired && !oldAge && _knownAgeIneligible.value) {
      _emitRevocation(const PrivacyRevocation());
    }
  }

  void _emitRevocation(PrivacyRevocation event) {
    if (_revocations.isClosed) return;
    _revocationQueue.add(event);
    if (_dispatchingRevocations) return;
    _dispatchingRevocations = true;
    try {
      // Synchronous listeners can retire the service. Queue its global revoke
      // until the current add returns; a sync broadcast cannot reenter add.
      while (_revocationQueue.isNotEmpty) {
        _revocations.add(_revocationQueue.removeAt(0));
      }
    } finally {
      _dispatchingRevocations = false;
      if (_closeRevocationsRequested) unawaited(_revocations.close());
    }
  }

  Future<void> sealAndDrain() {
    _retire();
    return _drain ??= _drainWrites();
  }

  Future<void> _drainWrites() async {
    await _writeTail;
    if (_fenceWriteFailed) {
      throw const PrivacyException('PRIVACY_LOCAL_STATE_UNAVAILABLE');
    }
  }

  static void _validateBirthDate(String raw) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
    final date = DateTime.tryParse('${raw}T00:00:00Z');
    final today = DateTime.now().toUtc();
    if (date == null ||
        date.year < 1900 ||
        date.isAfter(today) ||
        date.toIso8601String().substring(0, 10) != raw) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
  }

  static String _newRequestKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  void onClose() {
    _retire();
    super.onClose();
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _retirement.complete();
    _closeRevocationsRequested = true;
    _emitRevocation(const PrivacyRevocation());
    _authorizationEpoch++;
    _snapshot.value = null;
    _publicPolicy.value = null;
    _saving.value = false;
    _loading.value = 0;
    _localRevocations.clear();
    _localRevocationRevisions.clear();
    _observedRevocations.clear();
    _observedRevocationRevisions.clear();
    _revokedOrigins.clear();
    _lastDisclosedPolicy = null;
    _knownAgeIneligible.value = false;
    _ageIneligibleRevision = null;
    _closeGateway?.call();
  }
}

/// Null fields invalidate all processors after a policy/account change.
final class PrivacyRevocation {
  const PrivacyRevocation({this.recipientId, this.scope});
  final String? recipientId;
  final String? scope;
  bool affects(String recipient, String use) =>
      (recipientId == null || recipientId == recipient) &&
      (scope == null || scope == use);
}
