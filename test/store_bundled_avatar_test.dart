import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_catalog.dart';

import 'asset_store_service_test.dart' show assetJson;

class _Store extends AssetStoreService {
  _Store() : super(scope: () => 'account-a');
  Object? failure;
  var detailCalls = 0;
  var listCalls = 0;
  bool reportMattSelected = true;
  int currentSelections = 1;
  StoreAsset get matt => StoreAsset.fromJson({
    ...assetJson(id: '44', version: 'a' * 64, type: 'model'),
    'title': 'Matt',
    'ownership': {'selected': reportMattSelected},
    'popularity': {'metric': 'current_selections', 'value': currentSelections},
    'sourceRef': {'modelId': 44, 'expectedAssetVersionDigest': 'a' * 64},
  });

  @override
  Future<StoreAssetPage> list({
    required String type,
    String query = '',
    String sort = 'popular',
    String locale = 'en',
    String platform = '',
    String? cursor,
    bool workshop = false,
  }) async {
    listCalls++;
    if (failure != null) throw failure!;
    return StoreAssetPage([
      if ('matt'.contains(query.toLowerCase())) matt,
    ], null);
  }

  @override
  Future<StoreAsset> detail(
    StoreAsset item, {
    String locale = 'en',
    String platform = '',
  }) async {
    detailCalls++;
    return item;
  }
}

