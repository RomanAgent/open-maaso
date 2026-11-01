import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';

void main() {
  test(
    'joinAgent joins RTC with backend session config and connects actions',
    () async {
      final events = <String>[];
      final session = _legacySession();
      final rtc = _FakeRtcAdapter(events);
      AppLocale? createLocale;
      AppLocale? streamLocale;
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) async {
              createLocale = locale;
              events.add('create:$agentId:$userId:$resumeAfterSequence');
              return session;
            },
        rtcAdapter: rtc,
        connectActions: (session, {authority, agentId = 'self', locale}) async {
          streamLocale = locale;
          events.add('actions:$agentId:${session.actionStreamUri}');
        },
        disconnectActions: () async {
          events.add('actions:disconnect');
        },
        requestIdGenerator: () => 'rrs_legacy_0001',
      );

      final joined = await service.joinAgent(agentId: 'self', userId: 'user_1');

      expect(joined, same(session));
      expect(service.isJoined.value, isTrue);
      expect(service.currentSession.value, same(session));
      expect(rtc.config?.appId, 'volc-app-id');
      expect(rtc.config?.roomId, 'room_1');
      expect(rtc.config?.userId, 'user_1');
      expect(rtc.config?.token, 'token_1');
      expect(rtc.config?.agentUserId, session.agentUserId);
      expect(createLocale, AppLocale.en);
      expect(streamLocale, same(createLocale));
      expect(events, <String>[
        'create:self:user_1:0',
        'rtc:join:room_1',
        'actions:self:https://api.example.test/actions',
      ]);
    },
  );

  test(
    'retry and leave-rejoin replay until the authority tuple changes',
    () async {
      final fixture = await _authorityFixture();
      var activeAuthority = fixture.coordinator
          .requireCurrentRequestAuthority();
      final session = _fencedSession(leaseEpoch: activeAuthority.leaseEpoch);
      var activeSession = session;
      final requestIds = <String>[];
      final resumeCursors = <int>[];
      final cursorReads = <RealtimeSession>[];
      var generatedIds = 0;
      var connectCalls = 0;
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) async {
              requestIds.add(requestId);
              resumeCursors.add(resumeAfterSequence);
              expect(authority, same(activeAuthority));
              return activeSession;
            },
        rtcAdapter: _FakeRtcAdapter(<String>[]),
        connectActions:
            (connected, {authority, agentId = 'self', locale}) async {
              expect(connected, same(activeSession));
              expect(authority, same(activeAuthority));
              connectCalls += 1;
              if (connectCalls == 1) throw StateError('stream unavailable');
            },
        disconnectActions: () async {},
        authorityProvider: () => activeAuthority,
        readCursor: (prior) async {
          cursorReads.add(prior);
          return 73;
        },
        requestIdGenerator: () => 'rrs_test_${++generatedIds}',
      );

      await expectLater(
        service.joinAgent(agentId: 'self', userId: 'user_1'),
        throwsStateError,
      );
      await service.joinAgent(agentId: 'self', userId: 'user_1');

      expect(requestIds, <String>['rrs_test_1', 'rrs_test_1']);
      expect(resumeCursors, <int>[0, 73]);
      expect(cursorReads, <RealtimeSession>[session]);

      await service.leave();
      await service.joinAgent(agentId: 'self', userId: 'user_1');

      expect(requestIds, <String>['rrs_test_1', 'rrs_test_1', 'rrs_test_1']);
      expect(resumeCursors, <int>[0, 73, 73]);
      expect(cursorReads, <RealtimeSession>[session, session]);

      await service.leave();
      final replacement = await _authorityFixture(entropySeed: 41);
      activeAuthority = replacement.coordinator
          .requireCurrentRequestAuthority();
      activeSession = _fencedSession(
        sessionId: 'ms_fenced_0002',
        leaseEpoch: activeAuthority.leaseEpoch,
      );
      await service.joinAgent(agentId: 'self', userId: 'user_1');

      expect(requestIds.last, 'rrs_test_2');
      expect(resumeCursors.last, 0);
      expect(cursorReads, <RealtimeSession>[session, session]);
    },
  );

  test('holder proof is never included in Volc join configuration', () async {
    final fixture = await _authorityFixture();
    final leaseAuthority = fixture.coordinator.requireCurrentRequestAuthority();
    final session = _fencedSession(leaseEpoch: leaseAuthority.leaseEpoch);
    final rtc = _FakeRtcAdapter(<String>[]);
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => session,
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {},
      disconnectActions: () async {},
      authorityProvider: () => leaseAuthority,
      readCursor: (_) async => 0,
      requestIdGenerator: () => 'rrs_proof_fence',
    );

    await service.joinAgent(agentId: 'self');

    final config = rtc.config!;
    final proof = fixture.gateway.holderProof!;
    expect(<String>[
      config.appId,
      config.roomId,
      config.userId,
      config.token,
    ], everyElement(isNot(contains(proof))));
    expect(config.toString(), isNot(contains(proof)));
  });

  test('authority fenced after session creation blocks Volc join', () async {
    final fixture = await _authorityFixture();
    final leaseAuthority = fixture.coordinator.requireCurrentRequestAuthority();
    final events = <String>[];
    final failures = <Object>[];
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async {
            fixture.coordinator.fence();
            return _fencedSession(leaseEpoch: leaseAuthority.leaseEpoch);
          },
      rtcAdapter: _FakeRtcAdapter(events),
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
      },
      disconnectActions: () async {
        events.add('actions:disconnect');
      },
      authorityProvider: () => leaseAuthority,
      readCursor: (_) async => 0,
      onAuthorityFailure: failures.add,
    );

    await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);

    expect(events, isEmpty);
    expect(failures, hasLength(1));
    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
  });

  test('authority fenced by Volc join blocks actions and leaves RTC', () async {
    final fixture = await _authorityFixture();
    final leaseAuthority = fixture.coordinator.requireCurrentRequestAuthority();
    final events = <String>[];
    final failures = <Object>[];
    final rtc = _FakeRtcAdapter(
      events,
      onJoin: (_) => fixture.coordinator.fence(),
    );
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _fencedSession(leaseEpoch: leaseAuthority.leaseEpoch),
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
      },
      disconnectActions: () async {
        events.add('actions:disconnect');
      },
      authorityProvider: () => leaseAuthority,
      readCursor: (_) async => 0,
      onAuthorityFailure: failures.add,
    );

    await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);

    expect(events, <String>['rtc:join:room_1', 'rtc:leave']);
    expect(failures, hasLength(1));
    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
  });

  test('leave disconnects actions before leaving RTC room', () async {
    final events = <String>[];
    final rtc = _FakeRtcAdapter(events);
    final service = _legacyService(
      rtc: rtc,
      disconnectActions: () async {
        events.add('actions:disconnect');
      },
    );

    await service.leave();

    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
    expect(events, <String>['actions:disconnect', 'rtc:leave']);
  });

  test('failed session creation leaves no active realtime state', () async {
    final events = <String>[];
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => throw StateError('session down'),
      rtcAdapter: _FakeRtcAdapter(events),
      connectActions: (session, {authority, agentId = 'self', locale}) async {},
      disconnectActions: () async {
        events.add('actions:disconnect');
      },
    );

    await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);

    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
    expect(events, isEmpty);
  });

  test('action stream failure cleans up actions and joined RTC room', () async {
    final events = <String>[];
    final rtc = _FakeRtcAdapter(events);
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _legacySession(),
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
        throw StateError('stream down');
      },
      disconnectActions: () async {
        events.add('actions:disconnect');
      },
    );

    await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);

    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
    expect(events, <String>[
      'rtc:join:room_1',
      'actions:connect',
      'actions:disconnect',
      'rtc:leave',
    ]);
  });

  test(
    'dispose waits for an admitted join and prevents late publish',
    () async {
      final events = <String>[];
      final createStarted = Completer<void>();
      final createRelease = Completer<RealtimeSession>();
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) {
              createStarted.complete();
              return createRelease.future;
            },
        rtcAdapter: _FakeRtcAdapter(events),
        connectActions: (session, {authority, agentId = 'self', locale}) async {
          events.add('actions:connect');
        },
        disconnectActions: () async {
          events.add('actions:disconnect');
        },
      );

      final joining = service.joinAgent(agentId: 'self');
      final joiningExpectation = expectLater(joining, throwsStateError);
      await createStarted.future;
      var disposeDone = false;
      final disposing = service.dispose().then((_) => disposeDone = true);

      await Future<void>.delayed(Duration.zero);
      expect(disposeDone, isFalse);

      createRelease.complete(_legacySession());
      await joiningExpectation;
      await disposing;

      expect(service.isJoined.value, isFalse);
      expect(service.currentSession.value, isNull);
      expect(events, isNot(contains('rtc:join:room_1')));
      expect(events, isNot(contains('actions:connect')));
    },
  );

  test('dispose waits for an admitted leave operation', () async {
    final events = <String>[];
    final disconnectStarted = Completer<void>();
    final disconnectRelease = Completer<void>();
    var disconnectCalls = 0;
    final service = _legacyService(
      rtc: _FakeRtcAdapter(events),
      disconnectActions: () {
        disconnectCalls += 1;
        events.add('actions:disconnect');
        if (disconnectCalls == 1) {
          disconnectStarted.complete();
          return disconnectRelease.future;
        }
        return Future<void>.value();
      },
    );

    final leaving = service.leave();
    await disconnectStarted.future;
    var disposeDone = false;
    final disposing = service.dispose().then((_) => disposeDone = true);

    await Future<void>.delayed(Duration.zero);
    expect(disposeDone, isFalse);

    disconnectRelease.complete();
    await leaving;
    await disposing;
    expect(disconnectCalls, 2);
  });

  test('dispose fences late joins and is idempotent after success', () async {
    var createCalls = 0;
    final rtc = _CountingRtcAdapter();
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async {
            createCalls += 1;
            return _legacySession();
          },
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {},
      disconnectActions: () async {},
    );

    await service.dispose();
    await service.dispose();

    await expectLater(
      Future<RealtimeSession>.sync(() => service.joinAgent(agentId: 'self')),
      throwsStateError,
    );
    expect(createCalls, 0);
    expect(rtc.disposeCalls, 1);
  });

  test('dispose retries cleanup after an adapter failure', () async {
    final rtc = _CountingRtcAdapter(failFirstDispose: true);
    final service = _legacyService(rtc: rtc);

    await expectLater(service.dispose(), throwsStateError);
    await service.dispose();

    expect(rtc.disposeCalls, 2);
  });

  test(
    'leave during session creation prevents native join and publish',
    () async {
      final events = <String>[];
      final createEntered = Completer<void>();
      final releaseCreate = Completer<RealtimeSession>();
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) {
              createEntered.complete();
              return releaseCreate.future;
            },
        rtcAdapter: _FakeRtcAdapter(events),
        connectActions: (session, {authority, agentId = 'self', locale}) async {
          events.add('actions:connect');
        },
        disconnectActions: () async => events.add('actions:disconnect'),
      );

      final joining = service.joinAgent(agentId: 'self');
      final joinExpectation = expectLater(joining, throwsStateError);
      await createEntered.future;
      final leaving = service.leave();
      releaseCreate.complete(_legacySession());

      await joinExpectation;
      await leaving;
      expect(events, isNot(contains('rtc:join:room_1')));
      expect(events, isNot(contains('actions:connect')));
      expect(service.isJoined.value, isFalse);
      expect(service.currentSession.value, isNull);
    },
  );

  test('leave during native join prevents late action connection', () async {
    final events = <String>[];
    final joinEntered = Completer<void>();
    final releaseJoin = Completer<void>();
    final rtc = _FakeRtcAdapter(
      events,
      onJoin: (_) async {
        joinEntered.complete();
        await releaseJoin.future;
      },
    );
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _legacySession(),
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
      },
      disconnectActions: () async => events.add('actions:disconnect'),
    );

    final joining = service.joinAgent(agentId: 'self');
    final joinExpectation = expectLater(joining, throwsStateError);
    await joinEntered.future;
    var leaveDone = false;
    final leaving = service.leave().then((_) => leaveDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('rtc:leave'));
    expect(leaveDone, isFalse);

    releaseJoin.complete();
    await joinExpectation;
    await leaving;
    expect(events, isNot(contains('actions:connect')));
    expect(service.isJoined.value, isFalse);
  });

  test('leave during action connect blocks late joined publication', () async {
    final events = <String>[];
    final connectEntered = Completer<void>();
    final releaseConnect = Completer<void>();
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _legacySession(),
      rtcAdapter: _FakeRtcAdapter(events),
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
        connectEntered.complete();
        await releaseConnect.future;
      },
      disconnectActions: () async => events.add('actions:disconnect'),
    );

    final joining = service.joinAgent(agentId: 'self');
    final joinExpectation = expectLater(joining, throwsStateError);
    await connectEntered.future;
    final leaving = service.leave();
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('rtc:leave'));
    expect(events, contains('actions:disconnect'));

    releaseConnect.complete();
    await joinExpectation;
    await leaving;
    expect(service.isJoined.value, isFalse);
    expect(service.currentSession.value, isNull);
    expect(events.where((event) => event == 'actions:disconnect'), isNotEmpty);
  });

  test('stable leave stops RTC without waiting for action drain', () async {
    final events = <String>[];
    final disconnectEntered = Completer<void>();
    final releaseDisconnect = Completer<void>();
    final service = _legacyService(
      rtc: _FakeRtcAdapter(events),
      disconnectActions: () async {
        events.add('actions:disconnect');
        disconnectEntered.complete();
        await releaseDisconnect.future;
      },
    );

    final first = service.leave();
    final second = service.leave();
    expect(second, same(first));
    await disconnectEntered.future;
    await _eventually(() => events.contains('rtc:leave'));
    expect(events, <String>['actions:disconnect', 'rtc:leave']);

    releaseDisconnect.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(events, <String>['actions:disconnect', 'rtc:leave']);
  });

  test(
    'terminal RTC event clears publication and retires both paths',
    () async {
      final events = <String>[];
      final disconnectEntered = Completer<void>();
      final releaseDisconnect = Completer<void>();
      final rtc = _FakeRtcAdapter(events);
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) async => _legacySession(),
        rtcAdapter: rtc,
        connectActions: (session, {authority, agentId = 'self', locale}) async {
          events.add('actions:connect');
        },
        disconnectActions: () async {
          events.add('actions:disconnect');
          if (!disconnectEntered.isCompleted) disconnectEntered.complete();
          await releaseDisconnect.future;
        },
      );
      await service.joinAgent(agentId: 'self');
      events.clear();

      rtc.emitTerminal(
        const VolcRtcTerminalEvent(roomId: 'room_1', reason: 'token_expired'),
      );
      await disconnectEntered.future;
      await _eventually(() => events.contains('rtc:leave'));

      expect(service.isJoined.value, isFalse);
      expect(service.currentSession.value, isNull);
      expect(service.error.value, contains('token_expired'));
      expect(events, <String>['actions:disconnect', 'rtc:leave']);

      releaseDisconnect.complete();
      await service.leave();
    },
  );

  test('terminal event from another room is ignored', () async {
    final events = <String>[];
    final rtc = _FakeRtcAdapter(events);
    final service = VolcRtcSessionService.raw(
      createSession:
          ({
            required agentId,
            required requestId,
            authority,
            userId,
            locale,
            resumeAfterSequence = 0,
          }) async => _legacySession(),
      rtcAdapter: rtc,
      connectActions: (session, {authority, agentId = 'self', locale}) async {
        events.add('actions:connect');
      },
      disconnectActions: () async => events.add('actions:disconnect'),
    );
    await service.joinAgent(agentId: 'self');
    events.clear();

    rtc.emitTerminal(
      const VolcRtcTerminalEvent(roomId: 'room_old', reason: 'token_expired'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.isJoined.value, isTrue);
    expect(service.currentSession.value?.roomId, 'room_1');
    expect(service.error.value, isNull);
    expect(events, isEmpty);

    await service.leave();
  });

  test(
    'terminal cleanup failure blocks admission until explicit leave retries',
    () async {
      final events = <String>[];
      var createCalls = 0;
      final rtc = _FakeRtcAdapter(events, failedLeaveAttempts: 1);
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) async {
              createCalls++;
              return _legacySession();
            },
        rtcAdapter: rtc,
        connectActions:
            (session, {authority, agentId = 'self', locale}) async {},
        disconnectActions: () async => events.add('actions:disconnect'),
      );
      await service.joinAgent(agentId: 'self');

      rtc.emitTerminal(
        const VolcRtcTerminalEvent(roomId: 'room_1', reason: 'token_expired'),
      );
      await _eventually(() => rtc.leaveCalls == 1);
      await Future<void>.delayed(Duration.zero);

      await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);
      expect(createCalls, 1);

      await service.leave();
      expect(rtc.leaveCalls, 2);
    },
  );

  test(
    'early cleanup failure is observed while a join is still pending',
    () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final events = <String>[];
        final createEntered = Completer<void>();
        final releaseCreate = Completer<RealtimeSession>();
        final rtc = _FakeRtcAdapter(events, failedLeaveAttempts: 1);
        final service = VolcRtcSessionService.raw(
          createSession:
              ({
                required agentId,
                required requestId,
                authority,
                userId,
                locale,
                resumeAfterSequence = 0,
              }) {
                createEntered.complete();
                return releaseCreate.future;
              },
          rtcAdapter: rtc,
          connectActions:
              (session, {authority, agentId = 'self', locale}) async {},
          disconnectActions: () async {},
        );

        final joining = service.joinAgent(agentId: 'self');
        final joinExpectation = expectLater(joining, throwsStateError);
        await createEntered.future;
        final leaving = service.leave();
        await Future<void>.delayed(Duration.zero);
        expect(uncaught, isEmpty);

        releaseCreate.complete(_legacySession());
        await joinExpectation;
        await leaving;
        expect(rtc.leaveCalls, 2);
      }, (error, stackTrace) => uncaught.add(error));
      expect(uncaught, isEmpty);
    },
  );

  test(
    'failed join cleanup blocks new admission until leave retries',
    () async {
      final events = <String>[];
      var createCalls = 0;
      final rtc = _FakeRtcAdapter(
        events,
        failedLeaveAttempts: 1,
        onJoin: (_) => throw StateError('native join failed'),
      );
      final service = VolcRtcSessionService.raw(
        createSession:
            ({
              required agentId,
              required requestId,
              authority,
              userId,
              locale,
              resumeAfterSequence = 0,
            }) async {
              createCalls++;
              return _legacySession();
            },
        rtcAdapter: rtc,
        connectActions:
            (session, {authority, agentId = 'self', locale}) async {},
        disconnectActions: () async => events.add('actions:disconnect'),
      );

      await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);
      await expectLater(service.joinAgent(agentId: 'self'), throwsStateError);
      expect(createCalls, 1);

      await service.leave();
      expect(rtc.leaveCalls, 2);
    },
  );
}

