import 'package:flutter/services.dart';

import 'unity_avatar_transport.dart';
import 'unity_avatar_transport_native.dart'
    if (dart.library.js_interop) 'unity_avatar_transport_web.dart'
    as platform;

UnityAvatarTransport createUnityAvatarTransport({MethodChannel? channel}) {
  if (channel != null) {
    return MethodChannelUnityAvatarTransport(channel);
  }
  return platform.createDefaultUnityAvatarTransport();
}
