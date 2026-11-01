import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production wires the worker health gate and root validation host', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final appSource = File('lib/src/app/app.dart').readAsStringSync();

    expect(
      mainSource,
      contains('final surfaceWorkerHealthGate = appServices.put('),
    );
    expect(mainSource, contains('SurfaceWorkerHealthGate()'));
    expect(
      mainSource,
      contains('appServices.put<SurfaceWorkerFirstFrameWaiter>('),
    );
    expect(mainSource, contains('surfaceWorkerHealthGate,'));
    expect(appSource, contains('const SurfaceWorkerValidationHost()'));
    expect(appSource, contains('return Stack('));
  });

  test('scoped surface runtimes do not share the global session gate', () {
    final source = File(
      'lib/src/core/widgets/surface_web_view.dart',
    ).readAsStringSync();

    expect(source, contains('_workerHealthGate = widget.runtime == null'));
    expect(
      source,
      contains('? appServices.maybeFind<SurfaceWorkerHealthGate>()'),
    );
    expect(source, contains(': null;'));
  });
}
