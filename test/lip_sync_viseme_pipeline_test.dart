import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    final renderer = appServices.maybeFind<ActiveAvatarRuntime>()?.current;
    try {
      final authority = appServices
          .maybeFind<AvatarProjectionProductionAuthority>();
      if (authority != null) await authority.sealAndDrain();
    } finally {
      try {
        await appServices.reset();
      } finally {
        if (renderer is UnityAvatarRuntime) renderer.onClose();
        AvatarProductionOwnership.resetForTest();
      }
    }
  });

  test('viseme command is canonical and remains on the mouth channel', () {
    final track = _track();
    final command = AvatarVisemeTrackCommand(track);

    expect(command.channel, AvatarCommandChannel.mouth);
    expect(command.toCanonicalJson(), <String, Object?>{
      'channel': 'mouth',
      'format': LipSyncVisemeTrack.wireFormat,
      'envelope': <double>[0, 0.8, 0.65, 0],
      'cues': <Map<String, Object>>[
        <String, Object>{'frame': 0, 'viseme': 'sil'},
        <String, Object>{'frame': 1, 'viseme': 'aa'},
        <String, Object>{'frame': 2, 'viseme': 'ih'},
        <String, Object>{'frame': 3, 'viseme': 'sil'},
      ],
      'frameRate': 30,
    });
  });

  test('projection fences and dispatches a TTS-owned viseme track', () async {
    final sink = _RecordingSink();
    final service = SelfAvatarProjectionService(
      accountGeneration: 7,
      mode: () => FeatureRolloutMode.enforce,
      dispatchSink: sink,
    );
    await service.bindRenderer(
      accountGeneration: 7,
      rendererGeneration: 2,
      ready: true,
      sequence: 1,
    );
    await service.project(
      const SelfAvatarSpeakingProjectionInput(
        accountGeneration: 7,
        rendererGeneration: 2,
        sequence: 2,
        isSpeaking: true,
        generation: 11,
      ),
    );
    sink.dispatches.clear();

    final track = _track();
    final applied = await service.project(
      SelfAvatarVisemeTrackProjectionInput(
        accountGeneration: 7,
        rendererGeneration: 2,
        sequence: 3,
        track: track,
        generation: 11,
      ),
    );

    expect(applied.disposition, SelfAvatarProjectionDisposition.enforced);
    expect(sink.dispatches, hasLength(1));
    expect(sink.dispatches.single.visemeTrack, same(track));
    expect(sink.dispatches.single.channels, <SelfAvatarProjectionChannel>{
      SelfAvatarProjectionChannel.lipSync,
    });

    await service.project(
      const SelfAvatarSpeakingProjectionInput(
        accountGeneration: 7,
        rendererGeneration: 2,
        sequence: 4,
        isSpeaking: false,
        generation: 11,
      ),
    );
    final writesAfterStop = sink.dispatches.length;
    final stale = await service.project(
      SelfAvatarVisemeTrackProjectionInput(
        accountGeneration: 7,
        rendererGeneration: 2,
        sequence: 5,
        track: track,
        generation: 11,
      ),
    );
    expect(
      stale.disposition,
      SelfAvatarProjectionDisposition.rejectedStaleSpeech,
    );
    expect(sink.dispatches, hasLength(writesAfterStop));
  });

  test('Unity runtime sends the additive direct viseme method', () async {
    const channel = MethodChannel(UnityAvatarRuntime.channelName);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final runtime = UnityAvatarRuntime(channel: channel);
    addTearDown(runtime.onClose);
    final track = _track();
    await runtime.startVisemeTrack(track);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startVisemeTimeline');
    expect(calls.single.arguments, track.toRendererJson());
  });

  test(
    'ticketed mouth ownership blocks legacy viseme tracks until relinquished',
    () async {
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.avatarProjectionV2: FeatureRolloutMode.enforce,
        },
      ).init();
      appServices.put(flags);
      await flags.assign(
        flag: MaasoFeatureFlag.avatarProjectionV2,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
      final transport = _AckingUnityTransport();
      final runtime = UnityAvatarRuntime(transport: transport);
      final active = ActiveAvatarRuntime()..register(runtime);
      appServices.put(active);
      await transport.emit(const MethodCall('ready'));
      final authority = AvatarProjectionProductionAuthority(
        accountGeneration: 20,
        featureFlags: flags,
        activeAvatarRuntime: active,
        renderer: runtime,
        dispatchSink: runtime.commandDispatchSink,
        mountIsCurrent: () => true,
      );
      appServices.put(authority);
      await _flushAuthority(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.enforcing);
      expect(AvatarProductionOwnership.blocksLegacyAvatarMutation, isTrue);
      transport.calls.clear();

      final track = _track();
      await runtime.startVisemeTrack(track);
      expect(
        transport.calls.where((call) => call.method == 'startVisemeTimeline'),
        isEmpty,
        reason:
            'An un-ticketed timeline must not replace the current mouth owner',
      );

      flags.setRuntimeMaximum(
        MaasoFeatureFlag.avatarProjectionV2,
        FeatureRolloutMode.off,
      );
      await _flushAuthority(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.legacy);
      expect(AvatarProductionOwnership.blocksLegacyAvatarMutation, isFalse);
      transport.calls.clear();
      await runtime.startVisemeTrack(track);

      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.method, 'startVisemeTimeline');
      expect(transport.calls.single.arguments, track.toRendererJson());
    },
  );
}

Future<void> _flushAuthority(
  AvatarProjectionProductionAuthority authority,
) async {
  for (var attempt = 0; attempt < 4; attempt++) {
    authority.phase;
    await Future<void>.delayed(Duration.zero);
    await authority.waitForIdle();
  }
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  final Map<MaasoFeatureFlag, Map<String, Object?>> _rows = {};

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.values.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows[assignment.flag] = assignment.toJson();
  }
}

final class _AckingUnityTransport implements UnityAvatarTransport {
  final List<MethodCall> calls = [];
  UnityAvatarMethodCallHandler? _handler;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == UnityAvatarCommandDispatchSink.commandMethod ||
        method == UnityAvatarCommandDispatchSink.resetMethod) {
      final payload = Map<String, dynamic>.from(
        arguments! as Map<Object?, Object?>,
      )..remove('payloadJson');
      scheduleMicrotask(
        () => _handler?.call(
          MethodCall('commandResult', <String, dynamic>{
            ...payload,
            'method': method,
            'ok': true,
            'code': '',
          }),
        ),
      );
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) {
    final handler = _handler;
    if (handler == null) throw StateError('unity_handler_missing');
    return handler(call);
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    _handler = handler;
  }

  @override
  void dispose() {
    _handler = null;
  }
}

LipSyncVisemeTrack _track() => LipSyncVisemeTrack(
  envelope: const <double>[0, 0.8, 0.65, 0],
  cues: <LipSyncVisemeCue>[
    LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
    LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.aa),
    LipSyncVisemeCue(frame: 2, viseme: LipSyncViseme.ih),
    LipSyncVisemeCue(frame: 3, viseme: LipSyncViseme.sil),
  ],
);

final class _RecordingSink implements SelfAvatarProjectionDispatchSink {
  final dispatches = <SelfAvatarProjectionDispatch>[];

  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch command) async {
    dispatches.add(command);
  }
}
