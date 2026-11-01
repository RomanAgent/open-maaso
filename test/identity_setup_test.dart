import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/identity/application/identity_page_adapter.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/presentation/identity_badge.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';

import 'identity_test_support.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets(
    'two public identities are previewed and saved without any model dependency',
    (tester) async {
      final gateway = FakeIdentityGateway();
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
      );
      IdentityProfile? completed;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: IdentitySetupPage(
              controller: controller,
              route: '/onboarding',
              onCompleted: (result) async => completed = result.profile,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1. Your name (Alien)'), findsOneWidget);
      expect(find.text('2. Your Agent’s name (Native)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('identity-player-name')),
        'Star',
      );
      await tester.enterText(
        find.byKey(const ValueKey('identity-agent-name')),
        'Wheat',
      );
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is IdentityBadge &&
              widget.kind == IdentityActorKind.player &&
              widget.name == 'Star',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is IdentityBadge &&
              widget.kind == IdentityActorKind.agent &&
              widget.name == 'Wheat',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('identity-save')));
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      expect(gateway.writes, 1);
      expect(completed?.completed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable profile offers retry without fabricated identities',
    (tester) async {
      final gateway = FakeIdentityGateway()
        ..fetchOverride = () async =>
            throw const IdentityException(IdentityFailure.unavailable);
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: IdentitySetupPage(
              controller: controller,
              route: '/onboarding',
              onCompleted: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.ready.value, isFalse);
      expect(find.byKey(const ValueKey('identity-retry')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('identity-save')))
            .onPressed,
        isNull,
      );
      expect(gateway.writes, 0);
    },
  );

  testWidgets(
    'page adapter is scoped, only prepares visible names, and loses control on typing',
    (tester) async {
      final gateway = FakeIdentityGateway();
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
      );
      final control = AgentUiControlService();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: IdentitySetupPage(
              controller: controller,
              route: '/onboarding',
              uiControl: control,
              onCompleted: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(control.adapters.length, 1);
      final lease = control.coordinator
          .begin(
            sessionId: 'identity-test',
            purpose: 'Prepare names',
            targetRoute: '/onboarding',
          )
          .value!;
      final adapter = control.adapters
          .resolve<IdentityPageAdapter>(route: '/onboarding', lease: lease)
          .value!;
      final context = AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'stale',
      );
      final result = await adapter.executeAppControlAction(
        lease: lease,
        actionId: IdentityPageAdapter.prepareAction,
        arguments: {'playerName': 'Nova', 'agentName': 'Rice'},
        executionContext: context,
      );
      expect(result.isSuccess, isTrue);
      expect(result.value, {'prepared': true, 'saved': false});
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('identity-player-name')),
            )
            .controller
            ?.text,
        'Nova',
      );
      expect(gateway.writes, 0);
      expect(
        adapter.appControlActions.every((action) => !action.requiresApproval),
        isTrue,
      );
      expect(adapter.actionById('save'), isNull);
      await tester.tap(find.byKey(const ValueKey('identity-player-name')));
      await tester.enterText(
        find.byKey(const ValueKey('identity-player-name')),
        'My choice',
      );
      final takeover = await adapter.executeAppControlAction(
        lease: lease,
        actionId: IdentityPageAdapter.prepareAction,
        arguments: {'playerName': 'Override', 'agentName': 'Rice'},
        executionContext: context,
      );
      expect(takeover.isSuccess, isFalse);
      expect(controller.playerName.value, 'My choice');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(gateway.writes, 0);
      await control.coordinator.dispose();
    },
  );

  testWidgets(
    'compact screen and large text remain scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = IdentitySetupController(
        service: IdentityService(gateway: FakeIdentityGateway()),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: IdentitySetupPage(
              controller: controller,
              route: '/onboarding',
              onCompleted: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('identity-save')));
      expect(tester.takeException(), isNull);
    },
  );
}
