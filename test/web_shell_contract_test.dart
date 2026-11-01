import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web shell declares responsive desktop-friendly metadata', () {
    final index = File('web/index.html').readAsStringSync();
    final manifest =
        jsonDecode(File('web/manifest.json').readAsStringSync())
            as Map<String, dynamic>;

    expect(index, contains('name="viewport"'));
    expect(index, contains('width=device-width'));
    expect(index, contains('viewport-fit=cover'));
    expect(index, contains('<title>Maaso</title>'));
    expect(manifest['display'], 'standalone');
    expect(manifest.containsKey('orientation'), isFalse);
    expect(manifest['description'], contains('AI companion'));
  });

  test('web shell installs the bounded Unity avatar host before Flutter', () {
    final index = File('web/index.html').readAsStringSync();
    final host = File('web/maaso_unity_avatar.js').readAsStringSync();
    final syncScript = File(
      'tool/unity/update_web_unity_avatar.sh',
    ).readAsStringSync();
    final ignore = File('.gitignore').readAsStringSync();

    final hostScript = index.indexOf('src="maaso_unity_avatar.js"');
    final flutterBootstrap = index.indexOf('src="flutter_bootstrap.js"');
    expect(hostScript, greaterThanOrEqualTo(0));
    expect(flutterBootstrap, greaterThan(hostScript));

    expect(host, contains('global.maasoUnityAvatarHost = Object.freeze'));
    for (final api in <String>[
      'subscribe: subscribe',
      'unsubscribe: unsubscribe',
      'mount: mount',
      'detach: detach',
      'retry: retry',
      'invoke: invoke',
      'snapshot: snapshot',
      'emitFromUnity: emitFromUnity',
    ]) {
      expect(host, contains(api));
    }
    expect(host, contains('new global.URL(MANIFEST_RELATIVE_URL, baseUrl)'));
    expect(host, contains("var MAX_ARGUMENT_BYTES = 32 * 1024"));
    expect(host, contains("var MAX_QUEUE_ENTRIES = 128"));
    expect(host, contains("var UNITY_GAME_OBJECT = 'Main Camera'"));
    expect(host, contains("var UNITY_RECEIVER = 'OnFlutterCommand'"));
    expect(host, contains("'maaso-unity-avatar-ready'"));
    expect(host, contains("'maaso-unity-avatar-command-result'"));
    expect(host, isNot(contains("'maaso-unity-avatar-world-event'")));
    expect(host, isNot(contains('worldEvent: true')));
    expect(host, contains("canvasElement.style.pointerEvents = 'none'"));
    expect(host, contains("'webglcontextlost'"));
    expect(host, contains("'not_ready'"));

    final allowedStart = host.indexOf('var ALLOWED_METHODS = Object.freeze({');
    final allowedBlock = host.substring(
      allowedStart,
      host.indexOf('});', allowedStart),
    );
    final allowedMethods =
        RegExp(
          r"^\s*(?:'([^']+)'|([A-Za-z][A-Za-z0-9]*)): true,$",
          multiLine: true,
        ).allMatches(allowedBlock).map((match) {
          return match.group(1) ?? match.group(2)!;
        }).toSet();
    final runtime = File(
      'lib/src/features/agent/application/avatar/unity_avatar_runtime.dart',
    ).readAsStringSync();
    final delegatedMethods = <String>{
      for (final file in <String>[
        'unity_avatar_doorway_transitions.dart',
        'unity_avatar_phone_interactions.dart',
        'unity_avatar_presence_transitions.dart',
      ])
        ...RegExp(r"invokeMethod<void>\('([^']+)'")
            .allMatches(
              File(
                'lib/src/features/agent/application/avatar/$file',
              ).readAsStringSync(),
            )
            .map((match) => match.group(1)!),
    };
    final arbiter = File(
      'lib/src/features/agent/application/avatar/'
      'unity_avatar_command_dispatch_sink.dart',
    ).readAsStringSync();
    final outboundMethods = <String>{
      ...RegExp(
        r"_invoke\('([^']+)'",
      ).allMatches(runtime).map((match) => match.group(1)!),
      ...RegExp(
        r"_agentSpaceCommand\(\s*'([^']+)'",
      ).allMatches(runtime).map((match) => match.group(1)!),
      ...RegExp(
        r"invokeMethod<void>\('([^']+)'",
      ).allMatches(runtime).map((match) => match.group(1)!),
      ...RegExp(
        r"method: '(live\.[^']+)'",
      ).allMatches(runtime).map((match) => match.group(1)!),
      ...delegatedMethods,
      ...RegExp(
        r"static const String (?:commandMethod|resetMethod) = '([^']+)'",
      ).allMatches(arbiter).map((match) => match.group(1)!),
    };
    expect(
      outboundMethods.where((method) => method.startsWith('live.')),
      isEmpty,
    );
    // This lifecycle command belongs to the iOS native underlay, not the
    // WebGL command channel. Keep the web allowlist exact, and verify that
    // only an iOS view can acquire the owner which later emits releaseView.
    expect(outboundMethods, contains('releaseView'));
    final nativeView = File(
      'lib/src/core/widgets/unity_avatar_view.dart',
    ).readAsStringSync();
    expect(
      RegExp(
        r'if\s*\(!kIsWeb\s*&&\s*'
        r'defaultTargetPlatform\s*==\s*TargetPlatform\.iOS\s*&&\s*'
        r'!identical\(_nativeViewOwnerRuntime,\s*runtime\)\)\s*\{'
        r'[^}]*runtime\.retainNativeView\(this\);',
      ).hasMatch(nativeView),
      isTrue,
    );
    expect(
      RegExp(r'\.retainNativeView\(').allMatches(nativeView),
      hasLength(1),
    );
    outboundMethods.remove('releaseView');
    expect(allowedMethods, outboundMethods);
    expect(
      allowedMethods,
      containsAll(<String>[
        'enterAgentSpace',
        'leaveAgentSpace',
        'requestAgentSpaceMoveAtScreenPoint',
        'setWorldTimeOfDay',
        'setWorldCamera',
      ]),
    );
    for (final retired in <String>[
      'worldMapCache',
      'prepareWorldMap',
      'cancelWorldMap',
      'switchWorld',
      'worldPrivateRoute',
      'worldPrivateFurniture',
      'joinWorld',
      'applyWorldSnapshot',
      'applyWorldHudSnapshot',
      'showWorldChat',
      'showWorldEffect',
      'playWorldHighlight',
      'leaveWorld',
    ]) {
      expect(allowedMethods, isNot(contains(retired)));
    }
    expect(allowedMethods, isNot(contains('live.captureCover')));
    expect(allowedMethods, isNot(contains('releaseView')));

    expect(syncScript, contains('Builds/WebGL/MaasoAvatar'));
    expect(syncScript, contains('maaso-avatar-manifest.json'));
    expect(syncScript, contains('web/unity/avatar'));
    expect(ignore, contains('/web/unity/avatar/player/'));
    expect(File('web/unity/avatar/README.md').existsSync(), isTrue);
  });
}
