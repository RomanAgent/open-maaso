import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_host.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/presentation/action/material_action_approval_host.dart';

const _approvalTitle = 'Authorize exact publication';
const _exactText =
    'Ship exactly this message:\nHello @team — release 42 is ready.';

void main() {
  group('AppAgentShell approval takeover boundary', () {
    late AgentUiControlCoordinator coordinator;

    setUp(() {
      coordinator = AgentUiControlCoordinator();
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    testWidgets(
      'production builder hierarchy blocks page input and grants Allow once',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final navigatorKey = GlobalKey<NavigatorState>();
        final host = MaterialActionApprovalHost(navigatorKey: navigatorKey);
        var pageTaps = 0;

        await _pumpShell(
          tester,
          coordinator: coordinator,
          navigatorKey: navigatorKey,
          onPageTap: () => pageTaps += 1,
        );
        final lease = _beginWaitingLease(coordinator);
        final session = host.present(_prompt());
        final decision = _applyDecisionToLease(
          session: session,
          coordinator: coordinator,
          lease: lease,
        );
        var decisionSettled = false;
        session.decision.then<void>((_) => decisionSettled = true);
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(_approvalTitle), findsOneWidget);
        expect(find.text(_exactText), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          _exactText,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.namesRoute == true &&
                widget.properties.scopesRoute == true &&
                widget.properties.label == _approvalTitle,
          ),
          findsOneWidget,
        );

        final rejectButton = find.widgetWithText(OutlinedButton, 'Reject');
        final allowButton = find.widgetWithText(FilledButton, 'Allow once');
        expect(tester.getSize(rejectButton).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(allowButton).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(allowButton),
          matchesSemantics(
            label: 'Allow once',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
        final pageButton = find.byKey(
          const ValueKey<String>('ordinary-page-action'),
        );
        await tester.tap(pageButton, warnIfMissed: false);
        await tester.pump();

        expect(pageTaps, 0);
        expect(decisionSettled, isFalse);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.awaitingConsent);
        expect(coordinator.snapshot.pauseReason, isNull);
        expect(find.byType(AlertDialog), findsOneWidget);

        await tester.tap(allowButton);
        await tester.pumpAndSettle();

        expect(await decision, ActionApprovalDecision.allowOnce);
        expect(find.byType(AlertDialog), findsNothing);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.navigating);
        expect(coordinator.snapshot.pauseReason, isNull);

        await tester.tap(pageButton);

        expect(pageTaps, 1);
        expect(coordinator.snapshot.phase, AgentUiControlPhase.pausedByUser);
        expect(coordinator.snapshot.pauseReason, 'pointer_down');
        semantics.dispose();
      },
    );

    testWidgets('system back cancels and invalidates the waiting lease', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final host = MaterialActionApprovalHost(navigatorKey: navigatorKey);

      await _pumpShell(
        tester,
        coordinator: coordinator,
        navigatorKey: navigatorKey,
      );
      final lease = _beginWaitingLease(coordinator);
      final session = host.present(_prompt());
      final decision = _applyDecisionToLease(
        session: session,
        coordinator: coordinator,
        lease: lease,
      );
      await tester.pumpAndSettle();

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(await decision, ActionApprovalDecision.cancel);
      expect(find.byType(AlertDialog), findsNothing);
      expect(coordinator.snapshot.phase, AgentUiControlPhase.failed);
      expect(coordinator.snapshot.failureMessage, 'Approval cancelled.');
      expect(
        coordinator.checkLease(lease).status,
        AgentUiControlResultStatus.staleSession,
      );
    });

    testWidgets(
      'root Navigator disposal acknowledges and drains a visible approval',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        final host = MaterialActionApprovalHost(navigatorKey: navigatorKey);

        await _pumpShell(
          tester,
          coordinator: coordinator,
          navigatorKey: navigatorKey,
        );
        final session = host.present(_prompt());
        await tester.pumpAndSettle();

        expect(find.byType(AlertDialog), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();

        await expectLater(
          session.dismiss(ActionApprovalCancellationReason.hostFailed),
          completes,
        );
        await expectLater(host.whenAllDismissed, completes);
        expect(await session.decision, ActionApprovalDecision.cancel);
      },
    );
  });
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required AgentUiControlCoordinator coordinator,
  required GlobalKey<NavigatorState> navigatorKey,
  VoidCallback? onPageTap,
}) async {
  final router = GoRouter(
    navigatorKey: navigatorKey,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                key: const ValueKey<String>('ordinary-page-action'),
                onPressed: onPageTap,
                child: const Text('Ordinary page action'),
              ),
            ),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => AppAgentShell(
        coordinator: coordinator,
        child: child ?? const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pump();
}

AgentUiControlLease _beginWaitingLease(AgentUiControlCoordinator coordinator) {
  final lease = coordinator
      .begin(sessionId: 'approval-dialog', purpose: 'confirm an external write')
      .value!;
  expect(coordinator.enterAwaitingConsent(lease).isSuccess, isTrue);
  expect(coordinator.snapshot.phase, AgentUiControlPhase.awaitingConsent);
  return lease;
}

Future<ActionApprovalDecision> _applyDecisionToLease({
  required ActionApprovalSession session,
  required AgentUiControlCoordinator coordinator,
  required AgentUiControlLease lease,
}) => session.decision.then((decision) {
  if (decision == ActionApprovalDecision.allowOnce) {
    coordinator.grantConsent(lease);
  } else {
    coordinator.fail(lease, message: 'Approval cancelled.');
  }
  return decision;
});

ActionApprovalPrompt _prompt() => ActionApprovalPrompt(
  fingerprint: '0123456789abcdef0123456789abcdef',
  actionId: 'app_control.community.publish',
  expiresAt: DateTime.utc(2030, 1, 1),
  presentation: const ActionApprovalPresentation(
    title: _approvalTitle,
    description: 'This will publish content outside Maaso.',
    targetLabel: 'Community release channel',
    consequenceLabel: 'Visible to every channel member',
    exactText: _exactText,
    argumentFields: <ActionApprovalPresentationField>[
      ActionApprovalPresentationField(label: 'Channel', value: '#release'),
    ],
  ),
  risk: ActionRisk.externalWrite,
  consequencePolicy: ActionConsequencePolicy.exactTextCommit,
);
