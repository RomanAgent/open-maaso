import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  testWidgets(
    'independent Windows companion receives the shared streaming bubble',
    (tester) async {
      final windowGateway = _IndependentWindowGateway();
      final controller = DesktopWindowModeController(gateway: windowGateway);
      final host = _CompanionHostGateway();
      final presentation = AgentReplyPresentationService(
        minimumFallbackTtl: const Duration(seconds: 1),
        maximumFallbackTtl: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);
      addTearDown(host.dispose);
      addTearDown(presentation.closeLifecycle);

      await controller.enterPetMode();
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopCompanionShell(
            windowController: controller,
            autoEnterPetMode: false,
            hostGateway: host,
            replyPresentation: presentation,
            child: const ColoredBox(
              key: ValueKey<String>('windows-full-app'),
              color: Colors.white,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(host.calls, contains('show'));
      expect(
        find.byKey(const ValueKey<String>('windows-full-app')),
        findsOneWidget,
      );

      EventBus().fire(
        AgentReplyStartedEvent(
          turnId: 'windows-turn',
          origin: 'user',
          agentId: 'self',
        ),
      );
      EventBus().fire(
        AgentReplyDeltaEvent(
          'Windows ',
          turnId: 'windows-turn',
          agentId: 'self',
        ),
      );
      await tester.pump(const Duration(milliseconds: 45));
      expect(presentation.snapshot.text, 'Windows ');
      expect(host.calls, contains('bubble:Windows'));

      EventBus().fire(
        AgentReplyDeltaEvent('reply', turnId: 'windows-turn', agentId: 'self'),
      );
      await tester.pump(const Duration(milliseconds: 45));
      expect(host.calls, contains('bubble:Windows reply'));

      presentation.clear();
      await tester.pump(const Duration(milliseconds: 60));
      expect(host.calls.last, 'clearBubble');
    },
  );

  test('Windows runner owns a separate interactive desktop-pet HWND', () {
    final host = File(
      'windows/runner/windows_desktop_companion_host.cpp',
    ).readAsStringSync();
    final hostHeader = File(
      'windows/runner/windows_desktop_companion_host.h',
    ).readAsStringSync();
    final window = File('windows/runner/flutter_window.cpp').readAsStringSync();
    final windowHeader = File(
      'windows/runner/flutter_window.h',
    ).readAsStringSync();
    final unity = File(
      'windows/runner/unity_player_host.cpp',
    ).readAsStringSync();
    final unityHeader = File(
      'windows/runner/unity_player_host.h',
    ).readAsStringSync();
    final presentation = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'WindowsDesktopPetPresentationController.cs',
    ).readAsStringSync();
    final framePublisher = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'WindowsDesktopPetFramePublisher.cs',
    ).readAsStringSync();
    final avatarBridge = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'WindowsUnityAvatarMessageBridge.cs',
    ).readAsStringSync();
    final receiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/'
      'UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();

    expect(host, contains('maaso/desktop_companion'));
    expect(host, contains('WS_EX_TOOLWINDOW'));
    expect(host, contains('WS_EX_NOACTIVATE'));
    expect(host, contains('WS_EX_TOPMOST'));
    expect(host, contains('WS_EX_LAYERED'));
    expect(host, contains('return HTTRANSPARENT;'));
    expect(host, contains('TrackPopupMenuEx'));
    expect(host, contains('TPM_RETURNCMD'));
    expect(host, contains('SetCapture'));
    expect(host, contains('WM_MOUSEMOVE'));
    expect(host, contains('GetCursorPos'));
    expect(host, contains('(cursor.x - head_x) / Scale(220)'));
    expect(host, isNot(contains('(head_x - cursor.x) / Scale(220)')));
    expect(host, contains('DrawTextW'));
    expect(host, contains('kBubbleWindowClass'));
    expect(host, contains('LWA_ALPHA'));
    expect(host, contains('CreateDIBSection'));
    expect(host, contains('UpdateLayeredWindowIndirect'));
    expect(host, contains('ULW_ALPHA'));
    expect(host, contains('AC_SRC_ALPHA'));
    expect(host, contains('PresentLatestDesktopPetFrame'));
    expect(host, isNot(contains('SetLayeredWindowAttributes(pet_window_')));
    expect(host, contains('GetTickCount64'));
    expect(host, contains('IsAvatarReady'));
    expect(host, contains('hostUnavailable'));
    expect(host, contains('pet_started_callback_(error_message)'));
    expect(host, contains('state_replayed'));
    expect(
      host,
      contains('pet_unity_player_host_->DiscardPendingAvatarCommands()'),
    );
    expect(hostHeader, contains('PetStartedCallback'));
    expect(hostHeader, contains('pet_started_callback_'));
    expect(hostHeader, contains('kAvatarStartupTimeoutMilliseconds = 15000'));
    expect(hostHeader, contains('avatar_startup_deadline_'));
    expect(window, contains('WindowsDesktopCompanionHost'));
    expect(window, contains('maaso/unity_avatar'));
    expect(windowHeader, contains('pet_unity_player_host_'));
    expect(
      RegExp(r'std::make_unique<UnityPlayerHost>').allMatches(window).length,
      2,
    );
    expect(window, contains('pet_unity_player_host_->SendAvatarCommand'));
    expect(window, contains('pet_unity_player_host_->HandleAvatarCopyData'));
    expect(window, contains('Only the app-owned player is authoritative'));
    expect(window, contains('pet_callback_type == "commandResult"'));
    expect(window, contains('!main_running'));
    expect(window, contains('kPetBaselineAvatarMethods'));
    expect(window, contains('kPetTransientAvatarMethods'));
    expect(window, contains('PetBaselineAvatarCommandCache'));
    expect(window, contains('ShouldMirrorAvatarCommandToPet'));
    expect(
      window,
      contains('for (const char* method : kPetBaselineAvatarMethods)'),
    );
    expect(window, contains('cached = *call.arguments()'));
    expect(window, isNot(contains('"live.captureCover"')));
    expect(window, isNot(contains('"setWorldScene"')));
    expect(
      RegExp(
        r'desktop_companion_host_->IsVisible\(\)',
      ).allMatches(window).length,
      2,
    );
    expect(unity, contains('SetParentWindow'));
    expect(unity, contains('SendAvatarCommand'));
    expect(unity, contains('pending_avatar_commands_.clear()'));
    expect(unityHeader, contains('DiscardPendingAvatarCommands'));
    expect(unity, contains('WM_COPYDATA'));
    expect(unity, contains('BCryptGenRandom'));
    expect(unity, contains('WM_MOUSEMOVE'));
    expect(unity, contains('-maasoDesktopPet'));
    expect(unity, contains('CopyLatestDesktopPetFrame'));
    expect(unity, contains('OpenFileMappingW(FILE_MAP_READ'));
    expect(unity, contains('MapViewOfFile'));
    expect(unity, contains('kDesktopPetFrameMagic = 0x4653414D'));
    expect(unity, contains('sequence_begin_again'));
    expect(unity, isNot(contains('RGB(255, 0, 255)')));
    expect(unity, isNot(contains('LWA_COLORKEY')));
    expect(unityHeader, contains('CopyLatestDesktopPetFrame'));
    expect(presentation, contains('UNITY_STANDALONE_WIN'));
    expect(presentation, contains('CameraClearFlags.SolidColor'));
    expect(presentation, contains('TransparentBackground = Color.clear'));
    expect(presentation, contains('1 << DesktopPetLayer'));
    expect(presentation, contains('captureIntervalSeconds = 1.0 / 30.0'));
    expect(presentation, contains('CaptureResourceRetrySeconds = 0.75'));
    expect(
      presentation,
      contains('CrispCaptureSsaaScales =\n            { 4f, 3f, 2f, 1f }'),
    );
    expect(presentation, contains('CrispCaptureMsaaSamples = { 4, 2, 1 }'));
    expect(presentation, contains('foreach (float requestedScale'));
    expect(presentation, contains('foreach (int requestedSamples'));
    expect(presentation, contains('new HashSet<long>()'));
    expect(presentation, contains('attemptedInternalSizes.Add'));
    expect(
      presentation,
      contains('nextCaptureTime = now + CaptureResourceRetrySeconds'),
    );
    expect(presentation, contains('FindObjectsInactive.Exclude'));
    expect(presentation, contains('FindObjectsSortMode.None'));
    expect(presentation, isNot(contains('FindObjectsByType<Canvas>()')));
    expect(presentation, contains('ResolveAntiAliasedSurface'));
    expect(presentation, contains('RequestAsyncReadback'));
    expect(presentation, contains('TextureFormat.BGRA32'));
    expect(presentation, contains('readbackInFlight'));
    expect(presentation, isNot(contains('TransparencyKey')));
    expect(
      framePublisher,
      contains('MappingPrefix = @"Local\\MaasoAvatarFrame_"'),
    );
    expect(framePublisher, contains('FrameMagic = 0x4653414D'));
    expect(framePublisher, contains('HeaderBytes = 64'));
    expect(framePublisher, contains('MaximumDimension = 2048'));
    expect(framePublisher, contains('SequenceBeginOffset = 8'));
    expect(framePublisher, contains('SequenceEndOffset = 12'));
    expect(framePublisher, contains('PixelsOffset = HeaderBytes'));
    expect(framePublisher, contains('EnforcePremultipliedBgra'));
    expect(framePublisher, contains('pixelBuffer[offset + 3]'));
    expect(avatarBridge, contains('maasoAvatarSession'));
    expect(avatarBridge, contains('SetWindowLongPtr'));
    expect(avatarBridge, contains('ReportAvatarCommandResult'));
    expect(receiver, contains('case "setGaze":'));
    expect(receiver, contains('ApplyGaze(FromJson<GazeCommand>(json))'));
    expect(receiver, isNot(contains('Mouse.current')));
    expect(receiver, isNot(contains('UpdateWindowsDesktopPointerGaze')));
    expect(cmake, contains('windows_desktop_companion_host.cpp'));
  });

  test(
    'Windows show completes only after the first composited Avatar frame',
    () {
      final host = File(
        'windows/runner/windows_desktop_companion_host.cpp',
      ).readAsStringSync();
      final hostHeader = File(
        'windows/runner/windows_desktop_companion_host.h',
      ).readAsStringSync();

      final showStart = host.indexOf('if (call.method_name() == "show")');
      final hideStart = host.indexOf(
        'if (call.method_name() == "hide")',
        showStart,
      );
      expect(showStart, greaterThanOrEqualTo(0));
      expect(hideStart, greaterThan(showStart));
      final showHandler = host.substring(showStart, hideStart);

      expect(
        showHandler,
        contains('pending_show_result_ = std::move(result);'),
      );
      expect(showHandler, isNot(contains('result->Success();')));
      expect(
        hostHeader,
        contains(
          'std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>\n'
          '      pending_show_result_;',
        ),
      );

      final presentStart = host.indexOf(
        'void WindowsDesktopCompanionHost::PresentLatestDesktopPetFrame()',
      );
      final completeStart = host.indexOf(
        'void WindowsDesktopCompanionHost::CompletePendingShow()',
        presentStart,
      );
      expect(presentStart, greaterThanOrEqualTo(0));
      expect(completeStart, greaterThan(presentStart));
      final firstFramePresenter = host.substring(presentStart, completeStart);

      expect(
        firstFramePresenter,
        contains(
          'if (UpdatePetLayeredWindow()) {\n'
          '    UpdateAvatarHitRegion();\n'
          '    avatar_startup_deadline_ = 0;\n'
          '    CompletePendingShow();',
        ),
      );
      expect(host, contains('windows_desktop_companion_first_frame_timeout'));
      expect(host, contains('windows_desktop_companion_show_cancelled'));
      expect(host, contains('FailPendingShow('));
    },
  );

  test('Windows uses the native host and hides avatars during login', () {
    final hostFactory = File(
      'lib/src/desktop/infrastructure/desktop_companion_host_gateway_factory_io.dart',
    ).readAsStringSync();
    final windowGateway = File(
      'lib/src/desktop/infrastructure/window_manager_desktop_window_gateway.dart',
    ).readAsStringSync();
    final conditionalFactory = File(
      'lib/src/desktop/infrastructure/desktop_companion_host_gateway_factory.dart',
    ).readAsStringSync();
    final login = File(
      'lib/src/features/auth/presentation/login_page.dart',
    ).readAsStringSync();
    final unityReceiver = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs',
    ).readAsStringSync();
    final gazeDirector = File(
      'lib/src/core/services/gaze_director.dart',
    ).readAsStringSync();
    final shell = File(
      'lib/src/desktop/presentation/desktop_companion_shell.dart',
    ).readAsStringSync();
    final flutterWindow = File(
      'windows/runner/flutter_window.cpp',
    ).readAsStringSync();

    expect(hostFactory, contains('Platform.isMacOS || Platform.isWindows'));
    expect(windowGateway, contains('Platform.isMacOS || Platform.isWindows'));
    expect(conditionalFactory, contains('if (dart.library.io)'));
    expect(login, contains('LoginDoorwayArtwork()'));
    expect(unityReceiver, contains('UNITY_STANDALONE_WIN'));
    expect(unityReceiver, isNot(contains('UnityEngine.InputSystem')));
    expect(unityReceiver, isNot(contains('UpdateWindowsDesktopPointerGaze')));
    expect(unityReceiver, isNot(contains('Mouse.current')));
    expect(gazeDirector, contains('_behavior ?? _desktopPointer ?? _face'));
    expect(shell, contains('setDesktopPointerGaze(gaze)'));
    expect(flutterWindow, contains('"setMouthOpen",     "setGaze"'));
    expect(unityReceiver, contains('animator.GetBoneTransform'));
    expect(unityReceiver, contains('HumanBodyBones.LeftEye'));
    expect(unityReceiver, contains('HumanBodyBones.RightEye'));
  });
}

final class _IndependentWindowGateway
    implements DesktopWindowGateway, IndependentDesktopPetWindowGateway {
  @override
  bool get isSupported => true;

  @override
  bool get supportsIndependentPetWindow => true;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);

  @override
  Future<void> enterPetMode() async {}

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}

  @override
  Future<void> startDragging() async {}
}

final class _CompanionHostGateway implements DesktopCompanionHostGateway {
  final List<String> calls = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {
    calls.add('initialize');
  }

  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) async {
    calls.add('configureMenu');
  }

  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {
    calls.add('configurePresentation');
  }

  @override
  Future<void> show({required int interactionGeneration}) async {
    calls.add('show');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> showBubble(String text) async {
    calls.add('bubble:$text');
  }

  @override
  Future<void> clearBubble() async {
    calls.add('clearBubble');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}
