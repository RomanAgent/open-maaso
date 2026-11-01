import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'unity_avatar_transport.dart';

const _eventProtocolVersion = 1;
const _maxEventBytes = 256 * 1024;
const _knownEventTypes = <String>{
  'loading',
  'progress',
  'ready',
  'unready',
  'log',
  'error',
  'commandResult',
  'worldEvent',
};

@JS('maasoUnityAvatarHost')
external JSObject? get _unityAvatarHostObject;

extension type _UnityAvatarHost._(JSObject _) implements JSObject {
  external JSNumber subscribe(JSFunction callback);

  external void unsubscribe(JSNumber subscriptionId);

  external JSPromise<JSString> invoke(JSString method, JSString argsJson);
}

@JS()
extension type _UnityAvatarHostError._(JSObject _) implements JSObject {
  external JSString? get code;

  external JSString? get message;
}

UnityAvatarTransport createDefaultUnityAvatarTransport() =>
    _WebUnityAvatarTransport();

final class _WebUnityAvatarTransport implements UnityAvatarTransport {
  UnityAvatarMethodCallHandler? _handler;
  _UnityAvatarHost? _subscribedHost;
  JSNumber? _subscriptionId;
  late final JSFunction _eventCallback = _receiveEvent.toJS;
  Future<void> _dispatchTail = Future<void>.value();
  int _latestGeneration = -1;
  int _latestSequence = -1;
  bool _disposed = false;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    if (_disposed) {
      throw MissingPluginException('Unity WebGL transport is disposed');
    }
    final host = _resolveHost();
    if (host == null) {
      throw MissingPluginException(
        'window.maasoUnityAvatarHost is unavailable',
      );
    }
    if (!_ensureSubscribed(host)) {
      throw PlatformException(
        code: 'web_subscribe_failed',
        message: 'Unity WebGL event subscription failed',
      );
    }
    try {
      await host
          .invoke(method.toJS, jsonEncode(arguments ?? const {}).toJS)
          .toDart;
      return null;
    } catch (error) {
      final hostError = _readHostError(error);
      throw PlatformException(
        code: hostError?.code ?? 'web_transport_error',
        message:
            hostError?.message ?? 'Unity WebGL command $method failed: $error',
      );
    }
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    if (_disposed) return;
    _handler = handler;
    if (handler == null) {
      _unsubscribe();
      return;
    }
    final host = _resolveHost();
    if (host != null) _ensureSubscribed(host);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _handler = null;
    _unsubscribe();
  }

  _UnityAvatarHost? _resolveHost() {
    final object = _unityAvatarHostObject;
    return object == null ? null : _UnityAvatarHost._(object);
  }

  bool _ensureSubscribed(_UnityAvatarHost host) {
    if (_subscriptionId != null) return true;
    try {
      _subscriptionId = host.subscribe(_eventCallback);
      _subscribedHost = host;
      return true;
    } catch (error) {
      _debugLog('subscribe failed: $error');
      return false;
    }
  }

  void _unsubscribe() {
    final host = _subscribedHost;
    final subscriptionId = _subscriptionId;
    _subscribedHost = null;
    _subscriptionId = null;
    if (host == null || subscriptionId == null) return;
    try {
      host.unsubscribe(subscriptionId);
    } catch (error) {
      _debugLog('unsubscribe failed: $error');
    }
  }

  void _receiveEvent(JSString rawEvent) {
    if (_disposed) return;
    final eventText = rawEvent.toDart;
    if (eventText.length > _maxEventBytes) {
      _debugLog('ignored oversized event (${eventText.length} bytes)');
      return;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(eventText);
    } catch (error) {
      _debugLog('ignored malformed event JSON: $error');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _debugLog('ignored non-object event');
      return;
    }

    final version = decoded['version'];
    final generation = decoded['generation'];
    final sequence = decoded['sequence'];
    final type = decoded['type'];
    if (version != _eventProtocolVersion ||
        generation is! int ||
        generation < 0 ||
        sequence is! int ||
        sequence < 0 ||
        type is! String ||
        !_knownEventTypes.contains(type)) {
      _debugLog('ignored invalid event envelope');
      return;
    }
    if (generation < _latestGeneration ||
        (generation == _latestGeneration && sequence <= _latestSequence)) {
      _debugLog(
        'ignored stale event generation=$generation sequence=$sequence',
      );
      return;
    }

    final payload = decoded['payload'];
    if (!_isValidPayload(type, payload)) {
      _debugLog('ignored invalid $type payload');
      return;
    }
    _latestGeneration = generation;
    _latestSequence = sequence;

    _dispatchTail = _dispatchTail
        .then((_) async {
          if (_disposed) return;
          final handler = _handler;
          if (handler == null) return;
          await handler(MethodCall(type, payload));
        })
        .catchError((Object error, StackTrace stackTrace) {
          _debugLog('event handler failed for $type: $error');
        });
  }

  bool _isValidPayload(String type, Object? payload) {
    switch (type) {
      case 'commandResult':
      case 'worldEvent':
        return payload is Map<String, dynamic>;
      case 'ready':
      case 'unready':
        return payload == null || payload is Map<String, dynamic>;
      case 'loading':
      case 'progress':
      case 'log':
      case 'error':
        return payload == null ||
            payload is String ||
            payload is num ||
            payload is Map<String, dynamic>;
    }
    return false;
  }

  void _debugLog(String message) {
    if (!kDebugMode) return;
    debugPrint('[UnityAvatarWebTransport] $message');
  }
}

({String code, String message})? _readHostError(Object error) {
  if (!error.isA<JSObject>()) return null;
  try {
    final hostError = _UnityAvatarHostError._(error as JSObject);
    final code = hostError.code?.toDart.trim() ?? '';
    final message = hostError.message?.toDart.trim() ?? '';
    if (code.isEmpty) return null;
    return (
      code: code,
      message: message.isEmpty ? 'Unity WebGL command failed' : message,
    );
  } catch (_) {
    return null;
  }
}
