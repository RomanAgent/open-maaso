import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart'
    show surfaceProjectFromWidget;

import 'app_invocation_compatibility.dart';
import 'app_invocation_descriptor.dart';
import 'app_invocation_draft_snapshot.dart';
import 'app_invocation_sidecar.dart';
import 'app_invocation_sidecar_store.dart';

enum AppInvocationSourceOrigin { local, publicCatalog, ownedCatalog, official }

/// A source locator, not an authorization or an executable callback.
final class AppInvocationSourceLocator {
  const AppInvocationSourceLocator._(
    this.origin,
    this.id, {
    this.localWidgetId,
    this.clientSurfaceId,
  });
  final AppInvocationSourceOrigin origin;
  final String id;
  final int? localWidgetId;
  final String? clientSurfaceId;
}

final class AppInvocationCatalogEntry {
  const AppInvocationCatalogEntry._({
    required this.locator,
    required this.title,
    required this.summary,
    required this.type,
    required this.scopeKey,
    required this.mountId,
    required this.requestContextKey,
  });
  final AppInvocationSourceLocator locator;
  final String title, summary, scopeKey, mountId, requestContextKey;
  final AppletCatalogType type;
}

final class AppInvocationCatalogPage {
  AppInvocationCatalogPage._({
    required List<AppInvocationCatalogEntry> entries,
    required this.requestGeneration,
    this.nextCursor,
    Map<AppInvocationSourceOrigin, String> sourceErrors = const {},
  }) : entries = List.unmodifiable(entries),
       sourceErrors = Map.unmodifiable(sourceErrors);
  final List<AppInvocationCatalogEntry> entries;
  final int requestGeneration;
  final String? nextCursor;
  final Map<AppInvocationSourceOrigin, String> sourceErrors;
}

/// A pinned content reference. It conveys neither runtime validation nor access.
final class AppInvocationSelection {
  const AppInvocationSelection._({
    required this.entry,
    required this.identity,
    required this.contractDigest,
    required this.adapterId,
    required this.adapterVersion,
  });
  final AppInvocationCatalogEntry entry;
  final AppInvocationIdentity identity;
  final String contractDigest, adapterId, adapterVersion;
}

/// The exact inspected execution source, never permission to run it. A runner
/// must revalidate the selection before every invocation and acquire its own
/// current runtime/isolation authority. History and editor state are omitted.
final class AppInvocationPinnedSource {
  AppInvocationPinnedSource._({
    required this.identity,
    required this.contractDigest,
    required this.locator,
    required this.type,
    required this.title,
    required bool Function() isCurrent,
    SurfaceProject? surface,
    InstalledProjectBundleV2? installedBundle,
  }) : _isCurrent = isCurrent,
       _surfaceData = surface == null
           ? null
           : _snapshotExecutionSource(surface),
       _installedBundle = installedBundle {
    if ((surface == null) == (installedBundle == null)) {
      throw ArgumentError('invocation_source_kind_ambiguous');
    }
  }

  final AppInvocationIdentity identity;
  final String contractDigest;
  final AppInvocationSourceLocator locator;
  final AppletCatalogType type;
  final String title;
  final bool Function() _isCurrent;
  final Map<String, Object?>? _surfaceData;
  final InstalledProjectBundleV2? _installedBundle;
  bool get isCurrent => _isCurrent() && (_installedBundle?.isCurrent ?? true);

  SurfaceProject? get surface {
    if (_surfaceData == null) return null;
    if (!isCurrent) throw const AppInvocationCatalogException('source_retired');
    return SurfaceProject.fromJson(_surfaceData);
  }

  InstalledProjectBundleV2? get installedBundle {
    if (_installedBundle == null) return null;
    if (!isCurrent) throw const AppInvocationCatalogException('source_retired');
    return _installedBundle;
  }
}

/// Source inspection only: this resolver never produces `compatible` or a grant.
final class AppInvocationResolution {
  const AppInvocationResolution._({
    required this.entry,
    required this.status,
    required this.reason,
    this.selection,
    this.descriptor,
    this.sidecar,
    this.executableSource,
  });
  final AppInvocationCatalogEntry entry;
  final AppInvocationCompatibilityStatus status;
  final String reason;
  final AppInvocationSelection? selection;
  final AppInvocationDescriptor? descriptor;
  final AppInvocationSidecar? sidecar;
  final AppInvocationPinnedSource? executableSource;
}

