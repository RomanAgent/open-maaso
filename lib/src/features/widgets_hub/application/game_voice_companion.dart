import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/voice_input_retirement.dart';
import 'game_companion_context.dart';
import 'game_companion_speech_policy.dart';
import 'game_perception_coordinator.dart';
import '../data/game_companion_repository.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';

/// Public facts from one visible player. Identity always comes from its host.
final class GameVoiceObservation {
  const GameVoiceObservation({
    required this.scopeKey,
    required this.playerId,
    required this.generation,
    required this.title,
    required this.summary,
    required this.publicState,
    required this.eventKind,
    required this.revision,
    required this.observedAt,
    this.screenshot,
    this.context,
    this.moment,
  });

  final String scopeKey;
  final String playerId;
  final int generation;
  final String title;
  final String summary;
  final Map<String, Object?> publicState;
  final String eventKind;
  final int revision;
  final DateTime observedAt;
  final Uint8List? screenshot;
  final GameCompanionContext? context;
  final GameCompanionMoment? moment;
}

typedef GameVoiceCommentaryDelegate =
    Future<bool> Function(
      GameVoiceObservation observation, {
      required bool Function() isCurrent,
      required Future<void> onRevoked,
    });

/// A read-only page envelope. It cannot choose an account or issue commands.
final class GameVoiceEnvelope {
  GameVoiceEnvelope._(this.kind, this.revision, this.state, this.event);

  static const maxBytes = 12 * 1024;
  static const maxDepth = 8;
  static const maxNodes = 512;
  static const maxStringRunes = 512;
  final String kind;
  final int revision;
  final Map<String, Object?> state;
  final Map<String, Object?>? event;

  static GameVoiceEnvelope? parse(String source) {
    if (source.length > maxBytes || utf8.encode(source).length > maxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(source));
    } on Object {
      return null;
    }
  }

  static GameVoiceEnvelope? fromJson(Object? value) {
    try {
      if (value is! Map ||
          value.keys.any(
            (key) =>
                !const {'kind', 'revision', 'state', 'event'}.contains(key),
          )) {
        return null;
      }
      final kind = value['kind'];
      final revision = value['revision'];
      if ((kind != 'game.state' && kind != 'game.event') ||
          revision is! int ||
          revision < 0 ||
          revision > 9007199254740991 ||
          value['state'] is! Map) {
        return null;
      }
      var nodes = 0;
      Object? snapshot(Object? item, int depth) {
        if (++nodes > maxNodes || depth > maxDepth) {
          throw const FormatException('game_observation_bounds');
        }
        if (item == null || item is bool) return item;
        if (item is num && item.isFinite) return item;
        if (item is String && item.runes.length <= maxStringRunes) return item;
        if (item is List) {
          return List<Object?>.unmodifiable(
            item.map((entry) => snapshot(entry, depth + 1)),
          );
        }
        if (item is Map) {
          return Map<String, Object?>.unmodifiable(
            item.map((key, entry) {
              if (key is! String || key.runes.length > 64) {
                throw const FormatException('game_observation_key');
              }
              return MapEntry(key, snapshot(entry, depth + 1));
            }),
          );
        }
        throw const FormatException('game_observation_type');
      }

      final state = snapshot(value['state'], 0) as Map<String, Object?>;
      Map<String, Object?>? event;
      if (kind == 'game.event') {
        final raw = value['event'];
        if (raw is! Map ||
            raw.keys.any((key) => !const {'type', 'summary'}.contains(key)) ||
            raw['type'] is! String ||
            !RegExp(
              r'^[a-z][a-z0-9_.-]{0,47}$',
            ).hasMatch(raw['type'] as String) ||
            raw['summary'] is! String) {
          return null;
        }
        event = snapshot(raw, 0) as Map<String, Object?>;
      } else if (value.containsKey('event')) {
        return null;
      }
      if (utf8.encode(jsonEncode(value)).length > maxBytes) return null;
      return GameVoiceEnvelope._(kind as String, revision, state, event);
    } on Object {
      return null;
    }
  }
}

