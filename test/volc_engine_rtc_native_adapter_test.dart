import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/agent_sound_platforms.dart';
import 'package:maaso/src/core/services/volc_engine_rtc_native_adapter.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:volc_engine_rtc/codegen/pack/keytype.dart' as rtc_keytype;
import 'package:volc_engine_rtc/volc_engine_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installAgentSoundPlatforms);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MaasoTtsPlugin.soundEnabled.value = true;
  });
  tearDown(() {
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  for (final muted in [false, true]) {
    test('RTC early publication honors cold join mute=$muted', () async {
      MaasoTtsPlugin.soundEnabled.value = !muted;
      final events = <String>[];
      final room = _FakeRtcRoom(events, publishAgentOnHandlerInstall: true);
      final adapter = _adapterFor(_FakeRtcEngine(events, room: room));
      addTearDown(adapter.dispose);
      await adapter.join(_agentConfig);
      expect(events, contains('audio:agent-stream:${!muted}'));
      expect(
        events.indexOf('room:join'),
        lessThan(events.indexOf('audio:agent-stream:${!muted}')),
      );
      expect(events, contains('engine:start-audio'));
    });
  }

  test('RTC sound toggle only changes the named Agent stream', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events);
    final adapter = _adapterFor(_FakeRtcEngine(events, room: room));
    addTearDown(adapter.dispose);
    await adapter.join(_agentConfig);
    await room.publishAudio('agent-user', 'agent-stream');
    await room.publishAudio('other-user', 'other-stream');
    expect(
      events,
      containsAll(['audio:agent-stream:true', 'audio:other-stream:true']),
    );
    events.clear();
    await MaasoTtsPlugin.setSoundEnabled(false);
    expect(events, ['audio:agent-stream:false']);
    await MaasoTtsPlugin.setSoundEnabled(true);
    await _eventually(() => events.contains('audio:agent-stream:true'));
    expect(events, ['audio:agent-stream:false', 'audio:agent-stream:true']);
  });

  test('VolcEngineRtcNativeAdapter implements VolcRtcNativeAdapter', () {
    final VolcRtcNativeAdapter adapter = VolcEngineRtcNativeAdapter();

    expect(adapter, isA<VolcRtcNativeAdapter>());
  });

  test(
    'mute waits out an in-flight RTC subscribe and remains retryable',
    () async {
      final events = <String>[];
      final room = _FakeRtcRoom(
        events,
        holdSubscription: true,
        failedUnsubscribeAttempts: 1,
      );
      final adapter = _adapterFor(_FakeRtcEngine(events, room: room));
      addTearDown(adapter.dispose);
      await adapter.join(_agentConfig);
      final publishing = room.publishAudio('agent-user', 'agent-stream');
      await room.subscriptionEntered.future;
      final muting = MaasoTtsPlugin.setSoundEnabled(false);
      final failure = expectLater(muting, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('audio:agent-stream:false')));
      room.releaseSubscription.complete();
      await publishing;
      await failure;
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      await MaasoTtsPlugin.setSoundEnabled(false);
      expect(events.where((event) => event.startsWith('audio:')), [
        'audio:agent-stream:true',
        'audio:agent-stream:false',
        'audio:agent-stream:false',
      ]);
    },
  );

  test('RTC AI audio is configured before capture', () {
    final source = File(
      'lib/src/core/services/volc_engine_rtc_native_adapter.dart',
    ).readAsStringSync();

    final configureIndex = source.indexOf(
      '_configureRealtimeVoiceAudio(engine)',
    );
    final captureIndex = source.indexOf('startAudioCapture');

    expect(source, contains('AudioScenarioType.aiclient'));
    expect(source, contains('setAudioScenario'));
    expect(configureIndex, isNonNegative);
    expect(captureIndex, isNonNegative);
    expect(configureIndex, lessThan(captureIndex));
    expect(source, contains('rtc_pack.RTCEngine.destroyRTCEngine()'));
    expect(source, contains('RoomState.success'));
    expect(source, contains('_awaitRoomJoin(cycle)'));
    expect(source, contains('_awaitRoomExit(cycle)'));
  });

  test('normal leave retires capture, room, and engine in order', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    await adapter.leave();

    expect(events, <String>[
      'engine:stop-audio:1',
      'room:leave:1',
      'room:destroy:1',
      'engine:destroy:1',
    ]);
  });

  test('join waits for the current room success callback', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmJoin: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);

    var joinDone = false;
    final joining = adapter.join(_config).then((_) => joinDone = true);
    await _eventually(() => events.contains('room:join'));
    expect(joinDone, isFalse);

    await room.confirmJoin();
    await joining;
    expect(joinDone, isTrue);
    await adapter.leave();
  });

  test(
    'async join rejection leaves and waits for exit before destroy',
    () async {
      final events = <String>[];
      final room = _FakeRtcRoom(
        events,
        autoConfirmJoin: false,
        autoConfirmExit: false,
      );
      final engine = _FakeRtcEngine(events, room: room);
      final adapter = _adapterFor(engine);

      final joining = adapter.join(_config);
      await _eventually(() => events.contains('room:join'));
      await room.confirmJoinFailure(
        rtc_keytype.RoomStateChangeReason.invalid_token,
      );
      await _eventually(() => events.contains('room:leave:1'));
      expect(events, isNot(contains('room:destroy:1')));

      await room.confirmExit();
      await expectLater(joining, throwsStateError);
      expect(events, contains('room:destroy:1'));
      expect(events, contains('engine:destroy:1'));
    },
  );

  test('transient join failure waits for retry success', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmJoin: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);

    var joinDone = false;
    final joining = adapter.join(_config).then((_) => joinDone = true);
    await _eventually(() => events.contains('room:join'));
    await room.confirmJoinFailure(
      rtc_keytype.RoomStateChangeReason.join_room_failed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(joinDone, isFalse);

    await room.confirmJoin();
    await joining;
    expect(joinDone, isTrue);
    await adapter.leave();
  });

  test('room exit confirmation gates room and engine destruction', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmExit: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    var leaveDone = false;
    final leaving = adapter.leave().then((_) => leaveDone = true);
    await _eventually(() => room.leaveCalls == 1);
    expect(leaveDone, isFalse);
    expect(events, isNot(contains('room:destroy:1')));
    expect(events, isNot(contains('engine:destroy:1')));

    await room.confirmExit();
    await leaving;
    expect(events, contains('room:destroy:1'));
    expect(events, contains('engine:destroy:1'));
  });

  test('room exit timeout fails closed and remains retryable', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmExit: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine, roomStateTimeout: Duration.zero);
    await adapter.join(_config);
    events.clear();

    await expectLater(adapter.leave(), throwsA(isA<TimeoutException>()));
    expect(events, <String>['engine:stop-audio:1', 'room:leave:1']);

    await room.confirmExit();
    events.clear();
    await adapter.leave();
    expect(events, <String>['room:destroy:1', 'engine:destroy:1']);
  });

  test('active terminal state requests leave before any destroy', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmExit: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    final terminal = adapter.terminalEvents.first;
    await adapter.join(_config);
    events.clear();

    await room.reportActiveFailure(
      rtc_keytype.RoomStateChangeReason.token_expired,
    );
    final event = await terminal;
    expect(event.roomId, _config.roomId);
    expect(event.reason, 'token_expired');
    await _eventually(() => events.contains('room:leave:1'));
    expect(events, isNot(contains('room:destroy:1')));

    await room.confirmExit();
    await _eventually(() => events.contains('engine:destroy:1'));
  });

  test('active legacy error cannot masquerade as exit confirmation', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, autoConfirmExit: false);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    final terminal = adapter.terminalEvents.first;
    await adapter.join(_config);
    events.clear();

    await room.reportLegacyState(-1010);
    await terminal;
    await _eventually(() => events.contains('room:leave:1'));
    expect(events, isNot(contains('room:destroy:1')));
    expect(events, isNot(contains('engine:destroy:1')));

    await room.confirmExit();
    await _eventually(() => events.contains('engine:destroy:1'));
  });

  test(
    'a stale callback cannot complete a same-id replacement cycle',
    () async {
      final events = <String>[];
      final firstRoom = _FakeRtcRoom(events);
      final secondRoom = _FakeRtcRoom(events, autoConfirmJoin: false);
      final firstEngine = _FakeRtcEngine(events, room: firstRoom);
      final secondEngine = _FakeRtcEngine(events, room: secondRoom);
      final engines = <_FakeRtcEngine>[firstEngine, secondEngine];
      var engineIndex = 0;
      final adapter = VolcEngineRtcNativeAdapter(
        createEngine: (_) async {
          final engine = engines[engineIndex++];
          engine.events.add('engine:create');
          return engine;
        },
        destroyEngine: (candidate) =>
            (candidate as _FakeRtcEngine).destroyForAdapter(candidate),
        joinRoom: _joinRoomForTest,
      );

      await adapter.join(_config);
      await adapter.leave();
      var replacementDone = false;
      final replacement = adapter
          .join(_config)
          .then((_) => replacementDone = true);
      await _eventually(() => secondRoom.eventHandler != null);

      await firstRoom.confirmJoin();
      await Future<void>.delayed(Duration.zero);
      expect(replacementDone, isFalse);

      await secondRoom.confirmJoin();
      await replacement;
      await adapter.leave();
    },
  );

  test('internal room lifecycle observer preserves caller callbacks', () async {
    final events = <String>[];
    var joinCallbacks = 0;
    var exitCallbacks = 0;
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(
      engine,
      roomEventHandler: IRTCRoomEventHandler(
        onRoomStateChangedWithReason: (roomId, uid, state, reason) {
          if (state == rtc_keytype.RoomState.success) joinCallbacks++;
          if (state == rtc_keytype.RoomState.left) exitCallbacks++;
        },
      ),
    );

    await adapter.join(_config);
    await adapter.leave();

    expect(joinCallbacks, 1);
    expect(exitCallbacks, 1);
  });

  test('failed room leave keeps the same handle retryable', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, failedLeaveAttempts: 1);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    await expectLater(adapter.leave(), throwsStateError);
    expect(events, <String>['engine:stop-audio:1', 'room:leave:1']);

    events.clear();
    await adapter.leave();
    expect(events, <String>[
      'room:leave:2',
      'room:destroy:1',
      'engine:destroy:1',
    ]);
  });

  test('failed room destroy retries destroy without leaving twice', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, failedDestroyAttempts: 1);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    await expectLater(adapter.leave(), throwsStateError);
    expect(events, <String>[
      'engine:stop-audio:1',
      'room:leave:1',
      'room:destroy:1',
    ]);

    events.clear();
    await adapter.leave();
    expect(events, <String>['room:destroy:2', 'engine:destroy:1']);
  });

  test('failed awaited engine destroy remains retryable', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(events, room: room, failedDestroyAttempts: 1);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    await expectLater(adapter.leave(), throwsStateError);
    expect(events.last, 'engine:destroy:1');

    events.clear();
    await adapter.leave();
    expect(events, <String>['engine:destroy:2']);
  });

  test('successful engine destroy resolves an explicit stop failure', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(
      events,
      room: room,
      failedStopAudioAttempts: 1,
    );
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    await adapter.leave();
    expect(events, <String>[
      'engine:stop-audio:1',
      'room:leave:1',
      'room:destroy:1',
      'engine:destroy:1',
    ]);

    events.clear();
    await adapter.leave();
    expect(events, isEmpty);
  });

  test('concurrent leave callers share one retirement future', () async {
    final events = <String>[];
    final stopEntered = Completer<void>();
    final releaseStop = Completer<void>();
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(
      events,
      room: room,
      stopAudioEntered: stopEntered,
      releaseStopAudio: releaseStop,
    );
    final adapter = _adapterFor(engine);
    await adapter.join(_config);
    events.clear();

    final first = adapter.leave();
    final second = adapter.leave();
    expect(second, same(first));
    await stopEntered.future;
    expect(events, <String>['engine:stop-audio:1']);

    releaseStop.complete();
    await Future.wait(<Future<void>>[first, second]);
    expect(events, <String>[
      'engine:stop-audio:1',
      'room:leave:1',
      'room:destroy:1',
      'engine:destroy:1',
    ]);
  });

  test('create-room failure compensates capture and engine', () async {
    final events = <String>[];
    final engine = _FakeRtcEngine(events);
    final adapter = _adapterFor(engine);

    await expectLater(adapter.join(_config), throwsStateError);

    expect(events, <String>[
      'engine:create',
      'engine:scenario',
      'engine:start-audio',
      'engine:create-room',
      'engine:stop-audio:1',
      'engine:destroy:1',
    ]);
  });

  test('rejected join destroys unjoined room without a false leave', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events, joinResult: -1);
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);

    await expectLater(adapter.join(_config), throwsStateError);

    expect(events, <String>[
      'engine:create',
      'engine:scenario',
      'engine:start-audio',
      'engine:create-room',
      'room:join',
      'engine:stop-audio:1',
      'room:destroy:1',
      'engine:destroy:1',
    ]);
  });

  test(
    'leave interrupts a pending capture start before final destroy',
    () async {
      final events = <String>[];
      final startEntered = Completer<void>();
      final releaseStart = Completer<void>();
      final engine = _FakeRtcEngine(
        events,
        startAudioEntered: startEntered,
        releaseStartAudio: releaseStart,
      );
      final adapter = _adapterFor(engine);

      final joining = adapter.join(_config);
      await startEntered.future;
      final leaving = adapter.leave();
      await _eventually(() => events.contains('engine:stop-audio:1'));
      expect(events, isNot(contains('engine:destroy:1')));

      releaseStart.complete();
      await expectLater(joining, throwsStateError);
      await leaving;

      expect(
        events,
        containsAllInOrder(<String>[
          'engine:start-audio',
          'engine:stop-audio:1',
          'engine:stop-audio:2',
          'engine:destroy:1',
        ]),
      );
    },
  );

  test('leave never destroys a room while joinRoom is pending', () async {
    final events = <String>[];
    final joinEntered = Completer<void>();
    final releaseJoin = Completer<void>();
    final room = _FakeRtcRoom(
      events,
      joinEntered: joinEntered,
      releaseJoin: releaseJoin,
    );
    final engine = _FakeRtcEngine(events, room: room);
    final adapter = _adapterFor(engine);

    final joining = adapter.join(_config);
    await joinEntered.future;
    final leaving = adapter.leave();
    await Future<void>.delayed(Duration.zero);
    expect(events, isNot(contains('room:leave:1')));
    expect(events, isNot(contains('room:destroy:1')));
    expect(events, isNot(contains('engine:destroy:1')));

    releaseJoin.complete();
    await expectLater(joining, throwsStateError);
    await leaving;
    expect(events, contains('room:leave:1'));
    expect(events, contains('room:destroy:1'));
    expect(events, contains('engine:destroy:1'));
  });

  test('dispose failure fences join and remains retryable', () async {
    final events = <String>[];
    final room = _FakeRtcRoom(events);
    final engine = _FakeRtcEngine(events, room: room, failedDestroyAttempts: 1);
    final adapter = _adapterFor(engine);
    await adapter.join(_config);

    await expectLater(adapter.dispose(), throwsStateError);
    await expectLater(adapter.join(_config), throwsStateError);
    await adapter.dispose();
    expect(engine.destroyCalls, 2);
  });
}