/// A fresh, read-only player source. Opening a work does not require a callable
/// action contract and does not authorize any Agent invocation.
final class AppInvocationOpenTarget {
  AppInvocationOpenTarget._({
    required this.entry,
    required bool Function() isCurrent,
    AgentWidget? localWidget,
    SurfaceProject? surface,
    this.officialAppletId,
  }) : _isCurrent = isCurrent,
       _localWidget = localWidget,
       _surfaceData = surface == null
           ? null
           : _snapshotExecutionSource(surface);

  final AppInvocationCatalogEntry entry;
  final String? officialAppletId;
  final bool Function() _isCurrent;
  final AgentWidget? _localWidget;
  final Map<String, Object?>? _surfaceData;
  bool get isCurrent => _isCurrent();

  AgentWidget? get localWidget {
    if (!isCurrent) throw const AppInvocationCatalogException('source_retired');
    return _localWidget == null ? null : _snapshotWidget(_localWidget);
  }

  SurfaceProject? get surface {
    if (!isCurrent) throw const AppInvocationCatalogException('source_retired');
    return _surfaceData == null ? null : SurfaceProject.fromJson(_surfaceData);
  }
}

final class AppInvocationCatalogException implements Exception {
  const AppInvocationCatalogException(this.code);
  final String code;
  @override
  String toString() => 'AppInvocationCatalogException($code)';
}

/// Read-only aggregation of existing source APIs. The sole write dependency is
/// the separate sidecar store. No player, editor, publisher or runtime is opened.
final class AppInvocationCatalog {
  AppInvocationCatalog({
    required AppletCatalogGateway catalog,
    required AppletDiscoveryGateway discovery,
    required Future<List<AgentWidget>> Function() loadLocalWidgets,
    required Future<AppletInventoryPage> Function() loadOwnedInventory,
    required Iterable<({String id, String title})> Function()
    readAvailableOfficialApplets,
    required AppInvocationSidecarStore sidecars,
    required ({String id, String version}) Function(
      AppInvocationRuntimeKind kind,
    )
    adapterIdentityFor,
    required this.scopeKey,
    required this.mountId,
    required String Function() currentScopeKey,
    required String Function() currentMountId,
    required bool Function() isCurrent,
    Future<InstalledProjectBundleV2?> Function(AgentWidget widget)?
    readInstalledBundle,
    DateTime Function()? now,
  }) : _catalog = catalog,
       _discovery = discovery,
       _loadLocalWidgets = loadLocalWidgets,
       _loadOwnedInventory = loadOwnedInventory,
       _readOfficial = readAvailableOfficialApplets,
       _sidecars = sidecars,
       _adapterIdentityFor = adapterIdentityFor,
       _currentScopeKey = currentScopeKey,
       _currentMountId = currentMountId,
       _isCurrent = isCurrent,
       _readInstalledBundle = readInstalledBundle,
       _now = now ?? DateTime.now {
    if (scopeKey.isEmpty ||
        mountId.isEmpty ||
        sidecars.scopeKey != scopeKey ||
        sidecars.mountId != mountId) {
      throw ArgumentError('invocation_catalog_scope_mismatch');
    }
  }

  final String scopeKey, mountId;
  final AppletCatalogGateway _catalog;
  final AppletDiscoveryGateway _discovery;
  final Future<List<AgentWidget>> Function() _loadLocalWidgets;
  final Future<AppletInventoryPage> Function() _loadOwnedInventory;
  final Iterable<({String id, String title})> Function() _readOfficial;
  final AppInvocationSidecarStore _sidecars;
  final ({String id, String version}) Function(AppInvocationRuntimeKind kind)
  _adapterIdentityFor;
  final String Function() _currentScopeKey, _currentMountId;
  final bool Function() _isCurrent;
  final Future<InstalledProjectBundleV2?> Function(AgentWidget)?
  _readInstalledBundle;
  final DateTime Function() _now;
  bool _retired = false;
  int _personalGeneration = 0, _publicGeneration = 0, _resolveGeneration = 0;
  Set<String>? _knownOwnedIds;
  final _sourceGenerations = <String, int>{};
  final _pending = <Future<void>>{};