/// Account-owned observation and delivery wiring, without a second chat queue.
class GameVoiceCompanionService extends AppService {
  GameVoiceCompanionService({
    required CompanionBrowsingContextService browsingContext,
    required GameVoiceCommentaryDelegate commentary,
    bool Function()? soundEnabled,
    bool Function()? runtimeAvailable,
    bool Function()? userInputPending,
    DateTime Function()? now,
    this.commentInterval = const Duration(seconds: 20),
    this.createPerception,
    this.prepareRuntime,
    this.adapt,
    this.persistPreferences,
    this.disposeAdaptation,
    Stream<Object?>? privacyRevocations,
    GameCompanionPreferences initialPreferences =
        const GameCompanionPreferences(enabled: true),
  }) : _browsingContext = browsingContext,
       _commentary = commentary,
       _soundEnabled = soundEnabled ?? (() => true),
       _runtimeAvailable = runtimeAvailable ?? (() => true),
       _userInputPending =
           userInputPending ??
           (() => voiceInputRetirementCoordinator.hasPendingUserInput),
       _now = now ?? DateTime.now,
       _preferences = initialPreferences {
    _privacySubscription = privacyRevocations?.listen((_) {
      setVisualEnabled(false);
      _current?._invalidateComment();
    });
  }

  final CompanionBrowsingContextService _browsingContext;
  final GameVoiceCommentaryDelegate _commentary;
  final bool Function() _soundEnabled, _runtimeAvailable, _userInputPending;
  final DateTime Function() _now;
  final Duration commentInterval;
  final Future<void> Function(bool Function() isCurrent)? prepareRuntime;
  final GamePerceptionCoordinator? Function(GameVoiceCompanionSession)?
  createPerception;
  final Future<GameCompanionAdaptation> Function(
    GameVoiceCompanionSession,
    GameCompanionDomSnapshot?,
  )?
  adapt;
  final Future<void> Function(GameCompanionPreferences)? persistPreferences;
  final void Function()? disposeAdaptation;
  StreamSubscription<Object?>? _privacySubscription;
  final ValueNotifier<int> revision = ValueNotifier(0);
  final _speechPolicy = GameCompanionSpeechPolicy();
  GameCompanionPreferences _preferences;
  GameCompanionPreferences get preferences => _preferences;
  bool _visualEnabled = false;
  bool get visualEnabled => _visualEnabled;
  bool? _microphoneRequested;
  bool? get microphoneRequested => _microphoneRequested;
  bool _spokenRepliesEnabled = true;
  bool get spokenRepliesEnabled => _spokenRepliesEnabled;
  Object? _spokenRepliesOwner;
  final Expando<bool> _spokenRepliesChoices = Expando<bool>();
  final List<DateTime> _attempts = [];
  DateTime? _lastSpeechStartedAt;
  ({
    String scope,
    String player,
    int document,
    DateTime at,
    GameCompanionDialogueBuffer dialogue,
  })?
  _resumeDialogue;
  int _generation = 0;
  GameVoiceCompanionSession? _current;
  bool _closed = false;
  final List<({DateTime at, String title, String text})> _recentActivities = [];

  GameVoiceCompanionSession? get currentSession =>
      _current?.isCurrent == true ? _current : null;

  void _notify() {
    if (!_closed) revision.value++;
  }

  void setPreferences(GameCompanionPreferences preferences) {
    if (_closed || identical(preferences, _preferences)) return;
    _preferences = preferences;
    _current?._invalidateComment();
    _current?._syncSpeechPermission();
    _current?._syncPerception();
    if (preferences.enabled) _current?._prepareRuntime();
    _current?._publish();
    _notify();
    final save = persistPreferences;
    if (save != null) unawaited(save(preferences).catchError((Object _) {}));
  }

  void setVisualEnabled(bool enabled) {
    if (_closed || _visualEnabled == enabled) return;
    _visualEnabled = enabled;
    _current?._syncPerception();
    _notify();
  }

  void setMicrophoneEnabled(bool enabled) {
    if (_closed || _microphoneRequested == enabled) return;
    _microphoneRequested = enabled;
    _notify();
  }

  /// This player's voice choice never writes the ordinary chat sound setting.
  /// A host-owned token keeps an explicit mute across overlays/backgrounding.
  void setSpokenRepliesEnabled(bool enabled) {
    if (_closed || _spokenRepliesEnabled == enabled) return;
    _spokenRepliesEnabled = enabled;
    final owner = _spokenRepliesOwner;
    if (owner != null) _spokenRepliesChoices[owner] = enabled;
    _current?._invalidateComment();
    _current?._syncSpeechPermission();
    _notify();
  }

