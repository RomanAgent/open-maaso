import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    AvatarProductionOwnership.resetForTest();
    await appServices.reset();
  });
  tearDown(() async {
    await appServices.reset();
    AvatarProductionOwnership.resetForTest();
  });

  test(
    'matched v2 normal host starts and observed work controls desk camera',
    () async {
      final h = await _HostHarness.start(camera: true);
      addTearDown(h.close);
      expect(
        h.flags.effectiveMode(MaasoFeatureFlag.avatarProjectionV2),
        FeatureRolloutMode.off,
      );
      expect(h.authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(h.runtime.supportsHostBackgroundTaskWorkPresentation, isTrue);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      final start = h.transport.work.single;
      expect(start.keys.toSet(), _commandKeys);
      expect(start['sessionId'], owner.sessionId);
      expect(start['sessionId'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(start['loadRequestId'], h.transport.loadedRequest);
      expect(
        (start['deadlineEpochMs'] as int) - (start['issuedAtEpochMs'] as int),
        10000,
      );
      expect(h.transport.shots.last, 'hero_full_body');
      expect(await h.observe(owner.sessionId, 'approaching', 1), isTrue);
      expect(h.transport.shots.last, 'hero_full_body');
      expect(await h.observe(owner.sessionId, 'working', 2), isTrue);
      expect(h.transport.shots.last, 'desk_over_shoulder');
      await h.controller.end(owner);
      final end = h.transport.work.last;
      expect(end['phase'], 'end');
      expect(end['sessionId'], owner.sessionId);
      expect(
        await h.observe(owner.sessionId, 'rising', 3, workOwner: null),
        isTrue,
      );
      expect(h.transport.shots.last, 'hero_full_body');
      expect(
        h.transport.calls.any((c) => c.method == 'avatarArbiterCommand'),
        isFalse,
      );
    },
  );

  for (final version in [null, 1, '2', 2.0, 3, true]) {
    test('load work version $version cannot open host mutation', () async {
      final transport = _Transport()..workVersion = version;
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      await runtime.loadAvatar('unity://matt');
      expect(runtime.supportsHostBackgroundTaskWorkPresentation, isFalse);
      expect(runtime.supportsBackgroundTaskWorkPresentation, version == 1);
      final result = await runtime.setBackgroundTaskWork(
        sessionId: _sessionA,
        phase: AvatarBackgroundTaskWorkPhase.start,
      );
      expect(result.applied, isFalse);
      expect(result.code, 'work_unavailable');
      expect(transport.work, isEmpty);
    });
  }

  test(
    'generic ready without matched load does not grant host capability',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      await transport.emit(
        const MethodCall('commandResult', {
          'method': 'loadAvatar',
          'requestId': 'unsolicited',
          'ok': true,
          'backgroundTaskWorkVersion': 2,
        }),
      );
      expect(runtime.supportsHostBackgroundTaskWorkPresentation, isFalse);
      expect(
        (await runtime.setBackgroundTaskWork(
          sessionId: _sessionA,
          phase: AvatarBackgroundTaskWorkPhase.start,
        )).applied,
        isFalse,
      );
      expect(transport.work, isEmpty);
    },
  );

  test(
    'invalid host session identifiers never reach native transport',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      for (final session in ['', 'a' * 63, 'a' * 65, 'A' * 64, 'g' * 64]) {
        final result = await h.runtime.setBackgroundTaskWork(
          sessionId: session,
          phase: AvatarBackgroundTaskWorkPhase.start,
        );
        expect(result.code, 'invalid_command');
      }
      expect(h.transport.work, isEmpty);
    },
  );

  test(
    'wrong, duplicate, and extra-field command replies cannot settle pending start',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.autoAck = false;
      var completed = false;
      final starting = h.runtime.setBackgroundTaskWork(
        sessionId: _sessionA,
        phase: AvatarBackgroundTaskWorkPhase.start,
      )..then((_) => completed = true);
      await _turn();
      final packet = h.transport.work.single;
      final reply = h.transport.reply(packet);
      final invalid = <Map<String, Object?>>[
        {...reply, 'loadRequestId': 'other-load'},
        {...reply, 'sessionId': _sessionB},
        {...reply, 'phase': 'end'},
        {...reply, 'requestId': 'unmatched'},
        {...reply, 'sequence': (packet['sequence'] as int) + 1},
        {...reply, 'sequence': 1.0},
        {...reply, 'ok': 1},
        {...reply, 'code': 'raw_private_error'},
        {...reply, 'unexpected': 'private'},
        Map.of(reply)..remove('sequence'),
      ];
      for (final bad in invalid) {
        expect(
          await h.transport.emit(MethodCall('commandResult', bad)),
          isFalse,
        );
        expect(completed, isFalse);
      }
      expect(
        await h.transport.emit(MethodCall('commandResult', reply)),
        isTrue,
      );
      expect((await starting).applied, isTrue);
      expect(
        await h.transport.emit(MethodCall('commandResult', reply)),
        isFalse,
      );
      h.transport.autoAck = true;
      await h.runtime.setBackgroundTaskWork(
        sessionId: _sessionA,
        phase: AvatarBackgroundTaskWorkPhase.end,
      );
    },
  );

  test(
    'state observations require exact load, owner, sequence, and closed fields',
    () async {
      final h = await _HostHarness.start(camera: true);
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      final state = h.state(owner.sessionId, 'working', 2);
      final invalid = <Map<String, Object?>>[
        {...state, 'loadRequestId': 'old-load'},
        {...state, 'sessionId': _sessionB},
        {...state, 'workSessionId': _sessionB},
        {...state, 'sequence': 1.0},
        {...state, 'sequence': true},
        {...state, 'sequence': 0},
        {...state, 'phase': 'raw_animation'},
        {...state, 'furnitureId': 'private_bone'},
        {...state, 'sceneId': ''},
        {
          ...state,
          'raw': {'private': true},
        },
        Map.of(state)..remove('workSessionId'),
      ];
      for (final bad in invalid) {
        expect(
          await h.transport.emit(MethodCall('commandResult', bad)),
          isFalse,
        );
        expect(h.runtime.furnitureState, isNull);
        expect(h.transport.shots.last, 'hero_full_body');
      }
      expect(
        await h.transport.emit(MethodCall('commandResult', state)),
        isTrue,
      );
      await _turn();
      await h.camera!.waitForIdle();
      expect(h.runtime.furnitureState!.workSessionId, owner.sessionId);
      expect(h.transport.shots.last, 'desk_over_shoulder');
      expect(
        await h.transport.emit(MethodCall('commandResult', state)),
        isFalse,
      );
      expect(
        await h.transport.emit(
          MethodCall('commandResult', {...state, 'sequence': 1}),
        ),
        isFalse,
      );
      expect(h.runtime.furnitureState!.sequence, 2);
    },
  );

  test(
    'native busy retries the same owner without creating another task session',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.outcomes.add((false, 'presentation_busy'));
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(owner));
      expect(h.transport.work.single['sessionId'], owner.sessionId);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await h.controller.waitForIdle();
      expect(h.transport.work.length, 2);
      expect(h.transport.work.map((p) => p['sessionId']), [
        owner.sessionId,
        owner.sessionId,
      ]);
      expect(h.transport.work.map((p) => p['phase']), ['start', 'start']);
      expect(
        h.transport.work.last['sequence'] as int,
        greaterThan(h.transport.work.first['sequence'] as int),
      );
      await h.controller.end(owner);
    },
  );

  test(
    'model replacement retires pending start and rejects its late acknowledgement',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.autoAck = false;
      final starting = h.runtime.setBackgroundTaskWork(
        sessionId: _sessionA,
        phase: AvatarBackgroundTaskWorkPhase.start,
      );
      await _turn();
      final old = h.transport.work.single;
      await h.runtime.loadAvatar('unity://joy');
      final result = await starting;
      expect(result.applied, isFalse);
      expect(result.code, 'model_stale');
      expect(
        await h.transport.emit(
          MethodCall('commandResult', h.transport.reply(old)),
        ),
        isFalse,
      );
      expect(
        await h.transport.emit(
          MethodCall(
            'commandResult',
            h.state(
              _sessionA,
              'working',
              1,
              load: old['loadRequestId'] as String,
            ),
          ),
        ),
        isFalse,
      );
      expect(h.runtime.furnitureState, isNull);
      h.transport.autoAck = true;
      expect(
        (await h.runtime.setBackgroundTaskWork(
          sessionId: _sessionB,
          phase: AvatarBackgroundTaskWorkPhase.start,
        )).applied,
        isTrue,
      );
      await h.runtime.setBackgroundTaskWork(
        sessionId: _sessionB,
        phase: AvatarBackgroundTaskWorkPhase.end,
      );
    },
  );

  for (final busyRounds in [1, 3]) {
    test(
      'cancel after $busyRounds pre-mutation busy replies admits the next task without a native state',
      () async {
        final h = await _HostHarness.start();
        addTearDown(h.close);
        h.transport.outcomes.addAll(
          List.filled(busyRounds, (false, 'presentation_busy')),
        );
        final first = h.begin()!;
        await h.controller.waitForIdle();
        for (var round = 1; round < busyRounds; round++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await h.controller.waitForIdle();
        }
        expect(h.transport.work.length, busyRounds);
        expect(
          h.transport.work.every(
            (p) => p['sessionId'] == first.sessionId && p['phase'] == 'start',
          ),
          isTrue,
        );
        expect(h.runtime.furnitureState, isNull);
        await h.controller.end(first);
        final next = h.begin(job: 'after-busy')!;
        await h.controller.waitForIdle();
        expect(h.controller.activeOwner, same(next));
        expect(h.transport.work.last['sessionId'], next.sessionId);
        expect(h.transport.work.last['phase'], 'start');
        expect(next.sessionId, isNot(first.sessionId));
        await h.controller.end(next);
      },
    );
  }

  test(
    'human posture takeover still cancels exact host work without a force-stand command',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(await h.observe(owner.sessionId, 'working', 1), isTrue);
      final workEpoch = h.runtime.backgroundTaskWorkPresentationEpoch;
      expect(
        await h.observe(owner.sessionId, 'seated', 2, workOwner: null),
        isTrue,
      );
      await h.controller.waitForIdle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(h.controller.activeOwner, isNull);
      expect(h.runtime.backgroundTaskWorkPresentationEpoch, workEpoch + 1);
      expect(h.transport.work, hasLength(1));
      expect(h.runtime.furnitureState!.phase, AvatarFurniturePhase.seated);
      expect(h.runtime.furnitureState!.workSessionId, isNull);
      expect(await h.observe(owner.sessionId, 'working', 3), isFalse);
      expect(h.runtime.furnitureState!.phase, AvatarFurniturePhase.seated);
      expect(
        h.transport.calls.any(
          (c) => const {
            'playPrimitive',
            'playMotion',
            'avatarArbiterCommand',
          }.contains(c.method),
        ),
        isFalse,
      );
      await h.authority.sealAndDrain();
      expect(h.runtime.furnitureState, isNull);
    },
  );

  test(
    'normal end observations do not look like unsolicited user takeover',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(await h.observe(owner.sessionId, 'working', 1), isTrue);
      final workEpoch = h.runtime.backgroundTaskWorkPresentationEpoch;
      h.transport.autoAck = false;
      final ended = h.controller.end(owner);
      await _turn();
      final endPacket = h.transport.work.last;
      expect(endPacket['phase'], 'end');
      expect(
        await h.observe(owner.sessionId, 'rising', 2, workOwner: null),
        isTrue,
      );
      expect(h.runtime.backgroundTaskWorkPresentationEpoch, workEpoch);
      await h.transport.emit(
        MethodCall('commandResult', h.transport.reply(endPacket)),
      );
      await ended;
      expect(
        await h.observe(owner.sessionId, 'standing', 3, workOwner: null),
        isTrue,
      );
      expect(h.runtime.backgroundTaskWorkPresentationEpoch, workEpoch);
      expect(h.controller.activeOwner, isNull);
    },
  );

  for (final mode in [FeatureRolloutMode.off, FeatureRolloutMode.shadow]) {
    for (final finishInBackground in [false, true]) {
      test(
        'temporary native detach preserves exact job and cleanup (terminal=$finishInBackground mode=$mode)',
        () async {
          final h = await _HostHarness.start(mode: mode);
          addTearDown(h.close);
          h.transport.autoAck = false;
          final owner = h.begin()!;
          await _turn();
          final workEpoch = h.runtime.backgroundTaskWorkPresentationEpoch;
          final modelEpoch = h.runtime.modelLoadEpoch;
          final authorityEpoch = h.authority.hostTaskWorkAuthorityGeneration;
          h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
          await h.transport.emit(
            const MethodCall('unready', {'reason': 'detached'}),
          );
          await h.controller.waitForIdle();
          expect(h.runtime.backgroundTaskWorkPresentationEpoch, workEpoch);
          expect(h.runtime.modelLoadEpoch, modelEpoch);
          expect(h.authority.hostTaskWorkAuthorityGeneration, authorityEpoch);
          expect(h.controller.activeOwner, same(owner));
          if (finishInBackground) {
            h.jobCurrent = false;
            await h.controller.end(owner);
          }
          h.transport.autoAck = true;
          await h.transport.emit(const MethodCall('ready'));
          h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await h.controller.waitForIdle();
          expect(
            h.transport.work.map((packet) => packet['sessionId']).toSet(),
            {owner.sessionId},
          );
          expect(h.transport.work.map((packet) => packet['phase']), [
            'start',
            finishInBackground ? 'end' : 'start',
          ]);
          expect(
            h.controller.activeOwner,
            finishInBackground ? isNull : same(owner),
          );
        },
      );
    }
  }

  for (final boundary in ['rollout', 'sealed']) {
    test(
      'a true host authority $boundary change never resumes old work',
      () async {
        final h = await _HostHarness.start(mode: FeatureRolloutMode.shadow);
        addTearDown(h.close);
        final owner = h.begin()!;
        await h.controller.waitForIdle();
        final authorityEpoch = h.authority.hostTaskWorkAuthorityGeneration;
        h.controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        if (boundary == 'rollout') {
          h.flags.setRuntimeMaximum(
            MaasoFeatureFlag.avatarProjectionV2,
            FeatureRolloutMode.off,
          );
        } else {
          await h.authority.sealAndDrain();
        }
        await h.authority.waitForIdle();
        expect(
          h.authority.hostTaskWorkAuthorityGeneration,
          greaterThan(authorityEpoch),
        );
        h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await h.controller.waitForIdle();
        expect(h.controller.activeOwner, isNull);
        expect(h.transport.work.map((packet) => packet['phase']), ['start']);
        expect(h.transport.work.single['sessionId'], owner.sessionId);
      },
    );
  }

  test(
    'closed runtime retires pending start and cannot accept late ACK',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.autoAck = false;
      final starting = h.runtime.setBackgroundTaskWork(
        sessionId: _sessionA,
        phase: AvatarBackgroundTaskWorkPhase.start,
      );
      await _turn();
      final old = h.transport.work.single;
      h.runtime.onClose();
      expect((await starting).applied, isFalse);
      expect(h.runtime.supportsHostBackgroundTaskWorkPresentation, isFalse);
      expect(
        await h.transport.emit(
          MethodCall('commandResult', h.transport.reply(old)),
        ),
        isNull,
      );
      expect(
        (await h.runtime.setBackgroundTaskWork(
          sessionId: _sessionB,
          phase: AvatarBackgroundTaskWorkPhase.start,
        )).code,
        'work_unavailable',
      );
    },
  );

  test(
    'terminal pre-mutation rejection does not reserve the next task',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.outcomes.add((false, 'invalid_command'));
      h.begin();
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, isNull);
      final next = h.begin(job: 'next')!;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(next));
      expect(h.transport.work.last['sessionId'], next.sessionId);
      expect(h.transport.work.last['phase'], 'start');
      await h.controller.end(next);
    },
  );

  test(
    'unknown timeout retains an exact end compensation before next task',
    () async {
      final h = await _HostHarness.start();
      addTearDown(h.close);
      h.transport.dropStarts = true;
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, isNull);
      expect(h.transport.work.map((p) => p['phase']), ['start', 'end']);
      expect(h.transport.work.map((p) => p['sessionId']), [
        owner.sessionId,
        owner.sessionId,
      ]);
      expect(h.transport.work.map((p) => p['loadRequestId']).toSet(), {
        h.transport.loadedRequest,
      });
      h.transport.dropStarts = false;
      final next = h.begin(job: 'after-timeout')!;
      await h.controller.waitForIdle();
      expect(h.controller.activeOwner, same(next));
      expect(h.transport.work.last['sessionId'], next.sessionId);
      await h.controller.end(next);
    },
  );

  test(
    'late old end ACK and state cannot change the next active session',
    () async {
      final h = await _HostHarness.start(camera: true);
      addTearDown(h.close);
      final oldOwner = h.begin()!;
      await h.controller.waitForIdle();
      await h.controller.end(oldOwner);
      final oldEnd = h.transport.work.last;
      final owner = h.begin(job: 'next')!;
      await h.controller.waitForIdle();
      expect(await h.observe(owner.sessionId, 'working', 2), isTrue);
      expect(
        await h.transport.emit(
          MethodCall('commandResult', h.transport.reply(oldEnd)),
        ),
        isFalse,
      );
      expect(
        await h.transport.emit(
          MethodCall(
            'commandResult',
            h.state(oldOwner.sessionId, 'rising', 3, workOwner: null),
          ),
        ),
        isFalse,
      );
      await _turn();
      expect(h.controller.activeOwner, same(owner));
      expect(h.runtime.furnitureState!.workSessionId, owner.sessionId);
      expect(h.transport.shots.last, 'desk_over_shoulder');
      await h.controller.end(owner);
    },
  );

  test(
    'camera drops cached work when the exact host session changes without a state event',
    () async {
      final h = await _HostHarness.start(camera: true);
      addTearDown(h.close);
      final owner = h.begin()!;
      await h.controller.waitForIdle();
      await h.observe(owner.sessionId, 'working', 1);
      expect(h.transport.shots.last, 'desk_over_shoulder');
      await h.controller.end(owner);
      final next = h.begin(job: 'next-without-state')!;
      await h.controller.waitForIdle();
      expect(
        h.runtime.furnitureState,
        isNull,
        reason:
            'the previous work observation cannot represent the new session',
      );
      h.camera!.resumeAfterExternalPresentation();
      await h.camera!.waitForIdle();
      expect(h.transport.shots.last, isNot('desk_over_shoulder'));
      await h.controller.end(next);
    },
  );

  for (final mode in [FeatureRolloutMode.off, FeatureRolloutMode.shadow]) {
    test(
      '$mode host work does not open production model behavior authority',
      () async {
        final h = await _HostHarness.start(mode: mode);
        addTearDown(h.close);
        final owner = h.begin()!;
        await h.controller.waitForIdle();
        expect(
          h.authority.phase,
          mode == FeatureRolloutMode.off
              ? AvatarProductionAuthorityPhase.legacy
              : AvatarProductionAuthorityPhase.shadow,
        );
        final count = h.transport.work.length;
        final result = await h.authority.applyBehavior(
          bodyGesture: 'work_desk',
          duration: const Duration(seconds: 1),
        );
        expect(result.applied, isFalse);
        expect(h.transport.work.length, count);
        expect(
          h.transport.calls.any((c) => c.method == 'avatarArbiterCommand'),
          isFalse,
        );
        await h.controller.end(owner);
      },
    );
  }
}

