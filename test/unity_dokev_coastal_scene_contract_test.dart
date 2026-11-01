import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('masso_avatar no longer depends on authored world packs', () {
    const root = 'unity/masso_avatar';
    final scene = File(
      '$root/Assets/MaasoAvatar/Scenes/Companion.unity',
    ).readAsStringSync();

    expect(scene, contains('m_Name: Main Camera'));
    expect(
      scene,
      contains('m_BackGroundColor: {r: 1, g: 0.9843137, b: 0.9490196, a: 1}'),
    );
    expect(
      Directory(
        '$root/Assets/MaasoAvatar/Resources/MaasoAvatar/WorldPacks',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Editor/MaasoWorldAssetPackInstaller.cs',
      ).existsSync(),
      isFalse,
    );
    expect(scene, isNot(contains('ForegroundStreet')));
    expect(scene, isNot(contains('MidgroundBuildings')));
    expect(scene, isNot(contains('DokeV Coastal City')));
  });
}
