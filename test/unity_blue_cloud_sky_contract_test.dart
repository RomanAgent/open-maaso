import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const unityRoot = 'unity/masso_avatar';

  test(
    'bundled daytime sky is a texture-free blue gradient without clouds',
    () {
      final installer = File(
        '$unityRoot/Assets/MaasoWorld/Editor/WorldDaySkyInstaller.cs',
      ).readAsStringSync();
      final material = File(
        '$unityRoot/Assets/MaasoWorld/Resources/Maaso_DaySky.mat',
      ).readAsStringSync();
      final shader = File(
        '$unityRoot/Assets/MaasoWorld/Shaders/MaasoMobileDaySky.shader',
      ).readAsStringSync();

      for (final source in [installer, material, shader]) {
        expect(source, isNot(contains('_Cloud')));
        expect(source, isNot(contains('CloudBlob')));
        expect(source, isNot(contains('CloudShape')));
      }
      expect(installer, contains('Shader.Find(ShaderName)'));
      expect(material, isNot(contains('- _Tex:')));
      expect(material, isNot(contains('- _MainTex:')));
      expect(shader, contains('_ZenithColor'));
      expect(shader, contains('_HorizonColor'));
    },
  );
}
