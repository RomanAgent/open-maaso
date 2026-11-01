import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

void main() {
  test(
    'interpolation does not expand placeholders inside parameter values',
    () {
      expect(
        AgentPromptCatalog.text(
          'runtime.policy.wrapper',
          locale: AppLocale.en,
          params: const {'parts': '@error', 'error': 'must-not-expand'},
        ),
        '[policy: @error]',
      );
    },
  );

  test('interpolation does not expand placeholder prefixes in values', () {
    final rendered = AgentPromptCatalog.text(
      'runtime.policy.wrapper',
      locale: AppLocale.en,
      params: const {'parts': '@parts_extra', 'parts_extra': 'must-not-expand'},
    );

    expect(rendered, '[policy: @parts_extra]');
  });
}