  GameVoiceCompanionSession openSession({
    required String scopeKey,
    required String playerId,
    required String title,
    required String summary,
    required bool Function() isCurrent,
    Object? spokenRepliesOwner,
    int documentGeneration = 0,
    GameContentIdentity? contentIdentity,
    Future<Uint8List?> Function()? captureScreenshot,
    bool Function()? isCaptureSupported,
    Future<String?> Function()? readVisibleText,
  }) {
    _current?.close();
    if (_closed) throw StateError('game_voice_service_closed');
    _spokenRepliesOwner = spokenRepliesOwner;
    _spokenRepliesEnabled = spokenRepliesOwner == null
        ? true
        : _spokenRepliesChoices[spokenRepliesOwner] ?? true;
    final resume = _resumeDialogue;
    final dialogue =
        resume != null &&
            resume.scope == scopeKey &&
            resume.player == playerId &&
            resume.document == documentGeneration &&
            _now().difference(resume.at) < const Duration(minutes: 10)
        ? resume.dialogue
        : GameCompanionDialogueBuffer();
    _resumeDialogue = null;
    final session = GameVoiceCompanionSession._(
      service: this,
      dialogue: dialogue,
      scopeKey: scopeKey,
      playerId: playerId,
      generation: ++_generation,
      documentGeneration: documentGeneration,
      contentIdentity: contentIdentity,
      title: _boundedText(title, 220),
      summary: _boundedText(summary, 420),
      isCurrent: isCurrent,
      captureScreenshot: captureScreenshot,
      isCaptureSupported: isCaptureSupported,
      readVisibleText: readVisibleText,
    );
    _current = session;
    session._syncSpeechPermission();
    session._publish();
    session._syncPerception();
    session._prepareRuntime();
    session._adapt(null);
    _notify();
    return session;
  }

  Future<GameVoiceObservation?> snapshotForUserQuestion() async =>
      currentSession?.snapshotForUserQuestion();

  void recordDelivery(
    GameVoiceObservation observation,
    String id,
    String text,
    GameCompanionDeliveryStage stage,
  ) {
    final session = currentSession;
    if (session == null ||
        session.generation != observation.generation ||
        session.scopeKey != observation.scopeKey ||
        session.playerId != observation.playerId) {
      return;
    }
    session._recordDelivery(observation, id, text, stage);
  }

  /// Short lived recollection only; never describes another game's current board.
  String? recentActivityReference() {
    final now = _now();
    _recentActivities.removeWhere(
      (e) => now.difference(e.at) > const Duration(minutes: 30),
    );
    if (_recentActivities.isEmpty) return null;
    return _boundedText(
      'Earlier game conversations (history, not current state): ${jsonEncode(_recentActivities.map((e) => {'title': e.title, 'conversation': e.text}).toList())}',
      2000,
    );
  }

  @override
  void onClose() {
    _closed = true;
    _current?.close();
    _recentActivities.clear();
    _resumeDialogue?.dialogue.clear();
    _resumeDialogue = null;
    _spokenRepliesOwner = null;
    unawaited(_privacySubscription?.cancel());
    disposeAdaptation?.call();
    revision.dispose();
    super.onClose();
  }
}

final class GameVoiceCompanionSession {
  GameVoiceCompanionSession._({
    required GameVoiceCompanionService service,
    required GameCompanionDialogueBuffer dialogue,
    required this.scopeKey,
    required this.playerId,
    required this.generation,
    required this.documentGeneration,
    required this.contentIdentity,
    required this.title,
    required this.summary,
    required bool Function() isCurrent,
    required Future<Uint8List?> Function()? captureScreenshot,
    required bool Function()? isCaptureSupported,
    required Future<String?> Function()? readVisibleText,
  }) : _service = service,
       _dialogue = dialogue,
       _hostIsCurrent = isCurrent,
       _captureScreenshot = captureScreenshot,
       _isCaptureSupported = isCaptureSupported,
       _readVisibleText = readVisibleText;