VolcEngineRtcNativeAdapter _adapterFor(
  _FakeRtcEngine engine, {
  bool publishVideo = false,
  Duration roomStateTimeout = const Duration(seconds: 5),
  IRTCRoomEventHandler? roomEventHandler,
}) => VolcEngineRtcNativeAdapter(
  publishVideo: publishVideo,
  roomStateTimeout: roomStateTimeout,
  roomEventHandler: roomEventHandler,
  createEngine: (_) async {
    engine.events.add('engine:create');
    return engine;
  },
  destroyEngine: engine.destroyForAdapter,
  joinRoom: _joinRoomForTest,
);

Future<int?> _joinRoomForTest(
  RTCRoom room,
  VolcRtcJoinConfig config, {
  required bool publishAudio,
  required bool publishVideo,
  required bool autoSubscribeAudio,
  required bool autoSubscribeVideo,
}) {
  expect(config.roomId, _config.roomId);
  expect(publishAudio, isTrue);
  expect(publishVideo, isFalse);
  expect(autoSubscribeAudio, config.agentUserId == null);
  expect(autoSubscribeVideo, isFalse);
  return (room as _FakeRtcRoom).joinForTest();
}

const _config = VolcRtcJoinConfig(
  appId: 'app-id',
  roomId: 'room-id',
  userId: 'user-id',
  token: 'token',
);