const _sessionA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _sessionB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _commandKeys = {
  'requestId',
  'sessionId',
  'phase',
  'loadRequestId',
  'sequence',
  'issuedAtEpochMs',
  'deadlineEpochMs',
};

Future<void> _turn() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _HostHarness {
  _HostHarness._(this.transport, this.runtime, this.active, this.flags);
  final _Transport transport;
  final UnityAvatarRuntime runtime;
  final ActiveAvatarRuntime active;
  final MaasoFeatureFlagService flags;
  late final AvatarProjectionProductionAuthority authority;
  late final AvatarBackgroundTaskWorkController controller;
  AvatarCameraDirector? camera;
  bool mountCurrent = true;
  bool jobCurrent = true;
  bool _closed = false;

  static Future<_HostHarness> start({
    bool camera = false,
    FeatureRolloutMode mode = FeatureRolloutMode.off,
  }) async {
    final transport = _Transport();
    final runtime = UnityAvatarRuntime(transport: transport);
    final active = ActiveAvatarRuntime()..register(runtime);
    final flags = await MaasoFeatureFlagService(
      store: _FlagStore(),
      compileMaximums: mode == FeatureRolloutMode.shadow
          ? {MaasoFeatureFlag.avatarProjectionV2: mode}
          : null,
    ).init();
    if (mode == FeatureRolloutMode.shadow) {
      await flags.assign(
        flag: MaasoFeatureFlag.avatarProjectionV2,
        mode: mode,
        revision: 1,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
    }
    final h = _HostHarness._(transport, runtime, active, flags);
    await transport.emit(const MethodCall('ready'));
    await runtime.loadAvatar('unity://matt');
    h.authority = AvatarProjectionProductionAuthority(
      accountGeneration: 1,
      featureFlags: flags,
      activeAvatarRuntime: active,
      renderer: runtime,
      dispatchSink: runtime.commandDispatchSink,
      mountIsCurrent: () => h.mountCurrent,
    )..onInit();
    await h.authority.waitForIdle();
    h.controller = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => runtime,
      authorityProvider: () => h.authority,
      canPresent: () => true,
    );
    if (camera) {
      h.camera = AvatarCameraDirector(
        avatarRuntime: active,
        mountIsCurrent: () => true,
        currentRoute: () => '/home',
      )..onInit();
      await h.camera!.waitForIdle();
    }
    return h;
  }

  AvatarBackgroundTaskWorkOwner? begin({String job = 'job'}) =>
      controller.begin(
        jobId: job,
        attempt: 1,
        scopeKey: 'account-a/staging',
        isCurrent: () => jobCurrent,
      );

  Map<String, Object?> state(
    String session,
    String phase,
    int sequence, {
    String? workOwner = 'current',
    String? load,
  }) => {
    'method': 'backgroundTaskWorkState',
    'requestId': 'state-$sequence',
    'sessionId': session,
    'loadRequestId': load ?? transport.loadedRequest,
    'phase': phase,
    'furnitureId': 'desk',
    'sceneId': 'personal-space',
    'sequence': sequence,
    'workSessionId': workOwner == 'current' ? session : workOwner,
  };

  Future<dynamic> observe(
    String session,
    String phase,
    int sequence, {
    String? workOwner = 'current',
  }) async {
    final accepted = await transport.emit(
      MethodCall(
        'commandResult',
        state(session, phase, sequence, workOwner: workOwner),
      ),
    );
    await _turn();
    await camera?.waitForIdle();
    return accepted;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    jobCurrent = false;
    transport.autoAck = true;
    transport.dropStarts = false;
    await controller.dispose();
    await camera?.sealAndDrain();
    await authority.sealAndDrain();
    authority.onClose();
    flags.onClose();
    runtime.onClose();
  }
}

