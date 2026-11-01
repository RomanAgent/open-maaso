import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Runner scheme warms the asset catalog agent before building', () {
    final scheme = File(
      'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    ).readAsStringSync();

    expect(
      File('ios/scripts/warm_asset_catalog_agent.sh').existsSync(),
      isTrue,
    );
    expect(scheme, contains('<PreActions>'));
    expect(scheme, contains('scripts/warm_asset_catalog_agent.sh'));
  });

  test('iOS build preflight warms large pod XCFrameworks sequentially', () {
    final assetCatalogWarmup = File(
      'ios/scripts/warm_asset_catalog_agent.sh',
    ).readAsStringSync();

    expect(File('ios/scripts/warm_pod_xcframeworks.sh').existsSync(), isTrue);
    expect(assetCatalogWarmup, contains('warm_pod_xcframeworks.sh'));

    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'maaso-xcframework-preflight-test-',
    );
    addTearDown(() => temporaryDirectory.deleteSync(recursive: true));

    final podsRoot = Directory('${temporaryDirectory.path}/Pods')
      ..createSync(recursive: true);
    final log = File('${temporaryDirectory.path}/xcframework-order.log');
    for (final target in <String>[
      'sherpa_onnx_ios',
      'VolcApiEngine',
      'VolcEngineRTC',
    ]) {
      final supportDirectory = Directory(
        '${podsRoot.path}/Target Support Files/$target',
      )..createSync(recursive: true);
      File(
        '${supportDirectory.path}/$target-xcframeworks.sh',
      ).writeAsStringSync('''#!/bin/sh
printf '%s\\n' '$target' >> "\$MAASO_TEST_XCFRAMEWORK_LOG"
''');
    }

    final result = Process.runSync(
      '/bin/sh',
      ['ios/scripts/warm_pod_xcframeworks.sh'],
      environment: {
        ...Platform.environment,
        'PODS_ROOT': podsRoot.path,
        'PODS_XCFRAMEWORKS_BUILD_DIR':
            '${temporaryDirectory.path}/XCFrameworkIntermediates',
        'ARCHS': 'arm64',
        'PLATFORM_NAME': 'iphoneos',
        'EFFECTIVE_PLATFORM_NAME': '-iphoneos',
        'MAASO_TEST_XCFRAMEWORK_LOG': log.path,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(log.readAsLinesSync(), <String>[
      'sherpa_onnx_ios',
      'VolcApiEngine',
      'VolcEngineRTC',
    ]);
  });

  test('Flutter iOS builds sign embedded pod frameworks sequentially', () {
    final podfile = File('ios/Podfile').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(podfile, contains('COCOAPODS_PARALLEL_CODE_SIGN=false'));
    expect(project, contains('COCOAPODS_PARALLEL_CODE_SIGN=false'));
  });

  test('Runner executes CocoaPods scripts from launcher-private storage', () {
    final podfile = File('ios/Podfile').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(podfile, contains('MAASO_POD_SCRIPT_CACHE'));
    expect(podfile, contains('MAASO_COCOAPODS_EMBED_V2'));
    expect(podfile, contains(r'${MAASO_RELEASE_SECURE_TEMP_DIR:-}'));
    expect(podfile, contains('/private/tmp/maaso-local-build.XXXXXXXX'));
    expect(podfile, contains('/usr/bin/mktemp -d'));
    expect(podfile, contains('/bin/mkdir -m 0700'));
    expect(podfile, contains('/bin/cp -p -P'));
    expect(podfile, contains('/usr/bin/shasum -a 256'));
    expect(podfile, isNot(contains('maaso-cocoapods-')));
    expect(project, contains('MAASO_POD_SCRIPT_CACHE'));
    expect(project, contains('MAASO_COCOAPODS_EMBED_V2'));
    expect(project, contains(r'MAASO_RELEASE_SECURE_TEMP_DIR'));
    expect(project, contains('Pods-Runner-resources.sh'));
    expect(project, contains('Pods-Runner-frameworks.sh'));
    expect(project, isNot(contains('maaso-cocoapods-')));
    expect(podfile, contains('runner_pod_phases.each(&:remove_from_project)'));
    expect(project, isNot(contains('/* [CP] Embed Pods Frameworks */')));
    expect(project, isNot(contains('/* [CP] Copy Pods Resources */')));
  });

  test('large iOS XCFramework pod targets form a serial dependency chain', () {
    final podfile = File('ios/Podfile').readAsStringSync();

    expect(podfile, contains('sherpa_onnx_ios VolcApiEngine VolcEngineRTC'));
    expect(podfile, contains('add_dependency(prerequisite)'));
  });

  test('large pod copy phases are delegated to the scheme preflight', () {
    final podfile = File('ios/Podfile').readAsStringSync();

    expect(podfile, contains("phase.name == '[CP] Copy XCFrameworks'"));
    expect(podfile, contains('phase.remove_from_project'));
  });

  test('Unity iOS IL2CPP host runs from a policy-safe temporary cache', () {
    final unityProject = File(
      'unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final exporter = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Editor/'
      'MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(unityProject, contains('MAASO_IL2CPP_CACHE_ROOT'));
    expect(unityProject, contains('IL2CPP_SOURCE_ROOT'));
    expect(unityProject, contains('/usr/bin/ditto'));
    expect(exporter, contains('PatchIOSIl2CppHostExecution(outputPath)'));
    expect(exporter, contains('MAASO_IL2CPP_CACHE_ROOT'));
    expect(exporter, contains('MAASO_IL2CPP_CACHE_SCHEMA'));
    expect(exporter, contains('IL2CPP_CACHE_READY'));
    expect(exporter, contains('System.IO.Pipelines.dll'));
    expect(exporter, contains('Unity IL2CPP cache copy is incomplete'));
  });

  test('asset catalog warm-up retries a transient actool crash', () {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'maaso-actool-preflight-test-',
    );
    addTearDown(() => temporaryDirectory.deleteSync(recursive: true));

    final attemptsFile = File('${temporaryDirectory.path}/attempts');
    final fakeActool = File('${temporaryDirectory.path}/actool')
      ..writeAsStringSync('''#!/bin/sh
attempt=0
if [ -f "\$MAASO_TEST_ATTEMPTS_FILE" ]; then
  attempt=\$(cat "\$MAASO_TEST_ATTEMPTS_FILE")
fi
attempt=\$((attempt + 1))
printf '%s' "\$attempt" > "\$MAASO_TEST_ATTEMPTS_FILE"
if [ "\$attempt" -lt 2 ]; then
  echo 'simulated AssetCatalogSimulatorAgent crash' >&2
  exit 72
fi
exit 0
''');
    final chmod = Process.runSync('chmod', ['+x', fakeActool.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

    final result = Process.runSync(
      '/bin/sh',
      ['ios/scripts/warm_asset_catalog_agent.sh'],
      environment: {
        ...Platform.environment,
        'MAASO_ACTOOL': fakeActool.path,
        'MAASO_TEST_ATTEMPTS_FILE': attemptsFile.path,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(attemptsFile.readAsStringSync(), '2');
    expect('${result.stderr}', contains('attempt 1 failed'));
  });
}
