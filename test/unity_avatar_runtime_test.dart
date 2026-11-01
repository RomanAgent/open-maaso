import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(UnityAvatarRuntime.channelName);
  late List<MethodCall> calls;
  late bool autoCompleteAvatarLoads;

  setUp(() {
    calls = [];
    autoCompleteAvatarLoads = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (autoCompleteAvatarLoads && call.method == 'loadAvatar') {
            final arguments = call.arguments as Map<Object?, Object?>;
            final requestId = arguments['requestId'] as String;
            final modelUrl = arguments['modelUrl']?.toString() ?? '';
            Future<void>.microtask(
              () => _sendNativeCall(
                channel,
                MethodCall('commandResult', {
                  'requestId': requestId,
                  'method': 'loadAvatar',
                  'ok': true,
                  if (modelUrl.startsWith('https://'))
                    'capabilityProfile': _unityCapabilityProfile,
                }),
              ),
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'optional speech hints never create an unready or detached renderer',
    () async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
      final runtime = UnityAvatarRuntime(channel: channel);
      addTearDown(runtime.onClose);
      final clock = SpeechPlaybackClock(
        playbackId: 'wav-presented',
        generation: 1,
        turnId: 't',
        utteranceId: 'u',
        sequence: 1,
        state: SpeechPlaybackClockState.start,
        positionMs: 0,
        source: SpeechPlaybackClockSource.wav,
        authoritative: false,
      );
      Future<void> sendHints() async {
        await runtime.syncSpeechPlaybackClock(clock);
        await runtime.setConversationPhase('thinking', sequence: 1);
      }

      await sendHints();
      expect(
        calls,
        isEmpty,
        reason: 'ordinary audio cannot bootstrap an invisible Unity session',
      );
      await runtime.prepareView();
      final prepare = calls.single.arguments as Map<Object?, Object?>;
      final presentationId = prepare['presentationId'];
      await _sendNativeCall(channel, const MethodCall('ready'));
      expect(runtime.isReady.value, true);
      expect(runtime.presentationReady.value, false);
      calls.clear();
      await sendHints();
      expect(
        calls,
        isEmpty,
        reason:
            'retained engine readiness is not visible presentation ownership',
      );
      await _sendNativeCall(
        channel,
        MethodCall('presentationState', {
          'presentationId': presentationId,
          'attached': true,
        }),
      );
      expect(runtime.presentationReady.value, true);
      await sendHints();
      expect(calls.map((call) => call.method), [
        'syncSpeechPlaybackClock',
        'setConversationPhase',
      ]);
      expect(calls.first.arguments, clock.toJson());
      calls.clear();
      await _sendNativeCall(
        channel,
        MethodCall('presentationState', {
          'presentationId': presentationId,
          'attached': false,
        }),
      );
      await sendHints();
      expect(calls, isEmpty);
    },
  );

  test(
    'renderer prewarm starts Unity without making standby avatar visible',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);
      final AvatarRuntime renderer = runtime;
      await renderer.setLocalAvatarVisible(false);
      await renderer.prepareRenderer();
      expect(runtime.isReady.value, isFalse);
      expect(calls.map((call) => call.method), [
        'setLocalAvatarVisible',
        'prepareView',
      ]);
      await _sendNativeCall(channel, const MethodCall('ready'));
      expect(runtime.isReady.value, isTrue);
      expect(
        calls
            .where((call) => call.method == 'setLocalAvatarVisible')
            .map((call) => call.arguments),
        everyElement(containsPair('visible', false)),
      );
      expect(calls.any((call) => call.method == 'loadAvatar'), isFalse);
      runtime.onClose();
    },
  );

  test(
    'same-frame native view owner replacement keeps the underlay attached',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);
      final loginOwner = Object();
      final homeOwner = Object();
      runtime.retainNativeView(loginOwner);
      final leavingLogin = runtime.releaseNativeView(loginOwner);
      runtime.retainNativeView(homeOwner);
      await leavingLogin;
      expect(calls.where((call) => call.method == 'releaseView'), isEmpty);
      await runtime.releaseNativeView(homeOwner);
      expect(calls.where((call) => call.method == 'releaseView'), hasLength(1));
      runtime.onClose();
    },
  );

  test('an old runtime cannot detach its replacement native view', () async {
    final oldRuntime = UnityAvatarRuntime(channel: channel);
    final newRuntime = UnityAvatarRuntime(channel: channel);
    final oldOwner = Object();
    final newOwner = Object();
    oldRuntime.retainNativeView(oldOwner);
    final oldRelease = oldRuntime.releaseNativeView(oldOwner);
    newRuntime.retainNativeView(newOwner);
    await oldRelease;
    expect(calls.where((call) => call.method == 'releaseView'), isEmpty);
    await newRuntime.releaseNativeView(newOwner);
    expect(calls.where((call) => call.method == 'releaseView'), hasLength(1));
    oldRuntime.onClose();
    newRuntime.onClose();
  });

  test(
    'Unity runtime delegates to and disposes an injected transport',
    () async {
      final transport = _FakeUnityAvatarTransport();
      final runtime = UnityAvatarRuntime(transport: transport);
      final commandSink = runtime.commandDispatchSink;

      expect(runtime.commandDispatchSink, same(commandSink));

      await runtime.setMouthOpen(0.4);
      await transport.emit(const MethodCall('ready'));

      expect(runtime.isReady.value, isTrue);
      expect(
        transport.calls.map((call) => call.method),
        containsAllInOrder(<String>['setMouthOpen', 'setExpression']),
      );
      expect(transport.calls.first.arguments, containsPair('value', 0.4));

      runtime.onClose();

      expect(transport.disposed, isTrue);
      expect(transport.handler, isNull);
      expect((commandSink as UnityAvatarCommandDispatchSink).isClosed, isTrue);
    },
  );

  test(
    'Unity runtime surfaces not-ready for transient avatar actions',
    () async {
      final transport = _FakeUnityAvatarTransport(
        errors: <String, Object>{
          'playPrimitive': PlatformException(
            code: 'not_ready',
            message: 'Unity WebGL is loading',
          ),
        },
      );
      final runtime = UnityAvatarRuntime(transport: transport);

      await expectLater(
        runtime.playPrimitive('wave'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'not_ready',
          ),
        ),
      );

      runtime.onClose();
    },
  );

  test('Unity runtime rejects channel and transport together', () {
    final transport = _FakeUnityAvatarTransport();

    expect(
      () => UnityAvatarRuntime(channel: channel, transport: transport),
      throwsArgumentError,
    );
  });

  test('Unity runtime serializes avatar commands over MethodChannel', () async {
    final runtime = UnityAvatarRuntime(channel: channel);

    await runtime.loadAvatar('unity://masso/avatar_agent', {
      'scene': 'MaasoAvatar/Scenes/Companion',
      'avatar': 'agent',
      'background': 'transparent',
      'framing': 'front_full_body',
    });
    await runtime.setExpressionParams(
      const AvatarExpressionParams(happy: 0.8, mouthSmile: 0.7),
    );
    await runtime.setMouthOpen(2);
    await runtime.setGaze(
      const AvatarGaze(
        eyeX: 0.2,
        eyeY: -0.3,
        headX: 0.4,
        headY: -0.5,
        headRoll: 2,
        upperBodyX: -2,
      ),
    );
    await runtime.startLipSync(const [0.1, 0.5, 0.2], frameRate: 30);
    await runtime.playPrimitive('wave', {'durationMs': 900});
    await runtime.playAnimationClip('wave', {'loop': false});
    await runtime.setHandIkTarget('explain');
    await runtime.setBodyPose(const AvatarBodyPose(yaw: 0.4, z: 0.2));
    await runtime.playMotion('turn_back');
    await runtime.playMotionSequence(const [
      AvatarMotionStep(clip: 'wave', atMs: 0),
      AvatarMotionStep(primitive: 'nod', delayMs: 900),
    ]);
    await runtime.setFraming('full');
    await runtime.setViewportSafeArea(
      const AvatarViewportSafeArea(top: 0.18, bottom: 0.31),
    );
    await runtime.setWorldTimeOfDay('afternoon');
    await runtime.setWorldCamera('hero_full_body');
    await runtime.reactToScreenTap(normalizedX: 1.4, normalizedY: -0.5);
    await runtime.pause();
    await runtime.resume();

    expect(
      calls.map((call) => call.method),
      containsAllInOrder([
        'loadAvatar',
        'setExpression',
        'setMouthOpen',
        'setGaze',
        'startLipSync',
        'playPrimitive',
        'playAnimationClip',
        'setHandIkTarget',
        'setBodyPose',
        'playMotion',
        'playMotionSequence',
        'setFraming',
        'setViewportSafeArea',
        'setWorldTimeOfDay',
        'setWorldCamera',
        'reactToScreenTap',
        'pause',
        'resume',
      ]),
    );

    final mouthArgs =
        calls.firstWhere((call) => call.method == 'setMouthOpen').arguments
            as Map<Object?, Object?>;
    expect(mouthArgs['value'], 1);

    final gazeArgs =
        calls.firstWhere((call) => call.method == 'setGaze').arguments
            as Map<Object?, Object?>;
    expect(gazeArgs['headRoll'], 1);
    expect(gazeArgs['upperBodyX'], -1);

    final sequenceArgs =
        calls
                .firstWhere((call) => call.method == 'playMotionSequence')
                .arguments
            as Map<Object?, Object?>;
    final steps = sequenceArgs['steps'] as List<Object?>;
    expect(steps, hasLength(2));

    final viewportArgs =
        calls
                .firstWhere((call) => call.method == 'setViewportSafeArea')
                .arguments
            as Map<Object?, Object?>;
    expect(viewportArgs['topSafeViewport'], 0.18);
    expect(viewportArgs['bottomSafeViewport'], 0.31);

    final avatarArgs =
        calls.firstWhere((call) => call.method == 'loadAvatar').arguments
            as Map<Object?, Object?>;
    expect(avatarArgs['modelUrl'], 'unity://masso/avatar_agent');
    expect(avatarArgs['requestId'], isNotEmpty);
    expect(
      avatarArgs['config'],
      containsPair('scene', 'MaasoAvatar/Scenes/Companion'),
    );
    expect(avatarArgs, isNot(contains('resource')));

    final tapArgs =
        calls.firstWhere((call) => call.method == 'reactToScreenTap').arguments
            as Map<Object?, Object?>;
    expect(tapArgs['x'], 1);
    expect(tapArgs['y'], 0);
  });

  test('Unity avatar load completes only after native success', () async {
    autoCompleteAvatarLoads = false;
    final runtime = UnityAvatarRuntime(channel: channel);
    var completed = false;

    final load = runtime
        .loadAvatar('https://assets.example.com/avatar.bundle', {
          'assetName': 'Avatar',
          'approvedAssetSha256': 'a' * 64,
          'approvedAssetBytes': 4096,
        })
        .whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(completed, isFalse);
    final call = calls.singleWhere(
      (candidate) => candidate.method == 'loadAvatar',
    );
    final arguments = call.arguments as Map<Object?, Object?>;
    final requestId = arguments['requestId'] as String;
    expect(arguments['config'], containsPair('approvedAssetBytes', 4096));

    await _sendNativeCall(
      channel,
      MethodCall('commandResult', {
        'requestId': requestId,
        'method': 'loadAvatar',
        'ok': true,
        'cacheHit': false,
        'capabilityProfile': _unityCapabilityProfile,
      }),
    );

    await load;
    expect(completed, isTrue);
  });

  test(
    'Unity publishes only a matched authoritative capability profile',
    () async {
      autoCompleteAvatarLoads = false;
      final runtime = UnityAvatarRuntime(channel: channel);
      final profiles = <AvatarCapabilityProfile>[];
      final subscription = runtime.capabilityProfileChanges.listen(
        profiles.add,
      );
      addTearDown(subscription.cancel);
      addTearDown(runtime.onClose);

      final load = runtime.loadAvatar(
        'https://assets.example.com/avatar.bundle',
      );
      await Future<void>.delayed(Duration.zero);
      final call = calls.singleWhere(
        (candidate) => candidate.method == 'loadAvatar',
      );
      final requestId =
          (call.arguments as Map<Object?, Object?>)['requestId'] as String;

      await _sendNativeCall(
        channel,
        MethodCall('commandResult', {
          'requestId': 'stale-request',
          'method': 'loadAvatar',
          'ok': true,
          'capabilityProfile': _unityCapabilityProfile,
        }),
      );
      expect(
        runtime.activeCapabilityProfile.state,
        AvatarCapabilityState.unknown,
      );

      await _sendNativeCall(
        channel,
        MethodCall('commandResult', {
          'requestId': requestId,
          'method': 'loadAvatar',
          'ok': true,
          'capabilityProfile': _unityCapabilityProfile,
        }),
      );
      await load;

      expect(
        runtime.activeCapabilityProfile.state,
        AvatarCapabilityState.supported,
      );
      expect(
        runtime.activeCapabilityProfile.source,
        AvatarCapabilitySource.unity,
      );
      expect(profiles.map((profile) => profile.state), [
        AvatarCapabilityState.supported,
      ]);
    },
  );

  for (final invalidProfile in <String, Object?>{
    'missing': null,
    'catalog sourced': {..._unityCapabilityProfile, 'source': 'catalog'},
    'unknown': _unknownUnityCapabilityProfile,
    'malformed': 'not-a-profile',
  }.entries) {
    test(
      'remote Avatar rejects ${invalidProfile.key} capability result',
      () async {
        autoCompleteAvatarLoads = false;
        final runtime = UnityAvatarRuntime(channel: channel);
        final profiles = <AvatarCapabilityProfile>[];
        final subscription = runtime.capabilityProfileChanges.listen(
          profiles.add,
        );
        addTearDown(subscription.cancel);
        addTearDown(runtime.onClose);

        final load = runtime.loadAvatar(
          'https://assets.example.com/invalid-profile.bundle',
        );
        final expectation = expectLater(load, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        final call = calls.singleWhere(
          (candidate) => candidate.method == 'loadAvatar',
        );
        final requestId =
            (call.arguments as Map<Object?, Object?>)['requestId'] as String;

        await _sendNativeCall(
          channel,
          MethodCall('commandResult', {
            'requestId': requestId,
            'method': 'loadAvatar',
            'ok': true,
            if (invalidProfile.value != null)
              'capabilityProfile': invalidProfile.value,
          }),
        );

        await expectation;
        expect(
          runtime.activeCapabilityProfile,
          AvatarCapabilityProfile.unknown,
        );
        expect(profiles, isEmpty);
      },
    );
  }

  test('Unity rejects descriptor blockers before dispatch', () async {
    final runtime = UnityAvatarRuntime(channel: channel);
    addTearDown(runtime.onClose);
    final incompatible = <String, Object>{
      ..._unityCapabilityProfile,
      'state': 'incompatible',
      'rig': {
        ...(_unityCapabilityProfile['rig']! as Map<String, Object>),
        'humanoid': false,
      },
      'issues': const [
        {'code': 'missing_humanoid', 'severity': 'blocker'},
      ],
    };

    await expectLater(
      runtime.loadAvatar('https://assets.example.com/blocked.vrm', {
        'capabilityProfile': incompatible,
      }),
      throwsStateError,
    );
    expect(calls.where((call) => call.method == 'loadAvatar'), isEmpty);
  });

  test('Windows JSON callback completes an avatar command receipt', () async {
    autoCompleteAvatarLoads = false;
    final runtime = UnityAvatarRuntime(channel: channel);
    final load = runtime.loadAvatar('unity://masso/avatar_agent');
    await Future<void>.delayed(Duration.zero);
    final call = calls.singleWhere(
      (candidate) => candidate.method == 'loadAvatar',
    );
    final requestId =
        (call.arguments as Map<Object?, Object?>)['requestId'] as String;

    await _sendNativeCall(
      channel,
      MethodCall(
        'commandResult',
        jsonEncode(<String, Object?>{
          'requestId': requestId,
          'method': 'loadAvatar',
          'ok': true,
        }),
      ),
    );

    await load;
  });

  test('Unity avatar load skips an already loaded bundle', () async {
    final runtime = UnityAvatarRuntime(channel: channel);
    final config = {
      'assetName': 'Avatar',
      'approvedAssetSha256': 'a' * 64,
      'approvedAssetBytes': 4096,
    };

    await runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );
    await runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );

    expect(calls.where((call) => call.method == 'loadAvatar'), hasLength(1));
  });

  test(
    'Unity avatar load treats VRM format as part of its cache key',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);
      final hash = 'c' * 64;

      await runtime.loadAvatar('https://assets.example.com/avatar.vrm', {
        'assetFormat': 'vrm',
        'approvedAssetSha256': hash,
      });
      await runtime.loadAvatar('https://assets.example.com/avatar.vrm', {
        'assetFormat': 'vrm_1_0',
        'approvedAssetSha256': hash,
      });

      expect(calls.where((call) => call.method == 'loadAvatar'), hasLength(2));
    },
  );

  test('Unity avatar load retries the current bundle after unready', () async {
    final runtime = UnityAvatarRuntime(channel: channel);
    final config = {'assetName': 'Avatar', 'approvedAssetSha256': 'a' * 64};

    await runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );
    await _sendNativeCall(channel, const MethodCall('unready'));
    await runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );

    expect(calls.where((call) => call.method == 'loadAvatar'), hasLength(2));
  });

  test(
    'model load epoch changes only when native model cache is lost',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);
      final AvatarRuntime renderer = runtime;
      expect(renderer.modelLoadEpoch, 0);

      await runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      await runtime.setLocalAvatarVisible(true);
      await _sendNativeCall(channel, const MethodCall('ready'));
      expect(renderer.modelLoadEpoch, 0);

      await _sendNativeCall(
        channel,
        const MethodCall('unready', {'reason': 'detached'}),
      );
      await _sendNativeCall(channel, const MethodCall('ready'));
      expect(renderer.modelLoadEpoch, 0);
      expect(
        (calls
                .lastWhere((call) => call.method == 'setLocalAvatarVisible')
                .arguments
            as Map<Object?, Object?>)['visible'],
        isTrue,
      );

      await _sendNativeCall(
        channel,
        const MethodCall('unready', {'reason': 'renderer_reset'}),
      );
      expect(renderer.modelLoadEpoch, 1);
      await _sendNativeCall(channel, const MethodCall('ready'));
      expect(
        (calls
                .lastWhere((call) => call.method == 'setLocalAvatarVisible')
                .arguments
            as Map<Object?, Object?>)['visible'],
        isFalse,
      );
      await runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      expect(calls.where((call) => call.method == 'loadAvatar'), hasLength(2));
      runtime.onClose();
    },
  );

  test(
    'account-boundary avatar reset waits for renderer readiness without blocking',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await runtime.resetAvatarForAccountBoundary(
        'unity://masso/avatar_agent',
        const {'avatar': 'agent'},
      );

      expect(runtime.modelLoadEpoch, 1);

      expect(calls.where((call) => call.method == 'loadAvatar'), isEmpty);

      await _sendNativeCall(channel, const MethodCall('ready'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final loadCalls = calls
          .where((call) => call.method == 'loadAvatar')
          .toList(growable: false);
      expect(loadCalls, hasLength(1));
      expect(
        (loadCalls.single.arguments as Map<Object?, Object?>)['modelUrl'],
        'unity://masso/avatar_agent',
      );
    },
  );

  test(
    'new account avatar load supersedes a deferred boundary reset',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await runtime.resetAvatarForAccountBoundary(
        'unity://masso/avatar_agent',
        const {'avatar': 'agent'},
      );
      await runtime.loadAvatar('unity://masso/account_avatar', const {
        'avatar': 'account-avatar',
      });
      await _sendNativeCall(channel, const MethodCall('ready'));
      await Future<void>.delayed(Duration.zero);

      final loadCalls = calls
          .where((call) => call.method == 'loadAvatar')
          .toList(growable: false);
      expect(loadCalls, hasLength(1));
      expect(
        (loadCalls.single.arguments as Map<Object?, Object?>)['modelUrl'],
        'unity://masso/account_avatar',
      );
    },
  );

  test(
    'renderer retry fails an in-flight avatar load and redispatches',
    () async {
      final transport = _FakeUnityAvatarTransport();
      final runtime = UnityAvatarRuntime(
        transport: transport,
        avatarLoadTimeout: const Duration(seconds: 1),
      );
      addTearDown(runtime.onClose);
      final config = {'assetName': 'Avatar', 'approvedAssetSha256': 'a' * 64};

      final first = runtime.loadAvatar(
        'https://assets.example.com/avatar.bundle',
        config,
      );
      final firstExpectation = expectLater(
        first,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('retry'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final firstRequestId =
          (transport.calls.single.arguments
                  as Map<Object?, Object?>)['requestId']
              as String;

      await transport.emit(const MethodCall('unready', {'reason': 'retry'}));
      await firstExpectation.timeout(const Duration(milliseconds: 200));

      final second = runtime.loadAvatar(
        'https://assets.example.com/avatar.bundle',
        config,
      );
      await Future<void>.delayed(Duration.zero);
      final loadCalls = transport.calls
          .where((call) => call.method == 'loadAvatar')
          .toList(growable: false);
      expect(loadCalls, hasLength(2));
      final secondRequestId =
          (loadCalls.last.arguments as Map<Object?, Object?>)['requestId']
              as String;
      expect(secondRequestId, isNot(firstRequestId));

      expect(
        await transport.emit(
          MethodCall('commandResult', {
            'requestId': firstRequestId,
            'method': 'loadAvatar',
            'ok': true,
          }),
        ),
        isFalse,
      );
      await transport.emit(
        MethodCall('commandResult', {
          'requestId': secondRequestId,
          'method': 'loadAvatar',
          'ok': true,
          'capabilityProfile': _unityCapabilityProfile,
        }),
      );
      await second.timeout(const Duration(milliseconds: 200));
    },
  );

  test('soft unready keeps an in-flight and loaded avatar lease', () async {
    final transport = _FakeUnityAvatarTransport();
    final runtime = UnityAvatarRuntime(
      transport: transport,
      avatarLoadTimeout: const Duration(seconds: 1),
    );
    addTearDown(runtime.onClose);
    final config = {'assetName': 'Avatar', 'approvedAssetSha256': 'a' * 64};

    final first = runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );
    await Future<void>.delayed(Duration.zero);
    final firstRequestId =
        (transport.calls.single.arguments as Map<Object?, Object?>)['requestId']
            as String;
    await transport.emit(const MethodCall('unready', {'reason': 'detached'}));
    final joined = runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );
    expect(
      transport.calls.where((call) => call.method == 'loadAvatar'),
      hasLength(1),
    );

    await transport.emit(
      MethodCall('commandResult', {
        'requestId': firstRequestId,
        'method': 'loadAvatar',
        'ok': true,
        'capabilityProfile': _unityCapabilityProfile,
      }),
    );
    await Future.wait(<Future<void>>[first, joined]);

    await transport.emit(const MethodCall('unready', {'reason': 'bfcache'}));
    await runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      config,
    );
    expect(
      transport.calls.where((call) => call.method == 'loadAvatar'),
      hasLength(1),
    );
  });

  test(
    'renderer loss during dispatch does not leak pending receipt errors',
    () async {
      await _expectNoUncaughtDispatchReceiptError((runtime, transport) async {
        transport.failMethod = 'loadAvatar';
        await expectLater(
          runtime.loadAvatar('https://assets.example.com/avatar.bundle'),
          throwsStateError,
        );
      });
    },
  );

  test('Unity avatar load exposes native validation failure', () async {
    autoCompleteAvatarLoads = false;
    final runtime = UnityAvatarRuntime(channel: channel);

    final load = runtime.loadAvatar(
      'https://assets.example.com/avatar.bundle',
      {'assetName': 'Avatar', 'approvedAssetSha256': 'b' * 64},
    );
    await Future<void>.delayed(Duration.zero);
    final call = calls.singleWhere(
      (candidate) => candidate.method == 'loadAvatar',
    );
    final requestId =
        (call.arguments as Map<Object?, Object?>)['requestId'] as String;
    final expectation = expectLater(
      load,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('checksum_mismatch'),
        ),
      ),
    );

    await _sendNativeCall(
      channel,
      MethodCall('commandResult', {
        'requestId': requestId,
        'method': 'loadAvatar',
        'ok': false,
        'code': 'checksum_mismatch',
        'message': 'Avatar bundle checksum mismatch',
      }),
    );

    await expectation;
  });

  test('Unity avatar load times out without a native result', () async {
    autoCompleteAvatarLoads = false;
    final runtime = UnityAvatarRuntime(
      channel: channel,
      avatarLoadTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      runtime.loadAvatar('unity://masso/avatar_agent'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
  });

  test('new Unity avatar load supersedes the pending request', () async {
    autoCompleteAvatarLoads = false;
    final runtime = UnityAvatarRuntime(channel: channel);

    final first = runtime.loadAvatar('unity://masso/avatar_agent');
    final firstExpectation = expectLater(first, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final second = runtime.loadAvatar('unity://masso/modular_anime_female');
    await Future<void>.delayed(Duration.zero);
    final secondCall = calls.lastWhere(
      (candidate) => candidate.method == 'loadAvatar',
    );
    final secondRequestId =
        (secondCall.arguments as Map<Object?, Object?>)['requestId'] as String;

    await _sendNativeCall(
      channel,
      MethodCall('commandResult', {
        'requestId': secondRequestId,
        'method': 'loadAvatar',
        'ok': true,
      }),
    );

    await firstExpectation;
    await second;
  });

  test(
    'Unity runtime reapplies viewport safe area when native scene becomes ready',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await runtime.setViewportSafeArea(
        const AvatarViewportSafeArea(top: 0.22, bottom: 0.33),
      );
      await _sendNativeCall(channel, const MethodCall('ready'));

      expect(runtime.isReady.value, isTrue);
      final safeAreaCalls = calls
          .where((call) => call.method == 'setViewportSafeArea')
          .toList(growable: false);
      expect(safeAreaCalls, hasLength(2));
      final replayArgs = safeAreaCalls.last.arguments as Map<Object?, Object?>;
      expect(replayArgs['topSafeViewport'], 0.22);
      expect(replayArgs['bottomSafeViewport'], 0.33);
    },
  );

  test(
    'Unity runtime sends neutral expression when native scene becomes ready',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await _sendNativeCall(channel, const MethodCall('ready'));

      expect(runtime.isReady.value, isTrue);
      final expressionCalls = calls
          .where((call) => call.method == 'setExpression')
          .toList(growable: false);
      expect(expressionCalls, hasLength(1));
      final args = expressionCalls.single.arguments as Map<Object?, Object?>;
      expect(args['eyeOpen'], 1);
      expect(args['mouthOpen'], 0);
    },
  );

  test(
    'Unity runtime serializes renderer-neutral night world lighting',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await runtime.setWorldLighting(AvatarWorldLighting.night);

      final call = calls.singleWhere(
        (candidate) => candidate.method == 'setWorldTimeOfDay',
      );
      final arguments = call.arguments as Map<Object?, Object?>;
      expect(arguments['timeOfDay'], 'night');
    },
  );

  test(
    'Unity runtime replays the latest world lighting when native scene is ready',
    () async {
      final runtime = UnityAvatarRuntime(channel: channel);

      await runtime.setWorldLighting(AvatarWorldLighting.night);
      await _sendNativeCall(channel, const MethodCall('ready'));

      final lightingCalls = calls
          .where((candidate) => candidate.method == 'setWorldTimeOfDay')
          .toList(growable: false);
      expect(lightingCalls, hasLength(2));
      final replayArguments =
          lightingCalls.last.arguments as Map<Object?, Object?>;
      expect(replayArguments['timeOfDay'], 'night');
    },
  );
}

