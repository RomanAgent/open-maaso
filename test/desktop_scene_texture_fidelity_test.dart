import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/desktop_unity_sidecar_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Retina scene pixels survive fitting, native lease and IOSurface decode',
    () async {
      final viewport = AvatarPortalCapturePolicy.fitSceneViewport(
        width: 800,
        height: 632,
        devicePixelRatio: 2,
      )!;
      expect(viewport, (width: 1600, height: 1264));
      const channel = MethodChannel('maaso/test_desktop_fidelity');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'acquire') return null;
            final arguments = call.arguments as Map;
            expect(arguments['viewportWidth'], viewport.width);
            expect(arguments['viewportHeight'], viewport.height);
            return <String, int>{
              'textureId': 7,
              'width': viewport.width,
              'height': viewport.height,
              'generation': 1,
            };
          });
      final gateway = AvatarPortalChannelGateway(channel: channel);
      try {
        final lease = await gateway.acquire(
          generation: 1,
          includeWorld: true,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
        );
        expect((lease.width, lease.height), (1600, 1264));
        final frame = DesktopUnitySidecarSurface.fromEnvelope(
          DesktopUnitySidecarEnvelope(
            session: 'abcdefghijklmnopqrstuvwxyzABCDEF_1234567890',
            sequence: 1,
            type: DesktopUnitySidecarMessageType.surface,
            payload: const <String, Object?>{
              'surfaceId': 7,
              'width': 3840,
              'height': 2160,
              'generation': 1,
              'frameSequence': 1,
              'pixelFormat': 'bgra8Unorm_srgb',
            },
          ),
        );
        expect((frame.width, frame.height), (3840, 2160));
      } finally {
        await gateway.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
