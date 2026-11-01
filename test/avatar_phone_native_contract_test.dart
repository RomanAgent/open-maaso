import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('phone command and action receipt cross every native boundary', () {
    final mac = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    expect(
      mac.substring(mac.indexOf('avatarMethods:')),
      contains('"setPhoneInteraction"'),
    );
    expect(
      mac.substring(mac.indexOf('func isValidAvatarResult')),
      contains('"setPhoneInteraction"'),
    );
    for (final path in [
      'ios/Runner/AppDelegate.swift',
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('"setPhoneInteraction"'), reason: path);
      expect(
        source,
        contains('["interactionId"] = interactionId'),
        reason: path,
      );
    }
    for (final path in [
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/DesktopUnitySidecarBridge.cs',
      'windows/runner/unity_player_host.cpp',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('"setPhoneInteraction"'),
        reason: path,
      );
    }
    expect(
      File('web/maaso_unity_avatar.js').readAsStringSync(),
      contains('setPhoneInteraction: true'),
    );
  });

  test('Windows recognizes only the actual phone result method', () async {
    final native = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final first = native.indexOf('bool IsPhoneInteractionResult(');
    final last = native.indexOf('\n}', first) + 2;
    expect(first, greaterThanOrEqualTo(0));
    final temporary = Directory.systemTemp.createTempSync(
      'maaso-phone-receipt-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final file = File('${temporary.path}/receipt.cpp')
      ..writeAsStringSync('''
#include <string>
#include <regex>
#include <cassert>
${native.substring(first, last)}
int main() {
  assert(IsPhoneInteractionResult(R"json({"method":"setPhoneInteraction","ok":true})json"));
  assert(IsPhoneInteractionResult(R"json({ "method" : "setPhoneInteraction" })json"));
  assert(!IsPhoneInteractionResult(R"json({"method":"loadAvatar"})json"));
  assert(!IsPhoneInteractionResult(R"json({"method":"setPhoneInteractionOther"})json"));
  assert(!IsPhoneInteractionResult(R"json({"method":"other","code":"setPhoneInteraction"})json"));
}
''');
    final compile = await Process.run('clang++', [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      file.path,
      '-o',
      '${temporary.path}/receipt',
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stderr}');
    final run = await Process.run('${temporary.path}/receipt', []);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    // Phone ACK is accepted from the visible pet even after the handoff ends;
    // the concurrently running app renderer cannot supply a false completion.
    expect(
      native,
      contains(
        'pet_presenting && IsPhoneInteractionResult(pet_callback_payload)',
      ),
    );
    expect(native, contains('IsPhoneInteractionResult(main_callback_payload)'));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
