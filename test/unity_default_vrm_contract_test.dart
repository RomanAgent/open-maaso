import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectRoot = 'unity/masso_avatar';
const _defaultModelDirectory =
    '$_projectRoot/Assets/MaasoAvatar/Models/Default';
const _defaultModelPath = '$_defaultModelDirectory/Joy.vrm';
const _defaultScenePath =
    '$_projectRoot/Assets/MaasoAvatar/Scenes/Companion.unity';

void main() {
  test(
    'masso_avatar bundles only Joy Sportswear 1.5 in its default outfit',
    () {
      final modelFile = File(_defaultModelPath);
      expect(modelFile.existsSync(), isTrue);
      final exportManifest =
          jsonDecode(
                File(
                  'docs/avatar/joy_sportswear_15/joy15-export-manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(exportManifest['vrm_sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        sha256.convert(modelFile.readAsBytesSync()).toString(),
        exportManifest['vrm_sha256'],
      );

      final modelFiles =
          Directory(_defaultModelDirectory)
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.vrm'))
              .map((file) => file.path)
              .toList()
            ..sort();
      expect(modelFiles, [_defaultModelPath]);

      final gltf = _readGlbJson(modelFile);
      expect((gltf['asset'] as Map<String, dynamic>)['version'], '2.0');

      final extensionsUsed = (gltf['extensionsUsed'] as List<dynamic>)
          .cast<String>();
      expect(extensionsUsed, contains('VRMC_vrm'));

      final extensions = gltf['extensions'] as Map<String, dynamic>;
      final vrm = extensions['VRMC_vrm'] as Map<String, dynamic>;
      expect(vrm['specVersion'], '1.0');
      expect(
        (vrm['meta'] as Map<String, dynamic>)['name'],
        'Joy Sportswear 1.5',
      );
      expect(exportManifest['vrm_meta_name'], 'Joy Sportswear 1.5');
      expect(exportManifest['wardrobe'], '02_racerback_crop_high_waist');

      final meshes = gltf['meshes'] as List<dynamic>;
      expect(
        meshes.map((mesh) => (mesh as Map<String, dynamic>)['name']),
        unorderedEquals(<String>[
          'Joy_body',
          'Joy_eye',
          'Joy_hair_02',
          'Joy_racerback_crop_sport_low',
          'Joy_high_waist_leggings_low',
          'Joy_adidas_pink_shoes_low',
        ]),
        reason: 'Only the selected set02 outfit should ship with the default',
      );

      final humanoid = vrm['humanoid'] as Map<String, dynamic>;
      final humanBones = (humanoid['humanBones'] as Map<String, dynamic>).keys
          .toSet();
      expect(
        humanBones,
        containsAll(<String>{
          'hips',
          'spine',
          'head',
          'leftEye',
          'rightEye',
          'leftHand',
          'rightHand',
          'leftUpperArm',
          'leftLowerArm',
          'rightUpperArm',
          'rightLowerArm',
          'leftFoot',
          'rightFoot',
        }),
      );

      final lookAt = vrm['lookAt'] as Map<String, dynamic>;
      expect(lookAt['type'], 'bone');

      final expressions = vrm['expressions'] as Map<String, dynamic>;
      final presets = (expressions['preset'] as Map<String, dynamic>).keys
          .toSet();
      expect(
        presets,
        containsAll(<String>{
          'blink',
          'blinkLeft',
          'blinkRight',
          'happy',
          'sad',
          'angry',
          'surprised',
          'relaxed',
          'aa',
          'ih',
          'ou',
          'ee',
          'oh',
        }),
      );

      // The actual preset bindings must survive export, not merely their names.
      final nodes = gltf['nodes'] as List<dynamic>;
      final presetDefinitions = expressions['preset'] as Map<String, dynamic>;
      for (final name in <String>[
        'blink',
        'blinkLeft',
        'blinkRight',
        'happy',
        'sad',
        'angry',
        'surprised',
        'relaxed',
        'aa',
        'ih',
        'ou',
        'ee',
        'oh',
      ]) {
        final preset = presetDefinitions[name] as Map<String, dynamic>;
        final bindings = preset['morphTargetBinds'] as List<dynamic>?;
        expect(
          bindings,
          isNotEmpty,
          reason: '$name needs a working mesh binding',
        );
        for (final rawBinding in bindings!) {
          final binding = rawBinding as Map<String, dynamic>;
          final nodeIndex = binding['node'] as int;
          expect(nodeIndex, inInclusiveRange(0, nodes.length - 1));
          final node = nodes[nodeIndex] as Map<String, dynamic>;
          final mesh = meshes[node['mesh'] as int] as Map<String, dynamic>;
          final primitives = mesh['primitives'] as List<dynamic>;
          final targetIndex = binding['index'] as int;
          expect(
            binding['weight'],
            greaterThan(0),
            reason: '$name has zero weight',
          );
          expect(
            primitives.any(
              (primitive) =>
                  ((primitive as Map<String, dynamic>)['targets']
                          as List<dynamic>?)
                      ?.asMap()
                      .containsKey(targetIndex) ??
                  false,
            ),
            isTrue,
            reason: '$name references a missing morph target',
          );
        }
      }
    },
  );

  test('companion scene instantiates the checked-in default VRM asset', () {
    final modelMeta = File('$_defaultModelPath.meta');
    final scene = File(_defaultScenePath);

    expect(modelMeta.existsSync(), isTrue);
    expect(scene.existsSync(), isTrue);

    final modelGuid = RegExp(
      r'^guid: ([a-f0-9]+)$',
      multiLine: true,
    ).firstMatch(modelMeta.readAsStringSync())?[1];
    expect(modelGuid, isNotNull);

    final sceneContents = scene.readAsStringSync();
    expect(sceneContents, contains('guid: $modelGuid'));
    expect(sceneContents, contains('m_Name: Main Camera'));
  });

  test('retired avatar assets and generated artifacts stay removed', () {
    expect(Directory('$_projectRoot/Assets/JunVRC').existsSync(), isFalse);
    expect(
      Directory('$_projectRoot/Assets/ExpressionEditor').existsSync(),
      isFalse,
    );
    expect(
      File(
        '$_projectRoot/Assets/MaasoAvatar/Scripts/BundledAvatarCatalog.cs',
      ).existsSync(),
      isFalse,
    );
    expect(Directory('$_projectRoot/Assets/Rukha93').existsSync(), isFalse);
    expect(
      Directory(
        '$_projectRoot/Assets/MaasoAvatar/AvatarBundleSources',
      ).existsSync(),
      isFalse,
    );
    expect(
      Directory(
        '$_projectRoot/Assets/MaasoAvatar/Characters/ModularAnime',
      ).existsSync(),
      isFalse,
    );
    expect(
      Directory('$_projectRoot/Builds/AvatarBundles').existsSync(),
      isFalse,
    );
    expect(Directory('artifacts/avatar_white_base').existsSync(), isFalse);
    expect(
      File('assets/model_store/modular_anime_female.png').existsSync(),
      isFalse,
    );
    expect(
      File('assets/model_store/modular_anime_male.png').existsSync(),
      isFalse,
    );

    final packageManifest = File(
      '$_projectRoot/Packages/manifest.json',
    ).readAsStringSync();
    final packageLock = File(
      '$_projectRoot/Packages/packages-lock.json',
    ).readAsStringSync();
    expect(packageManifest, isNot(contains('jp.lilxyzw.liltoon')));
    expect(packageLock, isNot(contains('jp.lilxyzw.liltoon')));
    expect(
      File('$_projectRoot/ProjectSettings/lilToonSetting.json').existsSync(),
      isFalse,
    );
  });
}

Map<String, dynamic> _readGlbJson(File file) {
  final bytes = file.readAsBytesSync();
  expect(bytes.length, greaterThanOrEqualTo(20));

  final header = ByteData.sublistView(bytes);
  expect(header.getUint32(0, Endian.little), 0x46546c67);
  expect(header.getUint32(4, Endian.little), 2);
  expect(header.getUint32(8, Endian.little), bytes.length);

  final jsonLength = header.getUint32(12, Endian.little);
  expect(header.getUint32(16, Endian.little), 0x4e4f534a);
  expect(20 + jsonLength, lessThanOrEqualTo(bytes.length));

  final jsonBytes = bytes.sublist(20, 20 + jsonLength);
  return jsonDecode(utf8.decode(jsonBytes).trimRight()) as Map<String, dynamic>;
}
