import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/features/avatars/presentation/avatars_page.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const retiredWidgetName =
      'Avatar'
      '3D'
      'View';
  const retiredBackendName =
      'Avatar'
      'Backend'
      'Kind'
      '.'
      'vrm';
  const retiredRuntimeName =
      'Vrm'
      'Avatar'
      'Runtime';
  const retiredRuntimeFile =
      'v'
      'rm'
      '_avatar_runtime.dart';
  const retiredViewFile =
      'avatar'
      '3d'
      '_view.dart';
  const retiredAssetPath =
      'assets/'
      'avatar'
      '3d';

  test('home world renders Unity directly', () {
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(home, contains('UnityAvatarView'));
    expect(home, isNot(contains(retiredWidgetName)));
    expect(home, isNot(contains('AgentAvatarView')));
    expect(home, contains('backgroundColor: Colors.transparent'));
  });

  test('home uses Unity as the full-screen world layer by default', () {
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(
      home,
      contains('child: _HomeWorldBackdrop(key: ValueKey(sceneAttempt))'),
    );
    expect(home, contains('class _HomeWorldBackdrop'));
    expect(home, contains('return UnityAvatarView('));
    expect(
      home,
      contains(
        'viewportSafeArea: _HomeChrome.avatarViewportSafeAreaOf(context)',
      ),
    );
    expect(
      home,
      contains('viewportActive: ModalRoute.of(context)?.isCurrent ?? true'),
    );
    expect(home, contains('return const SizedBox.shrink();'));
    expect(home, isNot(contains(retiredBackendName)));
    expect(
      home,
      isNot(contains('return PlayfulBackdrop(\n            child: Stack(')),
    );
  });

  test('speech and local bridge route through ActiveAvatarRuntime', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final bridge = File(
      'lib/src/core/services/self_avatar_speech_bridge.dart',
    ).readAsStringSync();

    expect(runtime, contains('ActiveAvatarRuntime'));
    expect(runtime, contains('emotionToAvatarParams'));
    expect(runtime, contains('setMouthOpen'));
    expect(bridge, contains('ActiveAvatarRuntime'));
    expect(bridge, contains('emotionToAvatarParams'));
  });

  test('home has no separate fallback avatar stage', () {
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(home, isNot(contains('_AvatarStage')));
    expect(home, isNot(contains('_InputSafeAvatarStage')));
    expect(home, isNot(contains('WidgetStageController.avatarStageInsets')));
    expect(home, isNot(contains('Alignment.bottomLeft')));
    expect(home, isNot(contains('Offset(-0.10, 0.02)')));
  });

  test('gaze director depends on renderer-neutral avatar runtime', () {
    final gaze = File(
      'lib/src/core/services/gaze_director.dart',
    ).readAsStringSync();

    expect(gaze, contains('AvatarRuntime'));
  });

  test('device avatar runtimes stay permanent and account spaces are owned', () {
    final main = File('lib/main.dart').readAsStringSync();

    expect(main, contains('final activeAvatarRuntime = appServices.put('));
    expect(main, contains('ActiveAvatarRuntime(),'));
    expect(main, contains('permanent: true,'));
    expect(
      main,
      contains(
        "import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';",
      ),
    );
    expect(main, isNot(contains(retiredRuntimeName)));
    expect(main, isNot(contains(retiredRuntimeFile)));
    expect(
      main,
      contains(
        'final unityAvatarRuntime = appServices.put<UnityAvatarRuntime>(',
      ),
    );
    expect(main, contains('activeAvatarRuntime.register(unityAvatarRuntime);'));
    expect(main, contains('putOwned(AvatarWorldThemeService());'));
    expect(main, matches(RegExp(r'putOwned\(\s*AgentSpaceController\(')));
    expect(main, contains('avatar: activeAvatarRuntime'));
    expect(main, contains('isCurrent: () => _isCurrentAccountMount(mount)'));
    for (final retired in [
      'AgentWorldService(',
      'WorldRuntime(',
      'WorldAvatarSelectionFenceRuntime',
      'WorldCapabilityAuthority(',
    ]) {
      expect(main, isNot(contains(retired)));
    }
    expect(main, contains('accountSession: authCandidate.session'));
    expect(main, contains('environmentKey: accountScope.environmentKey'));
    expect(main, contains('avatarRuntime: activeAvatarRuntime'));
    expect(
      main,
      isNot(
        contains(
          'activeAvatarRuntime.register(appServices.put(UnityAvatarRuntime(',
        ),
      ),
    );
  });

  test('avatar selection storage initializes before avatar configuration', () {
    final main = File('lib/main.dart').readAsStringSync();
    final storageInit = main.indexOf('await SpUtils.init();');
    final catalogInit = main.indexOf('final avatarCatalog = putOwned(');
    final outboxInit = main.indexOf(
      'final avatarSelectionOutbox = putOwned<AvatarSelectionOutbox>',
    );
    final coordinatorInit = main.indexOf(
      'final avatarSelectionCoordinator = putOwned(',
    );
    final avatarConfigInit = main.indexOf('AvatarConfigService(');
    final agentSpaceInit = main.indexOf('AgentSpaceController(');

    expect(storageInit, greaterThanOrEqualTo(0));
    expect(catalogInit, greaterThan(storageInit));
    expect(outboxInit, greaterThan(catalogInit));
    expect(coordinatorInit, greaterThan(outboxInit));
    expect(avatarConfigInit, greaterThan(coordinatorInit));
    expect(agentSpaceInit, greaterThan(avatarConfigInit));
    expect(
      main,
      matches(
        RegExp(
          r'selectionCoordinator:\s*kOpenMaasoLocalEdition\s*\? null\s*: avatarSelectionCoordinator',
        ),
      ),
    );
    expect(main, contains('selectionAssetOptions: avatarCatalog'));
    expect(main, contains('await avatarConfig.ensureSelectedDisplayReady()'));
    expect(main, contains('if (!avatarConfig.selectionDisplayCurrent)'));
    expect(main, contains('loadReviewedCatalog: catalog.listApprovedModels'));
  });

  test('startup reconciles the authoritative avatar through one coordinator', () {
    final main = File('lib/main.dart').readAsStringSync();
    final restoreStart = main.indexOf(
      'Future<void> _restorePersistedReviewedAvatar',
    );
    final reconciler = main.indexOf(
      'AvatarSelectionStartupReconciler(',
      restoreStart,
    );
    final catalogLoad = main.indexOf(
      'loadReviewedCatalog: catalog.listApprovedModels',
      reconciler,
    );
    final reconcile = main.indexOf(').reconcile();', catalogLoad);

    expect(
      main,
      matches(
        RegExp(
          r'\.runAccountOperation\(\s*\(\) => _restorePersistedReviewedAvatar\(mount: mount\)',
        ),
      ),
    );
    expect(restoreStart, greaterThanOrEqualTo(0));
    expect(reconciler, greaterThan(restoreStart));
    expect(catalogLoad, greaterThan(reconciler));
    expect(reconcile, greaterThan(catalogLoad));
    final restoreBody = main.substring(restoreStart);
    expect(restoreBody, isNot(contains('config.applyInitial()')));
    expect(restoreBody, contains('catalog.selectionAssetOptions'));
    expect(restoreBody, contains('requireCurrent('));
    expect(restoreBody, contains('mount,'));
  });

  test('agent avatar view is Unity-only and has no legacy web entry', () {
    final view = File(
      'lib/src/core/widgets/agent_avatar_view.dart',
    ).readAsStringSync();
    final runtime = File(
      'lib/src/features/agent/application/avatar/unity_avatar_runtime.dart',
    ).readAsStringSync();
    final unityView = File(
      'lib/src/core/widgets/unity_avatar_view.dart',
    ).readAsStringSync();

    expect(view, contains('UnityAvatarView'));
    expect(view, isNot(contains(retiredWidgetName)));
    expect(view, isNot(contains(retiredBackendName)));
    expect(view, isNot(contains('switch (active.backend.value)')));
    expect(runtime, contains('class UnityAvatarRuntime'));
    expect(
      runtime,
      contains("static const channelName = 'maaso/unity_avatar'"),
    );
    expect(
      runtime,
      contains("static const viewType = 'maaso/unity_avatar_view'"),
    );
    expect(
      runtime,
      matches(RegExp(r'implements\s+(?:[A-Za-z]+,\s+)*AvatarRuntime(?:,|\s)')),
    );
    expect(runtime, contains('AvatarBackendKind.unity'));
    expect(runtime, contains('MissingPluginException'));
    expect(unityView, contains('class UnityAvatarView'));
    expect(unityView, contains('MAASO_ENABLE_UNITY_VIEW'));
    expect(unityView, contains('defaultValue: true'));
    expect(unityView, isNot(contains('AndroidView(')));
    expect(unityView, isNot(contains('PlatformViewHitTestBehavior')));
    expect(unityView, contains('TargetPlatform.android'));
    expect(unityView, contains('TargetPlatform.iOS'));
    expect(unityView, contains('return const SizedBox.expand();'));
    expect(unityView, isNot(contains('UiKitView(')));
    expect(
      unityView,
      contains(
        'case TargetPlatform.android:\n'
        '        return const SizedBox.expand();',
      ),
    );
    expect(
      unityView,
      contains(
        'case TargetPlatform.iOS:\n'
        '        return const SizedBox.expand();',
      ),
    );
  });

  testWidgets('iOS releases its underlay only after the final view leaves', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final runtime = appServices.put(
      UnityAvatarRuntime(channel: channel),
      permanent: true,
    );
    runtime.isReady.value = true;
    Widget views({required bool second, bool firstActive = true}) =>
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              UnityAvatarView(
                key: const ValueKey('first'),
                viewportActive: firstActive,
              ),
              if (second) const UnityAvatarView(key: ValueKey('second')),
            ],
          ),
        );
    try {
      await tester.pumpWidget(views(second: true));
      await tester.pump();
      calls.clear();
      await tester.pumpWidget(views(second: false));
      await tester.pump();
      expect(calls.where((c) => c.method == 'releaseView'), isEmpty);
      await tester.pumpWidget(views(second: false, firstActive: false));
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'releaseView'),
        isEmpty,
        reason: 'A popup can cover Home while still showing its room behind it',
      );
      calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.where((c) => c.method == 'prepareView'), isEmpty);
      await tester.pumpWidget(views(second: false));
      await tester.pump();
      expect(calls.where((c) => c.method == 'prepareView'), isNotEmpty);
      calls.clear();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.where((c) => c.method == 'releaseView'), hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  testWidgets('Unity view prepares after runtime registers late', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    try {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: UnityAvatarView(backgroundColor: Colors.transparent),
        ),
      );
      expect(calls.where((call) => call.method == 'prepareView'), isEmpty);

      appServices.put(UnityAvatarRuntime(channel: channel), permanent: true);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(calls.map((call) => call.method), contains('prepareView'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  testWidgets(
    'resumed Unity view retries until native attachment even with a ready engine',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel(UnityAvatarRuntime.channelName);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      try {
        final runtime = appServices.put(
          UnityAvatarRuntime(channel: channel),
          permanent: true,
        );
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: UnityAvatarView(backgroundColor: Colors.transparent),
          ),
        );
        await tester.pump();
        int prepareCount() =>
            calls.where((call) => call.method == 'prepareView').length;
        final beforeResume = prepareCount();

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 750));
        expect(prepareCount(), greaterThan(beforeResume + 1));

        runtime.isReady.value = true;
        await tester.pump();
        final afterReady = prepareCount();
        await tester.pump(const Duration(seconds: 2));
        expect(prepareCount(), greaterThan(afterReady));
        final presentationId =
            (calls.lastWhere((call) => call.method == 'prepareView').arguments!
                as Map)['presentationId'];
        final attached = const StandardMethodCodec().encodeMethodCall(
          MethodCall('presentationState', {
            'presentationId': presentationId,
            'attached': true,
          }),
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(channel.name, attached, (_) {});
        await tester.pump();
        final afterAttachment = prepareCount();
        await tester.pump(const Duration(seconds: 2));
        expect(runtime.presentationReady.value, isTrue);
        expect(prepareCount(), afterAttachment);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(runtime.presentationReady.value, isFalse);
        expect(prepareCount(), afterAttachment + 1);

        runtime.isReady.value = false;
        await tester.pumpWidget(const SizedBox.shrink());
        final afterDispose = prepareCount();
        await tester.pump(const Duration(seconds: 2));
        expect(prepareCount(), afterDispose);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await appServices.reset();
      }
    },
  );

  testWidgets(
    'missing iOS attachment acknowledgement has a bounded recoverable retry',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel(UnityAvatarRuntime.channelName);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      try {
        final runtime = appServices.put(UnityAvatarRuntime(channel: channel));
        runtime.isReady.value = true;
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: UnityAvatarView(),
          ),
        );
        int prepareCount() =>
            calls.where((call) => call.method == 'prepareView').length;
        for (var tick = 0; tick < 45; tick++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        final exhausted = prepareCount();
        expect(exhausted, greaterThan(2));
        expect(exhausted, lessThan(50));
        expect(runtime.isReady.value, isTrue);
        expect(runtime.presentationReady.value, isFalse);
        await tester.pump(const Duration(minutes: 1));
        expect(prepareCount(), exhausted);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(prepareCount(), greaterThan(exhausted));
        await tester.pumpWidget(const SizedBox.shrink());
        final disposed = prepareCount();
        await tester.pump(const Duration(seconds: 2));
        expect(prepareCount(), disposed);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await appServices.reset();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'native ready reloads the selected nonretired model before it is displayable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel(UnityAvatarRuntime.channelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'loadAvatar') {
          final requestId =
              (call.arguments as Map<Object?, Object?>)['requestId'] as String;
          final data = channel.codec.encodeMethodCall(
            MethodCall('commandResult', {
              'requestId': requestId,
              'method': 'loadAvatar',
              'ok': true,
              'capabilityProfile': <String, Object>{
                'schemaVersion': 1,
                'source': 'unity',
                'state': 'supported',
                'rig': <String, Object>{
                  'humanoid': true,
                  'head': true,
                  'leftEye': true,
                  'rightEye': true,
                },
                'behavior': <String, Object>{
                  'lookAt': true,
                  'lipSync': true,
                  'blink': true,
                  'expressions': true,
                },
                'render': <String, Object>{
                  'renderable': true,
                  'rendererCount': 2,
                  'skinnedMeshCount': 1,
                  'vertexCount': 64000,
                  'triangleCount': 96000,
                  'materialCount': 6,
                  'textureCount': 8,
                  'maxTextureSize': 2048,
                  'estimatedTextureBytes': 25165824,
                },
                'issues': <Object>[],
              },
            }),
          );
          Future<void>.microtask(
            () => messenger.handlePlatformMessage(channel.name, data, (_) {}),
          );
        }
        return null;
      });
      try {
        final runtime = appServices.put(
          UnityAvatarRuntime(channel: channel),
          permanent: true,
        );
        final active = appServices.put(
          ActiveAvatarRuntime()..register(runtime),
        );
        final config = appServices.put(
          AvatarConfigService(
            storageKeyPrefix: 'unity-view-ready-test',
            initialCatalog: [
              ...AvatarConfigService.builtInCatalog,
              AvatarOption(
                id: 'ready-fixture',
                name: 'Ready fixture',
                backend: AvatarBackendKind.unity,
                modelUrl: 'https://cdn.example.com/ready-fixture.bundle',
                config: {
                  'assetName': 'Avatar/ReadyFixture',
                  'approvedAssetSha256': 'a' * 64,
                },
              ),
            ],
            persistSelection: (_, _) async => true,
          ).init(),
        );
        config.selectedId.value = 'ready-fixture';
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: UnityAvatarView(backgroundColor: Colors.transparent),
          ),
        );
        await tester.pump();
        expect(calls.where((call) => call.method == 'loadAvatar'), isEmpty);
        expect(config.selectionDisplayCurrent, isFalse);

        runtime.isReady.value = true;
        await tester.pump();
        await tester.pump();
        final loads = calls
            .where((call) => call.method == 'loadAvatar')
            .toList();
        expect(loads, hasLength(1));
        expect(
          (loads.single.arguments as Map<Object?, Object?>)['modelUrl'],
          'https://cdn.example.com/ready-fixture.bundle',
        );
        expect(
          ((loads.single.arguments as Map<Object?, Object?>)['config']
              as Map<Object?, Object?>)['approvedAssetSha256'],
          'a' * 64,
        );
        expect(config.selectionDisplayCurrent, isTrue);
        expect(active.current, same(runtime));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
        await appServices.reset();
      }
    },
  );

  testWidgets('Unity view sends viewport safe area to native runtime', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    try {
      appServices.put(UnityAvatarRuntime(channel: channel), permanent: true);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: UnityAvatarView(
            backgroundColor: Colors.transparent,
            viewportSafeArea: AvatarViewportSafeArea(top: 0.2, bottom: 0.28),
          ),
        ),
      );
      await tester.pump();

      expect(calls.map((call) => call.method), contains('prepareView'));
      final safeAreaCall = calls.firstWhere(
        (call) => call.method == 'setViewportSafeArea',
      );
      final args = safeAreaCall.arguments as Map<Object?, Object?>;
      expect(args['topSafeViewport'], 0.2);
      expect(args['bottomSafeViewport'], 0.28);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  testWidgets('inactive route cannot overwrite the active Unity viewport', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    try {
      appServices.put(UnityAvatarRuntime(channel: channel), permanent: true);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: UnityAvatarView(
            backgroundColor: Colors.transparent,
            viewportSafeArea: AvatarViewportSafeArea(top: 0.2, bottom: 0.4),
            viewportActive: false,
          ),
        ),
      );
      await tester.pump();

      expect(
        calls.where((call) => call.method == 'setViewportSafeArea'),
        isEmpty,
      );

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: UnityAvatarView(
            backgroundColor: Colors.transparent,
            viewportSafeArea: AvatarViewportSafeArea(top: 0.2, bottom: 0.4),
          ),
        ),
      );
      await tester.pump();

      expect(
        calls.where((call) => call.method == 'setViewportSafeArea'),
        hasLength(1),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  testWidgets('Unity view turns background taps into avatar attention', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    try {
      final runtime = appServices.put(
        UnityAvatarRuntime(channel: channel),
        permanent: true,
      );
      appServices.put(ActiveAvatarRuntime()..register(runtime));
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 100,
            child: UnityAvatarView(backgroundColor: Colors.transparent),
          ),
        ),
      );
      await tester.pump();

      final avatarView = find.byType(UnityAvatarView);
      final topLeft = tester.getTopLeft(avatarView);
      final size = tester.getSize(avatarView);
      await tester.tapAt(
        topLeft + Offset(size.width * 0.75, size.height * 0.4),
      );
      await tester.pump();

      final tapCall = calls.firstWhere(
        (call) => call.method == 'reactToScreenTap',
      );
      final args = tapCall.arguments as Map<Object?, Object?>;
      expect(args['x'], closeTo(0.75, 0.01));
      expect(args['y'], closeTo(0.4, 0.01));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  testWidgets('World tap handler overrides the Home attention reaction', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    Offset? normalizedTap;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    try {
      appServices.put(UnityAvatarRuntime(channel: channel), permanent: true);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 100,
            child: UnityAvatarView(
              backgroundColor: Colors.transparent,
              onScreenTap: (x, y) async => normalizedTap = Offset(x, y),
            ),
          ),
        ),
      );
      await tester.pump();

      final avatarView = find.byType(UnityAvatarView);
      final size = tester.getSize(avatarView);
      await tester.tapAt(
        tester.getTopLeft(avatarView) +
            Offset(size.width * 0.25, size.height * 0.75),
      );
      await tester.pump();

      expect(normalizedTap?.dx, closeTo(0.25, 0.01));
      expect(normalizedTap?.dy, closeTo(0.75, 0.01));
      expect(calls.where((call) => call.method == 'reactToScreenTap'), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      appServices.reset();
    }
  });

  test('Unity runtime logs native bridge prepare availability', () {
    final runtime = File(
      'lib/src/features/agent/application/avatar/unity_avatar_runtime.dart',
    ).readAsStringSync();

    expect(runtime, contains('_debugLog'));
    expect(runtime, contains('prepareView request'));
    expect(runtime, contains('prepareView sent'));
    expect(runtime, contains('native plugin unavailable'));
  });

  testWidgets(
    'model-store gallery cards provide an opaque Material ink boundary',
    (tester) async {
      final page = File(
        'lib/src/features/avatars/presentation/avatars_page.dart',
      ).readAsStringSync();
      expect(page, contains('class _ModelSkinCard'));
      expect(page, contains("'model-store-gallery'"));
      expect(page, contains('selected: isCurrent'));
      for (final brightness in Brightness.values) {
        final controller = AvatarModelStoreController(
          catalog: _BundledOnlyWiringModels(),
          avatars: AvatarConfigService(),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: AvatarsPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey<String>('model-card-agent'));
        expect(card, findsOneWidget);
        final material = tester.widget<Material>(
          find.descendant(of: card, matching: find.byType(Material)).first,
        );
        expect(material.color, AppSecondaryPalette.resolve(brightness).surface);
        expect(material.color!.a, 1);
        expect(material.clipBehavior, Clip.antiAlias);
        expect(material.shape, isA<RoundedRectangleBorder>());
        expect(
          find.descendant(of: card, matching: find.byType(InkWell)),
          findsNWidgets(2),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  test('avatar config startup and failure logs use a safe field allowlist', () {
    final service = File(
      'lib/src/core/services/avatar_config_service.dart',
    ).readAsStringSync();

    expect(service, contains('[AvatarConfig] backend='));
    expect(service, contains('backend='));
    expect(service, contains('remote='));
    expect(service, contains('authority='));
    expect(service, contains(r'failure=${_avatarFailureClass(error)}'));
    expect(service, isNot(contains('[AvatarConfig] selectedId=')));
    expect(service, isNot(contains(r'source=${a.modelSource}')));
    expect(
      RegExp(r'^\s+error:\s*error,\s*$', multiLine: true).hasMatch(service),
      isFalse,
    );
    expect(
      RegExp(
        r'^\s+stackTrace:\s*stackTrace,\s*$',
        multiLine: true,
      ).hasMatch(service),
      isFalse,
    );
    expect(service, isNot(contains('modelUrl=')));
    expect(service, isNot(contains('resourcePath=')));
  });

  test('legacy web avatar renderer is not reachable from active app code', () {
    final main = File('lib/main.dart').readAsStringSync();
    final home = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final view = File(
      'lib/src/core/widgets/agent_avatar_view.dart',
    ).readAsStringSync();

    expect(main, isNot(contains(retiredRuntimeName)));
    expect(home, isNot(contains(retiredBackendName)));
    expect(view, isNot(contains(retiredWidgetName)));
    expect(view, isNot(contains(retiredViewFile)));
  });

  test('legacy web avatar renderer files and bundled assets are absent', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(File('lib/pages/widget/$retiredViewFile').existsSync(), isFalse);
    expect(File('lib/agent/avatar/$retiredRuntimeFile').existsSync(), isFalse);
    expect(Directory(retiredAssetPath).existsSync(), isFalse);
    expect(pubspec, isNot(contains(retiredAssetPath)));
  });

  test('legacy framing yields to camera director and keeps full fallback', () {
    final runtime = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();
    final bridge = File(
      'lib/src/core/services/self_avatar_speech_bridge.dart',
    ).readAsStringSync();

    for (final source in [runtime, bridge]) {
      final start = source.indexOf('void _updateAvatarFraming(');
      final body = source.substring(start, source.indexOf('\n  }', start));
      expect(body, contains("avatar.setFraming('full')"));
      // Admission and the delayed callback must both re-check ownership.
      expect(
        RegExp(
          r'maybeFind<AvatarCameraDirector>\(\)\?\.isActive',
        ).allMatches(body),
        hasLength(2),
      );
      expect(
        body.indexOf('maybeFind<AvatarCameraDirector>'),
        lessThan(body.indexOf("avatar.setFraming('full')")),
      );
    }
  });

  test('camera production wiring follows account and route lifecycle', () {
    final main = File('lib/main.dart').readAsStringSync();
    final actionIds = RegExp(
      r'enforcedReversibleLocalActionIds:\s*const <String>\{([^}]+)\}',
    ).firstMatch(main);
    expect(actionIds, isNotNull);
    expect(
      RegExp(
        "'([^']+)'",
      ).allMatches(actionIds!.group(1)!).map((match) => match.group(1)),
      unorderedEquals([
        'skill_avatarcamera_setframing',
        'local.avatar_camera',
        'creation.intent',
      ]),
    );
    expect(main, isNot(contains('enforcedEligibilities:')));
    final authority = main.indexOf('AvatarProjectionProductionAuthority(');
    final camera = main.indexOf('final avatarCameraDirector = putOwned(');
    final presence = main.indexOf(
      'avatarCameraDirector.bindPresence(presence)',
    );
    expect(authority, greaterThanOrEqualTo(0));
    expect(camera, greaterThan(authority));
    expect(presence, greaterThan(camera));
    expect(
      main.substring(authority, camera),
      contains('cameraFramingIsManaged:'),
    );
    final cameraMount = main.substring(camera, presence);
    expect(
      cameraMount,
      contains('mountIsCurrent: () => storageScopes.isCurrent(mount)'),
    );
    expect(cameraMount, isNot(contains('ownerIsCurrent')));
    final localMountStart = main.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime(',
    );
    final sharedMountStart = main.indexOf(
      'Future<AccountRuntimeLease> _mountAgentExecution(',
    );
    final sharedDrainStart = main.indexOf(
      'Future<void> _drainAgentExecution()',
    );
    expect(authority, greaterThan(localMountStart));
    expect(presence, lessThan(sharedMountStart));
    expect(
      main.substring(sharedMountStart, sharedDrainStart),
      isNot(contains('AvatarCameraDirector(')),
      reason: 'A shared-lease change cannot retire the local camera director.',
    );
    final drain = main.substring(
      main.indexOf('Future<void> _drainAccountRuntimeProducers()'),
    );
    expect(drain, contains("'avatar_camera'"));
    expect(
      drain.indexOf('final avatarCameraDrain ='),
      lessThan(drain.indexOf('final avatarOwnershipDrain =')),
    );
    expect(RegExp(r'\bavatarCameraDrain\b').allMatches(drain), hasLength(3));

    final shell = File('lib/src/app/app_agent_shell.dart').readAsStringSync();
    final bindStart = shell.indexOf('void _bindRouteListener()');
    final bind = shell.substring(bindStart, shell.indexOf('\n  }', bindStart));
    expect(bind, contains('currentRoute: _readCurrentRoute'));
    expect(
      bind.indexOf('maybeFind<AvatarCameraDirector>()'),
      lessThan(bind.indexOf('if (identical(next, _activeRouteListenable))')),
    );
  });
}

class _BundledOnlyWiringModels implements AvatarModelStoreGateway {
  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async => const [];

  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async => const [];

  @override
  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  }) => throw UnimplementedError();
}