  final GameVoiceCompanionService _service;
  final bool Function() _hostIsCurrent;
  final Future<Uint8List?> Function()? _captureScreenshot;
  final bool Function()? _isCaptureSupported;
  final Future<String?> Function()? _readVisibleText;
  final String scopeKey, playerId, title, summary;
  final int generation, documentGeneration;
  final GameContentIdentity? contentIdentity;
  final _revoked = Completer<void>();
  Completer<void> _speechRevoked = Completer<void>();
  final _positionChanges = StreamController<void>.broadcast(sync: true);
  Stream<void> get positionChanges => _positionChanges.stream;
  Completer<void>? _commentRevoked;
  bool _closed = false, _commentInFlight = false, _preparingRuntime = false;
  int _revision = -1, _domRevision = -1, _positionRevision = 0, _round = 0;
  int _adaptGeneration = 0;
  int _adaptDeferrals = 0;
  Timer? _adaptTimer;
  Map<String, Object?> _state = const {};
  GameCompanionDomSnapshot? _dom;
  GameCompanionDescriptor? _descriptor;
  final _evidence = <GameObservationEvidence>[];
  final _moments = <GameCompanionMoment>[];
  final GameCompanionDialogueBuffer _dialogue;
  int _userSerial = 0;
  GameVoiceObservation? _latest;
  GameCompanionMoment? _activeMoment;
  GameCompanionMoment? _pendingMoment;
  Timer? _pendingTimer;
  Timer? _commentExpiry;
  GamePerceptionCoordinator? _perception;
  GamePerceptionStatus? perceptionStatus;
  GameVisualObservation? _visual;

  bool get isCurrent =>
      !_closed && identical(_service._current, this) && _hostIsCurrent();
  bool get companionshipEnabled => isCurrent && _service.preferences.enabled;
  bool get spokenRepliesEnabled =>
      companionshipEnabled &&
      _service.spokenRepliesEnabled &&
      _service._soundEnabled();

  /// Capture this future with a speech turn. Re-enabling voice cannot revive
  /// an earlier turn whose permission has already been revoked.
  Future<void> get onSpeechRevoked => _speechRevoked.future;
  bool get canCapture =>
      isCurrent && (_isCaptureSupported?.call() ?? _captureScreenshot != null);
  Future<Uint8List?> capture() async =>
      isCurrent ? _captureScreenshot?.call() : null;
  Future<void> get onRevoked => _revoked.future;
  GameVoiceObservation? get latest => isCurrent ? _latest : null;
  List<Map<String, Object?>> get replayEnvelopes => [
    if (_revision >= 0)
      {'kind': 'game.state', 'revision': _revision, 'state': _state},
    if (_dom != null)
      {
        'kind': 'companion.snapshot',
        'revision': _domRevision,
        'state': _dom!.toPromptJson(),
      },
  ];
  int get roundGeneration => _round;
  int get positionRevision => _positionRevision;
  GameCompanionSessionKey get sessionKey => GameCompanionSessionKey(
    scopeKey: scopeKey,
    playerId: playerId,
    documentGeneration: documentGeneration,
    sessionGeneration: generation,
  );
  String get _ownerId => 'game-voice:${identityHashCode(_service)}:$generation';

  void _syncSpeechPermission() {
    if (!spokenRepliesEnabled) {
      if (!_speechRevoked.isCompleted) _speechRevoked.complete();
    } else if (_speechRevoked.isCompleted) {
      _speechRevoked = Completer<void>();
    }
  }

  GameCompanionContext get context => GameCompanionContext(
    sessionKey: sessionKey,
    roundGeneration: _round,
    preferences: _service.preferences,
    descriptor: _descriptor,
    evidence: _evidence.map((item) {
      if (item.source != GameObservationSource.vision) return item;
      final current =
          item.isFresh(
            now: _service._now(),
            maxAge: const Duration(seconds: 8),
          ) &&
          item.data['sourceMediaId'] == _perception?.latest?.sourceMediaId;
      return GameObservationEvidence(
        id: item.id,
        source: item.source,
        capturedAt: item.capturedAt,
        receivedAt: item.receivedAt,
        inferred: item.inferred,
        data: {...item.data, 'currentFrame': current},
      );
    }),
    recentMoments: _moments,
    recentConversation: _dialogue.snapshot,
  );

  /// Called only by the host when a local observer is recreated. Retain facts
  /// without comparing the new producer's counter with the detached producer.
  void beginDomProducer() {
    if (isCurrent) _domRevision = -1;
  }

  bool observeMessage(String source, {bool replay = false}) {
    final snapshot = GameCompanionDomSnapshot.parseMessage(source);
    if (snapshot != null) {
      return _observeDom(snapshot, allowInteraction: !replay);
    }
    final envelope = GameVoiceEnvelope.parse(source);
    return envelope != null && _observe(envelope, allowInteraction: !replay);
  }