final class _FakeUnityAvatarTransport implements UnityAvatarTransport {
  _FakeUnityAvatarTransport({this.errors = const <String, Object>{}});

  final calls = <MethodCall>[];
  final Map<String, Object> errors;
  UnityAvatarMethodCallHandler? handler;
  bool disposed = false;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    final error = errors[method];
    if (error != null) throw error;
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    this.handler = handler;
  }

  Future<dynamic> emit(MethodCall call) {
    final currentHandler = handler;
    if (currentHandler == null) {
      throw StateError('No Unity avatar transport handler is registered');
    }
    return currentHandler(call);
  }

  @override
  void dispose() {
    disposed = true;
    handler = null;
  }
}

final class _UnreadyDuringInvokeTransport implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? handler;
  String? failMethod;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method != failMethod) return null;
    final currentHandler = handler;
    if (currentHandler == null) {
      throw StateError('No Unity avatar transport handler is registered');
    }
    await currentHandler(const MethodCall('unready', {'reason': 'error'}));
    throw PlatformException(
      code: 'send_failed',
      message: 'renderer failed while dispatching $method',
    );
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    this.handler = handler;
  }

  Future<dynamic> emit(MethodCall call) {
    final currentHandler = handler;
    if (currentHandler == null) {
      throw StateError('No Unity avatar transport handler is registered');
    }
    return currentHandler(call);
  }

  @override
  void dispose() {
    handler = null;
  }
}

