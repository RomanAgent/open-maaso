import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';

import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_frame.dart';

import 'surface_bundle_document.dart';
import '../app_invocation/app_invocation_execution_contract.dart';

/// Trusted dependencies are mounted by the account owner. Authored pages never
/// choose storage scope, agent identity or seat.
final class SurfaceBundleHostServices {
  const SurfaceBundleHostServices({
    required this.installations,
    required this.verifier,
    this.playService,
    this.previewPlayService,
    this.agentId,
    this.appletControl,
    this.invocationData,
    this.invocationPlayService,
  });
  final ProjectBundleInstallationStore installations;
  final ProjectBundleVerificationService verifier;
  final SurfacePlayService? playService;
  final SurfacePlayService? previewPlayService;
  final String? agentId;
  final ProjectAppletControlService? appletControl;
  final AppInvocationApplicationDataPort? invocationData;
  final SurfacePlayService? invocationPlayService;
}

final class SurfaceBundlePresentation implements ProjectAppletControlHost {
  SurfaceBundlePresentation._({
    required this.installed,
    required this.permit,
    required this.services,
    required String sessionId,
    required String nonce,
    required this.preview,
    required bool Function() isCurrent,
    void Function(String?)? documentChanged,
  }) : _isCurrent = isCurrent,
       _sessionId = sessionId,
       _nonce = nonce,
       _documentChanged = documentChanged;

  final InstalledProjectBundleV2 installed;
  final ProjectBundleExecutionPermit permit;
  final SurfaceBundleHostServices services;
  String _sessionId, _nonce;
  String get sessionId => _sessionId;
  String get nonce => _nonce;
  final bool preview;
  final bool Function() _isCurrent;
  final void Function(String?)? _documentChanged;
  bool _closed = false;
  bool _documentActive = true;
  Future<void>? _restoringDocument;
  Completer<bool>? _firstFrame;
  bool? _frameOutcome;
  late String _document;
  String get document => _document;
  SurfacePlaySession? _play;
  StreamSubscription<SurfacePlayViewEvent>? _humanEvents;
  StreamSubscription<SurfacePlayFrame>? _humanFrames;
  SurfacePlayFrame? _latestFrame;
  Timer? _frameTimer;
  bool _frameInFlight = false;
  final _frameSentAt = Stopwatch();
  int _frameBindingEpoch = 0;
  Future<void>? _suspendingPlay;
  StreamSubscription<String>? _revocations;
  StreamSubscription<Set<String>>? _ownedInventory;
  StreamSubscription<void>? _appletControlEvents;
  Future<void> Function(String)? _evaluate;
  Future<Object?> Function(String)? _evaluateResult;
  bool Function()? _visible;
  final String _humanSeat = 'player1';
  bool _stateScheduled = false;
  final _state = StreamController<void>.broadcast(sync: true);
  Stream<void> get onControlsChanged => _state.stream;
  ProjectBundleDataRole get dataRole => installed.isAccepted && !preview
      ? ProjectBundleDataRole.installed
      : ProjectBundleDataRole.preview;
  bool get isGame => installed.bundle.protocol.isTrustedGame;
  bool get paused => _play?.isPaused ?? false;
  String get humanSeat => _humanSeat;
  bool get isCurrent => _documentActive && _baseCurrent;
  bool get _baseCurrent =>
      !_closed &&
      installed.isCurrent &&
      permit.isCurrent &&
      _isCurrent() &&
      (services.invocationData?.isCurrent ?? true);

  void _notifyControls() {
    if (_closed || _stateScheduled) return;
    _stateScheduled = true;
    scheduleMicrotask(() {
      _stateScheduled = false;
      if (!_closed) _state.add(null);
    });
  }

