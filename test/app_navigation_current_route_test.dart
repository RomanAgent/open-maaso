import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('unconfigured navigation retains root fallback', () {
    expect(AppNavigation().currentRoute, '/');
  });

  for (final nestedShell in <bool>[false, true]) {
    testWidgets(
      'current route follows actual pushed stack with shell=$nestedShell',
      (tester) async {
        final navigation = AppNavigation();
        final destinations = <RouteBase>[
          GoRoute(
            path: '/agent-space',
            builder: (_, _) => const Scaffold(body: Text('Agent Space')),
            routes: <RouteBase>[
              GoRoute(
                path: 'test-detail/:id',
                builder: (_, _) => const Scaffold(body: Text('Agent')),
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            builder: (_, _) => const Scaffold(body: Text('Settings')),
          ),
        ];
        final router = GoRouter(
          initialLocation: '/home',
          routes: <RouteBase>[
            GoRoute(
              path: '/home',
              builder: (_, _) => const Scaffold(body: Text('Home')),
            ),
            if (nestedShell)
              ShellRoute(builder: (_, _, child) => child, routes: destinations)
            else
              ...destinations,
          ],
        );
        navigation.configure(router);
        try {
          await tester.pumpWidget(MaterialApp.router(routerConfig: router));
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, '/home');

          const personal = '/agent-space?label=sea%20view#window';
          unawaited(navigation.push<void>(personal));
          await tester.pumpAndSettle();
          expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
          expect(
            router.routerDelegate.currentConfiguration.last,
            isA<ImperativeRouteMatch>(),
          );
          expect(navigation.currentRoute, personal);
          expect(find.text('Agent Space'), findsOneWidget);

          unawaited(navigation.push<void>('/settings?section=avatar'));
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, '/settings?section=avatar');
          router.pop();
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, personal);

          unawaited(navigation.replace<void>('/agent-space?label=study'));
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, '/agent-space?label=study');
          router.pop();
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, '/home');

          const detail = '/agent-space/test-detail/mika?from=chat#profile';
          navigation.go(detail);
          await tester.pumpAndSettle();
          expect(navigation.currentRoute, detail);
          expect(find.text('Agent'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          router.dispose();
        }
      },
    );
  }
  for (final outcome in <String>[
    'immediate',
    'wait',
    'reenter',
    'loseOwnership',
    'detach',
    'coldSpace',
  ]) {
    testWidgets('real Mac route and Agent space exit boundary: $outcome', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await appServices.reset();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SpUtils.init();
      final uiControl = AgentUiControlCoordinator();
      final presence =
          appServices.put<AccountSessionLifecycleService>(_MutablePresence())
              as _MutablePresence;
      final exit = outcome == 'immediate' || outcome == 'coldSpace'
          ? null
          : _HoldingAgentSpaceController();
      if (exit != null) appServices.put<AgentSpaceController>(exit);
      const portalChannel = MethodChannel(
        AvatarPortalChannelGateway.channelName,
      );
      final calls = <MethodCall>[];
      _installPortalMock(portalChannel, calls);
      final active = appServices.put(ActiveAvatarRuntime());
      active.register(_ReadyAvatarRuntime());
      appServices.put(AvatarConfigService().init());
      appServices.put(DBService());
      appServices.put(AgentRuntimeRegistry());
      appServices.put(AgentReplyPresentationService());
      appServices.put(DesktopCompanionPreferencesService());
      final controller = DesktopWindowModeController(
        gateway: _IndependentFakeDesktopWindowGateway(),
      );
      final host = _RecordingHostGateway();
      final router = GoRouter(
        initialLocation: outcome == 'coldSpace' ? '/agent-space' : '/home',
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (_, _) => const Scaffold(body: Text('Home chat')),
          ),
          GoRoute(
            path: '/agent-space',
            builder: (_, _) => const UnityAvatarView(includeWorld: true),
          ),
        ],
      );
      appNavigation.configure(router);
      bool? sceneActive;
      try {
        await tester.pumpWidget(
          MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => AppAgentShell(
              coordinator: uiControl,
              desktopWindowModeController: controller,
              desktopCompanionHostGateway: host,
              child: Builder(
                builder: (context) {
                  sceneActive = AvatarPortalScope.of(
                    context,
                  ).sceneSurfaceActive;
                  return child!;
                },
              ),
            ),
          ),
        );
        final initial = await _waitForAcquire(tester, calls);
        await _sendFirstFrame(portalChannel, initial);
        await tester.pumpAndSettle();
        if (outcome == 'coldSpace') {
          expect((initial.arguments as Map)['includeWorld'], isTrue);
          expect(
            calls.where(
              (call) =>
                  call.method == 'acquire' &&
                  (call.arguments as Map)['includeWorld'] != true,
            ),
            isEmpty,
          );
          expect(sceneActive, isTrue);
          expect(find.byType(Texture), findsOneWidget);
          expect(host.calls, isNot(contains('show')));
          return;
        }
        expect(controller.petVisible, isTrue);
        expect(sceneActive, isFalse);
        expect(host.calls, contains('show'));

        calls.clear();
        host.calls.clear();
        unawaited(appNavigation.push<void>('/agent-space'));
        final worldAcquire = await _waitForAcquire(tester, calls);
        await _sendFirstFrame(portalChannel, worldAcquire);
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
        expect(appNavigation.currentRoute, '/agent-space');
        expect(sceneActive, isTrue);
        expect(host.calls, contains('hide'));
        expect(find.byType(Texture), findsOneWidget);
        expect(controller.mode, DesktopWindowMode.app);

        calls.clear();
        host.calls.clear();
        router.pop();
        if (exit != null) {
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 125));
          }
          expect(exit.leaveCalls, greaterThan(0));
          expect(
            calls.where((call) => call.method == 'acquire'),
            isEmpty,
            reason:
                'The complete AgentSpaceController.leave future still holds capture.',
          );
          expect(host.calls, isNot(contains('show')));
          if (outcome == 'reenter') {
            unawaited(appNavigation.push<void>('/agent-space'));
            await tester.pumpAndSettle();
          } else if (outcome == 'loseOwnership') {
            presence.loseOwnership();
            await tester.pump();
          } else if (outcome == 'detach') {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          exit.completed.complete();
          if (outcome != 'wait' && outcome != 'loseOwnership') {
            for (var i = 0; i < 12; i++) {
              await tester.pump();
            }
            expect(
              calls.where(
                (call) =>
                    call.method == 'acquire' &&
                    (call.arguments as Map)['includeWorld'] != true,
              ),
              isEmpty,
              reason: 'Stale queued desktop preparation cannot capture.',
            );
            expect(host.calls, isNot(contains('show')));
            if (outcome == 'reenter') {
              expect(appNavigation.currentRoute, '/agent-space');
              expect(find.byType(Texture), findsOneWidget);
            }
            return;
          }
          if (outcome == 'loseOwnership') {
            // Execution ownership may move while the mounted account keeps
            // its local desktop avatar. Agent space exit must still complete first.
            expect(presence.canPresentAvatar, isFalse);
            expect(presence.isMounted, isTrue);
          }
        }
        final petAcquire = await _waitForAcquire(tester, calls);
        await _sendFirstFrame(portalChannel, petAcquire);
        await tester.pumpAndSettle();
        expect(appNavigation.currentRoute, '/home');
        expect(sceneActive, isFalse);
        expect(host.calls, contains('show'));
        expect(find.byType(Texture), findsNothing);
        expect(find.text('Home chat'), findsOneWidget);
        expect(controller.mode, DesktopWindowMode.app);
      } finally {
        if (exit != null && !exit.completed.isCompleted) {
          exit.completed.complete();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        router.dispose();
        controller.dispose();
        await uiControl.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(portalChannel, null);
        await appServices.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

void _installPortalMock(
  MethodChannel portalChannel,
  List<MethodCall> calls, {
  Future<void> Function()? onSuspend,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(portalChannel, (call) async {
        calls.add(call);
        if (call.method == 'acquire') {
          final arguments = call.arguments as Map<Object?, Object?>;
          final desktopHigh =
              arguments['profile'] == AvatarPortalProfile.desktopHigh.wireName;
          return <String, Object>{
            'textureId': 91,
            'width':
                arguments['viewportWidth'] as int? ??
                (desktopHigh ? 1024 : 320),
            'height':
                arguments['viewportHeight'] as int? ??
                (desktopHigh ? 1792 : 560),
            'generation': arguments['generation']! as int,
          };
        }
        if (call.method == 'suspend' && onSuspend != null) {
          await onSuspend();
        }
        return null;
      });
}

Future<MethodCall> _waitForAcquire(
  WidgetTester tester,
  List<MethodCall> calls,
) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    await tester.pump();
    if (calls.any((call) => call.method == 'acquire')) break;
  }
  return calls.lastWhere((call) => call.method == 'acquire');
}

Future<void> _sendFirstFrame(
  MethodChannel portalChannel,
  MethodCall acquire,
) async {
  final arguments = acquire.arguments as Map<Object?, Object?>;
  final generation = arguments['generation']! as int;
  final desktopHigh =
      arguments['profile'] == AvatarPortalProfile.desktopHigh.wireName;
  await _sendNativeCall(
    portalChannel,
    MethodCall('event', <String, Object>{
      'type': 'firstFrame',
      'generation': generation,
      'textureId': 91,
      'width': arguments['viewportWidth'] as int? ?? (desktopHigh ? 1024 : 320),
      'height':
          arguments['viewportHeight'] as int? ?? (desktopHigh ? 1792 : 560),
    }),
  );
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}

class _ReadyAvatarRuntime extends AvatarRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _IndependentFakeDesktopWindowGateway
    implements DesktopWindowGateway, IndependentDesktopPetWindowGateway {
  @override
  bool get isSupported => true;
  @override
  bool get supportsIndependentPetWindow => true;
  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);
  @override
  Future<void> enterPetMode() async {}
  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}
  @override
  Future<void> startDragging() async {}
}

