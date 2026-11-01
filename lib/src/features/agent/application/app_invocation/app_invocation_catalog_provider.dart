import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/official_applet.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';

import 'app_invocation_catalog.dart';
import 'app_invocation_descriptor.dart';
import 'app_invocation_sidecar_store.dart';

/// One account mount owns the directory and its descriptive cache. Construction
/// subscribes only to local invalidation signals; it does not fetch a directory,
/// ensure a runtime, open a player, or inspect an installed bundle.
final class AppInvocationCatalogProvider extends AppService {
  AppInvocationCatalogProvider({
    required DBService database,
    required this.mount,
    required AccountStorageScopeService storageScopes,
    required Uri accountBaseUri,
    required AppletCatalogService catalogService,
    required ProjectBundleInstallationStore installations,
    required Set<String> Function() enabledSkillIds,
    required AppCapabilitySnapshot? Function() capabilitySnapshot,
    required ({String id, String version}) Function(AppInvocationRuntimeKind)
    adapterIdentityFor,
    String Function()? currentAppletScope,
    Iterable<OfficialApplet> Function()? officialApplets,
    DateTime Function()? now,
  }) : _storageScopes = storageScopes,
       _installations = installations,
       _enabledSkillIds = enabledSkillIds,
       _capabilitySnapshot = capabilitySnapshot,
       _currentAppletScope =
           currentAppletScope ?? AppletLocalOwnership.currentScopeKey,
       _officialApplets =
           officialApplets ?? (() => OfficialAppletRegistry.all) {
    storageScopes.requireCurrent(mount);
    if (installations.accountScope != mount.scope) {
      throw ArgumentError('invocation_catalog_installation_scope_mismatch');
    }
    scopeKey = '${accountBaseUri.origin}|${mount.scope.accountUuid}';
    mountId = jsonEncode([mount.scope.storageNamespace, mount.generation]);
    sidecars = AppInvocationSidecarStore(
      database: database.raw,
      scopeKey: scopeKey,
      mountId: mountId,
      currentMountId: () => storageScopes.isCurrent(mount) ? mountId : '',
      isCurrent: () => _current,
    );
    catalog = AppInvocationCatalog(
      catalog: catalogService,
      discovery: catalogService,
      loadLocalWidgets: database.getAllWidgets,
      loadOwnedInventory: catalogService.mine,
      readAvailableOfficialApplets: _readAvailableOfficialApplets,
      sidecars: sidecars,
      adapterIdentityFor: adapterIdentityFor,
      scopeKey: scopeKey,
      mountId: mountId,
      currentScopeKey: _currentAppletScope,
      currentMountId: () => storageScopes.isCurrent(mount) ? mountId : '',
      isCurrent: () => _current,
      readInstalledBundle: _readInstalledBundle,
      now: now,
    );
    _revocations = installations.onProjectRevoked.listen(_invalidateBundle);
    _withdrawals = installations.onOwnedInventoryChanged.listen((ids) {
      for (final id in _observedBundles.difference(ids)) {
        _invalidateBundle(id);
      }
      _observedBundles.removeWhere((id) => !ids.contains(id));
    });
    unawaited(mount.whenInvalidated.then((_) => retire()));
  }

  final AccountStorageScopeMount mount;
  final AccountStorageScopeService _storageScopes;
  final ProjectBundleInstallationStore _installations;
  final Set<String> Function() _enabledSkillIds;
  final AppCapabilitySnapshot? Function() _capabilitySnapshot;
  final String Function() _currentAppletScope;
  final Iterable<OfficialApplet> Function() _officialApplets;
  late final String scopeKey, mountId;
  late final AppInvocationCatalog catalog;
  late final AppInvocationSidecarStore sidecars;
  late final StreamSubscription<String> _revocations;
  late final StreamSubscription<Set<String>> _withdrawals;
  final _observedBundles = <String>{};
  final _pendingInvalidations = <Future<void>>{};
  bool _sealed = false;
  Future<void>? _draining;

