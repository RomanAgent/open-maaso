import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show
        defaultTargetPlatform,
        kIsWeb,
        TargetPlatform,
        visibleForTesting,
        VoidCallback;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/context/agent_config.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maaso/src/features/agent/application/sherpa_tts_engine.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/lip_sync_viseme_analyzer.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/speech_playback_clock_emitter.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';
import 'package:maaso/src/core/utils/text_filters.dart';
import 'package:maaso/src/features/agent/application/speech/speech_playback_lease.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:path_provider/path_provider.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/core/services/local_system_voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _wavPlaybackClocks = Expando<SpeechPlaybackClockEmitter>();

/// Maaso-specific TTS engine facade.
///
/// It keeps CPU-heavy neural synthesis and WAV envelope extraction off the UI
/// isolate. The main isolate serializes playback, writes the finished WAV to a
/// temp file, starts audioplayers, and emits lip-sync ticks.
class MaasoTtsPlugin {
  MaasoTtsPlugin({this.agentId, FlutterTts? fallbackTts})
    : _fallbackTts = fallbackTts ?? FlutterTts() {
    _initFallbackTts();
    _wireEmotion();
  }

  final String? agentId;

  /// Ordinary chat playback preference, independent of microphone and vision.
  /// An explicitly authorized typed game turn can use a temporary local gate;
  /// neither that gate nor media playback changes this persisted preference.
  static final RxBool soundEnabled = true.obs;
  static const soundPreferenceKey = 'agent.sound_enabled';
  static final Set<Future<void> Function()> _soundStoppers = {};
  static Future<void> _soundPreferenceTail = Future<void>.value();
  static int _soundPreferenceRevision = 0;

  static Future<void> loadSoundPreference() async {
    final revision = _soundPreferenceRevision;
    final preferences = await SharedPreferences.getInstance();
    if (revision != _soundPreferenceRevision) return;
    soundEnabled.value = preferences.getBool(soundPreferenceKey) ?? true;
  }

  /// Registers another agent speech backend with the same mute barrier.
  /// Its stop callback must fence callbacks synchronously before awaiting I/O.
  static VoidCallback registerSoundStopper(Future<void> Function() stop) {
    _soundStoppers.add(stop);
    return () => _soundStoppers.remove(stop);
  }

  static Future<void> setSoundEnabled(bool enabled) {
    final revision = ++_soundPreferenceRevision;
    // Fence speech and lip sync immediately, including queued synthesis. Never
    // resume an old utterance when the user turns sound back on.
    if (!enabled) soundEnabled.value = false;
    final stopping = enabled
        ? Future<void>.value()
        : Future.wait<void>([
            stopAllStrict(),
            for (final stop in _soundStoppers.toList()) Future<void>.sync(stop),
          ]).then<void>((_) {});
    final previous = _soundPreferenceTail;
    final persistence = previous.then<void>((_) async {
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setBool(soundPreferenceKey, enabled)) {
        throw StateError('agent_sound_preference_not_saved');
      }
    });
    // Observe every stop result immediately, even while an earlier preference
    // write is still pending. A failed backend must not escape as an unhandled
    // asynchronous error or prevent the off preference from being saved.
    final operation = Future.wait<void>([stopping, persistence]).then<void>((
      _,
    ) {
      if (revision == _soundPreferenceRevision) soundEnabled.value = enabled;
    });
    _soundPreferenceTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static AudioPlayer _player = AudioPlayer();
  static bool _playerRetirementFailed = false;
  static Future<void>? _speakQueueTail;
  static int _speakGeneration = 0;
  static int _playbackClockSequence = 0;
  static _FallbackSpeechOwner? _activeFallbackSpeech;
  static Future<void>? _typedQueueTail;
  static final Set<_SpeechUtterance> _typedUtterances = {};
  static _SpeechUtterance? _activeTypedUtterance;
  static final Set<MaasoTtsTurn> _scopedSpeechTurns = {};

  /// Avatar events can follow a specifically authorized game turn while the
  /// ordinary-chat preference remains muted. This never authorizes other TTS.
  static bool permitsPlaybackEvents(String? agentId) {
    if (soundEnabled.value) return true;
    _scopedSpeechTurns.removeWhere((turn) => !turn._ownsGeneration);
    return _scopedSpeechTurns
        .toList(growable: false)
        .any(
          (turn) =>
              (turn._plugin.agentId ?? 'self') == (agentId ?? 'self') &&
              turn._allowsSpeech,
        );
  }

  final Set<MaasoTtsTurn> _speechTurns = {};
  bool _disposed = false;

  /// Captures control of the typed WAV utterance that owns playback now.
  ///
  /// The returned capability is bound to this exact utterance and generation.
  /// It becomes a no-op as soon as another utterance owns output. Legacy system
  /// TTS is intentionally not exposed because it has no correlated playback
  /// identity.
  static SpeechPlaybackLease? captureCurrentTypedPlayback({String? agentId}) {
    final utterance = _activeTypedUtterance;
    if (utterance == null ||
        (agentId != null && utterance._turn._plugin.agentId != agentId)) {
      return null;
    }
    final lease = utterance._playbackLease;
    return _ownsCurrentTypedPlayback(lease) ? lease : null;
  }

  /// Freezes the backend and voice once for a logical reply. This does not
  /// synthesize or interrupt audio; each published unit joins the normal queue.
  MaasoTtsTurn openTurn({
    required String turnId,
    required String text,
    bool Function()? canSpeak,
    Duration startTimeout = const Duration(seconds: 30),
  }) {
    if (_disposed) throw StateError('tts_plugin_disposed');
    if (turnId.trim().isEmpty) throw ArgumentError.value(turnId, 'turnId');
    if (startTimeout <= Duration.zero) {
      throw ArgumentError.value(startTimeout, 'startTimeout');
    }
    final hasChinese = RegExp(r'[一-龥]').hasMatch(text);
    final language = RegExp(r'[ぁ-んァ-ン]').hasMatch(text)
        ? 'ja'
        : RegExp(r'[가-힯]').hasMatch(text)
        ? 'ko'
        : hasChinese
        ? 'zh'
        : 'en';
    final registered = TTSEngineRegistry.current;
    final engine =
        registered != null && (!hasChinese || registered is MaasoProxyTtsEngine)
        ? registered
        : null;
    final avatarVoice = appServices
        .maybeFind<AvatarConfigService>()
        ?.voicePreferences;
    final local = engine is SherpaTtsEngine
        ? appServices.maybeFind<SherpaNeuralTts>()
        : null;
    final turn = MaasoTtsTurn._(
      this,
      turnId,
      _speakGeneration,
      startTimeout,
      _TurnVoice(
        engine: engine,
        language: language,
        voice: engine == null
            ? null
            : resolveAvatarAwareTtsVoice(
                engine: engine,
                avatarVoice: avatarVoice,
                configuredVoice: AgentConfig().getApiKey('TTS_VOICE_STYLE'),
              ),
        speed: _neuralSpeed(),
        local: local,
        localSid: local?.voiceSid.value,
      ),
      canSpeak,
    );
    _speechTurns.removeWhere((entry) => entry._settled);
    _speechTurns.add(turn);
    _scopedSpeechTurns.removeWhere(
      (entry) => entry._settled || !entry._ownsGeneration,
    );
    if (canSpeak != null) _scopedSpeechTurns.add(turn);
    return turn;
  }

