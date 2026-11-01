import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/acoustic_barge_in_policy.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/world_composer.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/barge_in_controller.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/speech_segment_processor.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/services/voice_prosody_service.dart';
import 'package:maaso/src/core/services/voice_turn_send_fence.dart';

typedef ChatInputPresentationBuilder =
    Widget Function(BuildContext context, ChatInputPresentation state);

/// Home owns its editor, attachments and morph. The shared input retains voice
/// capture, ASR and turn fencing; these values never expose its voice buffer.
final class ChatInputPresentation {
  const ChatInputPresentation({
    required this.voiceActive,
    required this.enteringVoice,
    required this.canEnterVoice,
    required this.enabled,
    required this.isThinking,
    required this.voiceSubmitBusy,
    required this.phase,
    required this.amplitude,
    required this.amplitudeStream,
    required this.enterVoice,
    required this.exitVoice,
    required this.submit,
    required this.interrupt,
    required this.reportInputActivity,
    required this.voiceControlBuilder,
  });

  final bool voiceActive, enteringVoice, canEnterVoice;
  final bool enabled, isThinking, voiceSubmitBusy;
  final VoiceOrbPhase phase;
  final double amplitude;
  final Stream<double>? amplitudeStream;
  final Future<void> Function() enterVoice, exitVoice;
  final VoidCallback submit;
  final VoidCallback? interrupt;
  final ValueChanged<PresenceInputActivityKind> reportInputActivity;
  final AppGlassVoiceControlBuilder voiceControlBuilder;
}

