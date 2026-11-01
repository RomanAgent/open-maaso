import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
  });

  tearDown(() async {
    await appServices.reset();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool active = true,
    void Function(double, double)? onTap,
  }) => tester.pumpWidget(
    MaterialApp(
      home: UnityAvatarView(
        viewportActive: active,
        showLoadingPlaceholder: false,
        onScreenTap: onTap,
      ),
    ),
  );

  Future<void> tap(WidgetTester tester, Offset normalized) async {
    final rect = tester.getRect(find.byType(UnityAvatarView));
    await tester.tapAt(
      rect.topLeft +
          Offset(rect.width * normalized.dx, rect.height * normalized.dy),
    );
    await tester.pump();
  }

  testWidgets('Home attention uses the active runtime, not the host runtime', (
    tester,
  ) async {
    final host = appServices.put<UnityAvatarRuntime>(_PreparationRuntime());
    final selected = _AttentionRuntime();
    appServices.put(ActiveAvatarRuntime()..register(selected));
    await mount(tester);
    await tap(tester, const Offset(.8, .3));
    expect(selected.points, [const Offset(.8, .3)]);
    expect((host as _PreparationRuntime).points, isEmpty);
    await tester.pump(const Duration(seconds: 8));
    expect(selected.gazeWrites, 0);
    expect(selected.gazeClears, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a later tap is a new attention without a Dart return timer', (
    tester,
  ) async {
    final selected = _AttentionRuntime();
    appServices.put(ActiveAvatarRuntime()..register(selected));
    await mount(tester);
    await tap(tester, const Offset(.2, .4));
    await tester.pump(const Duration(seconds: 3));
    await tap(tester, const Offset(.9, .7));
    await tester.pump(const Duration(seconds: 8));
    expect(selected.points, [const Offset(.2, .4), const Offset(.9, .7)]);
    expect(selected.gazeWrites, 0);
    expect(selected.gazeClears, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('old attention cannot write after the active model changes', (
    tester,
  ) async {
    final previous = _AttentionRuntime();
    final active = appServices.put(ActiveAvatarRuntime()..register(previous));
    await mount(tester);
    await tap(tester, const Offset(.2, .4));
    final current = _AttentionRuntime();
    active.register(current);
    await tap(tester, const Offset(.9, .7));
    await current.setGaze(
      const AvatarGaze(eyeX: 1, eyeY: 0, headX: 1, headY: 0),
    );
    await tester.pump(const Duration(seconds: 8));
    expect(previous.points, [const Offset(.2, .4)]);
    expect(current.points, [const Offset(.9, .7)]);
    expect(previous.gazeWrites, 0);
    expect(previous.gazeClears, 0);
    expect(current.gazeWrites, 1);
    expect(current.gazeClears, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an inactive viewport and background cannot send attention', (
    tester,
  ) async {
    final selected = _AttentionRuntime();
    appServices.put(ActiveAvatarRuntime()..register(selected));
    await mount(tester, active: false);
    await tap(tester, const Offset(.2, .4));
    expect(selected.points, isEmpty);
    await mount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tap(tester, const Offset(.2, .4));
    expect(selected.points, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tap(tester, const Offset(.8, .6));
    expect(selected.points, [const Offset(.8, .6)]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 8));
    expect(selected.gazeClears, 0);
  });

  testWidgets('world custom input keeps its own path', (tester) async {
    final selected = _AttentionRuntime();
    appServices.put(ActiveAvatarRuntime()..register(selected));
    final groundPoints = <Offset>[];
    await mount(tester, onTap: (x, y) => groundPoints.add(Offset(x, y)));
    await tap(tester, const Offset(.2, .8));
    expect(groundPoints, [const Offset(.2, .8)]);
    expect(selected.points, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a renderer without attention does not fall back to the host', (
    tester,
  ) async {
    final host = appServices.put<UnityAvatarRuntime>(_PreparationRuntime());
    appServices.put(ActiveAvatarRuntime()..register(_NoAttentionRuntime()));
    await mount(tester);
    await tap(tester, const Offset(.8, .3));
    expect((host as _PreparationRuntime).points, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _AttentionRuntime extends AvatarRuntime
    implements AvatarScreenAttentionRuntime {
  final points = <Offset>[];
  int gazeWrites = 0;
  int gazeClears = 0;

  @override
  final isReady = true.obs;

  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;

  @override
  Future<void> reactToScreenTap({
    required double normalizedX,
    required double normalizedY,
  }) async => points.add(Offset(normalizedX, normalizedY));

  @override
  Future<void> setGaze(AvatarGaze gaze) async => gazeWrites++;

  @override
  Future<void> clearGaze() async => gazeClears++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoAttentionRuntime extends AvatarRuntime {
  @override
  final isReady = true.obs;

  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreparationRuntime extends UnityAvatarRuntime {
  final points = <Offset>[];

  @override
  Future<void> prepareView() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> reactToScreenTap({
    required double normalizedX,
    required double normalizedY,
  }) async => points.add(Offset(normalizedX, normalizedY));
}
