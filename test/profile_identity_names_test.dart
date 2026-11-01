import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/application/profile_controller.dart';
import 'package:maaso/src/features/identity/presentation/current_player_identity_badge.dart';

import 'identity_test_support.dart';
import 'profile_membership_test_support.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets('initial setup names become personal and Agent identities', (
    tester,
  ) async {
    final fixture = ProfileFixture();
    addTearDown(fixture.close);
    fixture.identityGateway.stored = identityFixture(
      version: 0,
      player: '',
      agent: '',
    );
    final setup = IdentitySetupController(service: fixture.identity);
    addTearDown(setup.onClose);
    await setup.initialize();
    setup.setPlayerName('Harbor');
    setup.setAgentName('Little Comet');

    final result = await setup.save();
    expect(result, isNotNull);
    expect(result!.names.playerName, 'Harbor');
    expect(result.names.agentName, 'Little Comet');
    expect(fixture.identity.completed, isTrue);
    expect(fixture.identity.setupPlayerName, 'Harbor');
    expect(fixture.identity.setupAgentName, 'Little Comet');
    expect(fixture.identityGateway.writes, 1);

    await fixture.controller.refresh();
    expect(fixture.controller.beginEdit(ProfileEditField.nickname), isTrue);
    expect(fixture.controller.nickname.value, 'Harbor');
    fixture.controller.cancelEdit();

    appServices.put<IdentityService>(fixture.identity);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: CurrentPlayerIdentityBadge())),
      ),
    );
    expect(find.textContaining('Harbor', findRichText: true), findsOneWidget);
    expect(fixture.identity.profile!.agentName, 'Little Comet');
    expect(fixture.identityGateway.writes, 1);
    expect(fixture.companionGateway.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'personal nickname save updates public author and preserves Agent identity',
    (tester) async {
      final fixture = ProfileFixture();
      addTearDown(fixture.close);
      await fixture.controller.refresh();
      final original = fixture.identity.profile!;
      appServices.put<IdentityService>(fixture.identity);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: CurrentPlayerIdentityBadge()),
          ),
        ),
      );
      expect(find.textContaining('Star', findRichText: true), findsOneWidget);

      expect(fixture.controller.prepareNickname('Harbor'), isTrue);
      expect(fixture.identityGateway.writes, 0);
      expect(await fixture.controller.save(), isTrue);
      await tester.pump();

      expect(find.textContaining('Harbor', findRichText: true), findsOneWidget);
      expect(find.textContaining('Star', findRichText: true), findsNothing);
      final updated = fixture.identity.profile!;
      expect(updated.playerName, 'Harbor');
      expect(updated.agentName, original.agentName);
      expect(updated.playerActorId, original.playerActorId);
      expect(updated.agentActorId, original.agentActorId);
      expect(fixture.identity.setupAgentName, original.agentName);
      expect(fixture.identityGateway.stored.playerName, 'Harbor');
      expect(fixture.identityGateway.stored.agentName, original.agentName);
      expect(fixture.identityGateway.writes, 1);
      expect(fixture.companionGateway.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
