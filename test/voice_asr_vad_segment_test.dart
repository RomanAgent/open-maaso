import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';

void main() {
  const coreExitSignature =
      'Future<void> _exitVoice({\n'
      '    bool send = true,\n'
      '    bool preserveIntent = false,\n'
      '  })';
  testWidgets(
    'text composer does not overflow while constrained to voice orb width',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 86,
                child: ChatInputBar(controller: controller, onSend: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  test(
    'voice inputs share VAD-ended native and pinned local orchestration',
    () {
      final processor = File(
        'lib/src/core/services/speech_segment_processor.dart',
      );
      expect(processor.existsSync(), isTrue);

      const inputBars = <String>[
        'lib/src/core/widgets/chat_input_bar.dart',
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ];
      for (final path in inputBars) {
        final source = File(path).readAsStringSync();

        expect(source, contains('EventBus().on<UserSpeakingEndedEvent>()'));
        expect(source, contains('_recognizeNativeAsrSegment'));
        expect(source, contains('SpeechSegmentProcessor'));
        expect(source, contains('_speechSegmentProcessor.process('));
        expect(source, isNot(contains('nativeAsr.recognizeSamples(')));
        expect(
          source,
          contains('DesktopLocalAsrService? _desktopLocalAsrSession;'),
        );
        expect(
          source,
          contains('final desktopLocalAsr = _desktopLocalAsrSession;'),
        );
        expect(source, contains('desktopLocalAsr: _desktopLocalAsrSession,'));
        expect(
          source,
          isNot(contains('_desktopLocalAsrSession ? _desktopLocalAsr : null')),
        );
        expect(source, contains('supportsExternalAudioInput'));
        expect(source, contains('vadSegmentEndpointing'));
      }

      final source = File(
        'lib/src/core/widgets/chat_input_bar.dart',
      ).readAsStringSync();

      expect(source, contains('Future<bool> _enterNativeAsrWithVadVoice({'));
      expect(source, contains('PlatformAsrService'));
      expect(source, contains('VadService'));
      expect(
        source,
        contains('ever<bool>(vad.userIsSpeaking, _onVadSpeaking)'),
      );
      expect(source, contains('vadSegmentEndpointing'));
      expect(source, isNot(contains('session.feedFloat32(e.samples')));
      expect(source, isNot(contains("package:maaso/service/asr_service.dart")));
      expect(source, isNot(contains('AsrService()')));
    },
  );

  test('pinned local segments cannot be rerouted by a preference change', () {
    final processor = File(
      'lib/src/core/services/speech_segment_processor.dart',
    ).readAsStringSync();

    expect(
      processor,
      contains('final localRequested = desktopLocalAsr != null;'),
    );
    expect(
      processor,
      isNot(contains('desktopLocalAsr?.state.value.preferenceEnabled == true')),
    );
  });

  test('ASR logs retain source metadata but never transcript content', () {
    const inputBars = <String>[
      'lib/src/core/widgets/chat_input_bar.dart',
      'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
    ];

    for (final path in inputBars) {
      final source = File(path).readAsStringSync();
      final submit = _methodBody(
        source,
        'void _submitNativeAsrText(String text, {required String source})',
      );

      expect(submit, contains(r'chars=${finalText.length}'), reason: path);
      expect(submit, isNot(contains(r'text="$finalText"')), reason: path);
      expect(submit, isNot(contains(r'text=$finalText')), reason: path);
    }
  });

  test('voice input reopens capture before its background turn is sent', () {
    const inputBars = [
      'lib/src/core/widgets/chat_input_bar.dart',
      'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
    ];

    for (final path in inputBars) {
      final source = File(path).readAsStringSync();
      final submit = _methodBody(
        source,
        'void _submitNativeAsrText(String text, {required String source})',
      );
      final restart = _methodBody(
        source,
        'Future<void> _restartNativeAsrVoiceAfterSubmit',
      );
      final schedule = _methodBody(source, 'void _scheduleNativeVoiceRestart(');

      expect(
        source,
        contains('Future<void> _restartNativeAsrVoiceAfterSubmit'),
        reason: path,
      );
      expect(submit, contains('_scheduleNativeVoiceRestart('), reason: path);
      expect(
        schedule,
        contains('_restartNativeAsrVoiceAfterSubmit('),
        reason: path,
      );
      expect(
        schedule,
        contains('runVoiceInputAfterOperationDrain('),
        reason: path,
      );
      expect(
        schedule,
        contains('sessionGeneration == _voiceSessionGeneration'),
        reason: path,
      );
      expect(
        schedule,
        contains('voiceInputRetirementCoordinator.isOwner(this)'),
        reason: path,
      );
      expect(submit, contains('await voiceSend();'), reason: path);
      expect(restart, isNot(contains('await onSubmit?.call();')), reason: path);
      expect(restart, contains('_voiceTurnSends.launch('), reason: path);
      expect(
        restart.indexOf('_enterNativeAsrWithVadVoice('),
        lessThan(restart.indexOf('_voiceTurnSends.launch(')),
        reason: path,
      );
      expect(
        submit,
        isNot(contains('_cleanupNativeAsrVoice(cancelRecognizer: false);')),
        reason: path,
      );
      expect(source, contains('bool armNoSpeechTimeout = true'), reason: path);
      expect(restart, contains('armNoSpeechTimeout: false,'), reason: path);
    }
  });

  test('VAD float samples are converted to clamped little-endian PCM16', () {
    final bytes = PlatformAsrService.samplesToPcm16(
      Float32List.fromList(const [-2, -1, -0.5, 0, 0.5, 1, 2]),
    );
    final data = ByteData.sublistView(bytes);

    expect(bytes.length, 14);
    expect(data.getInt16(0, Endian.little), -32768);
    expect(data.getInt16(2, Endian.little), -32768);
    expect(data.getInt16(4, Endian.little), -16384);
    expect(data.getInt16(6, Endian.little), 0);
    expect(data.getInt16(8, Endian.little), 16384);
    expect(data.getInt16(10, Endian.little), 32767);
    expect(data.getInt16(12, Endian.little), 32767);
  });

  test(
    'iOS native ASR consumes shared mic PCM instead of opening a second mic',
    () {
      final platformAsr = File(
        'lib/src/core/services/platform_asr_service.dart',
      ).readAsStringSync();
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();

      expect(platformAsr, contains('Stream<Uint8List>? audioStream'));
      expect(platformAsr, contains('_externalChunksSent'));
      expect(platformAsr, contains('_externalBytesSent'));
      expect(platformAsr, contains('recognizeSamples'));
      expect(platformAsr, contains("'startExternal'"));
      expect(platformAsr, contains("'appendPcm16'"));
      expect(platformAsr, contains('finishExternalAudioOnDone'));
      expect(platformAsr, contains('external audio ended chunks='));
      expect(platformAsr, contains('Platform.isIOS'));
      expect(ios, contains('case "startExternal"'));
      expect(ios, contains('case "appendPcm16"'));
      expect(ios, contains('appendExternalPcm16'));
      expect(ios, contains('externalAudio'));
    },
  );

  test(
    'iOS normal ASR stop keeps recognition task alive until final callback',
    () {
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();

      expect(ios, contains('private func cleanupRecognition('));
      expect(ios, contains('private func finishRecognitionAfterFinal()'));
      expect(ios, contains('recognitionRequest?.endAudio()'));
      expect(ios, contains('recognitionTask?.cancel()'));
    },
  );

  test('both voice inputs fence duplicate and stale async entry work', () {
    const inputBars = <String>[
      'lib/src/core/widgets/chat_input_bar.dart',
      'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
    ];

    for (final path in inputBars) {
      final source = File(path).readAsStringSync();
      final enterVoice = _methodBody(source, 'Future<void> _enterVoice()');
      final nativeEntry = _methodBody(
        source,
        'Future<bool> _enterNativeAsrWithVadVoice({',
      );
      final staleCleanup = _methodBody(
        source,
        'Future<void> _abortStaleNativeVoiceEntry(',
      );
      final onVadSpeechEnded = _methodBody(
        source,
        'void _onVadSpeechEnded(UserSpeakingEndedEvent event)',
      );
      final segmentOperation = _methodBody(
        source,
        'Future<void> _runVoiceSegmentOperation(',
      );
      final recognizeSegment = _methodBody(
        source,
        'Future<void> _recognizeNativeAsrSegment(',
      );
      final exitVoice = _methodBody(
        source,
        path.contains('/core/')
            ? coreExitSignature
            : 'Future<void> _exitVoice({bool send = true})',
      );
      final restart = _methodBody(
        source,
        'Future<void> _restartNativeAsrVoiceAfterSubmit',
      );
      final cleanup = _methodBody(
        source,
        'Future<void> _cleanupNativeAsrVoice',
      );
      final relinquish = _methodBody(
        source,
        'Future<void> _relinquishVoiceOwnership()',
      );
      final releaseOwnership = _methodBody(
        source,
        'void _releaseVoiceOwnership()',
      );
      final dispose = _methodBody(source, 'void dispose()');

      expect(source, contains('bool _enteringVoice = false;'), reason: path);
      expect(source, contains('int _voiceEntryGeneration = 0;'), reason: path);
      expect(
        source,
        contains('int? _activeVoiceEntryGeneration;'),
        reason: path,
      );
      expect(source, contains('int? _beginVoiceEntry('), reason: path);
      expect(source, contains('void _invalidateVoiceEntry()'), reason: path);
      expect(source, contains('void _finishVoiceEntry('), reason: path);
      expect(source, contains('voiceInputRetirementCoordinator'), reason: path);
      expect(
        source,
        contains('voiceInputRetirementCoordinator.isOwner(this)'),
        reason: path,
      );
      expect(
        source,
        contains('voiceInputRetirementCoordinator.release(this)'),
        reason: path,
      );
      expect(source, contains('bool cleanupRequired = false;'), reason: path);
      expect(
        source,
        contains('Future<void>? _voiceRetirementFuture;'),
        reason: path,
      );
      expect(source, contains('runVoiceInputCleanupSteps'), reason: path);
      expect(
        source,
        contains('final _voiceSegmentOperations = VoiceInputOperationFence();'),
        reason: path,
      );
      expect(
        RegExp(r'_enteringVoice\s*=\s*false;').allMatches(source).length,
        2,
        reason: '$path must only clear the guard in its declaration/finalizer',
      );
      expect(
        source,
        contains('identical(_desktopLocalAsr, desktopLocalAsr)'),
        reason: path,
      );
      expect(
        enterVoice,
        contains('final entryGeneration = _beginVoiceEntry('),
        reason: path,
      );
      final beginVoiceEntry = _methodBody(source, 'int? _beginVoiceEntry(');
      expect(
        beginVoiceEntry,
        contains('_voiceSegmentOperations.isActive'),
        reason: path,
      );
      expect(
        enterVoice.indexOf('await voiceInputRetirementCoordinator.acquire('),
        lessThan(
          enterVoice.indexOf('final entryGeneration = _beginVoiceEntry('),
        ),
        reason: path,
      );
      expect(
        enterVoice,
        contains('retireCurrentOwner: _relinquishVoiceOwnership'),
        reason: path,
      );
      expect(
        enterVoice,
        contains('_finishVoiceEntry(entryGeneration);'),
        reason: path,
      );
      expect(
        nativeEntry,
        contains('final operational = await desktopLocalAsr!.isOperational();'),
        reason: path,
      );
      expect(
        nativeEntry,
        contains('final supported = await nativeAsr.isSupported();'),
        reason: path,
      );
      expect(
        nativeEntry,
        contains('_nativeVoiceEntryIsCurrent('),
        reason: path,
      );
      expect(
        nativeEntry.indexOf('await _resetVoiceModeSubscriptions();'),
        lessThan(
          nativeEntry.indexOf('EventBus().on<UserSpeakingEndedEvent>()'),
        ),
        reason: path,
      );
      expect(
        staleCleanup,
        contains('await _retireNativeVoiceEntryResources('),
        reason: path,
      );
      expect(staleCleanup, contains('cancelRecognizer: true'), reason: path);
      expect(
        onVadSpeechEnded,
        contains('_voiceSegmentOperations.track('),
        reason: path,
      );
      expect(
        onVadSpeechEnded,
        contains('_runVoiceSegmentOperation('),
        reason: path,
      );
      expect(
        segmentOperation,
        contains('drainSegmentOperations: false'),
        reason: path,
      );
      expect(
        recognizeSegment,
        contains('isCurrent: segmentIsCurrent'),
        reason: path,
      );
      expect(exitVoice, contains('_invalidateVoiceEntry();'), reason: path);
      expect(cleanup, contains('_invalidateVoiceEntry();'), reason: path);
      expect(
        restart,
        contains('_beginVoiceEntry(allowActiveVoiceMode: true)'),
        reason: path,
      );
      expect(dispose, contains('_invalidateVoiceEntry();'), reason: path);
      expect(
        dispose,
        contains('final pendingCleanup = _nativeVoiceCleanupFuture;'),
        reason: path,
      );
      expect(dispose, contains('_releaseVoiceOwnership()'), reason: path);
      expect(
        dispose,
        contains('_voiceSegmentOperations.drain()'),
        reason: path,
      );
      expect(
        source,
        contains('voiceInputRetirementCoordinator.track('),
        reason: path,
      );
      expect(source, contains('cancelAndDrain()'), reason: path);
      expect(
        cleanup,
        contains('retireVoiceInputResourcesWithOperationDrain('),
        reason: path,
      );
      expect(relinquish, contains('_invalidateVoiceEntry();'), reason: path);
      expect(
        relinquish,
        contains('await _voiceSegmentOperations.drain();'),
        reason: path,
      );
      expect(
        relinquish,
        contains('if (pendingEntry != null) await pendingEntry;'),
        reason: path,
      );
      expect(
        releaseOwnership,
        contains('_voiceSegmentOperations.isActive'),
        reason: path,
      );
    }

    final core = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();
    expect(core, contains('Worker? _nativeAsrErrorWorker'));
    expect(core, contains("source: 'partial-after-error'"));
    expect(core, contains('identical(_activeVoiceOwner, this)'));
  });

  test('realtime voice mode bypasses app VAD pipeline', () {
    final source = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();

    expect(source, contains('bool _realtimeVoiceActive = false;'));
    expect(source, contains('bool get _shouldUseRealtimeVoice'));
    expect(source, contains('Future<bool> _enterRealtimeVoice({'));
    final exitVoice = _methodBody(source, coreExitSignature);
    expect(exitVoice, contains('final leave = realtime.leave();'));
    expect(exitVoice, contains('voiceInputRetirementCoordinator.track('));
    expect(exitVoice, contains('retry: realtime.leave'));
    expect(exitVoice, contains('await leave;'));

    final enterVoice = _methodBody(source, 'Future<void> _enterVoice()');
    final realtimeGuard = enterVoice.indexOf('if (await _enterRealtimeVoice(');
    final returnAfterRealtime = enterVoice.indexOf('return;', realtimeGuard);
    final nativeAsrLookup = enterVoice.indexOf(
      'await _enterNativeAsrWithVadVoice(',
    );
    expect(realtimeGuard, greaterThanOrEqualTo(0));
    expect(returnAfterRealtime, greaterThan(realtimeGuard));
    expect(nativeAsrLookup, greaterThan(returnAfterRealtime));
  });
}

String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: signature);

  final bodyStart = source.indexOf(RegExp(r'\)\s*(?:async\s*)?\{'), start);
  expect(bodyStart, greaterThan(start), reason: signature);
  final openBrace = source.indexOf('{', bodyStart);
  expect(openBrace, greaterThan(bodyStart), reason: signature);

  var depth = 0;
  for (var i = openBrace; i < source.length; i += 1) {
    final char = source[i];
    if (char == '{') depth += 1;
    if (char == '}') {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }

  fail('Could not find method end for $signature');
}
