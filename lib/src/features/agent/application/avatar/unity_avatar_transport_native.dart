import 'package:flutter/services.dart';

import 'unity_avatar_transport.dart';

UnityAvatarTransport createDefaultUnityAvatarTransport() =>
    MethodChannelUnityAvatarTransport(
      const MethodChannel('maaso/unity_avatar'),
    );