const _agentConfig = VolcRtcJoinConfig(
  appId: 'app-id',
  roomId: 'room-id',
  userId: 'user-id',
  token: 'token',
  agentUserId: 'agent-user',
);

final class _FakeRtcEngine implements RTCEngine {
  _FakeRtcEngine(
    this.events, {
    this.room,
    this.failedStopAudioAttempts = 0,
    this.failedDestroyAttempts = 0,
    this.startAudioEntered,
    this.releaseStartAudio,
    this.stopAudioEntered,
    this.releaseStopAudio,
  });

  final List<String> events;
  final RTCRoom? room;
  final int failedStopAudioAttempts;
  final int failedDestroyAttempts;
  final Completer<void>? startAudioEntered;
  final Completer<void>? releaseStartAudio;
  final Completer<void>? stopAudioEntered;
  final Completer<void>? releaseStopAudio;
  int stopAudioCalls = 0;
  int destroyCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<int?> setAudioScenario(AudioScenarioType audioScenario) async {
    events.add('engine:scenario');
    return 0;
  }

  @override
  Future<int?> startAudioCapture() async {
    events.add('engine:start-audio');
    final entered = startAudioEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await releaseStartAudio?.future;
    return 0;
  }

  @override
  Future<int?> stopAudioCapture() async {
    stopAudioCalls++;
    events.add('engine:stop-audio:$stopAudioCalls');
    final entered = stopAudioEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await releaseStopAudio?.future;
    if (stopAudioCalls <= failedStopAudioAttempts) {
      throw StateError('stop audio failed');
    }
    return 0;
  }

