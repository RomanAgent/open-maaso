import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';

void main() {
  test('every provider gets the max_tokens ceiling', () {
    final openai = cloudExtraBodyFor(
      'https://api.openai.com/v1',
      'gpt-4o-mini',
    );
    expect(openai['max_tokens'], kCloudMaxOutputTokens);
    expect(openai.containsKey('thinking'), isFalse);
  });

  test('Volcano Ark keeps thinking-disabled AND gets the ceiling', () {
    final ark = cloudExtraBodyFor(
      'https://ark.cn-beijing.volces.com/api/v3',
      'doubao-seed-1-8',
    );
    expect(ark['max_tokens'], kCloudMaxOutputTokens);
    expect(ark['thinking'], {'type': 'disabled'});
  });

  test('live cloud client uses a >=90s first-response timeout', () {
    final src = File(
      'lib/src/core/services/llm_proxy_service.dart',
    ).readAsStringSync();
    // LiveLLMClient.defaultTimeout — headroom for long card generations.
    expect(src, contains('Duration(seconds: 90)'));
  });
}
