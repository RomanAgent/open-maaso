import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/execution_handoff_runtime_bridge.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

import 'helpers/bundled_matt_revision_fixture.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());

  test(
    'handoff rejects retired identities and uses the actual Joy selection version',
    () {
      final retired = AvatarSelectionSnapshot(
        selection: AvatarSelectionState(
          selectionId: 10,
          agentId: 'self',
          modelId: 44,
          version: 7,
          selectedAt: DateTime.utc(2026, 10, 23),
        ),
        asset: AvatarSelectionAssetDescriptor.fromJson(
          historicalMattDescriptor(),
        ),
        selectionAvailable: true,
      );
      expect(() => handoffAvatarIdentityFor(retired), throwsStateError);
      final joy = AvatarSelectionSnapshot(
        selection: AvatarSelectionState(
          selectionId: 10,
          agentId: 'self',
          modelId: null,
          version: 8,
          selectedAt: DateTime.utc(2026, 10, 23),
        ),
        asset: AvatarSelectionAssetDescriptor(
          id: 1,
          modelKey: 'masso.bundled.agent',
          displayName: 'Joy',
          modelSource: 'bundled',
          assetUrl: 'unity://masso/avatar_agent',
          assetSha256: 'a' * 64,
          runtimeConfig: const {},
          compatibility: const {},
        ),
        selectionAvailable: true,
      );
      expect(handoffAvatarIdentityFor(joy).toJson(), {
        'modelId': 'masso.bundled.agent',
        'revision': '8',
        'sha256': '',
      });
    },
  );

  test(
    'source request drains execution before its readonly identity',
    () async {
      final gate = Completer<void>();
      final bridge = _withExecutionPreparation(fixture, (_) async {
        fixture.events.add('provider-drain');
        await gate.future;
      });
      final request = bridge.currentAvatar();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.events, ['provider-drain']);
      gate.complete();
      await request;
      expect(fixture.events, ['provider-drain', 'identity']);
      fixture.events.clear();
      await bridge.prepareTarget(fixture.handoff());
      expect(fixture.events, [
        'identity',
      ], reason: 'a target preparation does not drain another owner');
    },
  );

  test(
    'account retirement while provider drains prevents identity dispatch',
    () async {
      final gate = Completer<void>();
      final bridge = _withExecutionPreparation(fixture, (_) => gate.future);
      final request = bridge.currentAvatar();
      fixture.changeAccount();
      gate.complete();
      await expectLater(request, _fails('handoff_account_changed'));
      expect(fixture.events, isEmpty);
    },
  );

  test('model identity is readonly and requires a current account', () async {
    final identity = await fixture.bridge.currentAvatar();
    expect(identity.matches(fixture.identity), isTrue);
    expect(fixture.events, ['identity']);
    fixture.context = null;
    expect(fixture.bridge.isAvailable, isFalse);
    await expectLater(
      fixture.bridge.currentAvatar(),
      _fails('handoff_account_unavailable'),
    );
    expect(fixture.events, ['identity']);
  });

  test(
    'source drain, exit and retirement invoke only execution callbacks',
    () async {
      final prepared = fixture.handoff();
      await fixture.bridge.quiesceSource(prepared);
      await fixture.bridge.exitSource(prepared);
      await fixture.bridge.retireSource(fixture.handoff(committed: true));
      await fixture.bridge.retireSource(fixture.handoff(committed: true));
      expect(fixture.events, ['identity', 'quiesce', 'retire']);
    },
  );

  test(
    'target prepare, mount and completion are repeatable without visual work',
    () async {
      await fixture.bridge.prepareTarget(fixture.handoff());
      final committed = fixture.handoff(committed: true);
      await fixture.bridge.mountTarget(committed);
      await fixture.bridge.enterTarget(committed);
      await fixture.bridge.mountTarget(committed);
      await fixture.bridge.enterTarget(committed);
      expect(fixture.events, ['identity', 'mount']);
    },
  );

  test(
    'first canonical committed target discovery can mount without preparation',
    () async {
      final committed = fixture.handoff(committed: true);
      await fixture.bridge.mountTarget(committed);
      await fixture.bridge.enterTarget(committed);
      expect(fixture.events, ['identity', 'mount']);
    },
  );

  test(
    'first canonical committed source discovery can retire without draining again',
    () async {
      final committed = fixture.handoff(committed: true);
      await fixture.bridge.retireSource(committed);
      await fixture.bridge.retireSource(committed);
      expect(fixture.events, ['identity', 'retire']);
    },
  );

  test(
    'failed committed mount cancels locally and can retry canonical identity',
    () async {
      final committed = fixture.handoff(committed: true);
      fixture.mountSucceeds = false;
      await expectLater(
        fixture.bridge.mountTarget(committed),
        _fails('handoff_target_runtime_mount_failed'),
      );
      await fixture.bridge.cancelTarget(committed);
      fixture.mountSucceeds = true;
      await fixture.bridge.mountTarget(committed);
      await fixture.bridge.enterTarget(committed);
      expect(fixture.events, ['identity', 'mount', 'identity', 'mount']);
    },
  );

  test(
    'committed completion cancellation revalidates without mounting twice',
    () async {
      final committed = fixture.handoff(committed: true);
      await fixture.bridge.mountTarget(committed);
      await fixture.bridge.enterTarget(committed);
      await fixture.bridge.cancelTarget(committed);
      await fixture.bridge.enterTarget(committed);
      await fixture.bridge.mountTarget(committed);
      expect(fixture.events, ['identity', 'mount', 'identity']);
    },
  );

  test(
    'pending target preparation cancellation rejects its late readonly result',
    () async {
      final handoff = fixture.handoff();
      final gate = fixture.identityGate = Completer<HandoffAvatarIdentity>();
      final pending = fixture.bridge.prepareTarget(handoff);
      final expectation = expectLater(
        pending,
        _fails('handoff_preparation_changed'),
      );
      await fixture.bridge.cancelTarget(handoff);
      gate.complete(fixture.identity);
      await expectation;
      await expectLater(
        fixture.bridge.mountTarget(handoff),
        _fails('handoff_target_changed'),
      );
      expect(fixture.events, ['identity']);
    },
  );

  test(
    'cancelling a different transfer cannot cancel current pending preparation',
    () async {
      final handoff = fixture.handoff();
      final gate = fixture.identityGate = Completer<HandoffAvatarIdentity>();
      final pending = fixture.bridge.prepareTarget(handoff);
      await fixture.bridge.cancelTarget(
        fixture.handoff(id: 'different-transfer'),
      );
      gate.complete(fixture.identity);
      await pending;
      fixture.identityGate = null;
      await fixture.bridge.mountTarget(fixture.handoff(committed: true));
      expect(fixture.events, ['identity', 'mount']);
    },
  );

  test(
    'another preparation fences the earlier model identity result',
    () async {
      final firstGate = fixture.identityGate =
          Completer<HandoffAvatarIdentity>();
      final first = fixture.bridge.prepareTarget(fixture.handoff(id: 'first'));
      final expectation = expectLater(
        first,
        _fails('handoff_preparation_changed'),
      );
      fixture.identityGate = null;
      await fixture.bridge.prepareTarget(fixture.handoff(id: 'second'));
      firstGate.complete(fixture.identity);
      await expectation;
      await fixture.bridge.mountTarget(
        fixture.handoff(id: 'second', committed: true),
      );
      expect(fixture.events, ['identity', 'identity', 'mount']);
    },
  );

  for (final target in [false, true]) {
    test(
      'changed model rejects ${target ? "target" : "source"} before execution',
      () async {
        fixture.identity = HandoffAvatarIdentity(
          modelId: 'changed',
          revision: '2',
        );
        await expectLater(
          target
              ? fixture.bridge.prepareTarget(fixture.handoff())
              : fixture.bridge.quiesceSource(fixture.handoff()),
          _fails('handoff_model_selection_changed'),
        );
        expect(fixture.events, ['identity']);
      },
    );
  }

  test(
    'model-read completion from another account cannot publish identity',
    () async {
      final gate = fixture.identityGate = Completer<HandoffAvatarIdentity>();
      final pending = fixture.bridge.currentAvatar();
      final expectation = expectLater(
        pending,
        _fails('handoff_account_changed'),
      );
      fixture.changeAccount();
      gate.complete(fixture.identity);
      await expectation;
      expect(fixture.events, ['identity']);
    },
  );

  test(
    'late target model read cannot prepare or mount another account',
    () async {
      final gate = fixture.identityGate = Completer<HandoffAvatarIdentity>();
      final pending = fixture.bridge.prepareTarget(fixture.handoff());
      final expectation = expectLater(
        pending,
        _fails('handoff_account_changed'),
      );
      fixture.changeAccount();
      gate.complete(fixture.identity);
      await expectation;
      await expectLater(
        fixture.bridge.mountTarget(fixture.handoff(committed: true)),
        _fails('handoff_account_changed'),
      );
      expect(fixture.events, ['identity']);
    },
  );

  test('late source identity cannot drain another account', () async {
    final gate = fixture.identityGate = Completer<HandoffAvatarIdentity>();
    final pending = fixture.bridge.quiesceSource(fixture.handoff());
    final expectation = expectLater(pending, _fails('handoff_account_changed'));
    fixture.changeAccount();
    gate.complete(fixture.identity);
    await expectation;
    expect(fixture.events, ['identity']);
  });

  for (final operation in ['quiesce', 'mount', 'restore', 'retire']) {
    test(
      'late $operation receipt is rejected after account replacement',
      () async {
        final handoff = fixture.handoff(committed: true);
        if (operation == 'restore' || operation == 'retire') {
          await fixture.bridge.quiesceSource(handoff);
        }
        final gate = fixture.executionGate = Completer<void>();
        final Future<void> pending = switch (operation) {
          'quiesce' => fixture.bridge.quiesceSource(handoff),
          'mount' => fixture.bridge.mountTarget(handoff),
          'restore' => fixture.bridge.restoreSource(handoff),
          _ => fixture.bridge.retireSource(handoff),
        };
        final expectation = expectLater(
          pending,
          _fails('handoff_account_changed'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(fixture.events, contains(operation));
        fixture.changeAccount();
        gate.complete();
        await expectation;
      },
    );
  }

  test(
    'cancelled source rollback is repeatable and can retry a failed restore',
    () async {
      final handoff = fixture.handoff();
      await fixture.bridge.quiesceSource(handoff);
      fixture.restoreSucceeds = false;
      await expectLater(
        fixture.bridge.restoreSource(handoff),
        _fails('handoff_source_restore_failed'),
      );
      fixture.restoreSucceeds = true;
      await fixture.bridge.restoreSource(handoff);
      await fixture.bridge.restoreSource(handoff);
      expect(fixture.events, ['identity', 'quiesce', 'restore', 'restore']);
    },
  );

  test(
    'source model rejection still permits fenced execution rollback',
    () async {
      fixture.identity = HandoffAvatarIdentity(
        modelId: 'changed',
        revision: '2',
      );
      final handoff = fixture.handoff();
      await expectLater(
        fixture.bridge.quiesceSource(handoff),
        _fails('handoff_model_selection_changed'),
      );
      await fixture.bridge.restoreSource(handoff);
      expect(fixture.events, ['identity', 'restore']);
    },
  );

  test(
    'wrong source and target are rejected before readonly model access',
    () async {
      fixture.sourceMatches = false;
      fixture.targetMatches = false;
      await expectLater(
        fixture.bridge.quiesceSource(fixture.handoff()),
        _fails('handoff_source_mismatch'),
      );
      await expectLater(
        fixture.bridge.prepareTarget(fixture.handoff()),
        _fails('handoff_target_mismatch'),
      );
      expect(fixture.events, isEmpty);
    },
  );
}

Matcher _fails(String message) => throwsA(
  isA<StateError>().having((error) => error.message, 'message', message),
);

ExecutionHandoffRuntimeBridge _withExecutionPreparation(
  _Fixture fixture,
  Future<void> Function(HandoffAccountContext) prepare,
) => ExecutionHandoffRuntimeBridge(
  accountContext: () => fixture.context,
  prepareExecutionRequest: prepare,
  readModelIdentity: (_) async {
    fixture.events.add('identity');
    return fixture.identity;
  },
  isSource: (_) => fixture.sourceMatches,
  isTarget: (_) => fixture.targetMatches,
  quiesceExecution: () async {},
  retireExecution: () async {},
  mountExecution: () async => true,
  restoreExecution: () async => true,
);

class _Fixture {
  _Fixture() {
    bridge = ExecutionHandoffRuntimeBridge(
      accountContext: () => context,
      readModelIdentity: (_) async {
        events.add('identity');
        final gate = identityGate;
        return gate == null ? identity : await gate.future;
      },
      isSource: (_) => sourceMatches,
      isTarget: (_) => targetMatches,
      quiesceExecution: () async {
        events.add('quiesce');
        await executionGate?.future;
      },
      retireExecution: () async {
        events.add('retire');
        await executionGate?.future;
      },
      mountExecution: () async {
        events.add('mount');
        await executionGate?.future;
        return mountSucceeds;
      },
      restoreExecution: () async {
        events.add('restore');
        await executionGate?.future;
        return restoreSucceeds;
      },
    );
  }

  late final ExecutionHandoffRuntimeBridge bridge;
  HandoffAccountContext? context = const HandoffAccountContext(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-a',
    presenceSessionId: 'presence-a',
  );
  HandoffAvatarIdentity identity = HandoffAvatarIdentity(
    modelId: 'bundled:avatar-agent',
    revision: 'built-in',
  );
  final events = <String>[];
  Completer<HandoffAvatarIdentity>? identityGate;
  Completer<void>? executionGate;
  bool sourceMatches = true, targetMatches = true;
  bool mountSucceeds = true, restoreSucceeds = true;

  void changeAccount() {
    context = const HandoffAccountContext(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-b',
      presenceSessionId: 'presence-b',
    );
  }

  AccountDeviceHandoff handoff({
    String id = 'transfer-1',
    bool committed = false,
  }) => AccountDeviceHandoff(
    handoffId: id,
    agentId: 'self',
    state: committed
        ? AccountHandoffState.accepted
        : AccountHandoffState.prepared,
    sourceLeaseId: 'source-lease',
    sourceEpoch: 1,
    sourcePresenceSessionId: 'source-presence',
    sourceRuntimeInstanceId: 'source-runtime',
    targetPresenceSessionId: 'target-presence',
    targetRuntimeInstanceId: 'target-runtime',
    avatarModel: HandoffAvatarIdentity(
      modelId: 'bundled:avatar-agent',
      revision: 'built-in',
    ),
    createdAt: DateTime.utc(2026, 10, 7),
    expiresAt: DateTime.utc(2026, 10, 7, 0, 1),
    remainingTtl: const Duration(minutes: 1),
  );
}
