import 'dart:async';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_emotion_timeline.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/core/services/turn_trace.dart';

/// Keeps the on-screen self avatar synced when chat is running in the
/// local-only fallback path.
///
/// Normal cloud/runtime turns are handled by [AgentRuntime] itself — it
/// owns the EventBus-to-avatar wiring for emotion, speech, lip-sync and
/// framing.  But when no cloud key exists there is no AgentRuntime alive,
/// so the [HomeController] answers via LocalBrainService + ReflexEngine and
/// nothing consumes the avatar-driving events.  This bridge fills that gap:
/// it shadows [AgentRuntime]'s `_wireEventBus` / `_applyEffective` for the
/// `self` agent, but only acts while the runtime does NOT own the avatar
/// (see [_runtimeOwnsAvatar]).  The moment a cloud runtime spins up, every
/// handler here no-ops and AgentRuntime takes back over.
class SelfAvatarBridge extends AppService {
  StreamSubscription? _emotionSub;
  StreamSubscription? _emotionResetSub;
  StreamSubscription? _memeSub;
  StreamSubscription? _speechSub;
  StreamSubscription? _lipSub;
  StreamSubscription? _lipEnvelopeSub;
  StreamSubscription? _visemeTrackSub;
  StreamSubscription? _playbackClockSub;
  Worker? _avatarReadyWorker;
  Worker? _avatarBackendWorker;
  Timer? _framingRevertTimer;

  /// The agent's intended mood, before any TTS mouth overlay.  Mirrors
  /// AgentRuntime._baseEmotion so the mouth can decay back cleanly when
  /// speech stops.
  late final AvatarEmotionTimeline _emotions = AvatarEmotionTimeline(
    onRestored: _applyEffective,
  );
  EmotionParams get _baseEmotion => _emotions.value;
  bool _isSpeaking = false;
  bool _loggedLip = false;

  static const _framingRevertDelay = Duration(seconds: 12);

  @override
  void onInit() {
    super.onInit();
    // Preferred: rich continuous params from the local brain's emotion
    // preemit (BrainRouter fires EmotionStateEvent) or any setEmotion.
    _emotionSub = EventBus()
        .on<EmotionStateEvent>()
        .where(_isSelfEvent)
        .listen(_onEmotion);
    _emotionResetSub = EventBus()
        .on<AvatarEmotionResetEvent>()
        .where(_isSelfEvent)
        .listen((_) => _emotions.cancelTransient());
    _memeSub = EventBus()
        .on<SendMemeEvent>()
        .where(_isSelfEvent)
        .listen(_onMeme);
    _speechSub = EventBus()
        .on<SpeakingStatusEvent>()
        .where(_isSelfEvent)
        .listen(_onSpeakingStatus);
    _lipSub = EventBus()
        .on<LipSyncAmplitudeEvent>()
        .where(_isSelfEvent)
        .listen(_onLipSync);
    _lipEnvelopeSub = EventBus()
        .on<LipSyncEnvelopeEvent>()
        .where(_isSelfEvent)
        .listen(_onLipSyncEnvelope);
    _visemeTrackSub = EventBus()
        .on<LipSyncVisemeTrackEvent>()
        .where(_isSelfEvent)
        .listen(_onVisemeTrack);
    _playbackClockSub = EventBus()
        .on<SpeechPlaybackClockEvent>()
        .where(_isSelfEvent)
        .listen(_onSpeechPlaybackClock);

    // Push the current mood the moment the avatar runtime reports ready;
    // otherwise a preemit that fired before the model loaded is lost and
    // otherwise a preemit that fired before the model loaded is lost.
    if (appServices.isRegistered<ActiveAvatarRuntime>()) {
      final active = appServices.find<ActiveAvatarRuntime>();
      _bindAvatarReady(active.current);
      _avatarBackendWorker = ever<AvatarBackendKind>(active.backend, (_) {
        _bindAvatarReady(active.current);
        if (!_runtimeOwnsAvatar) _applyEffective();
      });
    }
  }

