import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';

final class AvatarPortalChannelGateway implements AvatarPortalGateway {
  AvatarPortalChannelGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'maaso/avatar_portal';
  static const _maximumGeneration = 0x7fffffff;
  static const _maximumCompactTextureDimension = 1024;
  static const _maximumDesktopTextureDimension = 2048;
  static const _maximumReasonLength = 96;

  final MethodChannel _channel;
  final _events = StreamController<AvatarPortalEvent>.broadcast(sync: true);
  bool _closed = false;

  @override
  Stream<AvatarPortalEvent> get events => _events.stream;

  @override
  Future<AvatarPortalLease> acquire({
    required int generation,
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) async {
    _validateGeneration(generation);
    _validateTargetFps(targetFps);
    if (!AvatarPortalCapturePolicy.supportsSceneViewport(
      includeWorld: includeWorld,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    )) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_viewport',
        'World capture requires a bounded viewport size.',
      );
    }
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object>('acquire', <String, Object>{
        'generation': generation,
        'profile': profile.wireName,
        'targetFps': targetFps,
        if (includeWorld) ...<String, Object>{
          'includeWorld': true,
          'viewportWidth': viewportWidth!,
          'viewportHeight': viewportHeight!,
        },
      });
    } on MissingPluginException catch (error) {
      throw AvatarPortalFailure(
        'avatar_portal_unavailable',
        'The Avatar portal native bridge is unavailable.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw AvatarPortalFailure(
        error.code,
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'The native Avatar portal rejected the lease.',
        cause: error,
      );
    }
    return _parseLease(
      result,
      expectedGeneration: generation,
      maximumTextureWidth: includeWorld
          ? viewportWidth!
          : _maximumCompactTextureDimension,
      maximumTextureHeight: includeWorld
          ? viewportHeight!
          : profile == AvatarPortalProfile.desktopHigh
          ? _maximumDesktopTextureDimension
          : _maximumCompactTextureDimension,
    );
  }

  @override
  Future<void> suspend(int generation) =>
      _invokeGeneration('suspend', generation);

  @override
  Future<void> resume(int generation) =>
      _invokeGeneration('resume', generation);

  @override
  Future<void> release(int generation) =>
      _invokeGeneration('release', generation);

  Future<void> _invokeGeneration(String method, int generation) async {
    _validateGeneration(generation);
    try {
      await _channel.invokeMethod<void>(method, <String, Object>{
        'generation': generation,
      });
    } on MissingPluginException catch (error) {
      throw AvatarPortalFailure(
        'avatar_portal_unavailable',
        'The Avatar portal native bridge is unavailable.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw AvatarPortalFailure(
        error.code,
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'The native Avatar portal rejected $method.',
        cause: error,
      );
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (_closed || call.method != 'event') return false;
    final event = _parseEvent(call.arguments);
    if (event == null) return false;
    _events.add(event);
    return true;
  }

  AvatarPortalLease _parseLease(
    Object? payload, {
    required int expectedGeneration,
    required int maximumTextureWidth,
    required int maximumTextureHeight,
  }) {
    final map = _exactMap(payload, const <String>{
      'textureId',
      'width',
      'height',
      'generation',
    });
    final textureId = _boundedInt(map['textureId'], minimum: 0);
    final width = _boundedInt(
      map['width'],
      minimum: 1,
      maximum: maximumTextureWidth,
    );
    final height = _boundedInt(
      map['height'],
      minimum: 1,
      maximum: maximumTextureHeight,
    );
    final generation = _boundedInt(
      map['generation'],
      minimum: 1,
      maximum: _maximumGeneration,
    );
    if (generation != expectedGeneration) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_lease',
        'The native Avatar portal returned a stale generation.',
      );
    }
    return AvatarPortalLease(
      textureId: textureId,
      width: width,
      height: height,
      generation: generation,
    );
  }

  AvatarPortalEvent? _parseEvent(Object? payload) {
    if (payload is! Map) return null;
    final raw = Map<Object?, Object?>.from(payload);
    final type = raw['type'];
    if (type == 'firstFrame') {
      const keys = <String>{
        'type',
        'generation',
        'textureId',
        'width',
        'height',
      };
      if (!_hasExactKeys(raw, keys)) return null;
      final generation = _tryBoundedInt(
        raw['generation'],
        minimum: 1,
        maximum: _maximumGeneration,
      );
      final textureId = _tryBoundedInt(raw['textureId'], minimum: 0);
      final width = _tryBoundedInt(
        raw['width'],
        minimum: 1,
        maximum: AvatarPortalCapturePolicy.maximumSceneWidth,
      );
      final height = _tryBoundedInt(
        raw['height'],
        minimum: 1,
        maximum: AvatarPortalCapturePolicy.maximumSceneHeight,
      );
      if (generation == null ||
          textureId == null ||
          width == null ||
          height == null) {
        return null;
      }
      return AvatarPortalEvent.firstFrame(
        generation: generation,
        textureId: textureId,
        width: width,
        height: height,
      );
    }
    if (type == 'released') {
      const allowedKeys = <String>{'type', 'generation', 'reason'};
      if (!_hasOnlyKeys(raw, allowedKeys)) return null;
      final generation = raw.containsKey('generation')
          ? _tryBoundedInt(
              raw['generation'],
              minimum: 1,
              maximum: _maximumGeneration,
            )
          : 0;
      final reason = raw['reason'];
      if (generation == null ||
          reason is! String ||
          reason.isEmpty ||
          reason.length > _maximumReasonLength) {
        return null;
      }
      return AvatarPortalEvent.released(generation: generation, reason: reason);
    }
    return null;
  }

  Map<Object?, Object?> _exactMap(Object? payload, Set<String> keys) {
    if (payload is! Map) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_lease',
        'The native Avatar portal returned an invalid lease.',
      );
    }
    final map = Map<Object?, Object?>.from(payload);
    if (!_hasExactKeys(map, keys)) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_lease',
        'The native Avatar portal returned an invalid lease shape.',
      );
    }
    return map;
  }

  bool _hasExactKeys(Map<Object?, Object?> map, Set<String> expected) =>
      map.length == expected.length && _hasOnlyKeys(map, expected);

  bool _hasOnlyKeys(Map<Object?, Object?> map, Set<String> allowed) =>
      map.keys.every((key) => key is String && allowed.contains(key));

  int _boundedInt(
    Object? value, {
    required int minimum,
    int maximum = 0x1fffffffffffff,
  }) {
    final parsed = _tryBoundedInt(value, minimum: minimum, maximum: maximum);
    if (parsed == null) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_lease',
        'The native Avatar portal returned an out-of-range value.',
      );
    }
    return parsed;
  }

  int? _tryBoundedInt(
    Object? value, {
    required int minimum,
    int maximum = 0x1fffffffffffff,
  }) {
    if (value is! int || value < minimum || value > maximum) return null;
    return value;
  }

  void _validateGeneration(int generation) {
    if (generation <= 0 || generation > _maximumGeneration) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_generation',
        'Avatar portal generation must be a positive 32-bit integer.',
      );
    }
  }

  void _validateTargetFps(int targetFps) {
    if (!AvatarPortalCapturePolicy.supportsTargetFps(targetFps)) {
      throw const AvatarPortalFailure(
        'invalid_avatar_portal_target_fps',
        'Avatar portal target FPS must be 24, 30, or 60.',
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
