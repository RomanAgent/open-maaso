import 'dart:async';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';

typedef AvatarSelectionPersistence =
    Future<bool> Function(String key, String? selectedId);

enum AvatarSelectionAuthorityState {
  localOnly,
  synchronizing,
  ready,
  readOnlyBundled,
}

final class AvatarRemoteModelCapabilityException implements Exception {
  const AvatarRemoteModelCapabilityException.unavailable()
    : code = 'capability_unavailable';

  const AvatarRemoteModelCapabilityException.stale()
    : code = 'capability_snapshot_stale';

  final String code;

  @override
  String toString() => code;
}

final class AvatarAuthoritativeSelectionUnavailableException
    implements Exception {
  const AvatarAuthoritativeSelectionUnavailableException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class AvatarAuthoritativeReconcileResult {
  const AvatarAuthoritativeReconcileResult({
    required this.appliedModelId,
    required this.serverClearRequired,
  });

  final int? appliedModelId;
  final bool serverClearRequired;
}

final class _AvatarRemoteModelCapabilityAuthority {
  const _AvatarRemoteModelCapabilityAuthority(this.snapshots, this.lease);

  final AppCapabilitySnapshotService snapshots;
  final AppCapabilitySnapshotLease lease;

  Future<void> get whenInvalidated => lease.whenInvalidated;

  bool get isCurrent => snapshots.isCurrent(lease);

  void requireCurrent() {
    try {
      snapshots.requireCurrent(lease);
    } on StateError {
      throw const AvatarRemoteModelCapabilityException.stale();
    }
  }
}

final class _CommittedRemoteAvatarSelection {
  _CommittedRemoteAvatarSelection({
    required this.identity,
    required this.remoteModelId,
    required this.authority,
    required this.fallback,
    required this.fallbackBackend,
    required this.fallbackPersistedSelectionId,
    this.persistenceMayHaveChanged = false,
    this.provisional = false,
    this.authoritativeVersion,
  });

  final Object identity;
  final int remoteModelId;
  final _AvatarRemoteModelCapabilityAuthority authority;
  final AvatarOption fallback;
  final AvatarBackendKind fallbackBackend;
  final String fallbackPersistedSelectionId;

  bool invalidated = false;
  bool serverRetirementTerminal = false;
  bool persistenceMayHaveChanged;
  bool provisional;
  int? authoritativeVersion;
  AvatarSelectionCommittedSelection? evidence;
  int pendingLocalSideEffects = 0;
  int retryAttempt = 0;
  bool retirementRequested = false;
  bool localFallbackReassertRequired = false;
  Timer? retryTimer;
  Future<void>? retirementInFlight;
}

/// One selectable avatar backend/model pair.
///
/// [modelUrl] resolves relative to the renderer asset root. [config] is handed
/// to the runtime's `loadAvatar` and can carry renderer-specific options.
class AvatarOption {
  const AvatarOption({
    required this.id,
    required this.name,
    required this.backend,
    required this.modelUrl,
    this.config = const {},
    this.previewAssetPath,
    this.previewImageUrl,
    this.isDefault = false,
    this.remoteModelId,
    this.modelSource = 'bundled',
    this.voiceGender = AvatarVoiceGender.unspecified,
    this.preferredVoiceSid,
  });

  final String id;
  final String name;
  final AvatarBackendKind backend;
  final String modelUrl;
  final Map<String, dynamic> config;

  /// Store artwork shipped with the app. Remote catalog entries usually use
  /// [previewImageUrl] instead, while official bundled models can use either.
  final String? previewAssetPath;

  /// HTTPS thumbnail generated for a reviewed model by the catalog service.
  /// This image is presentation-only and is never handed to the Unity runtime.
  final String? previewImageUrl;

  /// Stable server-side ID for a reviewed community model. Built-in options
  /// intentionally leave this null and never require a network selection.
  final int? remoteModelId;

  final String modelSource;

  /// Explicit voice presentation assigned by the reviewed model descriptor.
  /// Unknown uploaded models keep the user's current voice.
  final AvatarVoiceGender voiceGender;

  /// Optional preferred Supertonic voice within [voiceGender]'s SID range.
  final int? preferredVoiceSid;

  /// True for the model the engine loads on its own at boot (no swap needed).
  final bool isDefault;

  bool get isRetiredOfficial => BundledAvatarContract.isRetiredOfficial(
    modelKey: config['modelKey']?.toString() ?? '',
    modelSource: modelSource,
    assetUrl: modelUrl,
  );

  bool get isTrustedBundledMatt =>
      !isRetiredOfficial &&
      BundledAvatarContract.isMatt(
        modelId: remoteModelId,
        modelKey: config['modelKey']?.toString() ?? '',
        modelSource: modelSource,
        assetUrl: modelUrl,
        assetSha256: config['approvedAssetSha256']?.toString(),
        runtimeConfig: config,
      );
}

/// Holds the catalog of available avatars and the user's current selection,
/// persists the choice, and drives the active avatar runtime.
///
class AvatarConfigService extends AppService {
  static const _legacyPrefsKey = 'avatar.selected_id';

  /// Built-in bundled avatars.  The first/`isDefault` one is what the engine
  /// loads at boot, so selecting it needs no swap.
  static const builtInCatalog = <AvatarOption>[
    AvatarOption(
      id: 'agent',
      name: 'Agent',
      backend: AvatarBackendKind.unity,
      modelUrl: 'unity://masso/avatar_agent',
      config: {
        'scene': 'MaasoAvatar/Scenes/Companion',
        'avatar': 'agent',
        'background': 'transparent',
        'framing': 'front_full_body',
      },
      previewAssetPath: 'assets/model_store/agent.png',
      isDefault: true,
      voiceGender: AvatarVoiceGender.female,
      preferredVoiceSid: AvatarVoiceService.defaultFemaleSid,
    ),
  ];

  AvatarConfigService({
    List<AvatarOption>? initialCatalog,
    AvatarVoiceService? voicePreferences,
    String storageKeyPrefix = '',
    AppCapabilitySnapshotService? capabilitySnapshots,
    AvatarSelectionPersistence? persistSelection,
    AvatarSelectionCoordinator? selectionCoordinator,
    this.selectionAssetOptions = const AvatarSelectionAssetOptions.none(),
  }) : voicePreferences =
           (voicePreferences ??
                   AvatarVoiceService(storageKeyPrefix: storageKeyPrefix))
               .init(),
       _storageKeyPrefix = storageKeyPrefix.trim(),
       _injectedCapabilitySnapshots = capabilitySnapshots,
       _persistSelection = persistSelection ?? _persistWithSpUtils,
       _selectionCoordinator = selectionCoordinator,
       selectionAuthorityState =
           (selectionCoordinator == null
                   ? AvatarSelectionAuthorityState.localOnly
                   : AvatarSelectionAuthorityState.synchronizing)
               .obs,
       catalog = List<AvatarOption>.of(initialCatalog ?? builtInCatalog).obs;

  static final Set<AppCapabilityKey> remoteModelCapabilityKeys =
      Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
        AppCapabilityKey.platformAction(AppActionCapability.unityAvatar),
        AppCapabilityKey.platformAction(
          AppActionCapability.remoteUnityAvatarAssets,
        ),
      });

  /// The bundled catalog plus any approved remote model descriptors.
  final RxList<AvatarOption> catalog;
  final AvatarVoiceService voicePreferences;
  final String _storageKeyPrefix;
  final AppCapabilitySnapshotService? _injectedCapabilitySnapshots;
  final AvatarSelectionPersistence _persistSelection;
  final AvatarSelectionCoordinator? _selectionCoordinator;
  final AvatarSelectionAssetOptions selectionAssetOptions;
  final Rx<AvatarSelectionAuthorityState> selectionAuthorityState;

  String get _prefsKey => _storageKeyPrefix.isEmpty
      ? _legacyPrefsKey
      : '$_storageKeyPrefix.preferences.$_legacyPrefsKey';

  final RxString selectedId = 'agent'.obs;
  final isSwitching = false.obs;

  /// True only after the current selection has been loaded into this runtime
  /// and, for account-scoped selection, reconciled with the server.
  final RxBool selectionDisplayReady = false.obs;

  /// Advances when a different selected model first becomes displayable.
  /// Reapplying the same model does not replay Home's entrance animation.
  final RxInt selectionDisplayGeneration = 0.obs;
  AvatarOption? _retainedSelectedOption;
  String? _loadedDisplayOptionId;
  AvatarRuntime? _loadedDisplayRuntime;
  int? _loadedDisplayModelEpoch;
  Worker? _displayRuntimeReadyWorker;
  String? _lastDisplayOptionId;
  int _displayLoadEpoch = 0;
  Future<void> _displayHideReceipt = Future<void>.value();
  int _displayHideRevision = 0;
  bool _displayHidePending = false;
  bool _displayHideFailed = false;
  Future<void>? _displayReadyRecovery;
  String _persistedSelectionId = '';
  bool _selectionCommittedSinceInit = false;
  Object? _activeInitialApplyIdentity;
  Object? _activeSwitchIdentity;
  _CommittedRemoteAvatarSelection? _committedRemoteSelection;
  final Set<Future<void>> _inFlightLocalOperations = <Future<void>>{};
  bool _sealed = false;
  bool _closed = false;

  AvatarOption get selected =>
      catalog.firstWhereOrNull((a) => a.id == selectedId.value) ??
      (_retainedSelectedOption?.id == selectedId.value
          ? _retainedSelectedOption
          : null) ??
      catalog.first;

  /// Synchronous presentation fence used at build time as well as by the
  /// readiness listener. It rejects a stale ready value on the very frame
  /// that Unity invalidates its native model load epoch.
  bool get selectionDisplayCurrent =>
      selectionDisplayReady.value && _canPublishDisplayReady();

  int _invalidateDisplayLoad() {
    selectionDisplayReady.value = false;
    _displayRuntimeReadyWorker?.dispose();
    _displayRuntimeReadyWorker = null;
    _loadedDisplayOptionId = null;
    _loadedDisplayRuntime = null;
    _loadedDisplayModelEpoch = null;
    _queueDisplayHide();
    return ++_displayLoadEpoch;
  }

  void _queueDisplayHide() {
    final revision = ++_displayHideRevision;
    _displayHidePending = true;
    final active = appServices.maybeFind<ActiveAvatarRuntime>();
    _displayHideReceipt = _displayHideReceipt
        // A later hide is an explicit retry after an earlier failed receipt.
        .catchError((Object _, StackTrace _) {})
        .then((_) => active?.setLocalAvatarVisible(false));
    unawaited(
      _displayHideReceipt.then<void>(
        (_) {
          if (revision != _displayHideRevision) return;
          _displayHidePending = false;
          _displayHideFailed = false;
          _publishDisplayReady();
        },
        onError: (Object error, StackTrace _) {
          if (revision != _displayHideRevision) return;
          _displayHidePending = false;
          _displayHideFailed = true;
          selectionDisplayReady.value = false;
          _logAvatarFailure('🎭 [AvatarSwitch] native hide failed', error);
        },
      ),
    );
  }

  void _recordDisplayLoad(
    int epoch,
    AvatarOption option,
    AvatarRuntime runtime,
  ) {
    if (_closed || _sealed || epoch != _displayLoadEpoch) return;
    _loadedDisplayOptionId = option.id;
    _loadedDisplayRuntime = runtime;
    _loadedDisplayModelEpoch = runtime.modelLoadEpoch;
    _displayRuntimeReadyWorker?.dispose();
    _displayRuntimeReadyWorker = runtime.isReady.listen((ready) {
      if (_closed || !identical(_loadedDisplayRuntime, runtime)) return;
      if (!ready) {
        selectionDisplayReady.value = false;
        _queueDisplayHide();
      } else if (_loadedDisplayModelEpoch != runtime.modelLoadEpoch) {
        _invalidateDisplayLoad();
      } else {
        _publishDisplayReady();
      }
    });
    _publishDisplayReady();
  }

  void _publishDisplayReady() {
    if (!_canPublishDisplayReady()) return;
    if (_lastDisplayOptionId != selectedId.value) {
      _lastDisplayOptionId = selectedId.value;
      selectionDisplayGeneration.value++;
    }
    selectionDisplayReady.value = true;
  }

  bool _canPublishDisplayReady() {
    if (_closed ||
        _sealed ||
        _displayHidePending ||
        _displayHideFailed ||
        isSwitching.value ||
        (usesAuthoritativeSelection &&
            selectionAuthorityState.value !=
                AvatarSelectionAuthorityState.ready) ||
        (_committedRemoteSelection?.invalidated == true &&
            selected.remoteModelId != null) ||
        _loadedDisplayOptionId != selectedId.value ||
        !identical(_loadedDisplayRuntime, _active.current) ||
        _loadedDisplayRuntime?.isReady.value != true ||
        _loadedDisplayModelEpoch != _loadedDisplayRuntime?.modelLoadEpoch) {
      return false;
    }
    return true;
  }

  AppCapabilitySnapshotService? get capabilitySnapshots =>
      _injectedCapabilitySnapshots ??
      appServices.maybeFind<AppCapabilitySnapshotService>();

  bool get _remoteModelCapabilityAvailable {
    final snapshots = capabilitySnapshots;
    if (snapshots == null) return true;
    if (snapshots.isClosed) return false;
    return snapshots.value
        .rejected(remoteModelCapabilityKeys, requireVisible: true)
        .isEmpty;
  }

  bool get remoteModelSelectionAvailable {
    if (usesAuthoritativeSelection &&
        selectionAuthorityState.value != AvatarSelectionAuthorityState.ready) {
      return false;
    }
    return _remoteModelCapabilityAvailable;
  }

  bool canSelectOption(AvatarOption option) {
    if (option.isRetiredOfficial) return false;
    if (option.remoteModelId == null) return true;
    if (usesAuthoritativeSelection &&
        selectionAuthorityState.value != AvatarSelectionAuthorityState.ready) {
      return false;
    }
    return _modelCapabilityAvailable(option);
  }

  bool _modelCapabilityAvailable(AvatarOption option) {
    if (option.isRetiredOfficial) return false;
    final snapshots = capabilitySnapshots;
    if (snapshots == null) return true;
    if (snapshots.isClosed) return false;
    return snapshots.value
        .rejected(_modelCapabilityKeys(option), requireVisible: true)
        .isEmpty;
  }

  Set<AppCapabilityKey> _modelCapabilityKeys(AvatarOption option) =>
      option.isTrustedBundledMatt
      ? {AppCapabilityKey.platformAction(AppActionCapability.unityAvatar)}
      : remoteModelCapabilityKeys;

  AvatarSelectionCoordinator? get selectionCoordinator => _selectionCoordinator;

  bool get usesAuthoritativeSelection => _selectionCoordinator != null;

  void beginAuthoritativeSelectionStartup() {
    if (!usesAuthoritativeSelection || _closed) return;
    _invalidateDisplayLoad();
    selectionAuthorityState.value = AvatarSelectionAuthorityState.synchronizing;
  }

  void markAuthoritativeSelectionReady() {
    if (!usesAuthoritativeSelection || _closed) return;
    if (selectionAuthorityState.value !=
        AvatarSelectionAuthorityState.synchronizing) {
      return;
    }
    selectionAuthorityState.value = AvatarSelectionAuthorityState.ready;
    _publishDisplayReady();
  }

  void markAuthoritativeSelectionReadOnly() {
    if (!usesAuthoritativeSelection || _closed) return;
    _invalidateDisplayLoad();
    selectionAuthorityState.value =
        AvatarSelectionAuthorityState.readOnlyBundled;
    _publishDisplayReady();
  }

  AvatarConfigService init() {
    catalog.removeWhere((option) => option.isRetiredOfficial);
    if (catalog.isEmpty) catalog.addAll(builtInCatalog);
    final saved = SpUtils.getString(_prefsKey);
    _persistedSelectionId = saved;
    final savedOption = catalog.firstWhereOrNull(
      (option) => option.id == saved,
    );
    if (savedOption != null &&
        (!usesAuthoritativeSelection || savedOption.remoteModelId == null)) {
      selectedId.value = savedOption.id;
    }
    if (appServices.isRegistered<ActiveAvatarRuntime>()) {
      _active.select(selected.backend);
    }
    _scheduleVoiceFor(selected);
    _logStartupSelection();
    return this;
  }

  /// Apply the persisted selection once the renderer is ready.
  Future<void> applyInitial() => applyForBackend(selected.backend);

  /// Reapply the selected model after a native renderer becomes ready again.
  /// Account startup owns reconciliation while authority is still loading;
  /// ready callbacks from overlapping Login/Home views share one recovery.
  Future<void> ensureSelectedDisplayReady() {
    if (_closed || _sealed) return Future<void>.value();
    final pending = _displayReadyRecovery;
    if (pending != null) return pending;
    if (selectionDisplayCurrent ||
        isSwitching.value ||
        (usesAuthoritativeSelection &&
            selectionAuthorityState.value !=
                AvatarSelectionAuthorityState.ready)) {
      return Future<void>.value();
    }
    final renderer = _active.current;
    if (renderer == null ||
        !renderer.isReady.value ||
        renderer.backendKind != selected.backend) {
      return Future<void>.value();
    }
    final recovery = applyForBackend(renderer.backendKind);
    _displayReadyRecovery = recovery;
    recovery.then<void>(
      (_) {
        if (identical(_displayReadyRecovery, recovery)) {
          _displayReadyRecovery = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_displayReadyRecovery, recovery)) {
          _displayReadyRecovery = null;
        }
      },
    );
    return recovery;
  }

  /// Apply the persisted selection only when the renderer that just became
  /// ready matches the selected backend.
  Future<void> applyForBackend(AvatarBackendKind backend) async {
    if (_closed || _sealed) return;
    final a = selected;
    if (a.backend != backend) return;
    if (isSwitching.value) return;
    final currentRuntime = _active.current;
    if (selectionDisplayReady.value &&
        _loadedDisplayOptionId == a.id &&
        identical(_loadedDisplayRuntime, currentRuntime) &&
        _loadedDisplayModelEpoch == currentRuntime?.modelLoadEpoch &&
        currentRuntime?.isReady.value == true) {
      return;
    }
    final shouldLoad = a.backend == AvatarBackendKind.unity || !a.isDefault;
    if (a.remoteModelId == null) {
      final displayEpoch = _invalidateDisplayLoad();
      await _displayHideReceipt;
      _activeInitialApplyIdentity = null;
      final remoteSelection = _committedRemoteSelection;
      if (remoteSelection?.invalidated != true) {
        _releaseRemoteSelection(remoteSelection);
      }
      _active.select(backend);
      final runtime = _active.current;
      if (runtime != null && shouldLoad) {
        await _startTrackedLocalOperation(
          () => runtime.loadAvatar(a.modelUrl, a.config),
        );
        _recordDisplayLoad(displayEpoch, a, runtime);
      }
      return;
    }

    final fallbackRecord = _committedRemoteSelection;
    final fallback = fallbackRecord?.fallback ?? _defaultOption;
    final fallbackBackend = fallbackRecord?.fallbackBackend ?? fallback.backend;
    final fallbackPersistedSelectionId =
        fallbackRecord?.fallbackPersistedSelectionId ?? '';
    final reusableSelection =
        fallbackRecord != null &&
            fallbackRecord.remoteModelId == a.remoteModelId &&
            !fallbackRecord.invalidated &&
            !fallbackRecord.serverRetirementTerminal
        ? fallbackRecord
        : null;
    final identity = reusableSelection?.identity ?? Object();
    _activeInitialApplyIdentity = identity;
    _beginSwitch(identity);
    final displayEpoch = _displayLoadEpoch;
    _CommittedRemoteAvatarSelection? remoteSelection;
    try {
      await _displayHideReceipt;
      remoteSelection = reusableSelection;
      final authority = remoteSelection == null
          ? _acquireRemoteModelAuthority(a)
          : null;
      if (remoteSelection == null && authority != null) {
        remoteSelection = _CommittedRemoteAvatarSelection(
          identity: identity,
          remoteModelId: a.remoteModelId!,
          authority: authority,
          fallback: fallback,
          fallbackBackend: fallbackBackend,
          fallbackPersistedSelectionId: fallbackPersistedSelectionId,
          persistenceMayHaveChanged: true,
        );
        _replaceRemoteSelection(remoteSelection);
        _watchRemoteSelection(remoteSelection);
      }
      if (remoteSelection != null) {
        _requireRemoteSelectionCurrent(remoteSelection);
      }
      _active.select(backend);
      if (remoteSelection != null) {
        _requireRemoteSelectionCurrent(remoteSelection);
      }
      final runtime = _active.current;
      if (runtime != null && shouldLoad) {
        if (remoteSelection == null) {
          await _startTrackedLocalOperation(
            () => runtime.loadAvatar(a.modelUrl, a.config),
          );
        } else {
          await _runRemoteOperation<void>(
            remoteSelection,
            () => runtime.loadAvatar(a.modelUrl, a.config),
            tracksLocalSideEffect: true,
          );
        }
        _recordDisplayLoad(displayEpoch, a, runtime);
      }
      if (!identical(_activeInitialApplyIdentity, identity) || _closed) {
        return;
      }
    } catch (error, stackTrace) {
      if (remoteSelection?.invalidated != true &&
          identical(_activeInitialApplyIdentity, identity) &&
          !_closed) {
        if (!identical(remoteSelection, reusableSelection)) {
          _releaseRemoteSelection(remoteSelection);
        }
        try {
          await _restoreRemoteSelectionFallback(
            fallback,
            fallbackBackend,
            fallbackPersistedSelectionId,
          );
        } catch (cleanupError) {
          _logAvatarFailure(
            '🎭 [AvatarSwitch] initial remote fallback failed',
            cleanupError,
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (identical(_activeInitialApplyIdentity, identity)) {
        _activeInitialApplyIdentity = null;
      }
      if (remoteSelection?.invalidated != true) {
        _finishSwitch(identity);
      }
    }
  }

  /// Replaces the reviewed portion of the picker with the latest server
  /// descriptors while preserving all bundled choices.
  bool replaceReviewedOptions(
    Iterable<AvatarOption> reviewed, {
    bool restorePersistedSelection = true,
  }) {
    if (_closed || _sealed) return false;
    final remoteById = <int, AvatarOption>{
      for (final option in reviewed)
        if (option.remoteModelId != null && !option.isRetiredOfficial)
          option.remoteModelId!: option,
    };
    final current = selected;
    final remoteOwner = _committedRemoteSelection;
    // A catalog listing is not the authority for an already committed
    // account selection. A partial refresh must not silently turn Matt into
    // the bundled Agent; the selection endpoint or capability lease decides
    // whether that model must actually be retired.
    _retainedSelectedOption =
        usesAuthoritativeSelection &&
            current.remoteModelId != null &&
            !current.isRetiredOfficial &&
            !remoteById.containsKey(current.remoteModelId) &&
            remoteOwner?.remoteModelId == current.remoteModelId &&
            remoteOwner?.invalidated == false &&
            remoteOwner?.authority.isCurrent == true
        ? current
        : null;
    final bundled = catalog.where((option) => option.remoteModelId == null);
    catalog.assignAll([...bundled, ...remoteById.values]);

    if (restorePersistedSelection &&
        !usesAuthoritativeSelection &&
        !_selectionCommittedSinceInit &&
        _persistedSelectionId.isNotEmpty &&
        catalog.any((option) => option.id == _persistedSelectionId)) {
      selectedId.value = _persistedSelectionId;
      _scheduleVoiceFor(selected);
      return true;
    }
    if (catalog.any((option) => option.id == selectedId.value)) {
      _scheduleVoiceFor(selected);
      return false;
    }
    if (_retainedSelectedOption?.id == selectedId.value) {
      return false;
    }
    _invalidateDisplayLoad();
    selectedId.value =
        catalog.firstWhereOrNull((option) => option.isDefault)?.id ??
        catalog.first.id;
    _scheduleVoiceFor(selected);
    return false;
  }

  bool canReconcileAuthoritative(AvatarSelectionSnapshot snapshot) {
    if (snapshot.asset.isRetiredOfficial) return false;
    if (snapshot.requiresUninstalledBundledMatt) return true;
    final modelId = snapshot.selection.modelId;
    if (modelId == null) return snapshot.selectionAvailable;
    if (!snapshot.selectionAvailable) {
      return false;
    }
    return catalog.any(
      (option) =>
          option.remoteModelId == modelId && _modelCapabilityAvailable(option),
    );
  }

  /// Converges renderer and local preference state to one proven server
  /// snapshot. This method performs no network request and is safe to call
  /// from [AvatarSelectionLocalPhases].
  Future<AvatarAuthoritativeReconcileResult> reconcileAuthoritative(
    AvatarSelectionSnapshot snapshot, {
    bool fallbackToBundled = false,
  }) async {
    if (_closed || _sealed) {
      throw StateError('Avatar configuration is inactive');
    }
    final resolved = _resolveAuthoritativeTarget(
      snapshot,
      fallbackToBundled: fallbackToBundled,
    );
    await _commitAuthoritativeLocally(
      resolved.target,
      authoritativeVersion: snapshot.selection.version,
    );
    return AvatarAuthoritativeReconcileResult(
      appliedModelId: resolved.target.remoteModelId,
      serverClearRequired: resolved.serverClearRequired,
    );
  }

  ({AvatarOption target, bool serverClearRequired}) _resolveAuthoritativeTarget(
    AvatarSelectionSnapshot snapshot, {
    required bool fallbackToBundled,
  }) {
    if (snapshot.asset.isRetiredOfficial) {
      // Retired products must converge the durable preference and server head
      // to Joy, including old applied receipts. Do not treat this as a missing
      // installation that preserves a desired model forever.
      return (
        target: _defaultOption,
        serverClearRequired: snapshot.selection.modelId != null,
      );
    }
    if (snapshot.requiresUninstalledBundledMatt) {
      // An exact historical revision is still the user's desired model. Do
      // not clear that server selection or pretend the current prefab has its
      // old digest. Only the local display falls back to the bundled default.
      return (target: _defaultOption, serverClearRequired: false);
    }
    final modelId = snapshot.selection.modelId;
    var serverClearRequired = false;
    AvatarOption? target;
    if (modelId == null && snapshot.selectionAvailable) {
      target = _defaultOption;
    } else if (modelId != null && snapshot.selectionAvailable) {
      target = catalog.firstWhereOrNull(
        (option) =>
            option.remoteModelId == modelId &&
            _modelCapabilityAvailable(option),
      );
    }

    if (target == null) {
      if (!fallbackToBundled) {
        throw const AvatarAuthoritativeSelectionUnavailableException(
          'avatar_authoritative_selection_unavailable',
        );
      }
      target = _defaultOption;
      serverClearRequired = modelId != null;
    }
    return (target: target, serverClearRequired: serverClearRequired);
  }

  /// Makes the renderer safe while server reconciliation is pending. It does
  /// not alter selected ID, voice, or preferences.
  Future<void> previewBundledFallback() async {
    if (_closed || _sealed) {
      throw StateError('Avatar configuration is inactive');
    }
    final displayEpoch = _invalidateDisplayLoad();
    await _displayHideReceipt;
    final fallback = _defaultOption;
    _active.select(fallback.backend);
    final runtime = _active.current;
    if (runtime != null) {
      await _startTrackedLocalOperation(
        () => runtime.loadAvatar(fallback.modelUrl, fallback.config),
      );
      _recordDisplayLoad(displayEpoch, fallback, runtime);
    }
  }

  Future<void> _commitAuthoritativeLocally(
    AvatarOption target, {
    bool withinSelectionTransaction = false,
    bool skipRendererLoad = false,
    Object? selectionIdentity,
    bool deferRemoteRetirement = false,
    bool reuseMatchingRemoteSelection = false,
    int? authoritativeVersion,
  }) async {
    if (_closed || _sealed) {
      throw StateError('Avatar configuration is closed');
    }
    if (isSwitching.value && !withinSelectionTransaction) {
      throw StateError('An avatar switch is already in progress');
    }

    final previous = selected;
    final previousBackend = _active.backend.value;
    final previousPersistedSelectionId = _persistedSelectionId;
    final previousCommittedRemote = _committedRemoteSelection;
    final identity = selectionIdentity ?? Object();
    final reusableRemoteSelection =
        reuseMatchingRemoteSelection &&
            target.remoteModelId != null &&
            previousCommittedRemote != null &&
            previousCommittedRemote.remoteModelId == target.remoteModelId &&
            !previousCommittedRemote.invalidated &&
            !previousCommittedRemote.serverRetirementTerminal
        ? previousCommittedRemote
        : null;
    final authority =
        target.remoteModelId == null || reusableRemoteSelection != null
        ? null
        : _acquireRemoteModelAuthority(target);
    final remoteSelection = authority == null
        ? reusableRemoteSelection
        : _CommittedRemoteAvatarSelection(
            identity: identity,
            remoteModelId: target.remoteModelId!,
            authority: authority,
            fallback: _defaultOption,
            fallbackBackend: _defaultOption.backend,
            fallbackPersistedSelectionId: '',
            provisional: true,
            authoritativeVersion: authoritativeVersion,
          );
    _activeInitialApplyIdentity = null;
    if (!withinSelectionTransaction) {
      _beginSwitch(identity);
    }
    final displayEpoch = _displayLoadEpoch;
    if (remoteSelection == null) {
      final preserveRetiringOwner =
          previousCommittedRemote != null &&
          (previousCommittedRemote.invalidated ||
              previousCommittedRemote.pendingLocalSideEffects > 0 ||
              previousCommittedRemote.serverRetirementTerminal);
      if (!preserveRetiringOwner) {
        _releaseRemoteSelection(previousCommittedRemote);
      }
    } else if (!identical(remoteSelection, previousCommittedRemote)) {
      _replaceRemoteSelection(remoteSelection);
    }

    var persistenceMayHaveChanged = false;
    var watchRemoteAfterCommit = false;
    try {
      await _displayHideReceipt;
      if (remoteSelection != null) {
        _requireRemoteSelectionCurrent(remoteSelection);
      }
      _active.select(target.backend);
      final runtime = _active.current;
      if (runtime != null && !skipRendererLoad) {
        await _startTrackedLocalOperation(
          () => runtime.loadAvatar(target.modelUrl, target.config),
        );
        _recordDisplayLoad(displayEpoch, target, runtime);
      }
      if (remoteSelection != null) {
        _requireRemoteSelectionCurrent(remoteSelection);
      }

      persistenceMayHaveChanged = true;
      final persistedId = target.remoteModelId == null ? null : target.id;
      final persisted = await _startTrackedLocalOperation(
        () => _persistSelection(_prefsKey, persistedId),
      );
      if (!persisted) {
        throw StateError('Could not save the authoritative avatar model');
      }
      if (remoteSelection != null) {
        remoteSelection.persistenceMayHaveChanged = true;
        _requireRemoteSelectionCurrent(remoteSelection);
      }

      _persistedSelectionId = persistedId ?? '';
      _selectionCommittedSinceInit = true;
      selectedId.value = target.id;
      if (_retainedSelectedOption?.id != target.id) {
        _retainedSelectedOption = null;
      }
      if (remoteSelection != null) {
        remoteSelection.provisional = deferRemoteRetirement;
        watchRemoteAfterCommit = true;
      }
      try {
        await _applyVoiceFor(target);
      } catch (error) {
        _logAvatarFailure(
          '🎭 [AvatarSwitch] authoritative voice apply failed',
          error,
        );
      }
    } catch (error, stackTrace) {
      if (!identical(remoteSelection, reusableRemoteSelection)) {
        _releaseRemoteSelection(remoteSelection);
      }
      if (withinSelectionTransaction) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      var rollback = previous;
      var rollbackBackend = previousBackend;
      var rollbackPersistedSelectionId = previousPersistedSelectionId;
      final canRestorePreviousRemote =
          previous.remoteModelId == null ||
          previousCommittedRemote?.authority.isCurrent == true;
      if (!canRestorePreviousRemote) {
        rollback = _defaultOption;
        rollbackBackend = rollback.backend;
        rollbackPersistedSelectionId = '';
      }
      await _restore(rollback, rollbackBackend);
      if (persistenceMayHaveChanged || rollback.id != previous.id) {
        await _restorePersistedSelection(rollbackPersistedSelectionId);
      }
      _persistedSelectionId = rollbackPersistedSelectionId;
      selectedId.value = rollback.id;
      if (rollback.id == previous.id &&
          previousCommittedRemote != null &&
          previousCommittedRemote.authority.isCurrent) {
        _replaceRemoteSelection(previousCommittedRemote);
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      if (!withinSelectionTransaction) {
        _finishSwitch(identity);
      }
    }
    if (watchRemoteAfterCommit && remoteSelection != null) {
      _watchRemoteSelection(remoteSelection);
      if (remoteSelection.invalidated) {
        _requestRemoteSelectionRetirement(remoteSelection);
      }
    }
  }

  /// User picked an avatar in the config page — hot-swap before persisting.
  ///
  /// A failed renderer load leaves the existing avatar and saved selection
  /// intact, so every surface continues showing the known-good model.
  Future<void> select(String id, {String? expectedAssetVersionDigest}) async {
    if (_closed || _sealed) {
      throw StateError('Avatar configuration is inactive');
    }
    final a = catalog.firstWhereOrNull((x) => x.id == id);
    if (a == null) return;
    if (a.isRetiredOfficial) {
      throw const AvatarAuthoritativeSelectionUnavailableException(
        'avatar_model_retired',
      );
    }
    final coordinator = _selectionCoordinator;
    if (coordinator != null) {
      await _selectAuthoritatively(
        a,
        coordinator,
        expectedAssetVersionDigest: expectedAssetVersionDigest,
      );
      return;
    }
    if (a.remoteModelId != null || expectedAssetVersionDigest != null) {
      throw const AvatarAuthoritativeSelectionUnavailableException(
        'avatar_selection_coordinator_required',
      );
    }
    if (a.id == selectedId.value) return;
    if (isSwitching.value) {
      throw StateError('An avatar switch is already in progress');
    }
    if (_committedRemoteSelection?.invalidated == true) {
      throw StateError('The revoked avatar selection is still being retired');
    }

    final previous = selected;
    final previousBackend = _active.backend.value;
    final previousPersistedSelectionId = _persistedSelectionId;
    final previousCommittedRemote = _committedRemoteSelection;
    final safeFallback = previous.remoteModelId == null
        ? previous
        : previousCommittedRemote?.fallback ?? _defaultOption;
    final safeFallbackBackend = previous.remoteModelId == null
        ? previousBackend
        : previousCommittedRemote?.fallbackBackend ?? safeFallback.backend;
    final safeFallbackPersistedSelectionId = previous.remoteModelId == null
        ? previousPersistedSelectionId
        : previousCommittedRemote?.fallbackPersistedSelectionId ?? '';
    final identity = Object();
    _activeInitialApplyIdentity = null;
    var stage = 'runtime_load';
    var persistenceMayHaveChanged = false;
    _beginSwitch(identity);
    final displayEpoch = _displayLoadEpoch;
    _releaseRemoteSelection(previousCommittedRemote);
    Log.i(
      '🎭 [AvatarSwitch] start previousRemote='
      '${previous.remoteModelId != null} targetRemote=${a.remoteModelId != null}',
    );
    try {
      await _displayHideReceipt;
      _active.select(a.backend);
      final runtime = _active.current;
      if (runtime != null) {
        await _startTrackedLocalOperation(
          () => runtime.loadAvatar(a.modelUrl, a.config),
        );
        _recordDisplayLoad(displayEpoch, a, runtime);
      }
      Log.i('🎭 [AvatarSwitch] runtime loaded');
      stage = 'persist';
      persistenceMayHaveChanged = true;
      final persisted = await _startTrackedLocalOperation(
        () => _persistSelection(_prefsKey, id),
      );
      if (!persisted) {
        throw StateError('Could not save the selected avatar model');
      }
      _persistedSelectionId = id;
      _selectionCommittedSinceInit = true;
      selectedId.value = id;
      if (_retainedSelectedOption?.id != id) {
        _retainedSelectedOption = null;
      }
      Log.i('🎭 [AvatarSwitch] committed');
      try {
        await _applyVoiceFor(a);
      } catch (error) {
        // Voice is a secondary preference. A transient persistence failure
        // must not roll back an already loaded and persisted local avatar.
        _logAvatarFailure('🎭 [AvatarSwitch] voice apply failed', error);
      }
    } catch (error) {
      _logAvatarFailure(
        '🎭 [AvatarSwitch] failed stage=$stage '
        'previousRemote=${previous.remoteModelId != null} '
        'targetRemote=${a.remoteModelId != null}',
        error,
      );
      var rollback = previous;
      var rollbackBackend = previousBackend;
      var rollbackPersistedSelectionId = previousPersistedSelectionId;
      final canRestorePreviousRemote =
          previous.remoteModelId == null ||
          previousCommittedRemote?.authority.isCurrent == true;
      if (!canRestorePreviousRemote) {
        rollback = safeFallback;
        rollbackBackend = safeFallbackBackend;
        rollbackPersistedSelectionId = safeFallbackPersistedSelectionId;
      }
      await _restore(rollback, rollbackBackend);
      if (persistenceMayHaveChanged || rollback.id != previous.id) {
        await _restorePersistedSelection(rollbackPersistedSelectionId);
      }
      _persistedSelectionId = rollbackPersistedSelectionId;
      selectedId.value = rollback.id;
      if (rollback.id == previous.id &&
          previousCommittedRemote != null &&
          previousCommittedRemote.authority.isCurrent) {
        _replaceRemoteSelection(previousCommittedRemote);
      }
      Log.w(
        '🎭 [AvatarSwitch] restored previous after failure stage=$stage '
        'remote=${rollback.remoteModelId != null}',
      );
      rethrow;
    } finally {
      _finishSwitch(identity);
    }
  }

  Future<void> _selectAuthoritatively(
    AvatarOption target,
    AvatarSelectionCoordinator coordinator, {
    String? expectedAssetVersionDigest,
  }) async {
    if (selectionAuthorityState.value != AvatarSelectionAuthorityState.ready) {
      throw const AvatarAuthoritativeSelectionUnavailableException(
        'avatar_selection_contract_not_ready',
      );
    }
    if (isSwitching.value) {
      throw StateError('An avatar switch is already in progress');
    }
    if (_committedRemoteSelection?.invalidated == true) {
      throw StateError('The revoked avatar selection is still being retired');
    }

    final previewAuthority = target.remoteModelId == null
        ? null
        : _acquireRemoteModelAuthority(target);
    var previewAuthorityInvalidated = false;
    if (previewAuthority != null) {
      unawaited(
        previewAuthority.whenInvalidated.then<void>((_) {
          previewAuthorityInvalidated = true;
        }),
      );
    }

    final previous = selected;
    final previousCommittedRemote = _committedRemoteSelection;
    final identity = Object();
    _activeInitialApplyIdentity = null;
    if (previousCommittedRemote != null) {
      // Keep the proven previous owner and its revocation watcher alive until
      // a local commit/restore actually replaces it. Coordinator preflight can
      // fail before any local phase when a durable obligation is outstanding.
      previousCommittedRemote.provisional = true;
    }
    _beginSwitch(identity);
    final displayEpoch = _displayLoadEpoch;
    var serverClearRequired = false;
    Log.i(
      '🎭 [AvatarSelectionV2] start previousRemote='
      '${previous.remoteModelId != null} targetRemote='
      '${target.remoteModelId != null}',
    );
    try {
      await _displayHideReceipt;
      final committed = await coordinator.commit(
        modelId: target.remoteModelId,
        assetOptions: selectionAssetOptions,
        expectedAssetVersionDigest: expectedAssetVersionDigest,
        local: AvatarSelectionLocalPhases(
          preview: () async {
            previewAuthority?.requireCurrent();
            await _displayHideReceipt;
            _active.select(target.backend);
            final runtime = _active.current;
            if (runtime != null) {
              await _startTrackedLocalOperation(
                () => runtime.loadAvatar(target.modelUrl, target.config),
              );
              _recordDisplayLoad(displayEpoch, target, runtime);
            }
            previewAuthority?.requireCurrent();
          },
          shouldCompensate: (_) =>
              _closed ||
              !identical(_activeSwitchIdentity, identity) ||
              (previewAuthority != null &&
                  (previewAuthorityInvalidated || !previewAuthority.isCurrent)),
          commit: (snapshot) async {
            if (snapshot.selection.modelId != target.remoteModelId) {
              throw const FormatException(
                'avatar_selection_commit_target_mismatch',
              );
            }
            final resolved = _resolveAuthoritativeTarget(
              snapshot,
              fallbackToBundled: false,
            );
            if (resolved.target.id != target.id) {
              throw const FormatException(
                'avatar_selection_catalog_target_mismatch',
              );
            }
            await _commitAuthoritativeLocally(
              resolved.target,
              withinSelectionTransaction: true,
              skipRendererLoad: true,
              selectionIdentity: identity,
              deferRemoteRetirement: true,
              authoritativeVersion: snapshot.selection.version,
            );
          },
          restore: (snapshot) async {
            final previousOwnerInvalidated =
                previousCommittedRemote?.invalidated == true;
            final resolved =
                previousOwnerInvalidated && snapshot.selection.modelId != null
                ? (target: _defaultOption, serverClearRequired: true)
                : _resolveAuthoritativeTarget(
                    snapshot,
                    fallbackToBundled: true,
                  );
            serverClearRequired =
                serverClearRequired || resolved.serverClearRequired;
            await _commitAuthoritativeLocally(
              resolved.target,
              withinSelectionTransaction: true,
              selectionIdentity: Object(),
              deferRemoteRetirement: true,
              reuseMatchingRemoteSelection: true,
            );
          },
        ),
      );

      if (target.remoteModelId != null) {
        final owner = _committedRemoteSelection;
        if (owner == null || !identical(owner.identity, identity)) {
          throw StateError('Avatar remote selection owner was not committed');
        }
        owner.evidence = committed;
        owner.authoritativeVersion = committed.receipt.selection.version;
        owner.provisional = false;
        if (previewAuthorityInvalidated || owner.invalidated) {
          _requestRemoteSelectionRetirement(owner);
        }
      }
      Log.i(
        '🎭 [AvatarSelectionV2] committed '
        'remote=${target.remoteModelId != null}',
      );
    } catch (error) {
      if (_isAvatarSelectionContractUnavailable(error)) {
        await _retireActiveRemoteSelectionReadOnly();
      } else if (serverClearRequired &&
          (error is AvatarSelectionCompensatedException ||
              error is AvatarSelectionLocalCommitCompensatedException)) {
        try {
          await _clearUnavailableAuthoritativeSelection(coordinator);
        } catch (clearError, clearStackTrace) {
          _logAvatarFailure(
            '🎭 [AvatarSelectionV2] bundled fallback server clear unresolved',
            clearError,
          );
          Error.throwWithStackTrace(clearError, clearStackTrace);
        }
      }
      _logAvatarFailure(
        '🎭 [AvatarSelectionV2] failed previousRemote='
        '${previous.remoteModelId != null} targetRemote='
        '${target.remoteModelId != null} '
        'serverClearRequired=$serverClearRequired',
        error,
      );
      rethrow;
    } finally {
      final owner = _committedRemoteSelection;
      if (owner?.provisional == true) {
        owner!.provisional = false;
        if (owner.invalidated) {
          _requestRemoteSelectionRetirement(owner);
        }
      }
      _finishSwitch(identity);
    }
  }

  Future<void> _clearUnavailableAuthoritativeSelection(
    AvatarSelectionCoordinator coordinator,
  ) async {
    Future<void> apply(AvatarSelectionSnapshot snapshot) async {
      final resolved = _resolveAuthoritativeTarget(
        snapshot,
        fallbackToBundled: true,
      );
      await _commitAuthoritativeLocally(
        resolved.target,
        withinSelectionTransaction: true,
        selectionIdentity: Object(),
        deferRemoteRetirement: true,
      );
    }

    try {
      await coordinator.commit(
        modelId: null,
        assetOptions: selectionAssetOptions,
        local: AvatarSelectionLocalPhases(
          preview: () => _restoreStrict(_defaultOption, _defaultOption.backend),
          commit: apply,
          restore: apply,
        ),
      );
      final owner = _committedRemoteSelection;
      if (owner?.invalidated == true) {
        _markRemoteSelectionServerRetirementTerminal(owner!);
      }
    } on AvatarSelectionVersionChangedException {
      // The coordinator already restored and published the newer current
      // snapshot. Never advance its version merely to force this stale clear.
      final owner = _committedRemoteSelection;
      if (owner?.invalidated == true) {
        _markRemoteSelectionServerRetirementTerminal(owner!);
      }
    } on Object catch (error) {
      if (!_isAvatarSelectionContractUnavailable(error)) rethrow;
      await _retireActiveRemoteSelectionReadOnly();
    }
  }

  ActiveAvatarRuntime get _active => appServices.find<ActiveAvatarRuntime>();

  AvatarOption get _defaultOption =>
      catalog.firstWhereOrNull((option) => option.isDefault) ?? catalog.first;

  _AvatarRemoteModelCapabilityAuthority? _acquireRemoteModelAuthority(
    AvatarOption option,
  ) {
    final snapshots = capabilitySnapshots;
    if (snapshots == null) return null;
    if (snapshots.isClosed) {
      throw const AvatarRemoteModelCapabilityException.unavailable();
    }
    final acquisition = snapshots.acquireLease(
      _modelCapabilityKeys(option),
      requireVisible: true,
    );
    final lease = acquisition.lease;
    if (lease == null) {
      throw const AvatarRemoteModelCapabilityException.unavailable();
    }
    return _AvatarRemoteModelCapabilityAuthority(snapshots, lease);
  }

  void _watchRemoteSelection(_CommittedRemoteAvatarSelection selection) {
    unawaited(
      selection.authority.whenInvalidated
          .then<void>((_) => _markRemoteSelectionInvalidated(selection))
          .catchError((Object error, StackTrace _) {
            _logAvatarFailure(
              '🎭 [AvatarSwitch] capability invalidation watcher failed',
              error,
            );
          }),
    );
  }

  void _markRemoteSelectionInvalidated(
    _CommittedRemoteAvatarSelection selection,
  ) {
    final wasInvalidated = selection.invalidated;
    selection.invalidated = true;
    if (!identical(_committedRemoteSelection, selection) || _closed) return;
    _invalidateDisplayLoad();
    if (identical(_activeInitialApplyIdentity, selection.identity)) {
      _activeInitialApplyIdentity = null;
    }
    if (!wasInvalidated) {
      _requestRemoteSelectionRetirement(selection);
    }
  }

  void _requireRemoteSelectionCurrent(
    _CommittedRemoteAvatarSelection selection,
  ) {
    try {
      selection.authority.requireCurrent();
    } on AvatarRemoteModelCapabilityException {
      _markRemoteSelectionInvalidated(selection);
      rethrow;
    }
  }

  Future<T> _runRemoteOperation<T>(
    _CommittedRemoteAvatarSelection selection,
    Future<T> Function() operation, {
    bool tracksLocalSideEffect = false,
  }) async {
    _requireRemoteSelectionCurrent(selection);
    if (tracksLocalSideEffect) {
      selection.pendingLocalSideEffects++;
    }
    final operationFuture = _startTrackedLocalOperation(operation);
    if (tracksLocalSideEffect) {
      unawaited(
        operationFuture.then<void>(
          (_) => _completeRemoteLocalSideEffect(selection),
          onError: (Object _, StackTrace _) {
            _completeRemoteLocalSideEffect(selection);
          },
        ),
      );
    }
    final invalidationFuture = selection.authority.whenInvalidated.then<T>((_) {
      _markRemoteSelectionInvalidated(selection);
      throw const AvatarRemoteModelCapabilityException.stale();
    });
    final result = await Future.any<T>(<Future<T>>[
      operationFuture,
      invalidationFuture,
    ]);
    _requireRemoteSelectionCurrent(selection);
    return result;
  }

  void _completeRemoteLocalSideEffect(
    _CommittedRemoteAvatarSelection selection,
  ) {
    if (selection.pendingLocalSideEffects > 0) {
      selection.pendingLocalSideEffects--;
    }
    if (selection.invalidated &&
        identical(_committedRemoteSelection, selection) &&
        !_closed) {
      selection.localFallbackReassertRequired = true;
      _requestRemoteSelectionRetirement(selection);
    }
  }

  void _requestRemoteSelectionRetirement(
    _CommittedRemoteAvatarSelection selection,
  ) {
    if (_closed ||
        _sealed ||
        !identical(_committedRemoteSelection, selection)) {
      return;
    }
    if (selection.provisional) {
      selection.retirementRequested = true;
      return;
    }
    selection.retryTimer?.cancel();
    selection.retryTimer = null;
    if (selection.retirementInFlight != null) {
      selection.retirementRequested = true;
      return;
    }
    selection.retirementRequested = false;
    final retirement = _retireRemoteSelection(selection);
    selection.retirementInFlight = retirement;
    _trackStartedLocalOperation(retirement);
    unawaited(
      retirement.then<void>(
        (_) {
          if (identical(selection.retirementInFlight, retirement)) {
            selection.retirementInFlight = null;
          }
          if (selection.retirementRequested &&
              identical(_committedRemoteSelection, selection) &&
              !_closed) {
            _requestRemoteSelectionRetirement(selection);
          }
        },
        onError: (Object error, StackTrace _) {
          if (identical(selection.retirementInFlight, retirement)) {
            selection.retirementInFlight = null;
          }
          _logAvatarFailure(
            '🎭 [AvatarSwitch] capability retirement failed',
            error,
          );
          if (selection.retirementRequested &&
              identical(_committedRemoteSelection, selection) &&
              !_closed) {
            _requestRemoteSelectionRetirement(selection);
          }
        },
      ),
    );
  }

  Future<void> _retireRemoteSelection(
    _CommittedRemoteAvatarSelection selection,
  ) {
    final coordinator = _selectionCoordinator;
    if (!selection.serverRetirementTerminal &&
        coordinator != null &&
        selectionAuthorityState.value !=
            AvatarSelectionAuthorityState.readOnlyBundled) {
      return _retireRemoteSelectionAuthoritatively(selection, coordinator);
    }
    return _retireRemoteSelectionLocally(selection);
  }

  Future<void> _retireRemoteSelectionAuthoritatively(
    _CommittedRemoteAvatarSelection selection,
    AvatarSelectionCoordinator coordinator,
  ) async {
    if (_closed || !identical(_committedRemoteSelection, selection)) return;
    _beginSwitch(selection.identity);
    var serverClearRequired = false;
    Future<void> convergeLocally(AvatarSelectionSnapshot snapshot) async {
      serverClearRequired =
          serverClearRequired || snapshot.selection.modelId != null;
      await _restoreRetiringRemoteSelectionLocalState(selection);
    }

    final local = AvatarSelectionLocalPhases(
      preview: () =>
          _restoreStrict(selection.fallback, selection.fallbackBackend),
      commit: convergeLocally,
      restore: convergeLocally,
    );

    try {
      final evidence = selection.evidence;
      AvatarSelectionSnapshot current;
      var ownsRestoredRemoteHead = false;
      if (evidence != null) {
        try {
          final retired = await coordinator.retireCommittedSelection(
            evidence,
            local: local,
          );
          current = retired.current;
          ownsRestoredRemoteHead =
              retired.outcome == AvatarSelectionRecoveryOutcome.compensated;
        } on AvatarSelectionOutboxConflictException catch (error) {
          if (error.code != 'avatar_selection_retirement_evidence_mismatch') {
            rethrow;
          }
          final recovered = await coordinator.recover(
            assetOptions: selectionAssetOptions,
            decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
            local: local,
          );
          current = recovered.current;
          ownsRestoredRemoteHead =
              recovered.outcome ==
                  AvatarSelectionRecoveryOutcome.rolledForward ||
              recovered.outcome == AvatarSelectionRecoveryOutcome.compensated ||
              (recovered.outcome ==
                      AvatarSelectionRecoveryOutcome.reconciledCurrent &&
                  _matchesRetiringRemoteHead(selection, recovered.current));
        }
      } else {
        try {
          final cleared = await coordinator.commit(
            modelId: null,
            assetOptions: selectionAssetOptions,
            local: local,
          );
          current = cleared.current;
        } on AvatarSelectionOutstandingObligationException {
          final recovered = await coordinator.recover(
            assetOptions: selectionAssetOptions,
            decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
            local: local,
          );
          current = recovered.current;
          ownsRestoredRemoteHead =
              recovered.outcome ==
                  AvatarSelectionRecoveryOutcome.rolledForward ||
              recovered.outcome == AvatarSelectionRecoveryOutcome.compensated ||
              (recovered.outcome ==
                      AvatarSelectionRecoveryOutcome.reconciledCurrent &&
                  _matchesRetiringRemoteHead(selection, recovered.current));
        }
      }

      if (serverClearRequired &&
          current.selection.modelId != null &&
          ownsRestoredRemoteHead) {
        serverClearRequired = false;
        final cleared = await coordinator.commit(
          modelId: null,
          assetOptions: selectionAssetOptions,
          local: local,
        );
        current = cleared.current;
      }
      if (current.selection.modelId != null && ownsRestoredRemoteHead) {
        throw StateError('Avatar remote selection retirement is incomplete');
      }
      _markRemoteSelectionServerRetirementTerminal(selection);
      Log.i(
        current.selection.modelId == null
            ? '🎭 [AvatarSelectionV2] retired remote selection authoritatively'
            : '🎭 [AvatarSelectionV2] retirement superseded by newer writer',
      );
    } on AvatarSelectionVersionChangedException {
      // The coordinator restored the newer current snapshot and proved that
      // this retirement no longer owns the server head. Never retry with the
      // disclosed newer version.
      _markRemoteSelectionServerRetirementTerminal(selection);
      Log.i('🎭 [AvatarSelectionV2] retirement lost CAS to newer writer');
    } catch (error) {
      if (_isAvatarSelectionContractUnavailable(error)) {
        await _retireActiveRemoteSelectionReadOnly();
        Log.w(
          '🎭 [AvatarSelectionV2] contract unavailable; '
          'switched to local-only retirement in read-only mode',
        );
        return;
      }
      if (!_closed && identical(_committedRemoteSelection, selection)) {
        _logAvatarFailure(
          '🎭 [AvatarSelectionV2] authoritative retirement failed; retrying',
          error,
        );
        _scheduleRemoteSelectionRetirementRetry(selection);
      }
    } finally {
      final owner = _committedRemoteSelection;
      var requestOwnerRetirement = false;
      if (owner?.provisional == true) {
        owner!.provisional = false;
        requestOwnerRetirement = owner.invalidated;
      }
      _finishSwitch(selection.identity);
      if (requestOwnerRetirement && owner != null) {
        _requestRemoteSelectionRetirement(owner);
      }
    }
  }

  Future<void> _retireActiveRemoteSelectionReadOnly() async {
    markAuthoritativeSelectionReadOnly();
    final activeSelection = _committedRemoteSelection;
    if (activeSelection == null) return;
    // Contract loss is a sticky local invalidation too. A tracked Unity or
    // persistence side effect can still settle after the first bundled
    // fallback; invalidated makes that completion trigger another local-only
    // convergence pass instead of leaving the late remote result active.
    activeSelection.invalidated = true;
    activeSelection.serverRetirementTerminal = true;
    activeSelection.retirementRequested = false;
    await _retireRemoteSelectionLocally(activeSelection);
  }

  Future<void> _retireRemoteSelectionLocally(
    _CommittedRemoteAvatarSelection selection,
  ) async {
    if (_closed || !identical(_committedRemoteSelection, selection)) return;
    _beginSwitch(selection.identity);
    try {
      try {
        await _restoreRetiringRemoteSelectionLocalState(selection);
        selection.retryAttempt = 0;
        if (selection.pendingLocalSideEffects == 0 &&
            !selection.retirementRequested &&
            !selection.localFallbackReassertRequired) {
          _releaseRemoteSelection(selection);
          Log.i(
            '🎭 [AvatarSwitch] capability retired remote model; '
            'restoredBundled=${selection.fallback.remoteModelId == null}',
          );
        } else {
          Log.i(
            '🎭 [AvatarSwitch] capability fallback restored; waiting for '
            '${selection.pendingLocalSideEffects} late local side effect(s)',
          );
        }
      } catch (error) {
        if (!_closed && identical(_committedRemoteSelection, selection)) {
          _logAvatarFailure(
            '🎭 [AvatarSwitch] capability fallback cleanup failed; retrying',
            error,
          );
          _scheduleRemoteSelectionRetirementRetry(selection);
        }
      }
    } finally {
      _finishSwitch(selection.identity);
    }
  }

  Future<void> _restoreRetiringRemoteSelectionLocalState(
    _CommittedRemoteAvatarSelection selection,
  ) async {
    if (_closed || !identical(_committedRemoteSelection, selection)) return;
    selection.localFallbackReassertRequired = false;
    await _restoreStrict(selection.fallback, selection.fallbackBackend);
    if (_closed || !identical(_committedRemoteSelection, selection)) return;
    final persisted =
        !selection.persistenceMayHaveChanged ||
        await _restorePersistedSelection(
          selection.fallbackPersistedSelectionId,
        );
    if (!persisted) {
      throw StateError('Avatar fallback persistence was not committed');
    }
    if (_closed || !identical(_committedRemoteSelection, selection)) return;

    final selectionChanged = selectedId.value != selection.fallback.id;
    _persistedSelectionId = selection.fallbackPersistedSelectionId;
    selectedId.value = selection.fallback.id;
    if (selectionChanged) {
      _scheduleVoiceFor(selection.fallback);
    }
  }

  void _markRemoteSelectionServerRetirementTerminal(
    _CommittedRemoteAvatarSelection selection,
  ) {
    selection.serverRetirementTerminal = true;
    selection.retryAttempt = 0;
    if (selection.pendingLocalSideEffects == 0) {
      if (!selection.localFallbackReassertRequired) {
        selection.retirementRequested = false;
        _releaseRemoteSelection(selection);
        return;
      }
      _requestRemoteSelectionRetirement(selection);
      Log.i(
        '🎭 [AvatarSelectionV2] server retirement terminal; '
        'finishing requested local convergence',
      );
      return;
    }
    Log.i(
      '🎭 [AvatarSelectionV2] server retirement terminal; waiting for '
      '${selection.pendingLocalSideEffects} late local side effect(s)',
    );
  }

  bool _matchesRetiringRemoteHead(
    _CommittedRemoteAvatarSelection selection,
    AvatarSelectionSnapshot current,
  ) {
    final version = selection.authoritativeVersion;
    return version != null &&
        current.selection.modelId == selection.remoteModelId &&
        current.selection.version == version;
  }

  void _scheduleRemoteSelectionRetirementRetry(
    _CommittedRemoteAvatarSelection selection,
  ) {
    if (_closed ||
        _sealed ||
        !identical(_committedRemoteSelection, selection)) {
      return;
    }
    selection.retryTimer?.cancel();
    final exponent = selection.retryAttempt > 6 ? 6 : selection.retryAttempt;
    final delay = Duration(milliseconds: 50 * (1 << exponent));
    selection.retryAttempt++;
    selection.retryTimer = Timer(delay, () {
      selection.retryTimer = null;
      _requestRemoteSelectionRetirement(selection);
    });
  }

  void _replaceRemoteSelection(_CommittedRemoteAvatarSelection selection) {
    final previous = _committedRemoteSelection;
    if (identical(previous, selection)) return;
    previous?.retryTimer?.cancel();
    previous?.retryTimer = null;
    _committedRemoteSelection = selection;
  }

  void _releaseRemoteSelection(_CommittedRemoteAvatarSelection? selection) {
    if (selection == null) return;
    selection.retryTimer?.cancel();
    selection.retryTimer = null;
    if (identical(_committedRemoteSelection, selection)) {
      _committedRemoteSelection = null;
    }
  }

  void _beginSwitch(Object identity) {
    _invalidateDisplayLoad();
    _activeSwitchIdentity = identity;
    isSwitching.value = true;
  }

  void _finishSwitch(Object identity) {
    if (!identical(_activeSwitchIdentity, identity)) return;
    _activeSwitchIdentity = null;
    isSwitching.value = false;
    _publishDisplayReady();
  }

  Future<void> _restoreRemoteSelectionFallback(
    AvatarOption fallback,
    AvatarBackendKind fallbackBackend,
    String fallbackPersistedSelectionId,
  ) async {
    await _restoreStrict(fallback, fallbackBackend);
    if (_closed) return;
    final persisted = await _restorePersistedSelection(
      fallbackPersistedSelectionId,
    );
    if (!persisted) {
      throw StateError('Avatar fallback persistence was not committed');
    }
    if (_closed) return;
    _persistedSelectionId = fallbackPersistedSelectionId;
    selectedId.value = fallback.id;
    _scheduleVoiceFor(fallback);
  }

  Future<bool> _restorePersistedSelection(String selectedId) async {
    try {
      final restored = await _startTrackedLocalOperation(
        () => _persistSelection(
          _prefsKey,
          selectedId.trim().isEmpty ? null : selectedId,
        ),
      );
      if (!restored) {
        Log.w('🎭 [AvatarSwitch] persistence cleanup was not committed');
      }
      return restored;
    } catch (error) {
      _logAvatarFailure('🎭 [AvatarSwitch] persistence cleanup failed', error);
      return false;
    }
  }

  static Future<bool> _persistWithSpUtils(
    String key,
    String? selectedId,
  ) async {
    if (selectedId == null || selectedId.trim().isEmpty) {
      if (!SpUtils.hasKey(key)) return true;
      return SpUtils.remove(key);
    }
    return SpUtils.put(key, selectedId);
  }

  Future<void> _applyVoiceFor(AvatarOption option) {
    if (_closed || _sealed) return Future<void>.value();
    return _startTrackedLocalOperation(
      () => voicePreferences.applyAvatar(
        gender: option.voiceGender,
        preferredSid: option.preferredVoiceSid,
      ),
    );
  }

  void _scheduleVoiceFor(AvatarOption option) {
    if (_closed || _sealed) return;
    unawaited(
      _applyVoiceFor(option).catchError((Object error, StackTrace _) {
        _logAvatarFailure(
          '🎭 [AvatarVoice] apply failed '
          'remote=${option.remoteModelId != null}',
          error,
        );
      }),
    );
  }

  Future<void> _restore(
    AvatarOption previous,
    AvatarBackendKind previousBackend,
  ) async {
    try {
      await _restoreStrict(previous, previousBackend);
    } catch (_) {
      // Preserve the original switch/confirmation error. The next renderer
      // readiness event will retry the still-persisted known-good selection.
    }
  }

  Future<void> _restoreStrict(
    AvatarOption previous,
    AvatarBackendKind previousBackend,
  ) async {
    final displayEpoch = _displayLoadEpoch;
    await _displayHideReceipt;
    _active.select(previousBackend);
    final runtime = _active.current;
    if (runtime == null) return;
    await _startTrackedLocalOperation(
      () => runtime.loadAvatar(previous.modelUrl, previous.config),
    );
    _recordDisplayLoad(displayEpoch, previous, runtime);
  }

  Future<T> _startTrackedLocalOperation<T>(Future<T> Function() operation) =>
      _trackStartedLocalOperation(Future<T>.sync(operation));

  Future<T> _trackStartedLocalOperation<T>(Future<T> operation) {
    late final Future<void> settlement;
    settlement = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _inFlightLocalOperations.add(settlement);
    unawaited(
      settlement.whenComplete(() {
        _inFlightLocalOperations.remove(settlement);
      }),
    );
    return operation;
  }

  Future<bool> deactivateAndDrain({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _sealed = true;
    _invalidateDisplayLoad();
    _committedRemoteSelection?.retryTimer?.cancel();
    _committedRemoteSelection?.retryTimer = null;
    final stopwatch = Stopwatch()..start();
    while (_inFlightLocalOperations.isNotEmpty) {
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) return false;
      try {
        await Future.wait<void>(
          List<Future<void>>.of(_inFlightLocalOperations),
          eagerError: false,
        ).timeout(remaining);
      } on TimeoutException {
        return false;
      }
    }
    final hideRemaining = timeout - stopwatch.elapsed;
    if (hideRemaining <= Duration.zero) return false;
    try {
      await _displayHideReceipt.timeout(hideRemaining);
    } on Object {
      return false;
    }
    if (_displayHideFailed || _displayHidePending) return false;
    // Let continuations of the just-drained operations register any final
    // renderer/persistence cleanup before declaring the account quiescent.
    await Future<void>.delayed(Duration.zero);
    return _inFlightLocalOperations.isEmpty;
  }

  void _logStartupSelection() {
    final a = selected;
    final backend = appServices.isRegistered<ActiveAvatarRuntime>()
        ? _active.backend.value.name
        : a.backend.name;
    Log.i(
      '🎭 [AvatarConfig] backend=$backend '
      'remote=${a.remoteModelId != null} '
      'authority=${selectionAuthorityState.value.name}',
    );
  }

  @override
  void onClose() {
    if (_closed) return;
    _sealed = true;
    _closed = true;
    _committedRemoteSelection?.retryTimer?.cancel();
    _activeInitialApplyIdentity = null;
    _activeSwitchIdentity = null;
    _committedRemoteSelection = null;
    isSwitching.value = false;
    super.onClose();
  }
}

bool _isAvatarSelectionContractUnavailable(Object error) {
  if (error is AvatarSelectionContractUnavailableException) return true;
  return error is AvatarSelectionAmbiguousTransportException &&
      error.cause is AvatarSelectionContractUnavailableException;
}

void _logAvatarFailure(String message, Object error) {
  Log.e('$message failure=${_avatarFailureClass(error)}');
}

String _avatarFailureClass(Object error) {
  if (_isAvatarSelectionContractUnavailable(error)) {
    return 'contractUnavailable';
  }
  if (error is AvatarSelectionVersionChangedException) {
    return 'versionConflict';
  }
  if (error is AvatarSelectionAmbiguousTransportException) {
    return 'ambiguousTransport';
  }
  if (error is AvatarSelectionCompensatedException ||
      error is AvatarSelectionLocalCommitCompensatedException) {
    return 'compensated';
  }
  if (error is AvatarSelectionCompensationSupersededException) {
    return 'superseded';
  }
  if (error is AvatarSelectionCoordinatorException) {
    return 'coordinator';
  }
  if (error is AvatarSelectionOutboxUnavailableException) {
    return 'outboxUnavailable';
  }
  if (error is AvatarSelectionOutboxConflictException) {
    return 'outboxConflict';
  }
  if (error is AvatarSelectionOutboxCorruptException) {
    return 'outboxCorrupt';
  }
  if (error is AvatarRemoteModelCapabilityException) {
    return 'capability';
  }
  if (error is TimeoutException) return 'timeout';
  if (error is FormatException) return 'invalidData';
  if (error is StateError) return 'localState';
  return 'unexpected';
}
