import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'unity/masso_avatar';

  test('masso avatar project is the active Unity project', () {
    expect(Directory(root).existsSync(), isTrue);
    expect(
      File('$root/Assets/MaasoAvatar/Scenes/Companion.unity').existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Models/Default/'
        'Joy.vrm',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Scripts/FrontFullBodyCamera.cs',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '$root/Assets/Tests/EditMode/FrontFullBodyCameraTests.cs',
      ).existsSync(),
      isTrue,
    );

    expect(
      File(
        'unity/maaso_avatar/Assets/MaasoAvatar/Scenes/MaasoWorld.unity',
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

  test('companion scene uses milk-white full-body front camera', () {
    final framingScriptMeta = File(
      '$root/Assets/MaasoAvatar/Scripts/FrontFullBodyCamera.cs.meta',
    ).readAsStringSync();
    final receiverScriptMeta = File(
      '$root/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs.meta',
    ).readAsStringSync();
    final scene = File(
      '$root/Assets/MaasoAvatar/Scenes/Companion.unity',
    ).readAsStringSync();

    final framingGuid = RegExp(
      r'guid: ([a-f0-9]+)',
    ).firstMatch(framingScriptMeta)![1]!;
    final receiverGuid = RegExp(
      r'guid: ([a-f0-9]+)',
    ).firstMatch(receiverScriptMeta)![1]!;

    expect(scene, contains('m_Name: Main Camera'));
    expect(scene, contains('m_TagString: MainCamera'));
    expect(scene, contains('m_ClearFlags: 2'));
    expect(
      scene,
      contains('m_BackGroundColor: {r: 1, g: 0.9843137, b: 0.9490196, a: 1}'),
    );
    expect(scene, contains('guid: $framingGuid'));
    expect(scene, contains('guid: $receiverGuid'));
    expect(scene, contains('autoFindTarget: 1'));
    expect(scene, contains('framingPadding: 1'));
    expect(scene, contains('topSafeViewport: 0.15'));
    expect(scene, contains('bottomSafeViewport: 0.2'));
    expect(scene, contains('m_LocalRotation: {x: 0, y: 1, z: 0, w: 0}'));
  });

  test('companion scene binds theme lighting to the avatar camera and sun', () {
    final controllerMeta = File(
      '$root/Assets/MaasoAvatar/Scripts/UnityWorldLightingController.cs.meta',
    ).readAsStringSync();
    final controllerGuid = RegExp(
      r'guid: ([a-f0-9]+)',
    ).firstMatch(controllerMeta)![1]!;
    final scene = File(
      '$root/Assets/MaasoAvatar/Scenes/Companion.unity',
    ).readAsStringSync();

    expect(
      scene,
      contains('m_Script: {fileID: 11500000, guid: $controllerGuid, type: 3}'),
    );
    expect(
      scene,
      matches(RegExp(r'backgroundCamera: \{fileID: [1-9][0-9]*\}')),
    );
    expect(
      scene,
      matches(RegExp(r'directionalLight: \{fileID: [1-9][0-9]*\}')),
    );
    expect(scene, contains('transitionSeconds: 0.45'));
    expect(scene, matches(RegExp(r'worldLighting: \{fileID: [1-9][0-9]*\}')));
  });

  test('companion scene is the first enabled Unity build scene', () {
    final settings = File(
      '$root/ProjectSettings/EditorBuildSettings.asset',
    ).readAsStringSync();

    expect(
      settings,
      contains('path: Assets/MaasoAvatar/Scenes/Companion.unity'),
    );
    expect(
      settings.indexOf('path: Assets/MaasoAvatar/Scenes/Companion.unity'),
      lessThan(settings.indexOf('m_configObjects:')),
    );
  });

  test('masso avatar project has an iOS Unity Library export entrypoint', () {
    final exporter = File(
      '$root/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(exporter, contains('MaasoUnityLibraryExporter'));
    expect(exporter, contains('public static void ExportIOS()'));
    expect(exporter, contains('BuildTarget.iOS'));
    expect(exporter, contains('Builds/iOS'));
    expect(exporter, contains('MaasoDefaultAvatarSceneBuilder.ScenePath'));
    expect(exporter, contains('EditorSceneManager.OpenScene(AgentScenePath'));
    expect(exporter, contains('OpenSceneMode.Single'));
    expect(exporter, isNot(contains('MaasoWorld')));
    expect(exporter, isNot(contains('Assets/JunVRC')));
  });

  test('VRM1 exports do not carry the retired JunVRC lilToon fallback', () {
    final exporter = File(
      '$root/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(exporter, isNot(contains('ApplyMobileMaterialFallbacks(')));
    expect(exporter, isNot(contains('RestoreMobileMaterialFallbacks(')));
    expect(exporter, isNot(contains('UsesUnsupportedLilToonShader')));
    expect(exporter, isNot(contains('Assets/JunVRC')));
    expect(exporter, isNot(contains('lilToon')));
  });

  test('iOS export restores Unity project settings touched by build hooks', () {
    final exporter = File(
      '$root/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(exporter, contains('BackupUnityProjectSettingFiles()'));
    expect(exporter, contains('RestoreUnityProjectSettingFiles('));
    expect(exporter, contains('ProjectSettings/ProjectSettings.asset'));
    expect(exporter, isNot(contains('ProjectSettings/lilToonSetting.json')));
    expect(exporter, contains('File.ReadAllBytes(settingPath)'));
    expect(exporter, contains('File.WriteAllBytes(backup.Path'));
  });

  test('Unity export refreshes FBX actions and cleans missing scripts', () {
    final exporter = File(
      '$root/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(exporter, contains('TryResolveDefaultSourceFolder('));
    expect(exporter, contains('ImportActionFbxFolder(sourceFolder)'));
    expect(exporter, contains('ExternalActionFolderEnv'));
    expect(exporter, contains('CleanupAgentSceneMissingScripts()'));
    expect(
      exporter,
      contains('GameObjectUtility.RemoveMonoBehavioursWithMissingScript'),
    );
    expect(exporter, contains('EditorSceneManager.SaveScene(scene)'));
  });

  test('Unity iOS refresh script exports, relinks, and verifies Flutter', () {
    final script = File('tool/unity/update_ios_unity_library.sh');

    expect(script.existsSync(), isTrue);

    final contents = script.readAsStringSync();
    expect(
      contents,
      contains('Maaso.Avatar.Editor.MaasoUnityLibraryExporter.ExportIOS'),
    );
    expect(contents, contains('ruby tool/unity/link_ios_unity_library.rb'));
    expect(contents, contains('Builds/iOS'));
    expect(contents, contains('Unity-iPhone.xcodeproj'));
    expect(contents, contains('Data/Managed/Metadata/global-metadata.dat'));
    expect(contents, contains('build ios --debug --no-codesign'));
    expect(contents, contains('run --debug'));

    final syntaxCheck = Process.runSync('bash', ['-n', script.path]);
    expect(
      syntaxCheck.exitCode,
      0,
      reason: '${syntaxCheck.stdout}\n${syntaxCheck.stderr}',
    );
  });

  test('Unity Android refresh script exports and verifies Flutter APK', () {
    final script = File('tool/unity/update_android_unity_library.sh');

    expect(script.existsSync(), isTrue);

    final contents = script.readAsStringSync();
    expect(
      contents,
      contains('Maaso.Avatar.Editor.MaasoUnityLibraryExporter.ExportAndroid'),
    );
    expect(
      contents,
      contains(r'UNITY_ANDROID_EXPORT="$UNITY_PROJECT/Builds/Android"'),
    );
    expect(
      contents,
      contains(r'UNITY_ANDROID_LIBRARY="$UNITY_ANDROID_EXPORT/unityLibrary"'),
    );
    expect(contents, contains('build apk --debug'));
    expect(contents, contains('run --debug'));

    final syntaxCheck = Process.runSync('bash', ['-n', script.path]);
    expect(
      syntaxCheck.exitCode,
      0,
      reason: '${syntaxCheck.stdout}\n${syntaxCheck.stderr}',
    );
  });
}
