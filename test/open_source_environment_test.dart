import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

void main() {
  test(
    'public service origins come only from the documented build settings',
    () {
      expect(
        MaasoEnvironment.test.baseUrl,
        const String.fromEnvironment(
          'MAASO_TEST_BASE_URL',
          defaultValue: 'https://test-api.open-maaso.invalid',
        ),
      );
      expect(
        MaasoEnvironment.production.baseUrl,
        const String.fromEnvironment(
          'MAASO_PRODUCTION_BASE_URL',
          defaultValue: 'https://api.open-maaso.invalid',
        ),
      );
    },
  );

  test('unconfigured source builds use non-routable reserved origins', () {
    if (!const bool.hasEnvironment('MAASO_TEST_BASE_URL')) {
      expect(
        Uri.parse(MaasoEnvironment.test.baseUrl).host.endsWith('.invalid'),
        isTrue,
      );
    }
    if (!const bool.hasEnvironment('MAASO_PRODUCTION_BASE_URL')) {
      expect(
        Uri.parse(
          MaasoEnvironment.production.baseUrl,
        ).host.endsWith('.invalid'),
        isTrue,
      );
    }
  });
}