  void Function() _beginOperation() {
    _guard();
    final completed = Completer<void>();
    _pending.add(completed.future);
    return () {
      _pending.remove(completed.future);
      if (!completed.isCompleted) completed.complete();
    };
  }

  void _guard([String? context]) {
    if (_retired ||
        !_isCurrent() ||
        _currentMountId() != mountId ||
        _currentScopeKey() != scopeKey) {
      throw const AppInvocationCatalogException('scope_retired');
    }
    if (context != null && context != _catalog.requestContextKey) {
      throw const AppInvocationCatalogException('request_context_changed');
    }
  }

  String _query(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.runes.length > 80) {
      throw const AppInvocationCatalogException('invalid_query');
    }
    return normalized;
  }

  AppInvocationCatalogEntry _entry(
    AppInvocationSourceLocator locator,
    String title,
    String summary,
    AppletCatalogType type,
    String context,
  ) => AppInvocationCatalogEntry._(
    locator: locator,
    title: title,
    summary: summary,
    type: type,
    scopeKey: scopeKey,
    mountId: mountId,
    requestContextKey: context,
  );

  Future<AppInvocationCatalogPage> listPersonal({
    String query = '',
    AppletCatalogType? type,
  }) async {
    _guard();
    final finish = _beginOperation();
    try {
      final normalized = _query(query).toLowerCase();
      final context = _catalog.requestContextKey;
      final generation = ++_personalGeneration;
      void current() {
        _guard(context);
        if (generation != _personalGeneration) {
          throw const AppInvocationCatalogException('request_superseded');
        }
      }

      final locals = await _guardedResult(_loadLocalWidgets(), current);
      current();
      final local = locals
          .where(
            (item) =>
                item.id != null &&
                _surfaceId(item).trim().isNotEmpty &&
                isAppletPresentationDiscoverable(item, scopeKey: scopeKey),
          )
          .map(_snapshotWidget)
          .toList();
      final entries = <AppInvocationCatalogEntry>[
        for (final item in local)
          _entry(
            AppInvocationSourceLocator._(
              AppInvocationSourceOrigin.local,
              _surfaceId(item),
              localWidgetId: item.id,
            ),
            item.title,
            _summary(item),
            item.spec['experienceType'] == 'game'
                ? AppletCatalogType.game
                : AppletCatalogType.applet,
            context,
          ),
        for (final official in _readOfficial())
          _entry(
            AppInvocationSourceLocator._(
              AppInvocationSourceOrigin.official,
              official.id,
            ),
            official.title,
            '',
            AppletCatalogType.applet,
            context,
          ),
      ];
      current();
      final errors = <AppInvocationSourceOrigin, String>{};
      AppletInventoryPage? inventory;
      try {
        inventory = await _loadOwnedInventory();
      } on AppletInventoryUnavailableException {
        errors[AppInvocationSourceOrigin.ownedCatalog] =
            'owned_inventory_unsupported';
      } catch (_) {
        errors[AppInvocationSourceOrigin.ownedCatalog] =
            'owned_inventory_unavailable';
      }
      current();
      if (inventory != null) {
        final ids = inventory.items.map((item) => item.id).toSet();
        final removed = (_knownOwnedIds ?? const <String>{}).difference(ids);
        _knownOwnedIds = Set.unmodifiable(ids);
        for (final id in removed) {
          await invalidateSource(
            origin: AppInvocationSourceOrigin.ownedCatalog,
            sourceId: id,
            reason: 'owned_source_withdrawn',
          );
          current();
        }
        final localIds = local.map(_surfaceId).toSet();
        final cloudIds = <String>{};
        for (final item in local) {
          final cloud = item.spec['cloud'];
          if (cloud is Map &&
              cloud['scopeKey'] == scopeKey &&
              cloud['gameId'] is String) {
            cloudIds.add(cloud['gameId']! as String);
          }
        }
        for (final item in inventory.items) {
          if (localIds.contains(item.clientSurfaceId) ||
              cloudIds.contains(item.id)) {
            continue;
          }
          entries.add(
            _entry(
              AppInvocationSourceLocator._(
                AppInvocationSourceOrigin.ownedCatalog,
                item.id,
                clientSurfaceId: item.clientSurfaceId,
              ),
              item.title,
              item.summary,
              item.type,
              context,
            ),
          );
        }
      }
      current();
      return AppInvocationCatalogPage._(
        entries: entries
            .where(
              (entry) =>
                  (type == null || entry.type == type) &&
                  (normalized.isEmpty ||
                      '${entry.title} ${entry.summary}'.toLowerCase().contains(
                        normalized,
                      )),
            )
            .toList(),
        requestGeneration: generation,
        sourceErrors: errors,
      );
    } finally {
      finish();
    }
  }

  Future<AppInvocationCatalogPage> searchPublic({
    required AppletCatalogType type,
    String query = '',
    String? cursor,
  }) async {
    _guard();
    final finish = _beginOperation();
    try {
      final normalized = _query(query);
      final context = _catalog.requestContextKey;
      final generation = ++_publicGeneration;
      void current() {
        _guard(context);
        if (generation != _publicGeneration) {
          throw const AppInvocationCatalogException('request_superseded');
        }
      }

      final page = await _guardedResult(
        normalized.isEmpty
            ? _catalog.browse(type: type, cursor: cursor)
            : _catalog.search(query: normalized, type: type, cursor: cursor),
        current,
      );
      return AppInvocationCatalogPage._(
        entries: [
          for (final item in page.items.where((item) => item.type == type))
            _entry(
              AppInvocationSourceLocator._(
                AppInvocationSourceOrigin.publicCatalog,
                item.id,
              ),
              item.title,
              item.summary,
              item.type,
              context,
            ),
        ],
        requestGeneration: generation,
        nextCursor: page.nextCursor,
      );
    } finally {
      finish();
    }
  }

  Future<AppInvocationResolution> resolveSelection(
    AppInvocationCatalogEntry entry,
  ) => _resolve(entry);

  Future<AppInvocationResolution> revalidateSelection(
    AppInvocationSelection selection,
  ) => _resolve(selection.entry, expected: selection);

  /// Restores only a fixed reference. This re-reads the current authorized
  /// source and rejects a changed revision; stored metadata grants no access.
  Future<AppInvocationResolution> revalidateStoredSelection(
    AppInvocationDraftSnapshot snapshot,
  ) {
    _guard();
    if (snapshot.scopeKey != scopeKey) {
      throw const AppInvocationCatalogException('selection_scope_mismatch');
    }
    final origin = AppInvocationSourceOrigin.values.byName(
      snapshot.sourceOrigin,
    );
    if (origin == AppInvocationSourceOrigin.official) {
      throw const AppInvocationCatalogException('official_source_unavailable');
    }
    final entry = _entry(
      AppInvocationSourceLocator._(
        origin,
        snapshot.sourceId,
        localWidgetId: snapshot.localWidgetId,
        clientSurfaceId: snapshot.clientSurfaceId,
      ),
      snapshot.sourceTitle,
      '',
      AppletCatalogType.values.byName(snapshot.sourceType),
      _catalog.requestContextKey,
    );
    return _resolve(
      entry,
      expected: AppInvocationSelection._(
        entry: entry,
        identity: AppInvocationIdentity(
          scopeKey: scopeKey,
          sourceId: snapshot.sourceId,
          revisionId: snapshot.revisionId,
          sourceDigest: snapshot.sourceDigest,
        ),
        contractDigest: snapshot.contractDigest,
        adapterId: snapshot.adapterId,
        adapterVersion: snapshot.adapterVersion,
      ),
    );
  }

  /// Resolves the player's source independently of invocation compatibility.
  /// Local bundles still pass the saved player's installation/permit checks.
  Future<AppInvocationOpenTarget> resolveOpen(
    AppInvocationCatalogEntry entry,
  ) async {
    _guard(entry.requestContextKey);
    final finish = _beginOperation();
    try {
      if (entry.scopeKey != scopeKey || entry.mountId != mountId) {
        throw const AppInvocationCatalogException('selection_scope_mismatch');
      }
      final locator = entry.locator;
      final sourceKey = jsonEncode([locator.origin.name, locator.id]);
      final sourceGeneration = _sourceGenerations[sourceKey] ?? 0;
      void current() {
        _guard(entry.requestContextKey);
        if ((_sourceGenerations[sourceKey] ?? 0) != sourceGeneration) {
          throw const AppInvocationCatalogException('source_retired');
        }
        if (locator.origin == AppInvocationSourceOrigin.ownedCatalog &&
            _knownOwnedIds != null &&
            !_knownOwnedIds!.contains(locator.id)) {
          throw const AppInvocationCatalogException('owned_source_unavailable');
        }
        if (locator.origin == AppInvocationSourceOrigin.official &&
            _readOfficial().where((item) => item.id == locator.id).length !=
                1) {
          throw const AppInvocationCatalogException(
            'official_source_unavailable',
          );
        }
      }

      bool isCurrent() {
        try {
          current();
          return true;
        } on Object {
          return false;
        }
      }

      current();
      if (locator.origin == AppInvocationSourceOrigin.official) {
        return AppInvocationOpenTarget._(
          entry: entry,
          isCurrent: isCurrent,
          officialAppletId: locator.id,
        );
      }
      if (locator.origin == AppInvocationSourceOrigin.local) {
        final records = await _guardedResult(_loadLocalWidgets(), current);
        final matches = records
            .where(
              (item) =>
                  item.id == locator.localWidgetId &&
                  _surfaceId(item) == locator.id &&
                  isAppletPresentationDiscoverable(item, scopeKey: scopeKey),
            )
            .toList();
        if (matches.length != 1) {
          throw const AppInvocationCatalogException('local_source_unavailable');
        }
        final item = _snapshotWidget(matches.single);
        if (item.spec['rendering'] != 'projectBundle' &&
            !item.spec.containsKey('bundleReference')) {
          SurfaceProjectValidator.validateForShow(
            surfaceProjectFromWidget(item),
          );
        }
        current();
        return AppInvocationOpenTarget._(
          entry: entry,
          isCurrent: isCurrent,
          localWidget: item,
        );
      }
      final fetched = await _guardedResult(
        _discovery.source(
          locator.id,
          owned: locator.origin == AppInvocationSourceOrigin.ownedCatalog,
          expectedContextKey: entry.requestContextKey,
        ),
        current,
      );
      // Recheck digest and envelope even for gateways with a public constructor.
      final source = AppletSourceDocument.fromJson({
        'id': fetched.id,
        'clientSurfaceId': fetched.clientSurfaceId,
        'revisionNo': fetched.revisionNo,
        'sourceSha256': fetched.sourceSha256,
        'experienceType': fetched.experienceType,
        'category': fetched.category,
        'skillInstructions': fetched.skillInstructions,
        'surface': fetched.surface,
        'cloud': fetched.cloud,
      });
      if (source.id != locator.id ||
          (locator.clientSurfaceId != null &&
              source.clientSurfaceId != locator.clientSurfaceId)) {
        throw const AppInvocationCatalogException('source_identity_mismatch');
      }
      final project = SurfaceProject.fromJson(
        source.toProjectJson(instanceId: source.id),
      );
      if (source.experienceType == 'game') {
        SurfaceProjectValidator.validateForPublicGame(project);
      } else {
        SurfaceProjectValidator.validateForPublicApplet(project);
      }
      current();
      return AppInvocationOpenTarget._(
        entry: entry,
        isCurrent: isCurrent,
        surface: project,
      );
    } finally {
      finish();
    }
  }

  Future<AppInvocationResolution> _resolve(
    AppInvocationCatalogEntry entry, {
    AppInvocationSelection? expected,
  }) async {
    _guard(entry.requestContextKey);
    final finish = _beginOperation();
    try {
      if (entry.scopeKey != scopeKey || entry.mountId != mountId) {
        throw const AppInvocationCatalogException('selection_scope_mismatch');
      }
      final generation = ++_resolveGeneration;
      bool Function()? sourceIsCurrent;
      void current() {
        _guard(entry.requestContextKey);
        if (generation != _resolveGeneration) {
          throw const AppInvocationCatalogException('request_superseded');
        }
        if (sourceIsCurrent?.call() == false) {
          throw const AppInvocationCatalogException('source_retired');
        }
      }

      final locator = entry.locator;
      final sourceKey = jsonEncode([locator.origin.name, locator.id]);
      final sourceGeneration = _sourceGenerations[sourceKey] ?? 0;
      if (locator.origin == AppInvocationSourceOrigin.official) {
        final matches = _readOfficial()
            .where((item) => item.id == locator.id)
            .toList();
        current();
        if (matches.length != 1) {
          throw const AppInvocationCatalogException(
            'official_source_unavailable',
          );
        }
        return AppInvocationResolution._(
          entry: _entry(
            locator,
            matches.single.title,
            '',
            entry.type,
            entry.requestContextKey,
          ),
          status: AppInvocationCompatibilityStatus.openOnly,
          reason: 'official_invocation_contract_unverified',
        );
      }
      final ticket = await _sidecars.beginSourceRead(
        sourceOrigin: locator.origin.name,
        sourceId: locator.id,
      );
      current();
      AppInvocationDescriptor descriptor;
      SurfaceProject? pinnedSurface;
      InstalledProjectBundleV2? pinnedBundle;
      var title = entry.title;
      var summary = entry.summary;
      var type = entry.type;
      if (locator.origin == AppInvocationSourceOrigin.local) {
        final records = await _guardedResult(_loadLocalWidgets(), current);
        current();
        final matching = records
            .where(
              (item) =>
                  item.id == locator.localWidgetId &&
                  _surfaceId(item) == locator.id &&
                  isAppletPresentationDiscoverable(item, scopeKey: scopeKey),
            )
            .toList();
        if (matching.length != 1) {
          await _invalidate(locator, 'local_source_unavailable');
          current();
          throw const AppInvocationCatalogException('local_source_unavailable');
        }
        final item = _snapshotWidget(matching.single);
        title = item.title;
        summary = _summary(item);
        type = item.spec['experienceType'] == 'game'
            ? AppletCatalogType.game
            : AppletCatalogType.applet;
        if (item.spec['rendering'] == 'projectBundle' ||
            item.spec.containsKey('bundleReference')) {
          final readBundle = _readInstalledBundle;
          if (readBundle == null) {
            return AppInvocationResolution._(
              entry: entry,
              status: AppInvocationCompatibilityStatus.pendingVerification,
              reason: 'verified_bundle_reader_unavailable',
            );
          }
          final reference = item.spec['bundleReference'];
          if (reference is! Map ||
              reference['packageSchema'] != 2 ||
              reference['projectId'] != locator.id) {
            throw const AppInvocationCatalogException(
              'invalid_bundle_reference',
            );
          }
          final installed = await _guardedResult(readBundle(item), current);
          current();
          if (installed == null ||
              !installed.isCurrent ||
              !installed.isAccepted) {
            throw const AppInvocationCatalogException(
              'verified_bundle_unavailable',
            );
          }
          sourceIsCurrent = () => installed.isCurrent;
          pinnedBundle = installed;
          if (installed.bundle.manifest.projectId != locator.id ||
              installed.bundle.manifest.revisionId != reference['revisionId'] ||
              installed.candidateDigest != reference['candidateDigest']) {
            await _invalidate(locator, 'source_version_changed');
            current();
            throw const AppInvocationCatalogException('selection_stale');
          }
          descriptor = AppInvocationDescriptor.fromValidatedBundle(
            bundle: installed.bundle,
            scopeKey: scopeKey,
          );
        } else {
          final project = surfaceProjectFromWidget(item);
          pinnedSurface = project;
          SurfaceProjectValidator.validateForShow(project);
          descriptor = AppInvocationDescriptor.fromSurface(
            project: project,
            identity: AppInvocationIdentity(
              scopeKey: scopeKey,
              sourceId: project.id,
              revisionId:
                  'local:${surfaceVersionFingerprint(item.spec, title: item.title)}',
              sourceDigest: surfaceSourceSha256(
                surfaceVersionSource(item.spec, title: item.title),
              ),
            ),
          );
        }
      } else {
        final owned = locator.origin == AppInvocationSourceOrigin.ownedCatalog;
        Future<void> ownerCurrent() async {
          current();
          if (owned &&
              _knownOwnedIds != null &&
              !_knownOwnedIds!.contains(locator.id)) {
            await _invalidate(locator, 'owned_source_withdrawn');
            current();
            throw const AppInvocationCatalogException(
              'owned_source_unavailable',
            );
          }
        }

        await ownerCurrent();
        late final AppletSourceDocument source;
        try {
          final fetched = await _discovery.source(
            locator.id,
            owned: owned,
            expectedContextKey: entry.requestContextKey,
          );
          current();
          await ownerCurrent();
          // The model has a public constructor; recheck the authenticated source
          // envelope/digest at this read boundary instead of trusting its type.
          source = AppletSourceDocument.fromJson({
            'id': fetched.id,
            'clientSurfaceId': fetched.clientSurfaceId,
            'revisionNo': fetched.revisionNo,
            'sourceSha256': fetched.sourceSha256,
            'experienceType': fetched.experienceType,
            'category': fetched.category,
            'skillInstructions': fetched.skillInstructions,
            'surface': fetched.surface,
            'cloud': fetched.cloud,
          });
        } on AppletCatalogRequestException catch (error) {
          current();
          if (!error.routeMissing &&
              const {401, 403, 404, 410}.contains(error.statusCode)) {
            await _invalidate(
              locator,
              error.statusCode == 401
                  ? 'source_authentication_required'
                  : 'source_withdrawn',
            );
            current();
            throw AppInvocationCatalogException(
              error.statusCode == 401
                  ? 'source_authentication_required'
                  : 'source_unavailable',
            );
          }
          throw const AppInvocationCatalogException('source_fetch_unavailable');
        } on FormatException {
          current();
          throw const AppInvocationCatalogException('source_invalid');
        } catch (error) {
          current();
          if (error is AppInvocationCatalogException) rethrow;
          throw const AppInvocationCatalogException('source_fetch_unavailable');
        }
        if (source.id != locator.id ||
            (locator.clientSurfaceId != null &&
                source.clientSurfaceId != locator.clientSurfaceId)) {
          throw const AppInvocationCatalogException('source_identity_mismatch');
        }
        final project = SurfaceProject.fromJson(
          source.toProjectJson(instanceId: source.id),
        );
        pinnedSurface = project;
        if (source.experienceType == 'game') {
          SurfaceProjectValidator.validateForPublicGame(project);
        } else {
          SurfaceProjectValidator.validateForPublicApplet(project);
        }
        title = project.title;
        type = source.experienceType == 'game'
            ? AppletCatalogType.game
            : AppletCatalogType.applet;
        descriptor = AppInvocationDescriptor.fromSurface(
          project: project,
          identity: AppInvocationIdentity(
            scopeKey: scopeKey,
            sourceId: source.id,
            revisionId: 'cloud:${source.revisionNo}',
            sourceDigest: source.sourceSha256,
          ),
        );
      }
      current();
      final adapter = _adapterIdentityFor(descriptor.runtimeKind);
      if (expected != null &&
          (!expected.identity.matches(descriptor.identity) ||
              expected.contractDigest != descriptor.contractDigest ||
              expected.adapterId != adapter.id ||
              expected.adapterVersion != adapter.version)) {
        await _invalidate(locator, 'source_version_changed');
        current();
        throw const AppInvocationCatalogException('selection_stale');
      }
      final resolvedEntry = _entry(
        locator,
        title,
        summary,
        type,
        entry.requestContextKey,
      );
      if (descriptor.contractIssues.isNotEmpty) {
        return AppInvocationResolution._(
          entry: resolvedEntry,
          descriptor: descriptor,
          status: AppInvocationCompatibilityStatus.invalidContract,
          reason: 'source_contract_invalid',
        );
      }
      final cached = await _sidecars.readForDescriptor(
        descriptor: descriptor,
        sourceOrigin: locator.origin.name,
        adapterId: adapter.id,
        adapterVersion: adapter.version,
      );
      current();
      // Even a cache hit must settle the pre-fetch ticket. Otherwise a source
      // invalidated and freshly restored during this read could accept old work.
      final sidecar = await _sidecars.putForDescriptor(
        descriptor: descriptor,
        ticket: ticket,
        adapterId: adapter.id,
        adapterVersion: adapter.version,
        generatedAt: cached?.generatedAt ?? _now(),
      );
      current();
      bool pinnedIsCurrent() {
        try {
          // Resolving a different draft only supersedes an in-flight lookup.
          // Once returned, this immutable source belongs to its invoking turn,
          // not to the next picker request or draft selection.
          _guard(entry.requestContextKey);
          return sourceIsCurrent?.call() != false &&
              (_sourceGenerations[sourceKey] ?? 0) == sourceGeneration &&
              (locator.origin != AppInvocationSourceOrigin.ownedCatalog ||
                  _knownOwnedIds == null ||
                  _knownOwnedIds!.contains(locator.id));
        } on Object {
          return false;
        }
      }

      if (!pinnedIsCurrent()) {
        throw const AppInvocationCatalogException('source_retired');
      }
      return AppInvocationResolution._(
        entry: resolvedEntry,
        descriptor: descriptor,
        sidecar: sidecar,
        executableSource: AppInvocationPinnedSource._(
          identity: descriptor.identity,
          contractDigest: descriptor.contractDigest,
          locator: resolvedEntry.locator,
          type: resolvedEntry.type,
          title: resolvedEntry.title,
          isCurrent: pinnedIsCurrent,
          surface: pinnedSurface,
          installedBundle: pinnedBundle,
        ),
        selection: AppInvocationSelection._(
          entry: resolvedEntry,
          identity: descriptor.identity,
          contractDigest: descriptor.contractDigest,
          adapterId: adapter.id,
          adapterVersion: adapter.version,
        ),
        status:
            descriptor.actions.isEmpty ||
                descriptor.runtimeKind == AppInvocationRuntimeKind.workerCanvas
            ? AppInvocationCompatibilityStatus.openOnly
            : AppInvocationCompatibilityStatus.pendingVerification,
        reason: descriptor.actions.isEmpty
            ? 'no_declared_actions'
            : descriptor.runtimeKind == AppInvocationRuntimeKind.workerCanvas
            ? 'runtime_requires_manual_open'
            : 'runtime_verification_required',
      );
    } finally {
      finish();
    }
  }

  Future<void> _invalidate(AppInvocationSourceLocator locator, String reason) =>
      invalidateSource(
        origin: locator.origin,
        sourceId: locator.id,
        reason: reason,
      );

  /// Host-reported known withdrawal; partial search omissions are not evidence.
  Future<void> invalidateSource({
    required AppInvocationSourceOrigin origin,
    required String sourceId,
    required String reason,
  }) async {
    final finish = _beginOperation();
    try {
      final key = jsonEncode([origin.name, sourceId]);
      _sourceGenerations[key] = (_sourceGenerations[key] ?? 0) + 1;
      await _sidecars.invalidateSource(
        sourceOrigin: origin.name,
        sourceId: sourceId,
        reason: reason,
      );
      _guard();
    } finally {
      finish();
    }
  }

  void retire() {
    _retired = true;
    _personalGeneration++;
    _publicGeneration++;
    _resolveGeneration++;
  }

  Future<void> deactivateAndDrain() async {
    retire();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}

