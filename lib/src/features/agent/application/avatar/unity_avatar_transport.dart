import 'package:flutter/services.dart';

typedef UnityAvatarMethodCallHandler =
    Future<dynamic> Function(MethodCall call);

/// Platform transport used by [UnityAvatarRuntime] to exchange semantic
/// commands with the Unity renderer.
abstract interface class UnityAvatarTransport {
  Future<T?> invokeMethod<T>(String method, [Object? arguments]);

  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler);

  void dispose();
}

/// Native transport that preserves the existing MethodChannel contract.
final class MethodChannelUnityAvatarTransport implements UnityAvatarTransport {
  MethodChannelUnityAvatarTransport(this.channel);

  final MethodChannel channel;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) =>
      channel.invokeMethod<T>(method, arguments);

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    channel.setMethodCallHandler(handler);
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
  }
}