class _AvatarConfig extends AvatarConfigService {
  _AvatarConfig()
    : super(initialCatalog: [...AvatarConfigService.builtInCatalog, _matt]) {
    selectedId.value = _matt.id;
  }
  static const _matt = AvatarOption(
    id: 'reviewed-model-44',
    name: 'Matt',
    backend: AvatarBackendKind.unity,
    remoteModelId: 44,
    modelUrl: BundledAvatarContract.mattAssetUrl,
  );
  final selections = <String>[];
  bool fail = false;
  @override
  Future<void> select(String id, {String? expectedAssetVersionDigest}) async {
    selections.add(id);
    if (fail) throw StateError('selection_rejected');
    selectedId.value = id;
  }
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
  });
  tearDown(appServices.reset);

  Future<StoreAssetCatalogState> pump(
    WidgetTester tester,
    _Store store,
    _AvatarConfig avatars, {
    bool Function()? canContinue,
    double scale = 1,
    Size viewport = const Size(360, 800),
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: viewport,
            textScaler: TextScaler.linear(scale),
          ),
          child: StoreAssetCatalog(
            type: 'model',
            header: const SizedBox(height: 50),
            legacyBuilder: (_) => const Text('legacy'),
            canContinue: canContinue ?? () => true,
            service: store,
            avatars: avatars,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<StoreAssetCatalogState>(find.byType(StoreAssetCatalog));
  }

  Future<void> openJoy(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('asset-card-builtin:agent')));
    await tester.pumpAndSettle();
  }

  testWidgets('unified model store includes real packaged Joy beside Matt', (
    tester,
  ) async {
    final store = _Store();
    final state = await pump(tester, store, _AvatarConfig());
    expect(find.text('Joy'), findsOneWidget);
    expect(find.text('Matt'), findsOneWidget);
    expect(
      find.image(const AssetImage('assets/model_store/agent.png')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Image>(
            find.image(const AssetImage('assets/model_store/agent.png')),
          )
          .fit,
      BoxFit.contain,
    );
    final local = state.visibleAssets.singleWhere(
      (item) => item['id'] == 'builtin:agent',
    );
    expect(local['versionId'], 'bundled:$avatarBuiltinCatalogVersion:agent');
    expect(local['source'], 'builtin');
    expect(local.containsKey('count'), isFalse);
    expect(local.containsKey('metric'), isFalse);
    expect(state.visibleAssets.map((item) => item['id']), [
      'builtin:agent',
      '44',
    ]);
  });

  for (final language in ['en', 'zh']) {
    testWidgets('selected badge clears the model cover on narrow $language', (
      tester,
    ) async {
      AppLocalization.updateLocale(Locale(language));
      final avatars = _AvatarConfig()..selectedId.value = 'agent';
      await pump(
        tester,
        _Store(),
        avatars,
        viewport: const Size(320, 800),
        scale: 2,
      );
      final card = find.byKey(const ValueKey('asset-card-builtin:agent'));
      final cover = find.descendant(of: card, matching: find.byType(Image));
      final badge = find.descendant(
        of: card,
        matching: find.byKey(const ValueKey('model-selected-status')),
      );
      expect(badge, findsOneWidget);
      expect(
        find
            .descendant(
              of: badge,
              matching: find.text('asset_store.selected'.tr),
            )
            .hitTestable(),
        findsOneWidget,
      );
      final imageRect = tester.getRect(cover);
      final badgeRect = tester.getRect(badge);
      expect(imageRect.height, 232);
      expect(badgeRect.overlaps(imageRect), isFalse);
      expect(badgeRect.top, greaterThan(imageRect.bottom));
      expect(avatars.selectedId.value, 'agent');
      expect(avatars.selections, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Joy remains visible on outage and searches by female aliases', (
    tester,
  ) async {
    final store = _Store()
      ..failure = const AssetStoreException('offline', statusCode: 503);
    final state = await pump(tester, store, _AvatarConfig());
    expect(find.text('legacy'), findsNothing);
    expect(find.text('Joy'), findsOneWidget);
    for (final query in ['Joy', 'female', '女性']) {
      await state.search(query, 'recent', () => true);
      await tester.pumpAndSettle();
      expect(state.visibleAssets.single['id'], 'builtin:agent');
      expect(
        find.byKey(const ValueKey('asset-card-builtin:agent')),
        findsOneWidget,
      );
    }
    await state.search('Matt', 'recent', () => true);
    await tester.pumpAndSettle();
    expect(find.text('Joy'), findsNothing);
    expect(state.visibleAssets, isEmpty);
    store.failure = null;
    await state.search('Matt', 'recent', () => true);
    await tester.pumpAndSettle();
    expect(state.visibleAssets.map((item) => item['id']), ['44']);
    expect(
      find.byKey(const ValueKey('asset-card-builtin:agent')),
      findsNothing,
    );
  });

  testWidgets(
    'Agent may open Joy details but cannot select without human confirmation',
    (tester) async {
      final store = _Store();
      final avatars = _AvatarConfig();
      final state = await pump(tester, store, avatars);
      final version = state.visibleAssets.first['versionId'] as String;
      await state.open('builtin:agent', 'stale');
      expect(find.byKey(const ValueKey('asset-execute')), findsNothing);
      await state.open('builtin:agent', version, authority: () => false);
      expect(find.byKey(const ValueKey('asset-execute')), findsNothing);
      final opening = state.open(
        'builtin:agent',
        version,
        authority: () => true,
      );
      await tester.pumpAndSettle();
      expect(store.detailCalls, 0);
      expect(avatars.selections, isEmpty);
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      expect(avatars.selections, isEmpty);
      await tester.tap(find.text('common.cancel'.tr));
      await tester.pumpAndSettle();
      expect(avatars.selections, isEmpty);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await opening;
    },
  );

  testWidgets(
    'confirmed Joy selection delegates to existing AvatarConfig and updates card',
    (tester) async {
      final store = _Store();
      final avatars = _AvatarConfig();
      await pump(tester, store, avatars);
      await openJoy(tester);
      final cover = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.image(const AssetImage('assets/model_store/agent.png')),
      );
      expect(cover, findsOneWidget);
      expect(tester.widget<Image>(cover).fit, BoxFit.contain);
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('common.confirm'.tr));
      await tester.pumpAndSettle();
      expect(avatars.selections, ['agent']);
      expect(avatars.selectedId.value, 'agent');
      expect(store.detailCalls, 0);
      store.reportMattSelected = false;
      store.currentSelections = 0;
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('asset-card-builtin:agent')),
          matching: find.text('asset_store.selected'.tr),
        ),
        findsOneWidget,
      );
      expect(find.text('asset_store.selected'.tr), findsOneWidget);
      expect(store.listCalls, 2);
      final matt = tester
          .state<StoreAssetCatalogState>(find.byType(StoreAssetCatalog))
          .visibleAssets
          .singleWhere((item) => item['id'] == '44');
      expect(matt['selected'], isFalse);
      expect(matt['count'], 0);
    },
  );

  testWidgets(
    'stale server selected ownership cannot block switching from Joy back to Matt',
    (tester) async {
      final store = _Store();
      final avatars = _AvatarConfig();
      final state = await pump(tester, store, avatars);
      await openJoy(tester);
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('common.confirm'.tr));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(store.listCalls, 2);
      expect(find.text('asset_store.selected'.tr), findsOneWidget);
      expect(
        state.visibleAssets
            .where((item) => item['selected'] == true)
            .map((item) => item['id']),
        ['builtin:agent'],
      );
      await tester.tap(find.text('Matt'));
      await tester.pumpAndSettle();
      final button = tester.widget<AppGlassButton>(
        find.byKey(const ValueKey('asset-execute')),
      );
      expect(button.onPressed, isNotNull);
      expect(button.label, 'asset_store.select'.tr);
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      expect(find.text('asset_store.confirm_select'.tr), findsOneWidget);
      await tester.tap(find.text('common.cancel'.tr));
      await tester.pumpAndSettle();
      expect(avatars.selectedId.value, 'agent');
    },
  );

  testWidgets(
    'failed statistics refresh retains Matt card with current selection state',
    (tester) async {
      final store = _Store();
      final avatars = _AvatarConfig();
      final state = await pump(tester, store, avatars);
      await openJoy(tester);
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('common.confirm'.tr));
      await tester.pumpAndSettle();
      store.failure = const AssetStoreException('offline', statusCode: 503);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Matt'), findsOneWidget);
      expect(find.text('asset_store.selected'.tr), findsOneWidget);
      expect(
        state.visibleAssets.singleWhere(
          (item) => item['id'] == '44',
        )['selected'],
        isFalse,
      );
      expect(find.text('asset_store.unavailable'.tr), findsOneWidget);
    },
  );

  testWidgets('failed selection keeps Matt selected with visible error', (
    tester,
  ) async {
    final avatars = _AvatarConfig()..fail = true;
    await pump(tester, _Store(), avatars);
    await openJoy(tester);
    await tester.tap(find.byKey(const ValueKey('asset-execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('common.confirm'.tr));
    await tester.pumpAndSettle();
    expect(avatars.selectedId.value, 'reviewed-model-44');
    expect(find.text('asset_store.unavailable'.tr), findsOneWidget);
  });

  testWidgets('account takeover during confirmation prevents Joy selection', (
    tester,
  ) async {
    var current = true;
    final avatars = _AvatarConfig();
    final state = await pump(
      tester,
      _Store(),
      avatars,
      canContinue: () => current,
    );
    await openJoy(tester);
    await tester.tap(find.byKey(const ValueKey('asset-execute')));
    await tester.pumpAndSettle();
    current = false;
    await tester.tap(find.text('common.confirm'.tr));
    await tester.pumpAndSettle();
    expect(avatars.selections, isEmpty);
    expect(state.visibleAssets, isEmpty);
  });

  testWidgets('Joy detail remains scrollable at large text', (tester) async {
    await pump(tester, _Store(), _AvatarConfig(), scale: 2);
    await openJoy(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('asset-execute')));
    expect(tester.takeException(), isNull);
  });
}
