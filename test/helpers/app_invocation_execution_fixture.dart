import 'dart:async';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:sembast/sembast.dart';

/// Produces real pinned sources through the production catalog. No test-only
/// capability constructor or model-authored reference bypass is introduced.
class InvocationCatalogFixture {
  InvocationCatalogFixture({
    required Database database,
    required this.scopeKey,
    this.mountId = 'fixture-mount',
    required this.isCurrent,
  }) {
    sidecars = AppInvocationSidecarStore(
      database: database,
      scopeKey: scopeKey,
      mountId: mountId,
      currentMountId: () => mountId,
      isCurrent: isCurrent,
    );
    final gateway = _FixtureGateway();
    catalog = AppInvocationCatalog(
      catalog: gateway,
      discovery: gateway,
      loadLocalWidgets: () async => works,
      loadOwnedInventory: () async => const AppletInventoryPage(
        items: [],
        quota: AppletQuotaSnapshot(used: 0, limit: 5),
      ),
      readAvailableOfficialApplets: () => [],
      sidecars: sidecars,
      adapterIdentityFor: AppInvocationRuntimeRegistry.identityFor,
      scopeKey: scopeKey,
      mountId: mountId,
      currentScopeKey: () => scopeKey,
      currentMountId: () => mountId,
      isCurrent: isCurrent,
    );
  }
  final String scopeKey, mountId;
  final bool Function() isCurrent;
  late final AppInvocationSidecarStore sidecars;
  late final AppInvocationCatalog catalog;
  final works = <AgentWidget>[];
  Future<
    ({
      AppInvocationPinnedSource source,
      AppInvocationDescriptor descriptor,
      AgentWidget work,
    })
  >
  pin({
    required String action,
    required Map<String, Object?> schema,
    String docs = '',
    String title = 'Test work',
  }) async {
    final id = works.length + 1;
    final work = AgentWidget(
      id: id,
      agentId: 'self',
      title: title,
      createdAt: DateTime.utc(2026),
      kind: 'surface',
      spec: {
        'surfaceId': 'test-work-$id',
        'experienceType': 'utility',
        'title': title,
        'rendering': 'webApp',
        'html': '<main>Unchanged source</main>',
        'css': '',
        'js': 'Surface.onAgent = (name, args) => args;',
        if (docs.isNotEmpty) 'skillInstructions': docs,
        'manifest': {
          'schemaVersion': 2,
          'actions': [
            {
              'name': action,
              'schema': schema,
              'risk': 'localMutation',
              'consequencePolicy': 'reversible',
            },
          ],
          'events': <Object?>[],
        },
      },
    );
    AppletLocalOwnership.stamp(work, scopeKey: scopeKey);
    works.add(work);
    final entries = await catalog.listPersonal();
    final entry = entries.entries.singleWhere(
      (entry) => entry.locator.localWidgetId == id,
    );
    final resolved = await catalog.resolveSelection(entry);
    if (resolved.status !=
            AppInvocationCompatibilityStatus.pendingVerification ||
        resolved.executableSource == null ||
        resolved.descriptor == null) {
      throw StateError(
        'fixture_source_unavailable:${resolved.status}:${resolved.reason}',
      );
    }
    return (
      source: resolved.executableSource!,
      descriptor: resolved.descriptor!,
      work: work,
    );
  }

  void retire() {
    catalog.retire();
    sidecars.retire();
  }
}

/// Explicit native backend double. These tests prove Dart policy and transport
/// integration only; they do not prove browser isolation or authored JS execution.
class InvocationBackendFixture implements AppInvocationBackend {
  InvocationBackendFixture(this.request);
  final AppInvocationHostRequest request;
  final invoked =
      <
        ({
          String action,
          Map<String, Object?> arguments,
          String requestId,
          List<AppInvocationInputImage> images,
        })
      >[];
  final receiptRequests = <String>[];
  Future<AppInvocationBackendResult> Function(
    String action,
    Map<String, Object?> arguments,
    List<AppInvocationInputImage> images,
  )?
  onInvoke;
  Future<AppInvocationBackendResult?> Function(String requestId)? onReceipt;
  bool live = true;
  int closes = 0;
  @override
  bool get isCurrent => live && request.isCurrent();
  @override
  bool get isVisible => false;
  @override
  bool get requiresVisibleHost => false;
  @override
  bool get supportsGameAuthority => false;
  @override
  AppInvocationRuntimeProtocol get protocol =>
      AppInvocationRuntimeProtocol.isolatedWorker;
  @override
  Set<AppInvocationIsolationBoundary> get verifiedBoundaries =>
      AppInvocationIsolationBoundary.values.toSet();
  @override
  Future<Map<String, Object?>> describe() async => {
    'ready': true,
    'actions': request.descriptor.actions.map((action) => action.name).toList(),
    'observationId': 'obs_1',
    'stateVersion': 1,
    'state': <String, Object?>{},
  };
  @override
  Future<AppInvocationBackendResult> invoke(
    String actionId,
    Map<String, Object?> arguments, {
    required String requestId,
    required String observationId,
    required int expectedStateVersion,
    required List<AppInvocationInputImage> inputImages,
  }) async {
    if (!isCurrent || observationId != 'obs_1' || expectedStateVersion != 1)
      throw StateError('fixture_stale_observation');
    invoked.add((
      action: actionId,
      arguments: Map.of(arguments),
      requestId: requestId,
      images: List.of(inputImages),
    ));
    return onInvoke == null
        ? AppInvocationBackendResult(
            status: AppInvocationActionStatus.completed,
            stateVersion: 2,
            result: {'echo': arguments},
          )
        : await onInvoke!(actionId, arguments, inputImages);
  }

  @override
  Future<AppInvocationBackendResult?> receipt(String requestId) async {
    receiptRequests.add(requestId);
    return await onReceipt?.call(requestId);
  }

  @override
  void fence() {
    live = false;
  }

  @override
  Future<void> close() async {
    fence();
    closes++;
  }
}

class _FixtureGateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  @override
  String get requestContextKey => 'fixture|native|en';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