VolcRtcSessionService _legacyService({
  required VolcRtcNativeAdapter rtc,
  RealtimeActionDisconnect? disconnectActions,
}) => VolcRtcSessionService.raw(
  createSession:
      ({
        required agentId,
        required requestId,
        authority,
        userId,
        locale,
        resumeAfterSequence = 0,
      }) async => throw StateError('not used'),
  rtcAdapter: rtc,
  connectActions: (session, {authority, agentId = 'self', locale}) async {},
  disconnectActions: disconnectActions ?? () async {},
);

RealtimeSession _legacySession() => RealtimeSession(
  sessionId: 'ms_legacy_1',
  locale: 'en',
  rtcAppId: 'volc-app-id',
  roomId: 'room_1',
  userId: 'user_1',
  agentUserId: 'ai_1',
  taskId: 'task_1',
  rtcToken: 'token_1',
  actionStreamUri: Uri.parse('https://api.example.test/actions'),
  createdAt: _wallNow,
);

RealtimeSession _fencedSession({
  String sessionId = 'ms_fenced_0001',
  required int leaseEpoch,
}) => RealtimeSession(
  sessionId: sessionId,
  locale: 'en',
  rtcAppId: 'volc-app-id',
  roomId: 'room_1',
  userId: 'user_1',
  agentUserId: 'ai_1',
  taskId: 'task_1',
  rtcToken: 'token_1',
  actionStreamUri: Uri.parse(
    '${MaasoEnvironment.test.baseUrl}/v1/realtime/sessions/'
    '$sessionId/actions',
  ),
  createdAt: _wallNow,
  leaseEpoch: leaseEpoch,
  rtcGeneration: 1,
);

