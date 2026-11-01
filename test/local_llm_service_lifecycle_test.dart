import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local LLM backend registration is route-lifecycle safe', () {
    final source = File(
      'lib/src/core/services/local_llm_service.dart',
    ).readAsStringSync();
    final loadBody = _sourceBetween(
      source,
      '  Future<void> _load({String? modelSource}) async {',
      '  Future<void> warmupFiller() async {',
    );
    final cachedLoadPath = _sourceBetween(
      loadBody,
      '      if (cachedFile != null) {',
      '      isDownloading.value = true;',
    );
    final downloadedLoadPath = _sourceBetween(
      loadBody,
      '      isDownloading.value = true;',
      '    } catch (e, st) {',
    );
    final unloadBody = _sourceBetween(
      source,
      '  Future<void> _unloadBackend() async {',
      '  /// Ensure the local model is up to serve as the cloud fallback',
    );

    _expectPermanentBackendRegistration(cachedLoadPath);
    _expectPermanentBackendRegistration(downloadedLoadPath);
    expect(
      RegExp(
        r'if\s*\(appServices\.isRegistered<LocalLLMBackend>\(\)\)\s*\{\s*'
        r'appServices\.delete<LocalLLMBackend>\(force:\s*true\);\s*\}\s*'
        r'final b = _backend;\s*_backend = null;\s*'
        r'isAvailable\.value = false;[\s\S]*'
        r'if\s*\(b != null\)\s*\{\s*await b\.dispose\(\);\s*\}',
      ).hasMatch(unloadBody),
      isTrue,
    );
  });
}

void _expectPermanentBackendRegistration(String loadPath) {
  expect(
    RegExp(
      r'_backend = backend;\s*'
      r'appServices\.put<LocalLLMBackend>\(\s*backend,\s*'
      r'permanent:\s*true\s*\);\s*'
      r'isAvailable\.value = true;',
    ).allMatches(loadPath),
    hasLength(1),
  );
}

String _sourceBetween(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start);
  expect(start, isNonNegative);
  expect(end, isNonNegative);
  return source.substring(start, end);
}
