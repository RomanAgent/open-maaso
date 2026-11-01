import 'dart:async';
import 'dart:typed_data';

import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/voice_prosody_service.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

enum SpeechSegmentProcessingStatus {
  externalRecognitionStarted,
  localRecognitionCompleted,
  fallbackFinalizeRequested,
  rejected,
}

final class SpeechSegmentProcessingResult {
  const SpeechSegmentProcessingResult._({
    required this.status,
    this.diagnostic,
    this.transcript,
    this.utteranceId,
    this.utteranceGeneration,
  });

  const SpeechSegmentProcessingResult.externalRecognitionStarted({
    required String utteranceId,
    required int utteranceGeneration,
  }) : this._(
         status: SpeechSegmentProcessingStatus.externalRecognitionStarted,
         utteranceId: utteranceId,
         utteranceGeneration: utteranceGeneration,
       );

  const SpeechSegmentProcessingResult.localRecognitionCompleted({
    required String transcript,
    required String utteranceId,
    required int utteranceGeneration,
  }) : this._(
         status: SpeechSegmentProcessingStatus.localRecognitionCompleted,
         transcript: transcript,
         utteranceId: utteranceId,
         utteranceGeneration: utteranceGeneration,
       );

  const SpeechSegmentProcessingResult.fallbackFinalizeRequested()
    : this._(status: SpeechSegmentProcessingStatus.fallbackFinalizeRequested);

  const SpeechSegmentProcessingResult.rejected({
    String? diagnostic,
    String? utteranceId,
    int? utteranceGeneration,
  }) : this._(
         status: SpeechSegmentProcessingStatus.rejected,
         diagnostic: diagnostic,
         utteranceId: utteranceId,
         utteranceGeneration: utteranceGeneration,
       );

  final SpeechSegmentProcessingStatus status;
  final String? diagnostic;
  final String? transcript;
  final String? utteranceId;
  final int? utteranceGeneration;
}

/// Stateless orchestration for one VAD-ended PCM segment.
///
/// The processor neither starts capture nor retains audio. Widget-owned voice
/// state remains outside this boundary and is supplied only as narrow callbacks
/// for the existing admission and stop ordering.
final class SpeechSegmentProcessor {
  const SpeechSegmentProcessor();

  static int _utteranceSerial = 0;
  static const int _utteranceGeneration = 1;
  static const int _vadSampleRate = 16000;

  Future<SpeechSegmentProcessingResult> process({
    required PlatformAsrService platformAsr,
    required Float32List samples,
    required Duration duration,
    required String locale,
    required String source,
    required bool Function() isCurrent,
    required void Function() onExternalRecognitionAdmission,
    required Future<void> Function() stopVad,
    required Future<void> Function() stopMic,
    DesktopLocalAsrService? desktopLocalAsr,
    VoiceProsodyService? voiceProsody,
  }) async {
    // A voice session pins the exact account-owned service at admission.
    // Do not re-read its mutable preference here: changing settings during an
    // admitted segment must never reroute that PCM to native/cloud handling.
    final localRequested = desktopLocalAsr != null;
    if (!localRequested && !platformAsr.supportsExternalAudioInput) {
      return const SpeechSegmentProcessingResult.fallbackFinalizeRequested();
    }
    if (!isCurrent()) {
      return const SpeechSegmentProcessingResult.rejected(
        diagnostic: 'stale_voice_segment',
      );
    }

    onExternalRecognitionAdmission();
    final utteranceId = _nextUtteranceId();
    SpeechSegmentProcessingResult staleResult() {
      voiceProsody?.invalidateActiveUtterance(
        utteranceId: utteranceId,
        nextGeneration: _utteranceGeneration + 1,
      );
      return SpeechSegmentProcessingResult.rejected(
        diagnostic: 'stale_voice_segment',
        utteranceId: utteranceId,
        utteranceGeneration: _utteranceGeneration,
      );
    }

    if (!isCurrent()) return staleResult();
    if (voiceProsody != null) {
      unawaited(
        voiceProsody.processActiveSegment(
          samples: samples,
          sampleRate: _vadSampleRate,
          utteranceId: utteranceId,
          utteranceGeneration: _utteranceGeneration,
        ),
      );
    }
    Log.i(
      '🎙️ [Voice] ${localRequested ? 'local' : 'native'} ASR requested '
      'by $source samples=${samples.length} '
      'durationMs=${duration.inMilliseconds}',
    );
    if (localRequested) {
      final localAsr = desktopLocalAsr;
      late final DesktopLocalAsrDecodeResult decoded;
      try {
        if (!isCurrent()) return staleResult();
        await stopVad();
        if (!isCurrent()) return staleResult();
        await stopMic();
        if (!isCurrent()) return staleResult();
        decoded = await localAsr.decode(
          samples: samples,
          sampleRateHz: _vadSampleRate,
          locale: locale,
        );
        if (!isCurrent()) return staleResult();
      } on Object {
        voiceProsody?.invalidateActiveUtterance(
          utteranceId: utteranceId,
          nextGeneration: _utteranceGeneration + 1,
        );
        rethrow;
      }
      if (!decoded.accepted) {
        voiceProsody?.invalidateActiveUtterance(
          utteranceId: utteranceId,
          nextGeneration: _utteranceGeneration + 1,
        );
        return SpeechSegmentProcessingResult.rejected(
          diagnostic: decoded.failure?.name ?? 'desktop_local_asr_failed',
          utteranceId: utteranceId,
          utteranceGeneration: _utteranceGeneration,
        );
      }
      return SpeechSegmentProcessingResult.localRecognitionCompleted(
        transcript: decoded.transcript ?? '',
        utteranceId: utteranceId,
        utteranceGeneration: _utteranceGeneration,
      );
    }

    late final bool started;
    try {
      if (!isCurrent()) return staleResult();
      await stopVad();
      if (!isCurrent()) return staleResult();
      await stopMic();
      if (!isCurrent()) return staleResult();
      started = await platformAsr.recognizeSamples(
        samples: samples,
        locale: locale,
      );
      if (!isCurrent()) return staleResult();
    } on Object {
      voiceProsody?.invalidateActiveUtterance(
        utteranceId: utteranceId,
        nextGeneration: _utteranceGeneration + 1,
      );
      rethrow;
    }
    if (!started) {
      voiceProsody?.invalidateActiveUtterance(
        utteranceId: utteranceId,
        nextGeneration: _utteranceGeneration + 1,
      );
      return SpeechSegmentProcessingResult.rejected(
        diagnostic: platformAsr.error.value,
        utteranceId: utteranceId,
        utteranceGeneration: _utteranceGeneration,
      );
    }
    return SpeechSegmentProcessingResult.externalRecognitionStarted(
      utteranceId: utteranceId,
      utteranceGeneration: _utteranceGeneration,
    );
  }

  static String _nextUtteranceId() {
    _utteranceSerial = (_utteranceSerial + 1) & 0x1fffffffffffff;
    if (_utteranceSerial == 0) _utteranceSerial = 1;
    return 'vad-utterance-$_utteranceSerial';
  }
}
