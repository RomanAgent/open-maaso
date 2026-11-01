import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

Map<String, String> _releaseTestEnvironment([
  Map<String, String> additions = const <String, String>{},
]) {
  final environment = Map<String, String>.from(Platform.environment)
    ..removeWhere((name, _) {
      return <String>{
            'RUBYOPT',
            'RUBYLIB',
            'RUBYGEMS_GEMDEPS',
            'GEM_HOME',
            'GEM_PATH',
            'FL_REPORT_PATH',
            'BASH_ENV',
            'ENV',
            'SHELLOPTS',
            'BASHOPTS',
            'CDPATH',
            'FASTLANE_PLUGIN_PATH',
            'FASTLANE_ENV',
            'FASTLANE_DOTENV',
            'JAVA_TOOL_OPTIONS',
            '_JAVA_OPTIONS',
            'JDK_JAVA_OPTIONS',
            'JAVA_OPTS',
            'JAVA_HOME',
            'GRADLE_OPTS',
            'GRADLE_USER_HOME',
            'PERL5OPT',
            'PERL5LIB',
            'PERLLIB',
          }.contains(name) ||
          name.startsWith('BUNDLE_') ||
          name.startsWith('BUNDLER_') ||
          name.startsWith('RBENV_');
    });
  return environment..addAll(additions);
}