class _FakeRtcAdapter implements VolcRtcNativeAdapter {
  _FakeRtcAdapter(this.events, {this.onJoin, this.failedLeaveAttempts = 0});

  final List<String> events;
  final FutureOr<void> Function(VolcRtcJoinConfig config)? onJoin;
  final int failedLeaveAttempts;
  VolcRtcJoinConfig? config;
  int leaveCalls = 0;
  final StreamController<VolcRtcTerminalEvent> _terminalEvents =
      StreamController<VolcRtcTerminalEvent>.broadcast();

  @override
  Stream<VolcRtcTerminalEvent> get terminalEvents => _terminalEvents.stream;

  void emitTerminal(VolcRtcTerminalEvent event) => _terminalEvents.add(event);

  @override
  Future<void> join(VolcRtcJoinConfig config) async {
    this.config = config;
    events.add('rtc:join:${config.roomId}');
    await onJoin?.call(config);
  }

  @override
  Future<void> leave() async {
    leaveCalls++;
    events.add('rtc:leave');
    if (leaveCalls <= failedLeaveAttempts) {
      throw StateError('rtc leave failed');
    }
  }

  @override
  Future<void> dispose() async {}
}

class _CountingRtcAdapter implements VolcRtcNativeAdapter {
  _CountingRtcAdapter({this.failFirstDispose = false});

