import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/widgets/agent_loading_card.dart';
import 'package:maaso/src/core/widgets/ui/app_card.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';
import 'package:maaso/src/features/auth/presentation/account_standby_page.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets('optional model failure never opens a startup Retry card', (
    tester,
  ) async {
    final boot = appServices.put(
      AgentBootController(fallbackStop: () async {}),
    );
    boot.modelFailed.value = true;
    boot.modelError.value = 'Optional model is unavailable';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AgentLoadingCards())),
    );

    expect(find.byType(AppCard), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Optional model is unavailable'), findsNothing);
    // Startup presentation does not clear the underlying failure evidence.
    expect(boot.modelFailed.value, isTrue);

    boot.modelFailed.value = false;
    await tester.pump();
    boot.modelFailed.value = true;
    await tester.pump();
    expect(find.byType(AppCard), findsNothing);
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an active model download keeps progress without a failure card',
    (tester) async {
      final boot = appServices.put(
        AgentBootController(fallbackStop: () async {}),
      );
      boot.modelLoading.value = true;
      boot.modelProgress.value = 0.25;
      boot.modelReceivedBytes.value = 1024;
      boot.modelTotalBytes.value = 4096;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AgentLoadingCards())),
      );
      expect(find.byType(AppCard), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.25,
      );

      boot.modelFailed.value = true;
      boot.modelError.value = 'Download failed';
      boot.modelLoading.value = false;
      await tester.pump();
      expect(find.byType(AppCard), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(boot.modelError.value, 'Download failed');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('every transitional standby phase uses inline loading', (
    tester,
  ) async {
    final lifecycle =
        appServices.put<AccountSessionLifecycleService>(_StandbyLifecycle())
            as _StandbyLifecycle;
    final theme = ThemeData().copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.orange,
      ).copyWith(surface: const Color(0x40FFF6EE)),
    );
    await tester.pumpWidget(
      MaterialApp(theme: theme, home: const AccountStandbyPage()),
    );

    for (final phase in AccountSessionLifecyclePhase.values.where(
      (phase) => !{
        AccountSessionLifecyclePhase.authenticatedStandby,
        AccountSessionLifecyclePhase.leaseConflict,
        AccountSessionLifecyclePhase.verificationRequired,
        AccountSessionLifecyclePhase.faulted,
      }.contains(phase),
    )) {
      lifecycle.setPhase(phase);
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: phase.name,
      );
      expect(find.byType(Card), findsNothing, reason: phase.name);
      expect(find.byType(Dialog), findsNothing, reason: phase.name);
      expect(find.text('Retry'), findsNothing, reason: phase.name);
      expect(find.text('Sign out'), findsNothing, reason: phase.name);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        const Color(0xFFFFF6EE),
        reason: phase.name,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final phase in [
    AccountSessionLifecyclePhase.authenticatedStandby,
    AccountSessionLifecyclePhase.leaseConflict,
    AccountSessionLifecyclePhase.verificationRequired,
    AccountSessionLifecyclePhase.faulted,
  ]) {
    testWidgets('${phase.name} keeps actionable recovery after transition', (
      tester,
    ) async {
      final lifecycle = _StandbyLifecycle()..setPhase(phase);
      appServices.put<AccountSessionLifecycleService>(lifecycle);
      await tester.pumpWidget(const MaterialApp(home: AccountStandbyPage()));
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);

      // Automatic recovery can notify without changing the phase first.
      lifecycle.setRecovering(true);
      await tester.pump();
      expect(lifecycle.phase.value, phase);
      expect(find.byType(Card), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      lifecycle.setRecovering(false);
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
      final pending = Completer<void>();
      lifecycle.mountWaiter = pending.future;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(lifecycle.mountCalls, 1);
      expect(
        lifecycle.cleanupCalls,
        phase == AccountSessionLifecyclePhase.faulted ? 1 : 0,
      );
      expect(find.text('Retry'), findsNothing);
      expect(find.byType(Card), findsNothing);

      pending.complete();
      await tester.pump();
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.mounted);
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

/// Only presentation transitions are simulated here; the real cleanup and
/// cross-device recovery operations retain their lifecycle integration tests.
class _StandbyLifecycle extends AppService
    implements AccountSessionLifecycleService {
  final _changes = ChangeNotifier();
  var _recovering = false;
  var mountCalls = 0;
  var cleanupCalls = 0;
  Future<void>? mountWaiter;

  @override
  final phase = AccountSessionLifecyclePhase.restoring.obs;
  @override
  AccountDeviceLeaseConflict? get leaseConflict => null;
  @override
  bool get presenceRecoveryInProgress => _recovering;
  @override
  bool get isFaulted => phase.value == AccountSessionLifecyclePhase.faulted;

  void setPhase(AccountSessionLifecyclePhase next) {
    phase.value = next;
    _changes.notifyListeners();
  }

  void setRecovering(bool recovering) {
    _recovering = recovering;
    _changes.notifyListeners();
  }

  @override
  Future<void> retryFaultedCleanup() async {
    cleanupCalls++;
  }

  @override
  Future<bool> mountCurrentSession() async {
    mountCalls++;
    await mountWaiter;
    setPhase(AccountSessionLifecyclePhase.mounted);
    return true;
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
