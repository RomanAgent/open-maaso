import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';

void main() {
  testWidgets('unsupported desktop host renders a safe explicit limitation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final runtime = SurfaceRuntime()..initializeLifecycle();
    addTearDown(runtime.closeLifecycle);
    await runtime.show(_surfaceProject());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SurfaceWebView(runtime: runtime)),
      ),
    );
    await tester.pump();

    expect(find.byKey(SurfaceWebView.hostUnavailableKey), findsOneWidget);
    expect(find.text('Interactive Applets are unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

SurfaceProject _surfaceProject() {
  return SurfaceProject(
    id: 'surface_windows_guard',
    title: 'Desktop guard',
    kind: SurfaceKind.card,
    rendering: SurfaceRendering.dom,
    html: '<main>Safe content</main>',
    css: '',
    js: '',
    transparent: false,
    experienceType: SurfaceExperienceType.utility,
    placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
    manifest: const SurfaceManifest(),
    backend: const <String, Object?>{},
    revisions: const [],
  );
}
