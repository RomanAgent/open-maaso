import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog_provider.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/applets/domain/official_applet.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_bundle_install_authority.dart';
import 'support/project_bundle_v2_fixture.dart';

const _skill = 'ble_yoturetoys_projector';
const _scopeKey = 'https://example.test|owner-a';
const _quota = AppletQuotaSnapshot(used: 0, limit: 5);

void main() {
  late AccountStorageScopeService scopes;
  late AccountStorageScopeMount mount;
  late DBService database;
  late ProjectBundleInstallationStore installations;
  late AppInvocationCatalogProvider provider;
  late Directory directory;
  late _Catalog service;
  Set<String> enabled = {};
  AppCapabilitySnapshot? snapshot;
  var officialBuilds = 0, enabledReads = 0, caseNumber = 0;
  final providers = <AppInvocationCatalogProvider>[];

  AppCapabilitySnapshot capabilities({bool allowed = true, int? generation}) =>
      AppCapabilitySnapshot.materialize(
        generation: 1,
        draft: AppCapabilitySnapshotDraft(
          context: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.ios,
            rolloutGeneration: 0,
            accountScopeDigest: mount.scope.accountDigest,
            accountGeneration: generation ?? mount.generation,
          ),
          decisions: [
            if (allowed)
              AppCapabilityDecision.available(AppCapabilityKey.skill(_skill)),
          ],
        ),
      );

  AppInvocationCatalogProvider create({ProjectBundleInstallationStore? store}) {
    final result = AppInvocationCatalogProvider(
      database: database,
      mount: mount,
      storageScopes: scopes,
      accountBaseUri: Uri.parse('https://example.test/'),
      catalogService: service,
      installations: store ?? installations,
      enabledSkillIds: () {
        enabledReads++;
        return enabled;
      },
      capabilitySnapshot: () => snapshot,
      adapterIdentityFor: AppInvocationRuntimeRegistry.identityFor,
      currentAppletScope: () => scopes.activeScope == null
          ? ''
          : 'https://example.test|${scopes.activeScope!.accountUuid}',
      officialApplets: () => [
        for (final entry in [
          (id: 'real-official', skill: _skill),
          (id: 'unknown-official', skill: 'undeclared-skill'),
          (id: 'metadata-only', skill: null),
        ])
          OfficialApplet(
            id: entry.id,
            nameKey: entry.id,
            icon: Icons.apps,
            color: Colors.blue,
            requiresSkillId: entry.skill,
            builder: () {
              officialBuilds++;
              return const SizedBox();
            },
          ),
      ],
    );
    providers.add(result);
    return result;
  }

  setUp(() async {
    scopes = AccountStorageScopeService();
    mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'owner-a'),
    );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'invocation-provider-${caseNumber++}.db',
    );
    directory = await Directory.systemTemp.createTemp('invocation-provider-');
    service = _Catalog();
    enabled = {};
    snapshot = null;
    officialBuilds = enabledReads = 0;
    installations = ProjectBundleInstallationStore(
      database: database.raw,
      accountScope: mount.scope,
      applicationSupportRoot: directory,
      projectBuildScopeKey: 'test|owner-a',
      isCurrent: () => scopes.isCurrent(mount),
    );
    provider = create();
  });
  tearDown(() async {
    for (final value in providers) {
      await value.deactivateAndDrain();
    }
    providers.clear();
    await installations.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'construction registers no network, skill factory, source or bundle work',
    () {
      expect(service.calls, 0);
      expect(enabledReads, 0);
      expect(officialBuilds, 0);
      expect(provider.catalog.scopeKey, _scopeKey);
      expect(provider.sidecars.mountId, provider.mountId);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'official metadata needs live enabled, implemented and account-matched capabilities',
    () async {
      enabled = {_skill, 'undeclared-skill'};
      expect((await provider.catalog.listPersonal()).entries, isEmpty);
      snapshot = capabilities();
      final page = await provider.catalog.listPersonal();
      expect(page.entries.map((entry) => entry.locator.id), ['real-official']);
      final resolution = await provider.catalog.resolveSelection(
        page.entries.single,
      );
      expect(resolution.status, AppInvocationCompatibilityStatus.openOnly);
      expect(resolution.executableSource, isNull);
      expect(officialBuilds, 0);
      enabled = {};
      expect((await provider.catalog.listPersonal()).entries, isEmpty);
      enabled = {_skill};
      snapshot = capabilities(allowed: false);
      expect((await provider.catalog.listPersonal()).entries, isEmpty);
      snapshot = capabilities(generation: mount.generation + 1);
      expect((await provider.catalog.listPersonal()).entries, isEmpty);
    },
  );

  test(
    'source lookup is on demand and still does not certify execution',
    () async {
      final entry = (await provider.catalog.searchPublic(
        type: AppletCatalogType.applet,
      )).entries.single;
      expect(service.calls, 1);
      final resolved = await provider.catalog.resolveSelection(entry);
      expect(service.calls, 2);
      expect(
        resolved.status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect(resolved.executableSource!.surface!.html, '<main>Original</main>');
      expect(
        resolved.executableSource!.identity.sourceDigest,
        service.document.sourceSha256,
      );
    },
  );

  test(
    'account A to B to A creates a new owner and rejects old handles',
    () async {
      final entry = (await provider.catalog.searchPublic(
        type: AppletCatalogType.applet,
      )).entries.single;
      final old = await provider.catalog.resolveSelection(entry);
      final originalMountId = provider.mountId;
      scopes.unmount(mount);
      final other = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'owner-b'),
      );
      expect(old.executableSource!.isCurrent, isFalse);
      scopes.unmount(other);
      mount = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'owner-a'),
      );
      final replacement = create();
      expect(replacement.mountId, isNot(originalMountId));
      await expectLater(
        provider.catalog.listPersonal(),
        throwsA(isA<AppInvocationCatalogException>()),
      );
      await expectLater(
        replacement.catalog.resolveSelection(entry),
        throwsA(isA<AppInvocationCatalogException>()),
      );
      expect(
        (await replacement.catalog.searchPublic(
          type: AppletCatalogType.applet,
        )).entries,
        hasLength(1),
      );
    },
  );

  test(
    'retirement waits for pending directory work but leaves the shared DB open',
    () async {
      final response = Completer<AppletSourceDocument>(),
          entered = Completer<void>();
      service.onSource = () {
        entered.complete();
        return response.future;
      };
      final entry = (await provider.catalog.searchPublic(
        type: AppletCatalogType.applet,
      )).entries.single;
      final resolving = expectLater(
        provider.catalog.resolveSelection(entry),
        throwsA(isA<AppInvocationCatalogException>()),
      );
      await entered.future;
      var drained = false;
      final drain = provider.deactivateAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      response.complete(service.document);
      await resolving;
      await drain;
      expect(drained, isTrue);
      expect(await database.getAllWidgets(), isEmpty);
      expect(
        await stringMapStoreFactory
            .store('app_invocation_sidecars.v1')
            .count(database.raw),
        0,
      );
    },
  );

  test(
    'a cached accepted V2 source is read without changing its head or app data',
    () async {
      final bundle = productionBundleFixture();
      final installed = await testInstallBundle(
        installations,
        bundle,
        expectedScopeKey: installations.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final widget = AgentWidget(
        agentId: 'self',
        title: bundle.title,
        kind: 'surface',
        createdAt: DateTime.utc(2026),
        spec: {
          'surfaceId': bundle.manifest.projectId,
          'rendering': 'projectBundle',
          'experienceType': 'utility',
          'bundleReference': {
            'packageSchema': 2,
            'projectId': bundle.manifest.projectId,
            'revisionId': bundle.manifest.revisionId,
            'candidateDigest': bundle.candidateDigest,
            'reportDigest': projectBundleV2JsonDigest(
              installed.verificationReport!,
            ),
          },
        },
      );
      AppletLocalOwnership.stamp(widget, scopeKey: _scopeKey);
      await database.saveAgentWidget(widget);
      final original = widget.toJson();
      final dataBefore = await installations.readApplicationData(
        bundle.candidateDigest,
        expectedScopeKey: installations.scopeKey,
        role: ProjectBundleDataRole.installed,
      );
      final entry = (await provider.catalog.listPersonal()).entries.single;
      final result = await provider.catalog.resolveSelection(entry);
      expect(
        result.executableSource!.installedBundle!.candidateDigest,
        bundle.candidateDigest,
      );
      expect(result.executableSource!.surface, isNull);
      expect(
        result.status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect((await database.getAllWidgets()).single.toJson(), original);
      expect(
        (await installations.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: installations.scopeKey,
        ))!.candidateDigest,
        bundle.candidateDigest,
      );
      final dataAfter = await installations.readApplicationData(
        bundle.candidateDigest,
        expectedScopeKey: installations.scopeKey,
        role: ProjectBundleDataRole.installed,
      );
      expect(dataAfter.version, dataBefore.version);
      expect(dataAfter.values, dataBefore.values);
      installations.reconcileOwnedPresentations(
        {},
        expectedScopeKey: installations.scopeKey,
      );
      expect(result.executableSource!.isCurrent, isFalse);
      await expectLater(
        provider.catalog.revalidateSelection(result.selection!),
        throwsA(isA<AppInvocationCatalogException>()),
      );
    },
  );

  test(
    'foreign-account installations cannot be injected into the mount',
    () async {
      final foreign = ProjectBundleInstallationStore(
        database: database.raw,
        accountScope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'other-owner',
        ),
        applicationSupportRoot: directory,
        isCurrent: () => true,
      );
      expect(() => create(store: foreign), throwsArgumentError);
      await foreign.deactivateAndDrain();
    },
  );
}