  bool _isSelfEvent(ClawEvent e) => e.agentId == null || e.agentId == 'self';

  /// When a cloud runtime exists it owns the avatar end-to-end; this bridge
  /// stays out of the way so we never double-drive avatar params.
  bool get _runtimeOwnsAvatar {
    if (AvatarProductionOwnership.ownsRenderer) return true;
    if (!appServices.isRegistered<AgentRuntimeRegistry>()) return false;
    return appServices.find<AgentRuntimeRegistry>().get('self') != null;
  }

  AvatarRuntime? get _avatar {
    if (!appServices.isRegistered<ActiveAvatarRuntime>()) return null;
    return appServices.find<ActiveAvatarRuntime>().current;
  }

  void _bindAvatarReady(AvatarRuntime? avatar) {
    _emotions.cancelTransient(notify: false);
    _avatarReadyWorker?.dispose();
    _avatarReadyWorker = null;
    if (avatar == null) return;
    _avatarReadyWorker = ever<bool>(avatar.isReady, (ready) {
      if (!ready) _emotions.cancelTransient(notify: false);
      if (ready && !_runtimeOwnsAvatar) _applyEffective();
    });
  }

  void _onEmotion(EmotionStateEvent e) {
    _emotions.set(
      e.params,
      semanticLabel: e.semanticLabel,
      duration: e.duration,
      persistent: e.persistent,
      automatic: e.automatic,
    );
    if (_runtimeOwnsAvatar) return;
    Log.i(
      '🎭 [self-bridge] setEmotion → ${e.semanticLabel ?? "raw"} '
      '(intensity=${e.params.intensity.toStringAsFixed(2)})',
    );
    _applyEffective();
  }

  void _onMeme(SendMemeEvent e) {
    _emotions.set(EmotionParams.love, semanticLabel: 'love');
    if (_runtimeOwnsAvatar) return;
    _applyEffective();
  }

  void _onSpeakingStatus(SpeakingStatusEvent e) {
    if (_runtimeOwnsAvatar) return;
    if (e.isSpeaking && !MaasoTtsPlugin.permitsPlaybackEvents(e.agentId)) {
      return;
    }
    final avatar = _avatar;
    TurnTrace.event(
      'avatar.speaking_status',
      details:
          'agent=self bridge=self-avatar speaking=${e.isSpeaking} '
          'from=${e.agentId} avatar=${avatar != null}',
    );
    Log.i(
      '🎬 [self-bridge] SpeakingStatus=${e.isSpeaking} '
      'from=${e.agentId} (avatar=${avatar != null}, '
      'trace=${TurnTrace.currentId})',
    );
    _isSpeaking = e.isSpeaking;
    if (!e.isSpeaking) {
      unawaited(avatar?.stopLipSync() ?? Future<void>.value());
    }
    // Only the speech lifecycle may switch between authored idle mouth and
    // TTS ownership. Facial refreshes never issue scalar mouth commands.
    _applyEffective();
    _updateAvatarFraming(e.isSpeaking, avatar);
  }

  void _onLipSync(LipSyncAmplitudeEvent e) {
    if (_runtimeOwnsAvatar) return;
    if (e.amplitude > 0 && !MaasoTtsPlugin.permitsPlaybackEvents(e.agentId)) {
      return;
    }
    final amp = e.amplitude.clamp(0.0, 1.0);
    if (!_loggedLip && amp > 0) {
      _loggedLip = true;
      TurnTrace.event(
        'avatar.first_lip_frame',
        details:
            'agent=self bridge=self-avatar amp=${amp.toStringAsFixed(2)} '
            'isSpeaking=$_isSpeaking avatar=${_avatar != null}',
      );
      Log.i(
        '👄 [self-bridge] first lip frame amp=${amp.toStringAsFixed(2)} '
        '(isSpeaking=$_isSpeaking, avatar=${_avatar != null}, '
        'trace=${TurnTrace.currentId})',
      );
    } else if (amp == 0) {
      _loggedLip = false;
    }
    // 30fps path: only the mouth moves frame-to-frame, so push the single
    // param instead of re-serializing the whole emotion map.
    _avatar?.setMouthOpen(amp.toDouble());
  }

