import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:sembast/sembast_memory.dart';

const _scope = 'https://example.test|owner';
const _quota = AppletQuotaSnapshot(used: 1, limit: 5);
final _now = DateTime.utc(2026, 10, 21, 12);

Map<String, Object?> _surface({
  String title = 'Any function',
  String action = 'custom.run',
  String document = '',
}) => {
  'title': title,
  'rendering': 'webApp',
  'html': '<main>$title</main>',
  'css': '',
  'js': 'Surface.onAgent = (name, args) => args;',
  'skillInstructions': document,
  'manifest': {
    'schemaVersion': 2,
    'actions': [
      {
        'name': action,
        'schema': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'maxLength': 100},
          },
          'required': ['text'],
          'additionalProperties': false,
        },
        'risk': 'localMutation',
        'consequencePolicy': 'reversible',
      },
    ],
    'events': <Object?>[],
  },
};

AppletSourceDocument _source({
  String id = 'remote-work',
  String clientId = 'client-work',
  int revision = 1,
  String action = 'custom.run',
  String title = 'Any function',
  String document = '',
}) {
  final surface = _surface(title: title, action: action, document: document);
  return AppletSourceDocument.fromJson({
    'id': id,
    'clientSurfaceId': clientId,
    'revisionNo': revision,
    'sourceSha256': surfaceSourceSha256(surface),
    'experienceType': 'utility',
    'category': '',
    'skillInstructions': document,
    'surface': surface,
  });
}

AgentWidget _local({
  int id = 1,
  String surfaceId = 'local-work',
  String scope = _scope,
}) {
  final item = AgentWidget(
    id: id,
    agentId: 'self',
    title: 'Local work $id',
    subtitle: 'Independent local functionality',
    kind: 'surface',
    createdAt: _now,
    spec: {..._surface(), 'surfaceId': surfaceId, 'experienceType': 'utility'},
  );
  AppletLocalOwnership.stamp(item, scopeKey: scope);
  return item;
}

AppletCatalogItem _public({
  String id = 'remote-work',
  AppletCatalogType type = AppletCatalogType.applet,
}) => AppletCatalogItem(
  id: id,
  title: 'Public work',
  type: type,
  summary: 'Functions of any kind',
  author: const AppletCatalogAuthor(
    agentId: 'author',
    displayName: 'Author',
    verified: false,
  ),
  shareUrl: Uri.parse('https://example.test/g/$id'),
  updatedAt: _now,
);

AppletInventoryItem _owned({
  String id = 'remote-work',
  String clientId = 'client-work',
}) => AppletInventoryItem(
  id: id,
  clientSurfaceId: clientId,
  title: 'Owned work',
  type: AppletCatalogType.applet,
  summary: 'Owned functionality',
  published: true,
  updatedAt: _now,
);

