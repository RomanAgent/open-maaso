import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

/// Exercises the real hub, using small panes so pixel sampling does not depend
/// on network-backed controllers or platform views. The exposed top strip
/// checks the hub background; the colored body detects fades of the pane.
Future<void> verifyOpaqueHubNavigation(
  WidgetTester tester, {
  required Widget Function(Widget Function(String) pane) buildHub,
  required List<String> paneNames,
  required List<String> destinationKeys,
  required Brightness brightness,
  required bool reduceMotion,
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final boundaryKey = GlobalKey();
  const paneColors = <Color>[
    Color(0xFF1B5E20),
    Color(0xFF0D47A1),
    Color(0xFF7B1FA2),
  ];
  final taps = <String>[];
  Widget pane(String name) => Stack(
    key: ValueKey<String>('probe-pane-$name'),
    fit: StackFit.expand,
    children: <Widget>[
      Positioned.fill(
        child: ColoredBox(color: paneColors[paneNames.indexOf(name)]),
      ),
      Center(
        child: TextButton(
          key: ValueKey<String>('probe-action-$name'),
          onPressed: () => taps.add(name),
          child: Text(name),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: const TextScaler.linear(2),
          disableAnimations: reduceMotion,
        ),
        child: RepaintBoundary(
          key: boundaryKey,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // Represents the native Unity/previous route under the hub.
              const ColoredBox(color: Color(0xFFFF00FF)),
              buildHub(pane),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> checkFrame(int index, String phase) async {
    for (final name in paneNames) {
      expect(
        find.byKey(ValueKey<String>('probe-pane-$name')),
        name == paneNames[index] ? findsOneWidget : findsNothing,
        reason: '$phase: only the active pane may remain mounted',
      );
    }
    final paneRect = tester.getRect(
      find.byKey(ValueKey<String>('probe-pane-${paneNames[index]}')),
    );
    final actual = await tester.runAsync(() async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        List<int> pixel(int x, int y) {
          final offset = (y * image.width + x) * 4;
          return <int>[
            for (var channel = 0; channel < 4; channel += 1)
              pixels.getUint8(offset + channel),
          ];
        }

        return <List<int>>[
          pixel(8, 8),
          pixel(8, (paneRect.top + paneRect.height / 2).round()),
        ];
      } finally {
        image.dispose();
      }
    });
    expect(actual, <List<int>>[
      _rgba(AppSecondaryPalette.resolve(brightness).backgroundStart),
      _rgba(paneColors[index]),
    ], reason: '$phase: background and active pane must paint at full opacity');
    expect(tester.takeException(), isNull);
  }

  await checkFrame(0, 'initial');
  final lastIndex = paneNames.length - 1;
  for (final index in <int>[1, lastIndex, 0]) {
    final destination = find.byKey(ValueKey<String>(destinationKeys[index]));
    await tester.ensureVisible(destination);
    await tester.tap(destination);
    await tester.pump();
    await checkFrame(index, '${paneNames[index]} at 0 ms');
    for (final delta in <int>[45, 45, 89]) {
      await tester.pump(Duration(milliseconds: delta));
      await checkFrame(index, '${paneNames[index]} after $delta ms');
    }
  }
  // Do not settle the segment's selection animation between rapid taps.
  for (final index in <int>[1, 0, lastIndex, 1]) {
    final destination = find.byKey(ValueKey<String>(destinationKeys[index]));
    await tester.ensureVisible(destination);
    await tester.tap(destination);
    await tester.pump(const Duration(milliseconds: 20));
    await checkFrame(index, 'rapid ${paneNames[index]}');
  }
  await tester.tap(
    find.byKey(ValueKey<String>('probe-action-${paneNames[1]}')),
  );
  expect(taps, <String>[paneNames[1]]);
  expect(tester.takeException(), isNull);
}

List<int> _rgba(Color color) {
  final argb = color.toARGB32();
  return <int>[(argb >> 16) & 255, (argb >> 8) & 255, argb & 255, argb >> 24];
}