  static Future<SurfaceBundlePresentation> prepare({
    required InstalledProjectBundleV2 installed,
    required ProjectBundleExecutionPermit permit,
    required SurfaceBundleHostServices services,
    required String sessionId,
    required bool Function() isCurrent,
    bool preview = false,
    void Function()? onRevoked,
    void Function(String?)? onDocumentChanged,
  }) async {
    if (permit.candidateDigest != installed.candidateDigest ||
        installed.scopeKey != services.installations.scopeKey) {
      throw StateError('bundle_permit_mismatch');
    }
    if (installed.isAccepted && !preview) {
      await services.installations.ensurePresentationAuthority(
        expectedScopeKey: services.installations.scopeKey,
      );
    }
    final random = Random.secure();
    final result = SurfaceBundlePresentation._(
      installed: installed,
      permit: permit,
      services: services,
      sessionId: sessionId,
      preview: preview,
      nonce: base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', ''),
      isCurrent: () =>
          isCurrent() &&
          (preview ||
              !installed.isAccepted ||
              services.installations.canPresentSavedProject(
                installed.bundle.manifest.projectId,
                expectedScopeKey: services.installations.scopeKey,
              )),
      documentChanged: onDocumentChanged,
    );
    void revoked() {
      if (result._closed) return;
      onRevoked?.call();
      unawaited(result.close());
    }

    result._revocations = services.installations.onProjectRevoked.listen((id) {
      if (id == installed.bundle.manifest.projectId) revoked();
    });
    result._ownedInventory = services.installations.onOwnedInventoryChanged
        .listen((ids) {
          if (result.dataRole == ProjectBundleDataRole.installed &&
              !ids.contains(installed.bundle.manifest.projectId)) {
            revoked();
          }
        });
    try {
      result._guard();
      late final Map<String, Object?> dataValues;
      late final int dataVersion;
      final invocationData = services.invocationData;
      if (invocationData != null) {
        final data = await invocationData.read();
        dataValues = data.values;
        dataVersion = data.version;
      } else {
        final data = await services.installations.readApplicationData(
          installed.candidateDigest,
          expectedScopeKey: services.installations.scopeKey,
          role: result.dataRole,
        );
        dataValues = data.values;
        dataVersion = data.version;
      }
      result._guard();
      final bundle = installed.bundle;
      if (result.isGame) {
        final play = services.invocationData != null
            ? services.invocationPlayService
            : result.dataRole == ProjectBundleDataRole.installed
            ? services.playService
            : services.previewPlayService;
        final agentId = services.agentId;
        if (play == null || agentId == null) {
          throw StateError('bundle_play_unavailable');
        }
        result._play = await play.openSession(
          protocol: bundle.protocol,
          sessionId: sessionId,
          agentId: agentId,
          contentManifestId: bundle.manifest.contentManifestId,
          protocolJson: utf8.decode(bundle.files['agent.protocol.json']!),
          agentDocument: bundle.agentMarkdown,
          isPresentationCurrent: () => result.isCurrent,
        );
        result._guard();
        result._bindHumanEvents();
      }
      result._document = SurfaceBundleDocument.build(
        bundle: bundle,
        nonce: result.nonce,
        sessionId: sessionId,
        initialData: dataValues,
        dataVersion: dataVersion,
        initialPlay: result._play
            ?.observeHuman(seatId: result._humanSeat)
            .toJson(),
        initialFrame: result._play
            ?.currentFrameHuman(seatId: result._humanSeat)
            ?.toJson(),
      );
      if (!result.isGame && services.appletControl != null) {
        services.appletControl!.registerHost(result);
        result._appletControlEvents = services.appletControl!.changes.listen((
          _,
        ) {
          result._notifyControls();
        });
      }
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    }
  }

