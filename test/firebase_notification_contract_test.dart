import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/firebase_bootstrap_service.dart';

void main() {
  test('Firebase project contract rejects accidental project drift', () {
    expect(
      FirebaseProjectContract.validate(
        projectId: 'masso-app-prod',
        messagingSenderId: '214440851723',
      ),
      isNull,
    );
    expect(
      FirebaseProjectContract.validate(
        projectId: 'another-project',
        messagingSenderId: '214440851723',
      ),
      contains('unexpected Firebase project'),
    );
  });

  test('background Firebase handler cannot enter app runtime or media', () {
    final source = File(
      'lib/src/core/notifications/firebase_bootstrap_service.dart',
    ).readAsStringSync();
    final handler = source.substring(
      source.indexOf("@pragma('vm:entry-point')"),
    );

    expect(handler, contains('firebaseMessagingBackgroundHandler'));
    expect(handler, isNot(contains('appServices')));
    expect(handler, isNot(contains('EventBus')));
    expect(handler, isNot(contains('AgentRuntime')));
    expect(handler, isNot(contains('Tts')));
    expect(handler, isNot(contains('Avatar')));
    expect(handler, contains('isDataOnly'));
    expect(handler, contains('hasCanonicalClaims'));
    expect(handler, isNot(contains('Firebase.initializeApp')));
    expect(handler, isNot(contains('.show(')));
  });

  test('remote delivery is data-only and background fail-closed', () {
    expect(FirebaseRemoteDeliveryContract.payloadMode, 'data-only');
    expect(
      FirebaseRemoteDeliveryContract.backgroundDeliveryMode,
      'fail-closed',
    );
    expect(
      FirebaseRemoteDeliveryContract.requiredDataClaims,
      containsAll(<String>['accountUuid', 'environmentKey', 'kind']),
    );
    expect(
      FirebaseRemoteDeliveryContract.hasCanonicalClaims(const <String, dynamic>{
        'accountUuid': 'account-a',
        'environmentKey': 'test',
        'kind': 'remote',
      }),
      isTrue,
    );
    expect(
      FirebaseRemoteDeliveryContract.hasCanonicalClaims(const <String, dynamic>{
        'accountUuid': ' account-a',
        'environmentKey': 'test',
        'kind': 'remote',
      }),
      isFalse,
    );
  });

  test(
    'mobile platform files carry notification plumbing without auto-init',
    () {
      final gradleSettings = File(
        'android/settings.gradle.kts',
      ).readAsStringSync();
      final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final info = File('ios/Runner/Info.plist').readAsStringSync();
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      final androidIcon = File(
        'android/app/src/main/res/drawable/ic_stat_maaso.xml',
      );

      expect(gradleSettings, contains('com.google.gms.google-services'));
      expect(appGradle, contains('google-services.json'));
      expect(appGradle, contains('isCoreLibraryDesugaringEnabled = true'));
      expect(appGradle, contains('desugar_jdk_libs:2.1.4'));
      expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
      expect(manifest, contains('ScheduledNotificationBootReceiver'));
      expect(manifest, contains('firebase_messaging_auto_init_enabled'));
      expect(info, contains('FirebaseMessagingAutoInitEnabled'));
      expect(info, contains('remote-notification'));
      expect(entitlements, contains('aps-environment'));
      expect(androidIcon.existsSync(), isTrue);
      expect(entitlements, isNot(contains('</content>')));
      expect(entitlements, isNot(contains('</invoke>')));
    },
  );

  test('native Firebase files target the exact Maaso production project', () {
    final android =
        jsonDecode(File('android/app/google-services.json').readAsStringSync())
            as Map<String, dynamic>;
    final project = android['project_info'] as Map<String, dynamic>;
    final clients = android['client'] as List<dynamic>;
    final androidInfo =
        (clients.single as Map<String, dynamic>)['client_info']
            as Map<String, dynamic>;
    final packageInfo =
        androidInfo['android_client_info'] as Map<String, dynamic>;
    final ios = File('ios/Runner/GoogleService-Info.plist').readAsStringSync();

    expect(project['project_id'], FirebaseProjectContract.projectId);
    expect(project['project_number'], FirebaseProjectContract.projectNumber);
    expect(packageInfo['package_name'], 'com.futurpals.maaso');
    expect(_plistString(ios, 'PROJECT_ID'), FirebaseProjectContract.projectId);
    expect(
      _plistString(ios, 'GCM_SENDER_ID'),
      FirebaseProjectContract.projectNumber,
    );
    expect(_plistString(ios, 'BUNDLE_ID'), 'com.futurpals.maaso');
  });

  test('iOS resolves Firebase and ML Kit through one CocoaPods graph', () {
    final podfile = File('ios/Podfile').readAsStringSync();
    final lock = File('ios/Podfile.lock').readAsStringSync();

    expect(podfile, contains("pod 'firebase_core', path:"));
    expect(podfile, contains("pod 'firebase_messaging', path:"));
    expect(podfile, contains('MaasoIosSwiftpmPrep.prepare!'));
    expect(lock, contains('firebase_core'));
    expect(lock, contains('firebase_messaging'));
    expect(lock, contains('Firebase/CoreOnly'));
    expect(lock, contains('Firebase/Messaging'));
    expect(lock, contains('GoogleMLKit/FaceDetection'));
  });
}

String? _plistString(String xml, String key) {
  final escaped = RegExp.escape(key);
  return RegExp(
    '<key>$escaped</key>\\s*<string>([^<]+)</string>',
  ).firstMatch(xml)?.group(1);
}
