import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> receipts;

  setUpAll(() async {
    if (!Platform.isMacOS) return;
    final directory = Directory.systemTemp.createTempSync(
      'maaso-ios-avatar-receipt-',
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

  test(
    'real iOS receipt preserves the Unity profile and advertised work version',
    () {
      final supported = receipts['supported'] as Map<String, dynamic>;
      expect(supported['ok'], isTrue);
      expect(supported['backgroundTaskWorkVersion'], 1);
      final profile = AvatarCapabilityProfile.fromJson(
        supported['capabilityProfile'],
      );
      expect(profile.source, AvatarCapabilitySource.unity);
      expect(profile.state, AvatarCapabilityState.supported);
      expect(profile.rendererCount, 2);
      expect(profile.estimatedTextureBytes, 25165824);
      expect(supported.keys, isNot(contains('privatePath')));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS profile boundary rejects malformed metadata with matched failures',
    () {
      final invalid = receipts['invalidProfiles'] as Map<String, dynamic>;
      expect(invalid, isNotEmpty);
      for (final entry in invalid.entries) {
        final result = entry.value as Map<String, dynamic>;
        expect(result['requestId'], 'load-1', reason: entry.key);
        expect(result['method'], 'loadAvatar', reason: entry.key);
        expect(result['ok'], isFalse, reason: entry.key);
        expect(result['code'], 'invalid_capability_profile', reason: entry.key);
        expect(result.keys, isNot(contains('capabilityProfile')));
        expect(result.keys, isNot(contains('privatePath')));
        expect(
          result['message'],
          'Unity avatar capability profile is invalid.',
        );
      }
      expect(receipts['invalidJSON'], isNull);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS work version requires a bounded integer and keeps absent legacy fields',
    () {
      final invalid = receipts['invalidVersions'] as Map<String, dynamic>;
      for (final entry in invalid.entries) {
        final result = entry.value as Map<String, dynamic>;
        expect(result['ok'], isFalse, reason: entry.key);
        expect(
          result['code'],
          'invalid_background_task_work_version',
          reason: entry.key,
        );
      }
      expect(
        (receipts['futureVersion']
            as Map<String, dynamic>)['backgroundTaskWorkVersion'],
        2,
      );
      final legacy = receipts['legacy'] as Map<String, dynamic>;
      expect(legacy['ok'], isTrue);
      expect(legacy.keys, isNot(contains('capabilityProfile')));
      expect(legacy.keys, isNot(contains('backgroundTaskWorkVersion')));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'real iOS supported receipt completes a matched remote runtime load',
    () async {
      final transport = _ReceiptTransport(
        receipts['supported'] as Map<String, dynamic>,
      );
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      await runtime.loadAvatar('https://assets.example.com/avatar.vrm');
      expect(
        runtime.activeCapabilityProfile.source,
        AvatarCapabilitySource.unity,
      );
      expect(
        runtime.activeCapabilityProfile.state,
        AvatarCapabilityState.supported,
      );
      expect(runtime.supportsBackgroundTaskWorkPresentation, isTrue);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Dart remains authoritative for semantic profiles and remote compatibility',
    () async {
      for (final name in ['blocked', 'inconsistent', 'unknown', 'legacy']) {
        final transport = _ReceiptTransport(
          receipts[name] as Map<String, dynamic>,
        );
        final runtime = UnityAvatarRuntime(transport: transport);
        try {
          await transport.emit(const MethodCall('ready'));
          await expectLater(
            runtime.loadAvatar('https://assets.example.com/avatar.vrm'),
            throwsStateError,
            reason: name,
          );
          expect(
            runtime.activeCapabilityProfile.state,
            AvatarCapabilityState.unknown,
          );
          expect(runtime.supportsBackgroundTaskWorkPresentation, isFalse);
        } finally {
          runtime.onClose();
        }
      }
      final legacyTransport = _ReceiptTransport(
        receipts['legacy'] as Map<String, dynamic>,
      );
      final legacyRuntime = UnityAvatarRuntime(transport: legacyTransport);
      addTearDown(legacyRuntime.onClose);
      await legacyTransport.emit(const MethodCall('ready'));
      await legacyRuntime.loadAvatar('unity://masso/avatar_agent');
      expect(
        legacyRuntime.activeCapabilityProfile.state,
        AvatarCapabilityState.unknown,
      );
    },
    skip: !Platform.isMacOS,
  );
}

class _ReceiptTransport implements UnityAvatarTransport {
  _ReceiptTransport(this.receipt);

  final Map<String, dynamic> receipt;
  UnityAvatarMethodCallHandler? handler;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'loadAvatar') {
      final payload = arguments as Map<String, Object?>;
      scheduleMicrotask(() async {
        await emit(
          MethodCall('commandResult', {
            ...receipt,
            'requestId': payload['requestId'],
          }),
        );
      });
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) async => handler?.call(call);

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    this.handler = handler;
  }

  @override
  void dispose() => handler = null;
}

const _nativeCases = r'''
let supported: [String: Any] = [
  "schemaVersion": 1, "source": "unity", "state": "supported",
  "rig": ["humanoid": true, "head": true, "leftEye": true, "rightEye": true],
  "behavior": ["lookAt": true, "lipSync": true, "blink": true, "expressions": true],
  "render": ["renderable": true, "rendererCount": 2, "skinnedMeshCount": 1,
    "vertexCount": 64000, "triangleCount": 96000, "materialCount": 6,
    "textureCount": 8, "maxTextureSize": 2048, "estimatedTextureBytes": 25165824],
  "issues": []
]
let base: [String: Any] = ["method": "loadAvatar", "requestId": "load-1", "ok": true]
func forward(_ raw: [String: Any]) -> Any {
  let data = try! JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
  let notification = Notification(name: Notification.Name("test"),
    userInfo: ["payload": String(data: data, encoding: .utf8)!])
  return publicUnityCommandResultPayload(notification) ?? NSNull()
}
func loaded(_ profile: Any) -> Any {
  var raw = base
  raw["capabilityProfile"] = profile
  raw["backgroundTaskWorkVersion"] = 1
  raw["privatePath"] = "/private/unreviewed-model"
  return forward(raw)
}
var output: [String: Any] = ["supported": loaded(supported), "legacy": forward(base)]
var blocked = supported
blocked["state"] = "incompatible"
blocked["rig"] = ["humanoid": false, "head": true, "leftEye": true, "rightEye": true]
blocked["issues"] = [["code": "missing_humanoid", "severity": "blocker"]]
output["blocked"] = loaded(blocked)
var inconsistent = supported
inconsistent["rig"] = ["humanoid": false, "head": true, "leftEye": true, "rightEye": true]
output["inconsistent"] = loaded(inconsistent)
output["unknown"] = loaded(["schemaVersion": 1, "source": "unity", "state": "unknown",
  "rig": [:], "behavior": [:], "render": [:], "issues": []])
var invalid: [String: Any] = [:]
for (label, key, value) in [
  ("boolean schema", "schemaVersion", true as Any),
  ("fraction schema", "schemaVersion", 1.5 as Any),
  ("unsupported schema", "schemaVersion", 2 as Any),
  ("catalog source", "source", "catalog" as Any),
  ("legacy source", "source", "legacy" as Any),
  ("unknown state", "state", "ready" as Any),
  ("null rig", "rig", NSNull() as Any),
  ("array behavior", "behavior", [] as Any),
  ("unknown field", "privatePath", "/private/model" as Any),
  ("oversized field", "privatePath", String(repeating: "字", count: 8192) as Any),
  ("missing issues", "issues", NSNull() as Any)
] {
  var profile = supported; profile[key] = value; invalid[label] = loaded(profile)
}
for (label, field, value) in [
  ("numeric boolean", "rig", ["humanoid": 1] as Any),
  ("string boolean", "behavior", ["lookAt": "true"] as Any),
  ("unknown rig key", "rig", ["humanoid": true, "bonePath": "private"] as Any),
  ("boolean count", "render", ["rendererCount": true] as Any),
  ("negative count", "render", ["vertexCount": -1] as Any),
  ("fraction count", "render", ["triangleCount": 1.5] as Any),
  ("overflow count", "render", ["rendererCount": 4097] as Any),
  ("overflow bytes", "render", ["estimatedTextureBytes": 2147483649] as Any),
  ("unknown issue", "issues", [["code": "raw_stack", "severity": "warning"]] as Any),
  ("wrong severity", "issues", [["code": "missing_head", "severity": "warning"]] as Any),
  ("extra issue key", "issues", [["code": "missing_blink", "severity": "warning", "path": "private"]] as Any),
  ("duplicate issue", "issues", Array(repeating: ["code": "missing_blink", "severity": "warning"], count: 2) as Any),
  ("too many issues", "issues", Array(repeating: ["code": "missing_blink", "severity": "warning"], count: 17) as Any)
] {
  var profile = supported; profile[field] = value; invalid[label] = loaded(profile)
}
invalid["null profile"] = loaded(NSNull())
invalid["string profile"] = loaded("not-profile")
output["invalidProfiles"] = invalid
var invalidVersions: [String: Any] = [:]
for (label, value) in [
  ("boolean", true as Any), ("string", "1" as Any), ("negative", -1 as Any),
  ("fraction", 1.5 as Any), ("overflow", 2147483648 as Any), ("null", NSNull() as Any)
] {
  var raw = base; raw["backgroundTaskWorkVersion"] = value
  invalidVersions[label] = forward(raw)
}
output["invalidVersions"] = invalidVersions
var future = base; future["backgroundTaskWorkVersion"] = 2
output["futureVersion"] = forward(future)
output["invalidJSON"] = publicUnityCommandResultPayload(Notification(
  name: Notification.Name("test"), userInfo: ["payload": "{\"ok\":NaN}"])) ?? NSNull()
let encoded = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(data: encoded, encoding: .utf8)!)
''';