  Future<void> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final ready =
        _frameOutcome ??
        await (_firstFrame ??= Completer<bool>()).future.timeout(timeout);
    _guard();
    if (!ready) throw StateError('bundle_first_frame_failed');
  }

  /// Called only by the current native visible host after its identity checks.
  void reportFirstFrame(bool ready) {
    if (!isCurrent || _frameOutcome != null) return;
    _frameOutcome = ready;
    _firstFrame?.complete(ready);
    services.appletControl?.contextChanged();
    _notifyControls();
  }

  void _guard() {
    if (!isCurrent) throw StateError('bundle_presentation_changed');
  }

  void attach(
    Future<void> Function(String) evaluate, {
    Future<Object?> Function(String)? evaluateResult,
    bool Function()? isVisible,
  }) {
    _evaluate = evaluate;
    _evaluateResult = evaluateResult;
    _visible = isVisible;
    _bindHumanFrames();
  }

  void detach() {
    if (_play != null && !_closed) {
      unawaited(_suspendRealtime().catchError((Object _) {}));
    }
    _clearHumanFrames();
    _evaluate = null;
    _evaluateResult = null;
    _visible = null;
    services.appletControl?.contextChanged();
  }

  void visibleContextChanged() {
    services.appletControl?.contextChanged();
    // Initial dependency notifications precede asynchronous bridge attachment.
    // An unbound callback has no visibility sample; it is not a hidden host.
    if (_play == null || _closed || _visible == null) return;
    if (!controlIsVisible) {
      unawaited(_suspendRealtime().catchError((Object _) {}));
    } else {
      _bindHumanFrames();
    }
  }

  Future<void> _suspendRealtime() => _suspendingPlay ??= _suspendRealtimeNow()
      .whenComplete(() => _suspendingPlay = null);

  Future<void> _suspendRealtimeNow() async {
    final play = _play;
    if (play == null || _closed) return;
    final paused = play.suspendForVisibilityLoss();
    _clearHumanFrames();
    final frame = play.isCurrent
        ? play.currentFrameHuman(seatId: _humanSeat)
        : null;
    if (frame != null) _queueHumanFrame(frame);
    await paused;
    _notifyControls();
    if (isCurrent) await _pushHumanView();
  }

  ProjectAppletGrant? get appletGrant {
    final grant = services.appletControl?.currentGrant(controlAgentId);
    return grant?.sessionId == sessionId &&
            grant?.candidateDigest == installed.candidateDigest
        ? grant
        : null;
  }

  bool get canGrantApplet =>
      !isGame &&
      isCurrent &&
      controlIsVisible &&
      controlIsReady &&
      services.appletControl != null &&
      appletGrant == null;
  Future<void> grantAppletFromNative(String purpose) async {
    final service = services.appletControl;
    if (service == null || isGame) {
      throw StateError('applet_control_unavailable');
    }
    await service.grantFromNative(this, purpose: purpose);
  }

  Future<void> takeOverAppletFromNative() async =>
      services.appletControl?.takeOverFromNative(this);

  @override
  String get controlScopeKey => installed.scopeKey;
  @override
  String get controlAgentId => services.agentId ?? 'self';
  @override
  String get controlProjectId => installed.bundle.manifest.projectId;
  @override
  String get controlRevisionId => installed.bundle.manifest.revisionId;
  @override
  String get controlCandidateDigest => installed.candidateDigest;
  @override
  String get controlSessionId => sessionId;
  @override
  String get controlTitle => installed.bundle.title;
  @override
  String get controlAgentDocument => installed.bundle.agentMarkdown;
  @override
  get controlProtocol => installed.bundle.protocol;
  @override
  bool get controlIsCurrent => isCurrent;
  @override
  bool get controlIsVisible => _visible?.call() ?? false;
  @override
  bool get controlIsReady => _frameOutcome == true && _evaluateResult != null;
  @override
  bool get canRetainControlReceipts => installed.isCurrent && permit.isCurrent;

  Future<Object?> _readControlJson(String method, [String? requestId]) async {
    _guard();
    if (isGame) throw StateError('game_requires_trusted_rules');
    final read = _evaluateResult;
    if (read == null) throw StateError('applet_transport_unavailable');
    final token = nonce;
    Object? result = await read(
      'JSON.stringify(globalThis.__maasoHost?.$method?.('
      '${SurfaceBundleDocument.safeJson(token)}'
      '${requestId == null ? '' : ',${SurfaceBundleDocument.safeJson(requestId)}'})??null)',
    );
    _guard();
    if (token != nonce) throw StateError('applet_document_changed');
    const codec = ProjectJsonCanonicalizer(
      maxBytes: 128 * 1024,
      maxDepth: 20,
      maxNodes: 8192,
    );
    for (var i = 0; i < 2 && result is String; i++) {
      result = codec.parse(result);
    }
    return result;
  }

  @override
  Future<Map<String, Object?>> controlInfo() async {
    final result = await _readControlJson('controlInfo');
    return result is Map ? Map<String, Object?>.from(result) : const {};
  }

  @override
  Future<Map<String, Object?>> inspectApplet() async {
    final result = await _readControlJson('inspect');
    if (result is! Map) throw StateError('applet_observation_invalid');
    return Map<String, Object?>.from(result);
  }

  @override
  Future<Map<String, Object?>?> lookupAppletReceipt(String requestId) async {
    final result = await _readControlJson('receipt', requestId);
    if (result == null) return null;
    if (result is! Map) throw StateError('applet_receipt_invalid');
    return Map<String, Object?>.from(result);
  }

  @override
  Future<void> dispatchApplet(
    Map<String, Object?> command,
    String callbackToken,
  ) async {
    _guard();
    if (isGame || _evaluate == null) {
      throw StateError('applet_transport_unavailable');
    }
    final token = nonce;
    await _evaluate!(
      'globalThis.__maasoNativeControlDispatch?.('
      '${SurfaceBundleDocument.safeJson(token)},${SurfaceBundleDocument.safeJson(command)},'
      '${SurfaceBundleDocument.safeJson(callbackToken)})',
    );
    _guard();
    if (token != nonce) throw StateError('applet_document_changed');
  }

  @override
  void fenceAppletDocument() {
    if (_closed || isGame || !_documentActive) return;
    _documentActive = false;
    _nonce = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    _sessionId = const Uuid().v4();
    if (_firstFrame != null && !_firstFrame!.isCompleted) {
      _firstFrame!.complete(false);
    }
    _firstFrame = null;
    _frameOutcome = null;
    _documentChanged?.call(null);
    _notifyControls();
  }

  @override
  Future<void> restoreAppletDocument() => _restoringDocument ??=
      _restoreAppletDocument().whenComplete(() => _restoringDocument = null);
  Future<void> _restoreAppletDocument() async {
    if (isGame || _documentActive || !_baseCurrent) return;
    final token = nonce;
    final data = await services.installations.readApplicationData(
      installed.candidateDigest,
      expectedScopeKey: services.installations.scopeKey,
      role: dataRole,
    );
    if (!_baseCurrent || token != nonce) return;
    _document = SurfaceBundleDocument.build(
      bundle: installed.bundle,
      nonce: nonce,
      sessionId: sessionId,
      initialData: data.values,
      dataVersion: data.version,
    );
    _documentActive = true;
    _documentChanged?.call(_document);
    _notifyControls();
  }

  void _bindHumanEvents() {
    unawaited(_humanEvents?.cancel());
    _humanEvents = _play!.humanEventsForSeat(_humanSeat).listen((event) {
      if (event.seatId == _humanSeat && isCurrent) {
        unawaited(_pushHumanView().catchError((Object _) {}));
      }
    });
    _bindHumanFrames();
  }

  void _clearHumanFrames() {
    _frameBindingEpoch++;
    unawaited(_humanFrames?.cancel());
    _humanFrames = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    _latestFrame = null;
  }

  void _bindHumanFrames() {
    _clearHumanFrames();
    final play = _play;
    if (play == null || !play.isRealtime || _evaluate == null || !isCurrent) {
      return;
    }
    final binding = _frameBindingEpoch;
    _humanFrames = play.framesForHumanSeat(_humanSeat).listen((frame) {
      if (binding == _frameBindingEpoch &&
          frame.seatId == _humanSeat &&
          isCurrent) {
        _queueHumanFrame(frame);
      }
    });
    final frame = play.currentFrameHuman(seatId: _humanSeat);
    if (frame != null) _queueHumanFrame(frame);
  }

  void _queueHumanFrame(SurfacePlayFrame frame) {
    if (!isCurrent || _evaluate == null || frame.seatId != _humanSeat) return;
    _latestFrame = frame;
    if (_frameInFlight || _frameTimer != null) return;
    final elapsed = _frameSentAt.isRunning
        ? _frameSentAt.elapsed
        : const Duration(seconds: 1);
    const interval = Duration(microseconds: 33334);
    final delay = elapsed >= interval ? Duration.zero : interval - elapsed;
    _frameTimer = Timer(delay, () {
      _frameTimer = null;
      unawaited(_flushHumanFrame());
    });
  }

  Future<void> _flushHumanFrame() async {
    final frame = _latestFrame;
    final evaluate = _evaluate;
    if (_frameInFlight || frame == null || evaluate == null || !isCurrent) {
      return;
    }
    _latestFrame = null;
    final token = nonce;
    _frameInFlight = true;
    _frameSentAt
      ..reset()
      ..start();
    try {
      await evaluate(
        'globalThis.__maasoHost?.updatePlayFrame(${SurfaceBundleDocument.safeJson(token)},${SurfaceBundleDocument.safeJson(frame.toJson())})',
      );
    } catch (_) {
      // Rendering frames are lossy. Commands and reliable receipts use the
      // separate non-coalesced channel; a slow renderer never blocks rules.
    } finally {
      _frameInFlight = false;
      if (isCurrent && token == nonce) {
        final latest = _latestFrame;
        if (latest != null) _queueHumanFrame(latest);
      }
    }
  }

  Future<void> _pushHumanView() async {
    _guard();
    final play = _play;
    final evaluate = _evaluate;
    if (play == null || evaluate == null) return;
    final view = play.observeHuman(seatId: _humanSeat).toJson();
    await evaluate(
      'globalThis.__maasoHost?.updatePlay(${SurfaceBundleDocument.safeJson(nonce)},${SurfaceBundleDocument.safeJson(view)})',
    );
    _guard();
    final frame = play.currentFrameHuman(seatId: _humanSeat);
    if (frame != null) _queueHumanFrame(frame);
  }

  /// Every message is bound to the account-owned presentation. All bridge
  /// operations are local; a page cannot name a different seat or storage key.
  Future<({String id, Object? result, String? error, bool? frameReady})?>
  handle(String source) async {
    if (!isCurrent) return null;
    final receivedNonce = nonce;
    const codec = ProjectJsonCanonicalizer(
      maxBytes: 96 * 1024,
      maxDepth: 20,
      maxNodes: 8192,
    );
    final Object? value;
    try {
      value = codec.parse(source);
    } catch (_) {
      return null;
    }
    if (value is! Map<String, Object?> ||
        value.length != 8 ||
        value['nonce'] != nonce ||
        value['sessionId'] != sessionId ||
        value['projectId'] != installed.bundle.manifest.projectId ||
        value['revisionId'] != installed.bundle.manifest.revisionId ||
        value['candidateDigest'] != installed.candidateDigest ||
        value['id'] is! String ||
        !RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(value['id']! as String)) {
      return null;
    }
    final id = value['id']! as String, operation = value['operation'];
    final payload = value['payload'];
    if (payload is! Map<String, Object?>) return null;
    try {
      switch (operation) {
        case 'frame':
          if (payload.length != 1 || payload['ready'] is! bool) return null;
          return (
            id: id,
            result: null,
            error: null,
            frameReady: payload['ready']! as bool,
          );
        case 'data_save':
          if (payload.length != 2 ||
              payload['values'] is! Map<String, Object?> ||
              payload['expectedDataVersion'] is! int) {
            return null;
          }
          late final int savedVersion;
          final invocationData = services.invocationData;
          if (invocationData != null) {
            final saved = await invocationData.save(
              payload['values']! as Map<String, Object?>,
              expectedVersion: payload['expectedDataVersion']! as int,
              canContinue: () => isCurrent && nonce == receivedNonce,
            );
            savedVersion = saved.version;
          } else {
            final saved = await services.installations.saveApplicationData(
              installed.candidateDigest,
              payload['values']! as Map<String, Object?>,
              expectedScopeKey: services.installations.scopeKey,
              role: dataRole,
              expectedDataVersion: payload['expectedDataVersion']! as int,
              canCommit: () => isCurrent && nonce == receivedNonce,
            );
            savedVersion = saved.version;
          }
          _guard();
          return (
            id: id,
            result: {'dataVersion': savedVersion},
            error: null,
            frameReady: null,
          );
        case 'control_result':
          final control = services.appletControl;
          if (isGame ||
              control == null ||
              payload.length != 2 ||
              payload['callbackToken'] is! String ||
              payload['receipt'] is! Map<String, Object?>) {
            return null;
          }
          final accepted = await control.acceptRuntimeResult(
            this,
            payload['callbackToken']! as String,
            payload['receipt']! as Map<String, Object?>,
          );
          if (nonce != receivedNonce || !isCurrent) return null;
          return (
            id: id,
            result: {'accepted': accepted},
            error: null,
            frameReady: null,
          );
        case 'play_submit':
        case 'play_receipt':
          final play = _play;
          if (play == null) throw StateError('play_unavailable');
          Object? result;
          try {
            if (operation == 'play_submit') {
              result = (await play.submitHuman(
                SurfacePlayCommand.fromJson(payload),
                seatId: _humanSeat,
              )).toJson();
            } else {
              if (payload.length != 1 || payload['requestId'] is! String) {
                return null;
              }
              result = (await play.receiptHuman(
                payload['requestId']! as String,
                seatId: _humanSeat,
              ))?.toJson();
            }
          } finally {
            // Rejected tokens and absent receipts may have no commit event.
            if (isCurrent) await _pushHumanView();
          }
          _guard();
          return (id: id, result: result, error: null, frameReady: null);
        default:
          return null;
      }
    } catch (_) {
      if (!isCurrent) return null;
      return (
        id: id,
        result: null,
        error: 'bundle_operation_failed',
        frameReady: null,
      );
    }
  }

  /// Compatibility for saved v2 human sessions. This never creates an Agent
  /// grant or starts a model driver, and has no player toolbar control.
  Future<void> resume() async {
    await _suspendingPlay;
    _guard();
    final play = _play;
    if (play == null) throw StateError('play_unavailable');
    await play.resume();
    _guard();
    await _pushHumanView();
  }

  Future<void> close() async {
    if (_closed) return;
    services.appletControl?.unregisterHost(this);
    _closed = true;
    _clearHumanFrames();
    if (_frameOutcome == null) {
      _frameOutcome = false;
      _firstFrame?.complete(false);
    }
    _evaluate = null;
    _evaluateResult = null;
    _visible = null;
    await _appletControlEvents?.cancel();
    await _revocations?.cancel();
    await _ownedInventory?.cancel();
    await _humanEvents?.cancel();
    await _play?.close();
    await _state.close();
  }
}
