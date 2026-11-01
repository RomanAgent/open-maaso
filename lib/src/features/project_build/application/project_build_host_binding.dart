import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

import '../data/project_build_v2_gateway.dart';
import '../data/project_build_v2_repository.dart';
import '../data/project_bundle_installation_store.dart';
import '../data/project_applet_action_journal.dart';
import '../domain/project_bundle_verification.dart';
import '../domain/project_json_canonicalizer.dart';
import 'project_build_v2_tasks.dart';
import 'project_applet_control_service.dart';
import 'project_applet_agent_coordinator.dart';

final class ProjectBuildHostConfiguration {
  ProjectBuildHostConfiguration._({
    required this.enableCreation,
    required this.trustedKeys,
    required this.allowDevelopmentIsolation,
  });
  final bool enableCreation, allowDevelopmentIsolation;
  final Map<String, List<int>> trustedKeys;

  factory ProjectBuildHostConfiguration.parse({
    required bool enableCreation,
    required String trustedKeysBase64,
    required bool debugBuild,
    bool allowDevelopmentIsolation = false,
  }) {
    final keys = <String, List<int>>{};
    if (trustedKeysBase64.length > 24 * 1024) {
      throw const FormatException('project_verifier_configuration');
    }
    if (trustedKeysBase64.isNotEmpty) {
      final bytes = base64Decode(trustedKeysBase64);
      if (bytes.length > 16 * 1024 ||
          base64Encode(bytes) != trustedKeysBase64) {
        throw const FormatException('project_verifier_configuration');
      }
      final raw = const ProjectJsonCanonicalizer(
        maxBytes: 16 * 1024,
        maxDepth: 4,
        maxNodes: 64,
      ).parseBytes(bytes);
      if (raw is! Map<String, Object?> || raw.length > 16) {
        throw const FormatException('project_verifier_configuration');
      }
      for (final entry in raw.entries) {
        if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(entry.key) ||
            entry.value is! String) {
          throw const FormatException('project_verifier_configuration');
        }
        final value = base64Decode(entry.value! as String);
        if (value.length != 32 || base64Encode(value) != entry.value) {
          throw const FormatException('project_verifier_configuration');
        }
        keys[entry.key] = List.unmodifiable(value);
      }
    }
    return ProjectBuildHostConfiguration._(
      enableCreation: enableCreation && keys.isNotEmpty,
      trustedKeys: Map.unmodifiable(keys),
      allowDevelopmentIsolation: debugBuild && allowDevelopmentIsolation,
    );
  }

  factory ProjectBuildHostConfiguration.fromEnvironment() {
    try {
      return ProjectBuildHostConfiguration.parse(
        enableCreation: const bool.fromEnvironment(
          'MAASO_PROJECT_BUILD_V2_ENABLED',
        ),
        trustedKeysBase64: const String.fromEnvironment(
          'MAASO_PROJECT_BUNDLE_TRUSTED_KEYS_BASE64',
        ),
        debugBuild: kDebugMode,
        allowDevelopmentIsolation: const bool.fromEnvironment(
          'MAASO_PROJECT_BUNDLE_ALLOW_DEVELOPMENT_ISOLATION',
        ),
      );
    } catch (_) {
      // A misconfigured optional feature must not break account boot or trust
      // key material returned by a candidate/download endpoint.
      return ProjectBuildHostConfiguration._(
        enableCreation: false,
        trustedKeys: const {},
        allowDevelopmentIsolation: false,
      );
    }
  }
}

typedef ProjectBundleCandidatePresenter =
    Future<bool> Function(
      InstalledProjectBundleV2,
      VerifiedProjectBundlePermit,
      bool preview,
    );