  bool observeEnvelope(Object? value, {bool replay = false}) {
    final snapshot = GameCompanionDomSnapshot.fromEnvelope(value);
    if (snapshot != null) {
      return _observeDom(snapshot, allowInteraction: !replay);
    }
    final envelope = GameVoiceEnvelope.fromJson(value);
    return envelope != null && _observe(envelope, allowInteraction: !replay);
  }

  void _addEvidence(GameObservationEvidence evidence) {
    _evidence.add(evidence);
    if (_evidence.length > 6) _evidence.removeAt(0);
  }

  bool _observeDom(
    GameCompanionDomSnapshot dom, {
    bool allowInteraction = true,
  }) {
    if (!isCurrent || dom.revision <= _domRevision) return false;
    _domRevision = dom.revision;
    final changed =
        jsonEncode(_dom?.toPromptJson()) != jsonEncode(dom.toPromptJson());
    _dom = dom;
    if (dom.descriptor != null) _descriptor = dom.descriptor;
    if (changed) {
      final now = _service._now();
      _addEvidence(
        GameObservationEvidence(
          id: 'dom:$generation:${dom.revision}',
          source: GameObservationSource.dom,
          capturedAt: now,
          receivedAt: now,
          data: dom.toPromptJson(),
        ),
      );
      if (_revision < 0) _advancePosition();
      _adapt(dom);
      _refresh('visible_scene', now);
      _publish();
      if (allowInteraction &&
          _revision < 0 &&
          (dom.visibleText?.isNotEmpty == true || dom.controls.isNotEmpty)) {
        _consider(
          _moment(
            'visible_scene',
            'The visible game screen changed.',
            now,
            scope: GameCompanionMomentScope.currentPosition,
          ),
        );
      }
    }
    return true;
  }

  bool _observe(GameVoiceEnvelope envelope, {bool allowInteraction = true}) {
    if (!isCurrent || envelope.revision <= _revision) return false;
    _revision = envelope.revision;
    final eventType = envelope.event?['type'] as String?;
    if (const {
      'round_start',
      'restart',
      'game_restart',
      'level_start',
    }.contains(eventType)) {
      _round++;
      _invalidateComment();
      _moments.clear();
      _evidence.clear();
      _visual = null;
      _perception?.invalidateRound();
    }
    if (jsonEncode(_state) != jsonEncode(envelope.state)) _advancePosition();
    _state = envelope.state;
    final now = _service._now();
    // A legacy structured envelope can be larger than an evidence item. Keep
    // it in the bounded public-state contract rather than duplicating it.
    if (utf8.encode(jsonEncode(envelope.state)).length <= 5 * 1024) {
      try {
        _addEvidence(
          GameObservationEvidence(
            id: 'state:$generation:$_revision',
            source: GameObservationSource.structured,
            capturedAt: now,
            receivedAt: now,
            data: {
              'state': envelope.state,
              if (envelope.event != null) 'event': envelope.event,
            },
          ),
        );
      } on Object {
        /* Legacy envelope remains available in publicState. */
      }
    }
    final moment = envelope.event == null
        ? null
        : _moment(
            eventType!,
            envelope.event!['summary'] as String,
            now,
            scope:
                const {
                  'move',
                  'position',
                  'hint',
                  'danger',
                  'opportunity',
                }.contains(eventType)
                ? GameCompanionMomentScope.currentPosition
                : GameCompanionMomentScope.occurredEvent,
          );
    _refresh(eventType ?? 'state', now, moment: moment, event: envelope.event);
    _publish();
    if (moment != null && allowInteraction) _consider(moment);
    return true;
  }

  void _advancePosition() {
    _positionRevision++;
    _positionChanges.add(null);
    if (_activeMoment?.scope == GameCompanionMomentScope.currentPosition) {
      _invalidateComment();
    }
  }

  GameCompanionMoment _moment(
    String kind,
    String summary,
    DateTime now, {
    required GameCompanionMomentScope scope,
  }) {
    final moment = GameCompanionMoment(
      id: 'm:$generation:$_round:$_revision:$_domRevision:${_moments.length}:${now.microsecondsSinceEpoch}',
      sessionKey: sessionKey,
      roundGeneration: _round,
      positionRevision: _positionRevision,
      scope: scope,
      kind: kind,
      summary: _boundedText(summary.trim().isEmpty ? kind : summary, 512),
      observedAt: now,
      expiresAt: now.add(
        scope == GameCompanionMomentScope.occurredEvent
            ? const Duration(seconds: 18)
            : const Duration(seconds: 8),
      ),
    );
    _moments.add(moment);
    if (_moments.length > 8) _moments.removeAt(0);
    return moment;
  }

