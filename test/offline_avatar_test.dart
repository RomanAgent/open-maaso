import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/offline/offline_avatar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() async {
    await appServices.reset();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'installation is lightweight; only an explicit view load starts Unity',
    () async {
      final transport = _Transport();
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.android,
        isWeb: false,
      );
      await controller.install();
      expect(transport.calls, isEmpty);
      expect(controller.ready, isFalse);
      expect(
        appServices.find<ActiveAvatarRuntime>().current,
        same(controller.runtime),
      );
      expect(await controller.load(), isTrue);
      final loads = transport.calls
          .where((c) => c.method == 'loadAvatar')
          .toList();
      expect(loads, hasLength(1));
      expect(
        (loads.single.arguments as Map)['modelUrl'],
        OfflineAvatarController.bundledModelUri,
      );
      final config = (loads.single.arguments as Map)['config'] as Map;
      expect(config['assetName'], 'OpenMaaso');
      expect(config.keys, isNot(contains('approvedRemoteUrl')));
      expect(controller.ready, isTrue);
      await controller.close();
      expect(appServices.isRegistered<UnityAvatarRuntime>(), isFalse);
      expect(appServices.isRegistered<ActiveAvatarRuntime>(), isFalse);
      final commandsAfterClose = transport.calls.length;
      await controller.speechStarted();
      await controller.speechProgress();
      await controller.speechEnded();
      expect(transport.calls.length, commandsAfterClose);
    },
  );

  test(
    'a late bundled-load receipt cannot reveal a hidden or logged-out Home',
    () async {
      final transport = _Transport()..acknowledgeLoads = false;
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.android,
        isWeb: false,
      );
      await controller.install();
      final load = controller.load();
      await transport.loadEntered.future;
      await controller.setVisible(false);
      await transport.acknowledgeLastLoad();
      expect(await load, isFalse);
      expect(controller.ready, isFalse);
      expect(
        transport.calls
            .where((c) => c.method == 'setLocalAvatarVisible')
            .any((c) => (c.arguments as Map)['visible'] == true),
        isFalse,
      );
      await controller.close();
    },
  );

  test(
    'iOS visibility requires the matched native presentation receipt',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = _Transport()..attachPresentation = false;
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.iOS,
        isWeb: false,
        readyTimeout: const Duration(milliseconds: 250),
      );
      await controller.install();
      final load = controller.load();
      await transport.loadEntered.future;
      expect(controller.ready, isFalse);
      await transport.emit(
        const MethodCall('presentationState', {
          'presentationId': 'old',
          'attached': true,
        }),
      );
      expect(controller.ready, isFalse);
      await transport.emit(
        MethodCall('presentationState', {
          'presentationId': transport.presentationId,
          'attached': true,
        }),
      );
      expect(await load, isTrue);
      expect(controller.ready, isTrue);
      await controller.close();
    },
  );

  test(
    'missing player finishes with an honest bounded unavailable state',
    () async {
      final transport = _Transport()..announceReady = false;
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.android,
        isWeb: false,
        readyTimeout: const Duration(milliseconds: 20),
      );
      await controller.install();
      expect(await controller.load(), isFalse);
      expect(controller.loading, isFalse);
      expect(controller.ready, isFalse);
      expect(controller.error, contains('Unity'));
      expect(transport.calls.where((c) => c.method == 'loadAvatar'), isEmpty);
      await controller.close();
    },
  );

  test(
    'speech owns bounded mouth cues and closes them on stop or hide',
    () async {
      final transport = _Transport();
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.android,
        isWeb: false,
      );
      await controller.install();
      await controller.load();
      await controller.speechProgress();
      expect(transport.calls.where((c) => c.method == 'setMouthOpen'), isEmpty);
      await controller.speechStarted();
      await controller.speechProgress();
      expect(
        (transport.calls.lastWhere((c) => c.method == 'setMouthOpen').arguments
            as Map)['value'],
        0.32,
      );
      await controller.speechEnded();
      expect(
        (transport.calls.lastWhere((c) => c.method == 'setMouthOpen').arguments
            as Map)['value'],
        0,
      );
      await controller.setVisible(false);
      final count = transport.calls
          .where((c) => c.method == 'setMouthOpen')
          .length;
      await controller.speechProgress();
      expect(
        transport.calls.where((c) => c.method == 'setMouthOpen').length,
        count,
      );
      await controller.close();
    },
  );

  test('web never installs or starts another avatar backend', () async {
    final transport = _Transport();
    final controller = OfflineAvatarController(
      unity: UnityAvatarRuntime(transport: transport),
      platform: TargetPlatform.android,
      isWeb: true,
    );
    await controller.install();
    expect(await controller.load(), isFalse);
    expect(appServices.isRegistered<UnityAvatarRuntime>(), isFalse);
    expect(transport.calls, isEmpty);
    await controller.close();
  });

  testWidgets(
    'full-body static preview stays until the matching model is ready',
    (tester) async {
      final transport = _Transport()..acknowledgeLoads = false;
      final controller = OfflineAvatarController(
        unity: UnityAvatarRuntime(transport: transport),
        platform: TargetPlatform.android,
        isWeb: false,
      );
      await controller.install();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [offlineAvatarRouteObserver],
          home: Scaffold(body: OfflineAvatarView(controller: controller)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.ready, isFalse);
      final poster = tester.widget<Image>(
        find.byKey(const Key('offline-avatar-poster')),
      );
      expect(poster.fit, BoxFit.contain);
      expect(
        (poster.image as AssetImage).assetName,
        'assets/brand/offline_avatar_preview.png',
      );
      expect(find.textContaining('静态预览'), findsOneWidget);
      await transport.acknowledgeLastLoad();
      await tester.pumpAndSettle();
      expect(controller.ready, isTrue);
      expect(find.byKey(const Key('offline-avatar-poster')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await controller.close();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('missing player keeps an honest full-body static fallback', (
    tester,
  ) async {
    final controller = OfflineAvatarController(
      platform: TargetPlatform.linux,
      isWeb: false,
    );
    await controller.install();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OfflineAvatarView(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.ready, isFalse);
    expect(controller.supported, isFalse);
    expect(find.byKey(const Key('offline-avatar-poster')), findsOneWidget);
    expect(find.textContaining('静态预览'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await controller.close();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('covering Home hides the underlay and returning restores it', (
    tester,
  ) async {
    final transport = _Transport();
    final controller = OfflineAvatarController(
      unity: UnityAvatarRuntime(transport: transport),
      platform: TargetPlatform.android,
      isWeb: false,
    );
    await controller.install();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [offlineAvatarRouteObserver],
        home: Scaffold(
          body: Stack(
            children: [
              OfflineAvatarView(controller: controller),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('settings')),
                    ),
                  ),
                  child: const Text('open settings'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.ready, isTrue);
    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();
    expect(controller.ready, isFalse);
    expect(
      (transport.calls
              .lastWhere((c) => c.method == 'setLocalAvatarVisible')
              .arguments
          as Map)['visible'],
      isFalse,
    );
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(controller.ready, isTrue);
    await tester.pumpWidget(const SizedBox());
    await controller.close();
    debugDefaultTargetPlatformOverride = null;
  });
}

class _Transport implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? handler;
  bool announceReady = true;
  bool attachPresentation = true;
  bool acknowledgeLoads = true;
  final loadEntered = Completer<void>();
  Map? lastLoad;
  String? presentationId;

  Future<dynamic> emit(MethodCall call) async => handler?.call(call);

  Future<void> acknowledgeLastLoad() async {
    await emit(
      MethodCall('commandResult', {
        'method': 'loadAvatar',
        'requestId': lastLoad!['requestId'],
        'ok': true,
      }),
    );
  }

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == 'prepareView') {
      if (arguments is Map) {
        presentationId = arguments['presentationId'] as String?;
      }
      if (announceReady) await emit(const MethodCall('ready'));
      if (attachPresentation && presentationId != null) {
        await emit(
          MethodCall('presentationState', {
            'presentationId': presentationId,
            'attached': true,
          }),
        );
      }
    }
    if (method == 'loadAvatar') {
      lastLoad = arguments as Map;
      if (!loadEntered.isCompleted) loadEntered.complete();
      if (acknowledgeLoads) await acknowledgeLastLoad();
    }
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? next) =>
      handler = next;
  @override
  void dispose() => handler = null;
}
