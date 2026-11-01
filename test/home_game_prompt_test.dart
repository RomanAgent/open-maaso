import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home HUD menu does not expose the old Create Game prompt action', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('void _prepareGamePrompt()')));
    expect(source, isNot(contains('onCreateGame')));
    expect(source, isNot(contains("label: 'Create Game'")));
    expect(source, isNot(contains('Prompt is ready in the chat bar.')));
  });
}
