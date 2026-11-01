import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/features/settings/presentation/device_handoff_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Pair pair;
  setUp(() async {
    pair = await _Pair.create();
  });
  tearDown(() async {
    try {
      pair.close();
    } finally {
      await appServices.reset();
    }
  });

  test(
    'conversation snapshots belong to a real handoff and current account',
    () async {
      expect(pair.source.conversationStatus, isNull);
      expect(pair.target.conversationStatus, isNull);
      final id = await pair.source.request(pair.targetId);
      final sourceStatus = pair.source.conversationStatus!;
      expect(sourceStatus.transactionId, startsWith('source:'));
      expect(sourceStatus.phase, AgentHandoffPhase.waitingForTarget);
      expect(sourceStatus.isTarget, isFalse);
      await pair.target.synchronize();
      final targetStatus = pair.target.conversationStatus!;
      expect(targetStatus.transactionId, id);
      expect(targetStatus.phase, AgentHandoffPhase.targetPreparing);
      expect(targetStatus.isTarget, isTrue);
      pair.targetContext = null;
      expect(pair.target.conversationStatus, isNull);
      expect(pair.source.conversationStatus, isNotNull);
    },
  );

  test(
    'cancellation conversation result waits for the actual local restore',
    () async {
      await pair.prepare();
      pair.sourceBridge.failure = 'exit';
      await pair.source.synchronize();
      final restore = pair.sourceBridge.restoreGate = Completer<void>();
      final source = pair.source.synchronize();
      await _flush();
      expect(pair.sourceBridge.calls, contains('restore'));
      expect(pair.source.conversationStatus?.cancelled, isNot(true));
      restore.complete();
      await source;
      expect(pair.source.conversationStatus?.cancelled, isTrue);
      expect(pair.source.conversationStatus?.phase, AgentHandoffPhase.idle);
      await pair.target.synchronize();
      expect(pair.target.conversationStatus?.cancelled, isTrue);
      pair.sourceContext = null;
      expect(pair.source.conversationStatus, isNull);
    },
  );

  test('handoff busy retains the local Agent Space display route', () async {
    await appServices.reset();
    appServices.put(pair.source);
    appServices.put<AccountSessionLifecycleService>(
      _HandoffWorldLifecycle(pair.sourceAuthority),
    );
    await pair.source.request(pair.targetId);
    expect(accountSessionRedirectForPath(AppRoutes.agentSpace), isNull);
    expect(accountSessionRedirectForPath(AppRoutes.settings), isNull);
    await pair.source.cancel();
    expect(accountSessionRedirectForPath(AppRoutes.agentSpace), isNull);
  });

  testWidgets('Settings cancellation remains clickable during a real handoff', (
    tester,
  ) async {
    await appServices.reset();
    await pair.source.request(pair.targetId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(children: [DeviceHandoffPanel(handoff: pair.source)]),
        ),
      ),
    );
    expect(find.text('Cancel switch').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Cancel switch'));
    await tester.runAsync(() async {
      for (var i = 0; i < 20 && pair.source.isBusy; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    expect(pair.source.isBusy, isFalse);
    expect(pair.source.conversationStatus?.cancelled, isTrue);
    expect(find.text('Cancel switch'), findsNothing);
    expect(find.text('Here I come…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await appServices.reset();
  });

  test(
    'lost prepare response and canonical rediscovery share one transcript identity',
    () async {
      pair.server.losePrepareReply = true;
      await expectLater(
        pair.source.request(pair.targetId),
        throwsA(isA<TimeoutException>()),
      );
      final lostResponse = pair.source.conversationStatus!;
      expect(lostResponse.phase, AgentHandoffPhase.failed);
      await pair.source.synchronize();
      expect(pair.source.handoff, isNotNull);
      expect(
        pair.source.conversationStatus!.transactionId,
        lostResponse.transactionId,
      );
      pair.server.failInspect = true;
      await pair.source.synchronize();
      expect(pair.source.conversationStatus!.phase, AgentHandoffPhase.failed);
      expect(
        pair.source.conversationStatus!.transactionId,
        lostResponse.transactionId,
      );
    },
  );

  test(
    'idle discovery failure cannot turn a completed crossing into failed chat',
    () async {
      await pair.prepare();
      await pair.source.synchronize();
      await pair.target.synchronize();
      expect(pair.source.conversationStatus?.phase, AgentHandoffPhase.away);
      expect(
        pair.target.conversationStatus?.phase,
        AgentHandoffPhase.completed,
      );
      pair.server.failInspect = true;
      await pair.source.synchronize();
      await pair.target.synchronize();
      expect(pair.source.error, isNotNull);
      expect(pair.target.error, isNotNull);
      expect(pair.source.conversationStatus?.phase, AgentHandoffPhase.away);
      expect(
        pair.target.conversationStatus?.phase,
        AgentHandoffPhase.completed,
      );
      pair.server.failInspect = false;
      await pair.source.synchronize();
      await pair.target.synchronize();
      expect(pair.source.conversationStatus?.phase, AgentHandoffPhase.away);
      expect(
        pair.target.conversationStatus?.phase,
        AgentHandoffPhase.completed,
      );
    },
  );

  test(
    'two real authority peers transfer only after prepare, drain and rendered exit',
    () async {
      final targetPrepared = pair.targetBridge.prepareGate = Completer<void>();
      final sourceDrained = pair.sourceBridge.drainGate = Completer<void>();
      final sourceExited = pair.sourceBridge.exitGate = Completer<void>();
      final targetEntered = pair.targetBridge.enterGate = Completer<void>();
      await pair.source.request(pair.targetId);
      final prepare = pair.target.synchronize();
      await _flush();
      expect(pair.server.state, AccountHandoffState.prepared);
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.sourceBridge.calls, isEmpty);
      targetPrepared.complete();
      await prepare;
      expect(pair.server.state, AccountHandoffState.targetReady);
      final exit = pair.source.synchronize();
      await _flush();
      expect(pair.sourceBridge.calls, ['drain']);
      expect(pair.server.state, AccountHandoffState.targetReady);
      sourceDrained.complete();
      await _flush();
      expect(pair.sourceBridge.calls, ['drain', 'exit']);
      expect(pair.server.state, AccountHandoffState.targetReady);
      sourceExited.complete();
      await exit;
      expect(pair.sourceBridge.hidden, isTrue);
      expect(pair.server.state, AccountHandoffState.accepted);
      expect(pair.source.phase, AgentHandoffPhase.away);
      expect(pair.sourceAuthority.canAdmitMutations, isFalse);
      final enter = pair.target.synchronize();
      await _flush();
      expect(pair.targetBridge.calls, [
        'prepare',
        'mount',
        'enter',
      ], reason: pair.target.error.toString());
      expect(pair.targetAuthority.canAdmitMutations, isTrue);
      expect(pair.server.state, AccountHandoffState.accepted);
      targetEntered.complete();
      await enter;
      expect(pair.targetBridge.hidden, isFalse);
      expect(pair.server.state, AccountHandoffState.completed);
      expect(pair.target.phase, AgentHandoffPhase.completed);
      expect(pair.server.commands, [
        AccountHandoffCommand.prepare,
        AccountHandoffCommand.targetReady,
        AccountHandoffCommand.sourceExited,
        AccountHandoffCommand.completed,
      ]);
    },
  );

  test(
    'confirmed target readiness is not posted again while waiting for source exit',
    () async {
      await pair.prepare();
      for (var tick = 0; tick < 4; tick++) {
        await pair.target.synchronize();
      }
      expect(
        pair.server.commands.where(
          (command) => command == AccountHandoffCommand.targetReady,
        ),
        hasLength(1),
      );
      expect(pair.targetBridge.calls, ['prepare']);
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.targetAuthority.canAdmitMutations, isFalse);

      await pair.source.synchronize();
      await pair.target.synchronize();
      expect(pair.target.phase, AgentHandoffPhase.completed);
      expect(pair.sourceBridge.hidden, isTrue);
      expect(pair.targetBridge.hidden, isFalse);
    },
  );

  test(
    'lost target readiness reply is retried before redundant posts stop',
    () async {
      await pair.source.request(pair.targetId);
      final ready = pair.server.readyGate = Completer<void>();
      final preparation = pair.target.synchronize();
      await _flush();
      ready.completeError(TimeoutException('ready_reply_lost'));
      await preparation;
      expect(pair.target.phase, AgentHandoffPhase.failed);
      expect(pair.targetBridge.hidden, isTrue);

      pair.server.readyGate = null;
      await pair.target.synchronize();
      await pair.target.synchronize();
      expect(
        pair.server.commands.where(
          (command) => command == AccountHandoffCommand.targetReady,
        ),
        hasLength(2),
      );
      expect(pair.targetAuthority.canAdmitMutations, isFalse);
      expect(pair.targetBridge.calls, ['prepare']);

      await pair.source.synchronize();
      await pair.target.synchronize();
      expect(pair.target.phase, AgentHandoffPhase.completed);
    },
  );

  test(
    'committed readiness response enters without another polling interval',
    () async {
      await pair.source.request(pair.targetId);
      final ready = pair.server.readyGate = Completer<void>();
      final preparation = pair.target.synchronize();
      await _flush();
      expect(pair.server.state, AccountHandoffState.targetReady);
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.targetAuthority.canAdmitMutations, isFalse);

      await pair.source.synchronize();
      expect(pair.sourceBridge.hidden, isTrue);
      expect(pair.sourceAuthority.canAdmitMutations, isFalse);
      ready.complete();
      await preparation;
      expect(pair.target.phase, AgentHandoffPhase.completed);
      expect(pair.targetBridge.calls, ['prepare', 'mount', 'enter']);
      expect(pair.targetBridge.hidden, isFalse);
    },
  );

  test(
    'uncertain prepare blocks a second transaction until canonical reconciliation',
    () async {
      pair.server.losePrepareReply = true;
      await expectLater(
        pair.source.request(pair.targetId),
        throwsA(isA<TimeoutException>()),
      );
      expect(pair.source.canRequest, isFalse);
      await expectLater(pair.source.request(pair.targetId), throwsStateError);
      expect(
        pair.server.commands.where((c) => c == AccountHandoffCommand.prepare),
        hasLength(1),
      );
      await pair.source.synchronize();
      expect(pair.source.handoff?.handoffId, pair.server.handoff?.handoffId);
      expect(pair.source.phase, AgentHandoffPhase.waitingForTarget);
    },
  );

  test(
    'caller-supplied prepare identity survives an uncertain retry',
    () async {
      pair.server.losePrepareReply = true;
      await expectLater(
        pair.source.request(
          pair.targetId,
          prepareRequestId: 'remote-return-once',
        ),
        throwsA(isA<TimeoutException>()),
      );
      pair.server.absentReads = 1;
      await pair.source.synchronize();
      expect(pair.server.prepareIds, [
        'remote-return-once',
        'remote-return-once',
      ]);
    },
  );

  test(
    'cancelled uncertain request cannot issue a late prepare retry',
    () async {
      pair.server.losePrepareReply = true;
      var current = true;
      await expectLater(
        pair.source.request(
          pair.targetId,
          prepareRequestId: 'remote-return-once',
          requestIsCurrent: () => current,
        ),
        throwsA(isA<TimeoutException>()),
      );
      pair.server.handoff = null;
      current = false;
      await pair.source.synchronize();
      expect(pair.server.prepareIds, ['remote-return-once']);
      expect(pair.source.canRequest, isTrue);
    },
  );

  test(
    'partial hidden target preparation is cleaned up even when prepare throws',
    () async {
      await pair.source.request(pair.targetId);
      pair.targetBridge.failPrepare = true;
      await pair.target.synchronize();
      await pair.target.synchronize();
      expect(pair.server.state, AccountHandoffState.cancelled);
      expect(pair.targetBridge.calls, contains('cancel'));
      expect(pair.targetBridge.allocated, isFalse);
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.sourceBridge.calls, isEmpty);
    },
  );

  test(
    'cancel after target preparation keeps standby hidden without source exit',
    () async {
      await pair.prepare();
      await pair.source.cancel();
      await pair.target.synchronize();
      expect(pair.server.state, AccountHandoffState.cancelled);
      expect(pair.sourceBridge.calls, isEmpty);
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.targetBridge.allocated, isFalse);
    },
  );

  test(
    'lost source exit reply keeps source hidden and retries canonical GET only',
    () async {
      await pair.prepare();
      pair.server.loseExitReply = true;
      await pair.source.synchronize();
      expect(pair.source.phase, AgentHandoffPhase.awaitingCommit);
      expect(pair.sourceBridge.hidden, isTrue);
      expect(pair.sourceBridge.calls, isNot(contains('restore')));
      await pair.source.synchronize();
      expect(pair.source.phase, AgentHandoffPhase.away);
      expect(pair.sourceBridge.calls.where((c) => c == 'exit'), hasLength(1));
      expect(
        pair.server.commands.where(
          (c) => c == AccountHandoffCommand.sourceExited,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'failed committed entry is hidden and never completes or restores source',
    () async {
      await pair.prepare();
      await pair.source.synchronize();
      pair.targetBridge.failEnterAfterReveal = true;
      await pair.target.synchronize();
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.server.state, AccountHandoffState.accepted);
      expect(
        pair.server.commands,
        isNot(contains(AccountHandoffCommand.completed)),
      );
      expect(pair.sourceBridge.calls, isNot(contains('restore')));
      expect(pair.targetBridge.calls, contains('cancel'));
    },
  );

  test(
    'mount failure after transferred proof consumption can retry safely',
    () async {
      await pair.prepare();
      await pair.source.synchronize();
      pair.targetBridge.failMountOnce = true;
      await pair.target.synchronize();
      expect(pair.server.state, AccountHandoffState.accepted);
      expect(pair.targetBridge.hidden, isTrue);
      await pair.target.synchronize();
      expect(pair.target.phase, AgentHandoffPhase.completed);
      expect(pair.server.state, AccountHandoffState.completed);
    },
  );

  test(
    'late prepare receipt cannot publish handoff into a different account',
    () async {
      pair.server.prepareGate = Completer<void>();
      final operation = pair.source.request(pair.targetId);
      final expectation = expectLater(operation, throwsStateError);
      await _flush();
      pair.sourceContext = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-2',
      );
      await pair.source.synchronize();
      pair.server.prepareGate!.complete();
      await expectation;
      expect(pair.source.handoff, isNull);
      expect(pair.source.phase, AgentHandoffPhase.idle);
      expect(pair.source.error, isNull);
    },
  );

  test(
    'late target ready reply cannot mutate next account or resume source',
    () async {
      await pair.source.request(pair.targetId);
      pair.server.readyGate = Completer<void>();
      final work = pair.target.synchronize();
      await _flush();
      pair.targetContext = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-2',
      );
      await pair.target.synchronize();
      pair.server.readyGate!.complete();
      await work;
      expect(pair.target.handoff, isNull);
      expect(pair.target.phase, AgentHandoffPhase.idle);
      expect(pair.target.error, isNull);
    },
  );
  test(
    'null reconciliation replays the uncertain prepare with its original key',
    () async {
      pair.server.losePrepareReply = true;
      await expectLater(
        pair.source.request(pair.targetId),
        throwsA(isA<TimeoutException>()),
      );
      pair.server.absentReads = 1;
      await pair.source.synchronize();
      expect(pair.server.prepareIds, hasLength(2));
      expect(pair.server.prepareIds[1], pair.server.prepareIds[0]);
      expect(pair.source.handoff?.handoffId, 'handoff-1');
    },
  );

  test(
    'uncertain prepare cannot replay with a replacement lease proof',
    () async {
      pair.server.losePrepareReply = true;
      await expectLater(
        pair.source.request(pair.targetId),
        throwsA(isA<TimeoutException>()),
      );
      pair.sourceAuthority.abandonLocalAuthority();
      await pair.sourceAuthority.acquire(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        deviceLabel: 'phone',
        platform: 'ios',
        appVersion: '1',
      );
      pair.server.absentReads = 1;
      await pair.source.synchronize();
      expect(pair.server.prepareIds, hasLength(1));
      expect(pair.source.canRequest, isFalse);
      expect(
        pair.source.error.toString(),
        contains('handoff_prepare_authority_changed'),
      );
    },
  );

  for (final rejection in [
    (400, 'VALIDATION_ERROR', true),
    (409, 'STALE_RUNTIME_PRESENCE', true),
    (409, 'REALTIME_SESSION_PENDING', true),
    (409, 'REALTIME_SESSION_BUSY', true),
    (409, 'RUNTIME_HANDOFF_CONFLICT', false),
    (409, 'RUNTIME_HANDOFF_REQUEST_REUSED', false),
    (500, 'INTERNAL_ERROR', false),
  ]) {
    test(
      'prepare ${rejection.$2} only permits reselect for proven noncommit',
      () async {
        final observedBusy = <bool>[];
        pair.source.addListener(() => observedBusy.add(pair.source.isBusy));
        pair.server.prepareRejection = AccountDeviceLeaseRequestException(
          statusCode: rejection.$1,
          code: rejection.$2,
        );
        await expectLater(
          pair.source.request(pair.targetId),
          throwsA(isA<AccountDeviceLeaseRequestException>()),
        );
        expect(pair.source.canRequest, rejection.$3);
        expect(observedBusy.first, isTrue);
        expect(
          observedBusy.last,
          pair.source.isBusy,
          reason: 'listeners must observe the request finally releasing busy',
        );
        expect(pair.server.handoff, isNull);
        if (rejection.$3) {
          pair.server.prepareRejection = null;
          await pair.source.request(pair.targetId);
          expect(pair.source.handoff, isNotNull);
          expect(pair.server.prepareIds[1], isNot(pair.server.prepareIds[0]));
        }
      },
    );
  }

  for (final failure in ['drain', 'exit']) {
    test(
      'precommit $failure failure cancels canonically before source restore',
      () async {
        await pair.prepare();
        pair.sourceBridge.failure = failure;
        await pair.source.synchronize();
        expect(pair.server.state, AccountHandoffState.targetReady);
        expect(
          pair.server.commands,
          isNot(contains(AccountHandoffCommand.sourceExited)),
        );
        expect(pair.sourceBridge.calls, isNot(contains('restore')));
        await pair.source.synchronize();
        expect(pair.server.state, AccountHandoffState.cancelled);
        expect(pair.sourceBridge.calls, contains('restore'));
        expect(pair.sourceBridge.hidden, isFalse);
        if (failure == 'drain') {
          expect(pair.sourceBridge.calls, isNot(contains('exit')));
        }
      },
    );
  }

  test(
    'cancelled source stays busy through failed and delayed restore retry',
    () async {
      await pair.prepare();
      pair.sourceBridge.failure = 'exit';
      await pair.source.synchronize();
      pair.sourceBridge.failure = 'restore';
      await pair.source.synchronize();
      expect(pair.server.state, AccountHandoffState.cancelled);
      expect(pair.source.phase, AgentHandoffPhase.failed);
      expect(pair.source.isBusy, isTrue);
      expect(pair.source.canRequest, isFalse);

      pair.sourceBridge.failure = null;
      pair.sourceBridge.restoreGate = Completer<void>();
      final retry = pair.source.synchronize();
      await _flush();
      expect(
        pair.sourceBridge.calls.where((c) => c == 'restore'),
        hasLength(2),
      );
      expect(pair.source.isBusy, isTrue);
      expect(pair.source.canRequest, isFalse);
      pair.sourceBridge.restoreGate!.complete();
      await retry;
      expect(pair.source.isBusy, isFalse);
      expect(pair.source.phase, AgentHandoffPhase.idle);
      expect(pair.source.canRequest, isTrue);
      await pair.source.request(pair.targetId);
      expect(pair.source.phase, AgentHandoffPhase.waitingForTarget);
    },
  );

  test(
    'account retirement releases failed cancellation recovery busy state',
    () async {
      await pair.prepare();
      pair.sourceBridge.failure = 'exit';
      await pair.source.synchronize();
      pair.sourceBridge.failure = 'restore';
      await pair.source.synchronize();
      expect(pair.source.isBusy, isTrue);
      pair.sourceContext = null;
      await pair.source.synchronize();
      expect(pair.source.isBusy, isFalse);
      expect(pair.source.phase, AgentHandoffPhase.idle);
      expect(pair.source.handoff, isNull);
    },
  );

  test(
    'account retirement notifies idle after releasing its busy guard',
    () async {
      await pair.source.request(pair.targetId);
      final observedBusy = <bool>[];
      pair.source.addListener(() => observedBusy.add(pair.source.isBusy));
      // Model an account switch before the new presence has been registered.
      pair.sourceContext = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-2',
      );
      pair.sourceAuthority.abandonLocalAuthority();
      await pair.source.synchronize();
      expect(pair.source.isBusy, isFalse);
      expect(pair.source.phase, AgentHandoffPhase.idle);
      expect(pair.source.handoff, isNull);
      expect(observedBusy, isNotEmpty);
      expect(observedBusy.last, isFalse);
    },
  );

  test(
    'disposed service releases busy state without accepting late restore',
    () async {
      final independent = await _Pair.create();
      await independent.prepare();
      independent.sourceBridge.failure = 'exit';
      await independent.source.synchronize();
      independent.sourceBridge.failure = null;
      independent.sourceBridge.restoreGate = Completer<void>();
      final restore = independent.source.synchronize();
      await _flush();
      expect(independent.source.isBusy, isTrue);
      independent.source.dispose();
      expect(independent.source.isBusy, isFalse);
      independent.sourceBridge.restoreGate!.complete();
      await restore;
      expect(independent.source.canRequest, isFalse);
      independent.target.dispose();
    },
  );

  test(
    'cancel during rendered exit prevents the commit acknowledgement',
    () async {
      await pair.prepare();
      pair.sourceBridge.exitGate = Completer<void>();
      final operation = pair.source.synchronize();
      await _flush();
      await pair.source.cancel();
      pair.sourceBridge.exitGate!.complete();
      await operation;
      expect(pair.sourceBridge.hidden, isTrue);
      expect(
        pair.server.commands,
        isNot(contains(AccountHandoffCommand.sourceExited)),
      );
      await pair.source.synchronize();
      expect(pair.server.state, AccountHandoffState.cancelled);
      expect(pair.sourceBridge.hidden, isFalse);
    },
  );

  test(
    'lost completed acknowledgement keeps the proven entry visible with its exact live lease',
    () async {
      await pair.prepare();
      await pair.source.synchronize();
      pair.server.loseCompletedReply = true;
      await pair.target.synchronize();
      expect(pair.server.state, AccountHandoffState.completed);
      expect(pair.targetBridge.hidden, isFalse);
      await pair.target.synchronize();
      expect(pair.targetBridge.hidden, isFalse);
      expect(pair.target.phase, AgentHandoffPhase.completed);
      expect(
        pair.targetBridge.calls.where((call) => call == 'enter'),
        hasLength(1),
      );
      expect(pair.sourceBridge.calls, isNot(contains('restore')));
    },
  );

  test(
    'lost completed acknowledgement hides when target lease becomes invalid',
    () async {
      await pair.prepare();
      await pair.source.synchronize();
      pair.server.loseCompletedReply = true;
      pair.server.onCompletedFailure = pair.targetAuthority.fence;
      await pair.target.synchronize();
      expect(pair.targetBridge.hidden, isTrue);
      expect(pair.targetBridge.calls.where((c) => c == 'enter'), hasLength(1));
      expect(pair.targetBridge.calls, contains('cancel'));
    },
  );

  test(
    'new presence fences a late reply even when account UUID is the same',
    () async {
      pair.sourceContext = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        presenceSessionId: 'session-old',
      );
      pair.server.prepareGate = Completer<void>();
      final operation = pair.source.request(pair.targetId);
      final failure = expectLater(operation, throwsStateError);
      await _flush();
      pair.sourceContext = const HandoffAccountContext(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        presenceSessionId: 'session-new',
      );
      await pair.source.synchronize();
      pair.server.prepareGate!.complete();
      await failure;
      expect(pair.source.handoff, isNull);
      expect(pair.source.phase, AgentHandoffPhase.idle);
      expect(pair.source.error, isNull);
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _HandoffWorldLifecycle extends AppService
    implements AccountSessionLifecycleService {
  _HandoffWorldLifecycle(this.authority);
  final AccountDeviceLeaseCoordinator authority;
  final _changes = ChangeNotifier();
  @override
  bool get isMounted => true;
  @override
  bool get canExecuteAgent => authority.canAdmitMutations;
  @override
  int get generation => 1;
  @override
  AccountDeviceLeaseReceipt? get activeDeviceLease => authority.currentReceipt;
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

Future<T> _serialize<T>(Future<T> Function() work) => work();
final _now = DateTime.utc(2026, 9, 8, 12);
final _avatar = HandoffAvatarIdentity(modelId: 'bundled', revision: '1');

class _Pair {
  _Pair(this.server, this.sourceAuthority, this.targetAuthority) {
    sourceBridge = _Bridge(sourceAuthority);
    targetBridge = _Bridge(targetAuthority);
    source = _service(sourceAuthority, sourceBridge, () => sourceContext);
    target = _service(targetAuthority, targetBridge, () => targetContext);
  }
  final _Server server;
  final AccountDeviceLeaseCoordinator sourceAuthority, targetAuthority;
  late final _Bridge sourceBridge, targetBridge;
  late final AgentHandoffService source, target;
  HandoffAccountContext? sourceContext = const HandoffAccountContext(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-1',
  );
  HandoffAccountContext? targetContext = const HandoffAccountContext(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-1',
  );
  int ids = 0;
  String get targetId => targetAuthority.currentPresence!.presenceSessionId;
  AgentHandoffService _service(
    AccountDeviceLeaseCoordinator authority,
    _Bridge bridge,
    HandoffAccountContext? Function() context,
  ) => AgentHandoffService(
    authority: authority,
    gateway: server,
    bridge: bridge,
    accountContext: context,
    serializeAuthority: _serialize,
    newRequestId: () => 'command-${++ids}',
    now: () => _now,
  );
  static Future<_Pair> create() async {
    SharedPreferences.setMockInitialValues({
      AppInstallationIdentityService.preferencesKey:
          '0123456789abcdef0123456789abcdef',
    });
    final preferences = await SharedPreferences.getInstance();
    final server = _Server();
    Future<AccountDeviceLeaseCoordinator> peer(int seed, bool holder) async {
      final identity = await AppInstallationIdentityService(
        sharedPreferences: preferences,
        randomBytes: (length) => List.filled(length, seed),
      ).init();
      var entropy = seed;
      final authority = AccountDeviceLeaseCoordinator(
        identity: identity,
        gateway: server,
        randomBytes: (length) => List.filled(length, ++entropy),
        monotonicNow: () => Duration.zero,
        wallClock: () => _now,
      );
      if (holder) {
        await authority.acquire(
          environment: MaasoEnvironment.test,
          accountUuid: 'account-1',
          deviceLabel: 'phone',
          platform: 'ios',
          appVersion: '1',
        );
      } else {
        await authority.openObservationPresence(
          environment: MaasoEnvironment.test,
          accountUuid: 'account-1',
          deviceLabel: 'desktop',
          platform: 'macos',
          appVersion: '1',
        );
      }
      return authority;
    }

    final source = await peer(20, true);
    final target = await peer(40, false);
    return _Pair(server, source, target);
  }

  Future<void> prepare() async {
    await source.request(targetId);
    await target.synchronize();
  }

  void close() {
    source.dispose();
    target.dispose();
  }
}

class _Bridge implements AgentHandoffRuntimeBridge {
  _Bridge(this.authority);
  final AccountDeviceLeaseCoordinator authority;
  final calls = <String>[];
  bool hidden = false, allocated = false;
  bool failPrepare = false, failEnterAfterReveal = false, failMountOnce = false;
  String? failure;
  Completer<void>? prepareGate, drainGate, exitGate, enterGate, restoreGate;
  @override
  bool get isAvailable => true;
  @override
  Future<HandoffAvatarIdentity> currentAvatar() async => _avatar;
  @override
  Future<void> prepareTarget(AccountDeviceHandoff h) async {
    calls.add('prepare');
    allocated = true;
    hidden = true;
    await prepareGate?.future;
    if (failPrepare) throw StateError('partial_prepare_failed');
  }

  @override
  Future<void> quiesceSource(AccountDeviceHandoff h) async {
    calls.add('drain');
    await drainGate?.future;
    if (failure == 'drain') throw StateError('preflight_failed');
  }

  @override
  Future<void> exitSource(AccountDeviceHandoff h) async {
    calls.add('exit');
    await exitGate?.future;
    hidden = true;
    if (failure == 'exit') throw StateError('exit_failed');
  }

  @override
  Future<void> retireSource(AccountDeviceHandoff h) async {
    calls.add('retire');
  }

  @override
  Future<void> mountTarget(AccountDeviceHandoff h) async {
    calls.add('mount');
    if (authority.hasTransferredLeaseAwaitingMount) {
      authority.consumeTransferredLeaseForMount();
    }
    if (failMountOnce) {
      failMountOnce = false;
      throw StateError('mount_failed');
    }
  }

  @override
  Future<void> enterTarget(AccountDeviceHandoff h) async {
    calls.add('enter');
    hidden = false;
    await enterGate?.future;
    if (failEnterAfterReveal) throw StateError('enter_reply_lost');
  }

  @override
  Future<void> restoreSource(AccountDeviceHandoff h) async {
    calls.add('restore');
    await restoreGate?.future;
    if (failure == 'restore') throw StateError('restore_failed');
    hidden = false;
  }

  @override
  Future<void> cancelTarget(AccountDeviceHandoff h) async {
    calls.add('cancel');
    hidden = true;
    allocated = false;
  }
}

class _Server
    implements AccountDeviceLeaseGateway, AccountDeviceHandoffGateway {
  final presences = <String, AccountDevicePresenceReceipt>{};
  final commands = <AccountHandoffCommand>[];
  AccountDeviceLeaseReceipt? lease;
  AccountDeviceHandoff? handoff;
  AccountHandoffState? get state => handoff?.state;
  bool losePrepareReply = false,
      loseExitReply = false,
      loseCompletedReply = false;
  bool failInspect = false;
  int absentReads = 0;
  final prepareIds = <Object?>[];
  AccountDeviceLeaseRequestException? prepareRejection;
  void Function()? onCompletedFailure;
  Completer<void>? prepareGate, readyGate;

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: lease,
  );

  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async {
    final receipt = AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence-${presences.length + 1}',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: _now,
      lastSeenAt: _now,
      expiresAt: _now.add(const Duration(minutes: 1)),
      remainingTtl: const Duration(minutes: 1),
      renewAfter: const Duration(seconds: 20),
    );
    presences[receipt.presenceSessionId] = receipt;
    return AccountDevicePresenceOperationResult(
      presence: receipt,
      replayed: false,
    );
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async =>
      AccountDevicePresenceOperationResult(presence: presence, replayed: false);
  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    lease = _lease(presences[presenceSessionId]!, 1);
    return AccountDeviceLeaseOperationResult(lease: lease!, replayed: false);
  }

  @override
  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  }) async {
    if (failInspect) throw StateError('discovery temporarily unavailable');
    if (absentReads > 0) {
      absentReads--;
      return const AccountHandoffResult(handoff: null, replayed: false);
    }
    return AccountHandoffResult(handoff: handoff, replayed: false);
  }

  @override
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  }) async {
    commands.add(command);
    switch (command) {
      case AccountHandoffCommand.prepare:
        prepareIds.add(body['requestId']);
        if (prepareRejection != null) throw prepareRejection!;
        final target = presences[body['targetPresenceSessionId']]!;
        handoff = AccountDeviceHandoff(
          handoffId: 'handoff-1',
          agentId: 'self',
          state: AccountHandoffState.prepared,
          sourceLeaseId: lease!.leaseId,
          sourceEpoch: lease!.epoch,
          sourcePresenceSessionId: lease!.presenceSessionId,
          sourceRuntimeInstanceId: lease!.runtimeInstanceId,
          targetPresenceSessionId: target.presenceSessionId,
          targetRuntimeInstanceId: target.runtimeInstanceId,
          avatarModel: _avatar,
          createdAt: _now,
          expiresAt: _now.add(const Duration(seconds: 30)),
          remainingTtl: const Duration(seconds: 30),
        );
        await prepareGate?.future;
        if (losePrepareReply) {
          losePrepareReply = false;
          throw TimeoutException('prepare_reply_lost');
        }
      case AccountHandoffCommand.targetReady:
        _state(AccountHandoffState.targetReady);
        await readyGate?.future;
      case AccountHandoffCommand.sourceExited:
        lease = _lease(presences[handoff!.targetPresenceSessionId]!, 2);
        _state(AccountHandoffState.accepted);
        if (loseExitReply) {
          loseExitReply = false;
          throw TimeoutException('exit_reply_lost');
        }
      case AccountHandoffCommand.completed:
        _state(AccountHandoffState.completed);
        if (loseCompletedReply) {
          loseCompletedReply = false;
          onCompletedFailure?.call();
          throw TimeoutException('completed_reply_lost');
        }
      case AccountHandoffCommand.cancel:
        if (!handoff!.isCommitted) _state(AccountHandoffState.cancelled);
    }
    return AccountHandoffResult(handoff: handoff, replayed: false);
  }

  void _state(AccountHandoffState state) {
    final h = handoff!;
    handoff = AccountDeviceHandoff(
      handoffId: h.handoffId,
      agentId: h.agentId,
      state: state,
      sourceLeaseId: h.sourceLeaseId,
      sourceEpoch: h.sourceEpoch,
      sourcePresenceSessionId: h.sourcePresenceSessionId,
      sourceRuntimeInstanceId: h.sourceRuntimeInstanceId,
      targetPresenceSessionId: h.targetPresenceSessionId,
      targetRuntimeInstanceId: h.targetRuntimeInstanceId,
      avatarModel: h.avatarModel,
      createdAt: h.createdAt,
      expiresAt: h.expiresAt,
      remainingTtl: h.remainingTtl,
      lease:
          state == AccountHandoffState.accepted ||
              state == AccountHandoffState.completed
          ? lease
          : null,
    );
  }

  AccountDeviceLeaseReceipt _lease(
    AccountDevicePresenceReceipt presence,
    int epoch,
  ) => AccountDeviceLeaseReceipt(
    agentId: 'self',
    leaseId: 'lease-$epoch',
    epoch: epoch,
    installationId: presence.installationId,
    runtimeInstanceId: presence.runtimeInstanceId,
    presenceSessionId: presence.presenceSessionId,
    expiresAt: _now.add(const Duration(seconds: 45)),
    remainingTtl: const Duration(seconds: 45),
    renewAfter: const Duration(seconds: 15),
    holder: presence.toHolder(),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
