import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shared scaffold and material use no sampled liquid pipeline', () {
    final scaffold = File(
      'lib/src/core/widgets/ui/glass/app_glass_scaffold.dart',
    ).readAsStringSync();
    final theme = File(
      'lib/src/core/widgets/ui/glass/maaso_glass_theme.dart',
    ).readAsStringSync();
    expect(scaffold, contains('child: Scaffold('));
    expect(scaffold, contains('GlassBackdropKind.platformView'));
    for (final source in [scaffold, theme]) {
      expect(source, isNot(contains('package:liquid_glass_widgets')));
      expect(source, isNot(contains('enableBackgroundSampling:')));
      expect(source, isNot(contains('GlassQuality.')));
      expect(source, isNot(contains('GlassThemeData')));
      expect(source, isNot(contains('BackdropFilter(')));
    }
  });
}
