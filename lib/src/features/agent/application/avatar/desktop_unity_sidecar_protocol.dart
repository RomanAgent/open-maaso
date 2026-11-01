import 'dart:convert';
import 'dart:typed_data';

enum DesktopUnitySidecarMessageType {
  hello('hello'),
  ready('ready'),
  command('command'),
  avatarCommand('avatarCommand'),
  avatarResult('avatarResult'),
  worldEvent('worldEvent'),
  surface('surface'),
  event('event'),
  error('error'),
  shutdown('shutdown');

  const DesktopUnitySidecarMessageType(this.wireName);

  final String wireName;

  static DesktopUnitySidecarMessageType? tryParse(Object? value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

final class DesktopUnitySidecarProtocolFailure implements Exception {
  const DesktopUnitySidecarProtocolFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'DesktopUnitySidecarProtocolFailure($code): $message';
}

final class DesktopUnitySidecarEnvelope {
  DesktopUnitySidecarEnvelope({
    required this.session,
    required this.sequence,
    required this.type,
    Map<String, Object?> payload = const <String, Object?>{},
  }) : payload = Map<String, Object?>.unmodifiable(payload) {
    DesktopUnitySidecarProtocol.validateSessionToken(session);
    DesktopUnitySidecarProtocol.validateSequence(sequence);
    DesktopUnitySidecarProtocol.validatePayload(payload);
  }

  final String session;
  final int sequence;
  final DesktopUnitySidecarMessageType type;
  final Map<String, Object?> payload;

  Uint8List encodeFrame() => DesktopUnitySidecarProtocol.encode(this);
}

final class DesktopUnitySidecarSurface {
  const DesktopUnitySidecarSurface({
    required this.surfaceId,
    required this.width,
    required this.height,
    required this.generation,
    required this.frameSequence,
  });

  final int surfaceId;
  final int width;
  final int height;
  final int generation;
  final int frameSequence;

  static DesktopUnitySidecarSurface fromEnvelope(
    DesktopUnitySidecarEnvelope envelope,
  ) {
    if (envelope.type != DesktopUnitySidecarMessageType.surface) {
      throw const DesktopUnitySidecarProtocolFailure(
        'unexpected_message_type',
        'Expected an IOSurface message.',
      );
    }
    const expectedKeys = <String>{
      'surfaceId',
      'width',
      'height',
      'generation',
      'frameSequence',
      'pixelFormat',
    };
    if (!_hasExactKeys(envelope.payload, expectedKeys) ||
        envelope.payload['pixelFormat'] != 'bgra8Unorm_srgb') {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_surface_payload',
        'The IOSurface payload has an invalid shape or pixel format.',
      );
    }
    return DesktopUnitySidecarSurface(
      surfaceId: _boundedInt(
        envelope.payload['surfaceId'],
        minimum: 1,
        maximum: 0xffffffff,
        code: 'invalid_surface_payload',
      ),
      width: _boundedInt(
        envelope.payload['width'],
        minimum: 1,
        maximum: DesktopUnitySidecarProtocol.maximumTextureWidth,
        code: 'invalid_surface_payload',
      ),
      height: _boundedInt(
        envelope.payload['height'],
        minimum: 1,
        maximum: DesktopUnitySidecarProtocol.maximumTextureHeight,
        code: 'invalid_surface_payload',
      ),
      generation: _boundedInt(
        envelope.payload['generation'],
        minimum: 1,
        maximum: DesktopUnitySidecarProtocol.maximumSequence,
        code: 'invalid_surface_payload',
      ),
      frameSequence: _boundedInt(
        envelope.payload['frameSequence'],
        minimum: 0,
        maximum: DesktopUnitySidecarProtocol.maximumSequence,
        code: 'invalid_surface_payload',
      ),
    );
  }
}

abstract final class DesktopUnitySidecarProtocol {
  static const version = 1;
  static const maximumFrameBytes = 64 * 1024;
  static const maximumSequence = 0x7fffffff;
  static const maximumTextureWidth = 3840;
  static const maximumTextureHeight = 2160;
  static const maximumPayloadDepth = 6;
  static const maximumStringLength = 32 * 1024;
  static const minimumSessionTokenLength = 32;
  static const maximumSessionTokenLength = 128;

  static final RegExp _sessionTokenPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  static const _envelopeKeys = <String>{
    'version',
    'session',
    'sequence',
    'type',
    'payload',
  };

