import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

const _assetPath = 'assets/sherpa_models/silero-vad-v5/silero_vad.onnx';

void main() {
  test('Silero VAD registry prefers the bundled model asset', () {
    expect(SherpaModelRegistry.sileroVad.bundledAssets, const <String, String>{
      _assetPath: 'silero_vad.onnx',
    });
    expect(SherpaModelRegistry.sileroVad.releaseUrl, isNotEmpty);
  });

  test('bundled Silero VAD bytes match the verified device model', () {
    final model = File(_assetPath);
    expect(model.existsSync(), isTrue);
    final bytes = model.readAsBytesSync();
    expect(bytes.length, 643854);
    expect(
      sha256.convert(bytes).toString(),
      '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    );
  });

  test('Flutter bundle declares the Silero VAD asset', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- $_assetPath'));
  });

  test('advanced settings no longer exposes a VAD download card', () {
    final settings = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    expect(settings, isNot(contains('const _VadSection()')));
    expect(settings, isNot(contains('class _VadSection')));
  });
}