  /// Releases this facade's listener and its own output leases only. Physical
  /// synthesis cleanup stays available on the turn/utterance [drained] future.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait<void>([
      if (_emotionSub != null) _emotionSub!.cancel(),
      for (final turn in _speechTurns) turn.cancel('plugin_disposed'),
    ]);
    _speechTurns.clear();
  }

  SpeechUtteranceHandle _enqueueUtterance(
    MaasoTtsTurn turn,
    String utteranceId,
    String text,
  ) {
    final spoken = _normalizeSpokenText(text);
    final utterance = _SpeechUtterance(turn, utteranceId, spoken);
    turn._utterances.add(utterance);
    if (!utterance._mayPlay) {
      utterance._finish(SpeechTerminal.cancelled);
      utterance._finishDrain();
      return utterance;
    }
    // flutter_tts callbacks share a global channel and have no utterance ID.
    // Its estimated timer and uncorrelated start cannot certify this contract.
    // Keep legacy system speech intact and let typed delivery use text instead.
    if (spoken.isEmpty ||
        turn._voice.engine == null ||
        _playerRetirementFailed) {
      utterance._finish(SpeechTerminal.failed);
      utterance._finishDrain();
      return utterance;
    }
    _typedUtterances.add(utterance);
    utterance._startDeadline = Timer(turn._startTimeout, () {
      unawaited(utterance._terminate(SpeechTerminal.timedOut));
    });
    final queued = _enqueueSpeak(
      () => _speakUtterance(utterance, spoken),
      canSpeak: () => utterance._mayPlay,
    );
    _typedQueueTail = queued;
    void release() {
      _typedUtterances.remove(utterance);
      if (identical(_typedQueueTail, queued)) _typedQueueTail = null;
      if (!utterance._terminal.isCompleted) {
        utterance._finish(SpeechTerminal.cancelled);
      }
      utterance._finishDrain();
    }

    unawaited(
      queued.then<void>(
        (_) => release(),
        onError: (Object error, StackTrace stack) {
          utterance._cleanupError ??= error;
          utterance._cleanupStack ??= stack;
          utterance._finish(SpeechTerminal.failed);
          release();
        },
      ),
    );
    return utterance;
  }

  Future<void> _speakUtterance(_SpeechUtterance utterance, String text) async {
    if (!utterance._mayPlay) return;
    if (_playerRetirementFailed) {
      utterance._finish(SpeechTerminal.failed);
      return;
    }
    utterance._running = true;
    final voice = utterance._turn._voice;
    final engine = voice.engine!;
    TurnTrace.event(
      'tts.utterance.synth',
      details:
          'turn=${utterance.turnId} utterance=${utterance.utteranceId} chars=${text.length}',
    );
    try {
      final ready = engine.isReady || await engine.warmUp();
      if (!utterance._mayPlay) return;
      if (!ready) {
        utterance._finish(SpeechTerminal.failed);
        return;
      }
      final _SynthClip clip;
      final local = voice.local;
      if (local != null) {
        // SherpaTtsEngine's legacy voice argument is ignored; use the existing
        // service's explicit sid parameter to preserve this turn's snapshot.
        final audio = await local.synthesizeToWavWithEnvelope(
          text,
          lang: voice.language,
          sid: voice.localSid,
          speed: voice.speed,
        );
        if (!utterance._mayPlay) return;
        final track = await Isolate.run(
          () => LipSyncVisemeAnalyzer.analyzeWav(audio.wav),
        );
        clip = _SynthClip(wav: audio.wav, track: track);
      } else {
        clip = await _synthesizeOffMain(
          engine,
          text,
          language: voice.language,
          voice: voice.voice,
          speed: voice.speed,
        );
      }
      if (!utterance._mayPlay) return;
      _activeTypedUtterance = utterance;
      utterance._outputPlayer = _player;
      final playback = await _startWavPlayback(
        clip.wav,
        track: clip.track,
        generation: utterance._turn._generation,
        utterance: utterance,
      );
      await playback.done;
    } catch (error) {
      TurnTrace.event(
        'tts.utterance.failed',
        details:
            'turn=${utterance.turnId} utterance=${utterance.utteranceId} type=${error.runtimeType}',
      );
      await utterance._terminate(SpeechTerminal.failed);
    } finally {
      await utterance._stopFuture;
      if (identical(_activeTypedUtterance, utterance)) {
        if (utterance._turn._generation == _speakGeneration) {
          EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
          EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        }
        final oldPlayer = utterance._outputPlayer!;
        try {
          // Platform completion messages identify a player, not a source.
          // Retire this sole player before creating the next incarnation so
          // an old native completion/seek tail cannot reach a new utterance.
          await oldPlayer.dispose();
          if (identical(_player, oldPlayer)) _player = AudioPlayer();
        } catch (error, stack) {
          _playerRetirementFailed = true;
          utterance._cleanupError ??= error;
          utterance._cleanupStack ??= stack;
        } finally {
          if (identical(_activeTypedUtterance, utterance)) {
            _activeTypedUtterance = null;
          }
        }
      }
    }
  }

  static Future<void> _stopUtterance(_SpeechUtterance utterance) async {
    if (!identical(_activeTypedUtterance, utterance)) return;
    _wavPlaybackClocks[utterance._outputPlayer!]?.stop();
    EventBus().fire(
      SpeakingStatusEvent(false, agentId: utterance._turn._plugin.agentId),
    );
    EventBus().fire(
      LipSyncAmplitudeEvent(0, agentId: utterance._turn._plugin.agentId),
    );
    await utterance._outputPlayer!.stop();
  }

  static bool _ownsCurrentTypedPlayback(_TypedWavPlaybackLease lease) {
    final utterance = lease._utterance;
    return lease.generation == _speakGeneration &&
        lease.generation == utterance._turn._generation &&
        identical(_activeTypedUtterance, utterance) &&
        identical(utterance._outputPlayer, _player) &&
        utterance._didStart &&
        utterance._mayPlay;
  }

  static Future<bool> _pauseTypedPlayback(_TypedWavPlaybackLease lease) async {
    if (!_ownsCurrentTypedPlayback(lease)) return false;
    final player = lease._utterance._outputPlayer!;
    await player.pause();
    if (!_ownsCurrentTypedPlayback(lease)) return false;
    EventBus().fire(SpeakingStatusEvent(false, agentId: lease.agentId));
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: lease.agentId));
    return true;
  }

  static Future<bool> _resumeTypedPlayback(_TypedWavPlaybackLease lease) async {
    if (!_ownsCurrentTypedPlayback(lease)) return false;
    final player = lease._utterance._outputPlayer!;
    await player.resume();
    if (!_ownsCurrentTypedPlayback(lease)) return false;
    EventBus().fire(SpeakingStatusEvent(true, agentId: lease.agentId));
    return true;
  }

  static Future<bool> _stopTypedPlayback(
    _TypedWavPlaybackLease lease,
    String reason,
  ) async {
    if (!_ownsCurrentTypedPlayback(lease)) return false;
    await lease._utterance.cancel(reason);
    return true;
  }

  /// Test seam: lets tests assert pause/resume do not advance the generation.
  @visibleForTesting
  static int get debugSpeakGeneration => _speakGeneration;

  final FlutterTts _fallbackTts;

  // ───────────────── Emotion → voice prosody ─────────────────
  // The agent fires setEmotion (an EmotionStateEvent) right before speaking
  // each turn; we cache the latest so the very next utterance is delivered in
  // that mood.  Supertonic exposes no emotion API, so we colour the voice
  // through pace (neural speed) and, on the fallback engine, rate + pitch.
  // Held for a future dispose. The facade lives for the whole session, so the
  // listener stays active.
  // ignore: unused_field
  StreamSubscription? _emotionSub;
  String? _emotionLabel;
  double _emotionIntensity = 1.0;

  /// Neutral baseline pace — normal speaking rate.  Emotion nudges the voice
  /// a little faster/slower around this, but the default delivery is 1.0×.
  static const double _neutralSpeed = 1.0;

  void _wireEmotion() {
    _emotionSub = EventBus().on<EmotionStateEvent>().listen((e) {
      // Untagged events are global; tagged ones must match our agent.
      if (e.agentId != null && e.agentId != agentId) return;
      _emotionLabel = e.semanticLabel;
      _emotionIntensity = e.params.intensity;
    });
  }

  /// Pace for the neural engine, blended from neutral toward the emotion's
  /// target by [intensity] (so "a little happy" speeds up less than "thrilled").
  double _neuralSpeed() {
    // Centered on 1.0 (normal speed) with a small spread, so the voice keeps a
    // touch of mood colour without the old "everything sounds rushed" 1.25
    // baseline.
    final target = switch (_emotionLabel) {
      'excited' => 1.15,
      'surprised' => 1.13,
      'fear' => 1.12,
      'angry' => 1.10,
      'happy' => 1.10,
      'wink' => 1.06,
      'thinking' => 0.98,
      'calm' => 0.97,
      'love' => 0.97,
      'confused' => 0.97,
      'shy' => 0.96,
      'sad' => 0.93,
      'sleeping' => 0.90,
      'bored' => 0.96,
      _ => _neutralSpeed, // neutral / unknown
    };
    final t = _emotionIntensity.clamp(0.0, 1.0);
    return (_neutralSpeed + (target - _neutralSpeed) * t).clamp(0.85, 1.25);
  }

  /// (rate, pitch) for the system fallback engine, same intensity blend.
  /// flutter_tts rate is ~0..1 (0.5 ≈ normal), pitch ~0.5..2.0.
  (double, double) _fallbackProsody() {
    // Rate stays centered on flutter_tts' normal 0.5 with only a small spread
    // (normal speaking pace, per the same "speak normally" rule as the neural
    // engine); emotional colour rides mostly on pitch.
    const baseRate = 0.5;
    const basePitch = 1.2;
    final (tRate, tPitch) = switch (_emotionLabel) {
      'excited' => (0.54, 1.45),
      'surprised' => (0.53, 1.40),
      'fear' => (0.53, 1.40),
      'happy' => (0.52, 1.35),
      'angry' => (0.53, 1.05),
      'wink' => (0.51, 1.35),
      'love' => (0.49, 1.25),
      'shy' => (0.49, 1.30),
      'confused' => (0.49, 1.15),
      'calm' => (0.49, 1.10),
      'thinking' => (0.48, 1.10),
      'bored' => (0.48, 1.00),
      'sad' => (0.47, 1.00),
      'sleeping' => (0.46, 0.95),
      _ => (baseRate, basePitch), // neutral / unknown
    };
    final t = _emotionIntensity.clamp(0.0, 1.0);
    final genderPitchFactor =
        appServices.isRegistered<AvatarConfigService>() &&
            appServices
                    .find<AvatarConfigService>()
                    .voicePreferences
                    .voiceGender
                    .value ==
                AvatarVoiceGender.male
        ? 0.78
        : 1.0;
    return (
      baseRate + (tRate - baseRate) * t,
      ((basePitch + (tPitch - basePitch) * t) * genderPitchFactor)
          .clamp(0.5, 2.0)
          .toDouble(),
    );
  }

  /// Interrupts queued speech for normal turn changes. Platform stop failures
  /// remain best-effort so a transient audio backend issue never blocks chat.
  static Future<void> stopAll({String? agentId}) =>
      _stopAll(agentId: agentId, strict: false);

  /// Teardown-only variant. A failed platform stop is propagated so account
  /// switching remains fail-closed and the lease can retry the same player.
  static Future<void> stopAllStrict({String? agentId}) =>
      _stopAll(agentId: agentId, strict: true);

  static Future<void> _stopAll({
    required String? agentId,
    required bool strict,
  }) async {
    final playerAtStop = _player;
    // Revoke presentation before awaiting a native stop acknowledgement. A
    // stalled platform cannot keep an old utterance's gestures running.
    _wavPlaybackClocks[playerAtStop]?.stop();
    final typedOwner = _activeTypedUtterance;
    final typedStop = typedOwner == null ? null : Completer<void>();
    if (typedStop != null) typedOwner!._observeStop(typedStop.future);
    _speakGeneration++;
    _scopedSpeechTurns.clear();
    // A cancelled neural request cannot be aborted by TTSEngine. Preserve its
    // physical queue slot so a new turn cannot synthesize in parallel with it.
    _speakQueueTail = _typedQueueTail;
    for (final utterance in _typedUtterances.toList()) {
      utterance._finish(SpeechTerminal.cancelled);
    }
    final fallback = _activeFallbackSpeech;
    fallback?.completionTimer?.cancel();
    TurnTrace.event(
      'tts.abort',
      details: 'agent=$agentId generation=$_speakGeneration',
    );
    // Clear this generation synchronously. A delayed stop acknowledgement must
    // not close the mouth or erase the owner of a newer fallback utterance.
    EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
    Object? firstError;
    StackTrace? firstStack;
    Future<void> stopOutput(Future<void> Function() stop, String output) async {
      try {
        await stop();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        Log.w(
          '🛑 [MaasoTTS] stopAll $output stop failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await Future.wait<void>([
      stopOutput(playerAtStop.stop, 'platform'),
      if (fallback != null)
        stopOutput(() async {
          await fallback.player.stop();
          if (identical(_activeFallbackSpeech, fallback)) {
            _activeFallbackSpeech = null;
          }
        }, 'system'),
    ]);
    if (typedStop != null) {
      if (firstError == null) {
        typedStop.complete();
      } else {
        typedStop.completeError(firstError!, firstStack!);
      }
    }
    if (strict && firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  /// Start of a fresh user turn: discard any old utterance still synthesizing,
  /// queued, or playing so the next reply is not heard one turn late.
  static Future<void> prepareForNewTurn({String? agentId}) =>
      stopAll(agentId: agentId);

  /// Pause the currently-playing reply WITHOUT cancelling it. Unlike [stopAll],
  /// this does not advance [_speakGeneration] or clear [_speakQueueTail], so the
  /// in-flight synth/play task stays alive (audioplayers `pause()` yields
  /// PlayerState.paused, not completed/stopped, so its completer stays pending).
  /// Used by voice barge-in to hold the reply while the user speaks.
  static Future<void> pause({String? agentId}) async {
    await _player.pause();
    EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
  }

  /// Resume a reply paused by [pause], continuing the same clip from where it
  /// stopped.
  static Future<void> resume({String? agentId}) async {
    if (_activeTypedUtterance != null) {
      final lease = captureCurrentTypedPlayback(agentId: agentId);
      if (lease != null) await lease.resume();
      return;
    }
    if (!soundEnabled.value) return;
    final generation = _speakGeneration;
    await _player.resume();
    if (!soundEnabled.value || generation != _speakGeneration) return;
    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
  }

  static Future<void> _enqueueSpeak(
    Future<void> Function() task, {
    bool Function()? canSpeak,
  }) {
    bool permitted() => canSpeak?.call() ?? soundEnabled.value;
    if (!permitted()) return Future<void>.value();
    final generation = _speakGeneration;
    final prev = _speakQueueTail ?? Future.value();
    final next = prev.catchError((_) {}).then((_) async {
      if (!permitted() || generation != _speakGeneration) {
        TurnTrace.event(
          'tts.queue.drop',
          details: 'generation=$generation current=$_speakGeneration',
        );
        return;
      }
      await task();
    });
    _speakQueueTail = next;
    return next;
  }

  Future<void> _initFallbackTts() async {
    await _fallbackTts.setSpeechRate(0.5);
    await _fallbackTts.setPitch(1.2);

    // NOTE: the speaking lifecycle (SpeakingStatusEvent) is driven explicitly
    // inside _speakWithFallback, NOT from these handlers.  _speakBestEffort
    // builds a throwaway plugin and speaks before this async init finishes, so
    // these handlers often weren't registered in time — the avatar then never
    // saw isSpeaking=true and stayed mouth-closed / un-framed even though audio
    // played.  Keep the handlers for logging only.
    _fallbackTts.setStartHandler(
      () => Log.i('🗣️ [MaasoTTS/sys] start trace=${TurnTrace.currentId}'),
    );
    _fallbackTts.setCompletionHandler(
      () => Log.i('🤐 [MaasoTTS/sys] done trace=${TurnTrace.currentId}'),
    );
    _fallbackTts.setCancelHandler(
      () => Log.w('🛑 [MaasoTTS/sys] cancelled trace=${TurnTrace.currentId}'),
    );
    _fallbackTts.setErrorHandler(
      (msg) => Log.e('❌ [MaasoTTS/sys] error: $msg'),
    );

    try {
      if (Platform.isAndroid) {
        await _fallbackTts.setQueueMode(1);
      } else if (Platform.isIOS) {
        await _fallbackTts
            .setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
              IosTextToSpeechAudioCategoryOptions.allowBluetooth,
              IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
              IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            ]);
      }
    } catch (e) {
      Log.e('⚠️ [MaasoTTS/sys] platform init failed: $e');
    }
  }

  Map<String, dynamic Function(List<dynamic>)> get methods => {'speak': _speak};

  /// Boot-time fallback uses the same playback ownership and mute fence as
  /// normal replies while retaining its controller-owned system TTS instance.
  Future<void> speakSystem(String text) {
    if (!soundEnabled.value || _disposed) return Future<void>.value();
    final spoken = _normalizeSpokenText(text);
    if (spoken.isEmpty) return Future<void>.value();
    final locale = RegExp(r'[一-龥]').hasMatch(spoken)
        ? 'zh-CN'
        : RegExp(r'[ぁ-んァ-ン]').hasMatch(spoken)
        ? 'ja-JP'
        : RegExp(r'[가-힯]').hasMatch(spoken)
        ? 'ko-KR'
        : 'en-US';
    final generation = _speakGeneration;
    return _enqueueSpeak(
      () => _speakWithFallback(spoken, locale, generation: generation),
    );
  }

  dynamic _speak(List<dynamic> args) {
    if (args.isEmpty) return '{"error":"missing_text"}';
    if (!soundEnabled.value) return '{"status":"muted"}';

    final safeText = stripEmoji(
      args[0]
          .toString()
          .replaceAll('\n', ' ')
          .replaceAll('\r', ' ')
          .replaceAll('*', '')
          .replaceAll('#', ''),
    );

    // ignore: unawaited_futures
    TurnTrace.event(
      'tts.enqueue',
      details: 'agent=$agentId chars=${safeText.length}',
    );
    if (safeText.trim().isNotEmpty) {
      EventBus().fire(AgentSpeechQueuedEvent(safeText, agentId: agentId));
    }
    final generation = _speakGeneration;
    _enqueueSpeak(() => _speakWithLanguageDetection(safeText, generation));
    return '{"status": "success"}';
  }

  Future<void> _speakWithLanguageDetection(String text, int generation) async {
    if (generation != _speakGeneration) return;
    final hasChinese = RegExp(r'[一-龥]').hasMatch(text);
    final hasJapanese = RegExp(r'[ぁ-んァ-ン]').hasMatch(text);
    final hasKorean = RegExp(r'[가-힯]').hasMatch(text);

    final engine = TTSEngineRegistry.current;
    if (engine != null && (!hasChinese || engine is MaasoProxyTtsEngine)) {
      final lang = hasJapanese
          ? 'ja'
          : hasKorean
          ? 'ko'
          : hasChinese
          ? 'zh'
          : 'en';
      await _speakWithEngine(text, language: lang, generation: generation);
      return;
    }

    final locale = hasChinese
        ? 'zh-CN'
        : hasJapanese
        ? 'ja-JP'
        : hasKorean
        ? 'ko-KR'
        : 'en-US';
    await _speakWithFallback(text, locale, generation: generation);
  }

  Future<void> _speakWithEngine(
    String text, {
    required String language,
    required int generation,
  }) async {
    if (generation != _speakGeneration) return;
    final traceSw = TurnTrace.stopwatch(
      'tts.engine',
      details: 'agent=$agentId lang=$language chars=${text.length}',
    );
    final engine = TTSEngineRegistry.current!;
    final ready = engine.isReady ? true : await engine.warmUp();
    if (!soundEnabled.value || generation != _speakGeneration) return;
    if (!ready) {
      TurnTrace.event('tts.engine.fallback', details: 'reason=not_ready');
      await _speakWithFallback(text, 'en-US', generation: generation);
      TurnTrace.done('tts.engine', traceSw, details: 'fallback=not_ready');
      return;
    }
    final voice = resolveAvatarAwareTtsVoice(
      engine: engine,
      avatarVoice: appServices.isRegistered<AvatarConfigService>()
          ? appServices.find<AvatarConfigService>().voicePreferences
          : null,
      configuredVoice: AgentConfig().getApiKey('TTS_VOICE_STYLE'),
    );
    final spoken = text.trim();
    if (spoken.isEmpty) {
      TurnTrace.done('tts.engine', traceSw, details: 'skip=empty');
      return;
    }

    // Snapshot the mood once for the whole utterance.
    final speed = _neuralSpeed();

    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    try {
      TurnTrace.event(
        'tts.engine.start',
        details:
            'agent=$agentId lang=$language chars=${spoken.length} '
            'emotion=${_emotionLabel ?? "neutral"} '
            'speed=${speed.toStringAsFixed(2)}',
      );
      Log.i(
        '🗣️ [MaasoTTS/engine] $language synth/play '
        '(${spoken.length} chars, emotion=${_emotionLabel ?? "neutral"} '
        'speed=${speed.toStringAsFixed(2)})',
      );

      // The reply publisher already owns bubble boundaries. Do not split its
      // paragraph a second time into short, audibly disconnected clips.
      final synthSw = TurnTrace.stopwatch(
        'tts.synth',
        details: 'agent=$agentId chars=${spoken.length}',
      );
      final clip = await _synthesizeOffMain(
        engine,
        spoken,
        language: language,
        voice: voice,
        speed: speed,
      );
      TurnTrace.done('tts.synth', synthSw);
      if (!soundEnabled.value || generation != _speakGeneration) {
        TurnTrace.done('tts.engine', traceSw, details: 'aborted=before_play');
        return;
      }
      TurnTrace.event(
        'tts.audio.start',
        details: 'agent=$agentId chars=${spoken.length}',
      );
      final playback = await _startWavPlayback(
        clip.wav,
        track: clip.track,
        generation: generation,
      );
      await playback.done;
      if (generation != _speakGeneration) {
        TurnTrace.done('tts.engine', traceSw, details: 'aborted=after_play');
        return;
      }

      EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));

      Log.i('🤐 [MaasoTTS/engine] done');
      TurnTrace.done('tts.engine', traceSw, details: 'chars=${spoken.length}');
    } catch (e) {
      TurnTrace.event('tts.engine.error', details: 'error=$e');
      Log.e('❌ [MaasoTTS/engine] synth/play failed: $e');
      if (e is PrivacyException) rethrow;
      await _speakWithFallback(text, 'en-US', generation: generation);
      TurnTrace.done('tts.engine', traceSw, details: 'fallback=error');
    } finally {
      if (generation == _speakGeneration) {
        EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
        EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
      }
    }
  }

  Future<_SynthClip> _synthesizeOffMain(
    TTSEngine engine,
    String text, {
    required String language,
    String? voice,
    double? speed,
  }) async {
    if (engine is SherpaTtsEngine) {
      final clip = await engine.synthesizeToWavWithEnvelope(
        text,
        language: language,
        voice: voice,
        speed: speed,
      );
      final track = await Isolate.run(
        () => LipSyncVisemeAnalyzer.analyzeWav(clip.wav),
        debugName: 'tts_viseme_worker',
      );
      return _SynthClip(wav: clip.wav, track: track);
    }

    final wav = await engine.synthesizeToWav(
      text,
      language: language,
      voice: voice,
    );
    final track = await Isolate.run(
      () => LipSyncVisemeAnalyzer.analyzeWav(wav),
      debugName: 'tts_viseme_worker',
    );
    return _SynthClip(wav: wav, track: track);
  }

  Future<({Future<void> done})> _startWavPlayback(
    Uint8List bytes, {
    required LipSyncVisemeTrack track,
    required int generation,
    _SpeechUtterance? utterance,
  }) async {
    final envelope = track.envelope;
    final playbackPlayer = utterance?._outputPlayer ?? _player;
    bool mayPlay() =>
        generation == _speakGeneration &&
        (utterance == null ? soundEnabled.value : utterance._mayPlay);
    if (!mayPlay()) return (done: Future<void>.value());
    final sw = TurnTrace.stopwatch(
      'tts.audio.play',
      details:
          'bytes=${bytes.length} envelope=${envelope.length} '
          'visemes=${track.cues.length}',
    );

    await playbackPlayer.stop();
    if (!mayPlay()) return (done: Future<void>.value());

    final playbackId = 'wav-${++_playbackClockSequence}';
    final clock = SpeechPlaybackClockEmitter(
      playbackId: playbackId,
      nativeGeneration: generation,
      turnId: utterance?.turnId ?? playbackId,
      utteranceId: utterance?.utteranceId ?? playbackId,
      source: SpeechPlaybackClockSource.wav,
      agentId: agentId,
    );
    _wavPlaybackClocks[playbackPlayer] = clock;
    // The default audioplayers updater polls once per Flutter frame. Speech
    // calibration needs at most four real cursor receipts per second, and
    // never more than one native position query in flight.
    playbackPlayer.positionUpdater = _SpeechPositionUpdater(
      getPosition: () async {
        if (!mayPlay()) return null;
        final position = await playbackPlayer.getCurrentPosition();
        return mayPlay() ? position : null;
      },
    );

    // audioplayers writes BytesSource to a provider-managed temporary file on
    // these platforms. The provider may return an absent cache directory,
    // especially a fresh macOS sandbox, and the package does not create it.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      final directory = await getTemporaryDirectory();
      if (!mayPlay()) return (done: Future<void>.value());
      await directory.create(recursive: true);
      if (!mayPlay()) return (done: Future<void>.value());
    }

    final completer = Completer<SpeechTerminal>();
    Timer? watchdog;
    var remaining = _playbackCompletionTimeout(
      bytes,
      envelope,
      frameRate: track.frameRate,
    );
    DateTime? watchdogStarted;
    void stopWatchdog() {
      watchdog?.cancel();
      watchdog = null;
      final started = watchdogStarted;
      if (started != null) remaining -= DateTime.now().difference(started);
      watchdogStarted = null;
    }

    void startWatchdog() {
      if (watchdog != null || completer.isCompleted) return;
      watchdogStarted = DateTime.now();
      watchdog = Timer(remaining.isNegative ? Duration.zero : remaining, () {
        if (!completer.isCompleted) completer.complete(SpeechTerminal.timedOut);
      });
    }

    final completed = playbackPlayer.onPlayerComplete.listen(
      (_) {
        if (!mayPlay()) return;
        utterance?._markStarted();
        if (!completer.isCompleted) {
          completer.complete(SpeechTerminal.completed);
        }
      },
      onError: (Object _, StackTrace _) {
        if (!completer.isCompleted) completer.complete(SpeechTerminal.failed);
      },
    );
    final sub = playbackPlayer.onPlayerStateChanged.listen((state) {
      if (mayPlay()) {
        if (state == PlayerState.paused) clock.pause();
        if (state == PlayerState.playing) clock.resume();
        if (state == PlayerState.stopped || state == PlayerState.completed) {
          clock.stop();
        }
      }
      if (state == PlayerState.stopped &&
          (utterance == null || !utterance._revoked)) {
        if (!completer.isCompleted) {
          completer.complete(SpeechTerminal.cancelled);
        }
      } else if (utterance != null && state == PlayerState.paused) {
        stopWatchdog();
      } else if (utterance != null && state == PlayerState.playing) {
        startWatchdog();
      }
    });
    final positionSub = playbackPlayer.onPositionChanged.listen((position) {
      if (mayPlay()) clock.observe(position.inMilliseconds);
    });
    try {
      await playbackPlayer.play(BytesSource(bytes, mimeType: 'audio/wav'));
      if (!mayPlay()) {
        if (utterance != null && identical(_activeTypedUtterance, utterance)) {
          utterance._observeStop(playbackPlayer.stop());
          await utterance._stopFuture;
        }
        watchdog?.cancel();
        await completed.cancel();
        await sub.cancel();
        await positionSub.cancel();
        return (done: Future<void>.value());
      }
    } catch (_) {
      watchdog?.cancel();
      await completed.cancel();
      await sub.cancel();
      await positionSub.cancel();
      rethrow;
    }
    if (utterance != null) {
      utterance._markStarted();
      EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    }
    startWatchdog();

    // Hand the WHOLE envelope to the renderer in one shot; the 3D renderer
    // samples it on its own ticker. This replaces the old 30fps Timer that fired
    // a LipSyncAmplitudeEvent + JavaScript bridge call every frame (heat/stutter).
    EventBus().fire(
      LipSyncEnvelopeEvent(
        envelope,
        frameRate: track.frameRate,
        agentId: agentId,
      ),
    );
    EventBus().fire(LipSyncVisemeTrackEvent(track, agentId: agentId));
    clock.start(
      durationMs: _wavDurationMs(bytes),
      envelope: envelope,
      frameRate: track.frameRate,
    );

    final done = () async {
      try {
        final result = utterance == null
            ? await completer.future
            : await Future.any<SpeechTerminal>([
                completer.future,
                utterance.terminal,
              ]);
        if (result == SpeechTerminal.timedOut) {
          TurnTrace.event(
            'tts.audio.play.timeout',
            details: 'generation=$generation',
          );
        }
        if (utterance != null && !utterance._terminal.isCompleted) {
          if (result == SpeechTerminal.completed) {
            utterance._finish(result);
          } else {
            await utterance._terminate(result);
          }
        }
      } finally {
        watchdog?.cancel();
        clock.stop();
        if (identical(_wavPlaybackClocks[playbackPlayer], clock)) {
          _wavPlaybackClocks[playbackPlayer] = null;
        }
        if (generation == _speakGeneration) {
          EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
        }
        await completed.cancel();
        await sub.cancel();
        await positionSub.cancel();
        TurnTrace.done('tts.audio.play', sw);
      }
    }();

    return (done: done);
  }

  static const Duration _playbackCompletionGrace = Duration(seconds: 2);

  Duration _playbackCompletionTimeout(
    Uint8List bytes,
    List<double> envelope, {
    required int frameRate,
  }) {
    final envelopeMs = envelope.isEmpty
        ? null
        : (envelope.length * 1000 / frameRate).ceil();
    final expectedMs = envelopeMs ?? _wavDurationMs(bytes);
    if (expectedMs == null || expectedMs <= 0) {
      return _playbackCompletionGrace;
    }
    return Duration(milliseconds: expectedMs) + _playbackCompletionGrace;
  }

  int? _wavDurationMs(Uint8List wav) {
    if (wav.length < 44 ||
        !_hasAscii(wav, 0, 'RIFF') ||
        !_hasAscii(wav, 8, 'WAVE')) {
      return null;
    }
    final data = ByteData.sublistView(wav);
    int? byteRate;
    int? dataBytes;
    var offset = 12;
    while (offset + 8 <= wav.length) {
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final bodyOffset = offset + 8;
      if (bodyOffset + chunkSize > wav.length) break;

      if (_hasAscii(wav, offset, 'fmt ') && chunkSize >= 16) {
        byteRate = data.getUint32(bodyOffset + 8, Endian.little);
      } else if (_hasAscii(wav, offset, 'data')) {
        dataBytes = chunkSize;
      }

      if (byteRate != null && byteRate > 0 && dataBytes != null) {
        return (dataBytes * 1000 / byteRate).ceil();
      }
      offset = bodyOffset + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    return null;
  }

  bool _hasAscii(Uint8List bytes, int offset, String value) {
    if (offset < 0 || offset + value.length > bytes.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  Future<void> _speakWithFallback(
    String text,
    String locale, {
    required int generation,
  }) async {
    if (generation != _speakGeneration) return;
    final owner = _FallbackSpeechOwner(_fallbackTts, generation);
    _activeFallbackSpeech = owner;
    final traceSw = TurnTrace.stopwatch(
      'tts.system',
      details: 'agent=$agentId locale=$locale chars=${text.length}',
    );
    // Drive the speaking lifecycle explicitly (the system-TTS handlers are
    // logging-only — see _initFallbackTts).  Firing this here is what makes the
    // avatar lip-sync (the mouth overlay is gated on isSpeaking) and frame to a
    // bust shot, even when this runs on a freshly-built throwaway plugin.
    EventBus().fire(SpeakingStatusEvent(true, agentId: agentId));
    final estDurationMs = math.max(800, text.length * 250);
    // System TTS gives us no PCM, so we precompute a synthetic "talking" sine
    // envelope and hand it over once (renderer self-samples it) — same self-
    // consume path as neural TTS, no 30fps bridge. Cleared by SpeakingStatus.
    final synthEnv = <double>[];
    for (var ms = 0; ms < estDurationMs; ms += 33) {
      final phase = ms / 1000.0 * 4 * 2 * math.pi;
      final fade = math
          .min(1.0, math.min(ms / 200, (estDurationMs - ms) / 200))
          .clamp(0.0, 1.0);
      synthEnv.add(((math.sin(phase) + 1) / 2 * 0.7) * fade);
    }
    EventBus().fire(
      LipSyncEnvelopeEvent(synthEnv, frameRate: 30, agentId: agentId),
    );
    final track = LipSyncVisemeAnalyzer.fromTextEnvelope(text, synthEnv);
    EventBus().fire(LipSyncVisemeTrackEvent(track, agentId: agentId));

    try {
      final (rate, pitch) = _fallbackProsody();
      await _fallbackTts.setSpeechRate(rate);
      await _fallbackTts.setPitch(pitch);
      await _fallbackTts.setLanguage(locale);
      if (!await prepareLocalSystemVoice(_fallbackTts, locale)) {
        throw StateError('No installed local system voice is available.');
      }
      if (generation != _speakGeneration) {
        TurnTrace.done('tts.system', traceSw, details: 'aborted=before_speak');
        return;
      }
      TurnTrace.event(
        'tts.system.start',
        details:
            'agent=$agentId locale=$locale rate=${rate.toStringAsFixed(2)} '
            'pitch=${pitch.toStringAsFixed(2)}',
      );
      await _fallbackTts.speak(text);
    } catch (e) {
      TurnTrace.event('tts.system.error', details: 'error=$e');
      Log.e('❌ [MaasoTTS/sys] language/speak failed: $e');
      if (generation == _speakGeneration &&
          identical(_activeFallbackSpeech, owner)) {
        EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
      }
    } finally {
      if (generation == _speakGeneration &&
          identical(_activeFallbackSpeech, owner)) {
        owner.completionTimer = Timer(
          Duration(milliseconds: estDurationMs + 600),
          () {
            if (generation != _speakGeneration ||
                !identical(_activeFallbackSpeech, owner)) {
              return;
            }
            EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
            EventBus().fire(SpeakingStatusEvent(false, agentId: agentId));
            TurnTrace.done('tts.system', traceSw);
          },
        );
      }
    }
  }
}

/// A voice lease for one logical reply, sharing MaasoTtsPlugin's playback queue.
class MaasoTtsTurn implements SpeechTurnHandle {
  MaasoTtsTurn._(
    this._plugin,
    this.turnId,
    this._generation,
    this._startTimeout,
    this._voice,
    this._canSpeak,
  );

  final MaasoTtsPlugin _plugin;
  @override
  final String turnId;
  final int _generation;
  final Duration _startTimeout;
  final _TurnVoice _voice;
  final bool Function()? _canSpeak;
  final List<_SpeechUtterance> _utterances = [];
  bool _cancelled = false;

  bool get _ownsGeneration =>
      !_cancelled &&
      !_plugin._disposed &&
      _generation == MaasoTtsPlugin._speakGeneration;

  bool get _allowsSpeech {
    if (!_ownsGeneration) return false;
    try {
      return _canSpeak?.call() ?? MaasoTtsPlugin.soundEnabled.value;
    } on Object {
      return false;
    }
  }

  bool get _settled =>
      (_cancelled || _utterances.isNotEmpty) &&
      _utterances.every((entry) => entry._drained.isCompleted);

  @override
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  }) {
    if (utteranceId.trim().isEmpty ||
        _utterances.any((entry) => entry.utteranceId == utteranceId)) {
      throw ArgumentError.value(utteranceId, 'utteranceId');
    }
    if (_canSpeak != null && _ownsGeneration) {
      MaasoTtsPlugin._scopedSpeechTurns.add(this);
    }
    return _plugin._enqueueUtterance(this, utteranceId, text);
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) {
    _cancelled = true;
    MaasoTtsPlugin._scopedSpeechTurns.remove(this);
    return Future.wait<void>([
      for (final utterance in _utterances) utterance.cancel(reason),
    ]);
  }

  @override
  Future<void> get drained => Future.wait<void>([
    for (final utterance in _utterances) utterance.drained,
  ]);
}