  bool get _current =>
      !_sealed &&
      _storageScopes.isCurrent(mount) &&
      _currentAppletScope() == scopeKey;

  void _guard() {
    if (!_current) throw const AppInvocationCatalogException('scope_retired');
  }

  Iterable<({String id, String title})> _readAvailableOfficialApplets() {
    _guard();
    final snapshot = _capabilitySnapshot();
    if (snapshot == null ||
        snapshot.context.accountScopeDigest != mount.scope.accountDigest ||
        snapshot.context.accountGeneration != mount.generation) {
      return const [];
    }
    final enabled = Set<String>.of(_enabledSkillIds());
    final available = <({String id, String title})>[];
    for (final applet in _officialApplets()) {
      final skillId = applet.requiresSkillId;
      if (skillId == null || !enabled.contains(skillId)) continue;
      final spec = SkillCatalog.byId(skillId);
      if (spec == null ||
          spec.factory == null ||
          spec.isComingSoon ||
          !spec.isAvailable ||
          spec.hostRouting == null ||
          !snapshot.allows(
            AppCapabilityKey.skill(skillId),
            requireVisible: true,
          )) {
        continue;
      }
      available.add((id: applet.id, title: applet.nameKey.tr));
    }
    _guard();
    return List.unmodifiable(available);
  }

  Future<InstalledProjectBundleV2?> _readInstalledBundle(
    AgentWidget widget,
  ) async {
    _guard();
    final reference = widget.spec['bundleReference'];
    if (reference is! Map ||
        reference['packageSchema'] != 2 ||
        reference['projectId'] is! String ||
        reference['revisionId'] is! String ||
        reference['candidateDigest'] is! String ||
        reference['reportDigest'] is! String) {
      return null;
    }
    final projectId = reference['projectId']! as String;
    await _installations.ensurePresentationAuthority(
      expectedScopeKey: _installations.scopeKey,
    );
    _guard();
    if (!_installations.canPresentSavedProject(
      projectId,
      expectedScopeKey: _installations.scopeKey,
    )) {
      return null;
    }
    final installed = await _installations.openCandidate(
      reference['candidateDigest']! as String,
      expectedScopeKey: _installations.scopeKey,
      reportDigest: reference['reportDigest']! as String,
    );
    _guard();
    if (installed == null ||
        !installed.isCurrent ||
        !installed.isAccepted ||
        installed.scopeKey != mount.scope.storageNamespace ||
        installed.bundle.manifest.projectId != projectId ||
        installed.bundle.manifest.revisionId != reference['revisionId'] ||
        installed.candidateDigest != reference['candidateDigest'] ||
        !_installations.canPresentSavedProject(
          projectId,
          expectedScopeKey: _installations.scopeKey,
        )) {
      return null;
    }
    _observedBundles.add(projectId);
    return installed;
  }

  void _invalidateBundle(String projectId) {
    if (!_current) return;
    final work = catalog.invalidateSource(
      origin: AppInvocationSourceOrigin.local,
      sourceId: projectId,
      reason: 'installed_source_withdrawn',
    );
    late Future<void> tracked;
    tracked = work
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (_current) {
              Log.w(
                '[AppInvocationCatalog] source invalidation failed',
                error: error,
                stackTrace: stackTrace,
              );
            }
          },
        )
        .whenComplete(() => _pendingInvalidations.remove(tracked));
    _pendingInvalidations.add(tracked);
  }

  void retire() {
    if (_sealed) return;
    _sealed = true;
    catalog.retire();
    sidecars.retire();
  }

  Future<void> deactivateAndDrain() => _draining ??= _drain();

  Future<void> _drain() async {
    retire();
    await Future.wait<void>([
      _revocations.cancel(),
      _withdrawals.cancel(),
      catalog.deactivateAndDrain(),
    ]);
    while (_pendingInvalidations.isNotEmpty) {
      await Future.wait(_pendingInvalidations.toList());
    }
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
