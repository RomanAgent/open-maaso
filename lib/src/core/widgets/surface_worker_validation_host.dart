import 'dart:async';
import 'dart:io';
import 'package:maaso/src/offline/local_surface_host.dart';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// App-root, on-demand first-frame preflight host.
///
/// It is laid out at the real app viewport so generated games see production
/// dimensions. It never attaches to [SurfaceRuntime], accepts only the current
/// session's strict lifecycle payload, and is removed after its first terminal
/// frame result. Visible SurfaceWebViews remain suppressed until that removal.
class SurfaceWorkerValidationHost extends StatelessWidget {
  const SurfaceWorkerValidationHost({super.key});

  @override
  Widget build(BuildContext context) {
    final gate = appServices.maybeFind<SurfaceWorkerHealthGate>();
    final fallbackRuntime = appServices.maybeFind<SurfaceRuntime>();
    if (gate == null || fallbackRuntime == null) return const SizedBox.shrink();
    return AppReactiveBuilder(() {
      final request = gate.activeRequest.value;
      if (request == null) return const SizedBox.shrink();
      return Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: _SurfaceWorkerValidationSession(
              key: ValueKey<int>(request.session),
              gate: gate,
              runtime: request.runtime ?? fallbackRuntime,
              request: request,
            ),
          ),
        ),
      );
    });
  }
}

class _SurfaceWorkerValidationSession extends StatefulWidget {
  const _SurfaceWorkerValidationSession({
    super.key,
    required this.gate,
    required this.runtime,
    required this.request,
  });

  final SurfaceWorkerHealthGate gate;
  final SurfaceRuntime runtime;
  final SurfaceWorkerValidationRequest request;

  @override
  State<_SurfaceWorkerValidationSession> createState() =>
      _SurfaceWorkerValidationSessionState();
}

