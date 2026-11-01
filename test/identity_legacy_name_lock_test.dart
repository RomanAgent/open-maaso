import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';
import 'identity_test_support.dart';

void main() {
  test(
    'partial-profile conflict keeps the captured local name despite a changed callback',
    () async {
      final gateway = FakeIdentityGateway();
      var oldName = 'Existing Companion';
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        legacyAgentName: () => oldName,
      );
      await controller.initialize();
      controller.setPlayerName('Sky');
      oldName = 'Changed Elsewhere';
      gateway.updateOverride = (_, _, _) async {
        gateway.stored = identityFixture(player: 'Remote Player', agent: '');
        throw const IdentityException(IdentityFailure.conflict);
      };
      expect(await controller.save(), isNull);
      expect(controller.agentName.value, 'Existing Companion');
      expect(controller.playerName.value, 'Remote Player');
      expect(controller.agentLocked, isTrue);
      expect(controller.playerLocked, isTrue);
      expect(gateway.writes, 1);
    },
  );
  test(
    'first setup locks a valid old local Agent name against typing and Agent preparation',
    () async {
      final gateway = FakeIdentityGateway();
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        legacyAgentName: () => '  Old  Friend  ',
      );
      await controller.initialize();
      expect(controller.agentName.value, 'Old  Friend');
      expect(controller.agentLocked, isTrue);
      controller.setAgentName('Overwrite');
      expect(controller.agentName.value, 'Old  Friend');
      expect(
        controller.prepareNames(player: 'Player', agent: 'Overwrite'),
        isFalse,
      );
      controller.setPlayerName('Player');
      await controller.save();
      expect(gateway.stored.agentName, 'Old  Friend');
      expect(gateway.stored.playerName, 'Player');
      expect(gateway.writes, 1);
    },
  );
  test(
    'explicit identity edit can rename while keeping stable actors',
    () async {
      final gateway = FakeIdentityGateway(
        initial: identityFixture(agent: 'Old Friend'),
      );
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        legacyAgentName: () => 'Old Friend',
        onlyMissing: false,
      );
      await controller.initialize();
      expect(controller.agentLocked, isFalse);
      controller.setAgentName('New Friend');
      await controller.save();
      expect(gateway.stored.agentName, 'New Friend');
      expect(gateway.stored.agentActorId, identityFixture().agentActorId);
      expect(gateway.stored.playerName, 'Star');
    },
  );
  test(
    'remote winning name stays authoritative after first-setup conflict',
    () async {
      final gateway = FakeIdentityGateway();
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        legacyAgentName: () => 'Old local',
      );
      await controller.initialize();
      controller.setPlayerName('My choice');
      gateway.updateOverride = (_, _, _) async {
        gateway.stored = identityFixture(
          player: 'Remote player',
          agent: 'Remote Agent',
        );
        throw const IdentityException(IdentityFailure.conflict);
      };
      expect(await controller.save(), isNull);
      expect(controller.agentName.value, 'Remote Agent');
      expect(controller.agentLocked, isTrue);
      expect(gateway.writes, 1);
    },
  );
  test(
    'blank or invalid old names leave the new Agent field editable',
    () async {
      for (final old in ['', ' ', 'Name\nOther']) {
        final controller = IdentitySetupController(
          service: IdentityService(gateway: FakeIdentityGateway()),
          legacyAgentName: () => old,
        );
        await controller.initialize();
        expect(controller.agentLocked, isFalse);
        controller.setAgentName('New Friend');
        expect(controller.agentName.value, 'New Friend');
      }
    },
  );
  testWidgets(
    'first-setup UI disables the old local Agent field but keeps player input',
    (tester) async {
      final controller = IdentitySetupController(
        service: IdentityService(gateway: FakeIdentityGateway()),
        legacyAgentName: () => 'Old Friend',
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
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('identity-agent-name')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('identity-player-name')),
            )
            .enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      controller.onClose();
    },
  );
}
