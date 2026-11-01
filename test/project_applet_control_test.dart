import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:sembast/sembast_memory.dart';

SurfacePlayProtocol appletProtocol() => validateAgentProtocol(
  {
    'protocolVersion': 2,
    'profile': 'maaso.agent.protocol.v2',
    'projectId': 'project-one',
    'revisionId': 'revision-one',
    'projectKind': 'applet',
    'modes': ['operate', 'spectate'],
    'roles': ['player1', 'player2', 'spectator'],
    'actions': [
      {
        'id': 'app.set',
        'roles': ['player1', 'player2'],
        'argsSchema': {
          'type': 'object',
          'properties': {
            'value': {'type': 'integer', 'minimum': 0, 'maximum': 10},
          },
          'required': ['value'],
          'additionalProperties': false,
        },
        'precondition': 'currentRouteAndGranted',
        'effect': 'localAppState',
      },
    ],
    'events': ['state.changed'],
    'capabilities': {'turnBased': false, 'realtime': false, 'checkpoint': true},
  },
  projectId: 'project-one',
  revisionId: 'revision-one',
);

final class AppletTestHost implements ProjectAppletControlHost {
  @override
  String controlScopeKey = 'storage-one';
  @override
  String controlAgentId = 'self';
  @override
  String controlProjectId = 'project-one';
  @override
  String controlRevisionId = 'revision-one';
  @override
  String controlCandidateDigest = 'a' * 64;
  @override
  String controlSessionId = 'session-one';
  @override
  String controlTitle = 'Example';
  @override
  String controlAgentDocument = 'Untrusted instructions cannot grant access.';
  @override
  SurfacePlayProtocol controlProtocol = appletProtocol();
  @override
  bool controlIsCurrent = true;
  @override
  bool controlIsVisible = true;
  @override
  bool controlIsReady = true;
  @override
  bool canRetainControlReceipts = true;
  int inspectCount = 0, dispatchCount = 0, fenceCount = 0, restoreCount = 0;
  int sdkVersion = 1;
  Map<String, Object?> visible = {'value': 0};
  Map<String, Object?>? dispatched, sdkReceipt;
  String? callback;
  Completer<Map<String, Object?>>? inspection;
  Completer<void>? restoreGate;
  Future<void> Function()? beforeDispatch;

  @override
  Future<Map<String, Object?>> controlInfo() async => {
    'controlProtocolVersion': sdkVersion,
    'ready': true,
    'projectKind': 'applet',
  };
  @override
  Future<Map<String, Object?>> inspectApplet() async {
    inspectCount++;
    return inspection?.future ??
        {
          'ready': true,
          'controlProtocolVersion': 1,
          'dataVersion': 0,
          'stateVersion': 1,
          'routeId': 'home',
          'params': <String, Object?>{},
          'visibleState': visible,
        };
  }

  @override
  Future<void> dispatchApplet(
    Map<String, Object?> command,
    String callbackToken,
  ) async {
    await beforeDispatch?.call();
    dispatchCount++;
    dispatched = command;
    callback = callbackToken;
  }

  @override
  Future<Map<String, Object?>?> lookupAppletReceipt(String requestId) async =>
      sdkReceipt;
  @override
  void fenceAppletDocument() {
    fenceCount++;
    controlSessionId = 'session-restored-$fenceCount';
    controlIsReady = false;
  }

