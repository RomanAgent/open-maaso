import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'surface_bundle_presentation.dart';
import 'surface_bundle_document.dart';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_canvas_host.dart';

class SurfaceEvent {
  const SurfaceEvent(this.surfaceId, this.event, this.data);

  final String surfaceId;
  final String event;
  final dynamic data;

  String toPromptLine() => formatSurfaceEventLine(surfaceId, event, data);
}

final class SurfaceCapabilityUnavailableException implements Exception {
  const SurfaceCapabilityUnavailableException();

  @override
  String toString() => 'surface_capability_unavailable';
}

class SurfaceRuntime extends AppService {
  static final Object _sessionCaptureZoneKey = Object();
  static final Object _capabilityLeaseZoneKey = Object();
  static final AppCapabilityKey _embeddedSurfaceCapability =
      AppCapabilityKey.platformAction(AppActionCapability.embeddedSurface);
  static const int _maxPayloadNodes = 4096;
  static const int _maxPayloadDepth = 64;
  static const int _maxPayloadTextCodeUnits = 64 * 1024;

  WebViewController? _web;

  final RxBool isVisible = false.obs;
  final Rxn<SurfaceProject> activeProject = Rxn<SurfaceProject>();
  final RxnString title = RxnString();
  final RxnString document = RxnString();

  String _activeSurfaceId = '';
  SurfaceManifest _activeManifest = const SurfaceManifest();
  int _activeSession = 0;
  int _bundleEpoch = 0;
  AppCapabilitySnapshotService? _activeCapabilityService;
  AppCapabilitySnapshotLease? _activeCapabilityLease;

  String get activeSurfaceId => _activeSurfaceId;
  SurfaceManifest get activeManifest => _activeManifest;
  int get activeSession => _activeSession;

  /// Cheap UI admission check. Production installs the immutable snapshot
  /// service before any Surface runtime. The absent-service fallback preserves
  /// isolated runtime/test bootstraps that do not construct the app graph.
  static bool get presentationCapabilityAvailable {
    if (!appServices.isRegistered<AppCapabilitySnapshotService>()) return true;
    try {
      final service = appServices.find<AppCapabilitySnapshotService>();
      return !service.isClosed &&
          service.value.allows(
            _embeddedSurfaceCapability,
            requireVisible: true,
          );
    } catch (_) {
      return false;
    }
  }

  /// Whether [session] is still the exact visible presentation authorized by
  /// the same immutable capability generation.
  bool isSessionCurrent(int session) {
    if (_activeSession != session ||
        !isVisible.value ||
        activeProject.value == null) {
      return false;
    }
    final service = _activeCapabilityService;
    final lease = _activeCapabilityLease;
    if (service == null && lease == null) return true;
    if (service == null || lease == null) return false;
    try {
      return service.isCurrent(lease);
    } catch (_) {
      return false;
    }
  }

  final StreamController<SurfaceEvent> _events =
      StreamController<SurfaceEvent>.broadcast();

  Stream<SurfaceEvent> get onEvent => _events.stream;

  @override
  void onClose() {
    _bundleEpoch++;
    unawaited(activeProject.value?.bundlePresentation?.close());
    _events.close();
    super.onClose();
  }

  void attach(WebViewController controller) {
    _web = controller;
  }

  void detach(WebViewController controller) {
    if (_web == controller) _web = null;
  }

  Future<void> show(SurfaceProject project) async {
    final zonedAuthority = Zone.current[_capabilityLeaseZoneKey];
    final authority = zonedAuthority is _SurfaceCapabilityAuthority
        ? zonedAuthority
        : _acquirePresentationAuthority();
    if (!authority.isCurrent) {
      throw const SurfaceCapabilityUnavailableException();
    }
    SurfaceProjectValidator.validateForShow(project);
    _bundleEpoch++;
    unawaited(activeProject.value?.bundlePresentation?.close());
    Log.i(
      '[SurfaceRuntime] show id=${project.id} title="${_compact(project.title)}" '
      'kind=${project.kind.name} rendering=${project.rendering.name} '
      'html=${project.html.length} css=${project.css.length} '
      'js=${project.js.length}',
    );
    _activeSession++;
    final capture = Zone.current[_sessionCaptureZoneKey];
    if (capture is void Function(int)) capture(_activeSession);
    _bindCapabilityAuthority(authority, session: _activeSession);
    activeProject.value = project;
    title.value = project.title;
    _activeSurfaceId = project.id;
    _activeManifest = project.manifest;
    document.value = _wrap(project, lifecycleToken: _activeSession);
    isVisible.value = true;
  }

