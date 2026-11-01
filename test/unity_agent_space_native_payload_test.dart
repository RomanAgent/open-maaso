import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native failure reasons match the Dart and Unity contract', () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final start = swift.indexOf(
      'private static let failureCodes: Set<String>',
      swift.indexOf('private enum UnityAgentSpacePayload {'),
    );
    final end = swift.indexOf(']', start);
    final nativeCodes = RegExp(r'"([a-z_]+)"')
        .allMatches(swift.substring(start, end))
        .map((match) => match.group(1)!)
        .toSet();
    final dart = File(
      'lib/src/features/agent/application/avatar/avatar_agent_space.dart',
    ).readAsStringSync();
    final dartStart = dart.indexOf('const avatarAgentSpaceFailureCodes');
    final dartEnd = dart.indexOf('};', dartStart);
    final dartCodes = RegExp(r"'([a-z_]+)'")
        .allMatches(dart.substring(dartStart, dartEnd))
        .map((match) => match.group(1)!)
        .toSet();
    final unity = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/AgentSpaceController.cs',
    ).readAsStringSync();
    final unityCodes = RegExp(
      r'"([a-z]+(?:_[a-z]+)+)"',
    ).allMatches(unity).map((match) => match.group(1)!).toSet();
    expect(nativeCodes, dartCodes);
    expect(nativeCodes, unityCodes);
  });
  test(
    'iOS and macOS enforce the real Agent Space native payload boundary',
    () async {
      if (!Platform.isMacOS) return;
      final nativeSources = <String>[
        'ios/Runner/AppDelegate.swift',
        'macos/Runner/MacOSUnityAvatarPortal.swift',
      ];
      final helpers = nativeSources.map((path) {
        final source = File(path).readAsStringSync();
        const marker = 'private enum UnityAgentSpacePayload {';
        final start = source.indexOf(marker);
        expect(start, greaterThanOrEqualTo(0));
        final end = source.indexOf('\n}\n\n', start);
        expect(end, greaterThan(start));
        return source.substring(start, end + 3);
      }).toList();
      expect(helpers[1], helpers[0]);
      final directory = Directory.systemTemp.createTempSync(
        'maaso-space-native-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final source = File('${directory.path}/main.swift');
      source.writeAsStringSync('''
import Foundation
import CoreFoundation
${helpers[0]}
$nativeCases
''');
      final executable = '${directory.path}/space-payload-test';
      final compilation = await Process.run('xcrun', [
        'swiftc',
        '-module-cache-path',
        '${directory.path}/module-cache',
        source.path,
        '-o',
        executable,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout}\n${compilation.stderr}',
      );
      final execution = await Process.run(executable, []);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}\n${execution.stderr}',
      );
      expect(
        execution.stdout,
        contains('Agent Space native payload boundary passed'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

const nativeCases = r'''
func check(_ value: Bool, _ label: String) {
  if !value { fatalError(label) }
}
let enter = "enterAgentSpace"
let move = "requestAgentSpaceMoveAtScreenPoint"
let args: [String: Any] = ["requestId": "request-1", "sessionId": "space:account-1"]
check(UnityAgentSpacePayload.isValidArguments(method: enter, raw: args), "valid entry")
check(UnityAgentSpacePayload.isValidArguments(method: "leaveAgentSpace", raw: args), "valid exit")
check(!UnityAgentSpacePayload.isValidArguments(method: "joinWorld", raw: args), "retired method")
for identifier in ["", " room", "room\n", "房间", String(repeating: "a", count: 129)] {
  var bad = args; bad["sessionId"] = identifier
  check(!UnityAgentSpacePayload.isValidArguments(method: enter, raw: bad), "invalid session")
}
var coordinates = args; coordinates["x"] = 0.5; coordinates["y"] = 1.0
check(UnityAgentSpacePayload.isValidArguments(method: move, raw: coordinates), "valid move")
for value: Any in [true, "0.5", Double.nan, Double.infinity, -0.1, 1.1] {
  var bad = coordinates; bad["x"] = value
  check(!UnityAgentSpacePayload.isValidArguments(method: move, raw: bad), "invalid coordinate")
}
var extra = args; extra["mapId"] = "cafe_garden"
check(!UnityAgentSpacePayload.isValidArguments(method: enter, raw: extra), "reject obsolete map arguments")
var receipt = args; receipt["method"] = enter; receipt["ok"] = true; receipt["code"] = ""
check(UnityAgentSpacePayload.publicResult(receipt) != nil, "valid entry receipt")
for field in ["requestId", "sessionId", "method", "ok", "code"] {
  var bad = receipt; bad.removeValue(forKey: field)
  check(UnityAgentSpacePayload.publicResult(bad) == nil, "incomplete receipt")
}
for value: Any in [1, 0, "true", NSNull()] {
  var bad = receipt; bad["ok"] = value
  check(UnityAgentSpacePayload.publicResult(bad) == nil, "strict receipt boolean")
}
var unknown = receipt; unknown["ok"] = false; unknown["code"] = "remote_map_download_failed"
check(UnityAgentSpacePayload.publicResult(unknown) == nil, "closed failure vocabulary")
var mismatched = receipt; mismatched["code"] = "session_mismatch"
check(UnityAgentSpacePayload.publicResult(mismatched) == nil, "success must have empty reason")
var failure = receipt; failure["ok"] = false; failure["code"] = "session_mismatch"
check(UnityAgentSpacePayload.publicResult(failure) != nil, "current session refusal")
var retired = receipt; retired["method"] = "worldPrivateFurniture"
check(UnityAgentSpacePayload.publicResult(retired) == nil, "obsolete World receipt")
var foreign = receipt; foreign["instanceId"] = "remote-room"
check(UnityAgentSpacePayload.publicResult(foreign) == nil, "reject extra authority fields")
print("Agent Space native payload boundary passed")
''';
