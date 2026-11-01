import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(UnityAvatarRuntime.channelName);

  setUp(() {
    appServices.testMode = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    appServices.put(UnityAvatarRuntime(channel: channel));
  });

  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> mount(
    WidgetTester tester,
    FutureOr<void> Function(double, double) onTap, {
    bool hold = true,
    bool active = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 500,
          child: UnityAvatarView(
            includeWorld: true,
            holdToWalk: hold,
            viewportActive: active,
            onScreenTap: onTap,
          ),
        ),
      ),
    ),
  );

  Offset ground(WidgetTester tester, [double x = .5]) {
    final rect = tester.getRect(find.byType(UnityAvatarView));
    return Offset(rect.left + rect.width * x, rect.top + rect.height * .9);
  }

  testWidgets('a quick tap submits one target and does not become a hold', (
    tester,
  ) async {
    final points = <Offset>[];
    await mount(tester, (x, y) => points.add(Offset(x, y)));
    await tester.tapAt(ground(tester));
    await tester.pump(const Duration(seconds: 1));
    expect(points, [const Offset(.5, .9)]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('holding repeats and moving the finger updates the target', (
    tester,
  ) async {
    final points = <Offset>[];
    await mount(tester, (x, y) => points.add(Offset(x, y)));
    final gesture = await tester.startGesture(ground(tester));
    await tester.pump();
    expect(points, [const Offset(.5, .9)]);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(points.length, greaterThanOrEqualTo(3));
    expect(points, everyElement(const Offset(.5, .9)));
    await gesture.moveTo(ground(tester, .75));
    await tester.pump(const Duration(milliseconds: 240));
    expect(points.last, const Offset(.75, .9));
    await gesture.up();
    final atRelease = points.length;
    await tester.pump(const Duration(seconds: 1));
    expect(points.length, atRelease);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a second finger cannot redirect or cancel the held walk', (
    tester,
  ) async {
    final points = <Offset>[];
    await mount(tester, (x, y) => points.add(Offset(x, y)));
    final first = await tester.startGesture(ground(tester), pointer: 1);
    await tester.pump();
    final second = await tester.startGesture(ground(tester, .2), pointer: 2);
    await second.moveTo(ground(tester, .1));
    await second.up();
    await tester.pump(const Duration(milliseconds: 120));
    expect(points.length, greaterThan(1));
    expect(points, everyElement(const Offset(.5, .9)));
    await first.up();
    final count = points.length;
    await tester.pump(const Duration(seconds: 1));
    expect(points.length, count);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ordinary avatar taps never repeat by default', (tester) async {
    var calls = 0;
    await mount(tester, (_, _) => calls++, hold: false);
    final gesture = await tester.startGesture(ground(tester));
    await tester.pump(const Duration(seconds: 2));
    await gesture.up();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('slow dispatch cannot queue movement beyond pointer release', (
    tester,
  ) async {
    final pending = <Completer<void>>[];
    await mount(tester, (_, _) {
      final completer = Completer<void>();
      pending.add(completer);
      return completer.future;
    });
    final gesture = await tester.startGesture(ground(tester));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));
    expect(pending, hasLength(1));
    pending.single.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(pending, hasLength(2));
    await gesture.up();
    pending.last.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(pending, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final interruption in ['cancel', 'inactive', 'hidden', 'dispose']) {
    testWidgets('held input stops on $interruption', (tester) async {
      var calls = 0;
      void send(double x, double y) => calls++;
      await mount(tester, send);
      final gesture = await tester.startGesture(ground(tester));
      await tester.pump(const Duration(milliseconds: 600));
      switch (interruption) {
        case 'cancel':
          await gesture.cancel();
        case 'inactive':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        case 'hidden':
          await mount(tester, send, active: false);
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      final atInterruption = calls;
      await tester.pump(const Duration(seconds: 1));
      expect(calls, atInterruption);
      if (interruption != 'cancel') await gesture.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