  /// Presents [project] and returns the exact session allocated by the
  /// concrete [show] invocation. The zone callback also works through test or
  /// platform subclasses that wrap [show], without guessing activeSession+1.
  Future<int> showWithSession(
    SurfaceProject project, {
    AppCapabilitySnapshotService? capabilityService,
    AppCapabilitySnapshotLease? capabilityLease,
  }) async {
    final authority = capabilityService == null && capabilityLease == null
        ? _acquirePresentationAuthority()
        : _SurfaceCapabilityAuthority(
            service: capabilityService,
            lease: capabilityLease,
          );
    if (!authority.isCurrent) {
      throw const SurfaceCapabilityUnavailableException();
    }
    int? allocatedSession;
    await runZoned(
      () => show(project),
      zoneValues: <Object, Object>{
        _capabilityLeaseZoneKey: authority,
        _sessionCaptureZoneKey: (int session) {
          allocatedSession = session;
        },
      },
    );
    final session = allocatedSession;
    if (session == null) {
      throw StateError('Surface runtime did not allocate a session');
    }
    if (!authority.isCurrent) {
      await closeIfSession(session);
      throw const SurfaceCapabilityUnavailableException();
    }
    return session;
  }

  /// Sole v2 execution entry point. Structural validation never grants this
  /// capability, and generated surface.show JSON cannot construct it.
  Future<int> showInstalledBundle(
    InstalledProjectBundleV2 installed, {
    required ProjectBundleExecutionPermit permit,
    SurfaceBundleHostServices? hostServices,
    bool preview = false,
    bool Function()? canContinue,
  }) async {
    final authority = _acquirePresentationAuthority();
    final services =
        hostServices ?? appServices.maybeFind<SurfaceBundleHostServices>();
    if (services == null ||
        !authority.isCurrent ||
        !installed.isCurrent ||
        !permit.isCurrent ||
        permit.candidateDigest != installed.candidateDigest) {
      throw StateError('bundle_presentation_not_authorized');
    }
    final epoch = ++_bundleEpoch;
    int? publishedSession;
    bool current() =>
        epoch == _bundleEpoch &&
        authority.isCurrent &&
        (canContinue?.call() ?? true) &&
        (publishedSession == null || isSessionCurrent(publishedSession));
    final presentation = await SurfaceBundlePresentation.prepare(
      installed: installed,
      permit: permit,
      services: services,
      sessionId: const Uuid().v4(),
      preview: preview,
      isCurrent: current,
      onDocumentChanged: (replacement) {
        if (current()) document.value = replacement;
      },
      onRevoked: () {
        if (!current()) return;
        final session = publishedSession;
        if (session == null) {
          _bundleEpoch++;
        } else {
          unawaited(closeIfSession(session));
        }
      },
    );
    if (!current()) {
      await presentation.close();
      throw StateError('bundle_presentation_superseded');
    }
    final previous = activeProject.value?.bundlePresentation;
    final bundle = installed.bundle;
    final project = SurfaceProject(
      id: bundle.manifest.projectId,
      title: bundle.title,
      kind: SurfaceKind.fullscreen,
      rendering: SurfaceRendering.projectBundle,
      html: '',
      css: '',
      js: '',
      transparent: false,
      placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
      manifest: const SurfaceManifest(),
      backend: const {},
      revisions: const [],
      experienceType: presentation.isGame
          ? SurfaceExperienceType.game
          : SurfaceExperienceType.utility,
      category: presentation.isGame ? 'game' : 'tools',
      bundlePresentation: presentation,
    );
    _activeSession++;
    _bindCapabilityAuthority(authority, session: _activeSession);
    activeProject.value = project;
    title.value = project.title;
    _activeSurfaceId = project.id;
    _activeManifest = project.manifest;
    isVisible.value = true;
    publishedSession = _activeSession;
    document.value = presentation.document;
    unawaited(previous?.close());
    return _activeSession;
  }

  Future<void> waitForBundleFirstFrame(
    int session, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final presentation = activeProject.value?.bundlePresentation;
    if (!isSessionCurrent(session) || presentation == null) {
      throw StateError('bundle_presentation_superseded');
    }
    await presentation.waitForFirstFrame(timeout: timeout);
    if (!isSessionCurrent(session) || !presentation.isCurrent) {
      throw StateError('bundle_presentation_superseded');
    }
  }