class _TurnVoice {
  const _TurnVoice({
    required this.engine,
    required this.language,
    required this.voice,
    required this.speed,
    required this.local,
    required this.localSid,
  });
  final TTSEngine? engine;
  final String language;
  final String? voice;
  final double speed;
  final SherpaNeuralTts? local;
  final int? localSid;
}

class _SpeechUtterance implements SpeechUtteranceHandle {
  _SpeechUtterance(this._turn, this.utteranceId, String spokenText) {
    _playbackLease = _TypedWavPlaybackLease._(this, spokenText);
    // Cleanup remains observable without making an ignored drain error an
    // unhandled asynchronous exception for fire-and-forget callers.
    unawaited(
      _drained.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  final MaasoTtsTurn _turn;
  late final _TypedWavPlaybackLease _playbackLease;
  @override
  String get turnId => _turn.turnId;
  @override
  final String utteranceId;
  final Completer<bool> _started = Completer<bool>();
  final Completer<SpeechTerminal> _terminal = Completer<SpeechTerminal>();
  final Completer<void> _drained = Completer<void>();
  Timer? _startDeadline;
  bool _revoked = false;
  bool _running = false;
  bool _didStart = false;
  AudioPlayer? _outputPlayer;
  Future<void> _stopFuture = Future<void>.value();
  Object? _cleanupError;
  StackTrace? _cleanupStack;

  bool get _mayPlay =>
      _turn._allowsSpeech &&
      !_revoked &&
      !_terminal.isCompleted &&
      !_turn._cancelled &&
      !_turn._plugin._disposed &&
      _turn._generation == MaasoTtsPlugin._speakGeneration;

  @override
  Future<bool> get started => _started.future;
  @override
  Future<SpeechTerminal> get terminal => _terminal.future;
  @override
  Future<void> get drained => _drained.future;

  void _markStarted() {
    if (!_mayPlay || _started.isCompleted) return;
    _didStart = true;
    _startDeadline?.cancel();
    _started.complete(true);
    TurnTrace.event(
      'tts.utterance.started',
      details: 'turn=$turnId utterance=$utteranceId',
    );
  }

  void _finish(SpeechTerminal result) {
    if (_terminal.isCompleted) return;
    _revoked = true;
    _startDeadline?.cancel();
    if (!_started.isCompleted) _started.complete(false);
    _terminal.complete(result);
    TurnTrace.event(
      'tts.utterance.terminal',
      details: 'turn=$turnId utterance=$utteranceId result=${result.name}',
    );
  }

  void _observeStop(Future<void> stopping) {
    final observed = stopping.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _cleanupError ??= error;
        _cleanupStack ??= stack;
      },
    );
    _stopFuture = Future.wait<void>([_stopFuture, observed]);
  }

