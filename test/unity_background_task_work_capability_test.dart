import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'generic ready and old native loads do not advertise task work',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      await transport.emit(const MethodCall('ready'));
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      await runtime.loadAvatar('unity://matt');
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      expect(
        transport.calls.any((c) => c.method == 'avatarArbiterCommand'),
        false,
      );
      runtime.onClose();
    },
  );

  test(
    'a matched native acknowledgement enables only its loaded model',
    () async {
      final transport = _Transport()..workVersion = 1;
      final runtime = UnityAvatarRuntime(transport: transport);
      await transport.emit(const MethodCall('ready'));
      await runtime.loadAvatar('unity://matt');
      expect(runtime.supportsBackgroundTaskWorkPresentation, true);
      final epoch = runtime.backgroundTaskWorkPresentationEpoch;
      transport.workVersion = null;
      await runtime.loadAvatar('unity://joy');
      expect(runtime.backgroundTaskWorkPresentationEpoch, greaterThan(epoch));
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      await transport.emit(
        const MethodCall('commandResult', {
          'requestId': 'unmatched',
          'method': 'loadAvatar',
          'ok': true,
          'backgroundTaskWorkVersion': 1,
        }),
      );
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      runtime.onClose();
    },
  );

  test(
    'string, fractional, and future capability versions fail closed',
    () async {
      for (final version in ['1', 1.0, 3, true]) {
        final transport = _Transport()..workVersion = version;
        final runtime = UnityAvatarRuntime(transport: transport);
        await transport.emit(const MethodCall('ready'));
        await runtime.loadAvatar('unity://matt');
        expect(runtime.supportsBackgroundTaskWorkPresentation, false);
        runtime.onClose();
      }
    },
  );

  test(
    'native reset retires capability until a new model acknowledgement',
    () async {
      final transport = _Transport()..workVersion = 1;
      final runtime = UnityAvatarRuntime(transport: transport);
      await transport.emit(const MethodCall('ready'));
      await runtime.loadAvatar('unity://matt');
      expect(runtime.supportsBackgroundTaskWorkPresentation, true);
      final epoch = runtime.backgroundTaskWorkPresentationEpoch;
      await transport.emit(
        const MethodCall('unready', {'reason': 'renderer_reset'}),
      );
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      expect(runtime.backgroundTaskWorkPresentationEpoch, greaterThan(epoch));
      await transport.emit(const MethodCall('ready'));
      expect(runtime.supportsBackgroundTaskWorkPresentation, false);
      await runtime.loadAvatar('unity://matt');
      expect(runtime.supportsBackgroundTaskWorkPresentation, true);
      runtime.onClose();
    },
  );
}

class _Transport implements UnityAvatarTransport {
  UnityAvatarMethodCallHandler? handler;
  final calls = <MethodCall>[];
  Object? workVersion;
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == 'loadAvatar') {
      final packet = arguments as Map;
      scheduleMicrotask(
        () => emit(
          MethodCall('commandResult', {
            'requestId': packet['requestId'],
            'method': 'loadAvatar',
            'ok': true,
            if (workVersion != null) 'backgroundTaskWorkVersion': workVersion,
          }),
        ),
      );
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) async => handler?.call(call);
  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) =>
      this.handler = handler;
  @override
  void dispose() => handler = null;
}
