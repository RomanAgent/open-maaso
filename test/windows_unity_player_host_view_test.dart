import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/presentation/windows_unity_player_host_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WindowsUnityPlayerHostView.channelName);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('starts with bounded physical coordinates and stops on dispose', (
    tester,
  ) async {
    final pixelRatio = tester.view.devicePixelRatio;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'start') {
            return <String, Object?>{'available': true, 'running': true};
          }
          return null;
        });

    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 160,
            height: 240,
            child: WindowsUnityPlayerHostView(
              fallback: ColoredBox(color: Colors.pink),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final start = calls.firstWhere((call) => call.method == 'start');
    expect(start.arguments, <String, int>{
      'left': 0,
      'top': 0,
      'width': (160 * pixelRatio).round(),
      'height': (240 * pixelRatio).round(),
    });
    expect(find.byKey(WindowsUnityPlayerHostView.fallbackKey), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(calls.last.method, 'stop');
  });

  testWidgets('keeps fallback visible when the native host is unavailable', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'unity_windows_host_unavailable');
        });

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 160,
          height: 240,
          child: WindowsUnityPlayerHostView(
            fallback: ColoredBox(color: Colors.pink),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(WindowsUnityPlayerHostView.fallbackKey), findsOneWidget);
  });
}