  Future<void> _terminate(SpeechTerminal result) async {
    if (_terminal.isCompleted) return;
    _revoked = true;
    _startDeadline?.cancel();
    if (identical(MaasoTtsPlugin._activeTypedUtterance, this)) {
      _observeStop(MaasoTtsPlugin._stopUtterance(this));
      await _stopFuture;
    }
    _finish(result);
    if (!_running) _finishDrain();
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) {
    if (_terminal.isCompleted) return _stopFuture;
    _finish(SpeechTerminal.cancelled);
    if (identical(MaasoTtsPlugin._activeTypedUtterance, this)) {
      _observeStop(MaasoTtsPlugin._stopUtterance(this));
    }
    if (!_running) _finishDrain();
    return _stopFuture;
  }

  void _finishDrain() {
    if (_drained.isCompleted) return;
    final error = _cleanupError;
    if (error == null) {
      _drained.complete();
    } else {
      _drained.completeError(error, _cleanupStack);
    }
  }
}

/// Native playback is the only position source. A slow platform query cannot
/// accumulate calibration work, and no Flutter frame ticker is installed.
final class _SpeechPositionUpdater extends PositionUpdater {
  _SpeechPositionUpdater({required super.getPosition});

  Timer? _timer;
  bool _inFlight = false;

  @override
  Future<void> update() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      await super.update();
    } catch (_) {
      // Missing calibration never delays or fails the existing audio lease.
    } finally {
      _inFlight = false;
    }
  }

  @override
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(SpeechPlaybackClockEmitter.updateInterval, (_) {
      unawaited(update());
    });
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