/// One account mount owns all v2 producers. Construction performs no network
/// calls; discovery and readiness start only after an app frame and foreground.
final class ProjectBuildHostBinding extends AppService {
  ProjectBuildHostBinding({
    required DBService database,
    required AccountStorageScope accountScope,
    required Directory applicationSupportRoot,
    required this.creatorScope,
    required this.appletScope,
    required this.configuration,
    required AgentTaskJobStore jobs,
    required Uri baseUri,
    required Future<String> Function() accessToken,
    required bool Function() isCurrent,
    required bool Function() isForeground,
    required Future<void> Function() authorizeCloudText,
    required AgentRuntime? Function(String agentId) runtimeForAgent,
    Listenable? contextChanges,
    List<AppReactiveValue<dynamic>> reactiveContext = const [],
    String Function()? currentAppletScope,
    ProjectBundleCandidatePresenter? presentCandidate,
    http.Client? httpClient,
    DateTime Function()? now,
    ChatMediaService? Function()? referenceMedia,
    Future<void> Function()? authorizeCloudImage,
  }) : _database = database,
       _isCurrent = isCurrent,
       _isForeground = isForeground,
       _authorizeCloudText = authorizeCloudText,
       _runtimeForAgent = runtimeForAgent,
       _contextChanges = contextChanges,
       _reactiveContext = reactiveContext,
       _currentAppletScope =
           currentAppletScope ?? AppletLocalOwnership.currentScopeKey,
       _now = now ?? DateTime.now {
    installations = ProjectBundleInstallationStore(
      database: database.raw,
      accountScope: accountScope,
      projectBuildScopeKey: creatorScope,
      applicationSupportRoot: applicationSupportRoot,
      isCurrent: () => _valid,
      loadOwnedProjectIds: () async {
        _guard();
        final known = await repository.readOwnedProjects(
          expectedScopeKey: creatorScope,
        );
        _guard();
        return known?.projects.map((project) => project.projectId).toSet();
      },
    );
    verification = ProjectBundleVerificationService(
      trustedKeys: configuration.trustedKeys,
      isCurrent: () => _valid,
      allowDevelopmentIsolation: configuration.allowDevelopmentIsolation,
    );
    repository = ProjectBuildV2Repository(
      database: database,
      scopeKey: creatorScope,
      isCurrent: () => _valid,
    );
    gateway = HttpProjectBuildV2Gateway(
      baseUri: () => baseUri,
      contextKey: () => creatorScope,
      accessToken: accessToken,
      isCurrent: () => _valid,
      client: httpClient,
    );
    companionCalls = SurfaceCompanionCallLedger(
      database: database,
      scopeKey: creatorScope,
      isCurrent: () => _valid,
      now: _now,
    );
    play = SurfacePlayService(
      companionCalls: companionCalls,
      scopeKey: creatorScope,
      projectBuildScopeKey: creatorScope,
      persistence: SurfacePlayStore(
        database: database,
        scopeKey: creatorScope,
        projectBuildScopeKey: creatorScope,
        isCurrent: () => _valid,
      ),
      isCurrent: () => _valid,
    );
    previewPlay = SurfacePlayService(
      companionCalls: companionCalls,
      scopeKey: '$creatorScope|preview',
      projectBuildScopeKey: creatorScope,
      persistence: SurfacePlayStore(
        database: database,
        scopeKey: '$creatorScope|preview',
        projectBuildScopeKey: creatorScope,
        isCurrent: () => _valid,
      ),
      isCurrent: () => _valid,
    );
    appletControl = ProjectAppletControlService(
      scopeKey: accountScope.storageNamespace,
      appletScopeKey: appletScope,
      journal: ProjectAppletActionJournal(
        database: database.raw,
        scopeKey: accountScope.storageNamespace,
        repositoryScopeKey: creatorScope,
        processId: const Uuid().v4(),
        isCurrent: () => _valid,
      ),
      isCurrent: () => _valid,
      isForeground: _isForeground,
    );
    appletAgent = ProjectAppletAgentCoordinator(
      control: appletControl,
      calls: companionCalls,
      runtimeForAgent: _runtimeForAgent,
      isCurrent: () => _valid,
    );
    hostServices = SurfaceBundleHostServices(
      installations: installations,
      verifier: verification,
      playService: play,
      previewPlayService: previewPlay,
      agentId: 'self',
      appletControl: appletControl,
    );
    tasks = ProjectBuildV2Tasks(
      jobs: jobs,
      installation: installations,
      verification: verification,
      repository: repository,
      gateway: gateway,
      scopeKey: creatorScope,
      appletScopeKey: appletScope,
      isCurrent: () => _valid && configuration.trustedKeys.isNotEmpty,
      isForeground: _isForeground,
      isCreationReady: () => creationReady,
      enableCreation: configuration.enableCreation,
      authorize: authorizeCloudText,
      canRecoverDispatch: _canRecoverDispatch,
      contextChanges: contextChanges,
      reactiveContext: [...reactiveContext, readiness],
      presentCandidate: presentCandidate ?? _presentCandidate,
      persistInstalled: persistInstalled,
      reconcileOwnedProjects: reconcileOwnedProjects,
      cleanupDeletedProject: cleanupDeletedProject,
      referenceMedia: referenceMedia,
      authorizeCloudImage: authorizeCloudImage,
    );
  }