  static Uint8List encode(DesktopUnitySidecarEnvelope envelope) {
    final frame = utf8.encode(
      '${jsonEncode(<String, Object?>{'version': version, 'session': envelope.session, 'sequence': envelope.sequence, 'type': envelope.type.wireName, 'payload': envelope.payload})}\n',
    );
    if (frame.length > maximumFrameBytes) {
      throw const DesktopUnitySidecarProtocolFailure(
        'frame_too_large',
        'The Unity sidecar frame exceeds 64 KiB.',
      );
    }
    return Uint8List.fromList(frame);
  }

  static DesktopUnitySidecarEnvelope decode(
    List<int> frame, {
    required String expectedSession,
  }) {
    validateSessionToken(expectedSession);
    if (frame.isEmpty || frame.length > maximumFrameBytes) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_frame_size',
        'The Unity sidecar frame size is invalid.',
      );
    }
    if (frame.last != 0x0a ||
        frame
            .take(frame.length - 1)
            .any((byte) => byte == 0x0a || byte == 0x0d)) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_frame_boundary',
        'The Unity sidecar protocol requires one newline-delimited JSON frame.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame.sublist(0, frame.length - 1)));
    } on FormatException {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_json',
        'The Unity sidecar frame is not valid UTF-8 JSON.',
      );
    }
    if (decoded is! Map) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_envelope',
        'The Unity sidecar frame must contain an object.',
      );
    }
    final raw = Map<Object?, Object?>.from(decoded);
    if (!_hasExactKeys(raw, _envelopeKeys) || raw['version'] != version) {
      throw const DesktopUnitySidecarProtocolFailure(
        'unsupported_protocol',
        'The Unity sidecar protocol version or envelope shape is unsupported.',
      );
    }
    final session = raw['session'];
    final sequence = raw['sequence'];
    final type = DesktopUnitySidecarMessageType.tryParse(raw['type']);
    final rawPayload = raw['payload'];
    if (session is! String ||
        session != expectedSession ||
        sequence is! int ||
        type == null ||
        rawPayload is! Map) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_envelope',
        'The Unity sidecar envelope is invalid or unauthenticated.',
      );
    }
    final payload = <String, Object?>{};
    for (final entry in rawPayload.entries) {
      if (entry.key is! String) {
        throw const DesktopUnitySidecarProtocolFailure(
          'invalid_payload',
          'Unity sidecar payload keys must be strings.',
        );
      }
      payload[entry.key as String] = entry.value;
    }
    return DesktopUnitySidecarEnvelope(
      session: session,
      sequence: sequence,
      type: type,
      payload: payload,
    );
  }

  static void validateSessionToken(String value) {
    if (value.length < minimumSessionTokenLength ||
        value.length > maximumSessionTokenLength ||
        !_sessionTokenPattern.hasMatch(value)) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_session_token',
        'The Unity sidecar session token is invalid.',
      );
    }
  }

  static void validateSequence(int value) {
    if (value < 0 || value > maximumSequence) {
      throw const DesktopUnitySidecarProtocolFailure(
        'invalid_sequence',
        'The Unity sidecar sequence is out of range.',
      );
    }
  }

  static void validatePayload(Map<String, Object?> payload) {
    _validateJsonValue(payload, depth: 0);
  }

  static void _validateJsonValue(Object? value, {required int depth}) {
    if (depth > maximumPayloadDepth) {
      throw const DesktopUnitySidecarProtocolFailure(
        'payload_too_deep',
        'The Unity sidecar payload nesting is too deep.',
      );
    }
    if (value == null || value is bool || value is int || value is double) {
      return;
    }
    if (value is String) {
      if (value.length > maximumStringLength) {
        throw const DesktopUnitySidecarProtocolFailure(
          'payload_string_too_large',
          'The Unity sidecar payload contains an oversized string.',
        );
      }
      return;
    }
    if (value is List) {
      for (final child in value) {
        _validateJsonValue(child, depth: depth + 1);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const DesktopUnitySidecarProtocolFailure(
            'invalid_payload',
            'Unity sidecar payload keys must be strings.',
          );
        }
        _validateJsonValue(entry.value, depth: depth + 1);
      }
      return;
    }
    throw const DesktopUnitySidecarProtocolFailure(
      'invalid_payload',
      'The Unity sidecar payload contains a non-JSON value.',
    );
  }
}

bool _hasExactKeys(Map<Object?, Object?> map, Set<String> expected) =>
    map.length == expected.length &&
    map.keys.every((key) => key is String && expected.contains(key));

int _boundedInt(
  Object? value, {
  required int minimum,
  required int maximum,
  required String code,
}) {
  if (value is! int || value < minimum || value > maximum) {
    throw DesktopUnitySidecarProtocolFailure(
      code,
      'The Unity sidecar integer is out of range.',
    );
  }
  return value;
}