Future<void> _expectNoUncaughtDispatchReceiptError(
  Future<void> Function(
    UnityAvatarRuntime runtime,
    _UnreadyDuringInvokeTransport transport,
  )
  operation,
) async {
  final uncaught = <Object>[];
  final guarded = runZonedGuarded<Future<void>>(() async {
    final transport = _UnreadyDuringInvokeTransport();
    final runtime = UnityAvatarRuntime(
      transport: transport,
      avatarLoadTimeout: const Duration(milliseconds: 200),
    );
    try {
      await operation(runtime, transport);
      await Future<void>.delayed(Duration.zero);
    } finally {
      runtime.onClose();
    }
  }, (error, _) => uncaught.add(error));
  await guarded;
  await Future<void>.delayed(Duration.zero);
  expect(uncaught, isEmpty);
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}

const _unityCapabilityProfile = <String, Object>{
  'schemaVersion': 1,
  'source': 'unity',
  'state': 'supported',
  'rig': <String, Object>{
    'humanoid': true,
    'head': true,
    'leftEye': true,
    'rightEye': true,
  },
  'behavior': <String, Object>{
    'lookAt': true,
    'lipSync': true,
    'blink': true,
    'expressions': true,
  },
  'render': <String, Object>{
    'renderable': true,
    'rendererCount': 2,
    'skinnedMeshCount': 1,
    'vertexCount': 64000,
    'triangleCount': 96000,
    'materialCount': 6,
    'textureCount': 8,
    'maxTextureSize': 2048,
    'estimatedTextureBytes': 25165824,
  },
  'issues': <Object>[],
};

const _unknownUnityCapabilityProfile = <String, Object>{
  'schemaVersion': 1,
  'source': 'unity',
  'state': 'unknown',
  'rig': <String, Object>{},
  'behavior': <String, Object>{},
  'render': <String, Object>{},
  'issues': <Object>[],
};