  void _refresh(
    String kind,
    DateTime at, {
    GameCompanionMoment? moment,
    Map<String, Object?>? event,
  }) {
    final currentVisual = _perception?.latest;
    if (currentVisual == null) _visual = null;
    _latest = GameVoiceObservation(
      scopeKey: scopeKey,
      playerId: playerId,
      generation: generation,
      title: title,
      summary: summary,
      publicState: Map.unmodifiable({
        if (_revision >= 0) 'state': _state,
        'event': ?event,
        if (_dom != null) 'visible': _dom!.toPromptJson(),
        if (_visual != null)
          'vision': {
            'description': _visual!.description,
            'capturedAt': _visual!.capturedAt.toIso8601String(),
            'inferred': true,
            'currentFrame': _visual!.isCurrentFrame,
          },
      }),
      eventKind: kind,
      revision: _revision,
      observedAt: at,
      context: context,
      moment: moment,
    );
  }

  void _adapt(GameCompanionDomSnapshot? dom) {
    final adapter = _service.adapt;
    if (adapter == null) return;
    _adaptTimer?.cancel();
    if (dom != null &&
        dom.descriptor == null &&
        (!_service._runtimeAvailable() || _service._userInputPending())) {
      if (_adaptDeferrals++ < 15) {
        _adaptTimer = Timer(const Duration(seconds: 2), () {
          if (isCurrent) _adapt(_dom);
        });
      }
      return;
    }
    final token = ++_adaptGeneration;
    unawaited(
      Future<GameCompanionAdaptation>.sync(() => adapter(this, dom)).then((
        adaptation,
      ) {
        final descriptor = adaptation.descriptor;
        if (!isCurrent ||
            token != _adaptGeneration ||
            (_dom?.descriptor != null &&
                adaptation.source != GameCompanionAdaptationSource.authored) ||
            descriptor == null) {
          return;
        }
        _descriptor = descriptor;
        final now = _service._now();
        _addEvidence(
          GameObservationEvidence(
            id: 'rules:$generation:$token',
            source: GameObservationSource.dom,
            capturedAt: now,
            receivedAt: now,
            inferred: adaptation.inferred,
            data: {
              'rulesSource': adaptation.source.name,
              'fromCache': adaptation.fromCache,
              'staticRulesOnly': true,
              'rules': descriptor.toPromptJson(),
            },
          ),
        );
        _refresh(_latest?.eventKind ?? 'unobserved', _service._now());
        _publish();
      }, onError: (Object _, StackTrace _) {}),
    );
  }

  void _prepareRuntime() {
    final prepare = _service.prepareRuntime;
    if (prepare == null ||
        _preparingRuntime ||
        !companionshipEnabled ||
        _service._runtimeAvailable()) {
      return;
    }
    _preparingRuntime = true;
    unawaited(
      Future<void>.sync(
        () => prepare(() => companionshipEnabled),
      ).catchError((Object _) {}).whenComplete(() {
        _preparingRuntime = false;
        if (!companionshipEnabled) return;
        _adapt(_dom);
        final pending = _pendingMoment;
        _pendingMoment = null;
        if (pending != null) _consider(pending);
      }),
    );
  }

  void _syncPerception() {
    if (!companionshipEnabled || !_service.visualEnabled) {
      final old = _perception;
      _perception = null;
      _visual = null;
      _evidence.removeWhere(
        (item) => item.source == GameObservationSource.vision,
      );
      _refresh(_latest?.eventKind ?? 'unobserved', _service._now());
      _publish();
      if (old != null) unawaited(old.close());
      return;
    }
    _perception ??= _service.createPerception?.call(this);
    _perception?.start();
  }

  void noteVisualChange() {
    if (!isCurrent || !_service.visualEnabled) return;
    _visual = null;
    if (_revision < 0) _advancePosition();
    _refresh('state', _service._now());
    _publish();
  }

  void updatePerceptionStatus(GamePerceptionStatus status) {
    if (!isCurrent) return;
    perceptionStatus = status;
    _service._notify();
  }