class _SurfaceWorkerValidationSessionState
    extends State<_SurfaceWorkerValidationSession> {
  static const String _blankDocument =
      '<!doctype html><html><body></body></html>';
  static const Duration _cleanupStepTimeout = Duration(milliseconds: 500);

  late final WebViewController _controller;
  bool _terminal = false;
  bool _loadingInitialDocument = true;
  bool _allowInitialWebAppNavigation = true;
  bool _initialWebAppDocumentStarted = false;
  String? _webAppLifecycleNonce;
  String? _webAppDocumentBaseUrl;

  @override
  void initState() {
    super.initState();
    _tracePhase('mount');
    _controller = createLocalSurfaceController();
    unawaited(_configureAndLoad());
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  Future<void> _configureAndLoad() async {
    try {
      await configureLocalSurfaceController(_controller);
      if (_isWebApp) {
        _webAppDocumentBaseUrl = SurfaceWebAppHost.documentBaseUrl(
          widget.runtime.activeProject.value!,
          lifecycleToken: widget.request.session,
          role: SurfaceWebAppDocumentRole.preflight,
        );
      }
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!Platform.isMacOS) {
        await _controller.setBackgroundColor(Colors.transparent);
      }
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _handleNavigationRequest,
          onPageStarted: _handlePageStarted,
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            if (SurfaceWebAppNavigationMessage.tryParse(error.url ?? '') !=
                null) {
              return;
            }
            _tracePhase('load-error');
            if (widget.gate.reportHostFatal(
              SurfaceWorkerFatalReason.webViewLoadFailed,
              session: widget.request.session,
              currentSession: widget.runtime.activeSession,
            )) {
              unawaited(_clearAndRelease());
            }
          },
        ),
      );
      if (_isWebApp) {
        await _controller.addJavaScriptChannel(
          'SurfaceValidationLifecycle',
          onMessageReceived: (message) {
            _handleWebAppLifecycleMessage(message.message);
          },
        );
      } else {
        await _controller.addJavaScriptChannel(
          'SurfaceLifecycle',
          onMessageReceived: (message) {
            _tracePhase('lifecycle');
            if (widget.gate.acceptLifecycleMessage(
              message.message,
              currentSession: widget.runtime.activeSession,
            )) {
              unawaited(_clearAndRelease());
            }
          },
        );
      }
      _tracePhase('configured');
      _tracePhase('load');
      try {
        await _controller.loadHtmlString(
          localSurfaceDocument(
            widget.request.document,
            const {},
            enableStorage: false,
          ),
          baseUrl: _webAppDocumentBaseUrl,
        );
      } finally {
        _loadingInitialDocument = false;
      }
    } catch (_) {
      _tracePhase('load-error');
      if (widget.gate.reportHostFatal(
        SurfaceWorkerFatalReason.webViewLoadFailed,
        session: widget.request.session,
        currentSession: widget.runtime.activeSession,
      )) {
        await _clearAndRelease();
      }
    }
  }

  Future<void> _clearAndRelease() async {
    if (_terminal) return;
    _terminal = true;
    try {
      await _controller
          .runJavaScript(
            'if (typeof window.__disposeSurfaceWorker === "function") {'
            'window.__disposeSurfaceWorker(${widget.request.session});'
            '}',
          )
          .timeout(_cleanupStepTimeout);
    } catch (_) {}
    try {
      await _controller
          .loadHtmlString(_blankDocument)
          .timeout(_cleanupStepTimeout);
    } catch (_) {}
    await disposeLocalSurfaceController(_controller);
    if (widget.gate.releaseValidationHost(widget.request.session)) {
      _tracePhase('release');
    }
  }

  bool get _isWebApp =>
      widget.runtime.activeSession == widget.request.session &&
      widget.runtime.activeProject.value?.rendering == SurfaceRendering.webApp;

  void _handleWebAppLifecycleMessage(String source) {
    final message = SurfaceWebAppLifecycleMessage.tryParse(source);
    if (message == null ||
        !_isWebApp ||
        message.session != widget.request.session) {
      return;
    }
    if (message.kind == SurfaceWebAppLifecycleKind.bootstrap) {
      _allowInitialWebAppNavigation = false;
      final currentNonce = _webAppLifecycleNonce;
      if (currentNonce == null) {
        _webAppLifecycleNonce = message.nonce;
        _tracePhase('bootstrap');
        return;
      }
      if (currentNonce != message.nonce) {
        _tracePhase('unexpected-reload');
        if (widget.gate.reportHostFatal(
          SurfaceWorkerFatalReason.securityBoundaryFailed,
          session: widget.request.session,
          currentSession: widget.runtime.activeSession,
        )) {
          unawaited(_clearAndRelease());
        }
      }
      return;
    }
    if (message.nonce == _webAppLifecycleNonce &&
        (message.diagnostic == null ||
            message.diagnostic!.matchesProjectSource(
              html: widget.runtime.activeProject.value!.html,
              js: widget.runtime.activeProject.value!.js,
            )) &&
        widget.gate.acceptLifecycleMessage(
          message.gatePayloadJson,
          currentSession: widget.runtime.activeSession,
        )) {
      _tracePhase('lifecycle');
      unawaited(_clearAndRelease());
    }
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    final message = SurfaceWebAppNavigationMessage.tryParse(request.url);
    if (message != null) {
      return NavigationDecision.prevent;
    }
    if (!_isWebApp || !request.isMainFrame) {
      return NavigationDecision.navigate;
    }
    final expectedDocument = _webAppDocumentBaseUrl;
    if (expectedDocument != null &&
        SurfaceWebAppHost.matchesDocumentBaseUrl(
          request.url,
          expectedDocument,
        )) {
      return NavigationDecision.navigate;
    }
    final isInternalDocument = _isInternalWebAppDocumentUrl(request.url);
    if (isInternalDocument &&
        (_loadingInitialDocument ||
            _allowInitialWebAppNavigation ||
            _terminal)) {
      return NavigationDecision.navigate;
    }
    if (!_terminal) {
      _tracePhase('unexpected-navigation');
      if (widget.gate.reportHostFatal(
        SurfaceWorkerFatalReason.securityBoundaryFailed,
        session: widget.request.session,
        currentSession: widget.runtime.activeSession,
      )) {
        unawaited(_clearAndRelease());
      }
    }
    return NavigationDecision.prevent;
  }

  void _handlePageStarted(String url) {
    // WK reports all navigation actions through onNavigationRequest and its
    // async page-start URL can be stale. Android needs this POST fallback.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (!_isWebApp || _terminal) return;
    final message = SurfaceWebAppNavigationMessage.tryParse(url);
    if (message != null) return;
    if (!_initialWebAppDocumentStarted) {
      final expectedDocument = _webAppDocumentBaseUrl;
      if (expectedDocument != null &&
          SurfaceWebAppHost.matchesDocumentBaseUrl(url, expectedDocument)) {
        _initialWebAppDocumentStarted = true;
      }
      return;
    }
    // Android may skip onNavigationRequest for a main-frame POST. Once the
    // host-controlled document starts, every later document start is an
    // authored replacement and must fail the same boundary on both hosts.
    _tracePhase('unexpected-page-start');
    if (widget.gate.reportHostFatal(
      SurfaceWorkerFatalReason.securityBoundaryFailed,
      session: widget.request.session,
      currentSession: widget.runtime.activeSession,
    )) {
      unawaited(_clearAndRelease());
    }
  }

  void _tracePhase(String phase) {
    TurnTrace.event(
      'surface.validation_host',
      details: 'session=${widget.request.session} phase=$phase',
    );
  }
}

bool _isInternalWebAppDocumentUrl(String source) {
  if (source.isEmpty) return true;
  final uri = Uri.tryParse(source);
  return uri != null &&
      ((uri.scheme == 'about' && uri.path == 'blank') ||
          uri.scheme == 'data' ||
          uri.scheme == 'blob');
}