  final DBService _database;
  final String creatorScope, appletScope;
  final ProjectBuildHostConfiguration configuration;
  late final ProjectAppletControlService appletControl;
  late final ProjectAppletAgentCoordinator appletAgent;
  late final SurfaceCompanionCallLedger companionCalls;
  final bool Function() _isCurrent, _isForeground;
  final Future<void> Function() _authorizeCloudText;
  final String Function() _currentAppletScope;
  final AgentRuntime? Function(String) _runtimeForAgent;
  final Listenable? _contextChanges;
  final List<AppReactiveValue<dynamic>> _reactiveContext;
  final DateTime Function() _now;
  late final ProjectBundleInstallationStore installations;
  late final ProjectBundleVerificationService verification;
  late final ProjectBuildV2Repository repository;
  late final HttpProjectBuildV2Gateway gateway;
  late final SurfacePlayService play, previewPlay;
  late final SurfaceBundleHostServices hostServices;
  late final ProjectBuildV2Tasks tasks;
  final RxBool readiness = false.obs;
  final List<Worker> _workers = [];
  final Set<SurfaceRuntime> _presentations = {};
  Future<void>? _probe, _draining;
  Future<void> _pointerTail = Future.value();
  Timer? _readinessExpiry, _refreshTimer;
  DateTime? _readinessAt, _lastInventory;
  int _epoch = 0;
  bool _sealed = false,
      _started = false,
      _frameQueued = false,
      _wasCurrent = false;
  bool get _valid =>
      !_sealed && _isCurrent() && _currentAppletScope() == appletScope;

  bool get creationReady {
    final stamp = _readinessAt;
    if (!_valid ||
        !configuration.enableCreation ||
        !readiness.value ||
        stamp == null) {
      return false;
    }
    final age = _now().difference(stamp);
    return !age.isNegative && age <= const Duration(seconds: 30);
  }

  void _guard() {
    if (!_valid || _currentAppletScope() != appletScope) {
      throw StateError('project_build_host_scope_changed');
    }
  }

  /// Called after all children have been registered in the account graph.
  void startAfterFirstFrame() {
    if (_started || _sealed) return;
    _started = true;
    appletAgent.start();
    _contextChanges?.addListener(_contextChanged);
    for (final signal in _reactiveContext) {
      _workers.add(signal.listen((_) => _contextChanged()));
    }
    _contextChanged();
  }

