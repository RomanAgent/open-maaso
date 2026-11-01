import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:maaso/src/features/chat/data/chat_media_service.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_thinking_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_composer.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';
import 'helpers/home_native_editor_harness.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_status_header.dart';
import 'package:sembast/sembast_memory.dart' show databaseFactoryMemory;

const _scrollKey = ValueKey('home-chat-scroll-view');
const _historyKey = ValueKey('desktop-home-chat-history');
const _latestContent = '最新回复：这段对话会继续保留。';
const _previewBoundaryKey = ValueKey('home-chat-preview-boundary');
const _definedPreviewDirectory = String.fromEnvironment(
  'MAASO_CHAT_PREVIEW_DIR',
);
final _previewDirectory = _definedPreviewDirectory.isNotEmpty
    ? _definedPreviewDirectory
    : Platform.environment['MAASO_CHAT_PREVIEW_DIR'] ?? '';
const _previewFont = 'MaasoChatPreview';
const _previewFontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

// This fixture exercises the real Home, composer, history and bubble layouts.
// Only account/Agent initialization is suppressed: no model, TTS or relay starts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late _LayoutHome home;
  late HomeNativeEditorHarness editors;
  var databaseSerial = 0;

  setUpAll(() async {
    if (_previewDirectory.isEmpty) return;
    // Ahem turns Chinese into blocks in widget tests. A locally installed font
    // makes the optional diagnostic readable; no font asset is copied/shipped.
    final font = File(_previewFontPath);
    if (!await font.exists()) {
      throw StateError('Chat preview needs the local font $_previewFontPath');
    }
    final fontData = ByteData.sublistView(await font.readAsBytes());
    await (FontLoader(_previewFont)..addFont(Future.value(fontData))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() async {
    editors = HomeNativeEditorHarness()..install();
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(ThemeService());
    appServices.put(HomePresentationPreferenceService());
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-floating-layout-${databaseSerial++}.db',
    );
    appServices.put(database);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_LayoutCore());
    home = _LayoutHome();
    appServices.put<HomeController>(home);
    for (var index = 0; index < 24; index++) {
      await database.saveChatMessage(
        ChatMessage(
          sessionId: 'self',
          senderId: index.isEven ? 'user' : 'self',
          receiverId: index.isEven ? 'self' : 'user',
          content: index == 23
              ? _latestContent
              : '历史消息 $index：一起聊聊今天的生活，保留这段上下文。',
          timestamp: DateUtils.dateOnly(
            DateTime.now(),
          ).add(Duration(minutes: index)),
          isUserMessage: index.isEven,
        ),
      );
    }
  });

  tearDown(() async {
    editors.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
    await database.close();
  });

  testWidgets(
    'Agent attachment strip reserves space above the composer without overlapping chat',
    (tester) async {
      const layout = _LayoutCase(
        'avatar with attachment',
        TargetPlatform.iOS,
        Size(375, 812),
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        final window = find.byKey(const ValueKey('home-avatar-chat-slot'));
        final before = tester.getRect(window);
        final beforeComposer = tester.getRect(
          find.byKey(const ValueKey('home-composer-slot')),
        );
        final item = PreparedChatMedia(
          ChatAttachment(
            id: '1'.padLeft(64, '1'),
            kind: 'video',
            byteLength: 1,
            durationMs: 1000,
          ),
          Uint8List(1),
          'video/mp4',
        );
        home.pendingMedia.add(item);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final withAttachment = tester.getRect(window);
        final composer = tester.getRect(
          find.byKey(const ValueKey('home-composer-slot')),
        );
        expect(composer.height, greaterThan(beforeComposer.height));
        expect(
          withAttachment.bottom,
          closeTo(
            before.bottom - (composer.height - beforeComposer.height),
            .1,
          ),
        );
        expect(withAttachment.bottom, lessThan(composer.top));
        home.pendingMedia.clear();
        await tester.pump();
        await tester.pump();
        expect(tester.getRect(window), before);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'expanded Home with image, edit banner and keyboard clears header at large text',
    (tester) async {
      const layout = _LayoutCase(
        'expanded editor with banner',
        TargetPlatform.iOS,
        Size(375, 812),
        keyboard: 320,
        textScale: 2,
      );
      try {
        appletEditReference.value = AppletEditReference(
          item: AgentWidget(
            id: 1,
            agentId: 'self',
            title: 'Existing work with a long edit reference title',
            kind: 'surface',
            spec: {'surfaceId': 'saved-work', 'title': 'Existing work'},
            createdAt: DateTime.utc(2026),
          ),
          scopeKey: AppletLocalOwnership.currentScopeKey(),
        );
        home.pendingMedia.add(
          PreparedChatMedia(
            ChatAttachment(id: 'a' * 64, kind: 'image', byteLength: 1),
            Uint8List(1),
            'image/jpeg',
          ),
        );
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        await tester.tap(find.byKey(const ValueKey('home-expand-composer')));
        await tester.pump();
        await tester.pump();
        final composer = tester.getRect(
          find.byKey(const ValueKey('home-composer-slot')),
        );
        final header = tester.getRect(find.byType(HomeStatusHeader));
        expect(composer.top, greaterThanOrEqualTo(header.bottom + 8));
        expect(
          composer.bottom,
          lessThanOrEqualTo(layout.size.height - layout.keyboard - 1),
        );
        expect(
          find.byKey(const ValueKey('applet-edit-reference')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        appletEditReference.value = null;
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('navigation retires the menu before a covered ticker resumes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: AppRouteCatalog.home,
      routes: [
        GoRoute(
          path: AppRouteCatalog.home,
          builder: (_, _) => const HomePage(),
        ),
        GoRoute(
          path: AppRouteCatalog.agentSpace,
          builder: (_, _) => const Scaffold(body: Text('Space test host')),
        ),
      ],
    );
    appNavigation.configure(router);
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp.router(
            theme: AppTheme.build(
              AppPalette.of(Brightness.light, AppAccent.blue),
            ),
            routerConfig: router,
          ),
        ),
      );
      await _waitForLatest(tester);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('home-menu-panel-layer'));
      expect(menu, findsOneWidget);
      await tester.tap(
        find.descendant(of: menu, matching: find.text('Agent 空间')),
      );
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey('home-menu-panel-layer'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.text('Space test host'), findsOneWidget);
      router.pop();
      await tester.pump();
      expect(menu, findsNothing);
      expect(
        find.byKey(const ValueKey('home-menu-dismiss-layer')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byType(ChatInputBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
    }
  });

  testWidgets('real Home menu keeps game entries and stable header geometry', (
    tester,
  ) async {
    const layout = _LayoutCase(
      'avatar stable HUD',
      TargetPlatform.iOS,
      Size(375, 812),
    );
    try {
      await _pumpHome(tester, home, layout);
      await _waitForLatest(tester);
      final header = find.byType(HomeStatusHeader);
      final identity = tester.element(header);
      final toggle = find.byKey(const ValueKey('home-menu-toggle'));
      final toggleRect = tester.getRect(toggle);
      expect(find.byKey(const ValueKey('home-wallet-button')), findsNothing);

      // Real pointer events exercise the conditional Stack children which
      // previously replaced the header's element when the dismiss layer appeared.
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.tap(toggle);
        await tester.pump();
        for (var frame = 0; frame < 24; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
          expect(tester.element(header), same(identity));
          expect(tester.getRect(toggle), toggleRect);
          if (cycle.isEven) {
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('home-menu-panel-layer')),
                matching: find.byIcon(Icons.sports_esports_rounded),
              ),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('home-menu-wallet-item')),
              findsNothing,
            );
          }
        }
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('navigation retires the menu before a covered ticker resumes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: AppRouteCatalog.home,
      routes: [
        GoRoute(
          path: AppRouteCatalog.home,
          builder: (_, _) => const HomePage(),
        ),
        GoRoute(
          path: AppRouteCatalog.agentSpace,
          builder: (_, _) => const Scaffold(body: Text('Space test host')),
        ),
      ],
    );
    appNavigation.configure(router);
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp.router(
            theme: AppTheme.build(
              AppPalette.of(Brightness.light, AppAccent.blue),
            ),
            routerConfig: router,
          ),
        ),
      );
      await _waitForLatest(tester);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('home-menu-panel-layer'));
      expect(menu, findsOneWidget);
      await tester.tap(
        find.descendant(of: menu, matching: find.text('Agent 空间')),
      );
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey('home-menu-panel-layer'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.text('Space test host'), findsOneWidget);
      router.pop();
      await tester.pump();
      expect(menu, findsNothing);
      expect(
        find.byKey(const ValueKey('home-menu-dismiss-layer')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(find.byType(ChatInputBar), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pumpAndSettle();
      expect(menu, findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
    }
  });

  testWidgets(
    'real Home menu reuses one native sampler while reversing and releases it on close',
    (tester) async {
      final native = _HudNativeRecorder(editors)..install();
      const layout = _LayoutCase(
        'avatar native menu',
        TargetPlatform.iOS,
        Size(375, 812),
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        final before = Set<int>.from(native.created);
        final toggle = find.byKey(const ValueKey('home-menu-toggle'));
        await tester.tap(toggle);
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 70));
        await tester.pump();
        final menu = find.byKey(const ValueKey('home-menu-frost'));
        expect(tester.widget<AppNativeFrostGroup>(menu).fit, StackFit.loose);
        final sampler = find.descendant(
          of: menu,
          matching: find.byType(UiKitView),
        );
        expect(sampler, findsOneWidget);
        final menuViews = native.created.where((id) => !before.contains(id));
        expect(menuViews, hasLength(1));
        final id = menuViews.single;
        final samplerState = tester.state(sampler);
        final headerSampler = tester.widget<UiKitView>(
          find.descendant(
            of: find.byType(HomeStatusHeader),
            matching: find.byType(UiKitView),
          ),
        );
        expect(
          tester.widget<UiKitView>(sampler).viewType,
          headerSampler.viewType,
        );
        for (final filter in [FadeTransition, ShaderMask, Opacity]) {
          expect(
            find.ancestor(of: sampler, matching: find.byType(filter)),
            findsNothing,
            reason: 'UIKit applies its own opacity mask, outside text filters',
          );
        }
        final payload = native.payloads[id]!.last;
        expect(payload['opacity'], allOf(greaterThan(0), lessThan(1)));
        expect(payload['topFade'], 0);
        expect(payload['bottomFade'], 0);
        final regions = payload['regions'] as List;
        expect(regions, hasLength(1));
        final region = regions.single as Map;
        expect((headerSampler.creationParams as Map)['cornerRadius'], 0.0);
        expect((headerSampler.creationParams as Map)['group'], isTrue);
        expect(
          (headerSampler.creationParams as Map).containsKey('shape'),
          isFalse,
        );
        expect(region['radius'], 20);
        expect(region['userTint'], isFalse);
        final menuRect = tester.getRect(menu);
        expect(region['width'], closeTo(menuRect.width, .01));
        expect(region['height'], closeTo(menuRect.height, .01));

        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 25));
        await tester.pump();
        expect(sampler, findsOneWidget);
        expect(
          native.payloads[id]!.last['opacity'],
          allOf(greaterThan(0), lessThan(payload['opacity'] as double)),
        );
        expect(
          find
              .descendant(of: menu, matching: find.byType(InkWell))
              .hitTestable(),
          findsNothing,
          reason: 'closing content must stop accepting actions immediately',
        );
        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.pump();
        expect(tester.state(sampler), same(samplerState));
        expect(native.created.where((id) => !before.contains(id)), [id]);
        expect(native.disposed, isNot(contains(id)));
        expect(native.payloads[id]!.last['opacity'], 1);
        expect(
          find
              .descendant(of: menu, matching: find.byType(InkWell))
              .hitTestable(),
          findsNWidgets(5),
          reason:
              'Wallet and Agent Feed are hidden; game and applet entries remain.',
        );

        await tester.tap(toggle);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await tester.pump();
        expect(menu, findsNothing);
        expect(native.disposed, contains(id));
        expect(
          find.byKey(const ValueKey('home-menu-panel-layer')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('home-menu-dismiss-layer')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        native.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final reduceMotion in [false, true]) {
    testWidgets(
      'real Home menu waits for native material and can cancel/reopen (reduce motion: $reduceMotion)',
      (tester) async {
        final native = _HudNativeRecorder(editors)..install();
        const layout = _LayoutCase(
          'pending menu',
          TargetPlatform.iOS,
          Size(375, 812),
        );
        final create = Completer<void>();
        final ack = Completer<void>();
        try {
          await _pumpHome(tester, home, layout, reduceMotion: reduceMotion);
          await _waitForLatest(tester);
          final existing = Set<int>.from(native.created);
          native.delayCreate = (id) async {
            if (!existing.contains(id)) await create.future;
          };
          native.delayRegions = (id) async {
            if (!existing.contains(id)) await ack.future;
          };
          final toggle = find.byKey(const ValueKey('home-menu-toggle'));
          final menu = find.byKey(const ValueKey('home-menu-frost'));
          double foreground() => tester
              .widgetList<Opacity>(
                find.descendant(of: menu, matching: find.byType(Opacity)),
              )
              .first
              .opacity;
          await tester.tap(toggle);
          for (var frame = 0; frame < 8; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
          }
          final firstId = native.created.last;
          expect(foreground(), 0);
          expect(
            find
                .descendant(of: menu, matching: find.byType(InkWell))
                .hitTestable(),
            findsNothing,
          );
          expect(toggle.hitTestable(), findsOneWidget);
          // A native view which never finishes creation must remain cancellable.
          await tester.tap(toggle);
          await tester.pump();
          expect(menu, findsNothing);
          expect(
            find.byKey(const ValueKey('home-menu-dismiss-layer')),
            findsNothing,
          );
          create.complete();
          await tester.pump();
          await tester.tap(toggle);
          for (var frame = 0; frame < 8; frame++) {
            await tester.pump(const Duration(milliseconds: 80));
          }
          final id = native.created.last;
          expect(id, isNot(firstId));
          expect(native.payloads[id]!.single['opacity'], 0);
          expect(foreground(), 0);
          ack.complete();
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 60));
          expect(
            foreground(),
            reduceMotion ? equals(1) : allOf(greaterThan(0), lessThan(1)),
          );
          await tester.pump(const Duration(milliseconds: 240));
          await tester.pump();
          expect(foreground(), 1);
          expect(native.payloads[id]!.last['opacity'], 1);
          // Normal motion reverses the existing sampler; reduced motion closes
          // instantly, so reopening in the same frame needs a fresh generation.
          await tester.tap(toggle);
          await tester.tap(toggle);
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 240));
          await tester.pump();
          expect(foreground(), 1);
          expect(
            find
                .descendant(of: menu, matching: find.byType(InkWell))
                .hitTestable(),
            findsNWidgets(5),
            reason:
                'Wallet and Agent Feed are hidden; game and applet entries remain.',
          );
          expect(tester.takeException(), isNull);
        } finally {
          if (!create.isCompleted) create.complete();
          if (!ack.isCompleted) ack.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          native.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  for (final layout in const [
    _LayoutCase('portrait', TargetPlatform.iOS, Size(375, 812)),
    _LayoutCase(
      'short landscape',
      TargetPlatform.iOS,
      Size(812, 320),
      safeArea: EdgeInsets.fromLTRB(44, 0, 44, 21),
    ),
  ]) {
    testWidgets(
      'real Home ${layout.name} menu fits content and reaches settings',
      (tester) async {
        final native = _HudNativeRecorder(editors)..install();
        try {
          await _pumpHome(tester, home, layout);
          await _waitForLatest(tester);
          await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
          for (var frame = 0; frame < 5; frame++) {
            await tester.pump();
          }
          await tester.pump(const Duration(milliseconds: 240));
          final menu = find.byKey(const ValueKey('home-menu-frost'));
          final rect = tester.getRect(menu);
          final header = tester.getRect(find.byType(HomeStatusHeader));
          expect(rect.width, 204);
          expect(rect.top, greaterThanOrEqualTo(header.bottom + 8));
          expect(
            rect.bottom,
            lessThanOrEqualTo(layout.size.height - layout.safeArea.bottom),
          );
          expect(
            rect.bottom,
            lessThanOrEqualTo(
              tester.getRect(find.byType(ChatInputBar)).top - 4,
            ),
            reason: 'menu actions must remain above the interactive composer',
          );
          final scrollable = find.descendant(
            of: menu,
            matching: find.byType(Scrollable),
          );
          final position = tester.state<ScrollableState>(scrollable).position;
          final settings = find.descendant(
            of: menu,
            matching: find.text('settings.title'.tr),
          );
          if (layout.name == 'portrait') {
            expect(position.maxScrollExtent, 0);
            expect(rect.height, lessThan(450));
            expect(settings.hitTestable(), findsOneWidget);
          } else {
            expect(position.maxScrollExtent, greaterThan(0));
            expect(settings.hitTestable(), findsNothing);
            await tester.scrollUntilVisible(
              settings,
              100,
              scrollable: scrollable,
            );
            await tester.pump(const Duration(milliseconds: 240));
            expect(settings.hitTestable(), findsOneWidget);
          }
          expect(
            tester
                .widget<InkWell>(
                  find.ancestor(of: settings, matching: find.byType(InkWell)),
                )
                .onTap,
            isNotNull,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          native.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets(
    'real Home menu opening and both closing paths leave chat hidden',
    (tester) async {
      const layout = _LayoutCase(
        'avatar menu chat exclusion',
        TargetPlatform.iOS,
        Size(375, 812),
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        final visibility = find.byType(ChatWindowVisibilityScope);
        expect(
          tester.widget<ChatWindowVisibilityScope>(visibility).visible,
          isTrue,
        );
        final toggle = find.byKey(const ValueKey('home-menu-toggle'));
        for (final outside in [false, true]) {
          await tester.tap(toggle);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 240));
          expect(
            tester.widget<ChatWindowVisibilityScope>(visibility).visible,
            isFalse,
          );
          if (outside) {
            await tester.tapAt(const Offset(30, 300));
          } else {
            await tester.tap(toggle);
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 240));
          expect(
            tester.widget<ChatWindowVisibilityScope>(visibility).visible,
            isFalse,
          );
          expect(_latestBubble().hitTestable(), findsNothing);
          expect(find.byKey(const ValueKey('home-menu-frost')), findsNothing);
        }
        // Once fully closed there is no stale menu hit layer preventing the
        // genuine chat wake action in its original position.
        await tester.tap(find.byKey(const ValueKey('chat-window-wake-region')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(
          tester.widget<ChatWindowVisibilityScope>(visibility).visible,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final layout in const [
    _LayoutCase('tap visibility phone', TargetPlatform.iOS, Size(375, 812)),
    _LayoutCase(
      'tap visibility narrow large text',
      TargetPlatform.iOS,
      Size(320, 740),
      textScale: 2,
    ),
    _LayoutCase(
      'tap visibility landscape',
      TargetPlatform.iOS,
      Size(844, 430),
      safeArea: EdgeInsets.only(left: 44, right: 44, bottom: 21),
    ),
  ]) {
    testWidgets(
      '${layout.name}: outside hides and native input reveals history',
      (tester) async {
        try {
          await _pumpHome(tester, home, layout, reduceMotion: true);
          await _waitForLatest(tester);
          final visibility = find.descendant(
            of: find.byType(HomeChatHistory),
            matching: find.byType(ChatWindowVisibilityScope),
          );
          bool visible() =>
              tester.widget<ChatWindowVisibilityScope>(visibility).visible;
          expect(visible(), isTrue);
          final window = tester.getRect(
            find.byKey(const ValueKey('home-avatar-chat-slot')),
          );
          final header = tester.getRect(find.byType(HomeStatusHeader));
          final scenePoint = Offset(
            layout.safeArea.left + 8,
            header.bottom + 28,
          );
          expect(window.contains(scenePoint), isFalse);
          await tester.tapAt(scenePoint);
          await tester.pump();
          expect(visible(), isFalse);
          expect(_latestBubble().hitTestable(), findsNothing);
          home.latestBubble.value = '收到新消息也不自动弹出';
          home.isThinking.value = true;
          await tester.pump(const Duration(milliseconds: 300));
          expect(visible(), isFalse);
          await tester.tap(
            find.byKey(const ValueKey('chat-window-wake-region')),
          );
          await tester.pump();
          expect(visible(), isTrue);
          expect(
            find.byKey(const ValueKey('message-action-menu')),
            findsNothing,
          );
          await tester.tapAt(scenePoint);
          await tester.pump();
          expect(visible(), isFalse);
          await tester.tap(find.byKey(const ValueKey('home-composer-editor')));
          await editors.focus();
          await tester.pump();
          expect(visible(), isTrue);
          // Retire the real history before clearing fixture state; changing
          // thinking here would start an unrelated asynchronous DB reload.
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets(
    'focused avatar history remains visible above the keyboard composer',
    (tester) async {
      const layout = _LayoutCase(
        'visible keyboard history',
        TargetPlatform.iOS,
        Size(375, 812),
        keyboard: 320,
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        await tester.tap(find.byKey(const ValueKey('home-composer-editor')));
        await editors.focus();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        final window = tester.getRect(
          find.byKey(const ValueKey('home-avatar-chat-slot')),
        );
        final composer = tester.getRect(
          find.byKey(const ValueKey('home-composer-slot')),
        );
        final header = tester.getRect(find.byType(HomeStatusHeader));
        expect(window.height, greaterThan(0));
        expect(window.bottom, lessThanOrEqualTo(composer.top - 4));
        expect(window.top, greaterThanOrEqualTo(header.bottom));
        final visibility = find.descendant(
          of: find.byType(HomeChatHistory),
          matching: find.byType(ChatWindowVisibilityScope),
        );
        expect(
          tester.widget<ChatWindowVisibilityScope>(visibility).visible,
          isTrue,
        );
        expect(_latestBubble().hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final layout in _layouts) {
    testWidgets(
      '${layout.name}: selected chat mode fills viewport with usable floating controls',
      (tester) async {
        try {
          await _pumpHome(
            tester,
            home,
            layout,
            presentationMode: HomePresentationMode.chat,
          );
          await _waitForLatest(tester);
          expect(find.byType(UnityAvatarView), findsNothing);
          expect(find.byKey(_historyKey), findsOneWidget);
          _expectFullViewport(tester, layout.size);

          final composerFinder = find.byType(ChatInputBar);
          final composer = tester.getRect(composerFinder);
          final menu = tester.getRect(
            find.byKey(const ValueKey('home-menu-toggle')),
          );
          expect(
            tester.widget<ChatInputBar>(composerFinder).floatingGlass,
            isTrue,
          );
          expect(composer.left, greaterThanOrEqualTo(layout.safeArea.left));
          expect(
            composer.right,
            lessThanOrEqualTo(layout.size.width - layout.safeArea.right),
          );
          expect(
            composer.bottom,
            lessThanOrEqualTo(layout.size.height - layout.keyboard - 1),
          );
          expect(composer.top, greaterThan(menu.bottom));
          expect(menu.top, greaterThanOrEqualTo(layout.safeArea.top));
          expect(
            menu.right,
            lessThanOrEqualTo(layout.size.width - layout.safeArea.right),
          );

          final statusHeader = tester.getRect(
            find.byKey(const ValueKey('home-status-header')),
          );
          final history = tester.widget<HomeChatHistory>(
            find.byType(HomeChatHistory),
          );
          expect(
            history.contentPadding.top,
            closeTo(statusHeader.bottom + 8, .01),
          );
          expect(
            find.byKey(const ValueKey('home-conversation-status')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);

          final latest = tester.getRect(_latestBubble());
          expect(latest.bottom, lessThanOrEqualTo(composer.top - 4));
          expect(latest.bottom, greaterThan(menu.bottom));
          expect(
            find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
            findsOneWidget,
          );
          final previewName = switch (layout.name) {
            '375px phone chat' => 'phone-chat-latest',
            'Mac local' => 'mac-local-latest',
            'phone large text dark' => 'phone-chat-dark-large-text',
            _ => null,
          };
          if (previewName != null) {
            await _exportPreview(tester, layout, previewName);
          }
          await editors.enterText(tester, '这是一条未发送的草稿');
          await tester.pump();
          expect(home.inputController.text, '这是一条未发送的草稿');
          expect(tester.takeException(), isNull);
        } finally {
          try {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      },
    );
  }

  for (final layout in const [
    _LayoutCase('local phone', TargetPlatform.iOS, Size(375, 812)),
    _LayoutCase(
      'local narrow large text',
      TargetPlatform.iOS,
      Size(320, 568),
      textScale: 2,
      safeArea: EdgeInsets.only(top: 24, bottom: 20),
    ),
    _LayoutCase(
      'local landscape',
      TargetPlatform.iOS,
      Size(812, 375),
      safeArea: EdgeInsets.fromLTRB(44, 0, 44, 21),
    ),
    _LayoutCase(
      'local keyboard',
      TargetPlatform.iOS,
      Size(375, 812),
      keyboard: 320,
    ),
  ]) {
    testWidgets(
      '${layout.name}: local view choice preserves history and drafts',
      (tester) async {
        try {
          await _pumpHome(tester, home, layout);
          await _waitForLatest(tester);
          final preferences = appServices
              .find<HomePresentationPreferenceService>();
          final scene = tester.getRect(find.byType(UnityAvatarView));
          final window = tester.getRect(
            find.byKey(const ValueKey('home-avatar-chat-window')),
          );
          final header = tester.getRect(
            find.byKey(const ValueKey('home-status-header')),
          );
          final composer = tester.getRect(find.byType(ChatInputBar));
          expect(scene, Offset.zero & layout.size);
          expect(window.height, greaterThan(0));
          expect(window.height, lessThanOrEqualTo(layout.size.height * .36));
          expect(window.top, greaterThanOrEqualTo(header.bottom + 8));
          expect(window.bottom, lessThanOrEqualTo(composer.top - 4));
          expect(
            find.byKey(const ValueKey('home-conversation-status')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);
          expect(
            find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
            findsOneWidget,
          );
          home.inputController.text = '本机视图切换保留的草稿';

          preferences.mode.value = HomePresentationMode.chat;
          await tester.pump();
          await _waitForLatest(tester);
          expect(find.byType(UnityAvatarView), findsNothing);
          _expectFullViewport(tester, layout.size);
          expect(
            find.byKey(const ValueKey('home-conversation-status')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);
          expect(
            tester.getRect(_latestBubble()).bottom,
            lessThanOrEqualTo(
              tester.getRect(find.byType(ChatInputBar)).top - 4,
            ),
          );
          expect(home.inputController.text, '本机视图切换保留的草稿');

          preferences.mode.value = HomePresentationMode.avatar;
          await tester.pump();
          await _waitForLatest(tester);
          expect(tester.getRect(find.byType(UnityAvatarView)), scene);
          expect(
            tester.getRect(
              find.byKey(const ValueKey('home-avatar-chat-window')),
            ),
            window,
          );
          expect(home.inputController.text, '本机视图切换保留的草稿');
          expect(
            find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
            findsOneWidget,
          );
          expect(preferences.mode.value, HomePresentationMode.avatar);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('phone idle and input keep the avatar Home and usable composer', (
    tester,
  ) async {
    const layout = _LayoutCase(
      'phone recovery',
      TargetPlatform.iOS,
      Size(375, 812),
    );
    try {
      await _pumpHome(tester, home, layout);
      await _waitForLatest(tester);
      final avatarState = tester.state(find.byType(UnityAvatarView));
      final avatarBounds = tester.getRect(find.byType(UnityAvatarView));
      final windowBounds = tester.getRect(
        find.byKey(const ValueKey('home-avatar-chat-window')),
      );
      home.inputController.text = '恢复前的草稿';
      await tester.pump();

      expect(find.byType(HomeChatHistory), findsOneWidget);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-avatar-chat-window')),
        findsOneWidget,
      );
      expect(home.inputController.text, '恢复前的草稿');
      expect(find.byType(ChatInputBar), findsOneWidget);
      final composer = tester.getRect(find.byType(ChatInputBar));
      expect(composer.top, greaterThan(0));
      expect(composer.bottom, lessThanOrEqualTo(layout.size.height));
      await tester.pump(const Duration(seconds: 31));
      expect(find.byType(HomeChatHistory), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      await _exportPreview(tester, layout, 'phone-idle-waiting');
      await editors.enterText(tester, '恢复期间仍可继续输入');
      await tester.pump();
      expect(home.inputController.text, '恢复期间仍可继续输入');
      expect(find.byType(HomeChatHistory), findsOneWidget);

      await tester.pump();
      await tester.pump();
      await _waitForLatest(tester);
      expect(tester.state(find.byType(UnityAvatarView)), same(avatarState));
      expect(tester.getRect(find.byType(UnityAvatarView)), avatarBounds);
      expect(
        tester.getRect(find.byKey(const ValueKey('home-avatar-chat-window'))),
        windowBounds,
      );
      expect(
        appServices.find<HomePresentationPreferenceService>().mode.value,
        HomePresentationMode.avatar,
      );
      expect(home.inputController.text, '恢复期间仍可继续输入');
      expect(_latestBubble().hitTestable(), findsOneWidget);
      // Explicit input focus reveals the compact conversation and keeps it
      // available across ordinary Home rebuilds.
      await editors.blur();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await _settleMessageLayout(tester);
      expect(
        tester
            .widget<ChatWindowVisibilityScope>(
              find.descendant(
                of: find.byType(HomeChatHistory),
                matching: find.byType(ChatWindowVisibilityScope),
              ),
            )
            .visible,
        isTrue,
      );

      expect(_latestBubble().hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'history moves behind floating composer while text input keeps hit testing',
    (tester) async {
      const layout = _LayoutCase('phone', TargetPlatform.iOS, Size(375, 812));
      try {
        await _pumpHome(
          tester,
          home,
          layout,
          presentationMode: HomePresentationMode.chat,
        );
        await _waitForLatest(tester);
        final viewport = tester.getRect(find.byKey(_scrollKey));
        final composer = tester.getRect(find.byType(ChatInputBar));
        final latest = tester.getRect(_latestBubble());
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(_scrollKey),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final shiftBehindComposer = composer.center.dy - latest.center.dy;
        expect(shiftBehindComposer, greaterThan(0));
        expect(
          scroll.position.maxScrollExtent,
          greaterThan(shiftBehindComposer),
        );
        // An actual gesture must relinquish follow-latest ownership. A direct
        // jumpTo is a programmatic scroll and intentionally does not do that.
        final gesture = await tester.startGesture(viewport.center);
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump();
        await gesture.moveBy(Offset(0, shiftBehindComposer));
        await tester.pump(const Duration(milliseconds: 150));
        await gesture.up();
        await tester.pump();
        expect(tester.getRect(_latestBubble()).overlaps(composer), isTrue);
        expect(tester.getRect(find.byKey(_scrollKey)), viewport);
        expect(viewport.bottom, greaterThan(composer.bottom));
        final returnToLatest = find.byKey(
          const ValueKey('home-chat-scroll-to-latest'),
        );
        expect(returnToLatest.hitTestable(), findsOneWidget);
        final returnButton = tester.getRect(returnToLatest);
        expect(returnButton.bottom, lessThanOrEqualTo(composer.top - 4));
        expect(returnButton.top, greaterThanOrEqualTo(layout.safeArea.top));
        expect(
          find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
          findsOneWidget,
        );
        await _exportPreview(tester, layout, 'phone-away-scrolled-history');
        await tester.tap(find.byKey(const ValueKey('home-composer-editor')));
        if (layout.platform == TargetPlatform.iOS ||
            layout.platform == TargetPlatform.android)
          await editors.focus();
        await tester.pump();
        expect(
          HomeChatInteractionScope.maybeOf(
            tester.element(find.byType(HomeChatComposer)),
          )!.hasFocus,
          isTrue,
        );
        await editors.enterText(tester, '历史在背后，输入仍能操作');
        expect(home.inputController.text, '历史在背后，输入仍能操作');
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );

  for (final layout in const [
    _LayoutCase(
      'small-avatar',
      TargetPlatform.iOS,
      Size(320, 568),
      safeArea: EdgeInsets.only(top: 20),
    ),
    _LayoutCase(
      'avatar-large-text-dark',
      TargetPlatform.iOS,
      Size(375, 812),
      brightness: Brightness.dark,
      textScale: 2,
    ),
    _LayoutCase(
      'avatar-landscape',
      TargetPlatform.iOS,
      Size(812, 375),
      safeArea: EdgeInsets.fromLTRB(44, 0, 44, 21),
    ),
    _LayoutCase(
      'avatar-keyboard',
      TargetPlatform.iOS,
      Size(375, 812),
      keyboard: 320,
    ),
  ]) {
    testWidgets(
      '${layout.name}: long thinking stays in the message window and composer remains usable',
      (tester) async {
        try {
          await _pumpHome(tester, home, layout);
          await _waitForLatest(tester);
          home.isThinking.value = true;
          home.latestThought.value = List.filled(
            8,
            '正在整理刚才讨论的内容，让这段文字在消息流里自然换行。',
          ).join('\n');
          await tester.pump();
          await _settleMessageLayout(tester);
          final window = tester.getRect(
            find.byKey(const ValueKey('home-avatar-chat-window')),
          );
          final composer = tester.getRect(find.byType(ChatInputBar));
          expect(
            window.height,
            lessThanOrEqualTo(layout.size.height * .36 + .1),
          );
          expect(window.top, greaterThanOrEqualTo(layout.safeArea.top + 48));
          expect(window.bottom, lessThanOrEqualTo(composer.top - 4));
          expect(window.right, lessThanOrEqualTo(layout.size.width - 14));
          expect(find.byType(ChatThinkingBubble), findsOneWidget);
          expect(
            find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
            findsOneWidget,
          );
          await editors.enterText(tester, '可继续输入');
          expect(home.inputController.text, '可继续输入');
          await _exportPreview(tester, layout, layout.name);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets(
    '320x400 avatar at 3x text keeps the chat window below the compact HUD',
    (tester) async {
      const layout = _LayoutCase(
        'short-avatar-triple-text',
        TargetPlatform.iOS,
        Size(320, 400),
        safeArea: EdgeInsets.only(top: 24),
        textScale: 3,
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        final header = tester.getRect(
          find.byKey(const ValueKey('home-status-header')),
        );
        final window = tester.getRect(
          find.byKey(const ValueKey('home-avatar-chat-window')),
        );
        final composer = tester.getRect(find.byType(ChatInputBar));
        expect(find.byType(UnityAvatarView), findsOneWidget);
        expect(
          tester.getRect(find.byType(UnityAvatarView)),
          Offset.zero & layout.size,
        );
        expect(header.top, greaterThanOrEqualTo(layout.safeArea.top));
        expect(header.height, allOf(greaterThan(48), lessThan(100)));
        expect(window.height, greaterThan(0));
        expect(window.height, lessThanOrEqualTo(layout.size.height * .36));
        expect(window.top, greaterThanOrEqualTo(header.bottom + 8));
        expect(window.overlaps(header), isFalse);
        expect(window.bottom, lessThanOrEqualTo(composer.top - 4));
        expect(window.width, closeTo(layout.size.width * .68, .1));
        expect(
          find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'phone local owner retains the full world and avatar composer policy',
    (tester) async {
      const layout = _LayoutCase(
        'phone owner',
        TargetPlatform.iOS,
        Size(375, 812),
      );
      try {
        await _pumpHome(tester, home, layout);
        await _waitForLatest(tester);
        expect(find.byType(UnityAvatarView), findsOneWidget);
        expect(find.byKey(_scrollKey), findsOneWidget);
        expect(find.byKey(_historyKey), findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-conversation-status')),
          findsNothing,
        );
        final avatar = tester.widget<UnityAvatarView>(
          find.byType(UnityAvatarView),
        );
        expect(avatar.includeWorld, isTrue);
        expect(avatar.holdToWalk, isFalse);
        final before = tester.getRect(find.byType(UnityAvatarView));
        final composerBefore = tester.getRect(find.byType(ChatInputBar));
        final windowBefore = tester.getRect(
          find.byKey(const ValueKey('home-avatar-chat-window')),
        );
        expect(windowBefore.width, closeTo(layout.size.width * .68, .1));
        expect(windowBefore.height, closeTo(layout.size.height * .36, .1));
        expect(windowBefore.bottom, lessThanOrEqualTo(composerBefore.top - 4));
        expect(
          tester.getRect(_latestBubble()).bottom,
          lessThanOrEqualTo(windowBefore.bottom),
        );
        await _exportPreview(tester, layout, 'phone-avatar-message-window');
        home.isThinking.value = true;
        home.latestThought.value = '先整理你刚才提到的两个重点。';
        await tester.pump();
        await _settleMessageLayout(tester);
        expect(find.byType(ChatThinkingBubble), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_scrollKey),
            matching: find.byType(ChatThinkingBubble),
          ),
          findsOneWidget,
        );
        await _exportPreview(tester, layout, 'phone-avatar-inline-thinking');
        expect(
          tester.widget<ChatInputBar>(find.byType(ChatInputBar)).floatingGlass,
          isTrue,
        );
        final nativeFrost = find.descendant(
          of: find.byType(ChatInputBar),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is UiKitView &&
                widget.viewType == AppFrostedInputBackground.nativeViewType &&
                (widget.creationParams as Map)['group'] != true,
          ),
        );
        expect(nativeFrost, findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is UiKitView &&
                (widget.creationParams as Map?)?['group'] == true,
          ),
          findsNWidgets(2),
        );
        expect(tester.widget<UiKitView>(nativeFrost).creationParams, {
          'dark': false,
          'cornerRadius': 20.0,
        });
        expect(
          find.ancestor(of: nativeFrost, matching: find.byType(IgnorePointer)),
          findsWidgets,
        );
        expect(find.byKey(AppGlassScaffold.unityUnderlayWashKey), findsNothing);
        expect(
          tester
              .widget<AppGlassScaffold>(find.byType(AppGlassScaffold))
              .backdropKind,
          GlassBackdropKind.platformView,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        await _pumpHome(
          tester,
          home,
          const _LayoutCase(
            'phone owner keyboard',
            TargetPlatform.iOS,
            Size(375, 812),
            keyboard: 320,
          ),
        );
        final after = tester.getRect(find.byType(UnityAvatarView));
        expect(after, before);
        expect(after, Offset.zero & layout.size);
        expect(
          tester.getRect(find.byType(ChatInputBar)).top,
          lessThan(composerBefore.top),
        );
        final keyboardWindow = tester.getRect(
          find.byKey(const ValueKey('home-avatar-chat-window')),
        );
        expect(
          keyboardWindow.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(ChatInputBar)).top - 4),
        );
        expect(keyboardWindow.top, greaterThanOrEqualTo(44 + 48));
        expect(
          find.byKey(const ValueKey('home-composer-editor')).hitTestable(),
          findsOneWidget,
        );
        await editors.enterText(tester, '输入栏可用');
        expect(home.inputController.text, '输入栏可用');
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    },
  );
}

const _layouts = [
  _LayoutCase('375px phone chat', TargetPlatform.iOS, Size(375, 812)),
  _LayoutCase(
    'Mac local',
    TargetPlatform.macOS,
    Size(1000, 760),
    safeArea: EdgeInsets.only(top: 28),
  ),
  _LayoutCase(
    'Windows chat',
    TargetPlatform.windows,
    Size(1000, 760),
    safeArea: EdgeInsets.only(top: 28),
  ),
  _LayoutCase(
    'phone landscape notch',
    TargetPlatform.iOS,
    Size(812, 375),
    safeArea: EdgeInsets.fromLTRB(44, 0, 44, 21),
  ),
  _LayoutCase(
    'phone keyboard',
    TargetPlatform.iOS,
    Size(375, 812),
    keyboard: 320,
  ),
  _LayoutCase(
    'phone large text dark',
    TargetPlatform.iOS,
    Size(375, 812),
    textScale: 2,
    brightness: Brightness.dark,
  ),
  _LayoutCase(
    'compact Mac large text dark',
    TargetPlatform.macOS,
    Size(640, 480),
    textScale: 1.8,
    brightness: Brightness.dark,
    safeArea: EdgeInsets.only(top: 28),
  ),
  _LayoutCase(
    'wide Mac local dark',
    TargetPlatform.macOS,
    Size(1280, 800),
    brightness: Brightness.dark,
    safeArea: EdgeInsets.only(top: 28),
  ),
];

class _LayoutCase {
  const _LayoutCase(
    this.name,
    this.platform,
    this.size, {
    this.safeArea = const EdgeInsets.only(top: 44, bottom: 34),
    this.keyboard = 0,
    this.textScale = 1,
    this.brightness = Brightness.light,
  });
  final String name;
  final TargetPlatform platform;
  final Size size;
  final EdgeInsets safeArea;
  final double keyboard;
  final double textScale;
  final Brightness brightness;
}

Future<void> _pumpHome(
  WidgetTester tester,
  _LayoutHome home,
  _LayoutCase layout, {
  bool reduceMotion = false,
  HomePresentationMode presentationMode = HomePresentationMode.avatar,
}) async {
  debugDefaultTargetPlatformOverride = layout.platform;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = layout.size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // Exercise the actual reactive presentation choice without starting a
  // platform preferences write inside the widget test's fake async clock.
  appServices.find<HomePresentationPreferenceService>().mode.value =
      presentationMode;
  appServices.find<ThemeService>().setBrightness(layout.brightness);
  var theme = AppTheme.build(AppPalette.of(layout.brightness, AppAccent.blue));
  if (_previewDirectory.isNotEmpty) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: _previewFont),
      primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _previewFont),
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: layout.size,
            padding: layout.safeArea.copyWith(
              bottom: layout.keyboard > 0 ? 0 : layout.safeArea.bottom,
            ),
            viewPadding: layout.safeArea,
            viewInsets: EdgeInsets.only(bottom: layout.keyboard),
            textScaler: TextScaler.linear(layout.textScale),
            platformBrightness: layout.brightness,
            disableAnimations: reduceMotion,
          ),
          child: RepaintBoundary(
            key: _previewBoundaryKey,
            child: _previewDirectory.isEmpty
                ? child!
                : ColoredBox(
                    color: layout.brightness == Brightness.dark
                        ? const Color(0xFF202733)
                        : const Color(0xFFE7EDF5),
                    child: child!,
                  ),
          ),
        ),
        home: const HomePage(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _exportPreview(
  WidgetTester tester,
  _LayoutCase layout,
  String name,
) async {
  if (_previewDirectory.isEmpty) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_previewBoundaryKey),
  );
  expect(boundary.debugNeedsPaint, isFalse);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Could not encode $name preview');
      final output = Directory(_previewDirectory);
      await output.create(recursive: true);
      await File('${output.path}/$name.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      await File('${output.path}/$name.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'source': 'Actual HomePage widgets with synthetic in-memory messages',
          'diagnosticOnly': true,
          'nativeLayerNote':
              'Unity and UIKit native input materials cannot be captured by flutter_tester. The preview uses a neutral backdrop only to visualize the Flutter message alpha and layout; native composition requires device verification.',
          'realUserData': false,
          'platform': layout.platform.name,
          'logicalWidth': layout.size.width,
          'logicalHeight': layout.size.height,
          'pixelRatio': 2,
          'brightness': layout.brightness.name,
          'textScale': layout.textScale,
          'keyboardInset': layout.keyboard,
          'fontOverride': _previewFontPath,
          'fontNote':
              'Themed text uses a readable local font. Null-family button text still uses test-engine fallback and can show missing glyphs; these PNGs do not verify live system fonts.',
        }),
      );
    } finally {
      image.dispose();
    }
  });
}

Finder _latestBubble() => find.byWidgetPredicate(
  (widget) =>
      widget is MessageBubble && widget.message.content == _latestContent,
);

Future<void> _waitForLatest(WidgetTester tester) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (_latestBubble().evaluate().isNotEmpty) {
      await _settleMessageLayout(tester);
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  throw TimeoutException(
    'The real Home history did not load the seeded latest message.',
  );
}

Future<void> _settleMessageLayout(WidgetTester tester) async {
  // Variable-height lazy rows refine the estimated scroll extent. Wait for
  // actual scrolling to settle without waiting for the repeating typing dots.
  var stableFrames = 0;
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(_scrollKey),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    if (!scroll.isScrollingNotifier.value &&
        scroll.pixels <= scroll.maxScrollExtent + .5 &&
        scroll.extentAfter < 1) {
      if (++stableFrames >= 3) return;
    } else {
      stableFrames = 0;
    }
  }
  throw TimeoutException('The message viewport did not settle at its tail.');
}

void _expectFullViewport(WidgetTester tester, Size size) {
  final viewport = tester.getRect(find.byKey(_scrollKey));
  expect(viewport.left, closeTo(0, .01));
  expect(viewport.top, closeTo(0, .01));
  expect(viewport.width, closeTo(size.width, .01));
  expect(viewport.height, closeTo(size.height, .01));
}

class _LayoutCore extends AgentCoreController {
  @override
  // Intentionally omit real Agent/account initialization for this layout test.
  // ignore: must_call_super
  void onInit() {}
}

class _HudNativeRecorder {
  _HudNativeRecorder(this.editors);
  final HomeNativeEditorHarness editors;
  final created = <int>[];
  final disposed = <int>[];
  final payloads = <int, List<Map<Object?, Object?>>>{};
  Future<void> Function(int)? delayCreate;
  Future<void> Function(int)? delayRegions;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      final args = call.arguments;
      if (call.method == 'create' &&
          args is Map &&
          args['viewType'] == HomeNativeTextEditingBridge.viewType)
        return editors.handlePlatformCall(call);
      final id = args is Map ? args['id'] as int : args as int;
      if (call.method == 'create') {
        created.add(id);
        messenger.setMockMethodCallHandler(
          MethodChannel('maaso/frosted_input/$id'),
          (call) async {
            if (call.method == 'regions') {
              (payloads[id] ??= []).add(
                Map<Object?, Object?>.from(call.arguments as Map),
              );
              await delayRegions?.call(id);
            }
            return null;
          },
        );
        await delayCreate?.call(id);
      } else if (call.method == 'dispose' && created.contains(id)) {
        disposed.add(id);
      }
      return null;
    });
  }

  void dispose() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final id in created) {
      messenger.setMockMethodCallHandler(
        MethodChannel('maaso/frosted_input/$id'),
        null,
      );
    }
  }
}

class _LayoutHome extends HomeController {
  @override
  // Preserve production observable state and composer without starting a turn.
  // ignore: must_call_super
  void onInit() {}
}
