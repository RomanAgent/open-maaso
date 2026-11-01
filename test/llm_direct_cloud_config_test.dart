import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  test('direct-cloud config round-trips as one secure value', () async {
    final storage = _MemorySecureStorage();
    const config = LLMDirectCloudConfig(
      apiKey: 'secret-a',
      baseUrl: 'https://a.example.test/v1',
      model: 'model-a',
      enabled: true,
    );

    expect(
      await storage.write(LLMDirectCloudConfig.storageKey, config.encode()),
      isTrue,
    );

    final restored = await LLMDirectCloudConfig.readFrom(storage);
    expect(restored?.apiKey, 'secret-a');
    expect(restored?.baseUrl, 'https://a.example.test/v1');
    expect(restored?.model, 'model-a');
    expect(restored?.enabled, isTrue);
  });

  test('malformed or unsupported envelopes fail closed', () {
    expect(LLMDirectCloudConfig.decode('{not-json'), isNull);
    expect(
      LLMDirectCloudConfig.decode(
        '{"version":2,"apiKey":"secret","baseUrl":"https://a",'
        '"model":"m","enabled":true}',
      ),
      isNull,
    );
    expect(
      LLMDirectCloudConfig.decode(
        '{"version":1,"apiKey":"secret","baseUrl":"https://a",'
        '"model":"m","enabled":"true"}',
      ),
      isNull,
    );
  });
}

final class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }
}
