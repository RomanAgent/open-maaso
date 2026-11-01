import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_attachment.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/presentation/project_build_saved_management.dart';
import 'project_build_v2_delivery_test.dart' as delivery;

class _EditingHome extends HomeController {
  @override
  // No model, TTS, relay or account bootstrap: actual edit methods and Home UI
  // remain unchanged in this fixture.
  // ignore: must_call_super
  void onInit() {}
}

class _EditingCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late delivery.Harness h;
  late Map<String, Object?> wire;
  late AgentWidget item;
  late GoRouter router;
  var homeConstructed = 0, head = 2;
  final posts = <String>[];
  Map<String, Object?> object(Object? value) => projectBuildV2Object(value);
  Map<String, Object?> history() => {
    ...object(wire['revisionsAfterFork']),
    'currentHeadVersion': head,
    'currentRevisionId': object(
      (object(wire['head$head'])['projects']! as List).single,
    )['currentRevisionId'],
    'revisions': (object(wire['revisionsAfterFork'])['revisions']! as List)
        .where(
          (r) =>
              object(r)['revisionId'] !=
              object(wire['thirdRevisionDocument'])['revisionId'],
        )
        .toList(),
  };
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    homeConstructed = 0;
    head = 2;
    posts.clear();
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    wire = object(
      jsonDecode(
        File('tool/fixtures/project_head_v2_wire.json').readAsStringSync(),
      ),
    );
    h = delivery.Harness(appletScope: AppletLocalOwnership.deviceLegacyScope);
    await h.init();
    h.head = 4;
    h.inventory['projects'] = wire['head2'];
    h.inventory['revisions'] = history();
    for (final key in ['firstRevisionDocument', 'secondRevisionDocument']) {
      final doc = object(wire[key]);
      h.documents[doc['revisionId']! as String] = doc;
    }
    h.specialRequest = (request) async {
      if (request.method == 'POST') {
        posts.add(request.url.path);
        return http.Response('{}', 500);
      }
      return null;
    };
    appServices.put(h.db);
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(ThemeService());
    appServices.put(
      const AppPlatformCapabilities.forPlatform(AppHostPlatform.linux),
    );
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: true));
    appServices.put<AgentCoreController>(_EditingCore());
    appServices.put<ProjectBuildV2Tasks>(h.tasks);
    appServices.lazyPut<HomeController>(() {
      homeConstructed++;
      return _EditingHome()..inputController.text = 'Keep this unsent draft';
    });
    final candidate = ProjectBuildV2Candidate.fromJson(
      object(wire['secondRevisionDocument']),
    );
    item = AgentWidget(
      id: 7,
      agentId: 'self',
      title: 'Saved project',
      kind: 'surface',
      createdAt: DateTime.now(),
      spec: {
        'rendering': 'projectBundle',
        'surfaceId': candidate.bundle.manifest.projectId,
        'bundleReference': {
          'packageSchema': 2,
          'projectId': candidate.bundle.manifest.projectId,
          'revisionId': candidate.reference.revisionId,
          'candidateDigest': candidate.reference.candidateDigest,
          'reportDigest': candidate.reference.reportDigest,
        },
      },
    );
    AppletLocalOwnership.stamp(item);
    router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/manage',
      routes: [
        GoRoute(
          path: '/manage',
          builder: (context, _) => Scaffold(
            body: TextButton(
              key: const ValueKey('manage'),
              onPressed: () =>
                  unawaited(showProjectBuildSavedManagement(context, item)),
              child: const Text('Manage'),
            ),
          ),
        ),
        GoRoute(
          path: AppRouteCatalog.home,
          builder: (_, state) =>
              HomePage(draftIntent: state.extra as HomeDraftIntent?),
        ),
      ],
    );
    appNavigation.configure(router);
  });
  tearDown(() async {
    router.dispose();
    await h.close();
    await appServices.reset();
  });
  Future<void> settle(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (ready()) return;
    }
    fail('Edit handoff did not reach expected state');
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }

  Future<void> mount(WidgetTester tester, {double scale = 1}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    );
    await tap(tester, find.byKey(const ValueKey('manage')));
    await settle(
      tester,
      () =>
          find
              .byKey(const ValueKey('project-build-edit'))
              .evaluate()
              .isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
  }

  testWidgets(
    'saved sheet mints the displayed baseline and cold Home consumes native intent without sending',
    (tester) async {
      await mount(tester, scale: 2);
      expect(homeConstructed, 0);
      await tap(tester, find.byKey(const ValueKey('project-build-edit')));
      await settle(
        tester,
        () => find
            .byKey(const ValueKey('project-build-edit-reference'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect(homeConstructed, 1);
      final home = appServices.find<HomeController>(),
          target = appServices
              .find<HomeController>()
              .projectBuildEditTarget
              .value!;
      expect(target.projectId, item.spec['surfaceId']);
      expect(
        target.baseRevision,
        object(wire['secondRevisionDocument'])['revisionId'],
      );
      expect(target.baseHeadVersion, 2);
      expect(
        target.candidateDigest,
        object(wire['secondRevisionDocument'])['candidateDigest'],
      );
      expect(target.isCurrent, isTrue);
      expect(home.inputController.text, 'Keep this unsent draft');
      expect(posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
      final media = PreparedChatMedia(
        ChatAttachment(id: 'a' * 64, kind: 'image', byteLength: 1),
        Uint8List.fromList([1]),
        'image/jpeg',
      );
      home.pendingMedia.add(media);
      await tester.pump();
      await tap(tester, find.byKey(const ValueKey('project-build-edit-clear')));
      await tester.pump();
      expect(home.projectBuildEditTarget.value, isNull);
      expect(home.pendingMedia.single, same(media));
      expect(home.inputController.text, 'Keep this unsent draft');
      expect(posts, isEmpty);
      // Rebuilding the same route extra does not consume/restore the target twice.
      await tester.pump();
      expect(home.projectBuildEditTarget.value, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'new game intent clears the old V2 target only after explicit draft replacement and keeps images',
    (tester) async {
      await mount(tester);
      await tap(tester, find.byKey(const ValueKey('project-build-edit')));
      await settle(
        tester,
        () => find
            .byKey(const ValueKey('project-build-edit-reference'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 500));
      final home = appServices.find<HomeController>();
      final selected = home.projectBuildEditTarget.value;
      final media = PreparedChatMedia(
        ChatAttachment(id: 'a' * 64, kind: 'image', byteLength: 1),
        Uint8List.fromList([1]),
        'image/jpeg',
      );
      home.pendingMedia.add(media);
      appNavigation.go(
        AppRouteCatalog.home,
        extra: HomeDraftIntent.gameCreation(
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          prompt: 'Create a playable mini game.',
        ),
      );
      await settle(
        tester,
        () => find
            .byKey(const ValueKey('game-draft-replace'))
            .evaluate()
            .isNotEmpty,
      );
      expect(home.projectBuildEditTarget.value, same(selected));
      expect(home.inputController.text, 'Keep this unsent draft');
      await tester.pump(const Duration(milliseconds: 500));
      await tap(tester, find.byKey(const ValueKey('game-draft-replace')));
      await settle(tester, () => home.projectBuildEditTarget.value == null);
      expect(home.inputController.text, 'Create a playable mini game.');
      expect(home.pendingMedia.single, same(media));
      expect(posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty new-game draft retires V2 selection after the Home update frame without auto submission',
    (tester) async {
      await mount(tester);
      await tap(tester, find.byKey(const ValueKey('project-build-edit')));
      await settle(
        tester,
        () => find
            .byKey(const ValueKey('project-build-edit-reference'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 500));
      final home = appServices.find<HomeController>();
      home.inputController.clear();
      appNavigation.go(
        AppRouteCatalog.home,
        extra: HomeDraftIntent.gameCreation(
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          prompt: 'Create a playable mini game.',
        ),
      );
      await settle(tester, () => home.projectBuildEditTarget.value == null);
      expect(tester.takeException(), isNull);
      expect(home.inputController.text, 'Create a playable mini game.');
      expect(find.byKey(const ValueKey('game-draft-replace')), findsNothing);
      expect(posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'changed head requires refresh instead of silently editing the newer version',
    (tester) async {
      await mount(tester);
      head = 3;
      h.inventory['projects'] = wire['head3'];
      h.inventory['revisions'] = history();
      await tap(tester, find.byKey(const ValueKey('project-build-edit')));
      await settle(
        tester,
        () => find.text('作品版本已发生变化，请刷新后重新选择。').evaluate().isNotEmpty,
      );
      expect(homeConstructed, 0);
      expect(posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'scope retirement while preparing prevents navigation and task creation',
    (tester) async {
      await mount(tester);
      final entered = Completer<void>(), release = Completer<void>();
      h.specialRequest = (request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/projects')) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        if (request.method == 'POST') posts.add(request.url.path);
        return null;
      };
      await tap(tester, find.byKey(const ValueKey('project-build-edit')));
      await settle(tester, () => entered.isCompleted);
      h.current = false;
      release.complete();
      await settle(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(homeConstructed, 0);
      expect(posts, isEmpty);
      expect(appNavigation.currentRoute, '/manage');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unavailable creation keeps the edit action disabled without inventing a target',
    (tester) async {
      h.creationReady = false;
      await mount(tester);
      final button = tester.widget<AppGlassButton>(
        find.byKey(const ValueKey('project-build-edit')),
      );
      expect(button.onPressed, isNull);
      expect(homeConstructed, 0);
      expect(posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