  void _onLipSyncEnvelope(LipSyncEnvelopeEvent e) {
    if (_runtimeOwnsAvatar || e.envelope.isEmpty) return;
    if (!MaasoTtsPlugin.permitsPlaybackEvents(e.agentId)) return;
    final avatar = _avatar;
    if (avatar == null) return;
    TurnTrace.event(
      'avatar.lip_envelope',
      details:
          'agent=self bridge=self-avatar frames=${e.envelope.length} '
          'fps=${e.frameRate}',
    );
    unawaited(avatar.startLipSync(e.envelope, frameRate: e.frameRate));
  }

  void _onVisemeTrack(LipSyncVisemeTrackEvent e) {
    if (_runtimeOwnsAvatar) return;
    if (!MaasoTtsPlugin.permitsPlaybackEvents(e.agentId)) return;
    final avatar = _avatar;
    if (avatar is! AvatarVisemeRuntime) return;
    final visemeAvatar = avatar as AvatarVisemeRuntime;
    TurnTrace.event(
      'avatar.viseme_track',
      details:
          'agent=self bridge=self-avatar frames=${e.track.envelope.length} '
          'cues=${e.track.cues.length} fps=${e.track.frameRate}',
    );
    unawaited(visemeAvatar.startVisemeTrack(e.track));
  }

  void _onSpeechPlaybackClock(SpeechPlaybackClockEvent event) {
    if (_runtimeOwnsAvatar) return;
    if (event.clock.state != SpeechPlaybackClockState.stop &&
        !MaasoTtsPlugin.permitsPlaybackEvents(event.agentId)) {
      return;
    }
    final avatar = _avatar;
    if (avatar is! AvatarSpeechPlaybackRuntime) return;
    unawaited(
      (avatar as AvatarSpeechPlaybackRuntime)
          .syncSpeechPlaybackClock(event.clock)
          .catchError((Object _) {}),
    );
  }

  /// Composes the visible avatar params from the base mood plus any TTS
  /// mouth overlay and pushes them to the active 3D runtime. Mirrors
  /// AgentRuntime._applyEffective (full-push variant).
  void _applyEffective() {
    if (_runtimeOwnsAvatar) return;
    final avatar = _avatar;
    if (avatar == null) return;
    final base = _baseEmotion;
    avatar.setExpressionParams(
      emotionToAvatarParams(
        _isSpeaking ? base.copyWith(mouthOpen: 0) : base,
        semanticLabel: _emotions.label,
      ),
    );
  }

  void _updateAvatarFraming(bool speaking, AvatarRuntime? avatar) {
    if (_runtimeOwnsAvatar ||
        (appServices.maybeFind<AvatarCameraDirector>()?.isActive ?? false)) {
      _framingRevertTimer?.cancel();
      _framingRevertTimer = null;
      return;
    }
    if (avatar == null) return;

    _framingRevertTimer?.cancel();
    _framingRevertTimer = null;

    avatar.setFraming('full');
    if (!speaking) {
      _framingRevertTimer = Timer(_framingRevertDelay, () {
        if (!_isSpeaking &&
            !_runtimeOwnsAvatar &&
            !(appServices.maybeFind<AvatarCameraDirector>()?.isActive ??
                false)) {
          avatar.setFraming('full');
        }
      });
    }
  }

  @override
  void onClose() {
    _emotions.close();
    _emotionSub?.cancel();
    _emotionResetSub?.cancel();
    _memeSub?.cancel();
    _speechSub?.cancel();
    _lipSub?.cancel();
    _lipEnvelopeSub?.cancel();
    _visemeTrackSub?.cancel();
    _playbackClockSub?.cancel();
    _avatarReadyWorker?.dispose();
    _avatarBackendWorker?.dispose();
    _framingRevertTimer?.cancel();
    super.onClose();
  }
}