final class _TypedWavPlaybackLease implements SpeechPlaybackLease {
  _TypedWavPlaybackLease._(this._utterance, this.spokenText)
    : generation = _utterance._turn._generation;

  final _SpeechUtterance _utterance;

  @override
  final int generation;
  @override
  String get turnId => _utterance.turnId;
  @override
  String get utteranceId => _utterance.utteranceId;
  @override
  String? get agentId => _utterance._turn._plugin.agentId;
  @override
  final String spokenText;

  @override
  Future<bool> pause() => MaasoTtsPlugin._pauseTypedPlayback(this);

  @override
  Future<bool> resume() => MaasoTtsPlugin._resumeTypedPlayback(this);

  @override
  Future<bool> stop([String reason = 'interrupted']) =>
      MaasoTtsPlugin._stopTypedPlayback(this, reason);
}

class _FallbackSpeechOwner {
  _FallbackSpeechOwner(this.player, this.generation);

  final FlutterTts player;
  final int generation;
  Timer? completionTimer;
}

@visibleForTesting
String? resolveAvatarAwareTtsVoice({
  required TTSEngine engine,
  required AvatarVoiceService? avatarVoice,
  required String? configuredVoice,
}) {
  if (engine is MaasoProxyTtsEngine) {
    return avatarVoice?.cloudVoiceId ?? configuredVoice;
  }
  return configuredVoice;
}

String _normalizeSpokenText(String text) => stripEmoji(
  text.replaceAll(RegExp(r'[\r\n*#]'), ' '),
).replaceAll(RegExp(r'\s+'), ' ').trim();

class _SynthClip {
  const _SynthClip({required this.wav, required this.track});

  final Uint8List wav;
  final LipSyncVisemeTrack track;
}