  void _contextChanged() {
    appletControl.contextChanged();
    _refreshTimer?.cancel();
    if (!_valid) {
      if (_wasCurrent) unawaited(deactivateAndDrain());
      return;
    }
    _wasCurrent = true;
    if (!_isForeground()) {
      _epoch++;
      readiness.value = false;
      _readinessAt = null;
      _readinessExpiry?.cancel();
      return;
    }
    if (_frameQueued) return;
    _frameQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameQueued = false;
      if (_valid && _isForeground()) unawaited(_foregroundRecovery());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _foregroundRecovery() async {
    await refreshReadiness();
    if (!_valid || !_isForeground() || configuration.trustedKeys.isEmpty) {
      return;
    }
    final previous = _lastInventory;
    if (previous == null ||
        _now().difference(previous) >= const Duration(minutes: 5)) {
      _lastInventory = _now();
      await tasks.restoreSavedProjects();
    }
  }

  Future<void> refreshReadiness() {
    if (!_valid || !_isForeground() || configuration.trustedKeys.isEmpty) {
      return Future.value();
    }
    final pending = _probe;
    if (pending != null) return pending;
    final epoch = _epoch;
    late Future<void> work;
    work =
        () async {
          try {
            final response = await gateway.readiness(
              expectedContextKey: creatorScope,
            );
            if (!_valid || !_isForeground() || epoch != _epoch) return;
            readiness.value = response.permitsCreation(
              configuration.trustedKeys.keys.toSet(),
              allowDevelopmentIsolation:
                  configuration.allowDevelopmentIsolation,
            );
            _readinessAt = _now();
            _readinessExpiry?.cancel();
            _readinessExpiry = Timer(const Duration(seconds: 30), () {
              readiness.value = false;
            });
          } catch (_) {
            if (_valid && epoch == _epoch) {
              readiness.value = false;
              _readinessAt = null;
            }
          } finally {
            if (_valid && _isForeground() && epoch == _epoch) {
              _refreshTimer?.cancel();
              _refreshTimer = Timer(const Duration(seconds: 20), () {
                unawaited(refreshReadiness());
              });
            }
          }
        }().whenComplete(() {
          if (identical(_probe, work)) _probe = null;
        });
    _probe = work;
    return work;
  }

  Future<bool> _canRecoverDispatch() async {
    if (!creationReady) return false;
    try {
      await _authorizeCloudText();
      return creationReady;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _presentCandidate(
    InstalledProjectBundleV2 installed,
    VerifiedProjectBundlePermit permit,
    bool preview,
  ) async {
    _guard();
    final runtime = SurfaceRuntime()..initializeLifecycle();
    _presentations.add(runtime);
    return presentProjectBundleInPlayer(
      installed,
      permit: permit,
      preview: preview,
      hostServices: hostServices,
      runtime: runtime,
      expectedScopeKey: appletScope,
      isCurrent: () => _valid,
      onDisposed: () => _presentations.remove(runtime),
    );
  }

  AgentWidget widgetFor(
    InstalledProjectBundleV2 installed, {
    required String reportDigest,
    required String agentId,
  }) {
    final bundle = installed.bundle;
    final widget = AgentWidget(
      agentId: agentId,
      title: bundle.title,
      kind: 'surface',
      createdAt: installed.installedAt,
      spec: {
        'surfaceId': bundle.manifest.projectId,
        'surfaceKind': 'fullscreen',
        'rendering': 'projectBundle',
        'experienceType': bundle.manifest.projectKind == 'game'
            ? 'game'
            : 'utility',
        'category': bundle.manifest.projectKind == 'game' ? 'game' : 'tools',
        'summary': bundle.summary,
        'bundleReference': {
          'packageSchema': 2,
          'projectId': bundle.manifest.projectId,
          'revisionId': bundle.manifest.revisionId,
          'candidateDigest': bundle.candidateDigest,
          'reportDigest': reportDigest,
        },
      },
    );
    AppletLocalOwnership.stamp(widget, scopeKey: appletScope);
    return widget;
  }

  Future<T> _withPointer<T>(Future<T> Function() action) {
    final result = _pointerTail.then((_) => action());
    _pointerTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> persistInstalled(
    InstalledProjectBundleV2 installed,
    String agentId,
  ) => _withPointer(() async {
    _guard();
    if (!installed.isAccepted ||
        installed.scopeKey != installations.scopeKey ||
        installed.verificationReport == null) {
      throw StateError('project_bundle_not_accepted');
    }
    final permit = await verification.verifyReport(
      installed.bundle,
      installed.verificationReport,
    );
    _guard();
    final head = await installations.openCurrent(
      installed.bundle.manifest.projectId,
      expectedScopeKey: installations.scopeKey,
    );
    if (head?.candidateDigest != installed.candidateDigest ||
        installed.headVersion == null ||
        head?.headVersion != installed.headVersion) {
      throw StateError('project_bundle_pointer_stale');
    }
    final row = widgetFor(
      installed,
      reportDigest: permit.reportDigest,
      agentId: agentId,
    );
    final records = await _database.getAllWidgets();
    _guard();
    bool matches(AgentWidget value) =>
        AppletLocalOwnership.isVisible(value, scopeKey: appletScope) &&
        value.spec['surfaceId'] == installed.bundle.manifest.projectId;
    final existing = records.where(matches).toList();
    if (existing.length > 1) {
      throw StateError('project_bundle_pointer_duplicate');
    }
    if (existing.isEmpty) {
      await _database.saveAgentWidgetValidated(
        row,
        validate: (current) {
          _guard();
          if (!permit.isCurrent || current.any(matches)) {
            throw StateError('project_bundle_pointer_conflict');
          }
        },
      );
    } else {
      final old = existing.single;
      if (old.spec['rendering'] != 'projectBundle') {
        throw StateError('project_bundle_pointer_conflict');
      }
      final oldDigest =
          (old.spec['bundleReference'] as Map?)?['candidateDigest'];
      await _database.updateGeneratedSurface(
        old.id!,
        title: row.title,
        spec: row.spec,
        expectedScopeKey: appletScope,
        validateScope: (value, scope) {
          _guard();
          final digest =
              (value.spec['bundleReference'] as Map?)?['candidateDigest'];
          return permit.isCurrent &&
              scope == appletScope &&
              matches(value) &&
              value.spec['rendering'] == 'projectBundle' &&
              (digest == oldDigest || digest == installed.candidateDigest);
        },
      );
    }
    _guard();
    await appServices.maybeFind<WidgetsHubController>()?.reload();
  });
  Future<void> reconcileOwnedProjects(Set<String> projectIds) => _withPointer(
    () async {
      _guard();
      installations.reconcileOwnedPresentations(
        projectIds,
        expectedScopeKey: installations.scopeKey,
      );
      for (final widget in await _database.getAllWidgets()) {
        if (widget.spec['rendering'] != 'projectBundle' ||
            !AppletLocalOwnership.isVisible(widget, scopeKey: appletScope)) {
          continue;
        }
        final project = widget.spec['surfaceId'];
        if (project is! String || projectIds.contains(project)) continue;
        await _database.deleteWidgetValidated(
          widget.id!,
          validate: (current) {
            _guard();
            return current.spec['rendering'] == 'projectBundle' &&
                current.spec['surfaceId'] == project &&
                AppletLocalOwnership.isVisible(current, scopeKey: appletScope);
          },
        );
      }
      _guard();
      await appServices.maybeFind<WidgetsHubController>()?.reload();
    },
  );

  Future<void> cleanupDeletedProject(
    ProjectBuildV2DeletionProof proof,
    Set<String> localTaskIds,
  ) => _withPointer(() async {
    void guard() {
      _guard();
      if (!proof.isScopeCurrent || proof.scopeKey != creatorScope) {
        throw StateError('project_bundle_delete_authority');
      }
    }

    guard();
    await appletControl.purgeDeletedProject(proof);
    guard();
    // Both formal saves and isolated previews belong to the deleted project.
    await play.purgeDeletedProject(
      proof,
      expectedProjectBuildScopeKey: creatorScope,
    );
    guard();
    await previewPlay.purgeDeletedProject(
      proof,
      expectedProjectBuildScopeKey: creatorScope,
    );
    guard();
    bool matches(AgentWidget row) =>
        AppletLocalOwnership.isVisible(row, scopeKey: appletScope) &&
        row.spec['rendering'] == 'projectBundle' &&
        row.spec['surfaceId'] == proof.projectId;
    final widgets = await _database.getAllWidgets();
    guard();
    for (final row in widgets.where(matches)) {
      if (row.id == null) continue;
      await _database.deleteWidgetValidated(
        row.id!,
        validate: (current) {
          guard();
          return matches(current);
        },
      );
      guard();
    }
    appServices.maybeFind<HomeController>()?.purgeDeletedProjectTaskCards(
      proof,
      localTaskIds,
      expectedAppletScopeKey: appletScope,
      expectedProjectBuildScopeKey: creatorScope,
    );
    await appServices.maybeFind<WidgetsHubController>()?.reload();
    guard();
  });

  Future<void> deactivateAndDrain() => _draining ??= _drain();
  Future<void> _drain() async {
    _sealed = true;
    _epoch++;
    readiness.value = false;
    _refreshTimer?.cancel();
    _readinessExpiry?.cancel();
    _contextChanges?.removeListener(_contextChanged);
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    verification.deactivate();
    final tasksDrain = tasks.deactivateAndDrain();
    await appletAgent.deactivateAndDrain();
    final controlDrain = appletControl.deactivateAndDrain();
    for (final runtime in _presentations.toList()) {
      await runtime.close();
      runtime.closeLifecycle();
    }
    _presentations.clear();
    await play.deactivateAndDrain();
    await previewPlay.deactivateAndDrain();
    await tasksDrain;
    await controlDrain;
    await _probe;
    await _pointerTail;
    await installations.deactivateAndDrain();
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