  final bool failFirstDispose;
  int disposeCalls = 0;

  @override
  Stream<VolcRtcTerminalEvent> get terminalEvents =>
      const Stream<VolcRtcTerminalEvent>.empty();

  @override
  Future<void> join(VolcRtcJoinConfig config) async {}

  @override
  Future<void> leave() async {}

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    if (failFirstDispose && disposeCalls == 1) {
      throw StateError('dispose failed');
    }
  }
}

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

Future<_AuthorityFixture> _authorityFixture({int entropySeed = 1}) async {
  final entropy = _Entropy(entropySeed);
  final identity = AppInstallationIdentityService(
    store: _MemoryIdentityStore(),
    randomBytes: entropy.bytes,
  );
  await identity.init();
  final gateway = _AuthorityLeaseGateway();
  final coordinator = AccountDeviceLeaseCoordinator(
    identity: identity,
    gateway: gateway,
    randomBytes: entropy.bytes,
    monotonicNow: () => Duration.zero,
    wallClock: () => _wallNow,
  );
  await coordinator.acquire(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-1',
    deviceLabel: 'Test Mac',
    platform: 'macos',
    appVersion: '1.0.0',
  );
  return _AuthorityFixture(coordinator: coordinator, gateway: gateway);
}

class _AuthorityFixture {
  const _AuthorityFixture({required this.coordinator, required this.gateway});