void main() {
  test('Fastlane Appfiles are bound only to the Maaso store apps', () {
    final ios = _read('ios/fastlane/Appfile');
    final android = _read('android/fastlane/Appfile');

    expect(ios, contains('app_identifier("com.futurpals.maaso")'));
    expect(ios, contains('team_id("8C4MW2PX66")'));
    expect(android, contains('package_name("com.futurpals.maaso")'));
    expect('$ios\n$android', isNot(contains('iprojectoren')));
    expect('$ios\n$android', isNot(contains('json_key_file')));
    expect('$ios\n$android', isNot(contains('apple_id(')));
  });

  test('iOS lane uses in-memory credentials and safe TestFlight policy', () {
    final lane = _read('ios/fastlane/Fastfile');
    final signingGuard = _read('tool/ios/store_release_signing_guard.rb');

    for (final key in <String>[
      'APP_STORE_CONNECT_KEY_ID',
      'APP_STORE_CONNECT_ISSUER_ID',
      'APP_STORE_CONNECT_KEY_CONTENT_BASE64',
      'APPLE_DISTRIBUTION_CERT_SHA256',
      'STORE_RELEASE_CONFIRM',
      'STORE_BUILD_NUMBER',
    ]) {
      expect(lane, contains(key), reason: key);
    }
    expect(lane, contains('is_key_content_base64: true'));
    expect(lane, contains('skip_submission: true'));
    expect(lane, contains('distribute_external: false'));
    expect(lane, contains('skip_waiting_for_build_processing: true'));
    expect(lane, contains('live: false'));
    expect(lane, contains('platform: "ios"'));
    expect(lane, contains('tool/store_release_source_guard'));
    expect(lane, contains('tool/store_release_option_guard'));
    expect(lane, contains('MaasoStoreReleaseSourceGuard.verify!'));
    expect(lane, contains('MaasoStoreReleaseOptionGuard.verify_ios!'));
    expect(
      lane,
      contains('MaasoStoreReleaseSourceGuard.verify_bundler_runtime!'),
    );
    expect(
      lane,
      contains('--dart-define=MAASO_CREATOR_IMAGE_GENERATION_ENABLED=true'),
    );
    expect(lane, contains('--dart-define=MAASO_TEST_MEDIA_CDN_HOSTS='));
    expect(lane, contains('--dart-define=MAASO_STORE_INTERNAL_BUILD=true'));
    expect(lane, contains('--dart-define=MAASO_RUNTIME_AUTHORITY_MODE=shadow'));
    expect(lane, contains('tool/ios/store_release_swiftpm_prep'));
    expect(lane, contains('tool/ios/store_release_temp_guard'));
    expect(lane, contains('MAASO_RELEASE_SECURE_TEMP_DIR'));
    expect(lane, contains('MaasoIosSwiftpmPrep.prepare!'));
    expect(lane, contains('prepare_ios_swiftpm!'));
    expect(lane, contains('skip_docs'));
    expect(lane, contains('"--no-pub"'));
    expect(lane, isNot(contains('stderr.lines')));
    expect(lane, contains('entitlements["aps-environment"] == "production"'));
    expect(lane, contains('tool/ios/store_release_signing_guard'));
    expect(lane, contains('verify_installed_identity!'));
    expect(lane, contains('verify_signed_app!'));
    expect(signingGuard, contains('"--verify"'));
    expect(signingGuard, contains('"--deep"'));
    expect(signingGuard, contains('"--strict"'));
    expect(signingGuard, contains('"--extract-certificates"'));
    expect(signingGuard, contains('embedded.mobileprovision'));
    expect(signingGuard, contains('DeveloperCertificates'));
    expect(signingGuard, contains('final IPA signer does not match'));
    expect(lane, contains('].each { |name| ENV.delete(name) }'));
    expect(lane, contains('tool/store_release_artifact_path_guard'));
    expect(
      lane,
      contains('MaasoStoreReleaseArtifactPathGuard.clean_directory!'),
    );
    expect(
      lane,
      contains('MaasoStoreReleaseArtifactPathGuard.single_regular_artifact!'),
    );
    expect(lane, isNot(contains('FileUtils.rm_rf')));
    expect(lane, isNot(contains('key_filepath')));
    expect(lane, isNot(contains('AuthKey_')));
    expect(lane, isNot(contains('BrightBuddies')));
    expect(lane, isNot(contains('iprojectoren')));
  });

  test('Android lane is fixed to signed Play internal releases', () {
    final lane = _read('android/fastlane/Fastfile');
    final gradle = _read('android/app/build.gradle.kts');

    for (final key in <String>[
      'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64',
      'ANDROID_UPLOAD_KEYSTORE_BASE64',
      'ANDROID_UPLOAD_KEYSTORE_PASSWORD',
      'ANDROID_UPLOAD_KEY_ALIAS',
      'ANDROID_UPLOAD_KEY_PASSWORD',
      'ANDROID_UPLOAD_CERT_SHA256',
    ]) {
      expect(lane, contains(key), reason: key);
    }
    expect(lane, contains('track: "internal"'));
    expect(lane, contains('release_status: "completed"'));
    expect(lane, contains('skip_upload_metadata: true'));
    expect(lane, contains('skip_upload_aab: false'));
    expect(lane, contains('skip_upload_changelogs: true'));
    expect(lane, contains('skip_upload_images: true'));
    expect(lane, contains('skip_upload_screenshots: true'));
    expect(lane, contains('verify_aab_identity!'));
    expect(lane, contains('verify_aab_signature!'));
    expect(lane, contains('MaasoAndroidArtifactGuard.verify_identity!'));
    expect(lane, contains('MaasoAndroidArtifactGuard.verify_signature!'));
    expect(lane, contains('tool/android/store_release_keystore_temp'));
    expect(lane, contains('MaasoAndroidStoreReleaseKeystoreTemp.with_file!'));
    expect(lane, contains('MAASO_RELEASE_RUNTIME.fetch(:secure_temp)'));
    expect(lane, contains('secure_temp_receipt'));
    expect(lane, isNot(contains('apkanalyzer')));
    expect(lane, isNot(contains('sh("jarsigner", "-verify", "-strict"')));
    expect(lane, contains('tool/store_release_artifact_path_guard'));
    expect(lane, contains('MaasoStoreReleaseArtifactPathGuard.remove_file!'));
    expect(
      lane,
      contains('MaasoStoreReleaseArtifactPathGuard.verify_regular_file!'),
    );
    expect(lane, isNot(contains('FileUtils.rm_f')));
    expect(lane, contains('tool/store_release_source_guard'));
    expect(lane, contains('tool/store_release_option_guard'));
    expect(lane, contains('MaasoStoreReleaseSourceGuard.verify!'));
    expect(lane, contains('MaasoStoreReleaseOptionGuard.verify_android!'));
    expect(lane, contains('skip_docs'));
    expect(
      lane,
      contains('MaasoStoreReleaseSourceGuard.verify_bundler_runtime!'),
    );
    expect(lane, contains('Entry type: PrivateKeyEntry'));
    expect(lane, contains('does not match Play Console'));
    expect(
      lane,
      contains('--dart-define=MAASO_CREATOR_IMAGE_GENERATION_ENABLED=true'),
    );
    expect(lane, contains('--dart-define=MAASO_TEST_MEDIA_CDN_HOSTS='));
    expect(lane, contains('--dart-define=MAASO_STORE_INTERNAL_BUILD=true'));
    expect(lane, contains('--dart-define=MAASO_RUNTIME_AUTHORITY_MODE=shadow'));
    expect(
      lane,
      contains('ENV.delete("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64")'),
    );
    expect(lane, isNot(contains('stderr.lines')));
    expect(lane, isNot(contains('json_key_file')));
    expect(lane, isNot(contains('iprojectoren')));

    expect(gradle, contains('releaseTaskRequested'));
    expect(gradle, contains('providers.gradleProperty("skipIl2CppBuild")'));
    expect(gradle, contains('store releases forbid the Unity skipIl2CppBuild'));
    expect(gradle, contains('ANDROID_UPLOAD_KEYSTORE_PATH'));
    expect(gradle, contains('signingConfigs.getByName("release")'));
    expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
  });

  test('one-command deploy shares one guarded cross-store build number', () {
    final script = _read('deploy.sh');

    expect(script, startsWith('#!/bin/bash -p\n'));
    expect(script, contains('set -Eeuo pipefail'));
    expect(script, contains('maaso_release_reject_ambient_runtime'));
    expect(script, contains('maaso_release_reject_fastlane_files'));
    expect(script, contains('MAASO_RELEASE_BUNDLE_EXECUTABLE'));
    expect(script, contains('MAASO_RELEASE_FLUTTER_EXECUTABLE'));
    expect(script, contains('MAASO_RELEASE_KEYTOOL_EXECUTABLE'));
    expect(script, contains('BUNDLE_FROZEN=1'));
    expect(script, contains('BUNDLE_IGNORE_CONFIG=1'));
    expect(
      script,
      contains('FL_REPORT_PATH="\$MAASO_RELEASE_SECURE_TEMP_DIR"'),
    );
    expect(script, contains('maaso_release_cleanup_fastlane_report'));
    expect(script, isNot(contains('#!/usr/bin/env bash')));
    expect(script, contains('STORE_RELEASE_CONFIRM'));
    expect(script, contains('UPLOAD_MAASO_INTERNAL'));
    expect(script, contains('date -u +%s'));
    expect(script, contains('BUNDLE_GEMFILE="\$ROOT_DIR/ios/Gemfile"'));
    expect(script, contains('BUNDLE_GEMFILE="\$ROOT_DIR/android/Gemfile"'));
    expect(script, contains('MAASO_RELEASE_BUNDLETOOL_EXECUTABLE'));
    expect(script, contains('MAASO_RELEASE_BUNDLETOOL_JAR'));
    expect(script, contains('MAASO_RELEASE_JARSIGNER_EXECUTABLE'));
    expect(script, contains('MAASO_RELEASE_POD_EXECUTABLE'));
    expect(script, contains('MAASO_RELEASE_TOOLS_DIR'));
    expect(script, contains('MAASO_RELEASE_SECURE_TEMP_STAT'));
    expect(script, contains('MAASO_RELEASE_SAFE_PATH'));
    expect(script, contains('maaso_release_resolve_bundle_executable'));
    expect(script, contains('maaso_release_prepare_pod_wrapper'));
    expect(script, contains('maaso_release_prepare_bundletool_wrapper'));
    expect(script, contains('MAASO_RELEASE_GRADLE_USER_HOME'));
    expect(script, contains('reject_git_repository_overrides'));
    expect(script, contains('verify_release_source_before_secrets'));
    expect(script, contains('create_release_secure_temp'));
    expect(script, contains('/private/tmp/maaso-store-release.XXXXXXXX'));
    expect(script, contains('/private/tmp/maaso-store-tools.XXXXXXXX'));
    expect(script, contains('/usr/bin/git'));
    expect(script, contains('/usr/bin/env'));
    expect(script, contains('-u APP_STORE_CONNECT_KEY_CONTENT_BASE64'));
    expect(script, contains('-u GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64'));
    expect(script, contains('-u ANDROID_UPLOAD_KEYSTORE_PASSWORD'));
    expect(script, contains('--no-replace-objects'));
    expect(script, contains('core.fileMode=true'));
    expect(script, contains('ls-files -v -z'));
    expect(script, contains('refs/heads/main'));
    expect(script, contains('run_ios beta'));
    expect(script, contains('run_android beta'));
    final allBranch = script.lastIndexOf('\n  all)');
    expect(allBranch, greaterThan(0));
    final iosPreflight = script.indexOf('run_ios preflight', allBranch);
    final androidPreflight = script.indexOf('run_android preflight', allBranch);
    final iosUpload = script.indexOf('run_ios beta', allBranch);
    expect(iosPreflight, greaterThan(allBranch));
    expect(androidPreflight, greaterThan(allBranch));
    expect(iosUpload, greaterThan(allBranch));
    expect(iosPreflight, lessThan(iosUpload));
    expect(androidPreflight, lessThan(iosUpload));
    final sourceGate = script.indexOf(
      '\nverify_release_source_before_secrets\n',
    );
    final firstPlatformRun = script.indexOf('\n    run_ios preflight');
    expect(sourceGate, greaterThan(0));
    expect(firstPlatformRun, greaterThan(sourceGate));
    expect(script, isNot(contains('IOS_DONE')));
    expect(script, isNot(contains('ANDROID_DONE')));
    expect(script, isNot(contains('iprojectoren')));

    final result = Process.runSync(
      '/bin/bash',
      <String>['-p', 'deploy.sh', 'not-a-release-command'],
      environment: _releaseTestEnvironment(),
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 64);
    expect(
      '${result.stdout}${result.stderr}',
      contains('Unknown release command'),
    );

    final redirected = Process.runSync(
      '/bin/bash',
      <String>['-p', 'deploy.sh', 'preflight'],
      environment: _releaseTestEnvironment(<String, String>{
        'GIT_DIR': '/tmp/not-the-maaso-repository',
      }),
      includeParentEnvironment: false,
    );
    expect(redirected.exitCode, isNot(0));
    expect(
      '${redirected.stdout}${redirected.stderr}',
      contains('Ambient Git configuration is forbidden'),
    );

    final temporary = Directory.systemTemp.createTempSync(
      'maaso-release-bash-env-contract.',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final canary = File('${temporary.path}/canary');
    final payload = File('${temporary.path}/payload')
      ..writeAsStringSync('/usr/bin/touch "${canary.path}"\n');
    final bashEnv = Process.runSync(
      './deploy.sh',
      <String>['help'],
      environment: _releaseTestEnvironment(<String, String>{
        'BASH_ENV': payload.path,
      }),
      includeParentEnvironment: false,
    );
    expect(bashEnv.exitCode, isNot(0));
    expect(canary.existsSync(), isFalse);
    expect('${bashEnv.stdout}${bashEnv.stderr}', contains('BASH_ENV'));

    const sentinel = 'runtime-secret-must-not-be-printed';
    final rubyOpt = Process.runSync(
      './deploy.sh',
      <String>['help'],
      environment: _releaseTestEnvironment(<String, String>{
        'RUBYOPT': sentinel,
      }),
      includeParentEnvironment: false,
    );
    expect(rubyOpt.exitCode, isNot(0));
    expect('${rubyOpt.stdout}${rubyOpt.stderr}', contains('RUBYOPT'));
    expect('${rubyOpt.stdout}${rubyOpt.stderr}', isNot(contains(sentinel)));
  });

  test('store lanes revalidate launcher-selected absolute tools', () {
    final runtimeGuard = _read('tool/store_release_runtime_guard.rb');
    final launcherGuard = _read('tool/store_release_launcher_guard.sh');
    final ios = _read('ios/fastlane/Fastfile');
    final android = _read('android/fastlane/Fastfile');

    for (final value in <String>[
      'RUBYOPT',
      'RUBYLIB',
      'RUBYGEMS_GEMDEPS',
      'GEM_HOME',
      'GEM_PATH',
      'BASH_ENV',
      'ENV',
      'SHELLOPTS',
      'BASHOPTS',
      'CDPATH',
      'FASTLANE_PLUGIN_PATH',
      'FASTLANE_ENV',
      'FASTLANE_DOTENV',
      'JAVA_TOOL_OPTIONS',
      '_JAVA_OPTIONS',
      'JDK_JAVA_OPTIONS',
      'JAVA_HOME',
      'GRADLE_OPTS',
      'GRADLE_USER_HOME',
      'PERL5OPT',
      'PERL5LIB',
      'PERLLIB',
      'RBENV_*',
      'FL_REPORT_PATH',
      'BUNDLE_*',
    ]) {
      expect(launcherGuard, contains(value), reason: value);
    }
    expect(launcherGuard, contains('*.env*'));
    expect(launcherGuard, contains('Fastfile.swift'));
    expect(launcherGuard, contains('Fastlane custom actions and plugins'));
    expect(launcherGuard, contains('/usr/bin/shasum -a 256'));
    expect(launcherGuard, contains('/usr/bin/env -i LANG=C LC_ALL=C'));
    expect(runtimeGuard, contains('MaasoStoreReleaseRuntimeGuard'));
    expect(runtimeGuard, contains('FASTLANE_VERSION = "2.232.2"'));
    expect(runtimeGuard, contains('BUNDLER_VERSION = "4.0.8"'));
    expect(runtimeGuard, contains('Digest::SHA256.file(path).hexdigest'));
    expect(runtimeGuard, contains('TOOLS_TEMP_BASENAME'));
    expect(runtimeGuard, contains('verify_regular_file_handoff!'));
    expect(launcherGuard, contains('MAASO_RELEASE_BUNDLETOOL_JAR_SHA256'));
    expect(launcherGuard, contains('maaso_release_prepare_pod_wrapper'));
    expect(launcherGuard, contains('maaso_release_prepare_bundletool_wrapper'));
    expect(launcherGuard, contains('PATH=/usr/bin:/bin:/usr/sbin:/sbin'));

    for (final lane in <String>[ios, android]) {
      expect(lane, contains('tool/store_release_runtime_guard'));
      expect(lane, contains('MaasoStoreReleaseRuntimeGuard.verify!'));
      expect(lane, isNot(contains('sh("flutter"')));
    }
    expect(ios, contains('release_flutter_executable!'));
    expect(ios, contains('verify_ios_pod_runtime!'));
    expect(android, contains('release_executable!(:flutter)'));
    expect(android, contains('release_executable!(:keytool)'));
    expect(android, contains('release_executable!(:bundletool)'));
    expect(android, contains('release_executable!(:jarsigner)'));
    expect(android, contains('"--no-android-gradle-daemon"'));
    expect(android, contains('unsetenv_others: true'));
    expect(android, isNot(contains('\n        "keytool",')));
  });

  test(
    'Android upload keystore ignores TMPDIR and stays in the launcher root',
    () {
      final helper = _read('tool/android/store_release_keystore_temp.rb');
      final helperTest = _read(
        'tool/android/store_release_keystore_temp_test.rb',
      );
      final lane = _read('android/fastlane/Fastfile');
      final script = _read('deploy.sh');

      expect(
        helper,
        contains('Tempfile.create(["maaso-upload-", ".jks"], directory)'),
      );
      expect(helper, contains('file.fsync'));
      expect(helper, contains('(stat.mode & 0o777) == 0o600'));
      expect(helper, contains('File.dirname(canonical) == directory'));
      expect(helper, contains('!stat.symlink?'));
      expect(helperTest, contains('ENV["TMPDIR"] = @hostile_tmp'));
      expect(helperTest, contains('assert_equal @secure, File.dirname(path)'));
      expect(lane, contains('MaasoAndroidStoreReleaseKeystoreTemp.with_file!'));
      expect(script, contains('cleanup_release_secure_temp'));
    },
  );

  test('release tooling is pinned and generated reports stay untracked', () {
    expect(File('ios/Gemfile').existsSync(), isTrue);
    expect(File('ios/Gemfile.lock').existsSync(), isTrue);
    expect(File('android/Gemfile').existsSync(), isTrue);
    expect(File('android/Gemfile.lock').existsSync(), isTrue);
    expect(_read('ios/Gemfile.lock'), contains('fastlane (2.232.2)'));
    expect(_read('android/Gemfile.lock'), contains('fastlane (2.232.2)'));

    final ignore = _read('.gitignore');
    expect(ignore, contains('**/fastlane/report.xml'));
    expect(ignore, contains('**/fastlane/*.p12'));
    expect(ignore, contains('**/fastlane/*.mobileprovision'));
    expect(ignore, contains('/.store-release.env'));
    expect(File('ios/fastlane/report.xml').existsSync(), isFalse);
    expect(File('android/fastlane/report.xml').existsSync(), isFalse);
    for (final path in <String>[
      'ios/fastlane/README.md',
      'android/fastlane/README.md',
    ]) {
      final readme = _read(path);
      expect(readme, contains('./deploy.sh preflight'));
      expect(readme, contains('release trust boundary'));
      expect(readme, isNot(contains('bundle exec fastlane ios')));
      expect(readme, isNot(contains('bundle exec fastlane android')));
      expect(readme, isNot(contains('[bundle exec] fastlane')));
    }
  });

  test('store source and ambient option guards fail closed', () {
    final sourceGuard = _read('tool/store_release_source_guard.rb');
    final optionGuard = _read('tool/store_release_option_guard.rb');

    expect(sourceGuard, contains('/usr/bin/git'));
    expect(sourceGuard, contains('--no-replace-objects'));
    expect(sourceGuard, contains('core.fileMode=true'));
    expect(sourceGuard, contains('start_with?("GIT_")'));
    expect(sourceGuard, contains('name != "GIT_PAGER"'));
    expect(sourceGuard, contains('"GIT_PAGER" => "cat"'));
    expect(sourceGuard, contains('ls-files'));
    expect(sourceGuard, contains('"-v", "-z"'));
    expect(sourceGuard, contains('refs/replace/'));
    expect(sourceGuard, contains('refs/heads/main'));
    expect(sourceGuard, contains('https://github.com/futurpals/maaso.git'));
    expect(sourceGuard, contains('git@github.com:futurpals/maaso.git'));
    expect(sourceGuard, contains('FASTLANE_VERSION = "2.232.2"'));
    expect(sourceGuard, contains('legacy plaintext store credential material'));

    expect(optionGuard, contains('SUPPLY_'));
    expect(optionGuard, contains('PILOT_'));
    expect(optionGuard, contains('FASTLANE_ITUNES_TRANSPORTER_'));
    expect(optionGuard, contains('LATEST_TESTFLIGHT_BUILD_NUMBER_'));
    expect(optionGuard, contains('APP_STORE_CONNECT_API_KEY_'));
    expect(optionGuard, contains('CURRENT_BUILD_NUMBER_LIVE'));
    expect(optionGuard, contains('APPSTORE_PLATFORM'));
    expect(optionGuard, contains('DEMO_ACCOUNT_REQUIRED'));
    expect(optionGuard, contains('GOOGLE_APPLICATION_CREDENTIALS'));
  });

  test('iOS Release uses exact production push entitlements', () {
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');
    final releaseEntitlements = _read('ios/Runner/RunnerRelease.entitlements');
    final lane = _read('ios/fastlane/Fastfile');

    expect(
      project,
      contains('CODE_SIGN_ENTITLEMENTS = Runner/RunnerRelease.entitlements;'),
    );
    expect(project, contains('GoogleService-Info.plist in Resources'));
    expect(
      RegExp(
        'GoogleService-Info\\.plist in Resources',
      ).allMatches(project).length,
      greaterThanOrEqualTo(2),
    );
    expect(lane, contains('embedded_firebase_path'));
    expect(
      lane,
      contains('embedded_firebase["PROJECT_ID"] == "masso-app-prod"'),
    );
    expect(
      lane,
      contains('embedded_firebase["BUNDLE_ID"] == MAASO_IOS_BUNDLE_ID'),
    );
    expect(releaseEntitlements, contains('<string>production</string>'));
    expect(
      releaseEntitlements,
      contains('<key>com.apple.developer.kernel.increased-memory-limit</key>'),
    );
    expect(
      releaseEntitlements,
      isNot(contains('<string>development</string>')),
    );
  });

  test('iOS CocoaPods scripts execute only from launcher-private storage', () {
    final podfile = _read('ios/Podfile');
    final project = _read('ios/Runner.xcodeproj/project.pbxproj');

    expect(podfile, contains('MAASO_COCOAPODS_EMBED_V2'));
    expect(podfile, contains(r'${MAASO_RELEASE_SECURE_TEMP_DIR:-}'));
    expect(podfile, contains('/private/tmp/maaso-local-build.XXXXXXXX'));
    expect(podfile, contains('/usr/bin/mktemp -d'));
    expect(podfile, contains('/usr/bin/stat -f'));
    expect(podfile, contains('/bin/mkdir -m 0700'));
    expect(podfile, contains('/bin/cp -p -P'));
    expect(podfile, contains('/usr/bin/shasum -a 256'));
    expect(podfile, contains('trap maaso_cleanup_pod_script_cache EXIT'));
    expect(podfile, isNot(contains(r'/private/tmp/maaso-cocoapods-${USER')));
    expect(project, contains('MAASO_COCOAPODS_EMBED_V2'));
    expect(project, contains(r'MAASO_RELEASE_SECURE_TEMP_DIR'));
    expect(project, isNot(contains('maaso-cocoapods-')));
  });

  test('Unity store exports require deterministic committed provenance', () {
    final guard = _read('tool/unity/store_release_provenance.rb');
    final generator = _read('tool/unity/generate_store_release_provenance.rb');
    final guide = _read('docs/deployment/store-release.md');
    final iosLane = _read('ios/fastlane/Fastfile');
    final androidLane = _read('android/fastlane/Fastfile');

    expect(guard, contains('release/unity-export-provenance.json'));
    expect(guard, contains('tracked Unity source or export tooling differs'));
    expect(guard, contains('manifest must be committed at HEAD'));
    expect(guard, contains('symlinked Unity inputs are forbidden'));
    expect(guard, contains('special Unity inputs are forbidden'));
    expect(guard, contains('verify_and_clean_android_generated_outputs!'));
    expect(guard, contains('clean_android_generated_outputs!'));
    expect(guard, contains('unityLibrary/.cxx/**'));
    expect(guard, contains('unityLibrary/build/**'));
    expect(guard, contains('unityLibrary/symbols/**'));
    expect(guard, contains('libil2cpp*.so'));
    expect(guard, contains('**/xcuserdata/**'));
    expect(guard, contains('Il2CppTempDirArtifacts/**'));
    expect(guard, contains('*_BurstDebugInformation_DoNotShip/**'));
    expect(generator, contains('ARGV == ["--reviewed-exports"]'));
    for (final name in <String>[
      'GIT_DIR',
      'GIT_WORK_TREE',
      'GIT_INDEX_FILE',
      'GIT_OBJECT_DIRECTORY',
      'GIT_ALTERNATE_OBJECT_DIRECTORIES',
      'GIT_COMMON_DIR',
      'GIT_NAMESPACE',
    ]) {
      expect(guard, contains(name), reason: name);
    }
    expect(guard, contains('--no-replace-objects'));
    expect(guard, contains('--show-toplevel'));
    expect(
      guard,
      contains('top-level does not match the canonical release root'),
    );
    expect(guide, contains('git add release/unity-export-provenance.json'));
    expect(guide, contains('verify provenance before and after'));

    for (final lane in <String>[iosLane, androidLane]) {
      expect(lane, contains('tool/unity/store_release_provenance'));
    }

    final iosContext = iosLane.indexOf('def ios_release_context!');
    final iosContextSource = iosLane.indexOf(
      'verify_release_source!',
      iosContext,
    );
    final iosContextInputs = iosLane.indexOf('verify_ios_inputs!', iosContext);
    final iosContextProvenance = iosLane.indexOf(
      'verify_ios_unity_export_provenance!',
      iosContext,
    );
    expect(iosContext, greaterThanOrEqualTo(0));
    expect(iosContextSource, greaterThan(iosContext));
    expect(iosContextInputs, greaterThan(iosContextSource));
    expect(iosContextProvenance, greaterThan(iosContextInputs));

    final iosBeta = iosLane.indexOf('lane :beta do');
    final iosBeforeBuild = iosLane.indexOf(
      'verify_ios_unity_export_provenance!',
      iosBeta,
    );
    final iosBuild = iosLane.indexOf('clean_ios_ipa_artifacts!', iosBeta);
    final iosAfterBuild = iosLane.indexOf(
      'verify_ios_unity_export_provenance!',
      iosBeforeBuild + 1,
    );
    expect(iosBeforeBuild, greaterThan(iosBeta));
    expect(iosBuild, greaterThan(iosBeforeBuild));
    expect(iosAfterBuild, greaterThan(iosBuild));

    final androidContext = androidLane.indexOf('def android_release_context!');
    final androidContextSource = androidLane.indexOf(
      'verify_release_source!',
      androidContext,
    );
    final androidContextInputs = androidLane.indexOf(
      'verify_android_inputs!',
      androidContext,
    );
    final androidContextProvenance = androidLane.indexOf(
      'verify_android_unity_export_provenance!',
      androidContext,
    );
    expect(androidContext, greaterThanOrEqualTo(0));
    expect(androidContextSource, greaterThan(androidContext));
    expect(androidContextInputs, greaterThan(androidContextSource));
    expect(androidContextProvenance, greaterThan(androidContextInputs));

    final androidBeta = androidLane.indexOf('lane :beta do');
    final androidBeforeBuild = androidLane.indexOf(
      'verify_android_unity_export_provenance!',
      androidBeta,
    );
    final androidClean = androidLane.indexOf(
      'clean_android_unity_generated_outputs!',
      androidBeforeBuild,
    );
    final androidBuild = androidLane.indexOf('clean_android_aab!', androidBeta);
    final androidAfterBuild = androidLane.indexOf(
      'verify_android_unity_export_provenance!',
      androidBuild + 1,
    );
    final androidSigningScopeEnd = androidLane.indexOf(
      '\n    end\n\n    verify_android_unity_export_provenance!',
      androidBuild,
    );
    final androidPostBuildSource = androidLane.indexOf(
      'verify_release_source!',
      androidAfterBuild,
    );
    expect(androidBeforeBuild, greaterThan(androidBeta));
    expect(androidClean, greaterThan(androidBeforeBuild));
    expect(androidBuild, greaterThan(androidClean));
    expect(androidAfterBuild, greaterThan(androidBuild));
    expect(androidSigningScopeEnd, greaterThan(androidBuild));
    expect(androidPostBuildSource, greaterThan(androidAfterBuild));
  });
}
