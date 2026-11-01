import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app startup no longer initializes a retired liquid renderer', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    expect(pubspec, isNot(contains('liquid_glass_widgets:')));
    expect(pubspec, isNot(contains('liquid_glass_easy:')));
    expect(main, isNot(contains('package:liquid_glass_widgets')));
    expect(main, isNot(contains('LiquidGlassWidgets.initialize')));
    expect(main, isNot(contains('LiquidGlassWidgets.wrap')));
    expect(main, contains('MaasoApp()'));
  });
}
