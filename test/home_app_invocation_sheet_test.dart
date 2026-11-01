import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/applets/domain/official_applet.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_app_invocation_sheet.dart';
import 'package:sembast/sembast_memory.dart';

const _scope = AppletLocalOwnership.deviceLegacyScope;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Home home;
  late DBService database;
  var serial = 0;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-ui-fixture-${serial++}.db',
    );
    appServices.put(database);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_Core());
    home = _Home();
    appServices.put<HomeController>(home);
  });
  tearDown(() async {
    await appServices.reset();
    await database.close();
  });

  Future<void> catalog(
    List<AgentWidget> works, {
    AppletSourceDocument? remote,
    List<({String id, String title})> official = const [],
  }) async {
    final db = await databaseFactoryMemory.openDatabase('sheet-${serial++}');
    final sidecars = AppInvocationSidecarStore(
      database: db,
      scopeKey: _scope,
      mountId: 'm1',
      currentMountId: () => 'm1',
      isCurrent: () => true,
    );
    final gateway = _Gateway()..document = remote;
    home.catalog = AppInvocationCatalog(
      catalog: gateway,
      discovery: gateway,
      loadLocalWidgets: () async => await home.localRead?.call() ?? works,
      loadOwnedInventory: () async => const AppletInventoryPage(
        items: [],
        quota: AppletQuotaSnapshot(used: 0, limit: 5),
      ),
      readAvailableOfficialApplets: () => official,
      sidecars: sidecars,
      adapterIdentityFor: (_) => (id: 'surface-bridge', version: '1'),
      scopeKey: _scope,
      mountId: 'm1',
      currentScopeKey: () => _scope,
      currentMountId: () => 'm1',
      isCurrent: () => true,
    );
    addTearDown(() async {
      home.catalog?.retire();
      sidecars.retire();
      await db.close();
    });
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => HomeAppInvocationSheet(
                    controller: home,
                    type: AppletCatalogType.applet,
                  ),
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  testWidgets('missing account catalog is explicit and retryable', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.text('The catalog is unavailable for this account'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(home.selectedAppInvocation.value, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search selects a real declared source reference without changing source',
    (tester) async {
      final work = _work(1, 'Echo tool', declared: true);
      final before = jsonEncode(work.spec);
      await catalog([work, _work(2, 'Other tool', declared: true)]);
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('home-invocation-search')),
        'Echo',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Other tool'), findsNothing);
      await tester.tap(find.text('Echo tool'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeAppInvocationSheet), findsNothing);
      expect(home.selectedAppInvocation.value?.entry.title, 'Echo tool');
      expect(jsonEncode(work.spec), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('work without a declared callable action stays open-only', (
    tester,
  ) async {
    final work = _work(1, 'Read me', declared: false);
    final before = jsonEncode(work.spec);
    await catalog([work]);
    await open(tester);
    await tester.tap(find.text('Read me'));
    await tester.pumpAndSettle();
    expect(home.selectedAppInvocation.value, isNull);
    expect(
      find.text('Open directly · Agent invocation unavailable'),
      findsOneWidget,
    );
    expect(jsonEncode(work.spec), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct open preserves the typed draft and existing selection', (
    tester,
  ) async {
    final callable = _work(1, 'Selected tool', declared: true);
    final plain = _work(2, 'Plain work', declared: false);
    final before = jsonEncode(plain.spec);
    await catalog([callable, plain]);
    await open(tester);
    await tester.tap(find.text('Selected tool'));
    await tester.pumpAndSettle();
    final selection = home.selectedAppInvocation.value;
    home.inputController.text = 'Keep this draft';
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('home-invocation-open-local:work-2')),
    );
    await tester.pumpAndSettle();
    expect(home.opened.single.localWidget?.id, 2);
    expect(home.inputController.text, 'Keep this draft');
    expect(home.selectedAppInvocation.value, same(selection));
    expect(find.byType(HomeAppInvocationSheet), findsNothing);
    expect(jsonEncode(plain.spec), before);
  });

  testWidgets(
    'open-only row opens after inspection and failed open is retryable',
    (tester) async {
      await catalog([_work(1, 'Plain work', declared: false)]);
      await open(tester);
      await tester.tap(find.text('Plain work'));
      await tester.pumpAndSettle();
      home.openResult = false;
      await tester.tap(find.text('Plain work'));
      await tester.pumpAndSettle();
      expect(
        find.text('The operation did not complete. Please retry.'),
        findsOneWidget,
      );
      expect(find.byType(HomeAppInvocationSheet), findsOneWidget);
      home.openResult = true;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(home.opened, hasLength(2));
      expect(find.byType(HomeAppInvocationSheet), findsNothing);
    },
  );

  testWidgets('closing the picker during source read prevents a late player', (
    tester,
  ) async {
    final work = _work(1, 'Plain work', declared: false);
    await catalog([work]);
    await open(tester);
    final pending = Completer<List<AgentWidget>>();
    home.localRead = () => pending.future;
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    pending.complete([work]);
    await tester.pumpAndSettle();
    expect(home.opened, isEmpty);
    expect(home.selectedAppInvocation.value, isNull);
  });

  testWidgets('changing search while selecting cannot attach the old source', (
    tester,
  ) async {
    final work = _work(1, 'Callable work', declared: true);
    await catalog([work]);
    await open(tester);
    final pending = Completer<List<AgentWidget>>();
    home.localRead = () => pending.future;
    await tester.tap(find.text('Callable work'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('home-invocation-search')),
      'Different',
    );
    home.localRead = null;
    pending.complete([work]);
    await tester.pumpAndSettle();
    expect(home.selectedAppInvocation.value, isNull);
    expect(find.byType(HomeAppInvocationSheet), findsOneWidget);
  });

  testWidgets(
    'real local opening enters the existing player with back and retry',
    (tester) async {
      final work = _work(1, 'Playable work', declared: false);
      await tester.runAsync(() => database.saveAgentWidget(work));
      await catalog([work]);
      home.useRealPlayer = true;
      appServices.put<AppCapabilitySnapshotService>(
        AppCapabilitySnapshotService(
          resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
          initialContext: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.macos,
            rolloutGeneration: 0,
          ),
        ),
      );
      home.inputController.text = 'Unsent draft';
      await open(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeAppInvocationSheet), findsNothing);
      expect(find.byKey(const ValueKey('applet-player-back')), findsOneWidget);
      // No native WebView/first-frame host is mounted by this widget test.
      expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
      expect(home.inputController.text, 'Unsent draft');
      await tester.tap(find.byKey(const ValueKey('applet-player-back')));
      await tester.pumpAndSettle();
      expect(rootNavigatorKey.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a newer open request supersedes an older pending source', (
    tester,
  ) async {
    final works = [
      _work(1, 'First', declared: false),
      _work(2, 'Second', declared: false),
    ];
    await catalog(works);
    await tester.runAsync(() async {
      final entries = (await home.catalog!.listPersonal()).entries;
      final pending = Completer<List<AgentWidget>>();
      var reads = 0;
      home.localRead = () async => reads++ == 0 ? await pending.future : works;
      final first = home.openAppInvocation(
        entries.firstWhere((e) => e.title == 'First'),
        canContinue: () => true,
      );
      final second = await home.openAppInvocation(
        entries.firstWhere((e) => e.title == 'Second'),
        canContinue: () => true,
      );
      expect(second, isTrue);
      pending.complete(works);
      expect(await first, isFalse);
      expect(home.opened.single.localWidget!.title, 'Second');
    });
  });

  testWidgets('replacing the account catalog cancels a pending open', (
    tester,
  ) async {
    final work = _work(1, 'Old account work', declared: false);
    await catalog([work]);
    await tester.runAsync(() async {
      final entry = (await home.catalog!.listPersonal()).entries.single;
      final pending = Completer<List<AgentWidget>>();
      home.localRead = () => pending.future;
      final opening = home.openAppInvocation(entry, canContinue: () => true);
      final original = home.catalog;
      home.catalog = null;
      pending.complete([work]);
      expect(await opening, isFalse);
      expect(home.opened, isEmpty);
      home.catalog = original;
    });
  });

  testWidgets(
    'public cloud opening uses the player without creating a local work',
    (tester) async {
      final spec = _work(1, 'Cloud work', declared: false).spec;
      final surface = <String, Object?>{
        for (final key in [
          'title',
          'rendering',
          'html',
          'css',
          'js',
          'manifest',
        ])
          key: spec[key],
      };
      final source = AppletSourceDocument.fromJson({
        'id': 'cloud-work',
        'clientSurfaceId': 'client-work',
        'revisionNo': 1,
        'sourceSha256': surfaceSourceSha256(surface),
        'experienceType': 'utility',
        'category': '',
        'skillInstructions': '',
        'surface': surface,
      });
      await catalog([], remote: source);
      home.useRealPlayer = true;
      appServices.put<AppCapabilitySnapshotService>(
        AppCapabilitySnapshotService(
          resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
          initialContext: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.macos,
            rolloutGeneration: 0,
          ),
        ),
      );
      await open(tester);
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeAppInvocationSheet), findsNothing);
      expect(find.byKey(const ValueKey('applet-player-back')), findsOneWidget);
      expect(await tester.runAsync(database.getAllWidgets), isEmpty);
      await tester.tap(find.byKey(const ValueKey('applet-player-back')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('official entry opens its registered native destination', (
    tester,
  ) async {
    final applet = OfficialApplet(
      id: 'picker-test-official',
      nameKey: 'Official fixture',
      icon: Icons.apps,
      color: Colors.blue,
      builder: () => const Scaffold(body: Text('Official destination')),
    );
    OfficialAppletRegistry.all.add(applet);
    addTearDown(() => OfficialAppletRegistry.all.remove(applet));
    await catalog([], official: [(id: applet.id, title: 'Official fixture')]);
    home.useRealPlayer = true;
    await open(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Official destination'), findsOneWidget);
    expect(find.byType(HomeAppInvocationSheet), findsNothing);
    expect(home.selectedAppInvocation.value, isNull);
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  });
}

AgentWidget _work(int id, String title, {required bool declared}) {
  final work = AgentWidget(
    id: id,
    agentId: 'self',
    title: title,
    kind: 'surface',
    createdAt: DateTime.utc(2026),
    spec: {
      'surfaceId': 'work-$id',
      'experienceType': 'utility',
      'rendering': 'webApp',
      'title': title,
      'html': '<main>$title</main>',
      'css': '',
      'js': declared ? 'Surface.onAgent = (name, args) => args;' : '',
      'manifest': {
        'schemaVersion': 2,
        'actions': [
          if (declared)
            {
              'name': 'custom.run',
              'schema': {
                'type': 'object',
                'properties': <String, Object?>{},
                'additionalProperties': false,
              },
              'risk': 'localMutation',
              'consequencePolicy': 'reversible',
            },
        ],
        'events': <Object?>[],
      },
    },
  );
  AppletLocalOwnership.stamp(work, scopeKey: _scope);
  return work;
}

class _Gateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  AppletSourceDocument? document;
  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async => AppletCatalogPage(
    items: [
      if (document case final source?)
        AppletCatalogItem(
          id: source.id,
          title: source.surface['title']! as String,
          type: AppletCatalogType.applet,
          summary: '',
          author: const AppletCatalogAuthor(
            agentId: 'author',
            displayName: 'Author',
            verified: false,
          ),
          shareUrl: Uri.parse('https://example.test/g/${source.id}'),
          updatedAt: DateTime.utc(2026),
        ),
    ],
    quota: const AppletQuotaSnapshot(used: 0, limit: 5),
  );

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async => document!;
  @override
  String get requestContextKey => 'sheet|owner|en';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Home extends HomeController {
  AppInvocationCatalog? catalog;
  Future<List<AgentWidget>> Function()? localRead;
  final opened = <AppInvocationOpenTarget>[];
  bool openResult = true;
  bool useRealPlayer = false;
  @override
  Future<bool> presentAppInvocationTarget(
    AppInvocationOpenTarget target, {
    required bool Function() canContinue,
  }) async {
    if (useRealPlayer) {
      return super.presentAppInvocationTarget(target, canContinue: canContinue);
    }
    if (!canContinue() || !target.isCurrent) return false;
    opened.add(target);
    return openResult;
  }

  @override
  AppInvocationCatalog? get invocationCatalog => catalog;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Core extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}
