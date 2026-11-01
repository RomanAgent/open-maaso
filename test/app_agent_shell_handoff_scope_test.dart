import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  late AgentUiControlCoordinator uiControl;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    uiControl = AgentUiControlCoordinator();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_Fixture.portalChannel, null);
    debugDefaultTargetPlatformOverride = null;
    fixture.window.dispose();
    await fixture.uiControl.dispose();
    await appServices.reset();
  });

  testWidgets(
    'execution adoption preserves the desktop pet and shared voice controller',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      fixture = _Fixture(uiControl);
      fixture.register();
      try {
        await fixture.mount(tester);
        expect(find.byType(CompanionSessionScope), findsOneWidget);
        expect(fixture.host.calls, contains('show'));
        final state = tester.state(find.byType(DesktopCompanionShell));
        final voice = tester
            .widget<CompanionSessionScope>(find.byType(CompanionSessionScope))
            .voice;
        fixture.host.calls.clear();

        for (final ownsExecution in [true, false, true]) {
          fixture.lifecycle.setOwner(ownsExecution);
          await fixture.pumpFrames(tester);
          expect(find.byType(CompanionSessionScope), findsOneWidget);
          expect(
            tester
                .widget<CompanionSessionScope>(
                  find.byType(CompanionSessionScope),
                )
                .voice,
            same(voice),
          );
          expect(tester.state(find.byType(DesktopCompanionShell)), same(state));
          expect(fixture.window.petVisible, isTrue);
          expect(fixture.host.calls, isEmpty);
          expect(fixture.lifecycle.canExecuteAgent, ownsExecution);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('a new account mount retires the old desktop shell', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    fixture = _Fixture(uiControl);
    fixture.register();
    try {
      await fixture.mount(tester);
      final state = tester.state(find.byType(DesktopCompanionShell));
      final oldMount = fixture.scopes.activeMount!;
      fixture.scopes.unmount(oldMount);
      fixture.scopes.mount(
        AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'next-account',
        ),
      );
      fixture.lifecycle.setOwner(false);
      await fixture.pumpFrames(tester);
      expect(state.mounted, isFalse);
      expect(
        tester.state(find.byType(DesktopCompanionShell)),
        isNot(same(state)),
      );
      expect(fixture.host.calls, contains('dispose'));
      expect(fixture.host.calls, isNot(contains('enter')));
      expect(fixture.host.calls, isNot(contains('prepare')));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

class _Fixture {
  _Fixture(this.uiControl);
  static const portalChannel = MethodChannel(
    AvatarPortalChannelGateway.channelName,
  );
  final lifecycle = _OwnerLifecycle();
  final scopes = AccountStorageScopeService();
  final AgentUiControlCoordinator uiControl;
  final host = _Host();
  final window = DesktopWindowModeController(gateway: _Window());
  final acquisitions = <Map<Object?, Object?>>[];
  int framesSent = 0;

  void register() {
    scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'same-account'),
    );
    appServices.put(scopes);
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    appServices.put(DBService());
    appServices.put(AgentRuntimeRegistry());
    appServices.put(AgentReplyPresentationService());
    appServices.put<AvatarConfigService>(_AvatarConfig());
    appServices.put(ActiveAvatarRuntime()).register(_ReadyAvatar());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(portalChannel, (call) async {
          if (call.method != 'acquire') return null;
          final args = call.arguments as Map<Object?, Object?>;
          acquisitions.add(args);
          return <String, Object>{
            'textureId': 91,
            'width': args['viewportWidth'] as int? ?? 1024,
            'height': args['viewportHeight'] as int? ?? 1792,
            'generation': args['generation']! as int,
          };
        });
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppAgentShell(
          coordinator: uiControl,
          desktopWindowModeController: window,
          desktopCompanionHostGateway: host,
          currentRoute: () => '/home',
          child: const SizedBox.expand(),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump();
      while (framesSent < acquisitions.length) {
        final args = acquisitions[framesSent++];
        final data = portalChannel.codec.encodeMethodCall(
          MethodCall('event', <String, Object>{
            'type': 'firstFrame',
            'textureId': 91,
            'generation': args['generation']! as int,
            'width': args['viewportWidth'] as int? ?? 1024,
            'height': args['viewportHeight'] as int? ?? 1792,
          }),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(portalChannel.name, data, (_) {});
      }
    }
  }
}

class _OwnerLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final _changes = ChangeNotifier();
  bool _owner = false;
  @override
  final phase = AccountSessionLifecyclePhase.mounted.obs;
  void setOwner(bool value) {
    _owner = value;
    _changes.notifyListeners();
  }

  @override
  bool get canExecuteAgent => _owner;
  @override
  bool get isMounted => true;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.shadow;
  @override
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {}
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

class _AvatarConfig extends AvatarConfigService {
  @override
  Future<void> applyInitial() async {}
}

class _ReadyAvatar extends AvatarRuntime {
  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Host implements DesktopCompanionHostGateway {
  final calls = <String>[];
  @override
  bool get isSupported => true;
  @override
  Future<void> show({required int interactionGeneration}) async =>
      calls.add('show');
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  Future<void> dispose() async => calls.add('dispose');
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Window
    implements DesktopWindowGateway, IndependentDesktopPetWindowGateway {
  @override
  bool get isSupported => true;
  @override
  bool get supportsIndependentPetWindow => true;
  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 10, top: 10, width: 1000, height: 700);
  @override
  Future<void> enterPetMode() async {}
  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}
  @override
  Future<void> startDragging() async {}
}
