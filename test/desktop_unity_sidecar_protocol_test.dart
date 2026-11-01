import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/desktop_unity_sidecar_protocol.dart';

void main() {
  const session = 'abcdefghijklmnopqrstuvwxyzABCDEF_1234567890';

  test('round-trips an authenticated newline-delimited envelope', () {
    final envelope = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 7,
      type: DesktopUnitySidecarMessageType.ready,
      payload: const <String, Object?>{'processId': 42},
    );

    final frame = envelope.encodeFrame();
    final decoded = DesktopUnitySidecarProtocol.decode(
      frame,
      expectedSession: session,
    );

    expect(frame.last, 0x0a);
    expect(decoded.session, session);
    expect(decoded.sequence, 7);
    expect(decoded.type, DesktopUnitySidecarMessageType.ready);
    expect(decoded.payload, <String, Object?>{'processId': 42});
  });

  test('recognizes Avatar control and callback message types', () {
    expect(
      DesktopUnitySidecarMessageType.tryParse('avatarCommand'),
      DesktopUnitySidecarMessageType.avatarCommand,
    );
    expect(
      DesktopUnitySidecarMessageType.tryParse('avatarResult'),
      DesktopUnitySidecarMessageType.avatarResult,
    );
    expect(
      DesktopUnitySidecarMessageType.tryParse('worldEvent'),
      DesktopUnitySidecarMessageType.worldEvent,
    );
  });

  test('rejects a frame authenticated for another launch', () {
    final frame = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 1,
      type: DesktopUnitySidecarMessageType.hello,
    ).encodeFrame();

    expect(
      () => DesktopUnitySidecarProtocol.decode(
        frame,
        expectedSession: 'zyxwvutsrqponmlkjihgfedcba_1234567890ABCDEF',
      ),
      throwsA(
        isA<DesktopUnitySidecarProtocolFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_envelope',
        ),
      ),
    );
  });

  test('rejects unknown fields and unsupported protocol versions', () {
    final frame = utf8.encode(
      '${jsonEncode(<String, Object?>{'version': 2, 'session': session, 'sequence': 1, 'type': 'ready', 'payload': <String, Object?>{}, 'unexpected': true})}\n',
    );

    expect(
      () => DesktopUnitySidecarProtocol.decode(frame, expectedSession: session),
      throwsA(
        isA<DesktopUnitySidecarProtocolFailure>().having(
          (failure) => failure.code,
          'code',
          'unsupported_protocol',
        ),
      ),
    );
  });

  test('rejects embedded newlines and oversized payload strings', () {
    final valid = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 1,
      type: DesktopUnitySidecarMessageType.ready,
    ).encodeFrame();
    final split = <int>[...valid.take(valid.length - 1), 0x0a, ...valid];

    expect(
      () => DesktopUnitySidecarProtocol.decode(split, expectedSession: session),
      throwsA(
        isA<DesktopUnitySidecarProtocolFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_frame_boundary',
        ),
      ),
    );
    expect(
      () => DesktopUnitySidecarEnvelope(
        session: session,
        sequence: 2,
        type: DesktopUnitySidecarMessageType.error,
        payload: <String, Object?>{
          'message':
              'x' * (DesktopUnitySidecarProtocol.maximumStringLength + 1),
        },
      ),
      throwsA(
        isA<DesktopUnitySidecarProtocolFailure>().having(
          (failure) => failure.code,
          'code',
          'payload_string_too_large',
        ),
      ),
    );
  });

  test('parses the maximum-aspect desktop IOSurface for the active lease', () {
    final envelope = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 9,
      type: DesktopUnitySidecarMessageType.surface,
      payload: const <String, Object?>{
        'surfaceId': 73,
        'width': 1024,
        'height': 1792,
        'generation': 4,
        'frameSequence': 31,
        'pixelFormat': 'bgra8Unorm_srgb',
      },
    );

    final surface = DesktopUnitySidecarSurface.fromEnvelope(envelope);

    expect(surface.surfaceId, 73);
    expect(surface.width, 1024);
    expect(surface.height, 1792);
    expect(surface.generation, 4);
    expect(surface.frameSequence, 31);
  });

  test('rejects IOSurfaces wider than the desktop protocol bound', () {
    final tooWide = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 9,
      type: DesktopUnitySidecarMessageType.surface,
      payload: const <String, Object?>{
        'surfaceId': 73,
        'width': 3841,
        'height': 560,
        'generation': 4,
        'frameSequence': 31,
        'pixelFormat': 'bgra8Unorm_srgb',
      },
    );

    expect(
      () => DesktopUnitySidecarSurface.fromEnvelope(tooWide),
      throwsA(
        isA<DesktopUnitySidecarProtocolFailure>().having(
          (failure) => failure.code,
          'code',
          'invalid_surface_payload',
        ),
      ),
    );
  });

  test('rejects IOSurfaces taller than the desktop protocol bound', () {
    final tooTall = DesktopUnitySidecarEnvelope(
      session: session,
      sequence: 10,
      type: DesktopUnitySidecarMessageType.surface,
      payload: const <String, Object?>{
        'surfaceId': 73,
        'width': 1024,
        'height': 2161,
        'generation': 4,
        'frameSequence': 32,
        'pixelFormat': 'bgra8Unorm_srgb',
      },
    );

    expect(
      () => DesktopUnitySidecarSurface.fromEnvelope(tooTall),
      throwsA(isA<DesktopUnitySidecarProtocolFailure>()),
    );
  });

  test(
    'accepts the full-scene IOSurface width without lowering desktop height',
    () {
      final envelope = DesktopUnitySidecarEnvelope(
        session: session,
        sequence: 11,
        type: DesktopUnitySidecarMessageType.surface,
        payload: const <String, Object?>{
          'surfaceId': 74,
          'width': 1080,
          'height': 1600,
          'generation': 5,
          'frameSequence': 1,
          'pixelFormat': 'bgra8Unorm_srgb',
        },
      );
      final surface = DesktopUnitySidecarSurface.fromEnvelope(envelope);
      expect((surface.width, surface.height), (1080, 1600));
    },
  );
}
