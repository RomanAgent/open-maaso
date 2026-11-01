import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/maaso/avatar_portal');
  late List<MethodCall> calls;
  Object? acquireResult;

  setUp(() {
    calls = <MethodCall>[];
    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 320,
      'height': 560,
      'generation': 7,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'acquire') return acquireResult;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('acquire uses the bounded native lease contract', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);

    final lease = await gateway.acquire(
      generation: 7,
      profile: AvatarPortalProfile.compactBalanced,
    );
    await gateway.suspend(7);
    await gateway.resume(7);
    await gateway.release(7);

    expect(lease.textureId, 42);
    expect(lease.width, 320);
    expect(lease.height, 560);
    expect(lease.generation, 7);
    expect(calls.map((call) => call.method), <String>[
      'acquire',
      'suspend',
      'resume',
      'release',
    ]);
    expect(calls.first.arguments, <String, Object>{
      'generation': 7,
      'profile': 'compactBalanced',
      'targetFps': 30,
    });

    await gateway.close();
  });

  test('desktopHigh accepts the bounded Retina lease size', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);
    acquireResult = <String, Object>{
      'textureId': 43,
      'width': 1024,
      'height': 1792,
      'generation': 8,
    };

    final lease = await gateway.acquire(
      generation: 8,
      profile: AvatarPortalProfile.desktopHigh,
      targetFps: 60,
    );

    expect(lease.width, 1024);
    expect(lease.height, 1792);
    expect(calls.single.arguments, <String, Object>{
      'generation': 8,
      'profile': 'desktopHigh',
      'targetFps': 60,
    });
    await gateway.close();
  });

  test('world capture carries its bounded physical viewport', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);
    acquireResult = <String, Object>{
      'textureId': 44,
      'width': 1080,
      'height': 1600,
      'generation': 7,
    };
    final lease = await gateway.acquire(
      generation: 7,
      includeWorld: true,
      viewportWidth: 1080,
      viewportHeight: 1600,
    );
    expect((lease.width, lease.height), (1080, 1600));
    expect(calls.single.arguments, <String, Object>{
      'generation': 7,
      'profile': 'compactHigh',
      'targetFps': 30,
      'includeWorld': true,
      'viewportWidth': 1080,
      'viewportHeight': 1600,
    });
    await gateway.close();
  });

  test('world viewport validation happens before native acquisition', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);
    for (final size in <(int?, int?)>[
      (null, null),
      (1080, null),
      (null, 1600),
      (63, 100),
      (100, 63),
      (3841, 2160),
      (3840, 2161),
    ]) {
      await expectLater(
        gateway.acquire(
          generation: 7,
          includeWorld: true,
          viewportWidth: size.$1,
          viewportHeight: size.$2,
        ),
        throwsA(
          isA<AvatarPortalFailure>().having(
            (e) => e.code,
            'code',
            'invalid_avatar_portal_viewport',
          ),
        ),
      );
    }
    await expectLater(
      gateway.acquire(generation: 7, viewportWidth: 320, viewportHeight: 560),
      throwsA(isA<AvatarPortalFailure>()),
    );
    expect(calls, isEmpty);
    await gateway.close();
  });

  test('world lease cannot exceed the requested viewport', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);
    acquireResult = <String, Object>{
      'textureId': 44,
      'width': 1080,
      'height': 1600,
      'generation': 7,
    };
    await expectLater(
      gateway.acquire(
        generation: 7,
        includeWorld: true,
        viewportWidth: 800,
        viewportHeight: 600,
      ),
      throwsA(isA<AvatarPortalFailure>()),
    );
    await gateway.close();
  });

  test(
    'physical scene dimensions fit uniformly and reject invalid geometry',
    () {
      final landscape = AvatarPortalCapturePolicy.fitSceneViewport(
        width: 1200,
        height: 800,
        devicePixelRatio: 2,
      );
      expect(landscape, (width: 2400, height: 1600));
      final portrait = AvatarPortalCapturePolicy.fitSceneViewport(
        width: 390,
        height: 844,
        devicePixelRatio: 3,
      )!;
      expect(portrait.height, 2160);
      expect(portrait.width / portrait.height, closeTo(390 / 844, 0.001));
      expect(
        AvatarPortalCapturePolicy.fitSceneViewport(
          width: 3840,
          height: 2160,
          devicePixelRatio: 2,
        ),
        (width: 3840, height: 2160),
      );
      expect(
        AvatarPortalCapturePolicy.fitSceneViewport(
          width: 800,
          height: 600,
          devicePixelRatio: 1,
        ),
        (width: 800, height: 600),
      );
      for (final width in <double>[0, -1, double.nan, double.infinity, 1]) {
        expect(
          AvatarPortalCapturePolicy.fitSceneViewport(
            width: width,
            height: 600,
            devicePixelRatio: 2,
          ),
          isNull,
        );
      }
    },
  );

  test('acquire rejects unsupported FPS before invoking native code', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);

    await expectLater(
      gateway.acquire(generation: 7, targetFps: 48),
      throwsA(
        isA<AvatarPortalFailure>().having(
          (error) => error.code,
          'code',
          'invalid_avatar_portal_target_fps',
        ),
      ),
    );
    expect(calls, isEmpty);
    await gateway.close();
  });

  test('acquire rejects stale, extra, and oversized lease data', () async {
    final gateway = AvatarPortalChannelGateway(channel: channel);

    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 320,
      'height': 560,
      'generation': 6,
    };
    await expectLater(
      gateway.acquire(generation: 7),
      throwsA(
        isA<AvatarPortalFailure>().having(
          (error) => error.code,
          'code',
          'invalid_avatar_portal_lease',
        ),
      ),
    );

    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 320,
      'height': 560,
      'generation': 7,
      'rawPixels': 'not-allowed',
    };
    await expectLater(
      gateway.acquire(generation: 7),
      throwsA(isA<AvatarPortalFailure>()),
    );

    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 640,
      'height': 1120,
      'generation': 7,
    };
    await expectLater(
      gateway.acquire(generation: 7),
      throwsA(isA<AvatarPortalFailure>()),
    );

    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 1025,
      'height': 1792,
      'generation': 7,
    };
    await expectLater(
      gateway.acquire(generation: 7, profile: AvatarPortalProfile.desktopHigh),
      throwsA(isA<AvatarPortalFailure>()),
    );

    acquireResult = <String, Object>{
      'textureId': 42,
      'width': 1024,
      'height': 2049,
      'generation': 7,
    };
    await expectLater(
      gateway.acquire(generation: 7, profile: AvatarPortalProfile.desktopHigh),
      throwsA(isA<AvatarPortalFailure>()),
    );

    await gateway.close();
  });

  test(
    'native events are exact, bounded, and unknown events are ignored',
    () async {
      final gateway = AvatarPortalChannelGateway(channel: channel);
      final events = <AvatarPortalEvent>[];
      final subscription = gateway.events.listen(events.add);

      await _sendNativeCall(
        channel,
        const MethodCall('event', <String, Object>{
          'type': 'firstFrame',
          'generation': 7,
          'textureId': 42,
          'width': 320,
          'height': 560,
        }),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('event', <String, Object>{
          'type': 'firstFrame',
          'generation': 7,
          'textureId': 42,
          'width': 4096,
          'height': 560,
        }),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('event', <String, Object>{
          'type': 'unityCommand',
          'generation': 7,
        }),
      );
      await _sendNativeCall(
        channel,
        const MethodCall('event', <String, Object>{
          'type': 'released',
          'reason': 'memoryPressure',
        }),
      );

      expect(events, hasLength(2));
      expect(events.first.type, AvatarPortalEventType.firstFrame);
      expect(events.first.generation, 7);
      expect(events.last.type, AvatarPortalEventType.released);
      expect(events.last.generation, 0);
      expect(events.last.reason, 'memoryPressure');

      await subscription.cancel();
      await gateway.close();
    },
  );

  test('platform errors retain their native failure code', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'avatar_portal_unity_unavailable',
            message: 'Unity is not ready.',
          );
        });
    final gateway = AvatarPortalChannelGateway(channel: channel);

    await expectLater(
      gateway.acquire(generation: 1),
      throwsA(
        isA<AvatarPortalFailure>()
            .having(
              (error) => error.code,
              'code',
              'avatar_portal_unity_unavailable',
            )
            .having((error) => error.message, 'message', 'Unity is not ready.'),
      ),
    );

    await gateway.close();
  });
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final data = channel.codec.encodeMethodCall(call);
  await messenger.handlePlatformMessage(channel.name, data, (_) {});
}
