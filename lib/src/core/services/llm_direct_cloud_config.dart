import 'dart:convert';

import 'package:maaso/src/core/services/secure_storage_service.dart';

/// One secure-storage value used by every direct-cloud reader.
///
/// Publishing the provider, model, enabled bit, and credential as one value
/// prevents a request from observing fields from two different saves.
final class LLMDirectCloudConfig {
  const LLMDirectCloudConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.enabled,
  });

  static const int schemaVersion = 1;
  static const String storageKey = 'llm_direct_cloud_config_v1';

  final String apiKey;
  final String baseUrl;
  final String model;
  final bool enabled;

  String encode() => jsonEncode(<String, Object>{
    'version': schemaVersion,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
    'enabled': enabled,
  });

  static LLMDirectCloudConfig? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['version'] != schemaVersion ||
          value['apiKey'] is! String ||
          value['baseUrl'] is! String ||
          value['model'] is! String ||
          value['enabled'] is! bool) {
        return null;
      }
      return LLMDirectCloudConfig(
        apiKey: value['apiKey'] as String,
        baseUrl: value['baseUrl'] as String,
        model: value['model'] as String,
        enabled: value['enabled'] as bool,
      );
    } on FormatException {
      return null;
    }
  }

  static Future<LLMDirectCloudConfig?> readFrom(
    SecureStorageService storage,
  ) async {
    return decode(await storage.read(storageKey));
  }
}
