import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingLifecycle lifecycle;
  late AgentUiControlCoordinator uiControl;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    lifecycle = _RecordingLifecycle();
    appServices.put<AccountSessionLifecycleService>(lifecycle);
    uiControl = AgentUiControlCoordinator();
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  tearDown(() async {
    await uiControl.dispose();
    await appServices.reset();
  });

  Future<void> mountShell(WidgetTester tester, {required bool desktop}) async {
    final window = DesktopWindowModeController(
      gateway: desktop
          ? _IndependentWindow()
          : const UnsupportedDesktopWindowGateway(),
    );
    addTearDown(window.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppAgentShell(
          coordinator: uiControl,
          desktopWindowModeController: window,
          desktopCompanionHostGateway:
              const UnsupportedDesktopCompanionHostGateway(),
          currentRoute: () => '/home',
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'phone suspension stops recovery and resume re-enables it without remount',
    (tester) async {
      await mountShell(tester, desktop: false);
      expect(lifecycle.calls.last, (foreground: true, handoff: false));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(lifecycle.calls.last, (
          foreground: false,
          handoff: false,
        ), reason: state.name);
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(lifecycle.calls.last, (foreground: true, handoff: false));
      expect(find.byType(AppAgentShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(lifecycle.calls.last, (foreground: false, handoff: false));
    },
  );

  testWidgets(
    'independent desktop pet stays eligible while chat window is inactive or hidden',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await mountShell(tester, desktop: true);
        expect(lifecycle.calls.last, (foreground: true, handoff: false));
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
          expect(lifecycle.calls.last, (
            foreground: true,
            handoff: false,
          ), reason: state.name);
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.detached,
        );
        await tester.pump();
        expect(lifecycle.calls.last, (foreground: false, handoff: false));
        // Detached disables frame delivery; resume before unmounting so this
        // assertion observes dispose rather than the preceding detached event.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(lifecycle.calls.last, (foreground: true, handoff: false));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(lifecycle.calls.last, (foreground: false, handoff: false));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('an active handoff reaches the lifecycle recovery guard', (
    tester,
  ) async {
    final bridge = _PreparingBridge();
    final handoff = AgentHandoffService(
      authority: _AdmittedAuthority(),
      gateway: _UnusedHandoffGateway(),
      bridge: bridge,
      accountContext: () => const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'presence-test-account',
        presenceSessionId: 'source-presence',
      ),
      serializeAuthority: <T>(Future<T> Function() work) => work(),
    );
    appServices.put<AgentHandoffService>(handoff);
    await mountShell(tester, desktop: false);
    expect(lifecycle.calls.last.handoff, isFalse);
    final request = handoff
        .request('target-presence')
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await tester.pump();
    expect(handoff.isBusy, isTrue);
    expect(lifecycle.calls.last, (foreground: true, handoff: true));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(lifecycle.calls.last, (foreground: false, handoff: true));
    // Hidden disables frame delivery. Keep the mounted shell alive through
    // resume and failure so both recovery-guard updates are actually observed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(lifecycle.calls.last, (foreground: true, handoff: true));
    bridge.avatar.completeError(
      StateError('test request cancelled before network dispatch'),
    );
    await request;
    await tester.pump();
    expect(handoff.isBusy, isFalse);
    expect(lifecycle.calls.last, (foreground: true, handoff: false));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(lifecycle.calls.last, (foreground: false, handoff: false));
    handoff.dispose();
  });
}

class _RecordingLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final calls = <({bool foreground, bool handoff})>[];
  final _changes = ChangeNotifier();
  @override
  final phase = AccountSessionLifecyclePhase.leaseConflict.obs;
  @override
  bool get canExecuteAgent => false;
  @override
  bool get isMounted => true;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.off;
  @override
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {
    calls.add((foreground: foreground, handoff: handoffInProgress));
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

class _IndependentWindow
    implements DesktopWindowGateway, IndependentDesktopPetWindowGateway {
  @override
  bool get isSupported => true;
  @override
  bool get supportsIndependentPetWindow => true;
  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 0, top: 0, width: 900, height: 700);
  @override
  Future<void> enterPetMode() async {}
  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}
  @override
  Future<void> startDragging() async {}
}

class _AdmittedAuthority implements AccountDeviceLeaseCoordinator {
  @override
  bool get canAdmitMutations => true;
  @override
  final currentPresence = AccountDevicePresenceReceipt(
    agentId: 'presence-test-agent',
    installationId: 'presence-test-installation',
    runtimeInstanceId: 'presence-test-runtime',
    presenceSessionId: 'source-presence',
    generation: 1,
    deviceLabel: 'Source phone',
    platform: 'ios',
    appVersion: '1.0.0',
    openedAt: DateTime.utc(2026, 9, 12),
    lastSeenAt: DateTime.utc(2026, 9, 12),
    expiresAt: DateTime.utc(2026, 9, 12, 0, 1),
    remainingTtl: const Duration(minutes: 1),
    renewAfter: const Duration(seconds: 20),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected authority call: ${invocation.memberName}');
}

class _PreparingBridge implements AgentHandoffRuntimeBridge {
  final avatar = Completer<HandoffAvatarIdentity>();
  @override
  bool get isAvailable => true;
  @override
  Future<HandoffAvatarIdentity> currentAvatar() => avatar.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected handoff bridge call: ${invocation.memberName}',
  );
}

class _UnusedHandoffGateway implements AccountDeviceHandoffGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected network call: ${invocation.memberName}');
}
