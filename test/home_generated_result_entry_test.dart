import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:sembast/sembast_memory.dart';

class _IdleHome extends HomeController {
  @override
  // Only suppress model/account startup; use production Home state and layout.
  // ignore: must_call_super
  void onInit() {}
}

class _IdleCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _SnapshotDb extends DBService {
  Completer<List<AgentWidget>>? nextSnapshot;

  @override
  Future<List<AgentWidget>> getAllWidgets() {
    final held = nextSnapshot;
    nextSnapshot = null;
    return held?.future ?? super.getAllWidgets();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentTaskJobStore store;
  late HomeController home;
  var serial = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(ThemeService());
    appServices.put(HomePresentationPreferenceService());
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    database = await _SnapshotDb().init(
      factory: databaseFactoryMemory,
      path: 'home-result-entry-${serial++}.db',
    );
    appServices.put(database);
    appServices.put<AgentCoreController>(_IdleCore());
    store = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(database),
    ).init();
    appServices.put(store);
    home = appServices.put<HomeController>(_IdleHome());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    await store.deactivateAndDrain();
    await appServices.reset();
    await database.close();
  });

  test(
    'retired bulb widget, state, positioning and discovery glue are absent',
    () {
      final page = File(
        'lib/src/features/home/presentation/home_page.dart',
      ).readAsStringSync();
      final controller = File(
        'lib/src/features/home/application/home_controller.dart',
      ).readAsStringSync();
      final stage = File(
        'lib/src/core/widgets/widget_stage_controller.dart',
      ).readAsStringSync();
      for (final old in [
        '_PendingWidgetBulb',
        'Icons.lightbulb_rounded',
        'home.pending_widget_tap',
      ]) {
        expect(page, isNot(contains(old)));
      }
      for (final old in [
        'pendingWidget',
        'dismissPendingWidget',
        '_checkForNewWidget',
        '_projectDeletionGeneration',
      ]) {
        expect(controller, isNot(contains(old)));
      }
      expect(stage, isNot(contains('pendingBulbTopLeft')));
    },
  );

  test(
    'a closed Home cannot receive a late generated-result dock read',
    () async {
      final snapshot = Completer<List<AgentWidget>>();
      (database as _SnapshotDb).nextSnapshot = snapshot;
      final loading = home.loadDock();
      await Future<void>.delayed(Duration.zero);
      home.closeLifecycle();
      final old = AgentWidget(
        agentId: 'self',
        title: 'Late former result',
        kind: 'surface',
        spec: const {'surfaceId': 'late-former-game', 'experienceType': 'game'},
        createdAt: DateTime.now(),
      );
      AppletLocalOwnership.stamp(old);
      snapshot.complete([old]);
      await loading;
      expect(home.dockWidgets, isEmpty);
    },
  );

  for (final layout in [
    (
      TargetPlatform.iOS,
      HomePresentationMode.chat,
      const Size(375, 812),
      Brightness.light,
    ),
    (
      TargetPlatform.iOS,
      HomePresentationMode.avatar,
      const Size(430, 932),
      Brightness.dark,
    ),
    (
      TargetPlatform.macOS,
      HomePresentationMode.chat,
      const Size(1280, 850),
      Brightness.light,
    ),
  ]) {
    testWidgets(
      'completed result stays in ${layout.$1.name}/${layout.$2.name} chat without a bulb',
      (tester) async {
        debugDefaultTargetPlatformOverride = layout.$1;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = layout.$3;
        addTearDown(tester.view.reset);
        appServices.find<HomePresentationPreferenceService>().mode.value =
            layout.$2;
        appServices.find<ThemeService>().setBrightness(layout.$4);
        final unseen = AgentWidget(
          agentId: 'self',
          title: '以前完成但还没打开的作品',
          kind: 'surface',
          spec: const {'surfaceId': 'prior-game', 'experienceType': 'game'},
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        );
        AppletLocalOwnership.stamp(unseen);
        await tester.runAsync(() async {
          await database.saveAgentWidget(unseen);
          await home.loadDock();
        });
        const requirement = '完成本次自由玩法作品';
        await tester.runAsync(() async {
          final job = store.start(
            agentId: 'self',
            taskKind: AgentTaskKind.gameGeneration,
            userText: requirement,
            appletScopeKey: AppletLocalOwnership.currentScopeKey(),
          );
          store.complete(job.id, summary: '作品已写好并且保存');
          await store.flush();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: MaterialApp(
              theme: AppTheme.build(AppPalette.of(layout.$4, AppAccent.blue)),
              builder: (context, child) => MediaQuery(
                data: MediaQueryData(
                  size: layout.$3,
                  padding: const EdgeInsets.only(top: 44, bottom: 34),
                  disableAnimations: true,
                  textScaler: TextScaler.linear(
                    layout.$1 == TargetPlatform.macOS ? 1.3 : 1,
                  ),
                ),
                child: child!,
              ),
              home: const HomePage(),
            ),
          ),
        );
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(find.byIcon(Icons.lightbulb_rounded), findsNothing);
        expect(find.byIcon(Icons.lightbulb_outline_rounded), findsNothing);
        expect(find.byType(AgentTaskChatCard), findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-avatar-chat-slot')),
          layout.$2 == HomePresentationMode.avatar
              ? findsOneWidget
              : findsNothing,
        );
        expect(find.text(requirement), findsOneWidget);
        expect(
          find.byKey(const ValueKey('home-composer-slot')),
          findsOneWidget,
        );
        final widgets = await tester.runAsync(database.getAllWidgets);
        expect(widgets!.single.seen, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
