import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  test(
    'Android local edition owns separate data and disables automatic Firebase',
    () {
      final gradle = source('android/app/build.gradle.kts');
      expect(gradle, contains('applicationId = "org.openmaaso.app"'));
      expect(
        gradle,
        isNot(contains('apply(plugin = "com.google.gms.google-services")')),
      );
      final manifest = XmlDocument.parse(
        source('android/app/src/main/AndroidManifest.xml'),
      );
      final application = manifest.findAllElements('application').single;
      expect(application.getAttribute('android:allowBackup'), 'false');
      expect(application.getAttribute('android:fullBackupContent'), 'false');
      final metadata = {
        for (final node in application.findElements('meta-data'))
          node.getAttribute('android:name'): node.getAttribute('android:value'),
      };
      expect(metadata['firebase_messaging_auto_init_enabled'], 'false');
      expect(metadata['firebase_analytics_collection_deactivated'], 'true');
      final firebase = application
          .findElements('provider')
          .singleWhere(
            (p) =>
                p.getAttribute('android:name') ==
                'com.google.firebase.provider.FirebaseInitProvider',
          );
      expect(firebase.getAttribute('tools:node'), 'remove');
      for (final alias in application.findElements('activity-alias')) {
        expect(
          alias.getAttribute('android:name'),
          startsWith(r'${applicationId}.'),
        );
        expect(
          alias.getAttribute('android:targetActivity'),
          'com.futurpals.maaso.MainActivity',
        );
      }
      expect(
        source('android/settings.gradle.kts'),
        contains('gradleProperty("openMaasoEmbedUnity").orNull != "false"'),
      );
      expect(
        source('android/settings.gradle.kts'),
        contains('requires its local free-avatar Unity export'),
      );
      expect(gradle, contains('Android release builds require'));
      expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
      expect(
        source('android/app/src/main/AndroidManifest.xml'),
        contains('android.intent.action.TTS_SERVICE'),
      );
    },
  );

  test('iOS offline player links local Unity without cloud configuration', () {
    final project = source('ios/Runner.xcodeproj/project.pbxproj');
    expect(project, contains('Unity-iPhone.xcodeproj'));
    expect(project, contains('UnityFramework.framework'));
    expect(project, isNot(contains('GoogleService-Info.plist')));
    expect(project, contains('PRODUCT_BUNDLE_IDENTIFIER = org.openmaaso.app;'));
    expect(
      project,
      isNot(contains('PRODUCT_BUNDLE_IDENTIFIER = com.futurpals.maaso;')),
    );
    final plist = source('ios/Runner/Info.plist');
    expect(
      plist,
      contains('<key>FirebaseAppDelegateProxyEnabled</key>\n\t\t<false/>'),
    );
    expect(
      plist,
      contains('<key>FirebaseMessagingAutoInitEnabled</key>\n\t\t<false/>'),
    );
    expect(plist, isNot(contains('<string>remote-notification</string>')));
    for (final path in [
      'ios/Runner/Runner.entitlements',
      'ios/Runner/RunnerRelease.entitlements',
    ]) {
      expect(source(path), isNot(contains('aps-environment')));
    }
    expect(
      source('ios/Runner/AppDelegate.swift'),
      contains('#if canImport(UnityFramework)'),
    );
    final delegate = source('ios/Runner/AppDelegate.swift');
    expect(
      delegate,
      contains(
        'class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {',
      ),
    );
    expect(
      delegate,
      contains('UNUserNotificationCenter.current().delegate = self'),
    );
    expect(delegate, isNot(contains('registerForRemoteNotifications()')));
    expect(delegate, contains('values.isExcludedFromBackup = true'));
    expect(delegate, contains('for: .applicationSupportDirectory'));
    expect(
      delegate.indexOf('excludeLocalDataFromCloudBackup()'),
      lessThan(delegate.indexOf('return super.application(application')),
    );
  });

  test('bundled Unity player disables cloud diagnostics and analytics', () {
    final root = 'unity/masso_avatar';
    final settings = source('$root/ProjectSettings/ProjectSettings.asset');
    expect(settings, contains('submitAnalytics: 0'));
    expect(settings, contains('enableCrashReportAPI: 0'));
    expect(settings, matches(RegExp(r'cloudProjectId:\s*\n')));
    expect(settings, contains('cloudServicesEnabled: {}'));
    final connect = source('$root/ProjectSettings/UnityConnectSettings.asset');
    expect(connect, isNot(matches(RegExp(r'm_Enabled: [1-9]'))));
    expect(connect, isNot(matches(RegExp(r'm_InitializeOnStartup: [1-9]'))));
    expect(connect, contains('m_EngineDiagnosticsEnabled: 0'));
    expect(connect, contains('m_EnableCloudDiagnosticsReporting: 0'));
    final manifest = source('$root/Packages/manifest.json');
    expect(manifest, isNot(contains('com.unity.modules.unityanalytics')));
    expect(manifest, isNot(contains('com.unity.services.')));
    expect(manifest, isNot(contains('com.unity.ads')));
  });

  for (final configuration in ['Debug', 'Profile', 'Release']) {
    test(
      'macOS $configuration omits and cleans only the generated Unity helper',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'open-maaso-native-',
        );
        addTearDown(() => root.delete(recursive: true));
        final contents = '${root.path}/products/OpenMaaso.app/Contents';
        final stale = Directory('$contents/Helpers/MaasoAvatar.app');
        await stale.create(recursive: true);
        await File(
          '${stale.path}/stale-player',
        ).writeAsString('old generated player');
        final keep = File('$contents/Helpers/keep.txt');
        await keep.writeAsString('unrelated content');
        final result = await Process.run(
          '/bin/sh',
          [File('macos/embed_unity_sidecar.sh').absolute.path],
          environment: {
            'SRCROOT': '${root.path}/source/macos',
            'TARGET_BUILD_DIR': '${root.path}/products',
            'CONTENTS_FOLDER_PATH': 'OpenMaaso.app/Contents',
            'CONFIGURATION': configuration,
          },
          includeParentEnvironment: false,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(stale.existsSync(), isFalse);
        expect(keep.readAsStringSync(), 'unrelated content');
      },
      skip: Platform.isWindows,
    );
  }

  test(
    'explicit macOS Unity opt-in still rejects absent release export',
    () async {
      final root = await Directory.systemTemp.createTemp('open-maaso-native-');
      addTearDown(() => root.delete(recursive: true));
      final result = await Process.run(
        '/bin/sh',
        [File('macos/embed_unity_sidecar.sh').absolute.path],
        environment: {
          'SRCROOT': '${root.path}/source/macos',
          'TARGET_BUILD_DIR': '${root.path}/products',
          'CONTENTS_FOLDER_PATH': 'OpenMaaso.app/Contents',
          'CONFIGURATION': 'Release',
          'OPEN_MAASO_EMBED_UNITY': '1',
        },
        includeParentEnvironment: false,
      );
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr.toString(),
        contains('export the Unity macOS sidecar'),
      );
    },
    skip: Platform.isWindows,
  );

  test('web shell loads bundled renderer assets and no Unity bootstrap', () {
    final bootstrap = source('web/flutter_bootstrap.js');
    expect(bootstrap, contains('{{flutter_js}}'));
    expect(bootstrap, contains('{{flutter_build_config}}'));
    expect(bootstrap, contains('canvasKitBaseUrl: "canvaskit/"'));
    expect(bootstrap, contains('fontFallbackBaseUrl: "fonts/"'));
    final fallback = File(
      'web/fonts/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2',
    ).readAsBytesSync();
    expect(String.fromCharCodes(fallback.take(4)), 'wOF2');
    expect(source('pubspec.yaml'), contains('family: MaasoOfflineSans'));
    expect(
      File('assets/fonts/NotoSansSC/NotoSansSC-Variable.ttf').existsSync(),
      isTrue,
    );
    expect(bootstrap, isNot(contains('https://')));
    final macScheme = source(
      'macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
    );
    expect(macScheme, contains('BuildableName = "OpenMaaso.app"'));
    expect(macScheme, isNot(contains('BuildableName = "maaso.app"')));
    expect(source('web/index.html'), isNot(contains('maaso_unity_avatar.js')));
    expect(
      source('macos/Runner/Configs/AppInfo.xcconfig'),
      contains('PRODUCT_BUNDLE_IDENTIFIER = org.openmaaso.app'),
    );
  });
}
