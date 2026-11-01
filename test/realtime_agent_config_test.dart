import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';

void main() {
  test('fromValues disables realtime agent when flag is off', () {
    final config = RealtimeAgentConfig.fromValues(
      enabled: false,
      baseUrl: 'https://api.example.test',
    );

    expect(config.isReady, isFalse);
    expect(config.baseUri, isNull);
  });

  test('fromValues accepts and canonicalizes a root HTTPS origin', () {
    final https = RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: ' HTTPS://API.Example.Test:8443/ ',
    );

    expect(https.isReady, isTrue);
    expect(https.baseUri.toString(), 'https://api.example.test:8443/');
  });

  test('fromValues rejects non-HTTPS and ambiguous origins', () {
    const unsafe = <String>[
      'not-a-url',
      'http://127.0.0.1:18090',
      'https://user:secret@api.example.test',
      'https://api.example.test/v1',
      'https://api.example.test?next=https://evil.example',
      'https://api.example.test#fragment',
      '//api.example.test',
    ];

    for (final value in unsafe) {
      final config = RealtimeAgentConfig.fromValues(
        enabled: true,
        baseUrl: value,
      );

      expect(config.isReady, isFalse, reason: value);
      expect(config.baseUri, isNull, reason: value);
      expect(
        config.disabledReason,
        contains('root HTTPS origin'),
        reason: value,
      );
      expect(
        config.disabledReason,
        isNot(contains('user:secret')),
        reason: value,
      );
    }
  });

  test('environment fallback is accepted only when it is HTTPS', () {
    final secure = RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: '',
      environmentBaseUrl: 'https://api.example.test',
    );
    final insecure = RealtimeAgentConfig.fromValues(
      enabled: true,
      baseUrl: '',
      environmentBaseUrl: 'http://api.example.test',
    );

    expect(secure.isReady, isTrue);
    expect(secure.baseUri.toString(), 'https://api.example.test/');
    expect(insecure.isReady, isFalse);
    expect(insecure.baseUri, isNull);
  });
}
