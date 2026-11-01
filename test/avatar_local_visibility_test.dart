import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'companion hidden decision survives renderer registration and first ready',
    () async {
      final active = ActiveAvatarRuntime();
      await active.setLocalAvatarVisible(false);
      final wire = _Wire();
      final unity = UnityAvatarRuntime(transport: wire);
      active.register(unity);
      await Future<void>.delayed(Duration.zero);
      expect(wire.calls.first.method, 'setLocalAvatarVisible');
      expect(wire.calls.first.arguments, {'visible': false});
      wire.calls.clear();
      await wire.handler!(const MethodCall('ready'));
      expect(wire.calls.first.method, 'setLocalAvatarVisible');
      expect(wire.calls.first.arguments, {'visible': false});
      unity.onClose();
    },
  );
  test(
    'soft view detach preserves visibility but a new scene stays hidden',
    () async {
      final wire = _Wire();
      final unity = UnityAvatarRuntime(transport: wire);
      await unity.setLocalAvatarVisible(true);
      await unity.setLocalAvatarVisible(false);
      wire.calls.clear();
      await wire.handler!(const MethodCall('ready'));
      expect(wire.calls.first.arguments, {'visible': false});
      await unity.setLocalAvatarVisible(true);
      for (final reason in ['detached', 'bfcache']) {
        await wire.handler!(MethodCall('unready', {'reason': reason}));
        wire.calls.clear();
        await wire.handler!(const MethodCall('ready'));
        expect(wire.calls.first.method, 'setLocalAvatarVisible');
        expect(wire.calls.first.arguments, {'visible': true});
        expect(unity.modelLoadEpoch, 0);
      }
      await wire.handler!(const MethodCall('unready', {'reason': 'retry'}));
      wire.calls.clear();
      await wire.handler!(const MethodCall('ready'));
      expect(unity.modelLoadEpoch, 1);
      expect(wire.calls.first.method, 'setLocalAvatarVisible');
      expect(wire.calls.first.arguments, {'visible': false});
      // Native engine readiness cannot reveal the bundled/default model. The
      // current selection/entrance owner must explicitly authorize visibility.
      await unity.setLocalAvatarVisible(true);
      expect(wire.calls.last.method, 'setLocalAvatarVisible');
      expect(wire.calls.last.arguments, {'visible': true});
      unity.onClose();
    },
  );
  test('renderer defaults hidden until ownership is supplied', () async {
    final wire = _Wire();
    final unity = UnityAvatarRuntime(transport: wire);
    await wire.handler!(const MethodCall('ready'));
    expect(wire.calls.first.method, 'setLocalAvatarVisible');
    expect(wire.calls.first.arguments, {'visible': false});
    unity.onClose();
  });
}

class _Wire implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? handler;
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? value) =>
      handler = value;
  @override
  void dispose() => handler = null;
}
