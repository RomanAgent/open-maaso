import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_composer_morph.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_toggle.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_orb.dart';

const _account = 'home-voice-owner|mount-1';
const _draft = TextEditingValue(
  text: 'Keep this typed draft',
  selection: TextSelection(baseOffset: 5, extentOffset: 9),
  composing: TextRange(start: 5, end: 9),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    voiceInputRetirementCoordinator.mountVoiceSessionScope(_account);
  });
  tearDown(() async {
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    await voiceInputRetirementCoordinator.waitForIdle();
    await appServices.reset();
  });

  testWidgets(
    'Home partial and final transcripts never replace its typed value',
    (tester) async {
      final fixture = _Fixture();
      try {
        await fixture.mount(tester);
        await fixture.enter(tester);
        fixture.asr.partialTranscript.value = 'spoken partial';
        await tester.pump();
        expect(fixture.state.controller.value, _draft);
        fixture.asr.finals.add('  spoken final  ');
        await _flush(tester);
        expect(fixture.state.sent, ['spoken final']);
        expect(fixture.state.controller.value, _draft);
        expect(fixture.state.textSends, 0);
        expect(fixture.state.legacyVoiceSends, isEmpty);
        await fixture.exit(tester);
        expect(fixture.state.controller.value, _draft);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'IME hook rejection preserves the draft before probing permissions',
    (tester) async {
      final fixture = _Fixture();
      try {
        await fixture.mount(tester);
        fixture.state.change(() => fixture.state.beforeEntry = () => false);
        await tester.pump();
        await fixture.enter(tester, listening: false);
        expect(fixture.mic.permissionCalls, 0);
        expect(fixture.asr.supportCalls, 0);
        expect(fixture.state.controller.value, _draft);
        expect(fixture.state.presentation!.voiceActive, isFalse);
        expect(fixture.state.presentation!.enteringVoice, isFalse);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'pending IME hook can be cancelled without starting capture later',
    (tester) async {
      final fixture = _Fixture();
      final hook = Completer<bool>();
      try {
        await fixture.mount(tester);
        fixture.state.change(
          () => fixture.state.beforeEntry = () => hook.future,
        );
        await tester.pump();
        final entering = fixture.state.presentation!.enterVoice();
        await tester.pump();
        expect(fixture.state.presentation!.enteringVoice, isTrue);
        await fixture.state.presentation!.exitVoice();
        await tester.pump();
        expect(fixture.state.presentation!.enteringVoice, isFalse);
        hook.complete(true);
        await entering;
        await _flush(tester);
        expect(fixture.mic.permissionCalls, 0);
        expect(fixture.state.sent, isEmpty);
        expect(fixture.state.controller.value, _draft);
      } finally {
        if (!hook.isCompleted) hook.complete(false);
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets('permission denial and missing Home callback fail closed', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await fixture.mount(tester);
      fixture.state.change(() => fixture.state.voiceCallback = null);
      await tester.pump();
      expect(fixture.state.presentation!.canEnterVoice, isFalse);
      await fixture.state.presentation!.enterVoice();
      expect(fixture.mic.permissionCalls, 0);
      expect(fixture.state.textSends, 0);
      fixture.state.change(
        () => fixture.state.voiceCallback = fixture.state.recordVoice,
      );
      fixture.mic.granted = false;
      await tester.pump();
      await fixture.enter(tester, listening: false);
      expect(fixture.mic.startCalls, 0);
      expect(fixture.state.controller.value, _draft);
      expect(fixture.state.sent, isEmpty);
      expect(fixture.state.presentation!.voiceActive, isFalse);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets(
    'restart captures callback and text without erasing the next partial',
    (tester) async {
      final fixture = _Fixture();
      final restart = Completer<bool>();
      final old = <String>[], replacement = <String>[];
      try {
        await fixture.mount(tester);
        fixture.state.change(
          () => fixture.state.voiceCallback = (text) async => old.add(text),
        );
        await tester.pump();
        await fixture.enter(tester);
        fixture.asr.restartGate = restart;
        fixture.asr.partialOnSecondStart = 'next phrase';
        fixture.asr.finals.add('first phrase');
        await _flush(tester);
        expect(fixture.asr.startCalls, 2);
        fixture.state.change(
          () =>
              fixture.state.voiceCallback = (text) async =>
                  replacement.add(text),
        );
        await tester.pump();
        restart.complete(true);
        await _flush(tester);
        expect(old, ['first phrase']);
        expect(replacement, isEmpty);
        fixture.asr.error.value = 'temporary recognizer failure';
        await _flush(tester);
        expect(replacement, ['next phrase']);
        expect(fixture.state.controller.value, _draft);
      } finally {
        if (!restart.isCompleted) restart.complete(false);
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'pending microphone permission can be cancelled from the Home orb',
    (tester) async {
      final fixture = _Fixture();
      final permission = Completer<bool>();
      try {
        await fixture.mount(tester);
        fixture.mic.permissionGate = permission;
        await fixture.enter(tester, listening: false);
        expect(fixture.mic.permissionCalls, 1);
        expect(fixture.state.presentation!.enteringVoice, isTrue);
        tester
            .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
            .onTap!
            .call();
        await _flush(tester);
        expect(fixture.state.presentation!.voiceActive, isFalse);
        expect(fixture.state.presentation!.enteringVoice, isFalse);
        permission.complete(true);
        await _flush(tester);
        expect(fixture.mic.startCalls, 0);
        expect(fixture.state.sent, isEmpty);
        expect(fixture.state.controller.value, _draft);
      } finally {
        if (!permission.isCompleted) permission.complete(false);
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'an admitted voice send remains single while the Home orb exits',
    (tester) async {
      final fixture = _Fixture();
      final completed = Completer<void>();
      try {
        await fixture.mount(tester);
        fixture.state.change(
          () => fixture.state.voiceCallback = (text) async {
            fixture.state.sent.add(text);
            await completed.future;
          },
        );
        await tester.pump();
        await fixture.enter(tester);
        fixture.asr.finals.add('one submitted turn');
        await _flush(tester);
        expect(fixture.state.presentation!.voiceSubmitBusy, isTrue);
        fixture.state.controller.text = 'A newer independent typed draft';
        tester
            .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
            .onTap!
            .call();
        await _flush(tester);
        fixture.asr.finals.add('late result after exit');
        await tester.pump();
        expect(fixture.state.sent, ['one submitted turn']);
        expect(fixture.state.interrupts, 0);
        expect(
          fixture.state.controller.text,
          'A newer independent typed draft',
        );
        completed.complete();
        await _flush(tester);
        expect(fixture.state.presentation!.voiceSubmitBusy, isFalse);
      } finally {
        if (!completed.isCompleted) completed.complete();
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'partial fallback reads the voice buffer instead of the hidden draft',
    (tester) async {
      final fixture = _Fixture();
      try {
        await fixture.mount(tester);
        await fixture.enter(tester);
        fixture.asr.partialTranscript.value = 'fallback phrase';
        fixture.vad.userIsSpeaking.value = true;
        await tester.pump();
        fixture.vad.userIsSpeaking.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));
        await tester.pump();
        expect(fixture.state.presentation!.phase, VoiceOrbPhase.recognizing);
        await tester.pump(const Duration(milliseconds: 700));
        await _flush(tester);
        expect(fixture.state.sent, ['fallback phrase']);
        expect(fixture.state.controller.value, _draft);
      } finally {
        await fixture.dispose(tester);
      }
    },
  );

  for (final phase in VoiceOrbPhase.values) {
    testWidgets(
      'Home ${phase.name} orb exits without interrupting or sending',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester);
          await fixture.enter(tester);
          switch (phase) {
            case VoiceOrbPhase.listening:
              break;
            case VoiceOrbPhase.recognizing:
              fixture.asr.partialTranscript.value = 'unfinished';
              fixture.vad.userIsSpeaking.value = true;
              await tester.pump();
              fixture.vad.userIsSpeaking.value = false;
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 900));
            case VoiceOrbPhase.thinking:
              fixture.state.change(() => fixture.state.thinking = true);
            case VoiceOrbPhase.speaking:
              fixture.mic.playbackActive.value = true;
          }
          await tester.pump();
          expect(fixture.state.presentation!.phase, phase);
          tester
              .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
              .onTap!
              .call();
          await _flush(tester);
          expect(fixture.state.presentation!.voiceActive, isFalse);
          expect(fixture.mic.isRecording.value, isFalse);
          expect(fixture.state.interrupts, 0);
          expect(fixture.state.sent, isEmpty);
          expect(fixture.state.controller.value, _draft);
          expect(find.byIcon(Icons.keyboard_alt_rounded), findsNothing);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }

  for (final replacement in [
    'controller',
    'mode',
    'callback',
    'account',
    'cancel',
  ]) {
    testWidgets('$replacement retirement rejects the old pending restart', (
      tester,
    ) async {
      final fixture = _Fixture();
      final restart = Completer<bool>();
      try {
        await fixture.mount(tester);
        await fixture.enter(tester);
        fixture.asr.restartGate = restart;
        fixture.asr.finals.add('old voice request');
        await _flush(tester);
        expect(fixture.asr.startCalls, 2);
        switch (replacement) {
          case 'controller':
            fixture.state.replaceController();
          case 'mode':
            fixture.state.change(() => fixture.state.homeMode = false);
          case 'callback':
            fixture.state.change(() => fixture.state.voiceCallback = null);
          case 'account':
            voiceInputRetirementCoordinator.clearVoiceSessionIntent();
            voiceInputRetirementCoordinator.mountVoiceSessionScope(
              'another-account|mount-2',
            );
          case 'cancel':
            unawaited(fixture.state.presentation!.exitVoice());
        }
        await tester.pump();
        restart.complete(true);
        await _flush(tester);
        expect(fixture.state.sent, isEmpty);
        expect(fixture.state.legacyVoiceSends, isEmpty);
        expect(fixture.state.textSends, 0);
        expect(
          fixture.state.controller.text,
          replacement == 'controller' ? 'New controller draft' : _draft.text,
        );
      } finally {
        if (!restart.isCompleted) restart.complete(false);
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets(
    'a pending legacy restart cannot overwrite a replacement Home controller',
    (tester) async {
      final fixture = _Fixture();
      final restart = Completer<bool>();
      try {
        await fixture.mount(tester);
        fixture.state.change(() => fixture.state.homeMode = false);
        await tester.pump();
        tester
            .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
            .onTap!
            .call();
        await _flush(tester);
        fixture.asr.restartGate = restart;
        fixture.asr.finals.add('legacy pending request');
        await _flush(tester);
        expect(fixture.asr.startCalls, 2);
        fixture.state.change(() => fixture.state.homeMode = true);
        fixture.state.replaceController();
        await tester.pump();
        restart.complete(true);
        await _flush(tester);
        expect(fixture.state.controller.text, 'New controller draft');
        expect(fixture.state.sent, isEmpty);
        expect(fixture.state.legacyVoiceSends, isEmpty);
      } finally {
        if (!restart.isCompleted) restart.complete(false);
        await fixture.dispose(tester);
      }
    },
  );

  testWidgets(
    'Home realtime entry and delayed exit preserve draft and prevent reentry',
    (tester) async {
      final fixture = _Fixture();
      final realtime = _FakeRealtime();
      final leaving = Completer<void>();
      try {
        appServices.put<SecureStorageService>(SecureStorageService());
        final mode = MaasoAgentModeService();
        mode.pipelineMode.value = AgentPipelineMode.volcRealtimeAudio;
        appServices.put<MaasoAgentModeService>(mode);
        appServices.put<RealtimeAgentConfig>(
          RealtimeAgentConfig(
            enabled: true,
            baseUri: Uri.parse('https://example.test/'),
          ),
        );
        appServices.put<VolcRtcSessionService>(realtime);
        await fixture.mount(tester);
        fixture.state.change(() => fixture.state.allowRealtime = true);
        await tester.pump();
        await fixture.enter(tester, listening: false);
        expect(realtime.joins, 1);
        expect(fixture.state.presentation!.voiceActive, isTrue);
        expect(fixture.state.controller.value, _draft);
        realtime.leaveGate = leaving;
        final exit = fixture.state.presentation!.exitVoice();
        await _flush(tester);
        expect(fixture.state.presentation!.canEnterVoice, isFalse);
        await fixture.state.presentation!.enterVoice();
        expect(realtime.joins, 1);
        leaving.complete();
        await exit;
        await _flush(tester);
        expect(fixture.state.controller.value, _draft);
        expect(fixture.state.presentation!.voiceActive, isFalse);
      } finally {
        if (!leaving.isCompleted) leaving.complete();
        await fixture.dispose(tester);
      }
    },
  );

  for (final voiceOnly in [false, true]) {
    testWidgets(
      'legacy voiceOnly=$voiceOnly retains the busy interrupt action',
      (tester) async {
        final fixture = _Fixture();
        try {
          await fixture.mount(tester);
          fixture.state.change(() {
            fixture.state.homeMode = false;
            fixture.state.voiceOnly = voiceOnly;
          });
          await tester.pump();
          tester
              .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
              .onTap!
              .call();
          await _flush(tester);
          expect(fixture.mic.isRecording.value, isTrue);
          fixture.state.change(() => fixture.state.thinking = true);
          await tester.pump();
          tester
              .widget<AppGlassVoiceToggle>(find.byType(AppGlassVoiceToggle))
              .onTap!
              .call();
          await tester.pump();
          expect(fixture.state.interrupts, 1);
          expect(fixture.mic.isRecording.value, isTrue);
          expect(find.byType(AppGlassComposerMorph), findsOneWidget);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  await tester.pump();
}

final class _Fixture {
  final asr = _FakeAsr();
  final mic = _FakeMic();
  final vad = _FakeVad();
  final key = GlobalKey<_HostState>();
  _HostState get state => key.currentState!;

  Future<void> mount(WidgetTester tester) async {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
    appServices.put<PlatformAsrService>(asr);
    appServices.put<MicCaptureService>(mic);
    appServices.put<VadService>(vad);
    await tester.pumpWidget(MaterialApp(home: _Host(key: key)));
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester, {bool listening = true}) async {
    unawaited(state.presentation!.enterVoice());
    await _flush(tester);
    if (listening) expect(mic.isRecording.value, isTrue);
  }

  Future<void> exit(WidgetTester tester) async {
    unawaited(state.presentation!.exitVoice());
    await _flush(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    if (asr.restartGate case final gate? when !gate.isCompleted) {
      gate.complete(false);
    }
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    for (var i = 0; i < 8 && voiceInputRetirementCoordinator.isRetiring; i++) {
      await _flush(tester);
    }
    expect(voiceInputRetirementCoordinator.isRetiring, isFalse);
    await asr.finals.close();
  }
}

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  TextEditingController controller = TextEditingController.fromValue(_draft);
  final retiredControllers = <TextEditingController>[];
  ChatInputPresentation? presentation;
  Future<void> Function(String)? voiceCallback;
  FutureOr<bool> Function()? beforeEntry;
  bool thinking = false,
      homeMode = true,
      voiceOnly = false,
      allowRealtime = false;
  int textSends = 0, interrupts = 0;
  final sent = <String>[], legacyVoiceSends = <String>[];
  @override
  void initState() {
    super.initState();
    voiceCallback = recordVoice;
  }

  Future<void> recordVoice(String text) async => sent.add(text);
  void change(VoidCallback action) => setState(action);
  void replaceController() => setState(() {
    retiredControllers.add(controller);
    controller = TextEditingController(text: 'New controller draft');
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: Center(
        child: ChatInputBar(
          controller: controller,
          homeComposerMode: homeMode,
          voiceOnly: voiceOnly,
          onVoiceTextSend: voiceCallback,
          beforeVoiceEntry: beforeEntry,
          onSend: () => textSends++,
          onVoiceSend: () async => legacyVoiceSends.add(controller.text),
          onInterrupt: () => interrupts++,
          isThinking: thinking,
          inheritVoiceSession: true,
          allowRealtimeVoice: allowRealtime,
          presentationBuilder: (context, value) {
            presentation = value;
            return value.voiceControlBuilder(
              context,
              value.voiceActive || value.enteringVoice ? 1 : 0,
            );
          },
        ),
      ),
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    for (final old in retiredControllers) {
      old.dispose();
    }
    super.dispose();
  }
}

class _FakeAsr extends PlatformAsrService {
  _FakeAsr() : super(supportsExternalAudioInputOverride: false);
  final finals = StreamController<String>.broadcast(sync: true);
  Completer<bool>? restartGate;
  String? partialOnSecondStart;
  int supportCalls = 0, startCalls = 0;
  @override
  Stream<String> get finalResults => finals.stream;
  @override
  Future<bool> isSupported() async {
    supportCalls++;
    return true;
  }

  @override
  Future<bool> start({
    String? locale,
    Stream<Uint8List>? audioStream,
    bool finishExternalAudioOnDone = false,
  }) async {
    startCalls++;
    final call = startCalls;
    partialTranscript.value = '';
    final started = call > 1 && restartGate != null
        ? await restartGate!.future
        : true;
    isListening.value = started;
    if (call == 2 && partialOnSecondStart != null) {
      partialTranscript.value = partialOnSecondStart!;
    }
    return started;
  }

  @override
  Future<void> stop() async {
    isListening.value = false;
  }

  @override
  Future<void> cancelAndDrain() async {
    isListening.value = false;
  }
}

class _FakeMic extends MicCaptureService {
  @override
  // This fake never owns a platform recorder or process-wide audio subscription.
  // ignore: must_call_super
  void onInit() {}
  bool granted = true;
  Completer<bool>? permissionGate;
  int permissionCalls = 0, startCalls = 0;
  @override
  Future<bool> hasPermission() async {
    permissionCalls++;
    return permissionGate == null ? granted : await permissionGate!.future;
  }

  @override
  Future<bool> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    startCalls++;
    isRecording.value = true;
    return true;
  }

  @override
  Future<void> stop() async {
    isRecording.value = false;
  }
}

class _FakeVad extends VadService {
  @override
  Future<void> ensureReady() async {
    isReady.value = true;
  }

  @override
  Future<void> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    isRunning.value = true;
  }

  @override
  Future<void> stop() async {
    isRunning.value = false;
  }
}

class _FakeRealtime implements VolcRtcSessionService {
  int joins = 0;
  Completer<void>? leaveGate;
  @override
  Future<RealtimeSession> joinAgent({
    String agentId = 'self',
    String? userId,
  }) async {
    joins++;
    return RealtimeSession(
      sessionId: 'test-session',
      locale: 'en',
      rtcAppId: 'test-app',
      roomId: 'test-room',
      userId: 'test-user',
      agentUserId: 'self',
      taskId: 'test-task',
      rtcToken: 'test-only',
      actionStreamUri: Uri.parse('https://example.test/actions'),
      createdAt: DateTime.utc(2026, 10, 22),
    );
  }

  @override
  Future<void> leave() async {
    if (leaveGate != null) await leaveGate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