Map<String, Object?> _snapshotExecutionSource(SurfaceProject project) {
  final source = {
    ...surfaceVersionSource(project.toJson(), title: project.title),
    'id': project.id,
    'kind': project.kind.name,
  };
  const ProjectJsonCanonicalizer(
    maxBytes: 6 * SurfaceProjectValidator.maximumPublicSourceBytes + 512 * 1024,
  ).canonicalize(source);
  return _freezeExecutionValue(source)! as Map<String, Object?>;
}

Object? _freezeExecutionValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeExecutionValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeExecutionValue));
  }
  return value;
}

AgentWidget _snapshotWidget(AgentWidget item) => AgentWidget.fromJson(
  Map<String, Object?>.from(jsonDecode(jsonEncode(item.toJson())) as Map),
  id: item.id,
);

String _surfaceId(AgentWidget item) =>
    (item.spec['surfaceId'] ?? item.spec['id'] ?? 'surface_${item.id ?? ''}')
        .toString();

String _summary(AgentWidget item) {
  final value = item.subtitle ?? item.spec['summary'];
  return value is String ? value : '';
}

Future<T> _guardedResult<T>(Future<T> work, void Function() current) async {
  try {
    final result = await work;
    current();
    return result;
  } catch (_) {
    current();
    rethrow;
  }
}