  void observeVisual(GameVisualObservation visual) {
    if (!isCurrent || !_service.visualEnabled || !companionshipEnabled) return;
    final now = _service._now();
    _addEvidence(
      GameObservationEvidence(
        id: 'vision:$generation:${visual.frameSequence}',
        source: GameObservationSource.vision,
        capturedAt: visual.capturedAt,
        receivedAt: visual.analyzedAt,
        inferred: true,
        data: {
          'description': _boundedText(visual.description, 512),
          'sourceMediaId': visual.sourceMediaId,
          'currentFrame': visual.isCurrentFrame,
        },
      ),
    );
    if (!visual.isCurrentFrame) {
      _refresh('past_scene', visual.capturedAt);
      _publish();
      _consider(
        _moment(
          'past_scene',
          'Earlier captured game screen: ${_boundedText(visual.description, 470)}',
          visual.capturedAt,
          scope: GameCompanionMomentScope.occurredEvent,
        ),
      );
      return;
    }
    final changed = _visual?.sourceMediaId != visual.sourceMediaId;
    _visual = visual;
    if (changed && _revision < 0) _advancePosition();
    _refresh('visible_scene', now);
    _publish();
    if (changed) {
      _consider(
        _moment(
          'visible_scene',
          _boundedText(visual.description, 512),
          visual.capturedAt,
          scope: GameCompanionMomentScope.currentPosition,
        ),
      );
    }
  }

  void _consider(GameCompanionMoment moment) {
    if (!isCurrent) return;
    if (_preparingRuntime) {
      if (spokenRepliesEnabled && !_service._userInputPending()) {
        _pendingMoment = moment;
      }
      return;
    }
    if (_commentInFlight) {
      _pendingMoment = moment;
      return;
    }
    final now = _service._now();
    _service._attempts.removeWhere(
      (at) => now.difference(at) >= const Duration(minutes: 1),
    );
    final admission = _service._speechPolicy.evaluate(
      now: now,
      preferences: _service.preferences,
      moment: moment,
      currentSession: sessionKey,
      currentRoundGeneration: _round,
      currentPositionRevision: _positionRevision,
      soundEnabled: spokenRepliesEnabled,
      runtimeAvailable: _service._runtimeAvailable(),
      userInputPending: _service._userInputPending(),
      focusRequiresSilence: _state['focusRequiresSilence'] == true,
      attempts: _service._attempts,
      lastSpeechStartedAt: _service._lastSpeechStartedAt,
      spokenMomentIds: _dialogue.spokenMomentIds,
      speechIntervalOverride:
          _service.preferences.talkativeness ==
              GameCompanionTalkativeness.balanced
          ? _service.commentInterval
          : null,
    );
    if (admission != GameCompanionSpeechAdmission.allowed) return;
    _service._attempts.add(now);
    _commentInFlight = true;
    _activeMoment = moment;
    final preferenceRevision = _service.preferences.revision;
    final revoked = _commentRevoked = Completer<void>();
    _commentExpiry?.cancel();
    _commentExpiry = Timer(
      moment.expiresAt.difference(now),
      _invalidateComment,
    );
    final visualSource = moment.kind == 'visible_scene'
        ? _visual?.sourceMediaId
        : null;
    _refresh(moment.kind, moment.observedAt, moment: moment);
    final observation = _latest!;
    bool current() =>
        isCurrent &&
        !revoked.isCompleted &&
        spokenRepliesEnabled &&
        preferenceRevision == _service.preferences.revision &&
        !_service._userInputPending() &&
        (visualSource == null ||
            _perception?.latest?.sourceMediaId == visualSource) &&
        moment.isValidFor(
          sessionKey: sessionKey,
          roundGeneration: _round,
          positionRevision: _positionRevision,
          now: _service._now(),
        );
    unawaited(
      Future<bool>.sync(
        () => _service._commentary(
          observation,
          isCurrent: current,
          onRevoked: revoked.future,
        ),
      ).then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(
        () {
          _commentInFlight = false;
          if (identical(_commentRevoked, revoked)) {
            _commentRevoked = null;
            _commentExpiry?.cancel();
          }
          _activeMoment = null;
          final pending = _pendingMoment;
          _pendingMoment = null;
          if (isCurrent && pending != null) {
            _pendingTimer?.cancel();
            _pendingTimer = Timer(
              const Duration(seconds: 3),
              () => _consider(pending),
            );
          }
        },
      ),
    );
  }

  void _recordDelivery(
    GameVoiceObservation observation,
    String id,
    String text,
    GameCompanionDeliveryStage stage,
  ) {
    if (!isCurrent) return;
    if (_dialogue.recordSpeech(
          id: id,
          text: text,
          at: _service._now(),
          stage: stage,
          momentId: observation.moment?.id,
        ) &&
        stage == GameCompanionDeliveryStage.started) {
      _service._lastSpeechStartedAt = _service._now();
    }
  }