  @override
  Future<int?> startVideoCapture() async {
    events.add('engine:start-video');
    return 0;
  }

  @override
  Future<int?> stopVideoCapture() async {
    events.add('engine:stop-video');
    return 0;
  }

  @override
  Future<RTCRoom?> createRTCRoom(
    String roomId, {
    bool autoInitRangeAudio = false,
    bool autoInitSpatialAudio = false,
  }) async {
    events.add('engine:create-room');
    return room;
  }

  Future<void> destroyForAdapter(RTCEngine candidate) async {
    expect(candidate, same(this));
    destroyCalls++;
    events.add('engine:destroy:$destroyCalls');
    if (destroyCalls <= failedDestroyAttempts) {
      throw StateError('destroy engine failed');
    }
  }
}

final class _FakeRtcRoom implements RTCRoom {
  _FakeRtcRoom(
    this.events, {
    this.joinResult = 0,
    this.failedLeaveAttempts = 0,
    this.failedDestroyAttempts = 0,
    this.joinEntered,
    this.releaseJoin,
    this.autoConfirmJoin = true,
    this.autoConfirmExit = true,
    this.publishAgentOnHandlerInstall = false,
    this.holdSubscription = false,
    this.failedUnsubscribeAttempts = 0,
  });

  final List<String> events;
  final int? joinResult;
  final int failedLeaveAttempts;
  final int failedDestroyAttempts;
  final Completer<void>? joinEntered;
  final Completer<void>? releaseJoin;
  final bool autoConfirmJoin;
  final bool autoConfirmExit;
  final bool publishAgentOnHandlerInstall;
  final bool holdSubscription;
  int failedUnsubscribeAttempts;
  final subscriptionEntered = Completer<void>();
  final releaseSubscription = Completer<void>();
  int leaveCalls = 0;
  int destroyCalls = 0;
  IRTCRoomEventHandler? eventHandler;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<int> setRTCRoomEventHandler(IRTCRoomEventHandler handler) async {
    eventHandler = handler;
    if (publishAgentOnHandlerInstall) {
      await publishAudio('agent-user', 'agent-stream');
    }
    return 0;
  }

