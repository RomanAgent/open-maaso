import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dashboard body is scroll-first to avoid root flex overflow', () {
    final source = File(
      'lib/src/features/dashboard/presentation/dashboard_page.dart',
    ).readAsStringSync();

    expect(source, contains('SingleChildScrollView('));
    expect(source, contains('AppSecondaryScaffold('));
    expect(source, contains('AppSecondaryHeader('));
    expect(source, contains('AppSecondaryCard('));
    expect(
      source,
      contains('padding: const EdgeInsets.fromLTRB(16, 4, 16, 20)'),
    );
    expect(source, contains('appServices.isRegistered<TtsWarmupService>()'));
    expect(
      source,
      isNot(contains('Expanded(\n              child: SingleChildScrollView')),
    );
    expect(source, isNot(contains('GlassBackdropKind.unityUnderlay')));
  });
}