/// Reusable chat composer with two interaction modes:
///
///   * **Text mode** — optional `leading` slot + text field + send and voice
///     buttons grouped on the right.
///   * **Voice mode** — the composer contracts into one centered voice orb.
///     The orb carries a live Siri-like pulse driven by
///     [MicCaptureService.amplitude], while native ASR partial transcripts
///     stream into the input controller. Maaso VAD detects trailing silence and
///     auto-sends. Home's opt-in uses a separate transcript buffer and a captured
///     text callback, preserving the independently edited draft.
///
/// Drop into any [Stack]: the bar manages its own animations and sizing.
class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;

  /// Async send hook used by continuous voice surfaces. Capture is reopened
  /// before this future is launched so acoustic barge-in remains possible;
  /// ordinary VAD submissions stay fenced until the active turn completes.
  final Future<void> Function()? onVoiceSend;

  /// Home-only opt-in. Keeps typed drafts separate from all ASR transcripts and
  /// makes every active orb tap exit voice, including while a turn is busy.
  final bool homeComposerMode;

  /// Receives a captured final transcript without touching [controller]. Home
  /// never falls back to [onSend] or [onVoiceSend] when this hook is missing.
  final Future<void> Function(String text)? onVoiceTextSend;

  /// Home may commit/blur its native IME here. False cancels entry before any
  /// capture or permission request; scope and entry fences are checked again.
  final FutureOr<bool> Function()? beforeVoiceEntry;

  /// Optional Home editor/morph presentation; other hosts keep the shared UI.
  final ChatInputPresentationBuilder? presentationBuilder;

  /// Optional widget rendered before the mic toggle in text mode.  Pages
  /// use this for screen-specific affordances when needed.
  final Widget? leading;

  /// Hint shown inside the text field.  Defaults to a generic English line
  /// if not supplied — pages with i18n usually pass a localized string here.
  final String hint;

  /// True while the agent is mid-reply (generating or speaking). When set, the
  /// send button becomes a PAUSE/interrupt button (if [onInterrupt] is given).
  final bool isThinking;

  /// Called when the user taps the pause button while [isThinking]. Null →
  /// the button just stays disabled (legacy behaviour).
  final VoidCallback? onInterrupt;

  /// Optional observer for presence/life-state signals. It must stay
  /// side-effect-light: sending still belongs to [onSend].
  final ValueChanged<PresenceInputActivityKind>? onInputActivity;

  /// Whether text, send, and voice controls accept input.
  final bool enabled;

  /// Optional hard limit for realtime prompt text.
  final int? maxLength;

  /// Optional focus node supplied by the owning surface.
  final FocusNode? focusNode;

  /// Optional key for automation and surface-specific input contracts.
  final Key? textFieldKey;

  /// Tooltip for the realtime submit action.
  final String sendTooltip;

  /// Opens the microphone as soon as this composer is mounted.
  final bool startInVoiceMode;

  /// Continues an already chosen account voice session across Home/game routes.
  /// It does not grant microphone permission or create a new user preference.
  final bool inheritVoiceSession;

  /// Keeps the compact orb presentation and removes the keyboard escape.
  /// The owning surface is then responsible for ending the voice session.
  final bool voiceOnly;

  /// Allows the composer to join the realtime audio room when that pipeline
  /// is selected. Turn-based companion surfaces disable this so transcripts,
  /// reply text, persistence, and the shared runtime stay in one path.
  final bool allowRealtimeVoice;

  /// Blurs Flutter chat content behind the floating text composer.
  /// Other surfaces retain the existing glass treatment by default.
  final bool floatingGlass;

  /// Adds a subtle text-field outline on full chat pages without an avatar.
  final bool textInputBorder;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.onVoiceSend,
    this.homeComposerMode = false,
    this.onVoiceTextSend,
    this.beforeVoiceEntry,
    this.presentationBuilder,
    this.leading,
    this.hint = 'chat.input_hint',
    this.isThinking = false,
    this.onInterrupt,
    this.onInputActivity,
    this.enabled = true,
    this.maxLength,
    this.focusNode,
    this.textFieldKey,
    this.sendTooltip = 'chat.send_message',
    this.startInVoiceMode = false,
    this.inheritVoiceSession = false,
    this.voiceOnly = false,
    this.allowRealtimeVoice = true,
    this.floatingGlass = false,
    this.textInputBorder = false,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar>
    with WidgetsBindingObserver {
  static const _autoSubmitSilence = Duration(milliseconds: 900);
  static const _noSpeechTimeout = Duration(seconds: 12);
  static const _speechSegmentProcessor = SpeechSegmentProcessor();
  static _ChatInputBarState? _activeVoiceOwner;
  final _voiceSegmentOperations = VoiceInputOperationFence();
  late final _voiceTurnSends = VoiceTurnSendFence(
    onBusyChanged: (_) {
      voiceInputRetirementCoordinator.notifyPriorityChanged(this);
      _refreshHomePresentation();
    },
  );

  String _homeVoiceText = '';
  bool _voiceUsesIsolatedBuffer = false;
  bool _requestingHomeVoiceOwnership = false;
  int? _homeOwnershipRequestBinding;
  String? _homeOwnershipRequestScope;
  int _voiceBindingGeneration = 0;
  int _homeVoiceExitCount = 0;
  bool _disposing = false;

  bool _voiceMode = false;
  bool _enteringVoice = false;
  int _voiceEntryGeneration = 0;
  int? _activeVoiceEntryGeneration;
  Completer<void>? _voiceEntryDone;
  _NativeVoiceEntryResources? _nativeVoiceEntryResources;
  Future<void>? _nativeVoiceCleanupFuture;
  Future<void>? _voiceRetirementFuture;
  bool _realtimeVoiceActive = false;
  VolcRtcSessionService? _realtimeVoiceSession;
  bool _nativeAsrActive = false;
  DesktopLocalAsrService? _desktopLocalAsrSession;
  bool _heardSpeech = false;
  int _voiceSessionGeneration = 0;
  // Continuous voice mode: after an utterance is sent we keep listening (we do
  // NOT drop back to the text field). The user leaves voice mode explicitly via
  // the back-to-text control.
  // Mirrors MicCaptureService.playbackActive — true while our own TTS plays
  // (plus the mic's decay grace). The mic gates the audio itself; we track it
  // only to avoid applying transcripts / auto-submit on the agent's voice.
  bool _agentSpeaking = false;
  StreamSubscription<String>? _nativeAsrFinalSub;
  Worker? _playbackWorker;
  Worker? _nativeAsrTranscriptWorker;
  Worker? _nativeAsrErrorWorker;
  Worker? _vadSpeakingWorker;
  Worker? _bargeInActiveWorker;
  StreamSubscription<UserSpeakingEndedEvent>? _vadEndedSub;
  StreamSubscription<PlaybackSpeechCandidateStartedEvent>?
  _playbackCandidateStartedSub;
  StreamSubscription<PlaybackSpeechCandidateEndedEvent>?
  _playbackCandidateEndedSub;
  Timer? _autoSubmitTimer;
  Timer? _noSpeechTimer;
  Timer? _nativeAsrFallbackTimer;
  bool _nativeAsrAwaitingFinal = false;
  int _playbackCandidateGeneration = 0;
  _PlaybackCandidateAttempt? _playbackCandidateAttempt;
  String? _voiceEntryScope;
  bool _foreground = true;
  bool _routeIsCurrent = true;
  bool _voiceVisibilitySyncScheduled = false;
  String? _prosodyUtteranceId;
  int? _prosodyUtteranceGeneration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    voiceInputRetirementCoordinator.sessionIntentRevision.addListener(
      _handleVoiceSessionIntent,
    );
    if (widget.startInVoiceMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_enterVoice());
      });
    }
  }

  bool get _voiceInputAvailable =>
      widget.enabled &&
      (!widget.homeComposerMode ||
          (!widget.voiceOnly && widget.onVoiceTextSend != null)) &&
      (!widget.inheritVoiceSession || (_foreground && _routeIsCurrent));

  bool get _homeComposerMode => widget.homeComposerMode && !widget.voiceOnly;
  bool get _homeEntryPending =>
      _voiceInputAvailable &&
      ((_requestingHomeVoiceOwnership &&
              _homeOwnershipRequestBinding == _voiceBindingGeneration &&
              _homeOwnershipRequestScope ==
                  voiceInputRetirementCoordinator.voiceSessionScopeKey) ||
          (_enteringVoice &&
              _activeVoiceEntryGeneration == _voiceEntryGeneration &&
              _voiceEntryScope ==
                  voiceInputRetirementCoordinator.voiceSessionScopeKey));
  bool get _canEnterHomeVoice =>
      mounted &&
      !_disposing &&
      _voiceInputAvailable &&
      _homeVoiceExitCount == 0 &&
      !_requestingHomeVoiceOwnership &&
      !_enteringVoice &&
      !_voiceMode &&
      !_voiceSegmentOperations.isActive &&
      _nativeVoiceCleanupFuture == null &&
      !(_nativeVoiceEntryResources?.cleanupRequired ?? false) &&
      !voiceInputRetirementCoordinator.isRetiring &&
      _voiceRetirementFuture == null;

  String get _voiceTranscriptText =>
      _voiceUsesIsolatedBuffer ? _homeVoiceText : widget.controller.text;

  void _writeVoiceTranscript(String text, {bool moveSelection = false}) {
    if (_voiceUsesIsolatedBuffer) {
      _homeVoiceText = text;
    } else {
      widget.controller.text = text;
      if (moveSelection) {
        widget.controller.selection = TextSelection.collapsed(
          offset: text.length,
        );
      }
    }
  }

  void _clearVoiceTranscript() {
    if (_voiceUsesIsolatedBuffer) {
      _homeVoiceText = '';
    } else {
      widget.controller.clear();
    }
  }

  void _refreshHomePresentation() {
    if (mounted && !_disposing && _homeComposerMode) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _scheduleVoiceVisibilitySync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _scheduleVoiceVisibilitySync();
  }

  void _handleVoiceSessionIntent() {
    if (!widget.inheritVoiceSession) return;
    _scheduleVoiceVisibilitySync();
  }

  void _scheduleVoiceVisibilitySync() {
    if (!widget.inheritVoiceSession || _voiceVisibilitySyncScheduled) return;
    if (!_voiceInputAvailable) _invalidateVoiceEntry();
    _voiceVisibilitySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _voiceVisibilitySyncScheduled = false;
      if (!mounted || !widget.inheritVoiceSession) return;
      final coordinator = voiceInputRetirementCoordinator;
      final scope = coordinator.voiceSessionScopeKey;
      final requested =
          scope != null && coordinator.voiceSessionRequestedFor(scope);
      final entryGeneration = _activeVoiceEntryGeneration;
      // Admission confirms the persistent choice only after capture starts.
      // Home activity and keyboard/layout changes can rebuild this composer
      // while support, permission, or recorder startup is still pending.
      // Preserve that exact admitted entry without weakening route, account,
      // service-identity, foreground, or ownership cancellation fences.
      final startingCurrentSession =
          entryGeneration != null &&
          _voiceEntryIsCurrent(entryGeneration, _desktopLocalAsr);
      if (!_voiceInputAvailable || (!requested && !startingCurrentSession)) {
        if (_voiceMode || _enteringVoice) {
          unawaited(_relinquishVoiceOwnership());
        }
      } else if (!_voiceMode && !_enteringVoice) {
        unawaited(_enterVoice());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  MicCaptureService? get _mic => appServices.isRegistered<MicCaptureService>()
      ? appServices.find<MicCaptureService>()
      : null;
  PlatformAsrService? get _platformAsr =>
      appServices.isRegistered<PlatformAsrService>()
      ? appServices.find<PlatformAsrService>()
      : null;
  DesktopLocalAsrService? get _desktopLocalAsr =>
      appServices.maybeFind<DesktopLocalAsrService>();
  VadService? get _vad => appServices.isRegistered<VadService>()
      ? appServices.find<VadService>()
      : null;
  VoiceProsodyService? get _voiceProsody =>
      appServices.maybeFind<VoiceProsodyService>();
  BargeInController? get _bargeInController =>
      appServices.maybeFind<BargeInController>();
  MaasoAgentModeService? get _agentMode =>
      appServices.isRegistered<MaasoAgentModeService>()
      ? appServices.find<MaasoAgentModeService>()
      : null;
  AgentPipelineMode get _pipelineMode =>
      _agentMode?.pipelineMode.value ?? AgentPipelineMode.defaultMode;
  RealtimeAgentConfig? get _realtimeConfig =>
      appServices.isRegistered<RealtimeAgentConfig>()
      ? appServices.find<RealtimeAgentConfig>()
      : null;
  VolcRtcSessionService? get _realtimeVoice =>
      appServices.isRegistered<VolcRtcSessionService>()
      ? appServices.find<VolcRtcSessionService>()
      : null;
  bool get _shouldUseRealtimeVoice =>
      widget.allowRealtimeVoice &&
      _pipelineMode.usesRealtimeAudio &&
      (_realtimeConfig?.isReady ?? false) &&
      _realtimeVoice != null;
  bool get _voiceTurnInFlight => _voiceTurnSends.isBusy;

  bool _allowsAcousticBargeIn() {
    final behaviorConfig = appServices.maybeFind<AgentBehaviorConfig>();
    if (behaviorConfig == null || _bargeInController == null) return false;
    return AcousticBargeInPolicy(
      platformCapabilities: AppPlatformCapabilities.current(),
      // The iOS recorder implementation is the affirmative AEC evidence used
      // by the global microphone authorization gate. The platform admission
      // below rejects every other host before this evidence is considered.
      platformAecEvidence: () => true,
      userInVoiceMode: () => _voiceMode,
      behaviorConfig: behaviorConfig,
    ).allowsCaptureDuringPlayback;
  }

  void _notifyInputActivity(PresenceInputActivityKind kind) {
    widget.onInputActivity?.call(kind);
  }

  void _setAgentSpeaking(bool speaking) {
    if (_agentSpeaking == speaking) return;
    if (mounted) {
      setState(() => _agentSpeaking = speaking);
    } else {
      _agentSpeaking = speaking;
    }
  }

  void _setNativeAsrAwaitingFinal(bool awaiting) {
    if (_nativeAsrAwaitingFinal == awaiting) return;
    if (mounted) {
      setState(() => _nativeAsrAwaitingFinal = awaiting);
    } else {
      _nativeAsrAwaitingFinal = awaiting;
    }
    voiceInputRetirementCoordinator.notifyPriorityChanged(this);
  }

  int? _beginVoiceEntry({bool allowActiveVoiceMode = false}) {
    if (!mounted ||
        !_voiceInputAvailable ||
        _enteringVoice ||
        _voiceSegmentOperations.isActive ||
        _nativeVoiceCleanupFuture != null ||
        (_nativeVoiceEntryResources?.cleanupRequired ?? false) ||
        voiceInputRetirementCoordinator.isRetiring ||
        _voiceRetirementFuture != null ||
        (!allowActiveVoiceMode && _voiceMode)) {
      return null;
    }
    _enteringVoice = true;
    final generation = ++_voiceEntryGeneration;
    _activeVoiceEntryGeneration = generation;
    _voiceEntryScope = voiceInputRetirementCoordinator.voiceSessionScopeKey;
    _voiceEntryDone = Completer<void>();
    _voiceUsesIsolatedBuffer = _homeComposerMode;
    _refreshHomePresentation();
    return generation;
  }

  bool _voiceEntryIsCurrent(
    int generation,
    DesktopLocalAsrService? desktopLocalAsr, {
    bool requireOwnership = true,
  }) =>
      mounted &&
      _voiceInputAvailable &&
      _voiceEntryScope ==
          voiceInputRetirementCoordinator.voiceSessionScopeKey &&
      _enteringVoice &&
      _activeVoiceEntryGeneration == generation &&
      _voiceEntryGeneration == generation &&
      identical(_desktopLocalAsr, desktopLocalAsr) &&
      (!requireOwnership ||
          (identical(_activeVoiceOwner, this) &&
              voiceInputRetirementCoordinator.isOwner(this)));

  bool _nativeVoiceEntryIsCurrent(
    int generation,
    DesktopLocalAsrService? desktopLocalAsr,
    _NativeVoiceEntryResources resources,
  ) =>
      _voiceEntryIsCurrent(generation, desktopLocalAsr) &&
      resources.entryGeneration == generation &&
      identical(_nativeVoiceEntryResources, resources) &&
      identical(_platformAsr, resources.platformAsr) &&
      identical(_mic, resources.mic) &&
      (resources.vad == null || identical(_vad, resources.vad));

  void _invalidateVoiceEntry() {
    _voiceEntryGeneration++;
    _refreshHomePresentation();
  }

  void _finishVoiceEntry(int generation) {
    if (_activeVoiceEntryGeneration != generation) return;
    _activeVoiceEntryGeneration = null;
    _enteringVoice = false;
    final done = _voiceEntryDone;
    _voiceEntryDone = null;
    if (done != null && !done.isCompleted) done.complete();
    _refreshHomePresentation();
  }

  void _clearRealtimeVoiceEntry(VolcRtcSessionService realtime) {
    if (!identical(_realtimeVoiceSession, realtime)) return;
    if (mounted) {
      setState(() => _voiceMode = false);
    } else {
      _voiceMode = false;
    }
    _realtimeVoiceActive = false;
    _realtimeVoiceSession = null;
  }

  Future<void> _retireNativeVoiceEntryResources(
    _NativeVoiceEntryResources resources, {
    required bool cancelRecognizer,
  }) {
    resources.cancelRecognizer = resources.cancelRecognizer || cancelRecognizer;
    resources.cleanupRequired = true;
    final existing = resources.cleanupFuture;
    if (existing != null) return existing;
    late final Future<void> cleanup;
    cleanup = () async {
      try {
        await _retireNativeVoiceEntryResourcesOnce(resources);
        resources.cleanupRequired = false;
        if (identical(_nativeVoiceEntryResources, resources)) {
          _nativeVoiceEntryResources = null;
        }
      } finally {
        if (identical(resources.cleanupFuture, cleanup)) {
          resources.cleanupFuture = null;
        }
        if (identical(_nativeVoiceCleanupFuture, cleanup)) {
          _nativeVoiceCleanupFuture = null;
        }
      }
    }();
    resources.cleanupFuture = cleanup;
    _nativeVoiceCleanupFuture = cleanup;
    voiceInputRetirementCoordinator.track(
      key: resources,
      retirement: cleanup,
      retry: () => _retireNativeVoiceEntryResources(
        resources,
        cancelRecognizer: resources.cancelRecognizer,
      ),
    );
    return cleanup;
  }

  Future<void> _retireNativeVoiceEntryResourcesOnce(
    _NativeVoiceEntryResources resources,
  ) => runVoiceInputCleanupSteps(<FutureOr<void> Function()>[
    _resetVoiceModeSubscriptions,
    () async => resources.vad?.stop(),
    resources.mic.stop,
    () async {
      if (resources.cancelRecognizer) {
        await resources.platformAsr.cancelAndDrain();
      }
    },
  ]);

  Future<void> _abortStaleNativeVoiceEntry(
    _NativeVoiceEntryResources resources,
  ) async {
    final cleanup = resources.cleanupFuture;
    if (cleanup != null) {
      try {
        await cleanup;
      } on Object catch (error, stackTrace) {
        Log.w(
          '🎙️ [Voice] stale entry cleanup failed; retrying: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _invalidateVoiceEntry();
    _voiceSessionGeneration++;
    if (mounted && _voiceMode) setState(() => _voiceMode = false);
    _nativeAsrActive = false;
    _desktopLocalAsrSession = null;
    _setNativeAsrAwaitingFinal(false);
    _setAgentSpeaking(false);
    // An exit can retire this entry while one of its start calls is still
    // pending. Run a second, captured-handle cleanup after that await settles;
    // ownership/entry guards prevent a replacement session from starting
    // until this pass completes.
    await _retireNativeVoiceEntryResources(resources, cancelRecognizer: true);
  }

  Future<void> _enterVoice() async {
    if (_requestingHomeVoiceOwnership) return;
    final homeEntry = _homeComposerMode;
    if (homeEntry && !_canEnterHomeVoice) return;
    final binding = _voiceBindingGeneration;
    final controller = widget.controller;
    final scope = voiceInputRetirementCoordinator.voiceSessionScopeKey;
    final beforeEntry = widget.beforeVoiceEntry;
    bool homeRequestIsCurrent() =>
        mounted &&
        !_disposing &&
        _homeComposerMode &&
        _voiceInputAvailable &&
        _voiceBindingGeneration == binding &&
        identical(widget.controller, controller) &&
        scope == voiceInputRetirementCoordinator.voiceSessionScopeKey;
    if (homeEntry) {
      _requestingHomeVoiceOwnership = true;
      _homeOwnershipRequestBinding = binding;
      _homeOwnershipRequestScope = scope;
      _refreshHomePresentation();
    }
    final alreadyOwned = voiceInputRetirementCoordinator.isOwner(this);
    try {
      final acquired = await voiceInputRetirementCoordinator.acquire(
        owner: this,
        retireCurrentOwner: _relinquishVoiceOwnership,
        hasPendingUserInput: () =>
            _nativeAsrAwaitingFinal || _voiceTurnSends.isBusy,
      );
      if (!acquired) {
        if (mounted) _showSnack('chat.voice_unavailable'.tr);
        return;
      }
      if (homeEntry && !homeRequestIsCurrent()) {
        if (!alreadyOwned) _releaseVoiceOwnership();
        return;
      }
    } on Object catch (error, stackTrace) {
      Log.w(
        '🎙️ [Voice] input ownership handoff failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) _showSnack('chat.voice_unavailable'.tr);
      return;
    } finally {
      if (homeEntry) {
        _requestingHomeVoiceOwnership = false;
        _homeOwnershipRequestBinding = null;
        _homeOwnershipRequestScope = null;
        _refreshHomePresentation();
      }
    }
    final entryGeneration = _beginVoiceEntry();
    if (entryGeneration == null) {
      if (!alreadyOwned) _releaseVoiceOwnership();
      return;
    }
    _activeVoiceOwner = this;
    final desktopLocalAsr = _desktopLocalAsr;
    if (!homeEntry) FocusManager.instance.primaryFocus?.unfocus();

    try {
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) return;
      if (homeEntry) {
        var allowed = true;
        try {
          if (beforeEntry != null) allowed = await beforeEntry();
        } on Object {
          allowed = false;
        }
        if (!homeRequestIsCurrent() ||
            !_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) {
          return;
        }
        if (!allowed) {
          voiceInputRetirementCoordinator.endVoiceSessionIntent(this);
          _homeVoiceText = '';
          return;
        }
        FocusManager.instance.primaryFocus?.unfocus();
      }

      if (await _enterRealtimeVoice(
        entryGeneration: entryGeneration,
        desktopLocalAsr: desktopLocalAsr,
      )) {
        return;
      }
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) return;
      await _enterNativeAsrWithVadVoice(
        entryGeneration: entryGeneration,
        desktopLocalAsr: desktopLocalAsr,
        armNoSpeechTimeout: !widget.voiceOnly,
      );
    } finally {
      _finishVoiceEntry(entryGeneration);
      if (!_voiceMode) _releaseVoiceOwnership();
    }
  }

  Future<void> _relinquishVoiceOwnership() async {
    if (_voiceUsesIsolatedBuffer || _homeComposerMode) {
      _voiceBindingGeneration++;
      _homeVoiceText = '';
    }
    final pendingEntry = _voiceEntryDone?.future;
    _invalidateVoiceEntry();
    if (_voiceMode) {
      await _exitVoice(send: false, preserveIntent: true);
    } else if (_nativeAsrActive ||
        _nativeVoiceEntryResources != null ||
        _voiceSegmentOperations.isActive) {
      await _cleanupNativeAsrVoice(cancelRecognizer: true);
    }
    await _voiceSegmentOperations.drain();
    final retirement = _voiceRetirementFuture;
    if (retirement != null) await retirement;
    if (pendingEntry != null) await pendingEntry;
    final cleanup = _nativeVoiceCleanupFuture;
    if (cleanup != null) await cleanup;
    final resources = _nativeVoiceEntryResources;
    if (resources != null && resources.cleanupRequired) {
      await _retireNativeVoiceEntryResources(resources, cancelRecognizer: true);
    }
    _releaseVoiceOwnership();
  }

  void _releaseVoiceOwnership() {
    if (_homeVoiceExitCount > 0 ||
        _enteringVoice ||
        _voiceSegmentOperations.isActive ||
        _nativeVoiceCleanupFuture != null ||
        (_nativeVoiceEntryResources?.cleanupRequired ?? false) ||
        _voiceRetirementFuture != null) {
      return;
    }
    if (identical(_activeVoiceOwner, this)) {
      _activeVoiceOwner = null;
    }
    voiceInputRetirementCoordinator.release(this);
  }

  Future<bool> _enterNativeAsrWithVadVoice({
    required int entryGeneration,
    required DesktopLocalAsrService? desktopLocalAsr,
    bool armNoSpeechTimeout = true,
  }) async {
    final nativeAsr = _platformAsr;
    final mic = _mic;
    if (nativeAsr == null || mic == null) {
      if (_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) {
        _showSnack('chat.voice_unavailable'.tr);
      }
      return true;
    }
    final localRequested =
        desktopLocalAsr?.state.value.preferenceEnabled == true;
    if (localRequested) {
      final operational = await desktopLocalAsr!.isOperational();
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
          !identical(_platformAsr, nativeAsr) ||
          !identical(_mic, mic)) {
        return true;
      }
      if (!operational) {
        Log.w(
          '🎙️ [LocalASR] unavailable failure='
          '${desktopLocalAsr.state.value.lastFailure?.name ?? 'not_ready'}',
        );
        _showSnack('chat.voice_unavailable'.tr);
        return true;
      }
    } else {
      final supported = await nativeAsr.isSupported();
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
          !identical(_platformAsr, nativeAsr) ||
          !identical(_mic, mic)) {
        return true;
      }
      if (!supported) {
        Log.w(
          '🎙️ [NativeASR] unsupported: '
          '${nativeAsr.error.value ?? 'no diagnostic'}',
        );
        _showSnack('chat.voice_unavailable'.tr);
        return true;
      }
    }

    await _resetVoiceModeSubscriptions();
    if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
        !identical(_platformAsr, nativeAsr) ||
        !identical(_mic, mic)) {
      return true;
    }
    final entryResources = _NativeVoiceEntryResources(
      entryGeneration: entryGeneration,
      platformAsr: nativeAsr,
      mic: mic,
    );
    _nativeVoiceEntryResources = entryResources;
    _clearVoiceTranscript();
    _voiceSessionGeneration++;
    final transcriptGeneration = _voiceSessionGeneration;
    bool transcriptIsCurrent() =>
        mounted &&
        !_disposing &&
        _voiceMode &&
        _nativeAsrActive &&
        transcriptGeneration == _voiceSessionGeneration &&
        identical(_platformAsr, nativeAsr) &&
        _voiceEntryScope ==
            voiceInputRetirementCoordinator.voiceSessionScopeKey;
    setState(() {
      _voiceMode = true;
      _nativeAsrActive = true;
      _desktopLocalAsrSession = localRequested ? desktopLocalAsr : null;
    });
    _notifyInputActivity(PresenceInputActivityKind.voiceModeEntry);

    final granted = await mic.hasPermission();
    if (!_nativeVoiceEntryIsCurrent(
      entryGeneration,
      desktopLocalAsr,
      entryResources,
    )) {
      await _abortStaleNativeVoiceEntry(entryResources);
      return true;
    }
    if (!granted) {
      _showSnack('chat.microphone_permission'.tr);
      await _cleanupNativeAsrVoice(cancelRecognizer: true);
      return true;
    }

    _setAgentSpeaking(mic.playbackActive.value);
    _playbackWorker = ever<bool>(mic.playbackActive, (speaking) {
      _setAgentSpeaking(speaking);
      Log.i('🎙️ [Voice] playback gate mirror=$speaking');
      if (speaking) {
        _heardSpeech = false;
        _cancelVoiceTimers();
      }
    });

    if (!localRequested) {
      _nativeAsrTranscriptWorker = ever<String>(nativeAsr.partialTranscript, (
        text,
      ) {
        if (!transcriptIsCurrent()) return;
        _writeVoiceTranscript(text, moveSelection: true);
        if (text.trim().isNotEmpty) {
          _heardSpeech = true;
          _noSpeechTimer?.cancel();
          _noSpeechTimer = null;
        }
      });
      _nativeAsrErrorWorker = ever<String?>(nativeAsr.error, _onNativeAsrError);
      _nativeAsrFinalSub = nativeAsr.finalResults.listen((text) {
        if (transcriptIsCurrent()) _onNativeAsrFinal(text);
      });
    }
    if (localRequested || nativeAsr.supportsExternalAudioInput) {
      _vadEndedSub = EventBus().on<UserSpeakingEndedEvent>().listen(
        _onVadSpeechEnded,
      );
    }

    final admittedBargeInController = _bargeInController;
    final requestPlaybackCandidates =
        !localRequested &&
        nativeAsr.supportsExternalAudioInput &&
        admittedBargeInController != null &&
        _allowsAcousticBargeIn();
    final micStarted = await mic.startWithOptions(
      includePlaybackCandidates: requestPlaybackCandidates,
    );
    if (!_nativeVoiceEntryIsCurrent(
      entryGeneration,
      desktopLocalAsr,
      entryResources,
    )) {
      await _abortStaleNativeVoiceEntry(entryResources);
      return true;
    }
    if (!micStarted) {
      Log.w(
        '🎙️ [Voice] microphone start failed: '
        '${mic.error.value ?? 'no diagnostic'}',
      );
      _showSnack('chat.microphone_unavailable'.tr);
      await _cleanupNativeAsrVoice(cancelRecognizer: true);
      return true;
    }
    final playbackCandidatesActive =
        requestPlaybackCandidates &&
        mic.playbackCandidateCaptureActive &&
        identical(_bargeInController, admittedBargeInController);
    if (playbackCandidatesActive) {
      final bargeInController = admittedBargeInController;
      _playbackCandidateStartedSub = EventBus()
          .on<PlaybackSpeechCandidateStartedEvent>()
          .listen(_onPlaybackCandidateStarted);
      _playbackCandidateEndedSub = EventBus()
          .on<PlaybackSpeechCandidateEndedEvent>()
          .listen(_onPlaybackCandidateEnded);
      _bargeInActiveWorker = ever<bool>(bargeInController.active, (active) {
        if (active) return;
        final attempt = _playbackCandidateAttempt;
        if (attempt != null && !attempt.resolving) {
          _onBargeInControllerInactive(attempt);
        }
      });
      Log.i('🎙️ [BargeIn] isolated playback candidate capture active');
    } else if (requestPlaybackCandidates) {
      Log.w('🎙️ [BargeIn] candidate capture request was denied by mic gate');
    }

    var vadSegmentEndpointing = false;
    final vad = _vad;
    entryResources.vad = vad;
    if (vad != null) {
      try {
        await vad.ensureReady();
        if (!_nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
          await _abortStaleNativeVoiceEntry(entryResources);
          return true;
        }
        _vadSpeakingWorker = ever<bool>(vad.userIsSpeaking, _onVadSpeaking);
        await vad.startWithOptions(
          includePlaybackCandidates: playbackCandidatesActive,
        );
        if (!_nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
          await _abortStaleNativeVoiceEntry(entryResources);
          return true;
        }
        vadSegmentEndpointing = true;
      } catch (e) {
        if (!_nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
          await _abortStaleNativeVoiceEntry(entryResources);
          return true;
        }
        Log.w(
          '🎙️ [Voice] VAD unavailable; native ASR final/manual stop only: $e',
        );
        _vadSpeakingWorker?.dispose();
        _vadSpeakingWorker = null;
      }
    }
    if (localRequested && !vadSegmentEndpointing) {
      Log.w('🎙️ [LocalASR] VAD is required for bounded segment recognition');
      _showSnack('chat.voice_unavailable'.tr);
      await _cleanupNativeAsrVoice(cancelRecognizer: false);
      return true;
    }
    _heardSpeech = false;
    if (armNoSpeechTimeout) {
      _armNoSpeechTimeout();
    }

    if ((localRequested || nativeAsr.supportsExternalAudioInput) &&
        vadSegmentEndpointing) {
      Log.i(
        '🎙️ [${localRequested ? 'LocalASR' : 'NativeASR'}] '
        'waiting for VAD speech segment samples',
      );
    } else {
      if (nativeAsr.supportsExternalAudioInput) {
        await vad?.stop();
        if (!_nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
          await _abortStaleNativeVoiceEntry(entryResources);
          return true;
        }
        await mic.stop();
        if (!_nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
          await _abortStaleNativeVoiceEntry(entryResources);
          return true;
        }
      }
      final started = await nativeAsr.start(
        locale: AppLocalization.locale.toLanguageTag(),
        audioStream: nativeAsr.supportsExternalAudioInput
            ? null
            : mic.recognitionStream,
      );
      if (!_nativeVoiceEntryIsCurrent(
        entryGeneration,
        desktopLocalAsr,
        entryResources,
      )) {
        await _abortStaleNativeVoiceEntry(entryResources);
        return true;
      }
      if (!started) {
        Log.w(
          '🎙️ [NativeASR] start failed: '
          '${nativeAsr.error.value ?? 'no diagnostic'}',
        );
        _showSnack('chat.voice_unavailable'.tr);
        await _cleanupNativeAsrVoice(cancelRecognizer: true);
      }
    }
    if (_voiceMode &&
        _nativeVoiceEntryIsCurrent(
          entryGeneration,
          desktopLocalAsr,
          entryResources,
        )) {
      voiceInputRetirementCoordinator.confirmVoiceSessionIntent(
        this,
        _voiceEntryScope,
      );
    }
    return true;
  }

  Future<bool> _enterRealtimeVoice({
    required int entryGeneration,
    required DesktopLocalAsrService? desktopLocalAsr,
  }) async {
    if (!_shouldUseRealtimeVoice) return false;
    final realtime = _realtimeVoice;
    if (realtime == null) return false;

    try {
      final mic = _mic;
      if (mic != null) {
        final granted = await mic.hasPermission();
        if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
            !identical(_realtimeVoice, realtime) ||
            !identical(_mic, mic)) {
          return true;
        }
        if (!granted) {
          _showSnack('chat.microphone_permission'.tr);
          return true;
        }
      }

      await _resetVoiceModeSubscriptions();
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
          !identical(_realtimeVoice, realtime) ||
          !identical(_mic, mic)) {
        return true;
      }
      _clearVoiceTranscript();
      setState(() {
        _voiceMode = true;
        _realtimeVoiceActive = true;
        _realtimeVoiceSession = realtime;
      });
      _notifyInputActivity(PresenceInputActivityKind.voiceModeEntry);
      await realtime.joinAgent(agentId: 'self');
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr) ||
          !identical(_realtimeVoice, realtime) ||
          !identical(_mic, mic)) {
        await realtime.leave();
        _clearRealtimeVoiceEntry(realtime);
      } else {
        voiceInputRetirementCoordinator.confirmVoiceSessionIntent(
          this,
          _voiceEntryScope,
        );
      }
      return true;
    } catch (e) {
      await realtime.leave();
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) {
        _clearRealtimeVoiceEntry(realtime);
        return true;
      }
      Log.w('🎙️ [RealtimeVoice] join failed: $e');
      _clearRealtimeVoiceEntry(realtime);
      _showSnack('chat.realtime_voice_failed'.tr);
      return true;
    }
  }

  Future<void> _exitVoice({
    bool send = true,
    bool preserveIntent = false,
  }) async {
    final homeExit = _voiceUsesIsolatedBuffer || _homeComposerMode;
    if (homeExit) {
      _homeVoiceExitCount++;
      _voiceBindingGeneration++;
      _homeVoiceText = '';
    }
    try {
      if (!preserveIntent) {
        voiceInputRetirementCoordinator.endVoiceSessionIntent(this);
      }
      _invalidateVoiceEntry();
      if (!_voiceMode) return;
      if (_realtimeVoiceActive) {
        setState(() => _voiceMode = false);
        _realtimeVoiceActive = false;
        final realtime = _realtimeVoiceSession;
        _realtimeVoiceSession = null;
        _setAgentSpeaking(false);
        await _resetVoiceModeSubscriptions();
        if (realtime != null) {
          final leave = realtime.leave();
          voiceInputRetirementCoordinator.track(
            key: realtime,
            retirement: leave,
            retry: realtime.leave,
          );
          await leave;
        }
        _clearVoiceTranscript();
        _releaseVoiceOwnership();
        return;
      }
      if (_nativeAsrActive) {
        if (send) {
          await _finalizeNativeAsrFromVad(source: 'manual');
        } else {
          await _cleanupNativeAsrVoice(cancelRecognizer: true);
        }
        return;
      }
      await _cleanupNativeAsrVoice(cancelRecognizer: true);
    } finally {
      if (homeExit) {
        _homeVoiceExitCount--;
        _refreshHomePresentation();
        _releaseVoiceOwnership();
      }
    }
  }

  void _onVadSpeaking(bool speaking) {
    if (!_voiceMode ||
        !_nativeAsrActive ||
        _agentSpeaking ||
        _voiceTurnInFlight) {
      return;
    }
    Log.i(
      '🎙️ [Voice] VAD speaking=$speaking heard=$_heardSpeech '
      'nativeAsr=${_platformAsr?.isListening.value}',
    );
    if (speaking) {
      _heardSpeech = true;
      _nativeAsrFallbackTimer?.cancel();
      _nativeAsrFallbackTimer = null;
      _autoSubmitTimer?.cancel();
      _autoSubmitTimer = null;
      _noSpeechTimer?.cancel();
      _noSpeechTimer = null;
      return;
    }
    if (!_heardSpeech) return;
    if (_desktopLocalAsrSession != null ||
        _platformAsr?.supportsExternalAudioInput == true) {
      return;
    }
    _autoSubmitTimer?.cancel();
    _autoSubmitTimer = Timer(_autoSubmitSilence, () {
      if (!_voiceMode) return;
      _finalizeNativeAsrFromVad(source: 'vad');
    });
  }

  void _onVadSpeechEnded(UserSpeakingEndedEvent event) {
    if (!_voiceMode ||
        !_nativeAsrActive ||
        _agentSpeaking ||
        _voiceTurnInFlight ||
        !voiceInputRetirementCoordinator.isOwner(this)) {
      return;
    }
    _heardSpeech = true;
    final operation = _voiceSegmentOperations.track(
      _runVoiceSegmentOperation(event, source: 'vad-segment'),
    );
    unawaited(
      operation.then<void>((_) {
        if (!_voiceMode) _releaseVoiceOwnership();
      }),
    );
  }

  void _onPlaybackCandidateStarted(PlaybackSpeechCandidateStartedEvent event) {
    if (!_voiceMode ||
        !_nativeAsrActive ||
        !_allowsAcousticBargeIn() ||
        !voiceInputRetirementCoordinator.isOwner(this) ||
        _playbackCandidateAttempt != null) {
      return;
    }
    final controller = _bargeInController;
    if (controller == null) return;
    final hold = _mic?.holdPlaybackCandidateCapture();
    if (hold == null) {
      Log.w('🎙️ [BargeIn] candidate ignored without an exact mic hold');
      return;
    }
    final attempt = _PlaybackCandidateAttempt(
      generation: ++_playbackCandidateGeneration,
      voiceSessionGeneration: _voiceSessionGeneration,
      controller: controller,
      captureHold: hold,
    );
    _playbackCandidateAttempt = attempt;
    unawaited(_beginPlaybackCandidate(attempt));
  }

  Future<void> _beginPlaybackCandidate(
    _PlaybackCandidateAttempt attempt,
  ) async {
    BargeInLease? lease;
    try {
      lease = await attempt.controller.beginCandidate(agentId: 'self');
    } on Object catch (error, stackTrace) {
      Log.w(
        '🎙️ [BargeIn] output pause failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      attempt.completeLease(lease);
    }
    if (!_playbackCandidateIsCurrent(attempt)) {
      if (!attempt.resolving) {
        if (lease != null) {
          await attempt.controller.cancelCandidate(lease, agentId: 'self');
        }
        attempt.completeSettled();
      }
      return;
    }
    if (lease == null) _clearPlaybackCandidate(attempt);
  }

  void _onPlaybackCandidateEnded(PlaybackSpeechCandidateEndedEvent event) {
    final attempt = _playbackCandidateAttempt;
    if (attempt == null ||
        attempt.ended ||
        !_playbackCandidateIsCurrent(attempt)) {
      return;
    }
    attempt.ended = true;
    final operation = _voiceSegmentOperations.track(
      _runPlaybackCandidateOperation(attempt, event),
    );
    unawaited(
      operation.then<void>((_) {
        if (!_voiceMode) _releaseVoiceOwnership();
      }),
    );
  }

  Future<void> _runPlaybackCandidateOperation(
    _PlaybackCandidateAttempt attempt,
    PlaybackSpeechCandidateEndedEvent event,
  ) async {
    final lease = await attempt.lease;
    if (lease == null) {
      if (_playbackCandidateIsCurrent(attempt)) {
        _clearPlaybackCandidate(attempt);
      }
      return;
    }
    if (!_playbackCandidateIsCurrent(attempt)) {
      attempt.completeSettled();
      return;
    }
    if (!attempt.controller.markRecognitionPending(lease)) {
      await _recoverPlaybackCandidate(attempt, 'recognition_pending_rejected');
      return;
    }
    if (!attempt.controller.markRecognizing(lease)) {
      await _recoverPlaybackCandidate(attempt, 'recognition_start_rejected');
      return;
    }

    final nativeAsr = _platformAsr;
    final vad = _vad;
    final mic = _mic;
    final voiceProsody = _voiceProsody;
    if (nativeAsr == null || !nativeAsr.supportsExternalAudioInput) {
      await _recoverPlaybackCandidate(attempt, 'external_pcm_unavailable');
      return;
    }
    bool candidateIsCurrent() =>
        _playbackCandidateIsCurrent(attempt) &&
        identical(_platformAsr, nativeAsr) &&
        identical(_voiceProsody, voiceProsody) &&
        identical(_vad, vad) &&
        identical(_mic, mic);

    late final SpeechSegmentProcessingResult result;
    try {
      result = await _speechSegmentProcessor.process(
        platformAsr: nativeAsr,
        samples: event.samples,
        duration: event.duration,
        locale: AppLocalization.locale.toLanguageTag(),
        source: 'playback-candidate',
        isCurrent: candidateIsCurrent,
        voiceProsody: voiceProsody,
        onExternalRecognitionAdmission: () {
          attempt.captureRestartRequired = true;
          _setNativeAsrAwaitingFinal(true);
          _cancelVoiceTimers();
        },
        stopVad: () async => vad?.stop(),
        stopMic: () async => mic?.stop(),
      );
    } on Object catch (error, stackTrace) {
      Log.w(
        '🎙️ [BargeIn] candidate recognition failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      await _recoverPlaybackCandidate(attempt, 'recognition_exception');
      return;
    }
    if (!candidateIsCurrent()) {
      _invalidateProsodyResult(result, voiceProsody);
      return;
    }
    switch (result.status) {
      case SpeechSegmentProcessingStatus.externalRecognitionStarted:
        _prosodyUtteranceId = result.utteranceId;
        _prosodyUtteranceGeneration = result.utteranceGeneration;
        return;
      case SpeechSegmentProcessingStatus.localRecognitionCompleted:
        _prosodyUtteranceId = result.utteranceId;
        _prosodyUtteranceGeneration = result.utteranceGeneration;
        await _resolvePlaybackCandidate(
          attempt,
          result.transcript ?? '',
          source: 'local',
        );
        return;
      case SpeechSegmentProcessingStatus.fallbackFinalizeRequested:
        await _recoverPlaybackCandidate(attempt, 'fallback_not_safe');
        return;
      case SpeechSegmentProcessingStatus.rejected:
        Log.w(
          '🎙️ [BargeIn] candidate rejected: '
          '${result.diagnostic ?? 'no diagnostic'}',
        );
        await _recoverPlaybackCandidate(attempt, 'recognition_rejected');
        return;
    }
  }

  void _onNativeAsrFinal(String text) {
    if (!_voiceMode || !_nativeAsrActive) return;
    final attempt = _playbackCandidateAttempt;
    if (attempt != null && _playbackCandidateIsCurrent(attempt)) {
      unawaited(
        _resolvePlaybackCandidate(attempt, text.trim(), source: 'final'),
      );
      return;
    }
    _submitNativeAsrText(text.trim(), source: 'final');
  }

  Future<void> _resolvePlaybackCandidate(
    _PlaybackCandidateAttempt attempt,
    String text, {
    required String source,
  }) async {
    final lease = await attempt.lease;
    if (lease == null ||
        attempt.resolving ||
        !_playbackCandidateIsCurrent(attempt)) {
      return;
    }
    attempt.resolving = true;
    late final BargeInOutcome outcome;
    try {
      outcome = await attempt.controller.resolveCandidate(
        lease,
        text,
        agentId: 'self',
      );
    } on Object catch (error, stackTrace) {
      Log.w(
        '🎙️ [BargeIn] candidate resolution failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      if (_playbackCandidateIsCurrent(attempt)) {
        _clearPlaybackCandidate(attempt);
        _setNativeAsrAwaitingFinal(false);
        _discardProsodyUtterance();
        _scheduleNativeVoiceRestart();
      } else {
        attempt.completeSettled();
      }
      return;
    }
    if (!_playbackCandidateIsCurrent(attempt)) {
      attempt.completeSettled();
      return;
    }
    _clearPlaybackCandidate(attempt);
    _setNativeAsrAwaitingFinal(false);
    if (outcome != BargeInOutcome.interrupted) {
      _discardProsodyUtterance();
      Log.i('🎙️ [BargeIn] candidate $source outcome=${outcome.name}');
      _scheduleNativeVoiceRestart();
      return;
    }

    Log.i('🎙️ [BargeIn] semantic interruption accepted source=$source');
    await _voiceTurnSends.waitForActive();
    if (!mounted ||
        !_voiceMode ||
        !_nativeAsrActive ||
        !voiceInputRetirementCoordinator.isOwner(this)) {
      _discardProsodyUtterance();
      return;
    }
    _submitNativeAsrText(text, source: 'barge-in-$source');
  }

  Future<void> _recoverPlaybackCandidate(
    _PlaybackCandidateAttempt attempt,
    String diagnostic,
  ) async {
    final lease = await attempt.lease;
    if (lease == null ||
        attempt.resolving ||
        !_playbackCandidateIsCurrent(attempt)) {
      return;
    }
    attempt.resolving = true;
    await attempt.controller.recoverCandidate(lease);
    if (!_playbackCandidateIsCurrent(attempt)) {
      attempt.completeSettled();
      return;
    }
    Log.w('🎙️ [BargeIn] candidate recovered reason=$diagnostic');
    _clearPlaybackCandidate(attempt);
    _setNativeAsrAwaitingFinal(false);
    _discardProsodyUtterance();
    _scheduleNativeVoiceRestart();
  }

  bool _playbackCandidateIsCurrent(_PlaybackCandidateAttempt attempt) =>
      mounted &&
      identical(_playbackCandidateAttempt, attempt) &&
      attempt.generation == _playbackCandidateGeneration &&
      attempt.voiceSessionGeneration == _voiceSessionGeneration &&
      identical(_bargeInController, attempt.controller) &&
      _voiceMode &&
      _nativeAsrActive &&
      voiceInputRetirementCoordinator.isOwner(this);

  void _onBargeInControllerInactive(_PlaybackCandidateAttempt attempt) {
    if (!_playbackCandidateIsCurrent(attempt) || attempt.resolving) return;
    attempt.resolving = true;
    final restartCapture = attempt.captureRestartRequired;
    Log.w('🎙️ [BargeIn] controller timeout recovered candidate');
    _setNativeAsrAwaitingFinal(false);
    _discardProsodyUtterance();
    if (restartCapture) {
      // Keep a resolving tombstone until restart teardown cancels the exact
      // lease. A delayed native final in this window must not become a normal
      // user turn merely because the controller watchdog resumed playback.
      attempt.releaseHold();
      _scheduleNativeVoiceRestart();
    } else {
      _clearPlaybackCandidate(attempt);
    }
  }

  void _clearPlaybackCandidate(_PlaybackCandidateAttempt attempt) {
    attempt.releaseHold();
    if (!identical(_playbackCandidateAttempt, attempt)) {
      attempt.completeSettled();
      return;
    }
    _playbackCandidateAttempt = null;
    attempt.completeSettled();
  }

  Future<void> _cancelPlaybackCandidate() async {
    final attempt = _playbackCandidateAttempt;
    if (attempt == null) return;
    _playbackCandidateGeneration++;
    _playbackCandidateAttempt = null;
    attempt.releaseHold();
    attempt.resolving = true;
    try {
      final lease = await attempt.lease;
      if (lease != null) {
        await attempt.controller.cancelCandidate(lease, agentId: 'self');
      }
    } finally {
      attempt.completeSettled();
    }
  }

  void _invalidateProsodyResult(
    SpeechSegmentProcessingResult result,
    VoiceProsodyService? voiceProsody,
  ) {
    final utteranceId = result.utteranceId;
    final utteranceGeneration = result.utteranceGeneration;
    if (utteranceId == null || utteranceGeneration == null) return;
    voiceProsody?.invalidateActiveUtterance(
      utteranceId: utteranceId,
      nextGeneration: utteranceGeneration + 1,
    );
  }

  Future<void> _runVoiceSegmentOperation(
    UserSpeakingEndedEvent event, {
    required String source,
  }) async {
    try {
      await _recognizeNativeAsrSegment(event, source: source);
    } on Object catch (error, stackTrace) {
      Log.w(
        '🎙️ [Voice] segment operation failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await _cleanupNativeAsrVoice(
          cancelRecognizer: true,
          drainSegmentOperations: false,
        );
      } on Object catch (cleanupError, cleanupStackTrace) {
        Log.w(
          '🎙️ [Voice] segment cleanup failed: $cleanupError',
          error: cleanupError,
          stackTrace: cleanupStackTrace,
        );
      }
    }
  }

  void _onNativeAsrError(String? message) {
    if (!_voiceMode || !_nativeAsrActive) return;
    final errorText = message?.trim();
    if (errorText == null || errorText.isEmpty) return;
    Log.w('🎙️ [Voice] native ASR error while listening: $errorText');
    final candidate = _playbackCandidateAttempt;
    if (candidate != null && _playbackCandidateIsCurrent(candidate)) {
      unawaited(_recoverPlaybackCandidate(candidate, 'native_asr_error'));
      return;
    }
    if (_voiceTranscriptText.trim().isNotEmpty) {
      _submitNativeAsrText(
        _voiceTranscriptText.trim(),
        source: 'partial-after-error',
      );
      return;
    }
    if (_heardSpeech) {
      _showSnack('chat.voice_recognition_failed'.tr);
    }
    unawaited(_cleanupNativeAsrVoice(cancelRecognizer: false));
  }

  Future<void> _finalizeNativeAsrFromVad({required String source}) async {
    if (!_voiceMode || !_nativeAsrActive || _nativeAsrAwaitingFinal) return;
    if (_desktopLocalAsrSession != null) {
      Log.i('🎙️ [LocalASR] manual stop cancels the unfinished VAD segment');
      await _cleanupNativeAsrVoice(cancelRecognizer: false);
      return;
    }
    _setNativeAsrAwaitingFinal(true);
    _cancelVoiceTimers();
    Log.i('🎙️ [Voice] native ASR finalize requested by $source');
    await _platformAsr?.stop();
    _nativeAsrFallbackTimer?.cancel();
    _nativeAsrFallbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (!_voiceMode || !_nativeAsrActive) return;
      _submitNativeAsrText(_voiceTranscriptText.trim(), source: 'partial');
    });
  }

  Future<void> _recognizeNativeAsrSegment(
    UserSpeakingEndedEvent event, {
    required String source,
  }) async {
    if (!_voiceMode || !_nativeAsrActive || _nativeAsrAwaitingFinal) return;
    final sessionGeneration = _voiceSessionGeneration;
    final nativeAsr = _platformAsr;
    if (nativeAsr == null) return;
    final desktopLocalAsr = _desktopLocalAsrSession;
    final vad = _vad;
    final mic = _mic;
    final voiceProsody = _voiceProsody;
    bool segmentIsCurrent() =>
        mounted &&
        sessionGeneration == _voiceSessionGeneration &&
        voiceInputRetirementCoordinator.isOwner(this) &&
        identical(_platformAsr, nativeAsr) &&
        identical(_voiceProsody, voiceProsody) &&
        identical(_vad, vad) &&
        identical(_mic, mic) &&
        (desktopLocalAsr == null ||
            identical(_desktopLocalAsr, desktopLocalAsr)) &&
        _voiceMode &&
        _nativeAsrActive;
    final result = await _speechSegmentProcessor.process(
      platformAsr: nativeAsr,
      desktopLocalAsr: _desktopLocalAsrSession,
      samples: event.samples,
      duration: event.duration,
      locale: AppLocalization.locale.toLanguageTag(),
      source: source,
      isCurrent: segmentIsCurrent,
      voiceProsody: voiceProsody,
      onExternalRecognitionAdmission: () {
        _setNativeAsrAwaitingFinal(true);
        _cancelVoiceTimers();
      },
      stopVad: () async {
        await vad?.stop();
      },
      stopMic: () async {
        await mic?.stop();
      },
    );
    if (!mounted ||
        sessionGeneration != _voiceSessionGeneration ||
        !identical(_platformAsr, nativeAsr) ||
        !identical(_voiceProsody, voiceProsody) ||
        (desktopLocalAsr != null &&
            !identical(_desktopLocalAsr, desktopLocalAsr)) ||
        !_voiceMode ||
        !_nativeAsrActive) {
      final utteranceId = result.utteranceId;
      final utteranceGeneration = result.utteranceGeneration;
      if (utteranceId != null && utteranceGeneration != null) {
        voiceProsody?.invalidateActiveUtterance(
          utteranceId: utteranceId,
          nextGeneration: utteranceGeneration + 1,
        );
      }
      return;
    }
    switch (result.status) {
      case SpeechSegmentProcessingStatus.fallbackFinalizeRequested:
        await _finalizeNativeAsrFromVad(source: source);
        return;
      case SpeechSegmentProcessingStatus.rejected:
        Log.w(
          '🎙️ [NativeASR] sample recognition failed: '
          '${result.diagnostic ?? 'no diagnostic'}',
        );
        _showSnack('chat.voice_recognition_failed'.tr);
        await _cleanupNativeAsrVoice(
          cancelRecognizer: true,
          drainSegmentOperations: false,
        );
        return;
      case SpeechSegmentProcessingStatus.externalRecognitionStarted:
        _prosodyUtteranceId = result.utteranceId;
        _prosodyUtteranceGeneration = result.utteranceGeneration;
        break;
      case SpeechSegmentProcessingStatus.localRecognitionCompleted:
        _prosodyUtteranceId = result.utteranceId;
        _prosodyUtteranceGeneration = result.utteranceGeneration;
        _submitNativeAsrText(result.transcript ?? '', source: 'local');
        return;
    }
    _nativeAsrFallbackTimer?.cancel();
    _nativeAsrFallbackTimer = Timer(const Duration(seconds: 4), () {
      if (!_voiceMode || !_nativeAsrActive) return;
      _submitNativeAsrText(_voiceTranscriptText.trim(), source: 'partial');
    });
  }

  void _submitNativeAsrText(String text, {required String source}) {
    if (_voiceTurnInFlight) return;
    _nativeAsrFallbackTimer?.cancel();
    _nativeAsrFallbackTimer = null;
    final finalText = text.trim();
    Log.i('🎙️ [ASR] utterance sent from=$source chars=${finalText.length}');
    final isolated = _voiceUsesIsolatedBuffer;
    final voiceTextSend = widget.onVoiceTextSend;
    final voiceSend = widget.onVoiceSend;
    final legacySend = widget.onSend;
    final controller = widget.controller;
    final binding = _voiceBindingGeneration;
    final scope = _voiceEntryScope;
    if (isolated && (!_homeComposerMode || voiceTextSend == null)) {
      _homeVoiceText = '';
      unawaited(_cleanupNativeAsrVoice(cancelRecognizer: true));
      return;
    }
    _writeVoiceTranscript(finalText);
    final shouldSubmit = finalText.isNotEmpty && widget.enabled;
    final reservation = shouldSubmit ? _voiceTurnSends.reserve() : null;
    if (shouldSubmit && reservation == null) return;
    if (shouldSubmit) {
      _claimProsodyForNextTurn();
    } else {
      _discardProsodyUtterance();
    }
    _scheduleNativeVoiceRestart(
      submittedText: finalText,
      reservation: reservation,
      onSubmit: shouldSubmit
          ? () async {
              if (!mounted ||
                  _disposing ||
                  binding != _voiceBindingGeneration ||
                  !identical(controller, widget.controller) ||
                  scope !=
                      voiceInputRetirementCoordinator.voiceSessionScopeKey) {
                return;
              }
              if (isolated &&
                  (!_homeComposerMode ||
                      !widget.enabled ||
                      !voiceInputRetirementCoordinator.isOwner(this))) {
                return;
              }
              _notifyInputActivity(
                PresenceInputActivityKind.voiceUtteranceEnded,
              );
              if (isolated) {
                await voiceTextSend!(finalText);
              } else if (voiceSend != null) {
                await voiceSend();
              } else {
                legacySend();
              }
            }
          : null,
    );
  }

  void _scheduleNativeVoiceRestart({
    String submittedText = '',
    VoiceTurnSendReservation? reservation,
    Future<void> Function()? onSubmit,
  }) {
    final sessionGeneration = _voiceSessionGeneration;
    Future<void> restart() => _restartNativeAsrVoiceAfterSubmit(
      submittedText: submittedText,
      reservation: reservation,
      onSubmit: onSubmit,
    );
    void cancelReservation() {
      if (reservation != null) _voiceTurnSends.cancelReservation(reservation);
    }

    if (_voiceSegmentOperations.isActive) {
      final scheduled = runVoiceInputAfterOperationDrain(
        operations: _voiceSegmentOperations,
        isCurrent: () =>
            mounted &&
            sessionGeneration == _voiceSessionGeneration &&
            voiceInputRetirementCoordinator.isOwner(this) &&
            _voiceMode &&
            _nativeAsrActive,
        action: restart,
      );
      unawaited(
        scheduled.then<void>(
          (ran) {
            if (!ran) cancelReservation();
          },
          onError: (Object error, StackTrace stackTrace) {
            cancelReservation();
            Log.w(
              '🎙️ [Voice] deferred capture restart failed: $error',
              error: error,
              stackTrace: stackTrace,
            );
          },
        ),
      );
      return;
    }
    unawaited(
      restart().catchError((Object error, StackTrace stackTrace) {
        cancelReservation();
        Log.w(
          '🎙️ [Voice] capture restart failed: $error',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _restartNativeAsrVoiceAfterSubmit({
    String submittedText = '',
    VoiceTurnSendReservation? reservation,
    Future<void> Function()? onSubmit,
  }) async {
    final isolated = _voiceUsesIsolatedBuffer;
    final binding = _voiceBindingGeneration;
    if (!_voiceMode && !_nativeAsrActive) {
      if (reservation != null) {
        _voiceTurnSends.cancelReservation(reservation);
      }
      return;
    }
    final entryGeneration = _beginVoiceEntry(allowActiveVoiceMode: true);
    if (entryGeneration == null) {
      if (reservation != null) {
        _voiceTurnSends.cancelReservation(reservation);
      }
      return;
    }
    final desktopLocalAsr = _desktopLocalAsr;
    var sendLaunched = false;
    try {
      _voiceSessionGeneration++;
      _nativeAsrActive = false;
      _desktopLocalAsrSession = null;
      _setNativeAsrAwaitingFinal(false);
      _setAgentSpeaking(false);
      _heardSpeech = false;
      final resources = _nativeVoiceEntryResources;
      if (resources != null) {
        await _retireNativeVoiceEntryResources(
          resources,
          cancelRecognizer: true,
        );
      } else {
        await _resetVoiceModeSubscriptions();
      }
      if (!_voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)) return;
      await _enterNativeAsrWithVadVoice(
        entryGeneration: entryGeneration,
        desktopLocalAsr: desktopLocalAsr,
        armNoSpeechTimeout: false,
      );
      if (onSubmit != null &&
          reservation != null &&
          mounted &&
          binding == _voiceBindingGeneration &&
          (!isolated ||
              (_homeComposerMode &&
                  widget.onVoiceTextSend != null &&
                  _voiceEntryIsCurrent(entryGeneration, desktopLocalAsr)))) {
        // Legacy callbacks read their shared field synchronously. Home sends
        // captured text directly and must not overwrite the reopened ASR's
        // next partial transcript (or the user's independent typed draft).
        if (!isolated) {
          widget.controller.text = submittedText;
          widget.controller.selection = TextSelection.collapsed(
            offset: submittedText.length,
          );
        }
        final tracked = _voiceTurnSends.launch(
          reservation,
          onSubmit,
          onError: (error, stackTrace) {
            Log.w(
              '🎙️ [Voice] submitted turn failed: $error',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
        sendLaunched = tracked != null;
        if (!isolated &&
            widget.controller.text.trim() == submittedText.trim()) {
          widget.controller.clear();
        }
      }
    } finally {
      if (!sendLaunched && reservation != null) {
        _voiceTurnSends.cancelReservation(reservation);
      }
      _finishVoiceEntry(entryGeneration);
      if (!_voiceMode) _releaseVoiceOwnership();
    }
  }

  Future<void> _cleanupNativeAsrVoice({
    required bool cancelRecognizer,
    bool drainSegmentOperations = true,
  }) async {
    if (_voiceUsesIsolatedBuffer) _homeVoiceText = '';
    _invalidateVoiceEntry();
    _discardProsodyUtterance();
    final resources = _nativeVoiceEntryResources;
    if (!_voiceMode &&
        !_nativeAsrActive &&
        resources == null &&
        !_voiceSegmentOperations.isActive) {
      _releaseVoiceOwnership();
      return;
    }
    _voiceSessionGeneration++;
    if (mounted) setState(() => _voiceMode = false);
    _nativeAsrActive = false;
    _desktopLocalAsrSession = null;
    _setNativeAsrAwaitingFinal(false);
    _setAgentSpeaking(false);
    late final Future<void> Function() retireResources;
    if (resources != null) {
      retireResources = () => _retireNativeVoiceEntryResources(
        resources,
        cancelRecognizer: cancelRecognizer,
      );
    } else {
      final vad = _vad;
      final mic = _mic;
      final platformAsr = _platformAsr;
      retireResources = () =>
          runVoiceInputCleanupSteps(<FutureOr<void> Function()>[
            _resetVoiceModeSubscriptions,
            () async => vad?.stop(),
            () async => mic?.stop(),
            () async {
              if (cancelRecognizer) await platformAsr?.cancelAndDrain();
            },
          ]);
    }
    if (drainSegmentOperations) {
      await retireVoiceInputResourcesWithOperationDrain(
        retireResources: retireResources,
        operations: _voiceSegmentOperations,
      );
    } else {
      await retireResources();
    }
    _releaseVoiceOwnership();
  }

  void _claimProsodyForNextTurn() {
    final id = _prosodyUtteranceId;
    final generation = _prosodyUtteranceGeneration;
    _prosodyUtteranceId = null;
    _prosodyUtteranceGeneration = null;
    if (id == null || generation == null) return;
    _voiceProsody?.markActiveUtteranceForNextTurn(
      utteranceId: id,
      utteranceGeneration: generation,
    );
  }

  void _discardProsodyUtterance() {
    final id = _prosodyUtteranceId;
    final generation = _prosodyUtteranceGeneration;
    _prosodyUtteranceId = null;
    _prosodyUtteranceGeneration = null;
    if (id == null || generation == null) return;
    _voiceProsody?.invalidateActiveUtterance(
      utteranceId: id,
      nextGeneration: generation + 1,
    );
  }

  void _armNoSpeechTimeout() {
    _noSpeechTimer?.cancel();
    _noSpeechTimer = Timer(_noSpeechTimeout, () {
      if (!_voiceMode || _heardSpeech) return;
      _exitVoice(send: false);
    });
  }

  void _cancelVoiceTimers() {
    _autoSubmitTimer?.cancel();
    _autoSubmitTimer = null;
    _noSpeechTimer?.cancel();
    _noSpeechTimer = null;
    _nativeAsrFallbackTimer?.cancel();
    _nativeAsrFallbackTimer = null;
  }

  Future<void> _resetVoiceModeSubscriptions() async {
    _cancelVoiceTimers();
    await runVoiceInputCleanupSteps(<FutureOr<void> Function()>[
      () async {
        final subscription = _playbackCandidateStartedSub;
        if (subscription == null) return;
        await subscription.cancel();
        if (identical(_playbackCandidateStartedSub, subscription)) {
          _playbackCandidateStartedSub = null;
        }
      },
      () async {
        final subscription = _playbackCandidateEndedSub;
        if (subscription == null) return;
        await subscription.cancel();
        if (identical(_playbackCandidateEndedSub, subscription)) {
          _playbackCandidateEndedSub = null;
        }
      },
      _cancelPlaybackCandidate,
      () {
        _playbackWorker?.dispose();
        _playbackWorker = null;
      },
      () {
        _nativeAsrTranscriptWorker?.dispose();
        _nativeAsrTranscriptWorker = null;
      },
      () {
        _nativeAsrErrorWorker?.dispose();
        _nativeAsrErrorWorker = null;
      },
      () async {
        final subscription = _nativeAsrFinalSub;
        if (subscription == null) return;
        await subscription.cancel();
        if (identical(_nativeAsrFinalSub, subscription)) {
          _nativeAsrFinalSub = null;
        }
      },
      () {
        _vadSpeakingWorker?.dispose();
        _vadSpeakingWorker = null;
      },
      () {
        _bargeInActiveWorker?.dispose();
        _bargeInActiveWorker = null;
      },
      () async {
        final subscription = _vadEndedSub;
        if (subscription == null) return;
        await subscription.cancel();
        if (identical(_vadEndedSub, subscription)) _vadEndedSub = null;
      },
    ]);
  }

  void _showSnack(String msg) {
    showAppGlassNotice(
      title: 'chat.voice_title'.tr,
      message: msg,
      icon: Icons.mic_none_rounded,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  void didUpdateWidget(covariant ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bindingChanged =
        !identical(oldWidget.controller, widget.controller) ||
        oldWidget.homeComposerMode != widget.homeComposerMode ||
        oldWidget.voiceOnly != widget.voiceOnly ||
        (oldWidget.homeComposerMode &&
            oldWidget.onVoiceTextSend != null &&
            widget.onVoiceTextSend == null);
    if (bindingChanged) {
      _voiceBindingGeneration++;
      _homeVoiceText = '';
      _invalidateVoiceEntry();
      if (oldWidget.homeComposerMode || widget.homeComposerMode) {
        voiceInputRetirementCoordinator.endVoiceSessionIntent(this);
      }
      unawaited(
        _relinquishVoiceOwnership().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          Log.w(
            '🎙️ [Voice] replaced input retirement failed',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    }
    if (oldWidget.enabled && !widget.enabled) {
      _invalidateVoiceEntry();
      if (_voiceMode) {
        unawaited(_exitVoice(send: false, preserveIntent: true));
      }
    }
    _scheduleVoiceVisibilitySync();
    if (!oldWidget.startInVoiceMode && widget.startInVoiceMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_enterVoice());
      });
    }
  }

  @override
  void dispose() {
    _disposing = true;
    _voiceBindingGeneration++;
    _homeVoiceText = '';
    WidgetsBinding.instance.removeObserver(this);
    voiceInputRetirementCoordinator.sessionIntentRevision.removeListener(
      _handleVoiceSessionIntent,
    );
    final pendingEntry = _voiceEntryDone?.future;
    final pendingCleanup = _nativeVoiceCleanupFuture;
    _invalidateVoiceEntry();
    _voiceSessionGeneration++;
    _voiceMode = false;
    _nativeAsrActive = false;
    _desktopLocalAsrSession = null;
    _cancelVoiceTimers();
    _playbackWorker?.dispose();
    _nativeAsrTranscriptWorker?.dispose();
    _nativeAsrErrorWorker?.dispose();
    _nativeAsrFinalSub?.cancel();
    _vadSpeakingWorker?.dispose();
    _bargeInActiveWorker?.dispose();
    _vadEndedSub?.cancel();
    _playbackCandidateStartedSub?.cancel();
    _playbackCandidateEndedSub?.cancel();
    final retirements = <Future<void>>[_cancelPlaybackCandidate()];
    final realtime = _realtimeVoiceSession;
    if (_realtimeVoiceActive && realtime != null) {
      final leave = realtime.leave();
      voiceInputRetirementCoordinator.track(
        key: realtime,
        retirement: leave,
        retry: realtime.leave,
      );
      retirements.add(leave);
    }
    _realtimeVoiceActive = false;
    _realtimeVoiceSession = null;
    final resources = _nativeVoiceEntryResources;
    if (pendingCleanup != null) {
      retirements.add(pendingCleanup);
    } else if (resources != null) {
      retirements.add(
        _retireNativeVoiceEntryResources(resources, cancelRecognizer: true),
      );
    }
    if (pendingEntry != null) retirements.add(pendingEntry);
    if (_voiceSegmentOperations.isActive) {
      retirements.add(_voiceSegmentOperations.drain());
    }
    if (retirements.isEmpty) {
      _releaseVoiceOwnership();
    } else {
      final retirement = () async {
        await Future.wait<void>(retirements);
        if (resources != null) {
          await _retireNativeVoiceEntryResources(
            resources,
            cancelRecognizer: true,
          );
        }
      }();
      _voiceRetirementFuture = retirement;
      unawaited(
        retirement.then<void>(
          (_) {
            if (identical(_voiceRetirementFuture, retirement)) {
              _voiceRetirementFuture = null;
            }
            _releaseVoiceOwnership();
          },
          onError: (Object error, StackTrace stackTrace) {
            Log.w('🎙️ [Voice] dispose cleanup failed: $error');
            if (identical(_voiceRetirementFuture, retirement)) {
              _voiceRetirementFuture = null;
            }
          },
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mic = _mic;
    final voiceActive = _voiceMode || widget.voiceOnly;
    final interrupt = widget.onInterrupt;
    final canInterruptFromVoice =
        !_homeComposerMode &&
        widget.enabled &&
        voiceActive &&
        widget.isThinking &&
        interrupt != null;
    final voicePhase = resolveVoiceOrbPhase(
      playbackActive: _agentSpeaking,
      awaitingFinal: _nativeAsrAwaitingFinal,
      isThinking: widget.isThinking,
    );
    Future<void> exitVoice() => _exitVoice(send: false);
    Widget voiceControlBuilder(BuildContext context, double activation) =>
        _VoiceOrbMode(
          key: const ValueKey('voice-orb'),
          activation: activation,
          onTap: _homeComposerMode
              ? (voiceActive || _homeEntryPending
                    ? exitVoice
                    : _canEnterHomeVoice
                    ? _enterVoice
                    : null)
              : canInterruptFromVoice
              ? interrupt
              : widget.enabled
              ? (_voiceMode
                    ? (widget.voiceOnly ? null : exitVoice)
                    : _enterVoice)
              : null,
          canInterrupt: canInterruptFromVoice,
          phase: voicePhase,
          voiceOnly: widget.voiceOnly,
          amplitude: mic?.amplitude.value ?? 0,
          amplitudeStream: mic?.amplitude.stream,
        );
    final presentationBuilder = widget.presentationBuilder;
    if (_homeComposerMode && presentationBuilder != null) {
      return presentationBuilder(
        context,
        ChatInputPresentation(
          voiceActive: voiceActive,
          enteringVoice: _homeEntryPending,
          canEnterVoice: _canEnterHomeVoice,
          enabled: widget.enabled,
          isThinking: widget.isThinking,
          voiceSubmitBusy: _voiceTurnSends.isBusy,
          phase: voicePhase,
          amplitude: mic?.amplitude.value ?? 0,
          amplitudeStream: mic?.amplitude.stream,
          enterVoice: _enterVoice,
          exitVoice: exitVoice,
          submit: widget.onSend,
          interrupt: interrupt,
          reportInputActivity: _notifyInputActivity,
          voiceControlBuilder: voiceControlBuilder,
        ),
      );
    }
    return AppGlassComposerMorph(
      floatingGlass: widget.floatingGlass,
      textInputBorder: widget.textInputBorder,
      voiceMode: voiceActive || (_homeComposerMode && _homeEntryPending),
      textRadius: 28,
      voiceDiameter: 56,
      editorChild: KeyedSubtree(
        key: const ValueKey('text-composer'),
        child: _TextRow(
          controller: widget.controller,
          onSend: widget.onSend,
          leading: widget.leading,
          hint: widget.hint,
          enabled: widget.enabled,
          maxLength: widget.maxLength,
          focusNode: widget.focusNode,
          textFieldKey: widget.textFieldKey,
          onInputActivity: _notifyInputActivity,
        ),
      ),
      submitChild: _buildSubmitButton(),
      voiceControlBuilder: voiceControlBuilder,
    );
  }

  Widget _buildSubmitButton() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, child) {
        final hasDraft = value.text.trim().isNotEmpty;
        final canInterrupt =
            !hasDraft && widget.isThinking && widget.onInterrupt != null;
        final enabled =
            widget.enabled && (hasDraft || !widget.isThinking || canInterrupt);
        return WorldComposerSendButton(
          icon: canInterrupt ? Icons.stop_rounded : Icons.arrow_upward,
          tooltip: canInterrupt
              ? 'chat.stop_response'.tr
              : widget.sendTooltip.tr,
          enabled: enabled,
          onTap: enabled
              ? (canInterrupt ? widget.onInterrupt : widget.onSend)
              : null,
        );
      },
    );
  }
}

// ─────────────────────────── Text mode ───────────────────────────

class _TextRow extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final Widget? leading;
  final String hint;
  final bool enabled;
  final int? maxLength;
  final FocusNode? focusNode;
  final Key? textFieldKey;
  final ValueChanged<PresenceInputActivityKind>? onInputActivity;

  const _TextRow({
    required this.controller,
    required this.onSend,
    required this.leading,
    required this.hint,
    required this.enabled,
    required this.maxLength,
    required this.focusNode,
    required this.textFieldKey,
    this.onInputActivity,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 4)],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: TextField(
              key: textFieldKey,
              controller: controller,
              enabled: enabled,
              maxLength: maxLength,
              focusNode: focusNode,
              style: TextStyle(color: glass.foregroundPrimary, fontSize: 15),
              cursorColor: glass.action,
              decoration: InputDecoration(
                hintText: hint.tr,
                hintStyle: TextStyle(
                  color: glass.foregroundSecondary.withValues(alpha: 0.8),
                ),
                filled: false,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                counterText: '',
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              textInputAction: TextInputAction.send,
              onTap: () => onInputActivity?.call(PresenceInputActivityKind.tap),
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              onChanged: (_) =>
                  onInputActivity?.call(PresenceInputActivityKind.typing),
              onSubmitted: (_) {
                if (enabled) onSend();
              },
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────── Voice mode ───────────────────────────

class _VoiceOrbMode extends StatelessWidget {
  const _VoiceOrbMode({
    super.key,
    required this.activation,
    required this.onTap,
    required this.canInterrupt,
    required this.phase,
    required this.voiceOnly,
    required this.amplitude,
    required this.amplitudeStream,
  });

  final double activation;
  final VoidCallback? onTap;
  final bool canInterrupt;
  final VoiceOrbPhase phase;
  final bool voiceOnly;
  final double amplitude;
  final Stream<double>? amplitudeStream;

  @override
  Widget build(BuildContext context) {
    final activeLabel = canInterrupt
        ? 'chat.stop_response'.tr
        : _voiceOrbSemanticLabel(phase, voiceOnly: voiceOnly);
    final label = activation > 0.001
        ? activeLabel
        : 'chat.start_voice_input'.tr;
    return Semantics(
      label: label,
      button: onTap != null,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: AppGlassVoiceToggle(
            activation: activation,
            phase: phase,
            amplitude: amplitude,
            amplitudeStream: amplitudeStream,
            reducedMotion:
                MediaQuery.maybeOf(context)?.disableAnimations ?? false,
            size: 56,
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

String _voiceOrbSemanticLabel(VoiceOrbPhase phase, {required bool voiceOnly}) {
  if (voiceOnly) {
    return switch (phase) {
      VoiceOrbPhase.listening => 'chat.voice_listening'.tr,
      VoiceOrbPhase.recognizing => 'chat.voice_recognizing'.tr,
      VoiceOrbPhase.thinking => 'chat.voice_thinking'.tr,
      VoiceOrbPhase.speaking => 'chat.voice_speaking'.tr,
    };
  }
  return switch (phase) {
    VoiceOrbPhase.listening => 'chat.voice_listening_return_keyboard'.tr,
    VoiceOrbPhase.recognizing => 'chat.voice_recognizing_return_keyboard'.tr,
    VoiceOrbPhase.thinking => 'chat.voice_thinking_return_keyboard'.tr,
    VoiceOrbPhase.speaking => 'chat.voice_speaking_return_keyboard'.tr,
  };
}

final class _NativeVoiceEntryResources {
  _NativeVoiceEntryResources({
    required this.entryGeneration,
    required this.platformAsr,
    required this.mic,
  });

  final int entryGeneration;
  final PlatformAsrService platformAsr;
  final MicCaptureService mic;
  VadService? vad;
  bool cancelRecognizer = false;
  bool cleanupRequired = false;
  Future<void>? cleanupFuture;
}

final class _PlaybackCandidateAttempt {
  _PlaybackCandidateAttempt({
    required this.generation,
    required this.voiceSessionGeneration,
    required this.controller,
    required PlaybackCandidateCaptureHold captureHold,
  }) : _captureHold = captureHold;

  final int generation;
  final int voiceSessionGeneration;
  final BargeInController controller;
  PlaybackCandidateCaptureHold? _captureHold;
  final Completer<BargeInLease?> _lease = Completer<BargeInLease?>();
  final Completer<void> _settled = Completer<void>();
  bool ended = false;
  bool resolving = false;
  bool captureRestartRequired = false;

  Future<BargeInLease?> get lease => _lease.future;
  Future<void> get settled => _settled.future;

  void completeLease(BargeInLease? value) {
    if (!_lease.isCompleted) _lease.complete(value);
  }

  void completeSettled() {
    if (!_settled.isCompleted) _settled.complete();
  }

  void releaseHold() {
    _captureHold?.release();
    _captureHold = null;
  }
}
