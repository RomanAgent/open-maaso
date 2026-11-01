import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:sembast/sembast_memory.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var databaseSerial = 0;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
    await appServices.reset();
    appServices.testMode = true;
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-away-chat-${databaseSerial++}.db',
    );
    appServices.put(database);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_IdleCore());
    appServices.put<HomeController>(_IdleHome());
    await database.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: 'self',
        content: '手机上继续聊天',
        timestamp: DateUtils.dateOnly(DateTime.now()),
        isUserMessage: true,
      ),
    );
    await database.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: '我在电脑上收到啦',
        timestamp: DateUtils.dateOnly(
          DateTime.now(),
        ).add(const Duration(minutes: 1)),
      ),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    debugDefaultTargetPlatformOverride = null;
    await appServices.reset();
  });

  testWidgets(
    'IME metrics keep Home avatar framing stable while composer moves',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      tester.view.viewPadding = const FakeViewPadding(top: 59, bottom: 34);
      tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: const MaterialApp(home: HomePage()),
          ),
        );
        await _waitForHomeHistory(tester, appServices.find<HomeController>(), [
          '手机上继续聊天',
          '我在电脑上收到啦',
        ]);
        final view = find.byType(UnityAvatarView);
        final resting = tester.widget<UnityAvatarView>(view).viewportSafeArea;
        final restingComposer = tester.getRect(find.byType(ChatInputBar));
        expect(resting?.bottom, closeTo(113 / 852, 1e-9));

        // Real FlutterView metrics: IME obscures the safe area, so padding is
        // zero while viewPadding still describes the physical home indicator.
        tester.view.padding = const FakeViewPadding(top: 59);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        await tester.pump();
        final media = MediaQuery.of(tester.element(view));
        expect(media.padding.bottom, 0);
        expect(media.viewPadding.bottom, 34);
        expect(tester.widget<UnityAvatarView>(view).viewportSafeArea, resting);
        expect(
          tester.getRect(find.byType(ChatInputBar)).top,
          lessThan(restingComposer.top),
        );

        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        tester.view.viewInsets = const FakeViewPadding();
        await tester.pump();
        expect(tester.widget<UnityAvatarView>(view).viewportSafeArea, resting);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'keyboard dismissal keeps the login door while rotation ends it',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.reset);
      final doorway = appServices.put(
        LoginDoorwayCoordinator(
          currentScope: () => 'same-account',
          currentGeneration: () => 1,
          accountMounted: () => true,
          consumeEntrance: () => true,
        ),
      )..requestAuthenticated();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(doorway.active, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      expect(
        doorway.active,
        isTrue,
        reason: 'IME changes insets but not the physical camera viewport.',
      );
      tester.view.physicalSize = const Size(852, 393);
      await tester.pump();
      expect(doorway.phase.value, LoginDoorwayStage.skipped);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 200));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} Home chat has no device-status panel', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final preferences = appServices.put(HomePresentationPreferenceService());
      preferences.mode.value = HomePresentationMode.chat;
      final home = appServices.find<HomeController>();
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: const MaterialApp(home: HomePage()),
          ),
        );
        await _waitForHomeHistory(tester, home, ['手机上继续聊天', '我在电脑上收到啦']);
        expect(
          find.byKey(const ValueKey('home-conversation-status')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('home-conversation-status-details')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(find.byType(MessageBubble), findsNWidgets(2));
        final history = tester.widget<HomeChatHistory>(
          find.byType(HomeChatHistory),
        );
        final header = tester.getRect(
          find.byKey(const ValueKey('home-status-header')),
        );
        expect(history.contentPadding.top, closeTo(header.bottom + 8, .01));
        await tester.enterText(find.byType(TextField), '本机聊天草稿');
        expect(home.inputController.text, '本机聊天草稿');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets(
    'Mac Home retains chat and drafts across remounts without capturing a room',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final home = appServices.find<HomeController>();
      final avatar = appServices.put(ActiveAvatarRuntime())
        ..register(_ReadyAvatar());
      final gateway = _HomeSceneGateway();
      final portal = AvatarPortalCoordinator(
        avatarRuntime: avatar,
        gateway: gateway,
      );
      Future<void> pumpHome({bool sceneActive = true}) async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: MaterialApp(
              home: AvatarPortalScope(
                portal: portal,
                avatarRuntime: avatar,
                sceneSurfaceActive: sceneActive,
                child: const HomePage(),
              ),
            ),
          ),
        );
        await _waitForHomeHistory(tester, home, ['手机上继续聊天', '我在电脑上收到啦']);
      }

      try {
        await pumpHome();
        expect(tester.takeException(), isNull);
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(find.byType(Texture), findsNothing);
        expect(gateway.requestedWorld, isEmpty);
        expect(portal.lease, isNull);
        expect(
          find.byKey(const ValueKey('desktop-home-chat-history')),
          findsOneWidget,
        );
        expect(find.byType(MessageBubble), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('home-conversation-status')),
          findsNothing,
        );
        await tester.enterText(find.byType(TextField), '尚未发送的桌面草稿');

        await pumpHome(sceneActive: false);
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(
          find.byKey(const ValueKey('desktop-home-chat-history')),
          findsOneWidget,
        );
        expect(gateway.requestedWorld, isEmpty);
        expect(home.inputController.text, '尚未发送的桌面草稿');

        await pumpHome();
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(
          find.byKey(const ValueKey('home-conversation-status')),
          findsNothing,
        );
        expect(gateway.requestedWorld, isEmpty);
        expect(home.inputController.text, '尚未发送的桌面草稿');
        expect(find.byType(MessageBubble), findsNWidgets(2));
        await pumpHome();
        await tester.runAsync(
          () => appServices.find<DBService>().saveChatMessage(
            ChatMessage(
              sessionId: 'self',
              senderId: 'self',
              receiverId: 'user',
              content: '回到桌面后继续同一段对话',
              timestamp: DateUtils.dateOnly(
                DateTime.now(),
              ).add(const Duration(minutes: 2)),
            ),
          ),
        );
        home.conversationRevision.value++;
        await _waitForHomeHistory(tester, home, [
          '手机上继续聊天',
          '我在电脑上收到啦',
          '回到桌面后继续同一段对话',
        ]);
        expect(find.text('回到桌面后继续同一段对话'), findsOneWidget);
        expect(find.byType(MessageBubble), findsNWidgets(3));
        expect(home.inputController.text, '尚未发送的桌面草稿');
        expect(gateway.requestedWorld, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        portal.dispose();
        unawaited(gateway.close());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('Mac Home composer sends through the local runtime, not relay', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final harness = (await tester.runAsync(() async {
      await appServices.reset();
      appServices.testMode = true;
      return ConversationEntryHarness.create();
    }))!;
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pump();
      expect(find.byType(UnityAvatarView), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-home-chat-history')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '继续桌面的本机对话');
      final composer = tester.widget<ChatInputBar>(find.byType(ChatInputBar));
      await tester.runAsync(() async {
        final reply = harness.runtime.onConversationMessage.firstWhere(
          (message) => message.content == 'C',
        );
        composer.onSend();
        await reply.timeout(const Duration(seconds: 5));
        await (() async {
          while (harness.home.isThinking.value) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        })().timeout(const Duration(seconds: 5));
      });
      await _waitForHomeHistory(tester, harness.home, [
        '继续桌面的本机对话',
        'A',
        'B',
        'C',
      ]);
      expect(harness.runtime.submissions, 1);
      final rows = (await tester.runAsync(
        () => harness.database.getMessages('self'),
      ))!;
      expect(
        rows.where((row) => row.isUserMessage).single.content,
        '继续桌面的本机对话',
      );
      expect(
        rows.where((row) => !row.isUserMessage).map((row) => row.content),
        ['A', 'B', 'C'],
      );
      expect(harness.home.isThinking.value, isFalse);
      expect(harness.home.inputController.text, isEmpty);
      expect(find.byType(MessageBubble), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(harness.close);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Home Agent space remains reachable with remote execution', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final lifecycle = appServices.put<AccountSessionLifecycleService>(
      _AwayLifecycle(),
    );
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: AppRouteCatalog.home,
      routes: [
        GoRoute(
          path: AppRouteCatalog.home,
          builder: (_, _) => const Stack(
            fit: StackFit.expand,
            children: [HomePage(), AppTopNoticeHost()],
          ),
        ),
        GoRoute(
          path: AppRouteCatalog.agentSpace,
          builder: (_, _) => const Scaffold(key: ValueKey('local-space-route')),
        ),
      ],
    );
    appNavigation.configure(router);
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(lifecycle.canExecuteAgent, isFalse);
      await tester.tap(find.byIcon(Icons.grid_view_rounded));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('home-menu-panel-layer')),
          matching: find.byIcon(Icons.home_outlined),
        ),
      );
      for (var attempt = 0; attempt < 6; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byKey(const ValueKey('local-space-route'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(appNavigation.currentRoute, AppRouteCatalog.agentSpace);
      expect(find.byKey(const ValueKey('local-space-route')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'Windows Home keeps its existing chat presentation for the local owner',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: const MaterialApp(home: HomePage()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(UnityAvatarView), findsNothing);
        expect(
          find.byKey(const ValueKey('desktop-home-chat-history')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'phone avatar view does not expose ownership or recall controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final home = appServices.find<HomeController>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(HomeChatHistory), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-startup-transition')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home-conversation-status')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);
      expect(find.byType(UnityAvatarView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-avatar-chat-window')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '保留这个草稿');
      await tester.pump();
      expect(home.inputController.text, '保留这个草稿');
      await _waitForHomeHistory(tester, home, ['手机上继续聊天', '我在电脑上收到啦']);
      expect(find.byType(MessageBubble), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'selected chat mode keeps local history and draft without a status panel',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(1179, 2556);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final presentation = appServices.put(HomePresentationPreferenceService());
      presentation.mode.value = HomePresentationMode.chat;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await _waitForHomeHistory(tester, appServices.find<HomeController>(), [
        '手机上继续聊天',
        '我在电脑上收到啦',
      ]);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('home-conversation-status')),
        findsNothing,
      );
      expect(find.byType(UnityAvatarView), findsNothing);
      expect(find.byType(MessageBubble), findsNWidgets(2));
      expect(find.text('手机上继续聊天'), findsOneWidget);
      expect(find.text('我在电脑上收到啦'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '新的草稿');
      expect(appServices.find<HomeController>().inputController.text, '新的草稿');
      final home = appServices.find<HomeController>() as _IdleHome;
      final header = tester.getRect(
        find.byKey(const ValueKey('home-status-header')),
      );
      final history = tester.getRect(
        find.byKey(const ValueKey('home-chat-scroll-view')),
      );
      expect(history.top, closeTo(0, .01));
      expect(history.bottom, closeTo(852, .01));
      expect(
        tester.getRect(find.byType(MessageBubble).first).top,
        greaterThanOrEqualTo(header.bottom),
      );
      expect(
        tester.getRect(find.byType(MessageBubble).last).bottom,
        lessThan(tester.getRect(find.byType(ChatInputBar)).top),
      );
      expect(find.byKey(const ValueKey('home-recall-agent')), findsNothing);
      expect(home.inputController.text, '新的草稿');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('hud-menu-open')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(appServices.find<HomeController>().inputController.text, '新的草稿');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Future<void> _waitForHomeHistory(
  WidgetTester tester,
  HomeController home,
  List<String> expectedContents,
) async {
  final elapsed = Stopwatch()..start();
  const timeout = Duration(seconds: 5);
  await tester.pump();
  while (true) {
    final renderedContents = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .map((bubble) => bubble.message.content)
        .toList();
    if (!home.isThinking.value &&
        listEquals(renderedContents, expectedContents)) {
      return;
    }
    if (elapsed.elapsed >= timeout) {
      const reason = 'Home did not render the completed DB history within 5s';
      expect(home.isThinking.value, isFalse, reason: reason);
      expect(renderedContents, expectedContents, reason: reason);
    }
    // Sembast reads can finish outside the widget test's fake clock. Let that
    // work progress, then render a frame; stop on actual contents, not a fixed
    // pump count or the absence of scheduled frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _IdleCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _IdleHome extends HomeController {
  @override
  // UI test retains the real state/composer, without executing any Agent.
  // ignore: must_call_super
  void onInit() {}
}

class _ReadyAvatar extends AvatarRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _AwayLifecycle extends AppService
    implements AccountSessionLifecycleService {
  @override
  bool get canPresentAvatar => false;
  @override
  bool get canExecuteAgent => false;
  @override
  bool get isMounted => true;
  @override
  int get generation => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HomeSceneGateway implements AvatarPortalGateway {
  final _events = StreamController<AvatarPortalEvent>.broadcast(sync: true);
  final requestedWorld = <bool>[];
  @override
  Stream<AvatarPortalEvent> get events => _events.stream;
  @override
  Future<AvatarPortalLease> acquire({
    required int generation,
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) async {
    requestedWorld.add(includeWorld);
    final lease = AvatarPortalLease(
      textureId: generation + 90,
      width: viewportWidth ?? 320,
      height: viewportHeight ?? 560,
      generation: generation,
    );
    scheduleMicrotask(
      () => _events.add(
        AvatarPortalEvent.firstFrame(
          generation: generation,
          textureId: lease.textureId,
          width: lease.width,
          height: lease.height,
        ),
      ),
    );
    return lease;
  }

  @override
  Future<void> release(int generation) async {}
  @override
  Future<void> resume(int generation) async {}
  @override
  Future<void> suspend(int generation) async {}
  @override
  Future<void> close() => _events.close();
}
