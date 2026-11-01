import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('masso_avatar uses the VRM1 companion scene instead of world packs', () {
    const root = 'unity/masso_avatar';

    expect(
      File('$root/Assets/MaasoAvatar/Scenes/Companion.unity').existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Scripts/WorldAssetPackRegistry.cs',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Scripts/WorldSceneController.cs',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Editor/MaasoWorldAssetPackInstaller.cs',
      ).existsSync(),
      isFalse,
    );
    expect(
      Directory(
        '$root/Assets/MaasoAvatar/Resources/MaasoAvatar/WorldPacks',
      ).existsSync(),
      isFalse,
    );
  });
}
