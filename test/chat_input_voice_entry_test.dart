import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_composer_morph.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_toggle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    voiceInputRetirementCoordinator.mountVoiceSessionScope(_accountA);
  });

  tearDown(() async {
    voiceInputRetirementCoordinator.clearVoiceSessionIntent();
    await voiceInputRetirementCoordinator.waitForIdle();
    await appServices.reset();
  });

  for (final stage in _EntryStage.values) {
    testWidgets('pending ${stage.name} survives Home parent rebuild', (
      tester,
    ) async {
      final fixture = _VoiceEntryFixture(stage);
      try {
        await fixture.mount(tester);
        await fixture.enter(tester);
        fixture.host.currentState!.rebuild();
        await tester.pump();
        fixture.release();
        await _flush(tester);
        fixture.expectListening(tester);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  for (final stage in [_EntryStage.support, _EntryStage.microphone]) {
    testWidgets('pending ${stage.name} survives MediaQuery change', (
      tester,
    ) async {
      final fixture = _VoiceEntryFixture(stage);
      try {
        await fixture.mount(tester);
        await fixture.enter(tester);
        fixture.host.currentState!.changeMediaQuery();
        await tester.pump();
        fixture.release();
        await _flush(tester);
        fixture.expectListening(tester);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }

  testWidgets('voice entry activity rebuild preserves pending permission', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.permission);
    try {
      await fixture.mount(tester, rebuildOnVoiceActivity: true);
      await fixture.enter(tester);
      expect(fixture.host.currentState!.voiceEntries, 1);
      fixture.release();
      await _flush(tester);
      fixture.expectListening(tester);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('iOS VAD initialization survives Home entry activity and rebuild', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(
      _EntryStage.vadReady,
      externalAudio: true,
    );
    try {
      await fixture.mount(tester, rebuildOnVoiceActivity: true);
      await fixture.enter(tester);
      expect(fixture.host.currentState!.voiceEntries, 1);
      expect(fixture.mic.isRecording.value, isTrue);
      expect(fixture.vad.isReady.value, isFalse);
      fixture.host.currentState!.rebuild();
      await tester.pump();
      fixture.release();
      await _flush(tester);
      fixture.expectListening(tester);
      expect(
        fixture.asr.startCalls,
        0,
        reason:
            'iOS segment ASR waits for VAD samples instead of opening another mic',
      );
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('route hiding cancels pending support without opening capture', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.support);
    try {
      await fixture.mount(tester);
      await fixture.enter(tester);
      unawaited(
        fixture.navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('another route')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      fixture.release();
      await _flush(tester);
      fixture.expectStopped(tester);
      expect(fixture.mic.permissionCalls, 0);
      expect(fixture.mic.startCalls, 0);
      fixture.navigator.currentState!.pop();
      await _flush(tester);
      expect(
        fixture.asr.supportCalls,
        1,
        reason: 'return must not revive entry',
      );
      fixture.expectStopped(tester);
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('background cancels pending ASR and drains late capture', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.asr);
    try {
      await fixture.mount(tester);
      await fixture.enter(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      fixture.release();
      await _flush(tester);
      // A paused app does not draw a new frame. Assert real service retirement
      // now, then require the refreshed visual mode to be off after resume.
      fixture.expectCaptureStopped();
      expect(fixture.asr.cancelCalls, greaterThan(0));
      expect(fixture.mic.stopCalls, greaterThan(0));
      _resume(tester);
      await _flush(tester);
      expect(
        fixture.asr.startCalls,
        1,
        reason: 'foreground cannot revive entry',
      );
      fixture.expectStopped(tester);
    } finally {
      _resume(tester);
      await fixture.dispose(tester);
    }
  });

  testWidgets('account change rejects late microphone success and old intent', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.microphone);
    try {
      await fixture.mount(tester);
      await fixture.enter(tester);
      voiceInputRetirementCoordinator.mountVoiceSessionScope(_accountB);
      await tester.pump();
      fixture.release();
      await _flush(tester);
      fixture.expectStopped(tester);
      expect(fixture.asr.startCalls, 0);
      expect(fixture.mic.stopCalls, greaterThan(0));
      expect(
        voiceInputRetirementCoordinator.voiceSessionRequestedFor(_accountB),
        isFalse,
      );
    } finally {
      await fixture.dispose(tester);
    }
  });

  testWidgets('replaced ASR service cannot admit the old pending entry', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.support);
    final replacement = _FakePlatformAsr();
    try {
      await fixture.mount(tester);
      await fixture.enter(tester);
      appServices.put<PlatformAsrService>(replacement, overrideAbstract: true);
      fixture.host.currentState!.rebuild();
      await tester.pump();
      fixture.release();
      await _flush(tester);
      fixture.expectStopped(tester);
      expect(fixture.mic.startCalls, 0);
      expect(replacement.startCalls, 0);
    } finally {
      await fixture.dispose(tester);
      fixture.asr.closeLifecycle();
    }
  });

  testWidgets('unsupported ASR never opens mic and a later tap can retry', (
    tester,
  ) async {
    final fixture = _VoiceEntryFixture(_EntryStage.support);
    try {
      await fixture.mount(tester);
      await fixture.enter(tester);
      fixture.release(false);
      await _flush(tester);
      fixture.expectStopped(tester);
      expect(fixture.mic.permissionCalls, 0);
      expect(fixture.mic.startCalls, 0);
      expect(fixture.asr.startCalls, 0);

      fixture.asr.support = null;
      await tester.tap(find.byKey(const ValueKey('voice-orb')));
      await _flush(tester);
      expect(fixture.asr.supportCalls, 2);
      fixture.expectListening(tester);
    } finally {
      await fixture.dispose(tester);
    }
  });
}

const _accountA = 'voice-account-a';
const _accountB = 'voice-account-b';

enum _EntryStage { support, permission, microphone, vadReady, vadStart, asr }

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  // Stream cancellation can complete on the real event loop. Let those
  // futures settle, then flush the widget zone without advancing voice timers.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

class _VoiceEntryFixture {
  _VoiceEntryFixture(this.stage, {bool externalAudio = false})
    : asr = _FakePlatformAsr(externalAudio: externalAudio) {
    switch (stage) {
      case _EntryStage.support:
        asr.support = gate;
      case _EntryStage.permission:
        mic.permission = gate;
      case _EntryStage.microphone:
        mic.startGate = gate;
      case _EntryStage.vadReady:
        vad.readyGate = gate;
      case _EntryStage.vadStart:
        vad.startGate = gate;
      case _EntryStage.asr:
        asr.startGate = gate;
    }
  }

  final _EntryStage stage;
  final gate = Completer<bool>();
  final _FakePlatformAsr asr;
  final mic = _FakeMic();
  final vad = _FakeVad();
  final host = GlobalKey<_VoiceEntryHostState>();
  final navigator = GlobalKey<NavigatorState>();

  Future<void> mount(
    WidgetTester tester, {
    bool rebuildOnVoiceActivity = false,
  }) async {
    _resume(tester);
    appServices.put<PlatformAsrService>(asr);
    appServices.put<MicCaptureService>(mic);
    appServices.put<VadService>(vad);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: _VoiceEntryHost(
          key: host,
          rebuildOnVoiceActivity: rebuildOnVoiceActivity,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('voice-orb')));
    await tester.pump();
    final calls = switch (stage) {
      _EntryStage.support => asr.supportCalls,
      _EntryStage.permission => mic.permissionCalls,
      _EntryStage.microphone => mic.startCalls,
      _EntryStage.vadReady => vad.readyCalls,
      _EntryStage.vadStart => vad.startCalls,
      _EntryStage.asr => asr.startCalls,
    };
    expect(calls, 1, reason: 'the real composer must reach the pending stage');
    expect(gate.isCompleted, isFalse);
    expect(
      voiceInputRetirementCoordinator.voiceSessionRequestedFor(_accountA),
      isFalse,
      reason: 'pending capture has not confirmed account voice intent',
    );
  }

  void release([bool succeeds = true]) {
    if (!gate.isCompleted) gate.complete(succeeds);
  }

  bool voiceMode(WidgetTester tester) => tester
      .widget<AppGlassComposerMorph>(
        find.byType(AppGlassComposerMorph, skipOffstage: false),
      )
      .voiceMode;

  void expectListening(WidgetTester tester) {
    expect(mic.startCalls, 1);
    expect(asr.startCalls, asr.supportsExternalAudioInput ? 0 : 1);
    expect(mic.isRecording.value, isTrue);
    expect(asr.isListening.value, !asr.supportsExternalAudioInput);
    expect(vad.isRunning.value, isTrue);
    expect(voiceMode(tester), isTrue);
    expect(
      voiceInputRetirementCoordinator.voiceSessionRequestedFor(_accountA),
      isTrue,
    );
    expect(
      mic.stopCalls,
      0,
      reason: 'ordinary rebuild does not retire capture',
    );
    expect(asr.cancelCalls, 0);
  }

  void expectStopped(WidgetTester tester) {
    expectCaptureStopped();
    expect(voiceMode(tester), isFalse);
  }

  void expectCaptureStopped() {
    expect(mic.isRecording.value, isFalse);
    expect(asr.isListening.value, isFalse);
    expect(vad.isRunning.value, isFalse);
    expect(
      voiceInputRetirementCoordinator.voiceSessionRequestedFor(_accountA),
      isFalse,
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    release(false);
    if (find
            .byType(AppGlassComposerMorph, skipOffstage: false)
            .evaluate()
            .isNotEmpty &&
        voiceMode(tester)) {
      tester
          .widget<AppGlassVoiceToggle>(
            find.byType(AppGlassVoiceToggle, skipOffstage: false),
          )
          .onTap
          ?.call();
      await _flush(tester);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Cancelling the filtered process-wide EventBus stream can use Dart's
    // shared completion future from the real event loop. Alternate bounded
    // real-loop turns with widget-zone microtasks; never bypass the fence.
    for (
      var turn = 0;
      turn < 10 && voiceInputRetirementCoordinator.isRetiring;
      turn++
    ) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(
      voiceInputRetirementCoordinator.isRetiring,
      isFalse,
      reason: 'captured native cleanup must settle within ten event-loop turns',
    );
    await voiceInputRetirementCoordinator.waitForIdle();
    expect(mic.isRecording.value, isFalse);
    expect(asr.isListening.value, isFalse);
    expect(vad.isRunning.value, isFalse);
  }
}

class _VoiceEntryHost extends StatefulWidget {
  const _VoiceEntryHost({super.key, required this.rebuildOnVoiceActivity});

  final bool rebuildOnVoiceActivity;

  @override
  State<_VoiceEntryHost> createState() => _VoiceEntryHostState();
}

class _VoiceEntryHostState extends State<_VoiceEntryHost> {
  final controller = TextEditingController();
  int revision = 0;
  int voiceEntries = 0;
  bool reducedMotion = false;

  void rebuild() => setState(() => revision++);

  void changeMediaQuery() => setState(() => reducedMotion = !reducedMotion);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
      child: Center(
        child: ChatInputBar(
          controller: controller,
          onSend: () {},
          hint: 'draft-$revision',
          inheritVoiceSession: true,
          allowRealtimeVoice: false,
          onInputActivity: (kind) {
            if (kind == PresenceInputActivityKind.voiceModeEntry) {
              voiceEntries++;
              if (widget.rebuildOnVoiceActivity) rebuild();
            }
          },
        ),
      ),
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

class _FakePlatformAsr extends PlatformAsrService {
  _FakePlatformAsr({bool externalAudio = false})
    : super(supportsExternalAudioInputOverride: externalAudio);

  Completer<bool>? support;
  Completer<bool>? startGate;
  int supportCalls = 0;
  int startCalls = 0;
  int cancelCalls = 0;

  @override
  Future<bool> isSupported() async {
    supportCalls++;
    return support == null ? true : await support!.future;
  }

  @override
  Future<bool> start({
    String? locale,
    Stream<Uint8List>? audioStream,
    bool finishExternalAudioOnDone = false,
  }) async {
    startCalls++;
    final started = startGate == null ? true : await startGate!.future;
    isListening.value = started;
    return started;
  }

  @override
  Future<void> cancelAndDrain() async {
    cancelCalls++;
    isListening.value = false;
  }
}

class _FakeMic extends MicCaptureService {
  @override
  // This fixture drives playbackActive directly and never publishes audio.
  // Avoid a process-wide EventBus subscription owned by another fake clock.
  // ignore: must_call_super
  void onInit() {}

  Completer<bool>? permission;
  Completer<bool>? startGate;
  int permissionCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> hasPermission() async {
    permissionCalls++;
    return permission == null ? true : await permission!.future;
  }

  @override
  Future<bool> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    startCalls++;
    final started = startGate == null ? true : await startGate!.future;
    isRecording.value = started;
    return started;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    isRecording.value = false;
  }
}

class _FakeVad extends VadService {
  Completer<bool>? readyGate;
  Completer<bool>? startGate;
  int readyCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> ensureReady() async {
    readyCalls++;
    if (readyGate != null) await readyGate!.future;
    isReady.value = true;
  }

  @override
  Future<void> startWithOptions({
    bool includePlaybackCandidates = false,
  }) async {
    startCalls++;
    if (startGate != null) await startGate!.future;
    isRunning.value = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    isRunning.value = false;
  }
}
