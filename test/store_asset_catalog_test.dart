import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_catalog.dart';
import 'package:maaso/src/features/store/presentation/store_asset_detail.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'asset_store_service_test.dart' show assetJson;

class _Store extends AssetStoreService {
  _Store() : super(scope: () => 'test');
  Object? failure;
  List<StoreAsset>? items;
  final calls = <String>[];
  int detailCalls = 0;
  Completer<StoreAssetPage>? pending;
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
    calls.add('$type|$query|$sort');
    if (failure != null) throw failure!;
    return pending?.future ??
        StoreAssetPage(items ?? [StoreAsset.fromJson(assetJson())], null);
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

class _SkillInstallProbe extends AppService implements SkillMarketplaceService {
  int installCalls = 0;
  int skillReadCalls = 0;

  @override
  Future<MarketplaceSkill> getSkill(String skillId) async {
    skillReadCalls++;
    throw StateError('A detail view must not load installable Skill content.');
  }

  @override
  Future<MarketplaceInstallResult> install({
    required String skillId,
    required String agentId,
    required Set<String> acceptedPermissions,
  }) async {
    installCalls++;
    throw StateError('Installation must require an explicit user action.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _SkillInstallProbe installs;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
    installs = _SkillInstallProbe();
    appServices.put<SkillMarketplaceService>(installs);
  });
  tearDown(() async {
    await appServices.reset();
  });
  Future<void> pump(
    WidgetTester tester,
    _Store store, {
    double scale = 1,
    String type = 'skill',
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: Size(width, 800),
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: StoreAssetCatalog(
          type: type,
          header: const SizedBox(height: 50),
          legacyBuilder: (_) => const Text('legacy'),
          canContinue: () => true,
          service: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search stays in selected type, card opens exact visible detail without executing',
    (tester) async {
      final store = _Store();
      await pump(tester, store);
      expect(store.calls, ['skill||popular']);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(store.calls.last, 'skill|hello|popular');
      await tester.tap(find.text('Wave'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('A friendly wave'),
        ),
        findsOneWidget,
      );
      expect(store.detailCalls, 1);
      expect(find.byKey(const ValueKey('asset-execute')), findsOneWidget);
      expect(installs.skillReadCalls, 0);
      expect(installs.installCalls, 0);
      expect(find.text('asset_store.preview_unavailable'.tr), findsOneWidget);
    },
  );
  testWidgets('only absent new route mounts legacy; outage stays explicit', (
    tester,
  ) async {
    final unsupported = _Store()
      ..failure = const AssetStoreException('missing', statusCode: 404);
    await pump(tester, unsupported);
    expect(find.text('legacy'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final outage = _Store()
      ..failure = const AssetStoreException('unavailable', statusCode: 503);
    await pump(tester, outage);
    expect(find.text('legacy'), findsNothing);
    expect(find.text('asset_store.unavailable'.tr), findsOneWidget);
  });
  testWidgets(
    'large text uses scrollable single column and retains detail return position',
    (tester) async {
      tester.view.resetPhysicalSize();
      final store = _Store();
      await pump(tester, store, scale: 2);
      await tester.ensureVisible(find.text('Wave'));
      await tester.tap(find.text('Wave'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Wave'), findsOneWidget);
      expect(store.calls.length, 1);
    },
  );
  testWidgets(
    'human cancels model confirmation without invoking native selection',
    (tester) async {
      final store = _Store()
        ..items = [
          StoreAsset.fromJson({
            ...assetJson(id: '7', version: 'a' * 64, type: 'model'),
            'sourceRef': {'modelId': 7, 'expectedAssetVersionDigest': 'a' * 64},
          }),
        ];
      await pump(tester, store, type: 'model');
      await tester.tap(find.text('Wave'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('asset-execute')));
      await tester.tap(find.byKey(const ValueKey('asset-execute')));
      await tester.pumpAndSettle();
      expect(find.text('asset_store.confirm_select'.tr), findsOneWidget);
      await tester.tap(find.text('common.cancel'.tr));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('asset_store.unavailable'.tr), findsNothing);
    },
  );
  testWidgets('cancelled agent search cannot apply a late catalog response', (
    tester,
  ) async {
    final store = _Store();
    await pump(tester, store);
    final state = tester.state<StoreAssetCatalogState>(
      find.byType(StoreAssetCatalog),
    );
    store.pending = Completer<StoreAssetPage>();
    var authorized = true;
    final pending = state.search('new', 'recent', () => authorized);
    await tester.pump();
    authorized = false;
    store.pending!.complete(
      StoreAssetPage([
        StoreAsset.fromJson({...assetJson(), 'title': 'Late result'}),
      ], null),
    );
    await pending;
    await tester.pumpAndSettle();
    expect(find.text('Late result'), findsNothing);
  });

  testWidgets(
    '375px model gallery has two columns and a large preview region',
    (tester) async {
      final first = _modelAsset('7', 'First model');
      final second = _modelAsset('8', 'Second model');
      final store = _Store()..items = [first, second];
      await pump(tester, store, type: 'model', width: 375);
      final firstCard = find.byKey(ValueKey('asset-card-${first.key}'));
      final secondCard = find.byKey(ValueKey('asset-card-${second.key}'));
      final a = tester.getRect(firstCard);
      final b = tester.getRect(secondCard);
      expect(a.top, closeTo(b.top, 0.1));
      expect(a.right, lessThan(b.left));
      expect(a.width, greaterThan(140));
      final preview = find.descendant(
        of: firstCard,
        matching: find.byWidgetPredicate(
          (widget) => widget is SizedBox && (widget.height ?? 0) >= 200,
        ),
      );
      expect(preview, findsOneWidget);
      expect(tester.getSize(preview).height, greaterThanOrEqualTo(200));
      expect(store.detailCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bundled in [false, true]) {
    testWidgets(
      'model cover is uncropped with historical descriptor=$bundled',
      (tester) async {
        final model = StoreAsset.fromJson({
          ...assetJson(id: '7', version: 'a' * 64, type: 'model'),
          'coverUrl': 'https://cdn.example.com/full-body.png',
          if (bundled)
            'sourceRef': {
              'modelId': 7,
              'expectedAssetVersionDigest': 'a' * 64,
              'model': {
                'id': 7,
                'modelKey': BundledAvatarContract.mattModelKey,
                'modelSource': 'official',
                'displayName': 'Matt',
                'assetUrl': BundledAvatarContract.mattAssetUrl,
                'assetSha256': BundledAvatarContract.mattAssetSha256,
                'runtimeConfig': BundledAvatarContract.mattRuntimeConfig,
                'compatibility': {
                  'backends': ['unity'],
                },
              },
            },
        });
        final store = _Store()..items = [model];
        await pump(tester, store, type: 'model');
        final card = find.byKey(ValueKey('asset-card-${model.key}'));
        final cover = find.descendant(of: card, matching: find.byType(Image));
        expect(cover, findsOneWidget);
        expect(tester.widget<Image>(cover).fit, BoxFit.contain);
        expect(tester.widget<Image>(cover).image, isA<NetworkImage>());
        await tester.tap(card);
        await tester.pumpAndSettle();
        final detailCover = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Image),
        );
        expect(detailCover, findsOneWidget);
        expect(tester.widget<Image>(detailCover).fit, BoxFit.contain);
        expect(store.detailCalls, 1);
        expect(installs.installCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'store and detail prefer canonical model cover over old metadata artwork',
    (tester) async {
      final item = StoreAsset.fromJson({
        ...assetJson(id: '25', version: 'a' * 64, type: 'model'),
        'coverUrl': 'https://cdn.example.com/old-face.png',
        'sourceRef': {
          'modelId': 25,
          'expectedAssetVersionDigest': 'a' * 64,
          'model': {
            'id': 25,
            'modelKey': 'community.full-body',
            'modelSource': 'community',
            'displayName': 'Full body',
            'assetUrl': 'https://cdn.example.com/model.vrm',
            'assetSha256': 'a' * 64,
            'runtimeConfig': {'assetFormat': 'vrm'},
            'compatibility': {
              'backends': ['unity'],
            },
            'previewImageUrl': 'https://cdn.example.com/full-body.png',
          },
        },
      });
      final store = _Store()..items = [item];
      await pump(tester, store, type: 'model');
      final card = find.byKey(ValueKey('asset-card-${item.key}'));
      final image = tester.widget<Image>(
        find.descendant(of: card, matching: find.byType(Image)),
      );
      expect(
        (image.image as NetworkImage).url,
        'https://cdn.example.com/full-body.png',
      );
      expect(image.fit, BoxFit.contain);
      await tester.tap(card);
      await tester.pumpAndSettle();
      final detail = tester.widget<Image>(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Image),
        ),
      );
      expect(
        (detail.image as NetworkImage).url,
        'https://cdn.example.com/full-body.png',
      );
      expect(detail.fit, BoxFit.contain);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'canonical cover helper preserves legacy fallback and Skill artwork',
    () {
      final legacy = StoreAsset.fromJson({
        ...assetJson(type: 'model', id: '25', version: 'a' * 64),
        'coverUrl': 'https://cdn.example.com/legacy.png',
      });
      expect(storeAssetCoverUrl(legacy), 'https://cdn.example.com/legacy.png');
      final skill = StoreAsset.fromJson({
        ...assetJson(type: 'skill'),
        'coverUrl': 'https://cdn.example.com/skill.png',
        'sourceRef': {
          'skillVersionId': 1,
          'model': {'previewImageUrl': 'https://cdn.example.com/ignore.png'},
        },
      });
      expect(storeAssetCoverUrl(skill), 'https://cdn.example.com/skill.png');
      for (final url in [
        'http://cdn.example.com/face.png',
        'https://user:secret@cdn.example.com/face.png',
      ]) {
        final unsafe = StoreAsset.fromJson({
          ...assetJson(type: 'model', id: '25', version: 'a' * 64),
          'coverUrl': url,
        });
        expect(storeAssetCoverUrl(unsafe), isNull);
      }
    },
  );

  testWidgets('320px and large text use a full-width model column', (
    tester,
  ) async {
    final first = _modelAsset('7', 'First model');
    final second = _modelAsset('8', 'Second model');
    final store = _Store()..items = [first, second];
    await pump(tester, store, type: 'model', width: 320, scale: 2);
    final firstCard = find.byKey(ValueKey('asset-card-${first.key}'));
    expect(tester.getSize(firstCard).width, closeTo(288, 0.1));
    final secondCard = find.byKey(ValueKey('asset-card-${second.key}'));
    final catalogScroll = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    expect(catalogScroll, findsOneWidget);
    await tester.scrollUntilVisible(secondCard, 200, scrollable: catalogScroll);
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondCard);
    await tester.pumpAndSettle();
    expect(secondCard.hitTestable(), findsOneWidget);
    expect(tester.getSize(secondCard).width, closeTo(288, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Skill catalog keeps one column even on a wider screen', (
    tester,
  ) async {
    final first = StoreAsset.fromJson(assetJson(id: 'first', version: '1'));
    final second = StoreAsset.fromJson(assetJson(id: 'second', version: '2'));
    final store = _Store()..items = [first, second];
    await pump(tester, store, width: 768);
    final a = tester.getRect(find.byKey(ValueKey('asset-card-${first.key}')));
    final b = tester.getRect(find.byKey(ValueKey('asset-card-${second.key}')));
    expect(a.left, closeTo(b.left, 0.1));
    expect(a.width, closeTo(600, 0.1));
    expect(b.top, closeTo(a.bottom, 0.1));
    expect(tester.takeException(), isNull);
  });

  for (final type in ['model', 'skill']) {
    testWidgets('search with keyboard fits a narrow large-text $type catalog', (
      tester,
    ) async {
      final store = _Store()
        ..items = [
          type == 'model'
              ? _modelAsset('7', 'First model')
              : StoreAsset.fromJson(assetJson()),
        ];
      await pump(tester, store, type: type, width: 320, scale: 2);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'name');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(store.calls.last, '$type|name|popular');
      expect(tester.takeException(), isNull);
    });
  }
}

StoreAsset _modelAsset(String id, String title) => StoreAsset.fromJson({
  ...assetJson(id: id, version: 'a' * 64, type: 'model'),
  'title': title,
});
