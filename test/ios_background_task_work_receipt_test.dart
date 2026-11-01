import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, dynamic> receipts;

  setUpAll(() async {
    if (!Platform.isMacOS) return;
    final directory = Directory.systemTemp.createTempSync(
      'maaso-ios-background-work-receipt-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final start = source.indexOf('private func exactPositiveJSONInteger(');
    final end = source.indexOf('private final class MaasoUnityPassthroughView');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final swift = File('${directory.path}/main.swift');
    swift.writeAsStringSync('''
import Foundation
import CoreFoundation
${source.substring(start, end)}
$_nativeCases
''');
    final executable = '${directory.path}/receipt-test';
    final compilation = await Process.run('xcrun', [
      'swiftc',
      '-module-cache-path',
      '${directory.path}/module-cache',
      swift.path,
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
    receipts = jsonDecode(execution.stdout as String) as Map<String, dynamic>;
  });

  test('real iOS work command accepts both phases and integer bounds', () {
    final valid = receipts['validCommands'] as Map<String, dynamic>;
    expect(
      valid.keys,
      unorderedEquals([
        'start',
        'end',
        'maximum identifiers',
        'maximum sequence',
        'maximum timestamps',
        'one millisecond window',
      ]),
    );
    for (final entry in valid.entries) {
      expect(entry.value, isTrue, reason: entry.key);
    }
  }, skip: !Platform.isMacOS);

  test('real iOS work command rejects malformed fields and open schemas', () {
    final invalid = receipts['invalidCommands'] as Map<String, dynamic>;
    expect(invalid, hasLength(80));
    for (final entry in invalid.entries) {
      expect(entry.value, isFalse, reason: entry.key);
    }
  }, skip: !Platform.isMacOS);

  test(
    'real iOS work acknowledgement projects eight fields and typed codes',
    () {
      final valid = receipts['validReplies'] as Map<String, dynamic>;
      expect(
        valid.keys,
        unorderedEquals([
          'start',
          'end',
          'maximum identifiers',
          'maximum sequence',
          ..._failureCodes,
        ]),
      );
      for (final entry in valid.entries) {
        final reply = entry.value as Map<String, dynamic>;
        expect(reply.keys, unorderedEquals(_replyKeys), reason: entry.key);
        expect(reply['method'], 'setBackgroundTaskWork');
        expect(reply['sessionId'], _sessionId);
        expect(reply['sequence'], isA<int>());
        expect(reply['requestId'], isNotEmpty);
        expect(reply['loadRequestId'], isNotEmpty);
        expect(reply['phase'], entry.key == 'end' ? 'end' : 'start');
        final failure = _failureCodes.contains(entry.key);
        expect(reply['ok'], !failure, reason: entry.key);
        expect(reply['code'], failure ? entry.key : '', reason: entry.key);
      }
      expect(
        (valid['maximum sequence'] as Map<String, dynamic>)['sequence'],
        9007199254740991,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS work acknowledgement rejects numeric booleans and unknown codes',
    () => _expectRejected(receipts['invalidReplies'], count: 68),
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS work state projects nine fields with scoped nullable work session',
    () {
      final valid = receipts['validStates'] as Map<String, dynamic>;
      expect(
        valid.keys,
        unorderedEquals([
          'approaching',
          'aligning',
          'working',
          'seated',
          'lying',
          'rising',
          'standing',
          'empty work session',
          'sofa',
          'chair',
          'bed',
          'maximum identifiers',
          'maximum sequence',
        ]),
      );
      for (final entry in valid.entries) {
        final state = entry.value as Map<String, dynamic>;
        expect(state.keys, unorderedEquals(_stateKeys), reason: entry.key);
        expect(state['method'], 'backgroundTaskWorkState');
        expect(state['requestId'], isNotEmpty);
        expect(state['loadRequestId'], isNotEmpty);
        expect(state['sceneId'], isNotEmpty);
        expect(state['sessionId'], _sessionId);
        expect(state['sequence'], isA<int>());
        if ([
          'approaching',
          'aligning',
          'working',
          'maximum identifiers',
          'maximum sequence',
        ].contains(entry.key)) {
          expect(state['workSessionId'], _sessionId, reason: entry.key);
          expect(state['furnitureId'], 'desk');
        } else {
          expect(
            state['workSessionId'],
            entry.key == 'empty work session' ? '' : null,
          );
        }
      }
      expect((valid['standing'] as Map<String, dynamic>)['furnitureId'], '');
      expect(
        (valid['maximum sequence'] as Map<String, dynamic>)['sequence'],
        9007199254740991,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS work state rejects malformed identities and session leakage',
    () => _expectRejected(receipts['invalidStates'], count: 89),
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS original furniture state preserves its original work session',
    () {
      final original = receipts['originalFurniture'] as Map<String, dynamic>;
      final working = original['working'] as Map<String, dynamic>;
      expect(working, {
        'method': 'furnitureState',
        'ownerToken': 'owner-original',
        'phase': 'working',
        'furnitureId': 'desk',
        'sceneId': 'original-room',
        'accountGeneration': 0,
        'rendererGeneration': 1,
        'sequence': 7,
        'workSessionId': List.filled(64, 'b').join(),
      });
      for (final key in ['absent', 'null', 'empty']) {
        final state = original[key] as Map<String, dynamic>;
        expect(
          state.keys,
          unorderedEquals([
            'method',
            'ownerToken',
            'phase',
            'furnitureId',
            'sceneId',
            'accountGeneration',
            'rendererGeneration',
            'sequence',
          ]),
          reason: key,
        );
        expect(state['phase'], 'working');
        expect(state['sequence'], 7);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS notification rejects malformed JSON and oversized work payloads',
    () => _expectRejected(receipts['invalidNotifications'], count: 10),
    skip: !Platform.isMacOS,
  );
}

void _expectRejected(dynamic raw, {required int count}) {
  final invalid = raw as Map<String, dynamic>;
  expect(invalid, hasLength(count));
  for (final entry in invalid.entries) {
    expect(entry.value, isNull, reason: entry.key);
  }
}

const _sessionId =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _failureCodes = [
  'invalid_command',
  'deadline_expired',
  'model_stale',
  'stale_sequence',
  'session_ended',
  'session_mismatch',
  'authority_owned',
  'not_ready',
  'presentation_busy',
  'user_pose_owned',
  'work_unavailable',
  'mutation_failed',
];
const _replyKeys = [
  'method',
  'requestId',
  'sessionId',
  'phase',
  'loadRequestId',
  'sequence',
  'ok',
  'code',
];
const _stateKeys = [
  'method',
  'requestId',
  'sessionId',
  'loadRequestId',
  'phase',
  'furnitureId',
  'sceneId',
  'sequence',
  'workSessionId',
];

const _nativeCases = r'''
let sessionId = String(repeating: "a", count: 64)
let otherSessionId = String(repeating: "b", count: 64)
let command: [String: Any] = [
  "requestId": "work-1", "sessionId": sessionId, "phase": "start",
  "loadRequestId": "load-1", "sequence": 1,
  "issuedAtEpochMs": 100_000, "deadlineEpochMs": 110_000,
]
let reply: [String: Any] = [
  "method": "setBackgroundTaskWork", "requestId": "work-1",
  "sessionId": sessionId, "phase": "start", "loadRequestId": "load-1",
  "sequence": 1, "ok": true, "code": "",
]
let state: [String: Any] = [
  "method": "backgroundTaskWorkState", "requestId": "work-1",
  "sessionId": sessionId, "phase": "working", "loadRequestId": "load-1",
  "sequence": 1, "furnitureId": "desk", "sceneId": "personal-room",
  "workSessionId": sessionId,
]
func changed(_ base: [String: Any], _ key: String, _ value: Any) -> [String: Any] {
  var raw = base; raw[key] = value; return raw
}
func notification(_ payload: Any) -> Any {
  return publicUnityCommandResultPayload(Notification(
    name: Notification.Name("test"), userInfo: ["payload": payload])) ?? NSNull()
}
func forward(_ raw: [String: Any]) -> Any {
  let data = try! JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
  return notification(String(data: data, encoding: .utf8)!)
}
func publicResult(_ raw: [String: Any]) -> Any {
  return UnityBackgroundTaskWorkPayload.publicResult(raw) ?? NSNull()
}
let invalidIdentifiers: [(String, Any)] = [
  ("empty", ""), ("blank", " \n\t"), ("overflow", String(repeating: "x", count: 129)),
  ("null", NSNull()), ("number", 1), ("boolean", true), ("array", ["work"]),
]
let invalidSessions: [(String, Any)] = [
  ("empty", ""), ("short", String(repeating: "a", count: 63)),
  ("long", String(repeating: "a", count: 65)),
  ("uppercase", String(repeating: "A", count: 64)),
  ("nonhex", String(repeating: "g", count: 64)),
  ("unicode", String(repeating: "字", count: 64)),
  ("newline", String(repeating: "a", count: 63) + "\n"),
  ("null", NSNull()), ("number", 64), ("boolean", true), ("array", [sessionId]),
]
let invalidIntegers: [(String, Any)] = [
  ("zero", 0), ("negative", -1), ("fraction", 1.5),
  ("overflow", NSNumber(value: Int64(9_007_199_254_740_992))),
  ("boolean", true), ("string", "1"), ("null", NSNull()), ("array", [1]),
  ("nan", Double.nan), ("infinity", Double.infinity),
]
var validCommands: [String: Any] = [
  "start": UnityBackgroundTaskWorkPayload.isValidArguments(command),
  "end": UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, "phase", "end")),
]
var maximumIdentifiers = command
maximumIdentifiers["requestId"] = String(repeating: "r", count: 128)
maximumIdentifiers["loadRequestId"] = String(repeating: "l", count: 128)
validCommands["maximum identifiers"] = UnityBackgroundTaskWorkPayload.isValidArguments(maximumIdentifiers)
validCommands["maximum sequence"] = UnityBackgroundTaskWorkPayload.isValidArguments(
  changed(command, "sequence", NSNumber(value: Int64(9_007_199_254_740_991))))
var maximumTimestamps = command
maximumTimestamps["issuedAtEpochMs"] = NSNumber(value: Int64(9_007_199_254_730_991))
maximumTimestamps["deadlineEpochMs"] = NSNumber(value: Int64(9_007_199_254_740_991))
validCommands["maximum timestamps"] = UnityBackgroundTaskWorkPayload.isValidArguments(maximumTimestamps)
validCommands["one millisecond window"] = UnityBackgroundTaskWorkPayload.isValidArguments(
  changed(command, "deadlineEpochMs", 100_001))
var invalidCommands: [String: Any] = [:]
for (label, raw) in [("null", NSNull() as Any), ("string", "command" as Any),
                     ("array", [command] as Any), ("number", 1 as Any)] {
  invalidCommands["raw \(label)"] = UnityBackgroundTaskWorkPayload.isValidArguments(raw)
}
invalidCommands["raw missing"] = UnityBackgroundTaskWorkPayload.isValidArguments(nil)
for key in command.keys {
  var raw = command; raw.removeValue(forKey: key)
  invalidCommands["missing \(key)"] = UnityBackgroundTaskWorkPayload.isValidArguments(raw)
}
for key in ["method", "privatePath", "workSessionId", "ownerToken", "ok"] {
  invalidCommands["extra \(key)"] = UnityBackgroundTaskWorkPayload.isValidArguments(
    changed(command, key, "/private/model"))
}
for key in ["requestId", "loadRequestId"] {
  for (label, value) in invalidIdentifiers {
    invalidCommands["\(key) \(label)"] = UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, key, value))
  }
}
for (label, value) in invalidSessions {
  invalidCommands["session \(label)"] = UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, "sessionId", value))
}
for (label, value) in [("unknown", "working" as Any), ("case", "START" as Any),
  ("empty", "" as Any), ("null", NSNull() as Any), ("number", 1 as Any)] {
  invalidCommands["phase \(label)"] = UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, "phase", value))
}
for key in ["sequence", "issuedAtEpochMs", "deadlineEpochMs"] {
  for (label, value) in invalidIntegers {
    invalidCommands["\(key) \(label)"] = UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, key, value))
  }
}
for (label, value) in [("equal deadline", 100_000), ("reversed deadline", 99_999),
                       ("window overflow", 110_001)] {
  invalidCommands[label] = UnityBackgroundTaskWorkPayload.isValidArguments(changed(command, "deadlineEpochMs", value))
}
var validReplies: [String: Any] = ["start": forward(reply), "end": forward(changed(reply, "phase", "end"))]
var maxReply = reply
maxReply["requestId"] = String(repeating: "r", count: 128)
maxReply["loadRequestId"] = String(repeating: "l", count: 128)
validReplies["maximum identifiers"] = forward(maxReply)
validReplies["maximum sequence"] = forward(changed(reply, "sequence", NSNumber(value: Int64(9_007_199_254_740_991))))
for code in ["invalid_command", "deadline_expired", "model_stale", "stale_sequence",
  "session_ended", "session_mismatch", "authority_owned", "not_ready",
  "presentation_busy", "user_pose_owned", "work_unavailable", "mutation_failed"] {
  var raw = reply; raw["ok"] = false; raw["code"] = code
  validReplies[code] = forward(raw)
}
var invalidReplies: [String: Any] = [:]
for key in reply.keys {
  var raw = reply; raw.removeValue(forKey: key)
  invalidReplies["missing \(key)"] = forward(raw)
}
for key in ["privatePath", "message", "issuedAtEpochMs", "deadlineEpochMs", "workSessionId"] {
  invalidReplies["extra \(key)"] = forward(changed(reply, key, "private"))
}
for key in ["requestId", "loadRequestId"] {
  for (label, value) in invalidIdentifiers { invalidReplies["\(key) \(label)"] = forward(changed(reply, key, value)) }
}
for (label, value) in invalidSessions { invalidReplies["session \(label)"] = forward(changed(reply, "sessionId", value)) }
for (label, value) in invalidIntegers { invalidReplies["sequence \(label)"] = publicResult(changed(reply, "sequence", value)) }
for (label, value) in [("numeric true", 1 as Any), ("numeric false", 0 as Any),
  ("string", "true" as Any), ("null", NSNull() as Any)] {
  invalidReplies["ok \(label)"] = forward(changed(reply, "ok", value))
}
for (label, value) in [("unknown", "working" as Any), ("case", "START" as Any),
  ("null", NSNull() as Any), ("number", 1 as Any)] {
  invalidReplies["phase \(label)"] = forward(changed(reply, "phase", value))
}
for (label, value) in [("failure on success", "deadline_expired" as Any),
  ("null", NSNull() as Any), ("number", 1 as Any),
  ("oversized", String(repeating: "x", count: 262_145) as Any)] {
  invalidReplies["code \(label)"] = forward(changed(reply, "code", value))
}
for code in ["", "failed", "DEADLINE_EXPIRED", "mutation_failed\n", "/private/model"] {
  var raw = reply; raw["ok"] = false; raw["code"] = code
  invalidReplies["failure code \(code)"] = forward(raw)
}
for method in ["furnitureState", "backgroundTaskWorkState", "unknown"] {
  invalidReplies["method \(method)"] = forward(changed(reply, "method", method))
}
var validStates: [String: Any] = [:]
for phase in ["approaching", "aligning", "working"] { validStates[phase] = forward(changed(state, "phase", phase)) }
for phase in ["seated", "lying", "rising", "standing"] {
  var raw = state; raw["phase"] = phase; raw["workSessionId"] = NSNull()
  if phase == "standing" { raw["furnitureId"] = "" }
  validStates[phase] = forward(raw)
}
validStates["empty work session"] = forward(changed(state, "workSessionId", ""))
for furniture in ["sofa", "chair", "bed"] {
  var raw = state; raw["furnitureId"] = furniture; raw["phase"] = "approaching"; raw["workSessionId"] = NSNull()
  validStates[furniture] = forward(raw)
}
var maxState = state
for key in ["requestId", "loadRequestId", "sceneId"] { maxState[key] = String(repeating: "x", count: 128) }
validStates["maximum identifiers"] = forward(maxState)
validStates["maximum sequence"] = forward(changed(state, "sequence", NSNumber(value: Int64(9_007_199_254_740_991))))
var invalidStates: [String: Any] = [:]
for key in state.keys {
  var raw = state; raw.removeValue(forKey: key); invalidStates["missing \(key)"] = forward(raw)
}
for key in ["privatePath", "ownerToken", "accountGeneration", "rendererGeneration", "ok", "code"] {
  invalidStates["extra \(key)"] = forward(changed(state, key, "private"))
}
for key in ["requestId", "loadRequestId", "sceneId"] {
  for (label, value) in invalidIdentifiers { invalidStates["\(key) \(label)"] = forward(changed(state, key, value)) }
}
for (label, value) in invalidSessions {
  invalidStates["session \(label)"] = forward(changed(state, "sessionId", value))
  invalidStates["work session \(label)"] = forward(changed(state, "workSessionId", value))
}
// A nullable or explicitly empty work session is accepted, unlike sessionId.
invalidStates.removeValue(forKey: "work session empty")
invalidStates.removeValue(forKey: "work session null")
invalidStates["work session mismatch"] = forward(changed(state, "workSessionId", otherSessionId))
for (label, value) in invalidIntegers { invalidStates["sequence \(label)"] = publicResult(changed(state, "sequence", value)) }
for (label, value) in [("unknown", "dancing" as Any), ("case", "WORKING" as Any),
  ("empty", "" as Any), ("null", NSNull() as Any), ("number", 1 as Any)] {
  invalidStates["phase \(label)"] = forward(changed(state, "phase", value))
}
for (label, value) in [("unknown", "stool" as Any), ("empty", "" as Any),
  ("case", "DESK" as Any), ("null", NSNull() as Any), ("number", 1 as Any),
  ("oversized", String(repeating: "d", count: 262_145) as Any)] {
  invalidStates["furniture \(label)"] = forward(changed(state, "furnitureId", value))
}
for furniture in ["", "sofa", "chair", "bed"] {
  invalidStates["work furniture \(furniture)"] = forward(changed(state, "furnitureId", furniture))
}
for phase in ["seated", "lying", "rising", "standing"] {
  invalidStates["work phase \(phase)"] = forward(changed(state, "phase", phase))
}
for method in ["furnitureState", "setBackgroundTaskWork", "unknown"] {
  invalidStates["method \(method)"] = forward(changed(state, "method", method))
}
let originalFurniture: [String: Any] = [
  "method": "furnitureState", "ownerToken": "owner-original", "phase": "working",
  "furnitureId": "desk", "sceneId": "original-room", "accountGeneration": 0,
  "rendererGeneration": 1, "sequence": 7, "workSessionId": otherSessionId,
  "privatePath": "/private/model", "requestId": "untrusted", "sessionId": sessionId,
]
var original: [String: Any] = ["working": forward(originalFurniture)]
var absent = originalFurniture; absent.removeValue(forKey: "workSessionId")
original["absent"] = forward(absent)
original["null"] = forward(changed(originalFurniture, "workSessionId", NSNull()))
original["empty"] = forward(changed(originalFurniture, "workSessionId", ""))
var invalidNotifications: [String: Any] = [:]
for payload in ["{", "[]", "null", "42", "\"text\"", "{\"sequence\":NaN}",
  "{\"method\":\"setBackgroundTaskWork\",\"ok\":true} trailing"] {
  invalidNotifications[payload] = notification(payload)
}
invalidNotifications["non-string"] = notification(reply)
invalidNotifications["absent payload"] = publicUnityCommandResultPayload(Notification(name: Notification.Name("test"))) ?? NSNull()
let validJSON = String(data: try! JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
invalidNotifications["oversized valid JSON"] = notification(validJSON + String(repeating: " ", count: 256 * 1024))
let output: [String: Any] = [
  "validCommands": validCommands, "invalidCommands": invalidCommands,
  "validReplies": validReplies, "invalidReplies": invalidReplies,
  "validStates": validStates, "invalidStates": invalidStates,
  "originalFurniture": original, "invalidNotifications": invalidNotifications,
]
let encoded = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(data: encoded, encoding: .utf8)!)
''';
