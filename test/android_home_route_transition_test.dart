import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';

void main() {
  for (final platform in TargetPlatform.values) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$platform $brightness pages stay opaque while pushed/popped',
        (tester) async {
          final navigator = GlobalKey<NavigatorState>();
          final capture = GlobalKey();
          const pageKey = ValueKey<String>('moving-secondary-page');
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                navigatorKey: navigator,
                theme: AppTheme.build(
                  AppPalette.of(brightness, AppAccent.blue),
                ).copyWith(platform: platform),
                home: const ColoredBox(color: Colors.green),
              ),
            ),
          );
          final page = MaterialPageRoute<void>(
            builder: (_) => const ColoredBox(key: pageKey, color: Colors.blue),
          );
          navigator.currentState!.push(page);
          await tester.pump();
          for (final milliseconds in <int>[45, 70, 90]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            await _expectVisiblePageOpaque(tester, capture, pageKey);
          }
          await tester.pumpAndSettle();
          navigator.currentState!.pop();
          await tester.pump();
          for (final milliseconds in <int>[45, 70, 90]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            await _expectVisiblePageOpaque(tester, capture, pageKey);
          }
          await tester.pumpAndSettle();
          expect(find.byKey(pageKey), findsNothing);
          expect(
            (await _pixelAt(
              tester,
              capture,
              const Offset(400, 300),
            )).toARGB32(),
            Colors.green.toARGB32(),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('$platform slide retains cancellable back navigation', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      const pageKey = ValueKey<String>('gesture-secondary-page');
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: AppTheme.build(
            AppPalette.of(Brightness.light, AppAccent.blue),
          ).copyWith(platform: platform),
          home: const ColoredBox(color: Colors.green),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const ColoredBox(key: pageKey, color: Colors.blue),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(1, 300));
      await gesture.moveBy(const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(find.byKey(pageKey)).dx, greaterThan(0));
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(pageKey), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(pageKey)).dx, 0);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(pageKey), findsNothing);
    });
  }
}

Future<void> _expectVisiblePageOpaque(
  WidgetTester tester,
  GlobalKey capture,
  Key pageKey,
) async {
  final rect = tester.getRect(find.byKey(pageKey));
  final viewport = tester.getSize(find.byKey(capture));
  final visible = rect.intersect(Offset.zero & viewport);
  expect(
    visible.width,
    greaterThan(0),
    reason: 'The page must still be onscreen.',
  );
  expect(
    (await _pixelAt(tester, capture, visible.center)).toARGB32(),
    Colors.blue.toARGB32(),
    reason: 'A secondary page must not fade into Home or a fallback scrim.',
  );
}

Future<Color> _pixelAt(
  WidgetTester tester,
  GlobalKey capture,
  Offset point,
) async {
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return Color.fromARGB(
        pixels.getUint8(offset + 3),
        pixels.getUint8(offset),
        pixels.getUint8(offset + 1),
        pixels.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}
