import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_host.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:sembast/sembast_memory.dart';

const _scope = AppletLocalOwnership.deviceLegacyScope;
const _quota = AppletQuotaSnapshot(used: 0, limit: 5);

void main() {
  late DBService database;
  late AppInvocationCatalog catalog;
  late AppInvocationSidecarStore sidecars;
  late _Gateway gateway;
  late _FirstFrameWaiter waiter;
  var serial = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'composer-player-${serial++}.db',
    );
    appServices.put(database);
    appServices.put(
      GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        commentary: (_, {required isCurrent, required onRevoked}) async =>
            false,
      ),
    );
    appServices.put<AppCapabilitySnapshotService>(
      AppCapabilitySnapshotService(
        resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
        initialContext: AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
      ),
    );
    final sidecarDb = await databaseFactoryMemory.openDatabase(
      'composer-player-sidecars-${serial++}',
    );
    addTearDown(sidecarDb.close);
    sidecars = AppInvocationSidecarStore(
      database: sidecarDb,
      scopeKey: _scope,
      mountId: 'player',
      currentMountId: () => 'player',
      isCurrent: () => true,
    );
    gateway = _Gateway();
    catalog = AppInvocationCatalog(
      catalog: gateway,
      discovery: gateway,
      loadLocalWidgets: database.getAllWidgets,
      loadOwnedInventory: () async =>
          const AppletInventoryPage(items: [], quota: _quota),
      readAvailableOfficialApplets: () => const [],
      sidecars: sidecars,
      adapterIdentityFor: (_) => (id: 'surface-bridge', version: '1'),
      scopeKey: _scope,
      mountId: 'player',
      currentScopeKey: () => _scope,
      currentMountId: () => 'player',
      isCurrent: () => true,
    );
    waiter = _FirstFrameWaiter();
    gameFeedFirstFrameWaiterOverride = waiter;
  });

  tearDown(() async {
    gameFeedFirstFrameWaiterOverride = null;
    catalog.retire();
    sidecars.retire();
    await appServices.reset();
    await database.close();
  });

  Future<AppInvocationOpenTarget> open(
    WidgetTester tester, {
    required bool game,
  }) async {
    gateway.game = game;
    final entry = (await catalog.searchPublic(
      type: game ? AppletCatalogType.game : AppletCatalogType.applet,
    )).entries.single;
    final target = await catalog.resolveOpen(entry);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const Scaffold(body: Text('Composer draft')),
      ),
    );
    expect(
      await openAppInvocationTarget(target, canContinue: () => true),
      isTrue,
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(waiter.attempts, hasLength(1));
    return target;
  }

  testWidgets('composer public game retains immersive companion player', (
    tester,
  ) async {
    await open(tester, game: true);
    expect(find.byKey(const ValueKey('game-player-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('game-cover-loading')), findsOneWidget);
    expect(find.byType(SurfaceWebView), findsNothing);
    waiter.attempts.single.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(find.byType(GameVoiceHost), findsOneWidget);
    expect(find.byKey(const ValueKey('game-player-controls')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('game-companion-controls')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('owned-game-detail-rail')), findsNothing);
    expect(await database.getAllWidgets(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('game-player-back')));
    await tester.pumpAndSettle();
    expect(find.text('Composer draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('composer applet retries failed first-frame preparation', (
    tester,
  ) async {
    await open(tester, game: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(SurfaceWebView), findsNothing);
    waiter.attempts.single.completeError(StateError('first frame failed'));
    await tester.pumpAndSettle();
    final retry = find.widgetWithIcon(IconButton, Icons.refresh_rounded);
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();
    expect(waiter.attempts, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    waiter.attempts.last.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(find.byType(GameVoiceHost), findsNothing);
    expect(await database.getAllWidgets(), isEmpty);
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('retiring composer source during preparation closes player', (
    tester,
  ) async {
    final target = await open(tester, game: true);
    catalog.retire();
    waiter.attempts.single.complete();
    await tester.pumpAndSettle();
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(find.text('Composer draft'), findsOneWidget);
    expect(rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(
      await openAppInvocationTarget(target, canContinue: () => true),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));
}

final class _FirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  final attempts = <Completer<void>>[];

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {}

  @override
  void cancelPresentation() {}

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    final attempt = Completer<void>();
    attempts.add(attempt);
    return attempt.future;
  }
}

final class _Gateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  bool game = true;

  @override
  String get requestContextKey => 'composer-player-fixture';

  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async => AppletCatalogPage(
    quota: _quota,
    items: [
      AppletCatalogItem(
        id: 'public-work',
        title: 'Playable source',
        type: type,
        summary: 'A source without callable actions',
        author: const AppletCatalogAuthor(
          agentId: 'author',
          displayName: 'Author',
          verified: false,
        ),
        shareUrl: Uri.parse('https://example.test/g/public-work'),
        updatedAt: DateTime.utc(2026, 10, 23),
      ),
    ],
  );

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async {
    final surface = <String, Object?>{
      'title': 'Playable source',
      'rendering': 'webApp',
      'html': '<main>Playable source</main>',
      'css': '',
      'js': '',
      'manifest': {'actions': <Object?>[]},
    };
    return AppletSourceDocument.fromJson({
      'id': id,
      'clientSurfaceId': 'public-source',
      'revisionNo': 1,
      'sourceSha256': surfaceSourceSha256(surface),
      'experienceType': game ? 'game' : 'utility',
      'category': game ? 'game' : 'tools',
      'skillInstructions': '',
      'surface': surface,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
