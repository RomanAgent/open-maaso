import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:sembast/sembast_memory.dart';
import 'helpers/home_native_editor_harness.dart';

class _HistoryHome extends HomeController {
  @override
  // Real Home state/layout; skip model, voice and execution-lease bootstrap.
  // ignore: must_call_super
  void onInit() {}
}

class _HistoryCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  late SembastAgentTaskPersistence persistence;
  late AgentTaskJobStore store;
  late HomeNativeEditorHarness nativeEditor;
  var serial = 0;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    nativeEditor = HomeNativeEditorHarness()..install();
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-history-${serial++}.db',
    );
    appServices.put(db);
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(ThemeService());
    appServices.put(
      const AppPlatformCapabilities.forPlatform(AppHostPlatform.linux),
    );
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_HistoryCore());
    persistence = SembastAgentTaskPersistence(db);
    store = AgentTaskJobStore(persistence: persistence);
  });
  tearDown(() async {
    nativeEditor.dispose();
    await store.deactivateAndDrain();
    await appServices.reset();
    await db.close();
  });
  Future<void> seed(String id, String scope, String title) async {
    final yesterday = DateUtils.dateOnly(
      DateTime.now(),
    ).subtract(const Duration(days: 1));
    final job = AgentTaskJob(
      id: id,
      agentId: 'self',
      taskKind: AgentTaskKind.surfaceGeneration,
      userText: title,
      status: AgentTaskJobStatus.failed,
      stage: AgentTaskStage.failed,
      createdAt: yesterday,
      updatedAt: yesterday,
      appletScopeKey: scope,
    );
    await persistence.writeJob(job.toJson(), store.cardFor(job));
  }

  Future<void> mount(
    WidgetTester tester, {
    required Size size,
    required Brightness brightness,
    double scale = 1,
  }) async {
    await tester.runAsync(store.init);
    appServices.put(store);
    appServices.put<HomeController>(_HistoryHome());
    appServices.find<ThemeService>().setBrightness(brightness);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: const HomePage(),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('home-menu-toggle')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  for (final layout in [
    (size: const Size(375, 812), brightness: Brightness.light, scale: 1.0),
    (size: const Size(320, 760), brightness: Brightness.dark, scale: 2.0),
    (size: const Size(812, 375), brightness: Brightness.light, scale: 1.0),
  ]) {
    testWidgets(
      'yesterday-only tasks remain reachable beside the Home menu at ${layout.size} and ${layout.scale}x',
      (tester) async {
        await tester.runAsync(() async {
          await seed('job_1000_1', 'device-legacy', '昨天的制作任务');
          await seed('job_1000_2', 'other-account', '其他账号的任务');
        });
        final before = await tester.runAsync(persistence.readJobs);
        // mount uses the same restored task store and real Home chat-day filter.
        await mount(
          tester,
          size: layout.size,
          brightness: layout.brightness,
          scale: layout.scale,
        );
        expect(find.byKey(const ValueKey('home-task-ledger')), findsNothing);
        expect(find.text('任务记录'), findsNothing);
        expect(
          find.byType(AgentTaskChatCard),
          findsNothing,
          reason: 'only yesterday has task cards',
        );
        final entry = find.byKey(const ValueKey('home-task-history-button'));
        expect(entry, findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-menu-task-history')),
          findsNothing,
        );
        final rect = tester.getRect(entry);
        expect(rect.height, greaterThanOrEqualTo(48));
        // Exercise the real 48px header button, not an inert wrapper.
        await tester.tapAt(Offset(rect.left + 12, rect.bottom - 1));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('昨天的制作任务'), findsOneWidget);
        expect(find.text('其他账号的任务'), findsNothing);
        await tester.tap(find.text('昨天的制作任务'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.byType(AgentTaskChatCard), findsOneWidget);
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byType(AgentTaskChatCard)),
          ).scale(10),
          10 * layout.scale,
        );
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.byKey(const ValueKey('home-menu-panel-layer')),
          findsNothing,
        );
        expect(find.byType(AgentTaskChatCard), findsNothing);
        expect(await tester.runAsync(persistence.readJobs), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'header history opens the empty state without exposing foreign tasks',
    (tester) async {
      await tester.runAsync(
        () => seed('job_1000_3', 'other-account', '其他账号的任务'),
      );
      await mount(
        tester,
        size: const Size(375, 812),
        brightness: Brightness.light,
      );
      await openMenu(tester);
      expect(
        find.byKey(const ValueKey('home-menu-task-history')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('home-task-ledger')), findsNothing);
      expect(find.byKey(const ValueKey('home-menu-wallet-item')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-task-history-button')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('其他账号的任务'), findsNothing);
      expect(find.textContaining('还没有制作任务'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-menu-panel-layer')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
