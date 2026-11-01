import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_scaffold.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/data/identity_local_store.dart';
import 'package:maaso/src/features/identity/domain/identity_local_state.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';

import 'identity_test_support.dart';

class _Store implements IdentityLocalStore {
  IdentityLocalState? state;
  int writes = 0;
  @override
  Future<IdentityLocalState?> read() async => state;
  @override
  Future<void> write(IdentityLocalState value) async {
    state = IdentityLocalState.fromJson(value.toJson());
    writes++;
  }
}

FakeIdentityGateway _offline() =>
    FakeIdentityGateway()
      ..fetchOverride = () async =>
          throw const IdentityException(IdentityFailure.unavailable);

Future<void> _mount(
  WidgetTester tester,
  IdentitySetupController controller, {
  required Future<void> Function(IdentitySetupResult) completed,
  Brightness brightness = Brightness.light,
  double scale = 1,
  AgentUiControlService? uiControl,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: IdentitySetupPage(
          controller: controller,
          route: '/onboarding',
          autoComplete: true,
          uiControl: uiControl,
          onCompleted: completed,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets(
    'first-use guide validates each step and saves offline names once',
    (tester) async {
      final gateway = _offline();
      final store = _Store();
      final service = IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
      );
      final controller = IdentitySetupController(
        service: service,
        legacyAgentName: () => 'Tina',
      );
      IdentitySetupResult? result;
      final control = AgentUiControlService();
      await _mount(
        tester,
        controller,
        completed: (value) async => result = value,
        uiControl: control,
      );
      expect(control.adapters.length, 0);
      expect(find.text('Step 1 of 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('identity-agent-name')), findsNothing);
      expect(find.byKey(const ValueKey('identity-retry')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('identity-player-name')),
        'Nova',
      );
      await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(control.adapters.length, 0);
      final agent = tester.widget<TextFormField>(
        find.byKey(const ValueKey('identity-agent-name')),
      );
      expect(agent.controller!.text, 'Tina');
      expect(agent.enabled, isFalse);
      await tester.tap(find.byTooltip('common.back'.tr));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('identity-player-name')),
            )
            .controller!
            .text,
        'Nova',
      );
      await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(control.adapters.length, 0);
      expect(find.byKey(const ValueKey('identity-preview')), findsOneWidget);
      expect(gateway.writes, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('identity-save')));
      await tester.tap(find.byKey(const ValueKey('identity-save')));
      await tester.pumpAndSettle();
      expect(result!.names.playerName, 'Nova');
      expect(result!.names.agentName, 'Tina');
      expect(result!.profile, isNull);
      expect(result!.pendingSync, isTrue);
      expect(service.onboardingCompleted, isTrue);
      expect(service.completed, isFalse);
      expect(store.writes, 1);
      expect(gateway.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.onClose();
      service.onClose();

      final nextGateway = _offline();
      final restored = IdentityService(
        gateway: nextGateway,
        localStore: store,
        allowLocalSetup: () => true,
      );
      final nextController = IdentitySetupController(service: restored);
      var resumed = 0;
      await _mount(tester, nextController, completed: (_) async => resumed++);
      expect(resumed, 1);
      expect(nextGateway.reads, 0);
      expect(store.writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      nextController.onClose();
      restored.onClose();
      await control.coordinator.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 812), const Size(812, 375)]) {
      testWidgets(
        'guide uses Maaso neutral shell at $brightness $size with large text',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final service = IdentityService(
            gateway: _offline(),
            localStore: _Store(),
            allowLocalSetup: () => true,
          );
          final controller = IdentitySetupController(service: service);
          await _mount(
            tester,
            controller,
            completed: (_) async {},
            brightness: brightness,
            scale: 2,
          );
          expect(find.byType(AppSecondaryScaffold), findsOneWidget);
          final background = tester.widget<DecoratedBox>(
            find.byKey(AppSecondaryScaffold.backgroundKey),
          );
          final decoration = background.decoration as BoxDecoration;
          final palette = AppSecondaryPalette.resolve(brightness);
          expect(decoration.color, palette.backgroundStart);
          expect(decoration.color!.a, 1);
          expect(decoration.gradient, isNull);
          await tester.enterText(
            find.byKey(const ValueKey('identity-player-name')),
            'Nova',
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('identity-guide-next')),
          );
          await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('identity-agent-name')),
            'Tina',
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('identity-guide-next')),
          );
          await tester.tap(find.byKey(const ValueKey('identity-guide-next')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('identity-save')),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('Enter Maaso'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          controller.onClose();
          service.onClose();
        },
      );
    }
  }
}