  void recordPublishedReply(String id, String text) {
    if (!isCurrent) return;
    _dialogue.recordSpeech(
      id: id,
      text: text,
      at: _service._now(),
      stage: GameCompanionDeliveryStage.published,
    );
  }

  void recordUser(String text) {
    if (!isCurrent) return;
    _invalidateComment();
    _dialogue.recordUser(
      id: 'u:$generation:${++_userSerial}',
      text: text,
      at: _service._now(),
    );
    // Only actual human input can change preferences. Authored text and vision
    // descriptions never pass through this method.
    final normalized = text.trim().toLowerCase();
    if (const {
      '安静点',
      '安静一点',
      '少说点',
      'be quiet',
      'quiet please',
    }.contains(normalized)) {
      _service.setPreferences(
        _service.preferences.copyWith(
          talkativeness: GameCompanionTalkativeness.quiet,
        ),
      );
    } else if (const {'多说点', '多聊点', 'talk more'}.contains(normalized)) {
      _service.setPreferences(
        _service.preferences.copyWith(
          talkativeness: GameCompanionTalkativeness.chatty,
        ),
      );
    } else if (const {
      '不要提示',
      '别剧透',
      'no hints',
      'no spoilers',
    }.contains(normalized)) {
      _service.setPreferences(
        _service.preferences.copyWith(
          hintPolicy: GameCompanionHintPolicy.onRequest,
        ),
      );
    }
  }

  void _publish() {
    if (!isCurrent) return;
    _service._browsingContext.publish(
      ownerId: _ownerId,
      surface: 'game_player',
      kind: 'game',
      title: title,
      summary: summary,
      detail: _latest == null
          ? 'Game description only. The current position has not been observed.'
          : jsonEncode({
              'observation': _latest!.publicState,
              'companion': context.toPromptJson(),
            }),
    );
  }

  Future<GameVoiceObservation?> snapshotForUserQuestion({
    bool refreshVisual = true,
  }) async {
    if (!isCurrent) return null;
    final round = _round;
    if (refreshVisual && _perception != null) {
      await _perception!.refreshForUserQuestion();
      if (!isCurrent || round != _round) return null;
    }
    if (_dom == null && _readVisibleText != null) {
      try {
        final text = await _readVisibleText();
        if (!isCurrent || round != _round) return null;
        if (text != null && text.trim().isNotEmpty) {
          observeEnvelope({
            'kind': 'companion.snapshot',
            'revision': _domRevision + 1,
            'state': {'version': 1, 'visibleText': _boundedText(text, 512)},
          }, replay: true);
        }
      } on Object {
        /* Optional DOM evidence never blocks a conversation. */
      }
    }
    if (!isCurrent || round != _round) return null;
    _refresh(_latest?.eventKind ?? 'unobserved', _service._now());
    _publish();
    return _latest;
  }

  void _invalidateComment() {
    _pendingMoment = null;
    _pendingTimer?.cancel();
    _commentExpiry?.cancel();
    final revoked = _commentRevoked;
    _commentRevoked = null;
    if (revoked != null && !revoked.isCompleted) revoked.complete();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _syncSpeechPermission();
    _adaptTimer?.cancel();
    _invalidateComment();
    final perception = _perception;
    _perception = null;
    if (perception != null) unawaited(perception.close());
    if (!_revoked.isCompleted) _revoked.complete();
    if (!_service._closed && _dialogue.snapshot.isNotEmpty) {
      _service._recentActivities.add((
        at: _service._now(),
        title: title,
        text: _boundedText(jsonEncode(_dialogue.toPromptJson()), 600),
      ));
      if (_service._recentActivities.length > 3) {
        _service._recentActivities.removeAt(0);
      }
    }
    unawaited(_positionChanges.close());
    if (_service._closed) {
      _dialogue.clear();
    } else {
      _service._resumeDialogue = (
        scope: scopeKey,
        player: playerId,
        document: documentGeneration,
        at: _service._now(),
        dialogue: _dialogue,
      );
    }
    _evidence.clear();
    _service._browsingContext.clear(ownerId: _ownerId);
    if (identical(_service._current, this)) _service._current = null;
    _service._notify();
  }
}

String _boundedText(String value, int limit) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return String.fromCharCodes(normalized.runes.take(limit));
}