  Future<void> publishAudio(String userId, String streamId) async {
    await eventHandler?.onUserPublishStreamAudio?.call(
      streamId,
      _StreamInfo(userId),
      true,
    );
  }

  @override
  Future<int?> subscribeStreamAudio({
    required string streamId,
    required bool subscribe,
  }) async {
    events.add('audio:$streamId:$subscribe');
    if (subscribe && holdSubscription) {
      if (!subscriptionEntered.isCompleted) subscriptionEntered.complete();
      await releaseSubscription.future;
    }
    if (!subscribe && failedUnsubscribeAttempts > 0) {
      failedUnsubscribeAttempts--;
      throw StateError('RTC unsubscribe failed');
    }
    return 0;
  }

  @override
  Future<int?> joinRoom({
    required string token,
    required UserInfo userInfo,
    required bool userVisibility,
    required rtc_keytype.RoomConfig roomConfig,
  }) async {
    events.add('room:join');
    final entered = joinEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await releaseJoin?.future;
    return joinResult;
  }

  Future<int?> joinForTest() async {
    events.add('room:join');
    final entered = joinEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await releaseJoin?.future;
    if (joinResult == 0 && autoConfirmJoin) await confirmJoin();
    return joinResult;
  }

  @override
  Future<int?> leaveRoom() async {
    leaveCalls++;
    events.add('room:leave:$leaveCalls');
    if (leaveCalls <= failedLeaveAttempts) {
      throw StateError('leave failed');
    }
    if (autoConfirmExit) await confirmExit();
    return 0;
  }

