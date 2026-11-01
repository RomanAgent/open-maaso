import 'package:maaso/src/core/foundation/app_framework.dart';

import '../data/identity_local_store.dart';
import '../domain/identity_local_state.dart';
import '../domain/identity_profile.dart';

/// One instance per mounted account. The host retires it on account teardown.
final class IdentityService extends AppService {
  IdentityService({
    required IdentityGateway gateway,
    void Function()? closeGateway,
    Future<void> Function(IdentityProfile)? projectProfile,
    bool Function()? hasLocalCompanion,
    IdentityLocalStore? localStore,
    bool Function()? allowLocalSetup,
    Future<void> Function(String)? projectLocalAgentName,
  }) : _gateway = gateway,
       _closeGateway = closeGateway,
       _projectProfile = projectProfile,
       _hasLocalCompanion = hasLocalCompanion,
       _localStore = localStore,
       _allowLocalSetup = allowLocalSetup,
       _projectLocalAgentName = projectLocalAgentName,
       boundContextKey = gateway.requestContextKey;

  final IdentityGateway _gateway;
  final void Function()? _closeGateway;
  final Future<void> Function(IdentityProfile)? _projectProfile;
  final bool Function()? _hasLocalCompanion;
  final IdentityLocalStore? _localStore;
  final bool Function()? _allowLocalSetup;
  final Future<void> Function(String)? _projectLocalAgentName;
  final String boundContextKey;
  final Rxn<IdentityProfile> _profile = Rxn<IdentityProfile>();
  Future<IdentityProfile>? _loading;
  bool _saving = false;
  bool _retired = false;
  Future<void> _projectionTail = Future<void>.value();
  final Rxn<int> _projectedVersion = Rxn<int>();
  bool _loadUnavailable = false;
  bool _localCompanionEnabled = false;
  final Rxn<IdentityLocalState> _localState = Rxn<IdentityLocalState>();
  Future<void>? _restoring;
  Future<void> _persistenceTail = Future<void>.value();
  bool _setupSaving = false;
  String? cacheIssue;

  bool get isCurrent =>
      !_retired && boundContextKey == _gateway.requestContextKey;
  IdentityProfile? get profile => isCurrent ? _profile.value : null;
  bool get completed =>
      (profile?.completed ?? false) &&
      _projectedVersion.value == profile?.version;
  bool get pendingSync => isCurrent && _localState.value?.pendingNames != null;
  IdentityLocalNames? get setupNames => isCurrent
      ? (_localState.value?.pendingNames ??
            (profile?.completed == true
                ? IdentityLocalNames(
                    playerName: profile!.playerName,
                    agentName: profile!.agentName,
                  )
                : _localState.value?.names))
      : null;
  String get setupPlayerName =>
      setupNames?.playerName ??
      profile?.playerName ??
      (isCurrent ? _localState.value?.serverProfile?.playerName : null) ??
      '';
  String get setupAgentName =>
      setupNames?.agentName ??
      profile?.agentName ??
      (isCurrent ? _localState.value?.serverProfile?.agentName : null) ??
      '';

  /// Navigation readiness is distinct from freshly verified public identity.
  bool get onboardingCompleted =>
      isCurrent &&
      (completed ||
          _localState.value?.serverProfile?.completed == true ||
          (pendingSync && (_allowLocalSetup?.call() ?? false)));
  bool get canSaveLocally =>
      isCurrent &&
      _localStore != null &&
      _loadUnavailable &&
      !(profile?.completed ??
          _localState.value?.serverProfile?.completed ??
          false) &&
      (_allowLocalSetup?.call() ?? false);
  IdentitySetupResult? get setupResult => !onboardingCompleted
      ? null
      : pendingSync
      ? IdentitySetupResult.local(_localState.value!.pendingNames!)
      : IdentitySetupResult.server(
          profile ?? _localState.value!.serverProfile!,
        );
  bool get canContinueLocally =>
      isCurrent &&
      _profile.value == null &&
      _loadUnavailable &&
      (_hasLocalCompanion?.call() ?? false);
  bool get localCompanionEnabled => isCurrent && _localCompanionEnabled;

  bool continueLocally() {
    if (!canContinueLocally) return false;
    _localCompanionEnabled = true;
    return true;
  }

  void _check() {
    if (!isCurrent) {
      throw const IdentityException(IdentityFailure.contextChanged);
    }
  }

  /// Local-only startup hydration. The host projects setupNames after restoring
  /// inside its mount fence; this never invokes runtime or network callbacks.
  Future<void> restore() {
    _check();
    return _restoring ??= _restore();
  }

  Future<void> _restore() async {
    if (_localStore == null) return;
    try {
      final value = await _localStore.read();
      _check();
      _localState.value = value;
      cacheIssue = null;
    } on FormatException {
      _check();
      cacheIssue = 'invalid_identity_cache';
    } on IdentityException {
      rethrow;
    } catch (_) {
      _check();
      cacheIssue = 'identity_cache_unavailable';
    }
  }

