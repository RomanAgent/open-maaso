import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_catalog.dart';
import 'package:maaso/src/features/store/presentation/store_hub_page.dart';

import 'asset_store_service_test.dart' show assetJson;

const _capture = bool.fromEnvironment('MAASO_CAPTURE_STORE');
const _visualFont = 'StoreWhiteFrostVisual';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
  });

  tearDown(() async {
    AppLocalization.updateLocale(const Locale('en'));
    await appServices.reset();
  });

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets('${locale.languageCode}: real header and one active catalog', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(tester, locale: locale);

        final brand = find.descendant(
          of: find.byKey(const ValueKey('store-frost-header')),
          matching: find.text('Maaso'),
        );
        expect(brand, findsOneWidget);
        expect(tester.getCenter(brand).dx, closeTo(393 / 2, .1));
        final title = find.byKey(const ValueKey('store-frost-title'));
        expect(tester.widget<Text>(title).data, 'store_hub.marketplace'.tr);
        expect(tester.widget<Text>(title).style!.fontSize, 28);
        expect(find.text('store_hub.page_subtitle'.tr), findsOneWidget);
        final workshop = find.byKey(const ValueKey('store-open-workshop'));
        expect(tester.getSize(workshop), const Size(48, 48));
        final workshopSemantics = tester.getSemantics(
          find.descendant(
            of: workshop,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics &&
                  widget.properties.button == true &&
                  widget.properties.label == 'store_hub.workshop'.tr,
            ),
          ),
        );
        expect(workshopSemantics.flagsCollection.isButton, isTrue);
        expect(workshopSemantics.label, contains('store_hub.workshop'.tr));
        expect(
          workshopSemantics.getSemanticsData().hasAction(
            ui.SemanticsAction.tap,
          ),
          isTrue,
        );

        expect(find.byType(StoreAssetCatalog), findsOneWidget);
        final models = tester.state<StoreAssetCatalogState>(
          find.byType(StoreAssetCatalog),
        );
        expect(models.widget.type, 'model');
        expect(fixture.store.calls.map((call) => call.type), ['model']);
        expect(find.text('Joy'), findsOneWidget);
        expect(find.text('Matt'), findsOneWidget);

        await _selectSection(tester, StoreHubSection.marketplace);
        expect(models.mounted, isFalse);
        expect(find.byType(StoreAssetCatalog), findsOneWidget);
        final skills = tester.state<StoreAssetCatalogState>(
          find.byType(StoreAssetCatalog),
        );
        expect(skills.widget.type, 'skill');
        expect(find.text('Joy'), findsNothing);
        expect(fixture.store.calls.map((call) => call.type), [
          'model',
          'skill',
        ]);

        await _selectSection(tester, StoreHubSection.models);
        expect(skills.mounted, isFalse);
        expect(find.byType(StoreAssetCatalog), findsOneWidget);
        expect(fixture.store.calls.map((call) => call.type), [
          'model',
          'skill',
          'model',
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final dark in [false, true]) {
    testWidgets('model covers and continuous Skill material, dark=$dark', (
      tester,
    ) async {
      final fixture = await _mount(
        tester,
        dark: dark,
        size: const Size(430, 1400),
      );
      final modelCards = [
        find.byKey(const ValueKey('asset-card-builtin:agent')),
        find.byKey(ValueKey('asset-card-${fixture.store.matt.key}')),
      ];
      for (final card in modelCards) {
        final material = tester.widget<Material>(card);
        final glass = MaasoGlassTheme.of(tester.element(card));
        expect(material.color, glass.muted);
        expect(material.elevation, 0);
        expect(material.shape, isNull);
        expect(
          find.descendant(of: card, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
        final cover = find.descendant(of: card, matching: find.byType(Image));
        expect(cover, findsOneWidget);
        expect(tester.widget<Image>(cover).fit, BoxFit.contain);
        expect(tester.widget<Image>(cover).image, isA<AssetImage>());
      }
      expect(
        find.image(const AssetImage('assets/model_store/agent.png')),
        findsOneWidget,
      );
      expect(
        find.image(const AssetImage(BundledAvatarContract.mattPreviewAsset)),
        findsOneWidget,
      );

      await _selectSection(tester, StoreHubSection.marketplace);
      final skillCards = [
        for (final skill in fixture.store.skills('en'))
          find.byKey(ValueKey('asset-card-${skill.key}')),
      ];
      for (var index = 0; index < skillCards.length; index++) {
        final card = skillCards[index];
        final material = tester.widget<Material>(card);
        final glass = MaasoGlassTheme.of(tester.element(card));
        expect(material.color, glass.muted);
        expect(material.elevation, 0);
        expect(material.shape, isNull);
        expect(
          find.descendant(of: card, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
        if (index > 0) {
          expect(
            tester.getRect(skillCards[index - 1]).bottom,
            closeTo(tester.getRect(card).top, .1),
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clearing model search reloads and restores both model covers', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.enterText(find.byType(TextField), 'Matt');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(fixture.store.calls.last.query, 'Matt');
    expect(find.text('Joy'), findsNothing);
    final mattTitle = find.descendant(
      of: find.byKey(ValueKey('asset-card-${fixture.store.matt.key}')),
      matching: find.text('Matt'),
    );
    expect(mattTitle, findsOneWidget);
    final beforeClear = fixture.store.calls.length;

    await tester.tap(find.byKey(const ValueKey('asset-store-clear-search')));
    await tester.pumpAndSettle();
    expect(fixture.store.calls.length, beforeClear + 1);
    expect(fixture.store.calls.last.type, 'model');
    expect(fixture.store.calls.last.query, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(find.text('Joy'), findsOneWidget);
    expect(mattTitle, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px large text can switch and submit search above keyboard', (
    tester,
  ) async {
    final fixture = await _mount(tester, size: const Size(320, 700), scale: 2);
    await _selectSection(tester, StoreHubSection.marketplace);
    final search = find.byType(TextField);
    await tester.ensureVisible(search);
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Web');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(fixture.store.calls.last.type, 'skill');
    expect(fixture.store.calls.last.query, 'Web');
    expect(tester.takeException(), isNull);
    await _selectSection(tester, StoreHubSection.models);
    expect(find.byType(StoreAssetCatalog), findsOneWidget);
    expect(
      tester.widget<StoreAssetCatalog>(find.byType(StoreAssetCatalog)).type,
      'model',
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (
      name: 'light-zh-393',
      locale: const Locale('zh'),
      dark: false,
      scale: 1.0,
      size: const Size(393, 852),
    ),
    (
      name: 'dark-zh-393',
      locale: const Locale('zh'),
      dark: true,
      scale: 1.0,
      size: const Size(393, 852),
    ),
    (
      name: 'light-en-375',
      locale: const Locale('en'),
      dark: false,
      scale: 1.0,
      size: const Size(375, 812),
    ),
    (
      name: 'dark-en-430',
      locale: const Locale('en'),
      dark: true,
      scale: 1.0,
      size: const Size(430, 932),
    ),
    (
      name: 'narrow-large-zh',
      locale: const Locale('zh'),
      dark: false,
      scale: 2.0,
      size: const Size(320, 740),
    ),
    (
      name: 'narrow-large-en',
      locale: const Locale('en'),
      dark: true,
      scale: 2.0,
      size: const Size(320, 740),
    ),
    (
      name: 'tablet-zh-768',
      locale: const Locale('zh'),
      dark: false,
      scale: 1.0,
      size: const Size(768, 1024),
    ),
    (
      name: 'desktop-en-1280',
      locale: const Locale('en'),
      dark: true,
      scale: 1.0,
      size: const Size(1280, 900),
    ),
    (
      name: 'landscape-en-1.3',
      locale: const Locale('en'),
      dark: false,
      scale: 1.3,
      size: const Size(812, 375),
    ),
  ]) {
    testWidgets('whole store layout ${scenario.name}', (tester) async {
      final previousShadows = debugDisableShadows;
      if (_capture) debugDisableShadows = false;
      try {
        final fixture = await _mount(
          tester,
          locale: scenario.locale,
          dark: scenario.dark,
          scale: scenario.scale,
          size: scenario.size,
          visual: _capture,
        );
        expect(tester.takeException(), isNull);
        await _captureFrame(tester, fixture, '${scenario.name}-models');
        await _scrollCatalogTo(
          tester,
          find.byKey(ValueKey('asset-card-${fixture.store.matt.key}')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await _selectSection(tester, StoreHubSection.marketplace);
        expect(tester.takeException(), isNull);
        await _captureFrame(tester, fixture, '${scenario.name}-skills');
        final lastSkill = fixture.store
            .skills(scenario.locale.languageCode)
            .last;
        await _scrollCatalogTo(
          tester,
          find.byKey(ValueKey('asset-card-${lastSkill.key}')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  bool dark = false,
  double scale = 1,
  Size size = const Size(393, 852),
  bool visual = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  AppLocalization.updateLocale(locale);
  final store = _Store();
  final avatars = AvatarConfigService(
    initialCatalog: AvatarConfigService.builtInCatalog,
  );
  final boundary = GlobalKey();
  if (visual) {
    await tester.runAsync(() async {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final font = File('/System/Library/Fonts/STHeiti Light.ttc');
      if (await font.exists()) {
        final data = ByteData.sublistView(await font.readAsBytes());
        for (final family in [_visualFont, 'Ahem', 'Roboto']) {
          await (FontLoader(family)..addFont(Future.value(data))).load();
        }
      }
    });
  }
  final base = AppTheme.build(
    AppPalette.of(dark ? Brightness.dark : Brightness.light, AppAccent.blue),
  ).copyWith(platform: TargetPlatform.iOS);
  Widget catalog(String type) => Builder(
    builder: (context) => MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      child: StoreAssetCatalog(
        type: type,
        header: const SizedBox.shrink(),
        legacyBuilder: (_) => const Text('Unexpected legacy catalog'),
        canContinue: () => true,
        service: store,
        avatars: avatars,
      ),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(
        theme: visual
            ? base.copyWith(
                textTheme: base.textTheme.apply(fontFamily: _visualFont),
                primaryTextTheme: base.primaryTextTheme.apply(
                  fontFamily: _visualFont,
                ),
              )
            : base,
        themeAnimationDuration: Duration.zero,
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 44, bottom: 24),
            textScaler: TextScaler.linear(scale),
          ),
          child: RepaintBoundary(key: boundary, child: child!),
        ),
        home: StoreHubPage(
          sectionBuilders: {
            StoreHubSection.models: (_) => catalog('model'),
            StoreHubSection.marketplace: (_) => catalog('skill'),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (visual) {
    await tester.runAsync(() async {
      await Future.wait([
        precacheImage(
          const AssetImage('assets/model_store/agent.png'),
          boundary.currentContext!,
        ),
        precacheImage(
          const AssetImage(BundledAvatarContract.mattPreviewAsset),
          boundary.currentContext!,
        ),
      ]);
    });
    await tester.pumpAndSettle();
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    store.close();
  });
  return _Fixture(store, boundary);
}

Future<void> _selectSection(
  WidgetTester tester,
  StoreHubSection section,
) async {
  final target = find.byKey(ValueKey('store-hub-${section.name}'));
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(target);
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
  final headerScroll = Scrollable.maybeOf(tester.element(target));
  if (headerScroll != null) {
    headerScroll.position.jumpTo(headerScroll.position.minScrollExtent);
    await tester.pumpAndSettle();
  }
}

Future<void> _scrollCatalogTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find
        .descendant(
          of: find.byType(StoreAssetCatalog),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .first,
  );
}

Future<void> _captureFrame(
  WidgetTester tester,
  _Fixture fixture,
  String name,
) async {
  if (!_capture) return;
  await tester.runAsync(() async {
    final render =
        fixture.boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final output = File(
      'build/verification/store-white-frost-20261022/$name.png',
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

final class _Fixture {
  const _Fixture(this.store, this.boundary);
  final _Store store;
  final GlobalKey boundary;
}

// All marketplace entries below are isolated test fixtures. Production catalog
// availability, approval, ownership and usage counts still come from the API.
class _Store extends AssetStoreService {
  _Store() : super(scope: () => 'white-frost-test');

  final calls = <({String type, String query, String sort})>[];

  StoreAsset get matt => StoreAsset.fromJson({
    ...assetJson(id: '7', version: 'a' * 64, type: 'model'),
    'title': 'Matt',
    'summary': 'Reviewed model fixture with the packaged full-body cover.',
    'author': {'name': 'Maaso'},
    'ownership': {'selected': false},
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

  List<StoreAsset> skills(String locale) {
    final chinese = locale == 'zh';
    return [
      _skill(
        id: 'web-search',
        version: '101',
        title: chinese ? '网页搜索' : 'Web search',
        summary: chinese
            ? '搜索公开信息，读取网页并整理要点。'
            : 'Find public information and summarize the useful details.',
      ),
      _skill(
        id: 'task-list',
        version: '102',
        title: chinese ? '任务清单' : 'Task list',
        summary: chinese
            ? '拆解多步骤任务，清楚查看每一步进度。'
            : 'Break a task into steps and keep track of progress.',
      ),
      _skill(
        id: 'scheduled-task',
        version: '103',
        title: chinese ? '定时任务' : 'Scheduled tasks',
        summary: chinese
            ? '为需要记住的事情设置提醒与周期任务。'
            : 'Set reminders and recurring tasks for things to remember.',
      ),
    ];
  }

  StoreAsset _skill({
    required String id,
    required String version,
    required String title,
    required String summary,
  }) => StoreAsset.fromJson({
    ...assetJson(id: id, version: version),
    'title': title,
    'summary': summary,
    'author': {'name': 'Maaso'},
    'ownership': {'installed': false},
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
    calls.add((type: type, query: query, sort: sort));
    final source = type == 'model' ? [matt] : skills(locale);
    final needle = query.toLowerCase();
    return StoreAssetPage([
      for (final asset in source)
        if (needle.isEmpty ||
            '${asset.title} ${asset.summary}'.toLowerCase().contains(needle))
          asset,
    ], null);
  }
}
