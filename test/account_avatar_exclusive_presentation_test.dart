import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/auth/presentation/account_standby_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AgentUiControlCoordinator uiControl;
  late _PresentationLifecycle lifecycle;

  setUp(() async {
    await appServices.reset();
    uiControl = AgentUiControlCoordinator();
    lifecycle = _PresentationLifecycle();
    appServices.put<AccountSessionLifecycleService>(lifecycle);
  });

  tearDown(() async {
    await uiControl.dispose();
    await appServices.reset();
  });

  Future<void> mountShell(WidgetTester tester) async {
    appServices.put(DBService());
    appServices.put(AgentRuntimeRegistry());
    appServices.put(AgentReplyPresentationService());
    await tester.pumpWidget(
      MaterialApp(
        home: AppAgentShell(
          coordinator: uiControl,
          currentRoute: () => '/home',
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pump();
  }

  bool petAvailable(WidgetTester tester) => tester
      .widget<DesktopCompanionShell>(find.byType(DesktopCompanionShell))
      .petAvailable;

  for (final ownsExecution in [false, true]) {
    testWidgets(
      'mounted ${ownsExecution ? 'owner' : 'companion'} device can display its avatar',
      (tester) async {
        lifecycle.setMounted(true);
        lifecycle.setAuthority(ownsExecution);
        await mountShell(tester);
        expect(petAvailable(tester), isTrue);
        expect(lifecycle.canExecuteAgent, ownsExecution);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(lifecycle.listenerCount, 0);
      },
    );
  }

  testWidgets('executor changes keep the mounted desktop pet available', (
    tester,
  ) async {
    lifecycle.setMounted(true);
    lifecycle.setAuthority(true);
    await mountShell(tester);
    expect(petAvailable(tester), isTrue);
    expect(lifecycle.listenerCount, greaterThan(0));
    lifecycle.setAuthority(false);
    await tester.pump();
    expect(appServices.isRegistered<DBService>(), isTrue);
    expect(appServices.isRegistered<AgentRuntimeRegistry>(), isTrue);
    expect(lifecycle.canExecuteAgent, isFalse);
    expect(petAvailable(tester), isTrue);
    lifecycle.setAuthority(true);
    await tester.pump();
    expect(petAvailable(tester), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(lifecycle.listenerCount, 0);
  });

  testWidgets(
    'account retirement hides the pet before retained services close',
    (tester) async {
      lifecycle.setMounted(true);
      await mountShell(tester);
      expect(petAvailable(tester), isTrue);
      lifecycle.setMounted(false);
      await tester.pump();
      expect(appServices.isRegistered<DBService>(), isTrue);
      expect(appServices.isRegistered<AgentRuntimeRegistry>(), isTrue);
      expect(petAvailable(tester), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(lifecycle.listenerCount, 0);
    },
  );

  testWidgets('retained services cannot reveal an unmounted account avatar', (
    tester,
  ) async {
    lifecycle.setAuthority(true);
    await mountShell(tester);
    expect(petAvailable(tester), isFalse);
    lifecycle.setMounted(true);
    await tester.pump();
    expect(petAvailable(tester), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('standby occludes a prewarmed actor under a transparent theme', (
    tester,
  ) async {
    final theme = ThemeData().copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.orange,
      ).copyWith(surface: const Color(0x40FFF6EE)),
    );
    await tester.pumpWidget(
      MaterialApp(theme: theme, home: const AccountStandbyPage()),
    );
    expect(find.text('Your Agent is active elsewhere'), findsOneWidget);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      const Color(0xFFFFF6EE),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

/// Presentation tests keep storage registered while authority changes. The
/// real two-device lease/CAS behavior is tested by lifecycle integration tests.
class _PresentationLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final _changes = ChangeNotifier();
  var listenerCount = 0;
  var _ownsExecution = false;
  var _mounted = false;

  @override
  final phase = AccountSessionLifecyclePhase.leaseConflict.obs;
  @override
  AccountDeviceLeaseConflict? get leaseConflict => null;
  @override
  bool get usesExclusiveDeviceLease => true;
  @override
  AccountRuntimeAuthorityMode get effectiveAuthorityMode =>
      AccountRuntimeAuthorityMode.off;
  @override
  bool get canPresentAvatar => isMounted;
  @override
  bool get canExecuteAgent => _mounted && _ownsExecution;
  @override
  bool get isMounted => _mounted;
  @override
  bool get presenceRecoveryInProgress => false;

  // This fixture controls lease ownership directly; shell lifecycle events
  // are covered separately by app_agent_shell_presence_lifecycle_test.dart.
  @override
  void updateApplicationPresence({
    required bool foreground,
    bool handoffInProgress = false,
  }) {}

  void setAuthority(bool allowed) {
    _ownsExecution = allowed;
    _changes.notifyListeners();
  }

  void setMounted(bool mounted) {
    _mounted = mounted;
    phase.value = mounted
        ? AccountSessionLifecyclePhase.mounted
        : AccountSessionLifecyclePhase.retiring;
    _changes.notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    _changes.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    _changes.removeListener(listener);
  }

  @override
  void onClose() {
    _changes.dispose();
    super.onClose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