  Future<void> _persist(
    IdentityLocalState value, {
    bool preservePendingNames = false,
  }) {
    final pending = _persistenceTail.then((_) async {
      _check();
      // A server read can finish while a human's local save is committing.
      // Merge after earlier writes settle, so that read cannot erase the draft.
      final next = preservePendingNames
          ? IdentityLocalState(
              serverProfile: value.serverProfile,
              pendingNames:
                  _localState.value?.pendingNames ?? value.pendingNames,
            )
          : value;
      await _localStore?.write(next);
      _check();
      _localState.value = next;
      cacheIssue = null;
    });
    _persistenceTail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<IdentityProfile> load() {
    _check();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<IdentityProfile> _load() async {
    await restore();
    _check();
    late final IdentityProfile value;
    try {
      value = await _gateway.fetch(expectedContextKey: boundContextKey);
    } catch (error) {
      _check();
      _loadUnavailable =
          error is! IdentityException ||
          error.failure == IdentityFailure.unavailable;
      if (!_loadUnavailable) _localCompanionEnabled = false;
      rethrow;
    }
    _check();
    _loadUnavailable = false;
    _localCompanionEnabled = false;
    final previous = _profile.value ?? _localState.value?.serverProfile;
    // A slow read admitted before a successful write must not regress it.
    if (previous != null && value.version < previous.version) {
      await _project(previous);
      return previous;
    }
    _validateStableActors(previous, value);
    if (previous != null &&
        value.version == previous.version &&
        (value.playerName != previous.playerName ||
            value.agentName != previous.agentName)) {
      throw const IdentityException(IdentityFailure.invalidResponse);
    }
    _profile.value = value;
    final pending = _localState.value?.pendingNames;
    if (pending != null && !value.completed && !_saving && !_setupSaving) {
      // The original human save authorizes filling still-missing names only.
      // A completed identity on another device wins without being overwritten.
      return save(
        playerName: value.playerName.isEmpty
            ? pending.playerName
            : value.playerName,
        agentName: value.agentName.isEmpty
            ? pending.agentName
            : value.agentName,
      );
    }
    await _persist(
      IdentityLocalState(
        serverProfile: value,
        pendingNames: value.completed ? null : pending,
      ),
      preservePendingNames: !value.completed,
    );
    await _project(value);
    return value;
  }

  Future<void> _project(IdentityProfile value) {
    final pending = _projectionTail.then((_) async {
      _check();
      if (!value.completed ||
          _profile.value?.version != value.version ||
          _projectedVersion.value == value.version) {
        return;
      }
      await _projectProfile?.call(value);
      _check();
      if (_profile.value?.version == value.version) {
        _projectedVersion.value = value.version;
      }
    });
    _projectionTail = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return pending;
  }

  Future<IdentityProfile> save({
    required String playerName,
    required String agentName,
  }) async {
    _check();
    if (_saving || _profile.value == null) {
      throw const IdentityException(IdentityFailure.rejected);
    }
    final before = _profile.value!;
    final player = IdentityNames.require(playerName);
    final agent = IdentityNames.require(agentName);
    _saving = true;
    try {
      // Retrying a local projection/navigation failure must not mint a new revision.
      if (before.completed &&
          before.playerName == player &&
          before.agentName == agent) {
        await _persist(IdentityLocalState(serverProfile: before));
        await _project(before);
        return before;
      }
      final result = await _gateway.update(
        expectedContextKey: boundContextKey,
        expectedVersion: before.version,
        playerName: player,
        agentName: agent,
      );
      _check();
      if (!result.completed ||
          result.version <= before.version ||
          result.playerName != player ||
          result.agentName != agent) {
        throw const IdentityException(IdentityFailure.invalidResponse);
      }
      _validateStableActors(before, result);
      final current = _profile.value;
      if (current != null && current.version > result.version) {
        throw const IdentityException(IdentityFailure.conflict);
      }
      _profile.value = result;
      await _persist(IdentityLocalState(serverProfile: result));
      await _project(result);
      return result;
    } finally {
      _saving = false;
    }
  }

  /// Human first-use submission. Unavailable internal-test APIs may defer the
  /// server registration, without inventing an actor or claiming server success.
  Future<IdentitySetupResult> saveSetup({
    required String playerName,
    required String agentName,
  }) async {
    _check();
    if (_setupSaving || _saving) {
      throw const IdentityException(IdentityFailure.rejected);
    }
    final names = IdentityLocalNames(
      playerName: playerName,
      agentName: agentName,
    );
    _setupSaving = true;
    try {
      try {
        if (_profile.value == null && !canSaveLocally) await load();
        if (_profile.value != null) {
          return IdentitySetupResult.server(
            await save(
              playerName: names.playerName,
              agentName: names.agentName,
            ),
          );
        }
      } on IdentityException catch (error) {
        _check();
        if (error.failure != IdentityFailure.unavailable) rethrow;
        _loadUnavailable = true;
      }
      if (!canSaveLocally) {
        throw const IdentityException(IdentityFailure.unavailable);
      }
      await _persist(
        IdentityLocalState(
          serverProfile: _profile.value ?? _localState.value?.serverProfile,
          pendingNames: names,
        ),
      );
      await _projectLocalAgentName?.call(names.agentName);
      _check();
      return IdentitySetupResult.local(names);
    } finally {
      _setupSaving = false;
    }
  }

  static void _validateStableActors(
    IdentityProfile? before,
    IdentityProfile after,
  ) {
    if (before != null &&
        ((before.playerActorId.isNotEmpty &&
                before.playerActorId != after.playerActorId) ||
            (before.agentActorId.isNotEmpty &&
                before.agentActorId != after.agentActorId))) {
      throw const IdentityException(IdentityFailure.invalidResponse);
    }
  }

  @override
  void onClose() {
    _retired = true;
    _profile.value = null;
    _localState.value = null;
    _closeGateway?.call();
    super.onClose();
  }
}