class _Transport implements UnityAvatarTransport {
  UnityAvatarMethodCallHandler? handler;
  final calls = <MethodCall>[];
  Object? workVersion = 2;
  bool autoAck = true;
  bool dropStarts = false;
  String? loadedRequest;
  final outcomes = <(bool, String)>[];
  List<Map<String, Object?>> get work => calls
      .where((c) => c.method == 'setBackgroundTaskWork')
      .map((c) => Map<String, Object?>.from(c.arguments as Map))
      .toList();
  List<String> get shots => calls
      .where((c) => c.method == 'setFraming')
      .map((c) => (c.arguments as Map)['mode'] as String)
      .toList();

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == 'loadAvatar') {
      loadedRequest = (arguments as Map)['requestId'] as String;
      scheduleMicrotask(
        () => emit(
          MethodCall('commandResult', {
            'method': 'loadAvatar',
            'requestId': loadedRequest,
            'ok': true,
            if (workVersion != null) 'backgroundTaskWorkVersion': workVersion,
          }),
        ),
      );
    } else if (method == 'setBackgroundTaskWork' && autoAck) {
      final packet = Map<String, Object?>.from(arguments as Map);
      if (!(dropStarts && packet['phase'] == 'start')) {
        final outcome = outcomes.isEmpty ? (true, '') : outcomes.removeAt(0);
        scheduleMicrotask(
          () => emit(
            MethodCall(
              'commandResult',
              reply(packet, ok: outcome.$1, code: outcome.$2),
            ),
          ),
        );
      }
    }
    return null;
  }

  Map<String, Object?> reply(
    Map<String, Object?> packet, {
    bool ok = true,
    String code = '',
  }) => {
    'method': 'setBackgroundTaskWork',
    'requestId': packet['requestId'],
    'sessionId': packet['sessionId'],
    'phase': packet['phase'],
    'loadRequestId': packet['loadRequestId'],
    'sequence': packet['sequence'],
    'ok': ok,
    'code': code,
  };
  Future<dynamic> emit(MethodCall call) async => handler?.call(call);
  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) =>
      this.handler = handler;
  @override
  void dispose() => handler = null;
}

class _FlagStore implements MaasoFeatureFlagAssignmentStore {
  @override
  Future<List<Map<String, Object?>>> readAll() async => [];
  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {}
}
