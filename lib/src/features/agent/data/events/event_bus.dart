import 'dart:async';
import '../models/emotion_params.dart';
import '../models/lip_sync_viseme.dart';
import '../models/speech_playback_clock.dart';
import '../utils/logger.dart';

// ============================================================================
// 1. Global event base class (every event must extend it for type safety).
// ============================================================================
abstract class ClawEvent {
  final DateTime timestamp;

  /// Which agent emitted the event. null means the global/default agent.
  /// When a multi-agent runtime like Maaso shares the EventBus, the UI uses
  /// this field to route to the corresponding agent's avatar/status bar.
  final String? agentId;

  ClawEvent({this.agentId}) : timestamp = DateTime.now();

  /// Whether [EventBus.fire] prints a routing log.
  ///
  /// High-frequency events (e.g. lip-sync ~30fps) should override this to
  /// false: every `Log.i` constructs a stack frame, and printing at tens to
  /// hundreds of Hz on the main isolate drags down the whole event loop,
  /// which in turn slows the token stream coming back from the inference
  /// isolate. Defaults to true.
  bool get verboseLog => true;
}

// ============================================================================
// 2. Concrete business events (extend freely as the product grows).
// ============================================================================

/// System hardware status event (e.g. low battery, disconnect, screen on).
class SystemStatusEvent extends ClawEvent {
  final String triggerType; // e.g. "battery_low", "app_resumed"
  final dynamic payload; // attached data, e.g. battery percentage 15

  SystemStatusEvent(this.triggerType, {this.payload, super.agentId});
}

/// Memory updated event (fired when the Agent remembers something new; can be
/// used to refresh the UI).
class MemoryUpdatedEvent extends ClawEvent {
  final String newFact;
  MemoryUpdatedEvent(this.newFact, {super.agentId});
}

/// Proactive-speak request event (fired when the subconscious engine decides
/// to speak up).
class ProactiveSpeakEvent extends ClawEvent {
  final String thoughtContext;
  ProactiveSpeakEvent(this.thoughtContext, {super.agentId});
}

/// Passes the mic-captured volume level while the user is speaking.
class ListeningLevelEvent extends ClawEvent {
  final double level;
  ListeningLevelEvent(this.level, {super.agentId});
}

class SpeakingStatusEvent extends ClawEvent {
  final bool isSpeaking;
  SpeakingStatusEvent(this.isSpeaking, {super.agentId});
}

/// Bounded native playback receipts, independent of synthesis and queueing.
class SpeechPlaybackClockEvent extends ClawEvent {
  SpeechPlaybackClockEvent(this.clock, {super.agentId});

  final SpeechPlaybackClock clock;

  @override
  bool get verboseLog => false;
}

/// Text accepted by the shared TTS queue.
///
/// Desktop presentation uses this as an early, read-only caption when a
/// `voice.speak` action starts before the enclosing agent turn has produced
/// its final reply. It does not alter synthesis or playback behavior.
class AgentSpeechQueuedEvent extends ClawEvent {
  AgentSpeechQueuedEvent(this.text, {super.agentId});

  final String text;

  @override
  bool get verboseLog => false;
}

/// Starts a user-visible agent reply.
///
/// Desktop companion presentation listens to this lifecycle instead of
/// starting a second runtime turn, so every app surface and the pet share the
/// same answer and TTS queue.
class AgentReplyStartedEvent extends ClawEvent {
  AgentReplyStartedEvent({
    required this.turnId,
    required this.origin,
    super.agentId,
  });

  final String turnId;
  final String origin;

  @override
  bool get verboseLog => false;
}

/// One incremental fragment of the active agent reply.
class AgentReplyDeltaEvent extends ClawEvent {
  AgentReplyDeltaEvent(this.delta, {required this.turnId, super.agentId});

  final String turnId;
  final String delta;

  @override
  bool get verboseLog => false;
}

/// The canonical final text returned by the active agent turn.
class AgentReplyCompletedEvent extends ClawEvent {
  AgentReplyCompletedEvent(this.text, {required this.turnId, super.agentId});

  final String turnId;
  final String text;

  @override
  bool get verboseLog => false;
}

/// Terminates a reply that failed or was cancelled before producing a result.
class AgentReplyAbortedEvent extends ClawEvent {
  AgentReplyAbortedEvent({required this.turnId, super.agentId});

  final String turnId;

  @override
  bool get verboseLog => false;
}

/// 🌟 For lip-sync: pushes the live audio waveform amplitude (0..1) along with
/// the TTS audio.
///
/// The render layer (3D avatar) uses this value as the
/// instantaneous driver for mouthOpen, keeping the mouth aligned to the speech
/// rhythm. About one frame every 33ms (~30fps).
///
/// The supertonic path pre-parses the WAV's RMS envelope for precise driving;
/// flutter_tts (system TTS) can't get the PCM, so it degrades to a ~4Hz sine
/// wave — the rhythm doesn't line up, but the mouth still moves.
class LipSyncAmplitudeEvent extends ClawEvent {
  /// 0 = fully closed, 1 = fully open.
  final double amplitude;
  LipSyncAmplitudeEvent(this.amplitude, {super.agentId});

  // Fires continuously at ~30fps — never log, or the log flood drags down the main isolate.
  @override
  bool get verboseLog => false;
}