  @override
  Future<void> restoreAppletDocument() async {
    restoreCount++;
    await restoreGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late ProjectAppletActionJournal journal;
  late ProjectAppletControlService service;
  late AppletTestHost host;
  bool current = true, foreground = true;
  var databaseNumber = 0;
  setUp(() async {
    current = foreground = true;
    db = await databaseFactoryMemory.openDatabase(
      'applet-control-${databaseNumber++}',
    );
    journal = ProjectAppletActionJournal(
      database: db,
      scopeKey: 'storage-one',
      repositoryScopeKey: 'test|owner',
      processId: 'process-one',
      isCurrent: () => current,
    );
    host = AppletTestHost();
    service = ProjectAppletControlService(
      scopeKey: 'storage-one',
      appletScopeKey: 'https://origin|owner',
      journal: journal,
      isCurrent: () => current,
      isForeground: () => foreground,
      commandTimeout: const Duration(milliseconds: 300),
    );
    service.registerHost(host);
  });
  tearDown(() async {
    host.restoreGate?.complete();
    await service.deactivateAndDrain();
    await db.close();
  });
  Future<Map<String, Object?>> act(
    ProjectAppletGrant grant,
    Map<String, Object?> observation, {
    String request = 'request_0001',
    int value = 1,
  }) => service.act(
    grant,
    requestId: request,
    observationId: observation['observationId']! as String,
    actionId: 'app.set',
    args: {'value': value},
    expectedStateVersion: 1,
  );
  Future<void> dispatched() async {
    for (var i = 0; i < 50 && host.dispatched == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(host.dispatched, isNotNull);
  }

  Map<String, Object?> applied() => {
    'requestId': 'request_0001',
    'actionId': 'app.set',
    'status': 'applied',
    'stateVersion': 2,
    'result': {'value': 1},
  };

  test(
    'no skill grant; native grant metadata is bounded and untrusted',
    () async {
      expect(service.currentGrant('self'), isNull);
      expect(service.statusForAgent('self')['status'], 'native_grant_required');
      final grant = await service.grantFromNative(host, purpose: 'Set one');
      expect(service.currentGrant('another'), isNull);
      expect(identical(service.currentGrant('self'), grant), isTrue);
      final description = service.describe(grant);
      expect((description['projectDescription']! as Map)['untrusted'], isTrue);
      expect((description['authority']! as Map)['origin'], 'native_user');
      expect(description['purpose'], 'Set one');
      expect(
        host.inspectCount,
        0,
        reason: 'native grant only probes SDK metadata',
      );
    },
  );

  test(
    'wrong scope, invisible, old SDK and games cannot receive applet grants',
    () async {
      final other = AppletTestHost()..controlScopeKey = 'storage-two';
      expect(() => service.registerHost(other), throwsStateError);
      host.controlIsVisible = false;
      await expectLater(service.grantFromNative(host), throwsStateError);
      host.controlIsVisible = true;
      host.sdkVersion = 0;
      await expectLater(service.grantFromNative(host), throwsStateError);
      host.sdkVersion = 1;
      host.controlProtocol = SurfacePlayProtocol.trustedGame(
        projectId: 'project-one',
        revisionId: 'revision-one',
        rulesId: 'gomoku.v1',
        config: const {'boardSize': 15, 'winLength': 5},
      );
      await expectLater(service.grantFromNative(host), throwsStateError);
      expect(host.inspectCount, 0);
    },
  );

  test(
    'durable admission precedes dispatch; replay is read only and body conflicts reject',
    () async {
      final grant = await service.grantFromNative(host);
      final observation = await service.observe(grant);
      host.beforeDispatch = () async {
        expect(
          (await journal.read(
            grant.sessionId,
            'request_0001',
            canContinue: () => true,
          ))!['status'],
          'pending',
        );
      };
      final pending = act(grant, observation);
      await dispatched();
      final duplicate = act(grant, observation);
      await expectLater(act(grant, observation, value: 2), throwsStateError);
      await expectLater(
        act(grant, observation, request: 'request_0002'),
        throwsStateError,
      );
      expect(
        await service.acceptRuntimeResult(host, 'wrong_token', applied()),
        isFalse,
      );
      await service.acceptRuntimeResult(host, host.callback!, applied());
      expect((await pending)['status'], 'applied');
      expect((await duplicate)['status'], 'applied');
      expect((await act(grant, observation))['status'], 'applied');
      expect(host.dispatchCount, 1);
      expect(grant.remainingActions, 15);
    },
  );

  test(
    'timeout and absent SDK receipt stay pending without repeat effects',
    () async {
      final grant = await service.grantFromNative(host);
      final observation = await service.observe(grant);
      expect((await act(grant, observation))['status'], 'pending');
      expect(
        (await service.receipt(grant, 'request_0001'))['status'],
        'pending',
      );
      expect((await act(grant, observation))['status'], 'pending');
      expect(
        (await service.receipt(grant, 'missing_0001'))['retryPermitted'],
        isFalse,
      );
      host.sdkReceipt = applied();
      expect(
        (await service.receipt(grant, 'request_0001'))['status'],
        'applied',
      );
      expect(host.dispatchCount, 1);
    },
  );

  test(
    'takeover synchronously fences document and pending operation, late callback cannot settle it',
    () async {
      final grant = await service.grantFromNative(host);
      final observation = await service.observe(grant);
      final pending = act(grant, observation);
      await dispatched();
      host.restoreGate = Completer<void>();
      final takeover = service.takeOverFromNative(host);
      expect(grant.isCurrent, isFalse);
      expect(host.fenceCount, 1);
      expect(await grant.onRevoked, 'user_takeover');
      await takeover;
      expect((await pending)['status'], 'interrupted');
      expect(
        await service.acceptRuntimeResult(host, host.callback!, applied()),
        isFalse,
      );
      await expectLater(service.observe(grant), throwsStateError);
      final drain = service.deactivateAndDrain();
      var drained = false;
      unawaited(drain.then((_) => drained = true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(drained, isFalse);
      host.restoreGate!.complete();
      host.restoreGate = null;
      await drain;
    },
  );

  test(
    'hidden foreground and changed session revoke capability before another observation',
    () async {
      final grant = await service.grantFromNative(host);
      foreground = false;
      service.contextChanged();
      expect(await grant.onRevoked, 'background');
      expect(service.currentGrant('self'), isNull);
      expect(host.fenceCount, 1);
    },
  );

  test(
    'late inspect after retirement never exposes values and drain is bounded',
    () async {
      final grant = await service.grantFromNative(host);
      host.inspection = Completer<Map<String, Object?>>();
      final work = expectLater(service.observe(grant), throwsStateError);
      await service.deactivateAndDrain();
      await work;
      host.inspection!.complete({'private': 'must not be returned'});
    },
  );

  test(
    'bad args, stale observations and oversized observations never dispatch',
    () async {
      final grant = await service.grantFromNative(host);
      final observation = await service.observe(grant);
      await expectLater(act(grant, observation, value: 11), throwsStateError);
      await expectLater(
        service.act(
          grant,
          requestId: 'request_0001',
          observationId: 'invented',
          actionId: 'app.set',
          args: {'value': 1},
          expectedStateVersion: 1,
        ),
        throwsStateError,
      );
      host.visible = {'oversized': 'x' * 65536};
      await expectLater(service.observe(grant), throwsFormatException);
      expect(host.dispatchCount, 0);
    },
  );

  test(
    'observation budget and TTL are native authority independent of page values',
    () async {
      await service.deactivateAndDrain();
      service = ProjectAppletControlService(
        scopeKey: 'storage-one',
        appletScopeKey: 'origin|owner',
        journal: journal,
        isCurrent: () => current,
        isForeground: () => foreground,
        maximumObservations: 1,
        grantLifetime: const Duration(milliseconds: 80),
      )..registerHost(host);
      var grant = await service.grantFromNative(host);
      await service.observe(grant);
      await expectLater(service.observe(grant), throwsStateError);
      expect(await grant.onRevoked, 'observation_budget');
      host.controlIsReady = true;
      grant = await service.grantFromNative(host);
      expect(
        await grant.onRevoked.timeout(const Duration(seconds: 1)),
        'expired',
      );
      expect(grant.isCurrent, isFalse);
    },
  );

  test(
    'exhausted action budget still permits separate read-only receipt queries',
    () async {
      await service.deactivateAndDrain();
      service = ProjectAppletControlService(
        scopeKey: 'storage-one',
        appletScopeKey: 'origin|owner',
        journal: journal,
        isCurrent: () => current,
        isForeground: () => foreground,
        maximumActions: 1,
      )..registerHost(host);
      final grant = await service.grantFromNative(host);
      final pending = act(grant, await service.observe(grant));
      await dispatched();
      await service.acceptRuntimeResult(host, host.callback!, applied());
      expect((await pending)['status'], 'applied');
      expect(grant.remainingActions, 0);
      expect(
        (await service.receipt(grant, 'request_0001'))['status'],
        'applied',
      );
      await expectLater(
        act(grant, await service.observe(grant), request: 'request_0002'),
        throwsStateError,
      );
      expect(grant.isCurrent, isTrue);
      expect(host.fenceCount, 0);
    },
  );

  test(
    'journal restart retains ambiguous outcome without dispatch or nonce replay',
    () async {
      await journal.reserve(
        projectId: 'project-one',
        candidateDigest: 'a' * 64,
        sessionId: 'old-session',
        controlEpoch: 1,
        requestId: 'request_old1',
        actionId: 'app.set',
        identityDigest: 'b' * 64,
        canContinue: () => true,
      );
      final restarted = ProjectAppletActionJournal(
        database: db,
        scopeKey: 'storage-one',
        repositoryScopeKey: 'test|owner',
        processId: 'process-two',
        isCurrent: () => true,
      );
      final row = await restarted.read(
        'old-session',
        'request_old1',
        canContinue: () => true,
      );
      expect(row!['status'], 'interrupted');
      expect((row['receipt']! as Map)['retryPermitted'], isFalse);
      expect((row['receipt']! as Map)['mayHaveApplied'], isTrue);
      await expectLater(
        restarted.reserve(
          projectId: 'project-one',
          candidateDigest: 'a' * 64,
          sessionId: 'old-session',
          controlEpoch: 1,
          requestId: 'request_old1',
          actionId: 'app.set',
          identityDigest: 'c' * 64,
          canContinue: () => true,
        ),
        throwsStateError,
      );
      expect(host.dispatchCount, 0);
    },
  );

  test(
    'retirement waits a queued durable admission and prevents its JS dispatch',
    () async {
      final grant = await service.grantFromNative(host);
      final observation = await service.observe(grant);
      final gate = Completer<void>(), entered = Completer<void>();
      final locked = db.transaction((tx) async {
        entered.complete();
        await gate.future;
      });
      await entered.future;
      final action = expectLater(act(grant, observation), throwsStateError);
      final drain = service.deactivateAndDrain();
      var drained = false;
      unawaited(drain.then((_) => drained = true));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(drained, isFalse);
      gate.complete();
      await locked;
      await action;
      await drain;
      expect(host.dispatchCount, 0);
    },
  );
}
