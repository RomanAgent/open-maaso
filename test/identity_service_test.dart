import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

import 'identity_test_support.dart';

void main() {
  test(
    'successful CAS updates one stable profile without recreating Agent',
    () async {
      final gateway = FakeIdentityGateway(initial: identityFixture());
      final service = IdentityService(gateway: gateway);
      await service.load();
      final saved = await service.save(playerName: 'Nova', agentName: 'Rice');
      expect(gateway.expectedVersion, 1);
      expect(saved.version, 2);
      expect(saved.agentActorId, identityFixture().agentActorId);
      expect(service.completed, isTrue);
    },
  );

  test('late load from a retired account never sets profile', () async {
    final reply = Completer<IdentityProfile>();
    final gateway = FakeIdentityGateway()..fetchOverride = () => reply.future;
    final service = IdentityService(gateway: gateway);
    final load = service.load();
    final check = expectLater(load, throwsA(isA<IdentityException>()));
    service.onClose();
    reply.complete(identityFixture());
    await check;
    expect(service.profile, isNull);
  });

  test('account replacement hides current profile and blocks writes', () async {
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final service = IdentityService(gateway: gateway);
    await service.load();
    gateway.requestContextKey = 'test|account-b';
    expect(service.profile, isNull);
    await expectLater(
      service.save(playerName: 'Nova', agentName: 'Rice'),
      throwsA(isA<IdentityException>()),
    );
    expect(gateway.writes, 0);
  });

  test(
    'malformed server identity cannot change stable actor or fake a saved version',
    () async {
      for (final result in [
        identityFixture(version: 2, player: 'Nova', playerId: 'other'),
        identityFixture(player: 'Nova'),
      ]) {
        final gateway = FakeIdentityGateway(initial: identityFixture())
          ..updateOverride = (_, _, _) async => result;
        final service = IdentityService(gateway: gateway);
        await service.load();
        await expectLater(
          service.save(playerName: 'Nova', agentName: 'Wheat'),
          throwsA(isA<IdentityException>()),
        );
        expect(service.profile?.version, 1);
      }
    },
  );

  test('slow read cannot regress a confirmed write', () async {
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final service = IdentityService(gateway: gateway);
    await service.load();
    final reply = Completer<IdentityProfile>();
    gateway.fetchOverride = () => reply.future;
    final read = service.load();
    await service.save(playerName: 'Nova', agentName: 'Wheat');
    reply.complete(identityFixture());
    expect((await read).version, 2);
    expect(service.profile?.playerName, 'Nova');
  });

  test('same revision cannot silently replace a known public name', () async {
    final gateway = FakeIdentityGateway(initial: identityFixture());
    final service = IdentityService(gateway: gateway);
    await service.load();
    gateway.stored = identityFixture(player: 'Unversioned edit');
    await expectLater(service.load(), throwsA(isA<IdentityException>()));
    expect(service.profile?.playerName, 'Star');
  });

  test(
    'double save sends only one mutation and preserves draft on failure',
    () async {
      final result = Completer<IdentityProfile>();
      final gateway = FakeIdentityGateway(initial: identityFixture())
        ..updateOverride = (_, _, _) => result.future;
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        onlyMissing: false,
      );
      await controller.initialize();
      controller.setPlayerName('My edit');
      final first = controller.save();
      expect(await controller.save(), isNull);
      expect(gateway.writes, 1);
      result.completeError(
        const IdentityException(IdentityFailure.unavailable),
      );
      expect(await first, isNull);
      expect(controller.playerName.value, 'My edit');
      expect(controller.error.value, IdentityFailure.unavailable);
      expect(controller.service.profile?.playerName, 'Star');
    },
  );

  test(
    'first setup preserves server Agent name and fills only missing player name',
    () async {
      final gateway = FakeIdentityGateway(
        initial: identityFixture(player: '', agent: 'Existing'),
      );
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        legacyAgentName: () => 'Wrong local name',
      );
      await controller.initialize();
      expect(controller.agentName.value, 'Existing');
      expect(controller.agentLocked, isTrue);
      controller.setAgentName('Overwrite');
      controller.setPlayerName('Star');
      await controller.save();
      expect(gateway.stored.agentName, 'Existing');
      expect(gateway.stored.playerName, 'Star');
    },
  );

  test('unnamed account can prefill only the locally named Agent', () async {
    final controller = IdentitySetupController(
      service: IdentityService(gateway: FakeIdentityGateway()),
      legacyAgentName: () => 'My Agent',
    );
    await controller.initialize();
    expect(controller.playerName.value, isEmpty);
    expect(controller.agentName.value, 'My Agent');
    expect(controller.canSave, isFalse);
  });

  test(
    'CAS conflict loads current names for explicit review, never auto retries',
    () async {
      final gateway = FakeIdentityGateway(initial: identityFixture());
      final controller = IdentitySetupController(
        service: IdentityService(gateway: gateway),
        onlyMissing: false,
      );
      await controller.initialize();
      controller.setPlayerName('My edit');
      gateway.updateOverride = (_, _, _) async {
        gateway.stored = identityFixture(version: 2, player: 'Other device');
        throw const IdentityException(IdentityFailure.conflict);
      };
      expect(await controller.save(), isNull);
      expect(gateway.writes, 1);
      expect(controller.error.value, IdentityFailure.conflict);
      expect(controller.playerName.value, 'Other device');
      expect(controller.ready.value, isTrue);
    },
  );
}