/// 🌟 Lip-sync (full-envelope version) — the performance-optimized path.
///
/// Pushes the entire TTS amplitude envelope to the render layer at once; the
/// render layer (3D renderer) samples it over time in its own ticker to
/// drive the mouth, with **zero per-frame cross-platform calls during the whole
/// utterance**, replacing the previous [LipSyncAmplitudeEvent] +
/// evaluateJavascript every 33ms (a major cause of heat/jank).
///
/// [frameRate] is the envelope's sampling rate (usually 30). Fire once when
/// playback starts; on end/interrupt, fire [SpeakingStatusEvent](false) so the
/// render layer wraps up.
class LipSyncEnvelopeEvent extends ClawEvent {
  /// An amplitude sequence in 0..1, spaced 1000/[frameRate] ms apart.
  final List<double> envelope;
  final int frameRate;
  LipSyncEnvelopeEvent(this.envelope, {this.frameRate = 30, super.agentId});

  @override
  bool get verboseLog => false;
}

/// Renderer-neutral five-vowel lip-sync track.
///
/// This is additive to [LipSyncEnvelopeEvent]: producers emit the legacy
/// envelope first so renderers that do not understand visemes still animate.
/// Updated renderers then use this sparse track to select VRM Aa/Ih/Ou/Ee/Oh
/// expressions without sending one cross-platform call per audio frame.
class LipSyncVisemeTrackEvent extends ClawEvent {
  final LipSyncVisemeTrack track;

  LipSyncVisemeTrackEvent(this.track, {super.agentId});

  @override
  bool get verboseLog => false;
}

/// Renderer-neutral semantic emotion state used by emotion actions.
/// The renderer interpolates the full [EmotionParams] across updates.
class EmotionStateEvent extends ClawEvent {
  final EmotionParams params;

  /// The semantic label the AI gave at the time (e.g. "angry"); the UI can use
  /// it for a text hint. Nullable.
  final String? semanticLabel;

  /// A positive duration is a temporary cue. Without one, the semantic mood
  /// is retained but positive facial actions still release to a resting face.
  final Duration? duration;

  /// Only an explicit request to hold an expression should set this flag.
  /// Ordinary model mood updates and speech cues must leave it false.
  final bool persistent;

  /// Host provenance, never model-supplied JSON. Only ambient automation is
  /// rate-limited; a newly authored temporary cue may intentionally recur.
  final bool automatic;

  EmotionStateEvent(
    this.params, {
    this.semanticLabel,
    this.duration,
    this.persistent = false,
    this.automatic = false,
    super.agentId,
  }) {
    if (duration != null && duration! <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'must be positive');
    }
  }
}

/// Cancels only the temporary facial cue, preserving the persistent mood and
/// the independent TTS mouth channel.
class AvatarEmotionResetEvent extends ClawEvent {
  AvatarEmotionResetEvent({super.agentId});
}

class SendMemeEvent extends ClawEvent {
  final String memeUrl;
  final String emotion;

  SendMemeEvent({required this.memeUrl, required this.emotion, super.agentId});
}

/// 🚨 Agent screen-takeover event — via [AlertSkill.alertUser] the AI
/// proactively breaks the normal chat flow and forces a feedback card that
/// sits "above other UI". The host app listens and renders it.
///
/// [level] decides the visual intensity:
///  * "info"    — bottom snackbar / small top bar
///  * "warning" — top yellow banner + medium haptic
///  * "urgent"  — screen flashes red + full-screen modal + heavy haptic
///
/// [haptic] / [flash] are reference switches for the UI layer; the exact
/// effect is up to the host.
class AlertEvent extends ClawEvent {
  final String level; // "info" | "warning" | "urgent"
  final String title;
  final String? message;
  final String? color; // hex like "#FF3333", optional
  final int durationMs; // 0 = require manual dismiss
  final bool flash;
  final String haptic; // "none" | "light" | "medium" | "heavy"

  AlertEvent({
    required this.title,
    this.message,
    this.level = 'info',
    this.color,
    this.durationMs = 4000,
    this.flash = false,
    this.haptic = 'medium',
    super.agentId,
  });
}

// ============================================================================
// 3. Core event bus (EventBus) — singleton + broadcast stream.
// ============================================================================
class EventBus {
  // Singleton.
  static final EventBus _instance = EventBus._internal();
  factory EventBus() => _instance;
  EventBus._internal();

  // A broadcast stream controller that supports multiple subscribers.
  final StreamController<ClawEvent> _streamController =
      StreamController<ClawEvent>.broadcast();

  /// 🌟 Listen for a specific event type.
  /// Any module can call `EventBus().on<SystemStatusEvent>()` to subscribe.
  Stream<T> on<T extends ClawEvent>() {
    if (T == dynamic) {
      return _streamController.stream as Stream<T>;
    } else {
      // Use Dart's where + cast to filter the event stream by type.
      return _streamController.stream.where((event) => event is T).cast<T>();
    }
  }

  /// 🌟 Broadcast an event.
  /// The perception layer or triggers call this to throw an event onto the bus.
  void fire(ClawEvent event) {
    if (event.verboseLog) {
      Log.i('🚏 [EventBus] Routing event: ${event.runtimeType}');
    }
    _streamController.add(event);
  }

  /// Destroy the bus (usually called when the app fully exits).
  void destroy() {
    _streamController.close();
  }
}