  Future<void> confirmJoin() async {
    await eventHandler?.onRoomStateChangedWithReason?.call(
      _config.roomId,
      _config.userId,
      rtc_keytype.RoomState.success,
      rtc_keytype.RoomStateChangeReason.join_room,
    );
  }

  Future<void> confirmJoinFailure(
    rtc_keytype.RoomStateChangeReason reason,
  ) async {
    await eventHandler?.onRoomStateChangedWithReason?.call(
      _config.roomId,
      _config.userId,
      rtc_keytype.RoomState.failed,
      reason,
    );
  }

  Future<void> confirmExit() async {
    await eventHandler?.onRoomStateChangedWithReason?.call(
      _config.roomId,
      _config.userId,
      rtc_keytype.RoomState.left,
      rtc_keytype.RoomStateChangeReason.leave_room,
    );
  }

  Future<void> reportActiveFailure(rtc_keytype.RoomStateChangeReason reason) =>
      confirmJoinFailure(reason);

  Future<void> reportLegacyState(int state) async {
    await eventHandler?.onRoomStateChanged?.call(
      _config.roomId,
      _config.userId,
      state,
      '',
    );
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
    events.add('room:destroy:$destroyCalls');
    if (destroyCalls <= failedDestroyAttempts) {
      throw StateError('destroy failed');
    }
  }
}

class _StreamInfo implements StreamInfo {
  _StreamInfo(this.userId);
  @override
  final String userId;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
