import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy chat keeps fixed fallback prose in the prompt catalog', () {
    final source = File(
      'lib/src/features/chat/application/u2a_chat_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('final turnLocale = AgentPromptCatalog.currentLocale'),
    );
    expect(source, contains("'app.home.api_key_missing_error'"));
    expect(source, contains("'runtime.fallback.local_empty'"));
    expect(source, contains("'app.home.direct_chat_error'"));
    expect(source, isNot(contains("'chat.execution_error'.trParams")));
    expect(source, isNot(contains("{'error': result.stderr}")));
  });
}