final class _Catalog implements AppletCatalogService {
  int calls = 0;
  Future<AppletSourceDocument> Function()? onSource;
  @override
  String get requestContextKey => 'test|owner-a|en';
  AppletSourceDocument get document {
    final surface = <String, Object?>{
      'title': 'Generic',
      'rendering': 'webApp',
      'html': '<main>Original</main>',
      'css': '',
      'js': 'Surface.onAgent = (name, args) => args;',
      'manifest': {
        'events': [],
        'actions': [
          {
            'name': 'custom.transform',
            'schema': {'input': 'string'},
          },
        ],
      },
    };
    return AppletSourceDocument.fromJson({
      'id': 'remote',
      'clientSurfaceId': 'remote-source',
      'revisionNo': 1,
      'sourceSha256': surfaceSourceSha256(surface),
      'experienceType': 'utility',
      'category': '',
      'skillInstructions': '',
      'surface': surface,
    });
  }

  @override
  Future<AppletInventoryPage> mine() async {
    calls++;
    return const AppletInventoryPage(items: [], quota: _quota);
  }

  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async {
    calls++;
    return AppletCatalogPage(
      items: [
        AppletCatalogItem(
          id: 'remote',
          title: 'Generic',
          type: type,
          summary: 'Any declared action',
          author: const AppletCatalogAuthor(
            agentId: 'author',
            displayName: 'Author',
            verified: false,
          ),
          shareUrl: Uri.parse('https://example.test/g/remote'),
          updatedAt: DateTime.utc(2026),
        ),
      ],
      quota: _quota,
    );
  }

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async {
    calls++;
    if (onSource case final read?) return read();
    return document;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