class _RecordingHostGateway implements DesktopCompanionHostGateway {
  final calls = <String>[];
  @override
  bool get isSupported => true;
  @override
  Future<void> show({required int interactionGeneration}) async =>
      calls.add('show');
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _HoldingAgentSpaceController extends AgentSpaceController {
  _HoldingAgentSpaceController() : super(avatar: ActiveAvatarRuntime());
  final completed = Completer<void>();
  var leaveCalls = 0;
  @override
  Future<void> leave({
    bool animated = false,
    AvatarViewportSafeArea? homeViewportSafeArea,
  }) {
    leaveCalls++;
    return completed.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MutablePresence extends AppService
    implements AccountSessionLifecycleService {
  final _changes = ChangeNotifier();
  var here = true;
  @override
  final phase = AccountSessionLifecyclePhase.mounted.obs;
  @override
  bool get canPresentAvatar => here;
  @override
  bool get canExecuteAgent => here;
  @override
  bool get isMounted => true;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.off;
  @override
  int get generation => 1;
  @override
  AccountDeviceLeaseReceipt? get activeDeviceLease => null;
  @override
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {}

  void loseOwnership() {
    here = false;
    phase.value = AccountSessionLifecyclePhase.leaseConflict;
    _changes.notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);
  @override
  void onClose() {
    _changes.dispose();
    super.onClose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
