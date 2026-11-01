import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS registers plugins only after the implicit scene engine exists', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final sceneDelegate = File(
      'ios/Runner/SceneDelegate.swift',
    ).readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final launchStart = appDelegate.indexOf('  override func application(');
    final callbackStart = appDelegate.indexOf(
      '  func didInitializeImplicitFlutterEngine(',
    );
    final registrationStart = appDelegate.indexOf(
      '  private func registerGeneratedPluginsIfNeeded(',
    );

    expect(
      sceneDelegate,
      contains('class SceneDelegate: FlutterSceneDelegate'),
    );
    expect(infoPlist, contains(r'$(PRODUCT_MODULE_NAME).SceneDelegate'));
    expect(appDelegate, contains('FlutterImplicitEngineDelegate'));
    expect(launchStart, greaterThanOrEqualTo(0));
    expect(callbackStart, greaterThan(launchStart));
    expect(registrationStart, greaterThan(callbackStart));
    final launch = appDelegate.substring(launchStart, callbackStart);
    expect(launch, contains('return super.application('));
    expect(launch, isNot(contains('registerGeneratedPluginsIfNeeded(')));
    expect(launch, isNot(contains('registerMaasoNativePlugins(')));
    final engineReady = appDelegate.substring(callbackStart, registrationStart);
    expect(
      engineReady,
      contains(
        'registerGeneratedPluginsIfNeeded(with: engineBridge.pluginRegistry)',
      ),
    );
    expect(
      engineReady,
      contains('registerMaasoNativePlugins(with: engineBridge.pluginRegistry)'),
    );
    expect(
      appDelegate,
      isNot(contains('GeneratedPluginRegistrant.register(with: self)')),
    );
    expect(
      appDelegate,
      contains('guard !didRegisterGeneratedPlugins else { return }'),
    );
    expect(
      appDelegate,
      contains('guard !didRegisterMaasoNativePlugins else { return }'),
    );
  });

  test('iOS forwards scene recovery to Unity before resuming Flutter', () {
    final sceneDelegate = File(
      'ios/Runner/SceneDelegate.swift',
    ).readAsStringSync();
    const callbacks = <String, String>{
      'sceneWillResignActive': 'willResignActive',
      'sceneDidEnterBackground': 'didEnterBackground',
      'sceneWillEnterForeground': 'willEnterForeground',
      'sceneDidBecomeActive': 'didBecomeActive',
    };
    for (final entry in callbacks.entries) {
      final start = sceneDelegate.indexOf('override func ${entry.key}(');
      expect(start, greaterThanOrEqualTo(0), reason: entry.key);
      final nextCallback = sceneDelegate.indexOf('override func ', start + 1);
      final body = sceneDelegate.substring(
        start,
        nextCallback < 0 ? sceneDelegate.length : nextCallback,
      );
      final unity = body.indexOf(
        'UnityAvatarRuntimeBridge.handleSceneLifecycle(.${entry.value}',
      );
      final flutter = body.indexOf('super.${entry.key}(scene)');
      expect(unity, greaterThanOrEqualTo(0), reason: entry.key);
      expect(flutter, greaterThan(unity), reason: entry.key);
      expect('super.${entry.key}(scene)'.allMatches(body), hasLength(1));
    }
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('UnityAvatarLifecycle.swift in Sources'));
  });

  test(
    'iOS records scene transitions before an optional Unity sink exists',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final start = source.indexOf('static func handleSceneLifecycle(');
      final end = source.indexOf('static func synchronizePlayer(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      // Optional chaining skips argument evaluation when the sink is nil.
      // Persist the scene phase outside that call so late startup can catch up.
      final record = body.indexOf('let events = lifecycle.receive(event)');
      final dispatch = body.indexOf('commandSink?.applySceneLifecycle(events)');
      expect(record, greaterThanOrEqualTo(0));
      expect(dispatch, greaterThan(record));
      expect(body.substring(0, record), isNot(contains('return')));
    },
  );

  test(
    'iOS compatibility pause messages cannot become a second engine owner',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final handler = source.indexOf(
        'private func handle(call: FlutterMethodCall',
      );
      expect(handler, greaterThanOrEqualTo(0));
      for (final method in ['pause', 'resume']) {
        final start = source.indexOf('case "$method":', handler);
        expect(start, greaterThan(handler));
        final nextCase = source.indexOf('\n    case ', start + 1);
        final nextDefault = source.indexOf('\n    default:', start + 1);
        final end = nextCase < 0 || nextDefault < nextCase
            ? nextDefault
            : nextCase;
        expect(end, greaterThan(start));
        final body = source.substring(start, end);
        expect(body, contains('result(nil)'));
        expect(body, isNot(contains('completeCommand(')));
        expect(body, isNot(contains('commandSink.send(')));
        expect(body, isNot(contains('unityFramework.pause(')));
      }
    },
  );

  test('Unity gaze uses the same owned late pose on mobile and desktop', () {
    final receiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();

    final lateStart = receiver.indexOf('private void LateUpdate()');
    final lateEnd = receiver.indexOf(
      'public void OnFlutterCommand(',
      lateStart,
    );
    final gazeStart = receiver.indexOf(
      'private void ApplyGaze(GazeCommand gaze)',
    );
    final gazeEnd = receiver.indexOf('private void ApplyGazePose()', gazeStart);
    expect(lateStart, greaterThanOrEqualTo(0));
    expect(lateEnd, greaterThan(lateStart));
    expect(gazeStart, greaterThanOrEqualTo(0));
    expect(gazeEnd, greaterThan(gazeStart));
    final late = receiver.substring(lateStart, lateEnd);
    final commands = receiver.substring(gazeStart, gazeEnd);
    expect(late, isNot(contains('#if')));
    expect(commands, isNot(contains('#if')));
    expect(late, contains('ApplyGazePose();'));
    expect(late, contains('RestoreOwnedGazePose();'));
    expect(
      commands,
      contains('gazeTarget = (gaze ?? GazeCommand.Center).Clamped();'),
    );
    expect(commands, contains('ClearGaze(immediate: true);'));
    expect(receiver, isNot(contains('StabilizeEyeBones')));
    expect(receiver, contains('[DefaultExecutionOrder(10000)]'));
  });

  test(
    'iOS prepares Unity as a Flutter underlay instead of a platform view',
    () {
      final appDelegate = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();

      expect(appDelegate, contains('UnityAvatarPlugin'));
      expect(appDelegate, contains('"maaso/unity_avatar"'));
      expect(
        appDelegate,
        contains(
          'registerGeneratedPluginsIfNeeded(with: engineBridge.pluginRegistry)',
        ),
      );
      expect(
        appDelegate,
        contains(
          'registerMaasoNativePlugins(with: engineBridge.pluginRegistry)',
        ),
      );
      expect(
        appDelegate,
        contains('private var didRegisterMaasoNativePlugins = false'),
      );
      expect(
        appDelegate,
        contains('resolvedCommandSink.onSceneReady = { [weak channel] in'),
      );
      expect(
        appDelegate,
        contains('flutterView.backgroundColor = UIColor.clear'),
      );
      expect(
        appDelegate,
        contains('flutterViewController.isViewOpaque = false'),
      );
      expect(
        appDelegate,
        contains('insertSubview(container, belowSubview: flutterView)'),
      );
      expect(appDelegate, contains('MaasoUnityPassthroughView'));
      expect(appDelegate, contains('maasoUnityBackdropColor'));
      expect(appDelegate, contains('installUnityBackdrop(in: superview'));
      expect(appDelegate, contains('commandSink.attachToFlutterHost()'));
      expect(
        appDelegate,
        isNot(contains('commandSink.attachToPlatformView(rootView)')),
      );
      expect(appDelegate, isNot(contains('FlutterPlatformViewFactory')));
      expect(appDelegate, isNot(contains('FlutterPlatformView')));
      expect(
        appDelegate,
        isNot(
          contains(
            'commandSink.attachToPlatformView(rootView)\n'
            '    commandSink.markUnitySceneReady()',
          ),
        ),
      );
      expect(appDelegate, contains('invokeMethod("ready"'));
      expect(appDelegate, isNot(contains('maasoUnityAvatarWorldEvent')));
      expect(appDelegate, isNot(contains('invokeMethod("worldEvent"')));
      for (final method in _unityMethods) {
        expect(appDelegate, contains('"$method"'), reason: method);
      }
    },
  );

  test('Android hosts Unity as a Flutter underlay, not a platform view', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();
    final unityView = File(
      'lib/src/core/widgets/unity_avatar_view.dart',
    ).readAsStringSync();

    expect(activity, contains('UnityAvatarBridge'));
    expect(activity, contains('"maaso/unity_avatar"'));
    expect(activity, contains('override fun getRenderMode(): RenderMode'));
    expect(
      activity,
      contains('override fun getTransparencyMode(): TransparencyMode'),
    );
    expect(activity, contains('attachToFlutterUnderlay()'));
    expect(activity, contains('android.R.id.content'));
    expect(activity, contains('content.addView('));
    expect(activity, contains('container,\n                0,'));
    expect(activity, contains('bringToFront()'));
    expect(activity, contains('setBackgroundColor(Color.TRANSPARENT)'));
    expect(activity, contains('isClickable = false'));
    expect(activity, contains('isFocusable = false'));
    expect(activity, contains('channel.invokeMethod("ready", null)'));
    expect(
      activity,
      isNot(contains('fun emitUnityWorldEvent(payload: String)')),
    );
    expect(
      activity,
      isNot(contains('channel.invokeMethod("worldEvent", event)')),
    );
    expect(manifest, contains('android:windowSoftInputMode="adjustPan"'));
    expect(
      manifest,
      isNot(contains('android:windowSoftInputMode="adjustResize"')),
    );
    expect(manifest, contains('com.unity3d.player.UnityPlayerGameActivity'));
    expect(manifest, contains('tools:node="remove"'));
    expect(activity, isNot(contains('registerViewFactory')));
    expect(activity, isNot(contains('PlatformViewFactory')));
    expect(activity, isNot(contains('PlatformView')));
    expect(unityView, isNot(contains('AndroidView(')));
    expect(unityView, isNot(contains('PlatformViewHitTestBehavior')));
    expect(
      unityView,
      contains(
        'case TargetPlatform.android:\n'
        '        return const SizedBox.expand();',
      ),
    );
    for (final method in _unityMethods) {
      expect(activity, contains('"$method"'), reason: method);
    }
  });

  test('desktop bridges admit every shared Unity avatar command', () {
    for (final (path, pattern) in <(String, String)>[
      (
        'macos/Runner/MacOSUnityAvatarPortal.swift',
        r'avatarMethods:\s*Set<String>\s*=\s*\[([^\]]*)\]',
      ),
      (
        'windows/runner/unity_player_host.cpp',
        r'kAvatarMethods\s*=\s*\{([^}]*)\}',
      ),
    ]) {
      final source = File(path).readAsStringSync();
      final declaration = RegExp(pattern).firstMatch(source);
      expect(declaration, isNotNull, reason: '$path command whitelist');
      final methods = RegExp(r'"([^\"]+)"')
          .allMatches(declaration!.group(1)!)
          .map((match) => match.group(1)!)
          .toSet();
      for (final method in _unityMethods) {
        expect(methods, contains(method), reason: '$path: $method');
      }
    }
  });

  test(
    'Windows mirrors viseme timelines to the pet without replay caching',
    () {
      final source = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final transient = RegExp(
        r'kPetTransientAvatarMethods\s*=\s*\{([^}]*)\}',
      ).firstMatch(source);
      final baseline = RegExp(
        r'kPetBaselineAvatarMethods\s*=\s*\{([^}]*)\}',
      ).firstMatch(source);

      expect(transient, isNotNull);
      expect(baseline, isNotNull);
      expect(transient!.group(1), contains('"startVisemeTimeline"'));
      expect(baseline!.group(1), isNot(contains('"startVisemeTimeline"')));
      expect(source, contains('kPetTransientAvatarMethods.find(method)'));
      expect(source, contains('ShouldMirrorAvatarCommandToPet'));
    },
  );

  test(
    'Android starts the Unity 6 player before reporting the avatar view ready',
    () {
      final activity = File(
        'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
      ).readAsStringSync();
      final receiver = File(
        'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
        'UnityAvatarCommandReceiver.cs',
      ).readAsStringSync();

      expect(activity, contains('UnityPlayerForActivityOrService'));
      expect(activity, contains('isNativeInitialized'));
      expect(activity, contains('pendingCommands'));
      expect(activity, contains('flushPendingCommands'));
      expect(activity, contains('notifyReady'));
      expect(activity, contains('fun emitUnityAvatarReady()'));
      expect(activity, contains('unityAvatarBridge?.emitReady()'));
      expect(activity, contains('fun emitReady()'));
      expect(receiver, contains('#elif UNITY_ANDROID && !UNITY_EDITOR'));
      expect(receiver, contains('activity?.Call("emitUnityAvatarReady")'));
      expect(activity, contains('private var activityStarted = false'));
      expect(activity, contains('private var activityResumed = false'));
      expect(activity, contains('private var activityWindowFocused = false'));
      expect(activity, contains('replayUnityLifecycleAfterAttach()'));
      expect(activity, contains('if (activityStarted)'));
      expect(activity, contains('if (activityResumed)'));
      expect(activity, contains('onUnityStart()'));
      expect(activity, contains('onUnityStop()'));
      expect(activity, contains('onUnityPause()'));
      expect(activity, contains('onUnityResume()'));
      expect(activity, contains('onUnityDestroy()'));
      expect(
        activity,
        contains(
          'override fun attach(container: FrameLayout, onReady: () -> Unit): Boolean',
        ),
      );
      expect(activity, contains('if (commandSink.attach(container) {'));
      expect(
        activity,
        isNot(contains('channel.invokeMethod("ready", null)\n        }')),
      );
      expect(
        activity,
        isNot(contains('getConstructor(Context::class.java).newInstance')),
      );
      expect(
        activity,
        isNot(contains('getConstructor(Activity::class.java).newInstance')),
      );
    },
  );

  test('native Unity commands target the VRM1 companion scene camera', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();
    final scene = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scenes/Companion.unity',
    ).readAsStringSync();

    expect(scene, contains('m_Name: Main Camera'));
    expect(appDelegate, contains('gameObjectName = "Main Camera"'));
    expect(activity, contains('"Main Camera"'));
    expect(appDelegate, isNot(contains('gameObjectName = "MaasoWorld"')));
    expect(activity, isNot(contains('"MaasoWorld"')));
  });

  test('ticketed Avatar protocol waits for Unity post-mutation receipts', () {
    final receiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();
    final runtime = File(
      'lib/src/features/agent/application/avatar/unity_avatar_runtime.dart',
    ).readAsStringSync();
    final sink = File(
      'lib/src/features/agent/application/avatar/'
      'unity_avatar_command_dispatch_sink.dart',
    ).readAsStringSync();

    expect(receiver, contains('method == "avatarArbiterCommand"'));
    expect(receiver, contains('method == "avatarArbiterReset"'));
    expect(receiver, contains('DispatchAvatarArbiterCommand(json)'));
    expect(receiver, contains('DispatchAvatarArbiterReset(json)'));
    expect(
      receiver,
      contains('command.deadlineEpochMs < UtcEpochMilliseconds()'),
    );
    expect(receiver, contains('avatarArbiterTicketHighWater'));
    expect(receiver, contains('FixedTokenEquals(avatarArbiterOwnerToken'));
    expect(receiver, contains('Sha256Hex(command.payloadJson)'));
    expect(receiver, contains('AvatarArbiterCommandFields'));
    expect(receiver, contains('AvatarArbiterExpressionFields'));
    expect(receiver, contains('HasExactJsonObjectFields('));
    expect(receiver, contains('fields.ContainsKey(key)'));
    expect(receiver, contains('IsJsonNumberArray('));
    expect(
      receiver,
      contains('ApplyAvatarArbiterMutation(command, rendererPayload)'),
    );
    expect(
      receiver,
      contains('NotifyAvatarArbiterCommandResult(command, true'),
    );
    expect(receiver, contains('ResetAvatarArbiterState()'));
    expect(receiver, contains('framing.SetFramingMode("hero_full_body")'));
    expect(receiver, contains('expression.mouthOpen != 0f'));
    expect(
      runtime,
      contains('_commandDispatchSink.handleCommandResult(result)'),
    );
    expect(runtime, contains('_commandDispatchSink.markRendererUnavailable()'));
    expect(runtime, contains('_commandDispatchSink.close()'));
    expect(sink, contains('operation.issueRendererMutationPermit()'));
    expect(sink, contains('operation.acceptRendererReceipt(permit)'));
    expect(sink, isNot(contains("invokeMethod<void>('setExpression'")));
  });

  test('native bridges validate the ticketed protocol or fail closed', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final android = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();
    final macos = File(
      'macos/Runner/MacOSUnityAvatarPortal.swift',
    ).readAsStringSync();
    final windows = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    for (final source in <String>[ios, android, macos]) {
      expect(source, contains('avatarArbiterCommand'));
      expect(source, contains('avatarArbiterReset'));
      expect(source, contains('payloadSha256'));
      expect(source, contains('deadlineEpochMs'));
      expect(source, contains('commitToken'));
      expect(source, contains('clearsChannel'));
      expect(source, contains('invalid_unity_avatar_arbiter_command'));
      expect(source, contains('not_ready'));
    }
    expect(windows, contains('avatarArbiterCommand'));
    expect(windows, contains('avatarArbiterReset'));
    expect(windows, contains('avatar_arbiter_multi_renderer_unsupported'));
    expect(
      windows.indexOf('avatar_arbiter_multi_renderer_unsupported'),
      lessThan(
        windows.indexOf('SendAvatarCommand(\n            call.method_name()'),
      ),
    );
  });

  test('iOS waits for the Unity scene receiver before flushing commands', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final iosBridge = File(
      'unity/masso_avatar/Assets/Plugins/iOS/MaasoUnityAvatarBridge.mm',
    ).readAsStringSync();
    final receiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();

    expect(appDelegate, contains('NotificationCenter.default.addObserver'));
    expect(appDelegate, contains('Notification.Name("MaasoUnityAvatarReady")'));
    expect(iosBridge, contains('extern "C" void MaasoUnityAvatarReady'));
    expect(iosBridge, contains('NSNotificationCenter'));
    expect(
      iosBridge,
      contains('postNotificationName:@"MaasoUnityAvatarReady"'),
    );
    expect(receiver, contains('DllImport("__Internal")'));
    expect(receiver, contains('MaasoUnityAvatarReady()'));
    for (final method in const [
      'enterAgentSpace',
      'leaveAgentSpace',
      'requestAgentSpaceMoveAtScreenPoint',
    ]) {
      expect(receiver, contains('case "$method":'));
    }
    expect(receiver, contains('case "loadAvatar":'));
    expect(receiver, contains('private void Start()'));
    expect(iosBridge, isNot(contains('MaasoUnityAvatarWorldEvent')));
    expect(iosBridge, contains('MaasoUnityAvatarCommandResult'));
  });

  test('native bridges expose only structured avatar load results', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();

    for (final source in [appDelegate, activity]) {
      expect(source, contains('"loadAvatar"'));
      expect(source, contains('"requestId"'));
      expect(source, contains('"cacheHit"'));
      expect(source, contains('"assetSha256"'));
      expect(source, isNot(contains('result["modelUrl"]')));
    }
  });

  test(
    'native bridges use closed local space commands and session receipts',
    () {
      for (final path in const [
        'ios/Runner/AppDelegate.swift',
        'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
        'macos/Runner/MacOSUnityAvatarPortal.swift',
      ]) {
        final source = File(path).readAsStringSync();
        for (final method in const [
          'enterAgentSpace',
          'leaveAgentSpace',
          'requestAgentSpaceMoveAtScreenPoint',
        ]) {
          expect(source, contains('"$method"'), reason: '$path $method');
        }
        for (final field in const [
          'requestId',
          'sessionId',
          'method',
          'ok',
          'code',
        ]) {
          expect(source, contains('"$field"'), reason: '$path $field');
        }
        expect(source, isNot(contains('"prepareWorldMap"')));
        expect(source, isNot(contains('"joinWorld"')));
      }
    },
  );

  test('Unity scene receiver routes world time to real lighting', () {
    final receiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();
    final lighting = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityWorldLightingController.cs',
    ).readAsStringSync();

    expect(receiver, contains('case "setWorldTimeOfDay":'));
    expect(receiver, contains('SetWorldTimeOfDay('));
    expect(receiver, contains('UnityWorldLightingController worldLighting'));
    expect(lighting, contains('public void SetTimeOfDay(string timeOfDay)'));
    expect(lighting, contains('private Camera backgroundCamera'));
    expect(lighting, contains('private Light directionalLight'));
  });

  test(
    'Android Gradle links exported masso_avatar Unity Library when it exists',
    () {
      final settings = File('android/settings.gradle.kts').readAsStringSync();
      final appBuild = File('android/app/build.gradle.kts').readAsStringSync();
      final rootBuild = File('android/build.gradle.kts').readAsStringSync();

      expect(
        settings,
        contains('unity/masso_avatar/Builds/Android/unityLibrary'),
      );
      expect(settings, contains('include(":unityLibrary")'));
      expect(settings, contains('project(":unityLibrary").projectDir'));
      expect(
        rootBuild,
        contains('unity/masso_avatar/Builds/Android/unityLibrary'),
      );
      expect(rootBuild, contains('resolve("libs")'));
      expect(rootBuild, contains('flatDir'));
      expect(appBuild, contains('minSdk = maxOf(flutter.minSdkVersion, 26)'));
      expect(appBuild, contains('useLegacyPackaging = true'));
      expect(
        appBuild,
        contains('unity/masso_avatar/Builds/Android/unityLibrary/build.gradle'),
      );
      expect(appBuild, contains('implementation(project(":unityLibrary"))'));
    },
  );

  test('iOS linker points at exported masso_avatar UnityFramework', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final script = File(
      'tool/unity/link_ios_unity_library.rb',
    ).readAsStringSync();

    expect(script, contains('Unity-iPhone.xcodeproj'));
    expect(script, contains('UnityFramework.framework'));
    expect(script, contains('../unity/masso_avatar/Builds/iOS'));
    expect(script, contains('ensure_unity_framework_data_resource'));
    expect(script, contains('Embed Unity Frameworks'));
    expect(script, contains('frameworks_build_phase.add_file_reference'));
    expect(appDelegate, contains('canImport(UnityFramework)'));
    expect(appDelegate, contains('runEmbedded'));
    expect(appDelegate, contains('appController()?.rootView'));
    expect(appDelegate, contains('setDataBundleId("com.unity3d.framework")'));
  });

  test(
    'iOS Unity export completes reviewed avatar load commands when present',
    () {
      final codegen = File(
        'unity/masso_avatar/Builds/iOS/Il2CppOutputProject/Source/'
        'il2cppOutput/Assembly-CSharp_CodeGen.c',
      );
      if (!codegen.existsSync()) return;

      final contents = codegen.readAsStringSync();
      expect(
        contents,
        contains('UnityAvatarCommandReceiver_FinishAvatarLoad'),
        reason:
            'The embedded Unity export is stale: the model can change on '
            'screen while Flutter waits forever for its load result.',
      );
    },
  );

  test(
    'Android Unity export completes reviewed avatar load commands when present',
    () {
      final codegen = File(
        'unity/masso_avatar/Builds/Android/unityLibrary/src/main/'
        'Il2CppOutputProject/Source/il2cppOutput/Assembly-CSharp_CodeGen.c',
      );
      if (!codegen.existsSync()) return;

      final contents = codegen.readAsStringSync();
      expect(
        contents,
        contains('UnityAvatarCommandReceiver_FinishAvatarLoad'),
        reason:
            'The embedded Unity export is stale: the model can change on '
            'screen while Flutter waits forever for its load result.',
      );
    },
  );

  test('iOS Runner project UnityFramework link state matches export state', () {
    final exportProject = Directory(
      'unity/masso_avatar/Builds/iOS/Unity-iPhone.xcodeproj',
    ).existsSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    int count(String needle) =>
        RegExp(RegExp.escape(needle)).allMatches(project).length;

    if (exportProject) {
      expect(project, contains('UnityFramework.framework in Frameworks'));
      expect(
        project,
        contains('UnityFramework.framework in Embed Unity Frameworks'),
      );
      expect(project, contains('Embed Unity Frameworks'));
      expect(count('/* UnityFramework.framework in Frameworks */ ='), 1);
      expect(
        count('/* UnityFramework.framework in Embed Unity Frameworks */ ='),
        1,
      );
      expect(count('/* UnityFramework.framework */ = {'), 1);
      expect(count('remoteInfo = UnityFramework;'), 2);
    } else {
      expect(
        project,
        isNot(contains('UnityFramework.framework in Frameworks')),
      );
      expect(
        project,
        isNot(contains('UnityFramework.framework in Embed Unity Frameworks')),
      );
      expect(project, isNot(contains('Embed Unity Frameworks')));
      expect(count('remoteInfo = UnityFramework;'), 0);
    }
  });

  test('native Unity view does not consume Flutter HUD touches', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();

    expect(
      appDelegate,
      contains('unityRootView.isUserInteractionEnabled = false'),
    );
    expect(
      appDelegate,
      contains('private final class MaasoUnityPassthroughView'),
    );
    expect(appDelegate, contains('point(inside point: CGPoint'));
    expect(appDelegate, contains('return false'));
    expect(appDelegate, contains('private func disableInteractionRecursively'));
    expect(
      appDelegate,
      contains('disableInteractionRecursively(unityRootView)'),
    );
    expect(appDelegate, contains('attachUnityRootViewAsFlutterUnderlay'));
    expect(
      appDelegate,
      contains('insertSubview(container, belowSubview: flutterView)'),
    );
    expect(appDelegate, contains('unityContainerView'));
    expect(appDelegate, contains('container.isUserInteractionEnabled = false'));
    expect(appDelegate, contains('flutterView.layer.zPosition = 0'));
    expect(
      appDelegate,
      contains('private func configureUnityWindowForFlutterUnderlay'),
    );
    expect(appDelegate, contains('unityFramework?.appController()?.window'));
    expect(
      appDelegate,
      contains('unityWindow.isUserInteractionEnabled = false'),
    );
    expect(appDelegate, contains('unityWindow.isHidden = true'));
    expect(appDelegate, contains('flutterWindow?.makeKeyAndVisible()'));
    expect(activity, contains('isClickable = false'));
    expect(activity, contains('isFocusable = false'));
    expect(activity, contains('PassthroughUnityAvatarContainer'));
    expect(activity, contains('dispatchTouchEvent(event: MotionEvent)'));
    expect(activity, isNot(contains('view.requestFocus()')));
    expect(activity, contains('bringToFront()'));
  });

  test('iOS Unity underlay uses a milk-white backdrop below Unity', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(appDelegate, contains('maasoUnityBackdropColor'));
    expect(appDelegate, contains('red: 1.0'));
    expect(appDelegate, contains('green: 251.0 / 255.0'));
    expect(appDelegate, contains('blue: 242.0 / 255.0'));
    expect(appDelegate, contains('maasoUnityBackdropViewTag'));
    expect(appDelegate, contains('superview.window?.backgroundColor'));
    expect(
      appDelegate,
      contains(
        'superview.insertSubview(backdropView, belowSubview: flutterView)',
      ),
    );
    expect(
      appDelegate,
      contains('superview.insertSubview(container, belowSubview: flutterView)'),
    );
    expect(appDelegate, contains('backdropView.layer.zPosition = -2'));
    expect(appDelegate, contains('container.layer.zPosition = -1'));
  });

  test('iOS Unity underlay makes the Flutter renderer transparent', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(appDelegate, contains('configureFlutterHostForUnityUnderlay()'));
    expect(
      appDelegate,
      contains('hostViewController as? FlutterViewController'),
    );
    expect(appDelegate, contains('flutterViewController.isViewOpaque = false'));
    expect(appDelegate, contains('flutterView.isOpaque = false'));
    expect(
      appDelegate,
      contains('flutterView.backgroundColor = UIColor.clear'),
    );
  });
}

const _unityMethods = [
  'prepareView',
  'loadAvatar',
  'setExpression',
  'setMouthOpen',
  'setGaze',
  'clearGaze',
  'startLipSync',
  'startVisemeTimeline',
  'stopLipSync',
  'playPrimitive',
  'playAnimationClip',
  'reactToScreenTap',
  'enterAgentSpace',
  'leaveAgentSpace',
  'requestAgentSpaceMoveAtScreenPoint',
  'setHandIkTarget',
  'setBodyPose',
  'playMotion',
  'playMotionSequence',
  'setFraming',
  'setViewportSafeArea',
  'pause',
  'resume',
];