final class _Gateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  String context = 'test|owner|en';
  @override
  String get requestContextKey => context;
  List<AppletCatalogItem> items = [_public()];
  String? nextCursor;
  AppletSourceDocument document = _source();
  final requests =
      <
        ({String query, AppletCatalogType? type, String? cursor, bool browse})
      >[];
  Future<AppletCatalogPage> Function(String query)? onSearch;
  Future<AppletSourceDocument> Function(String id, bool owned)? onSource;
  final sourceCalls = <({String id, bool owned, String context})>[];

  @override
  Future<AppletCatalogPage> search({
    required String query,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    requests.add((query: query, type: type, cursor: cursor, browse: false));
    final callback = onSearch;
    if (callback != null) return callback(query);
    return AppletCatalogPage(
      items: items,
      quota: _quota,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async {
    requests.add((query: '', type: type, cursor: cursor, browse: true));
    return AppletCatalogPage(
      items: items,
      quota: _quota,
      nextCursor: nextCursor,
    );
  }

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async {
    sourceCalls.add((id: id, owned: owned, context: expectedContextKey));
    final callback = onSource;
    if (callback != null) return callback(id, owned);
    return document;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Matcher _code(String code) => throwsA(
  isA<AppInvocationCatalogException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

void main() {
  late _Gateway gateway;
  late AppInvocationCatalog catalog;
  late AppInvocationSidecarStore sidecars;
  late List<AgentWidget> locals;
  late List<AppletInventoryItem> owned;
  late List<({String id, String title})> official;
  var mount = 'mount-1', scope = _scope, adapterVersion = '1';
  var current = true;
  Object? ownedError;
  var number = 0;
  Future<InstalledProjectBundleV2?> Function(AgentWidget)? bundleReader;

  AppInvocationCatalog create() => AppInvocationCatalog(
    catalog: gateway,
    discovery: gateway,
    loadLocalWidgets: () async => locals,
    loadOwnedInventory: () async {
      if (ownedError case final error?) throw error;
      return AppletInventoryPage(items: owned, quota: _quota);
    },
    readAvailableOfficialApplets: () => official,
    sidecars: sidecars,
    adapterIdentityFor: (_) => (id: 'surface-bridge', version: adapterVersion),
    scopeKey: _scope,
    mountId: 'mount-1',
    currentScopeKey: () => scope,
    currentMountId: () => mount,
    isCurrent: () => current,
    readInstalledBundle: bundleReader,
    now: () => _now,
  );

  Future<AppInvocationCatalogEntry> publicEntry() async =>
      (await catalog.searchPublic(
        type: AppletCatalogType.applet,
      )).entries.single;

  setUp(() async {
    gateway = _Gateway();
    locals = [];
    owned = [];
    official = [];
    mount = 'mount-1';
    scope = _scope;
    adapterVersion = '1';
    current = true;
    ownedError = null;
    bundleReader = null;
    final db = await databaseFactoryMemory.openDatabase(
      'invocation-catalog-${number++}.db',
    );
    sidecars = AppInvocationSidecarStore(
      database: db,
      scopeKey: _scope,
      mountId: mount,
      currentMountId: () => mount,
      isCurrent: () => current && scope == _scope,
    );
    catalog = create();
    addTearDown(() async {
      catalog.retire();
      sidecars.retire();
      await db.close();
    });
  });

  test(
    'personal list merges real sources, filters owner markers and deduplicates real IDs',
    () async {
      final visible = _local(surfaceId: 'client-work');
      final pending = _local(id: 2)..spec['presentationPending'] = true;
      final deleted = _local(id: 3)..spec['cloudDelete'] = {'pending': true};
      locals = [visible, pending, deleted, _local(id: 4, scope: 'other|owner')];
      owned = [_owned(), _owned(id: 'cloud-only', clientId: 'other-client')];
      official = [(id: 'available-official', title: 'Official utility')];
      final before = jsonEncode(locals.map((item) => item.toJson()).toList());
      final page = await catalog.listPersonal();
      expect(page.entries.map((entry) => entry.locator.id), [
        'client-work',
        'available-official',
        'cloud-only',
      ]);
      expect(page.entries.map((entry) => entry.locator.origin), [
        AppInvocationSourceOrigin.local,
        AppInvocationSourceOrigin.official,
        AppInvocationSourceOrigin.ownedCatalog,
      ]);
      expect(jsonEncode(locals.map((item) => item.toJson()).toList()), before);
      expect(
        (await catalog.listPersonal(
          query: 'independent',
        )).entries.single.locator.origin,
        AppInvocationSourceOrigin.local,
      );
    },
  );

  test(
    'owned failures preserve local and official rows without claiming withdrawal',
    () async {
      locals = [_local()];
      official = [(id: 'official', title: 'Available official')];
      ownedError = const AppletInventoryUnavailableException();
      final page = await catalog.listPersonal();
      expect(page.entries, hasLength(2));
      expect(
        page.sourceErrors[AppInvocationSourceOrigin.ownedCatalog],
        'owned_inventory_unsupported',
      );
    },
  );

  test(
    'empty public queries browse; searches retain normalized text, type and pagination',
    () async {
      gateway.nextCursor = 'page-2';
      final first = await catalog.searchPublic(type: AppletCatalogType.applet);
      expect(gateway.requests.single.browse, isTrue);
      expect(first.nextCursor, 'page-2');
      await catalog.searchPublic(
        type: AppletCatalogType.game,
        query: '  unrelated   function  ',
        cursor: first.nextCursor,
      );
      expect(gateway.requests.last, (
        query: 'unrelated function',
        type: AppletCatalogType.game,
        cursor: 'page-2',
        browse: false,
      ));
      await expectLater(
        catalog.searchPublic(type: AppletCatalogType.applet, query: 'x' * 81),
        _code('invalid_query'),
      );
    },
  );

  test(
    'different arbitrary function names resolve without docs but never enable execution',
    () async {
      final entry = await publicEntry();
      for (final name in [
        'text.decorate',
        'stock.reduce',
        'custom_194.execute',
      ]) {
        gateway.document = _source(action: name);
        final result = await catalog.resolveSelection(entry);
        expect(result.descriptor!.actions.single.name, name);
        expect(
          result.sidecar!.documentOrigin,
          AppInvocationSidecarDocumentOrigin.maasoGenerated,
        );
        expect(
          result.status,
          AppInvocationCompatibilityStatus.pendingVerification,
        );
        expect(result.reason, 'runtime_verification_required');
        expect(
          result.selection!.identity.sourceDigest,
          gateway.document.sourceSha256,
        );
        expect(gateway.sourceCalls.last.context, gateway.context);
      }
    },
  );

  test(
    'local resolution leaves the widget unchanged and detects edit-restore ABA',
    () async {
      final item = _local();
      var history = SurfaceVersionHistory.create(item.spec, title: item.title);
      item.spec['versionHistory'] = history.toJson();
      locals = [item];
      final before = jsonEncode(item.toJson());
      final entry = (await catalog.listPersonal()).entries.single;
      final first = await catalog.resolveSelection(entry);
      expect(
        first.status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect(jsonEncode(item.toJson()), before);
      history = history.append({
        ...item.spec,
        'js': 'changed()',
      }, title: item.title);
      history = history.append(
        item.spec,
        title: item.title,
        restoredFromId: history.versions.first.id,
      );
      item.spec['versionHistory'] = history.toJson();
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('selection_stale'),
      );
    },
  );

  test(
    'public and owned revisions of the same ID remain separate source bindings',
    () async {
      owned = [_owned()];
      gateway.onSource = (id, isOwned) async => _source(
        id: id,
        revision: isOwned ? 2 : 1,
        title: isOwned ? 'Owned draft' : 'Published work',
      );
      final public = await catalog.resolveSelection(await publicEntry());
      final ownedEntry = (await catalog.listPersonal()).entries.single;
      final own = await catalog.resolveSelection(ownedEntry);
      expect(public.selection!.identity.revisionId, 'cloud:1');
      expect(own.selection!.identity.revisionId, 'cloud:2');
      expect(public.sidecar!.sourceOrigin, 'publicCatalog');
      expect(own.sidecar!.sourceOrigin, 'ownedCatalog');
      expect(gateway.sourceCalls.map((call) => call.owned), [false, true]);
    },
  );

  test(
    'removing the local source invalidates its selected description',
    () async {
      locals = [_local()];
      final entry = (await catalog.listPersonal()).entries.single;
      final result = await catalog.resolveSelection(entry);
      locals = [];
      await expectLater(
        catalog.revalidateSelection(result.selection!),
        _code('local_source_unavailable'),
      );
      expect(
        await sidecars.readForDescriptor(
          descriptor: result.descriptor!,
          sourceOrigin: 'local',
          adapterId: 'surface-bridge',
          adapterVersion: '1',
        ),
        isNull,
      );
    },
  );

  test(
    'author documentation without declared actions remains open-only',
    () async {
      final surface = _surface(document: 'Call anything you want');
      (surface['manifest']! as Map)['actions'] = <Object?>[];
      gateway.document = AppletSourceDocument(
        id: 'remote-work',
        clientSurfaceId: 'client-work',
        revisionNo: 1,
        sourceSha256: surfaceSourceSha256(surface),
        experienceType: 'utility',
        category: '',
        skillInstructions: 'Call anything you want',
        surface: surface,
      );
      final result = await catalog.resolveSelection(await publicEntry());
      expect(result.status, AppInvocationCompatibilityStatus.openOnly);
      expect(result.reason, 'no_declared_actions');
      expect(result.descriptor!.actions, isEmpty);
    },
  );

  test(
    'pinned revision, hash and adapter changes require reselection',
    () async {
      final entry = await publicEntry();
      var first = await catalog.resolveSelection(entry);
      gateway.document = _source(revision: 2);
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('selection_stale'),
      );
      first = await catalog.resolveSelection(entry);
      gateway.document = _source(revision: 2, action: 'different.function');
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('selection_stale'),
      );
      first = await catalog.resolveSelection(entry);
      adapterVersion = '2';
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('selection_stale'),
      );
    },
  );

  test(
    'newer search wins and an old page cannot overwrite its generation',
    () async {
      final gate = Completer<AppletCatalogPage>();
      gateway.onSearch = (query) => query == 'old'
          ? gate.future
          : Future.value(
              AppletCatalogPage(
                items: [_public(id: 'new')],
                quota: _quota,
              ),
            );
      final first = expectLater(
        catalog.searchPublic(type: AppletCatalogType.applet, query: 'old'),
        _code('request_superseded'),
      );
      final second = await catalog.searchPublic(
        type: AppletCatalogType.applet,
        query: 'new',
      );
      expect(second.entries.single.locator.id, 'new');
      gate.complete(
        AppletCatalogPage(
          items: [_public(id: 'old')],
          quota: _quota,
        ),
      );
      await first;
    },
  );

  test(
    'late source results cannot cross locale, account or mount changes',
    () async {
      for (final change in ['locale', 'account', 'mount']) {
        final entry = await publicEntry();
        final entered = Completer<void>(),
            response = Completer<AppletSourceDocument>();
        gateway.onSource = (_, _) {
          entered.complete();
          return response.future;
        };
        final result = expectLater(
          catalog.resolveSelection(entry),
          _code(
            change == 'locale' ? 'request_context_changed' : 'scope_retired',
          ),
        );
        await entered.future;
        if (change == 'locale') gateway.context = 'test|owner|zh';
        if (change == 'account') scope = 'https://example.test|different';
        if (change == 'mount') mount = 'mount-new';
        response.complete(_source());
        await result;
        scope = _scope;
        mount = 'mount-1';
        gateway.context = 'test|owner|en';
        gateway.onSource = null;
      }
    },
  );

  test('superseded search failures cannot replace a newer result', () async {
    final response = Completer<AppletCatalogPage>();
    gateway.onSearch = (query) => query == 'old'
        ? response.future
        : Future.value(AppletCatalogPage(items: [_public()], quota: _quota));
    final old = expectLater(
      catalog.searchPublic(type: AppletCatalogType.applet, query: 'old'),
      _code('request_superseded'),
    );
    await catalog.searchPublic(type: AppletCatalogType.applet, query: 'new');
    response.completeError(AppletCatalogRequestException(500, 'FAILED'));
    await old;
  });

  test(
    'a superseded denial cannot revoke the newer successful description',
    () async {
      final entry = await publicEntry();
      final entered = Completer<void>(),
          oldResponse = Completer<AppletSourceDocument>();
      var calls = 0;
      gateway.onSource = (_, _) async {
        if (++calls == 1) {
          entered.complete();
          return oldResponse.future;
        }
        return _source();
      };
      final old = expectLater(
        catalog.resolveSelection(entry),
        _code('request_superseded'),
      );
      await entered.future;
      final fresh = await catalog.resolveSelection(entry);
      oldResponse.completeError(
        AppletCatalogRequestException(404, 'NOT_FOUND'),
      );
      await old;
      expect(
        await sidecars.readForDescriptor(
          descriptor: fresh.descriptor!,
          sourceOrigin: 'publicCatalog',
          adapterId: 'surface-bridge',
          adapterVersion: '1',
        ),
        isNotNull,
      );
    },
  );

  test(
    'withdrawal invalidates cached text and subsequent network failure cannot revive it',
    () async {
      final entry = await publicEntry();
      final first = await catalog.resolveSelection(entry);
      gateway.onSource = (_, _) async =>
          throw AppletCatalogRequestException(404, 'NOT_FOUND');
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('source_unavailable'),
      );
      gateway.onSource = (_, _) async => throw TimeoutException('offline');
      await expectLater(
        catalog.resolveSelection(entry),
        _code('source_fetch_unavailable'),
      );
      expect(
        await sidecars.readForDescriptor(
          descriptor: first.descriptor!,
          sourceOrigin: 'publicCatalog',
          adapterId: 'surface-bridge',
          adapterVersion: '1',
        ),
        isNull,
      );
    },
  );

  test(
    'route absence and rate limits do not claim a source withdrawal',
    () async {
      final entry = await publicEntry();
      final first = await catalog.resolveSelection(entry);
      for (final error in [
        AppletCatalogRequestException(404, 'route_missing', routeMissing: true),
        AppletCatalogRequestException(429, 'RATE_LIMITED'),
        AppletCatalogRequestException(500, 'FAILED'),
      ]) {
        gateway.onSource = (_, _) async => throw error;
        await expectLater(
          catalog.resolveSelection(entry),
          _code('source_fetch_unavailable'),
        );
        expect(
          await sidecars.readForDescriptor(
            descriptor: first.descriptor!,
            sourceOrigin: 'publicCatalog',
            adapterId: 'surface-bridge',
            adapterVersion: '1',
          ),
          isNotNull,
        );
      }
    },
  );

  test(
    'complete owned inventory withdrawal invalidates an old selection',
    () async {
      owned = [_owned()];
      final entry = (await catalog.listPersonal()).entries.single;
      final first = await catalog.resolveSelection(entry);
      owned = [];
      await catalog.listPersonal();
      await expectLater(
        catalog.revalidateSelection(first.selection!),
        _code('owned_source_unavailable'),
      );
      expect(
        await sidecars.readForDescriptor(
          descriptor: first.descriptor!,
          sourceOrigin: 'ownedCatalog',
          adapterId: 'surface-bridge',
          adapterVersion: '1',
        ),
        isNull,
      );
    },
  );

  test('omission from a public page is not withdrawal evidence', () async {
    final entry = await publicEntry();
    final first = await catalog.resolveSelection(entry);
    gateway.items = [];
    await catalog.searchPublic(type: AppletCatalogType.applet);
    expect(
      (await catalog.revalidateSelection(first.selection!)).status,
      AppInvocationCompatibilityStatus.pendingVerification,
    );
  });

  test(
    'official items are rechecked and never invent an invocation contract',
    () async {
      official = [(id: 'projector', title: 'Enabled official app')];
      final entry = (await catalog.listPersonal()).entries.single;
      final result = await catalog.resolveSelection(entry);
      expect(result.status, AppInvocationCompatibilityStatus.openOnly);
      expect(result.descriptor, isNull);
      expect(result.selection, isNull);
      official = [];
      await expectLater(
        catalog.resolveSelection(entry),
        _code('official_source_unavailable'),
      );
      expect(gateway.sourceCalls, isEmpty);
    },
  );

  test(
    'bundle references never fall back to ordinary unverified Surface source',
    () async {
      final item = _local()
        ..spec.addAll({
          'rendering': 'projectBundle',
          'bundleReference': {
            'packageSchema': 2,
            'projectId': 'local-work',
            'revisionId': 'old',
            'candidateDigest': 'a' * 64,
          },
        });
      locals = [item];
      final entry = (await catalog.listPersonal()).entries.single;
      final result = await catalog.resolveSelection(entry);
      expect(result.reason, 'verified_bundle_reader_unavailable');
      expect(
        result.status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect(result.descriptor, isNull);
      bundleReader = (_) async => null;
      catalog.retire();
      catalog = create();
      await expectLater(
        catalog.resolveSelection(entry),
        _code('verified_bundle_unavailable'),
      );
    },
  );

  test(
    'source identity and digest failures cannot create a valid selection',
    () async {
      final entry = await publicEntry();
      gateway.document = _source(id: 'another-work');
      await expectLater(
        catalog.resolveSelection(entry),
        _code('source_identity_mismatch'),
      );
      final valid = _source();
      gateway.document = AppletSourceDocument(
        id: valid.id,
        clientSurfaceId: valid.clientSurfaceId,
        revisionNo: valid.revisionNo,
        sourceSha256: 'b' * 64,
        experienceType: valid.experienceType,
        category: valid.category,
        skillInstructions: valid.skillInstructions,
        surface: valid.surface,
      );
      await expectLater(
        catalog.resolveSelection(entry),
        _code('source_invalid'),
      );
    },
  );

  test(
    'retiring the catalog does not retire the shared sidecar store',
    () async {
      final result = await catalog.resolveSelection(await publicEntry());
      catalog.retire();
      await expectLater(
        catalog.revalidateSelection(result.selection!),
        _code('scope_retired'),
      );
      expect(
        await sidecars.readForDescriptor(
          descriptor: result.descriptor!,
          sourceOrigin: 'publicCatalog',
          adapterId: 'surface-bridge',
          adapterVersion: '1',
        ),
        isNotNull,
      );
    },
  );

  test(
    'pinned source getters isolate mutable projections and omit editor history',
    () async {
      final item = _local();
      item.spec['versionHistory'] = SurfaceVersionHistory.create(
        item.spec,
        title: item.title,
      ).toJson();
      locals = [item];
      final original = jsonEncode(item.toJson());
      final entry = (await catalog.listPersonal()).entries.single;
      final result = await catalog.resolveSelection(entry);
      final pinned = result.executableSource!;
      expect(pinned.isCurrent, isTrue);
      final firstView = pinned.surface!;
      expect(firstView.versionHistory, isNull);
      expect(firstView.revisions, isEmpty);
      firstView.backend['changed'] = true;
      expect(pinned.surface!.backend, isEmpty);
      expect(jsonEncode(item.toJson()), original);
      final refreshed = await catalog.revalidateSelection(result.selection!);
      expect(pinned.isCurrent, isTrue);
      expect(refreshed.executableSource!.isCurrent, isTrue);
      final other = await catalog.resolveSelection(await publicEntry());
      expect(other.executableSource!.isCurrent, isTrue);
      expect(pinned.isCurrent, isTrue);
      item.spec['js'] = 'void 0;';
      await expectLater(
        catalog.revalidateSelection(result.selection!),
        _code('selection_stale'),
      );
      expect(pinned.isCurrent, isFalse);
      expect(() => pinned.surface, _code('source_retired'));
    },
  );

  test(
    'known host withdrawal invalidates pinned source before cache IO finishes',
    () async {
      final result = await catalog.resolveSelection(await publicEntry());
      final pinned = result.executableSource!;
      final invalidating = catalog.invalidateSource(
        origin: AppInvocationSourceOrigin.publicCatalog,
        sourceId: result.entry.locator.id,
        reason: 'source_withdrawn',
      );
      expect(pinned.isCurrent, isFalse);
      await invalidating;
      expect(() => pinned.surface, _code('source_retired'));
    },
  );

  group('direct opening independently of invocation compatibility', () {
    test(
      'webApp game actions are selectable but workerCanvas stays playable only',
      () async {
        final work = _local();
        work.spec['experienceType'] = 'game';
        locals = [work];
        final entry = (await catalog.listPersonal(
          type: AppletCatalogType.game,
        )).entries.single;
        expect(
          (await catalog.resolveSelection(entry)).status,
          AppInvocationCompatibilityStatus.pendingVerification,
        );
        work.spec['rendering'] = 'workerCanvas';
        work.spec['html'] = '';
        work.spec['js'] =
            'Game.define({init(){return {};},update(s){return s;},draw(){return [{type:"clear",color:"#10131a"}];},input(s){return s;}});';
        final resolution = await catalog.resolveSelection(entry);
        expect(resolution.status, AppInvocationCompatibilityStatus.openOnly);
        expect(resolution.reason, 'runtime_requires_manual_open');
        expect((await catalog.resolveOpen(entry)).localWidget?.id, work.id);
      },
    );

    test(
      'local work without actions opens an immutable fresh source',
      () async {
        final work = _local();
        work.spec['manifest'] = {'schemaVersion': 2, 'actions': <Object?>[]};
        locals = [work];
        final entry = (await catalog.listPersonal()).entries.single;
        final target = await catalog.resolveOpen(entry);
        expect(target.localWidget?.id, work.id);
        target.localWidget!.spec['html'] = '<main>changed copy</main>';
        expect(target.localWidget!.spec['html'], work.spec['html']);
        expect(target.surface, isNull);
        expect(target.isCurrent, isTrue);
        await catalog.invalidateSource(
          origin: entry.locator.origin,
          sourceId: entry.locator.id,
          reason: 'deleted',
        );
        expect(target.isCurrent, isFalse);
        expect(() => target.localWidget, _code('source_retired'));
      },
    );

    test(
      'invalid invocation metadata does not disable a valid playable work',
      () async {
        final work = _local();
        (work.spec['manifest'] as Map)['schemaVersion'] = 1;
        (work.spec['manifest'] as Map)['actions'] = [
          {'name': 'custom.run', 'schema': <String, Object?>{}},
          {'name': 'custom.run', 'schema': <String, Object?>{}},
        ];
        locals = [work];
        final entry = (await catalog.listPersonal()).entries.single;
        expect(
          (await catalog.resolveSelection(entry)).status,
          AppInvocationCompatibilityStatus.invalidContract,
        );
        expect((await catalog.resolveOpen(entry)).localWidget?.id, work.id);
      },
    );

    test(
      'owned cloud source uses authenticated source read without saving',
      () async {
        owned = [_owned()];
        final entry = (await catalog.listPersonal()).entries.single;
        final target = await catalog.resolveOpen(entry);
        expect(gateway.sourceCalls.single.owned, isTrue);
        expect(target.surface!.id, 'remote-work');
        expect(target.localWidget, isNull);
        expect(locals, isEmpty);
        owned = [];
        await catalog.listPersonal();
        expect(target.isCurrent, isFalse);
      },
    );

    test('public source integrity is rechecked before opening', () async {
      final entry = await publicEntry();
      final document = gateway.document;
      gateway.document = AppletSourceDocument(
        id: document.id,
        clientSurfaceId: document.clientSurfaceId,
        revisionNo: document.revisionNo,
        sourceSha256: '0' * 64,
        experienceType: document.experienceType,
        category: document.category,
        skillInstructions: document.skillInstructions,
        surface: document.surface,
      );
      await expectLater(catalog.resolveOpen(entry), throwsFormatException);
    });

    test('retiring an account during source read prevents opening', () async {
      final entry = await publicEntry();
      final pending = Completer<AppletSourceDocument>();
      gateway.onSource = (_, _) => pending.future;
      final opening = catalog.resolveOpen(entry);
      catalog.retire();
      pending.complete(gateway.document);
      await expectLater(opening, _code('scope_retired'));
    });

    test('removed local work is not opened from the picker snapshot', () async {
      locals = [_local()];
      final entry = (await catalog.listPersonal()).entries.single;
      locals = [];
      await expectLater(
        catalog.resolveOpen(entry),
        _code('local_source_unavailable'),
      );
    });

    test(
      'official opening rechecks current availability and revocation',
      () async {
        official = [(id: 'official-tool', title: 'Official tool')];
        final entry = (await catalog.listPersonal()).entries.single;
        final target = await catalog.resolveOpen(entry);
        expect(target.officialAppletId, 'official-tool');
        official = [];
        expect(target.isCurrent, isFalse);
        await expectLater(
          catalog.resolveOpen(entry),
          _code('official_source_unavailable'),
        );
      },
    );
  });
}