  final AccountDeviceLeaseCoordinator coordinator;
  final _AuthorityLeaseGateway gateway;
}

class _MemoryIdentityStore implements AppInstallationIdentityStore {
  String? _value;

  @override
  Future<String?> read(String key) async => _value;

  @override
  Future<bool> write(String key, String value) async {
    _value = value;
    return true;
  }
}

class _Entropy {
  _Entropy([this._seed = 1]);

  int _seed;

  List<int> bytes(int length) {
    final seed = _seed++;
    return List<int>.generate(length, (index) => (seed + index) & 0xff);
  }
}

class _AuthorityLeaseGateway implements AccountDeviceLeaseGateway {
  AccountDevicePresenceReceipt? _presence;
  AccountDeviceLeaseReceipt? _lease;
  String? holderProof;

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
    final presence = _presence ??= AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence_0001',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: _wallNow,
      lastSeenAt: _wallNow,
      expiresAt: _wallNow.add(const Duration(minutes: 1)),
      remainingTtl: const Duration(minutes: 1),
      renewAfter: const Duration(seconds: 20),
    );
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

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
    this.holderProof = holderProof;
    final holder = AccountDeviceLeaseHolder(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      deviceLabel: 'Test Mac',
      platform: 'macos',
      lastSeenAt: _wallNow,
    );
    final lease = _lease ??= AccountDeviceLeaseReceipt(
      agentId: agentId,
      leaseId: 'lease_0001',
      epoch: 1,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: _wallNow.add(const Duration(seconds: 45)),
      remainingTtl: const Duration(seconds: 45),
      renewAfter: const Duration(seconds: 15),
      holder: holder,
    );
    return AccountDeviceLeaseOperationResult(lease: lease, replayed: false);
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
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async => AccountDeviceLeaseOperationResult(lease: lease, replayed: false);

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async => AccountDeviceLeaseReleaseResult(
    released: true,
    stale: false,
    epoch: lease.epoch + 1,
  );

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async => AccountDevicePresenceCloseResult(
    closed: true,
    stale: false,
    generation: presence.generation,
  );

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: _lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: _lease,
  );
}

final DateTime _wallNow = DateTime.utc(2026, 8, 21, 12);
