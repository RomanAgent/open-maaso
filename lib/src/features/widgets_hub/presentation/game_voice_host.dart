import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_voice_observation_adapter.dart';
import 'package:maaso/src/features/widgets_hub/presentation/opened_game_snapshot.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Invisible voice/context lifecycle for the existing full-screen player.
class GameVoiceHost extends StatefulWidget {
  const GameVoiceHost({
    required this.playerId,
    required this.scopeKey,
    required this.documentGeneration,
    required this.title,
    required this.summary,
    required this.ready,
    required this.child,
    this.controller,
    this.runtime,
    this.playerIsCurrent,
    this.observation,
    this.bufferedObservations = const [],
    this.contentIdentity,
    super.key,
  });

  final String playerId, scopeKey, title, summary;
  final int documentGeneration;
  final bool ready;
  final WebViewController? controller;
  final SurfaceRuntime? runtime;
  final bool Function()? playerIsCurrent;
  final String? observation;
  final List<String> bufferedObservations;
  final GameContentIdentity? contentIdentity;
  final Widget child;

  @override
  State<GameVoiceHost> createState() => _GameVoiceHostState();
}

class _GameVoiceHostState extends State<GameVoiceHost>
    with WidgetsBindingObserver {
  GameVoiceCompanionSession? _session;
  GameVoiceCompanionService? _service;
  CompanionVoiceSessionController? _voice;
  StreamSubscription<SurfaceEvent>? _events;
  bool _foreground = true;
  bool _active = true;
  bool _routeCurrent = true;
  bool _syncScheduled = false;
  final List<Worker> _scopeWorkers = [];
  Future<void> _bindingTail = Future<void>.value();
  Object _spokenRepliesOwner = Object();

  bool get _visible =>
      mounted &&
      _active &&
      widget.ready &&
      _foreground &&
      _routeCurrent &&
      widget.scopeKey == AppletLocalOwnership.currentScopeKey() &&
      (widget.playerIsCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    voiceInputRetirementCoordinator.sessionIntentRevision.addListener(
      _scheduleSync,
    );
    _scopeWorkers.addAll(AppletLocalOwnership.watchScope(_scheduleSync));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _voice = CompanionSessionScope.maybeOf(context)?.voice;
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant GameVoiceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playerId != oldWidget.playerId ||
        widget.scopeKey != oldWidget.scopeKey ||
        widget.documentGeneration != oldWidget.documentGeneration ||
        !identical(widget.controller, oldWidget.controller) ||
        !identical(widget.runtime, oldWidget.runtime)) {
      _closeSession(retainState: false);
      _spokenRepliesOwner = Object();
    }
    _scheduleSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _scheduleSync();
  }

  @override
  void deactivate() {
    _active = false;
    _closeSession();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _scheduleSync();
  }

  void _scheduleSync() {
    if (!_visible) {
      _closeSession(
        retainState: widget.scopeKey == AppletLocalOwnership.currentScopeKey(),
      );
    }
    if (_syncScheduled || !mounted) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      _syncSession();
      setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _syncSession() {
    if (!_visible) {
      _closeSession();
      return;
    }
    final service = appServices.maybeFind<GameVoiceCompanionService>();
    if (!identical(service, _service)) {
      _service?.revision.removeListener(_scheduleSync);
      _closeSession(retainState: false);
      _service = service;
      service?.revision.addListener(_scheduleSync);
    }
    if (service == null) return;
    final opening = _session == null;
    final session = _session ??= service.openSession(
      scopeKey: widget.scopeKey,
      playerId: widget.playerId,
      documentGeneration: widget.documentGeneration,
      contentIdentity: widget.contentIdentity,
      title: widget.title,
      summary: widget.summary,
      isCurrent: () => _visible,
      spokenRepliesOwner: _spokenRepliesOwner,
      captureScreenshot: () async {
        final controller = widget.controller;
        return controller == null
            ? null
            : OpenedGameSnapshot.capture(controller);
      },
      isCaptureSupported: () =>
          widget.controller != null &&
          OpenedGameSnapshot.isSupported(widget.controller!),
      readVisibleText: () async {
        final controller = widget.controller;
        return controller == null
            ? null
            : GameVoiceObservationAdapter.readVisibleText(controller);
      },
    );
    if (opening) {
      for (final envelope in _retainedState) {
        session.observeEnvelope(envelope, replay: true);
      }
    }
    for (final source in [
      if (widget.observation != null) widget.observation!,
      ...widget.bufferedObservations,
    ]) {
      if (_lastBufferedObservations.contains(source)) continue;
      _lastBufferedObservations.add(source);
      if (_lastBufferedObservations.length > 4) {
        _lastBufferedObservations.removeAt(0);
      }
      final parsed = GameVoiceEnvelope.parse(source);
      if (opening && parsed != null) {
        session.observeEnvelope({
          'kind': 'game.state',
          'revision': parsed.revision,
          'state': parsed.state,
        });
      } else {
        session.observeMessage(source, replay: opening);
      }
      _rememberState(session);
    }
    final runtime = widget.runtime;
    if (opening && runtime != null) session.beginDomProducer();
    if (_events == null && runtime != null) {
      final runtimeSession = runtime.activeSession;
      _events = runtime.onEvent.listen((event) {
        if (!session.isCurrent || !runtime.isSessionCurrent(runtimeSession)) {
          return;
        }
        if (event.event != 'game.state' && event.event != 'game.event') return;
        if (event.data is Map) {
          session.observeEnvelope({
            ...Map<String, Object?>.from(event.data as Map),
            'kind': event.event,
          });
          _rememberState(session);
        }
      });
    }
    final controller = widget.controller;
    if (controller != null && _attachedController != controller) {
      _attachedController = controller;
      final documentGeneration = widget.documentGeneration;
      bool currentBinding() =>
          session.isCurrent &&
          identical(_session, session) &&
          identical(widget.controller, controller) &&
          widget.documentGeneration == documentGeneration;
      _bindingTail = _bindingTail
          .then((_) async {
            if (!currentBinding()) return;
            await GameVoiceObservationAdapter.attach(
              controller,
              (source) {
                if (currentBinding()) {
                  session.observeMessage(source);
                  _rememberState(session);
                }
              },
              mode: widget.runtime == null
                  ? GameVoiceObservationMode.publicRelay
                  : GameVoiceObservationMode.local,
              isCurrent: currentBinding,
            );
          })
          .catchError((Object _) {});
    }
    if (service.preferences.enabled &&
        (service.microphoneRequested ??
            voiceInputRetirementCoordinator.voiceSessionRequestedFor(
              widget.scopeKey,
            ))) {
      _voice?.activate();
    }
  }

  WebViewController? _attachedController;
  final List<String> _lastBufferedObservations = [];
  List<Map<String, Object?>> _retainedState = [];

  void _rememberState(GameVoiceCompanionSession session) {
    _retainedState = session.replayEnvelopes;
  }

  void _closeSession({bool retainState = true}) {
    final session = _session;
    final ownsVoice =
        session != null && identical(_service?.currentSession, session);
    _session = null;
    if (!retainState) {
      _retainedState = [];
    } else if (session != null) {
      _retainedState = session.replayEnvelopes;
    }
    _lastBufferedObservations.clear();
    final controller = _attachedController;
    _attachedController = null;
    session?.close();
    if (controller != null) {
      _bindingTail = _bindingTail
          .then((_) => GameVoiceObservationAdapter.detach(controller))
          .catchError((Object _) {});
    }
    unawaited(_events?.cancel());
    _events = null;
    if (ownsVoice) _voice?.deactivate();
  }

  Future<void> _sendVoice() {
    final session = _session;
    final voice = _voice;
    if (session == null || voice == null || !session.isCurrent) {
      return Future<void>.value();
    }
    return voice.sendVoiceMessage(
      canContinue: () => session.isCurrent,
      onRevoked: session.onRevoked,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    voiceInputRetirementCoordinator.sessionIntentRevision.removeListener(
      _scheduleSync,
    );
    _service?.revision.removeListener(_scheduleSync);
    _closeSession();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final voice = _voice;
    final listening =
        _visible &&
        session?.isCurrent == true &&
        voice != null &&
        _service?.preferences.enabled == true &&
        (_service?.microphoneRequested ??
            voiceInputRetirementCoordinator.voiceSessionRequestedFor(
              widget.scopeKey,
            ));
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (listening)
          Offstage(
            child: SizedBox.square(
              dimension: 56,
              child: ChatInputBar(
                controller: voice.inputController,
                onSend: () => unawaited(_sendVoice()),
                onVoiceSend: _sendVoice,
                onInterrupt: voice.interruptCurrent,
                isThinking: voice.isThinking,
                startInVoiceMode: true,
                inheritVoiceSession: _service?.microphoneRequested != true,
                voiceOnly: true,
                allowRealtimeVoice: false,
              ),
            ),
          ),
      ],
    );
  }
}