  Future<bool> goBackInBundle() async {
    final presentation = activeProject.value?.bundlePresentation;
    final web = _web;
    if (presentation == null || web == null || !presentation.isCurrent) {
      return false;
    }
    final session = _activeSession;
    final nonce = SurfaceBundleDocument.safeJson(presentation.nonce);
    final result = await web.runJavaScriptReturningResult(
      'JSON.stringify((()=>{const h=globalThis.__maasoHost;if(!h)return {handled:false};'
      'if(!h.inspect($nonce).canGoBack)return {handled:false};h.back($nonce);return {handled:true};})())',
    );
    if (!isSessionCurrent(session) || !presentation.isCurrent) return true;
    Object? decoded = result;
    for (var i = 0; i < 2 && decoded is String; i++) {
      decoded = jsonDecode(decoded);
    }
    return decoded is Map && decoded['handled'] == true;
  }

  Future<void> close() async {
    _bundleEpoch++;
    final bundle = activeProject.value?.bundlePresentation;
    final closingSession = _activeSession;
    final project = activeProject.value;
    final web = _web;
    Future<void>? disposeFuture;
    if (project?.rendering == SurfaceRendering.workerCanvas && web != null) {
      try {
        disposeFuture = web.runJavaScript(
          'if (typeof window.__disposeSurfaceWorker === "function") {'
          'window.__disposeSurfaceWorker($closingSession);'
          '}',
        );
      } catch (error, stackTrace) {
        Log.w(
          '[SurfaceRuntime] workerCanvas dispose bridge failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (_activeSession == closingSession) {
      _activeCapabilityService = null;
      _activeCapabilityLease = null;
      isVisible.value = false;
      activeProject.value = null;
      document.value = null;
      title.value = null;
      _activeSurfaceId = '';
      _activeManifest = const SurfaceManifest();
    }
    await bundle?.close();
    if (disposeFuture != null) {
      try {
        await disposeFuture.timeout(const Duration(milliseconds: 500));
      } catch (error, stackTrace) {
        Log.w(
          '[SurfaceRuntime] workerCanvas dispose did not finish in time',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  Future<void> closeIfSession(int session) async {
    if (_activeSession != session) return;
    await close();
  }

  _SurfaceCapabilityAuthority _acquirePresentationAuthority() {
    if (!appServices.isRegistered<AppCapabilitySnapshotService>()) {
      return const _SurfaceCapabilityAuthority.legacy();
    }
    try {
      final service = appServices.find<AppCapabilitySnapshotService>();
      if (service.isClosed) {
        throw const SurfaceCapabilityUnavailableException();
      }
      final acquisition = service.acquireLease(<AppCapabilityKey>[
        _embeddedSurfaceCapability,
      ], requireVisible: true);
      final lease = acquisition.lease;
      if (!acquisition.isGranted || lease == null) {
        throw const SurfaceCapabilityUnavailableException();
      }
      return _SurfaceCapabilityAuthority(service: service, lease: lease);
    } on SurfaceCapabilityUnavailableException {
      rethrow;
    } catch (_) {
      throw const SurfaceCapabilityUnavailableException();
    }
  }

  void _bindCapabilityAuthority(
    _SurfaceCapabilityAuthority authority, {
    required int session,
  }) {
    final service = authority.service;
    final lease = authority.lease;
    _activeCapabilityService = service;
    _activeCapabilityLease = lease;
    if (service == null || lease == null) return;
    unawaited(
      lease.whenInvalidated.then((_) {
        if (_activeSession != session ||
            !identical(_activeCapabilityService, service) ||
            !identical(_activeCapabilityLease, lease)) {
          return;
        }
        unawaited(closeIfSession(session));
      }),
    );
  }

  Future<String?> surfaceCall(String action, Object? data) async {
    final callingSession = _activeSession;
    if (!isSessionCurrent(callingSession)) {
      return 'surface capability unavailable';
    }
    final prepared = _prepareSurfaceCall(action, data);
    final err = prepared.error;
    if (err != null) return err;
    try {
      await prepared.web!.runJavaScript(
        'window.__applyAgent(${jsonEncode(action)}, '
        '${jsonEncode(prepared.payload)})',
      );
      if (!isSessionCurrent(callingSession)) {
        return 'surface capability unavailable';
      }
    } catch (e) {
      return 'surface bridge error: $e';
    }
    return null;
  }

  void onPageEvent(String event, Object? data) {
    if (activeProject.value?.rendering == SurfaceRendering.projectBundle) {
      return;
    }
    if (!isSessionCurrent(_activeSession)) return;
    if (_events.isClosed) return;
    final payload = _snapshotPayload(_normalizePayload(data));
    if (payload == null) {
      // ignore: avoid_print
      print(
        '[SurfaceRuntime] dropped event - '
        'event "$event" invalid_arguments:payload_not_json',
      );
      return;
    }
    final err = _activeManifest.validateEvent(event, payload.value);
    if (err != null) {
      // ignore: avoid_print
      print('[SurfaceRuntime] dropped event - $err');
      return;
    }
    _events.add(SurfaceEvent(_activeSurfaceId, event, payload.value));
  }

  Object? _normalizePayload(Object? data) {
    if (_activeManifest.schemaVersion == 1 && data == null) {
      return const <String, Object?>{};
    }
    return data;
  }

  /// Validates one agent-to-surface call without running JavaScript.
  ///
  /// The check is side-effect free and may be used for whole-envelope
  /// admission. [surfaceCall] repeats the same preparation immediately before
  /// execution so a stale preflight cannot authorize a changed payload,
  /// manifest, visibility state, or WebView attachment.
  String? preflightCall(String action, Object? data) =>
      _prepareSurfaceCall(action, data).error;

  static _SurfacePayloadSnapshot? _snapshotPayload(Object? value) {
    final budget = _SurfacePayloadBudget(
      remainingNodes: _maxPayloadNodes,
      remainingTextCodeUnits: _maxPayloadTextCodeUnits,
    );
    try {
      return _SurfacePayloadSnapshot(
        _snapshotPayloadValue(
          value,
          depth: 0,
          budget: budget,
          activeContainers: Set<Object>.identity(),
        ),
      );
    } on _InvalidSurfacePayload {
      return null;
    }
  }

  ({String? error, Object? payload, WebViewController? web})
  _prepareSurfaceCall(String action, Object? data) {
    final project = activeProject.value;
    if (project?.experienceType == SurfaceExperienceType.game ||
        project?.category == 'game') {
      return (
        error: 'game actions are controlled by the player',
        payload: null,
        web: null,
      );
    }
    if (activeProject.value?.rendering == SurfaceRendering.projectBundle) {
      return (
        error: 'project bundle requires typed operation authority',
        payload: null,
        web: null,
      );
    }
    final payload = _snapshotPayload(_normalizePayload(data));
    if (payload == null) {
      return (
        error: 'action "$action" invalid_arguments:payload_not_json',
        payload: null,
        web: null,
      );
    }
    final err = _activeManifest.validateAction(action, payload.value);
    if (err != null) return (error: err, payload: null, web: null);
    final web = _web;
    if (web == null || !isVisible.value) {
      return (error: 'no surface is open', payload: null, web: null);
    }
    return (error: null, payload: payload.value, web: web);
  }

  String manifestForPrompt({AppLocale? locale}) {
    if (!isVisible.value || _activeSurfaceId.isEmpty) return '';
    if (activeProject.value?.rendering == SurfaceRendering.projectBundle) {
      return '';
    }
    return _activeManifest.toPromptText(
      _activeSurfaceId,
      title: title.value,
      locale: locale,
    );
  }

  String _wrap(SurfaceProject project, {required int lifecycleToken}) {
    if (project.rendering == SurfaceRendering.workerCanvas) {
      return SurfaceWorkerCanvasHost.build(
        project,
        lifecycleToken: lifecycleToken,
      );
    }
    if (project.rendering == SurfaceRendering.webApp) {
      return SurfaceWebAppHost.build(project, lifecycleToken: lifecycleToken);
    }
    final documentDefaults = project.transparent
        ? 'html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden;}'
        : 'html,body{margin:0;width:100%;height:100%;overflow:hidden;}';
    return _template
        .replaceFirst('/*__SURFACE_DEFAULTS__*/', documentDefaults)
        .replaceFirst('/*__SURFACE_CSS__*/', _safeInlineStyle(project.css))
        .replaceFirst('<!--SURFACE_HTML-->', project.html)
        .replaceFirst('/*__SURFACE_JS__*/', _safeInlineScript(project.js));
  }

  static String _safeInlineScript(String source) {
    return source.replaceAll(
      RegExp(r'</script', caseSensitive: false),
      r'<\/script',
    );
  }

  static String _safeInlineStyle(String source) {
    return source.replaceAll(
      RegExp(r'</style', caseSensitive: false),
      r'<\/style',
    );
  }

  static String _compact(String value) {
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 48 ? text : '${text.substring(0, 48)}...';
  }

  static const String _template = '''
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
<style>
/*__SURFACE_DEFAULTS__*/
/*__SURFACE_CSS__*/
</style>
<script>
(function () {
  window.Surface = {
    emit: function (event, data) {
      try {
        SurfaceEvent.postMessage(JSON.stringify({
          event: event,
          data: (data === undefined ? null : data)
        }));
      } catch (e) {}
    },
    onAgent: null
  };
  window.__applyAgent = function (action, data) {
    if (typeof window.Surface.onAgent === 'function') {
      try { window.Surface.onAgent(action, data); } catch (e) {}
    }
  };
  function surfaceLogError(kind, message, detail) {
    try {
      console.error('[SurfaceRuntime] ' + kind + ': ' + message + (detail ? ' ' + detail : ''));
    } catch (e) {}
  }
  window.addEventListener("error", function (event) {
    var detail = (event.filename || '') + ':' + (event.lineno || 0) + ':' + (event.colno || 0);
    surfaceLogError('js error', event.message || 'unknown', detail);
  });
  window.addEventListener("unhandledrejection", function (event) {
    var reason = event && event.reason;
    var message = reason && (reason.stack || reason.message) ? (reason.stack || reason.message) : String(reason || 'unknown');
    surfaceLogError('unhandled rejection', message, '');
  });
})();
</script>
</head>
<body><!--SURFACE_HTML--><script>
/*__SURFACE_JS__*/
</script></body>
</html>
''';
}

final class _SurfaceCapabilityAuthority {
  const _SurfaceCapabilityAuthority({
    required this.service,
    required this.lease,
  });

  const _SurfaceCapabilityAuthority.legacy() : service = null, lease = null;

  final AppCapabilitySnapshotService? service;
  final AppCapabilitySnapshotLease? lease;

  bool get isCurrent {
    if (service == null && lease == null) return true;
    if (service == null || lease == null) return false;
    try {
      return service!.isCurrent(lease!) &&
          lease!.snapshot.allows(
            SurfaceRuntime._embeddedSurfaceCapability,
            requireVisible: true,
          );
    } catch (_) {
      return false;
    }
  }
}

final class _SurfacePayloadSnapshot {
  const _SurfacePayloadSnapshot(this.value);

  final Object? value;
}

final class _SurfacePayloadBudget {
  _SurfacePayloadBudget({
    required this.remainingNodes,
    required this.remainingTextCodeUnits,
  });

  int remainingNodes;
  int remainingTextCodeUnits;

  void takeNode() {
    if (remainingNodes <= 0) throw const _InvalidSurfacePayload();
    remainingNodes -= 1;
  }

  void takeText(String value) {
    remainingTextCodeUnits -= value.length;
    if (remainingTextCodeUnits < 0) throw const _InvalidSurfacePayload();
  }
}

final class _InvalidSurfacePayload implements Exception {
  const _InvalidSurfacePayload();
}

Object? _snapshotPayloadValue(
  Object? value, {
  required int depth,
  required _SurfacePayloadBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > SurfaceRuntime._maxPayloadDepth) {
    throw const _InvalidSurfacePayload();
  }
  budget.takeNode();
  if (value == null || value is bool) return value;
  if (value is String) {
    budget.takeText(value);
    return value;
  }
  if (value is num) {
    if (!value.isFinite) throw const _InvalidSurfacePayload();
    return value;
  }
  if (value is Map) {
    if (!activeContainers.add(value)) throw const _InvalidSurfacePayload();
    final snapshot = <String, Object?>{};
    try {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) throw const _InvalidSurfacePayload();
        budget.takeText(key);
        snapshot[key] = _snapshotPayloadValue(
          entry.value,
          depth: depth + 1,
          budget: budget,
          activeContainers: activeContainers,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return Map<String, Object?>.unmodifiable(snapshot);
  }
  if (value is List) {
    if (!activeContainers.add(value)) throw const _InvalidSurfacePayload();
    final snapshot = <Object?>[];
    try {
      for (final item in value) {
        snapshot.add(
          _snapshotPayloadValue(
            item,
            depth: depth + 1,
            budget: budget,
            activeContainers: activeContainers,
          ),
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return List<Object?>.unmodifiable(snapshot);
  }
  throw const _InvalidSurfacePayload();
}
