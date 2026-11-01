import 'dart:async';
import 'dart:convert';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_document.dart';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_web_app_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SurfaceWebView extends StatefulWidget {
  const SurfaceWebView({
    super.key,
    this.backgroundColor,
    this.runtime,
    this.onWorkerFatal,
    this.onFirstFrameReady,
    this.controller,
  });

  final Color? backgroundColor;
  final SurfaceRuntime? runtime;
  final ValueChanged<SurfaceWorkerFatalReason>? onWorkerFatal;

  /// Optional observation of the existing visible player after its own first
  /// frame validation. Never creates a second player for cover generation.
  final ValueChanged<WebViewController>? onFirstFrameReady;

  /// An explicitly isolated controller owned by an invocation host. Ordinary
  /// players retain their existing default controller/data-store behavior.
  final WebViewController? controller;

  static const webAppFirstFrameCoverKey = ValueKey<String>(
    'surface-web-app-first-frame-cover',
  );
  static const hostUnavailableKey = ValueKey<String>(
    'surface-web-view-host-unavailable',
  );

  @override
  State<SurfaceWebView> createState() => _SurfaceWebViewState();
}

class _SurfaceWebViewState extends State<SurfaceWebView>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  late final bool _hostSupported;
  SurfaceRuntime? _runtime;
  SurfaceWorkerHealthGate? _workerHealthGate;
  Worker? _documentWorker;
  Worker? _validationClaimWorker;
  Worker? _visibleLeaseWorker;
  bool _isConfigured = false;
  bool _surfaceEventChannelAdded = false;
  bool _surfaceLifecycleChannelAdded = false;
  bool _webAppValidationChannelAdded = false;
  bool _bundleChannelAdded = false;
  Future<void> _loadSerial = Future<void>.value();
  String? _loadedDocument;
  bool _workerSuppressed = false;
  bool _loadingInternalDocument = false;
  int? _reportedFatalSession;
  int? _reportedFirstFrameSession;
  int? _webAppLifecycleSession;
  String? _webAppLifecycleNonce;
  Timer? _webAppFirstFrameTimer;
  bool _webAppFirstFrameReady = false;
  bool _webAppFirstFrameFailed = false;
  bool _allowInitialWebAppNavigation = false;
  int _webAppLoadEpoch = 0;
  int? _webAppStartedLoadEpoch;
  String? _webAppDocumentBaseUrl;
  SurfaceWebAppNavigationMessage? _pendingInitialGameState;
  final _controlFocus = FocusNode(debugLabel: 'project-applet-takeover');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime =
        widget.runtime ??
        (appServices.isRegistered<SurfaceRuntime>()
            ? appServices.find<SurfaceRuntime>()
            : null);
    _hostSupported = _surfaceWebViewHostSupported;
    if (!_hostSupported) return;
    _controller = widget.controller ?? WebViewController();
    // The global validation gate belongs to the appServices SurfaceRuntime.
    // A route/feed-injected runtime has exactly one owned host and must not
    // collide with global runtime session numbers or its visible-host lease.
    _workerHealthGate = widget.runtime == null
        ? appServices.maybeFind<SurfaceWorkerHealthGate>()
        : null;
    _runtime?.attach(_controller);
    final rt = _runtime;
    if (rt != null) {
      _documentWorker = ever<String?>(rt.document, _loadDocument);
    }
    final gate = _workerHealthGate;
    if (rt != null && gate != null) {
      _validationClaimWorker = ever<SurfaceWorkerValidationRequest?>(
        gate.activeRequest,
        (_) => _loadDocument(rt.document.value),
      );
      _visibleLeaseWorker = ever<int>(
        gate.visibleLeaseRevision,
        (_) => _loadDocument(rt.document.value),
      );
    }
    unawaited(_configureController());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlFocus.dispose();
    _webAppFirstFrameTimer?.cancel();
    _runtime?.activeProject.value?.bundlePresentation?.detach();
    _documentWorker?.dispose();
    _validationClaimWorker?.dispose();
    _visibleLeaseWorker?.dispose();
    _workerHealthGate?.releaseVisibleHost(this);
    if (_hostSupported) {
      _runtime?.detach(_controller);
    }
    super.dispose();
  }

  bool get _controlVisible =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controlVisibilityChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controlVisibilityChanged();
  }

  void _controlVisibilityChanged() {
    final presentation = _runtime?.activeProject.value?.bundlePresentation;
    presentation?.visibleContextChanged();
    if (presentation != null && !presentation.isGame && _controlVisible) {
      unawaited(presentation.restoreAppletDocument().catchError((Object _) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rt = _runtime;
    if (rt == null) return const SizedBox.shrink();
    if (!_hostSupported) return _buildUnavailableHost(context, rt);
    return AppReactiveBuilder(() {
      final visible = rt.isVisible.value && rt.document.value != null;
      final project = rt.activeProject.value;
      final presentation = project?.bundlePresentation;
      final waitingForWebAppFrame =
          visible &&
          (project?.rendering == SurfaceRendering.webApp ||
              project?.rendering == SurfaceRendering.projectBundle) &&
          (_webAppLifecycleSession != rt.activeSession ||
              !_webAppFirstFrameReady);
      return StreamBuilder<void>(
        stream: presentation?.onControlsChanged,
        builder: (context, _) {
          final controlled = presentation?.appletGrant != null;
          return Offstage(
            offstage: !visible,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ExcludeSemantics(
                  excluding: controlled,
                  child: AbsorbPointer(
                    absorbing: controlled,
                    child: ColoredBox(
                      color: widget.backgroundColor ?? Colors.transparent,
                      child: WebViewWidget(controller: _controller),
                    ),
                  ),
                ),
                if (controlled)
                  Positioned.fill(
                    child: Focus(
                      focusNode: _controlFocus,
                      autofocus: true,
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent) {
                          unawaited(presentation!.takeOverAppletFromNative());
                        }
                        return KeyEventResult.handled;
                      },
                      child: Semantics(
                        button: true,
                        label: 'project_control.take_over'.tr,
                        onTap: () =>
                            unawaited(presentation!.takeOverAppletFromNative()),
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (_) => unawaited(
                            presentation!.takeOverAppletFromNative(),
                          ),
                          child: const ColoredBox(color: Colors.transparent),
                        ),
                      ),
                    ),
                  ),
                if (waitingForWebAppFrame)
                  Positioned.fill(
                    key: SurfaceWebView.webAppFirstFrameCoverKey,
                    child: AbsorbPointer(
                      child: ColoredBox(
                        color:
                            widget.backgroundColor ??
                            Theme.of(context).scaffoldBackgroundColor,
                        child: Center(
                          child: _webAppFirstFrameFailed
                              ? Icon(
                                  Icons.error_outline_rounded,
                                  color: Theme.of(context).colorScheme.error,
                                  size: 30,
                                )
                              : SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    });
  }

  Widget _buildUnavailableHost(BuildContext context, SurfaceRuntime rt) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return AppReactiveBuilder(() {
      final visible = rt.isVisible.value && rt.document.value != null;
      return Offstage(
        offstage: !visible,
        child: ColoredBox(
          key: SurfaceWebView.hostUnavailableKey,
          color:
              widget.backgroundColor ??
              Theme.of(context).scaffoldBackgroundColor,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.widgets_outlined,
                    size: 36,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isZh
                        ? '当前平台暂不支持交互式小程序'
                        : 'Interactive Applets are unavailable',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isZh
                        ? '页面和已保存内容仍可访问；请在 iOS、Android 或 macOS 上运行此小程序。'
                        : 'The page and saved content remain available. Run this Applet on iOS, Android, or macOS.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Future<void> _configureController() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      await _controller.setBackgroundColor(
        widget.backgroundColor ?? Colors.transparent,
      );
    }
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: _handleNavigationRequest,
        onPageStarted: _handlePageStarted,
        onWebResourceError: (error) {
          if (_runtime?.activeProject.value?.rendering ==
              SurfaceRendering.projectBundle) {
            if (error.isForMainFrame != false) {
              _failVisibleWebApp(
                SurfaceWorkerFatalReason.webViewLoadFailed,
                session: _runtime?.activeSession,
              );
            }
            return;
          }
          if (SurfaceWebAppNavigationMessage.tryParse(error.url ?? '') !=
              null) {
            return;
          }
          if (_isSupersededWebAppDocumentUrl(
            error.url,
            _webAppDocumentBaseUrl,
          )) {
            return;
          }
          if (error.isForMainFrame != false &&
              _runtime?.activeProject.value?.rendering ==
                  SurfaceRendering.webApp) {
            final isCurrentDocumentFailure =
                defaultTargetPlatform == TargetPlatform.android
                ? _webAppStartedLoadEpoch == _webAppLoadEpoch
                : _isCurrentWebAppDocumentUrl(
                    error.url,
                    _webAppDocumentBaseUrl,
                  );
            if (!_isSupersededNavigationCancellation(error) &&
                (_isControllerLevelWebAppFailure(error) ||
                    isCurrentDocumentFailure)) {
              _failVisibleWebApp(
                SurfaceWorkerFatalReason.webViewLoadFailed,
                session: _runtime?.activeSession,
              );
            }
          }
          debugPrint(
            '[SurfaceWebView] error loading ${error.url}: '
            'code=${error.errorCode} type=${error.errorType} '
            'mainFrame=${error.isForMainFrame} ${error.description}',
          );
        },
      ),
    );
    await _controller.setOnConsoleMessage((msg) {
      if (_runtime?.activeProject.value?.rendering ==
          SurfaceRendering.projectBundle) {
        return;
      }
      debugPrint('[SurfaceWebView] ${msg.message}');
    });
    _isConfigured = true;
    _loadDocument(_runtime?.document.value);
  }

  NavigationDecision _handleNavigationRequest(NavigationRequest request) {
    if (_runtime?.activeProject.value?.rendering ==
        SurfaceRendering.projectBundle) {
      if (request.isMainFrame &&
          surfaceBundleAllowsInitialNavigation(
            source: request.url,
            expectedDocument: _webAppDocumentBaseUrl,
            loading: _loadingInternalDocument,
            allowInitial: _allowInitialWebAppNavigation,
          )) {
        _allowInitialWebAppNavigation = false;
        return NavigationDecision.navigate;
      }
      return NavigationDecision.prevent;
    }
    final message = SurfaceWebAppNavigationMessage.tryParse(request.url);
    if (message != null) {
      if (request.isMainFrame) {
        _handleWebAppNavigationMessage(message);
      }
      return NavigationDecision.prevent;
    }
    // Closing the runtime precedes clearing its native document. Keep failed
    // authored code inert during that gap without blocking a replacement load.
    if (_reportedFatalSession != null &&
        _reportedFatalSession == _runtime?.activeSession &&
        !(_loadingInternalDocument && _isEmptyHostDocumentUrl(request.url))) {
      return NavigationDecision.prevent;
    }
    final project = _runtime?.activeProject.value;
    if (project?.rendering != SurfaceRendering.webApp || !request.isMainFrame) {
      return NavigationDecision.navigate;
    }
    final expectedDocument = _webAppDocumentBaseUrl;
    if (expectedDocument != null &&
        SurfaceWebAppHost.matchesDocumentBaseUrl(
          request.url,
          expectedDocument,
        )) {
      // Same-document hash navigation stays available to SPAs. A real reload
      // also reaches onPageStarted and is rejected there.
      return NavigationDecision.navigate;
    }
    if (expectedDocument != null &&
        SurfaceWebAppHost.isDocumentBaseUrl(request.url) &&
        _webAppStartedLoadEpoch != _webAppLoadEpoch) {
      // A delayed decision from a superseded in-memory host must not poison
      // the session whose document has not started yet.
      return NavigationDecision.prevent;
    }
    final isInternalDocument = _isInternalWebAppDocumentUrl(request.url);
    if (isInternalDocument &&
        (_loadingInternalDocument || _allowInitialWebAppNavigation)) {
      return NavigationDecision.navigate;
    }
    _failVisibleWebApp(
      SurfaceWorkerFatalReason.securityBoundaryFailed,
      session: _runtime?.activeSession,
    );
    return NavigationDecision.prevent;
  }

  void _handlePageStarted(String url) {
    // WK reports navigation actions (including POST) to onNavigationRequest.
    // Its page-start callback reads webView.url only after an async hop, so a
    // superseded A callback can be mislabeled as B. Android omits POST from
    // shouldOverrideUrlLoading and needs this fallback.
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final rt = _runtime;
    if (rt == null ||
        (rt.activeProject.value?.rendering != SurfaceRendering.webApp &&
            rt.activeProject.value?.rendering !=
                SurfaceRendering.projectBundle) ||
        rt.activeSession != _webAppLifecycleSession ||
        _webAppFirstFrameFailed) {
      return;
    }
    final expectedDocument = _webAppDocumentBaseUrl;
    if (_webAppStartedLoadEpoch != _webAppLoadEpoch) {
      if (expectedDocument != null &&
          SurfaceWebAppHost.matchesDocumentBaseUrl(url, expectedDocument)) {
        _webAppStartedLoadEpoch = _webAppLoadEpoch;
      }
      // Until the exact current host URL starts, callbacks can only belong to
      // a superseded load. Authored code in the current document cannot run
      // before this callback.
      return;
    }
    // Android does not invoke shouldOverrideUrlLoading for every POST. The
    // main-frame start callback is therefore the authoritative fallback for
    // document replacements that bypass onNavigationRequest.
    _failVisibleWebApp(
      SurfaceWorkerFatalReason.securityBoundaryFailed,
      session: rt.activeSession,
    );
  }

  void _handleWebAppNavigationMessage(SurfaceWebAppNavigationMessage message) {
    final rt = _runtime;
    if (rt == null ||
        rt.activeProject.value?.rendering != SurfaceRendering.webApp ||
        message.session != rt.activeSession ||
        message.session != _webAppLifecycleSession ||
        message.kind != SurfaceWebAppNavigationKind.event ||
        _webAppFirstFrameFailed ||
        _reportedFatalSession == message.session) {
      return;
    }
    if (!_webAppFirstFrameReady) {
      final project = rt.activeProject.value!;
      final data = message.data;
      if (_webAppLifecycleNonce == null ||
          project.experienceType != SurfaceExperienceType.game ||
          !project.manifest.events.any((entry) => entry.name == 'game.state') ||
          message.event != 'game.state' ||
          data is! Map<String, dynamic> ||
          data.length != 2) {
        return;
      }
      final observation = GameVoiceEnvelope.fromJson({
        ...data,
        'kind': message.event,
      });
      if (observation == null || observation.state.isEmpty) return;
      final pending = _pendingInitialGameState?.data;
      if (pending is Map &&
          pending['revision'] is int &&
          observation.revision <= (pending['revision'] as int)) {
        return;
      }
      // The navigation parser caps this entire message at 8 KB. Keep only
      // one real initial snapshot until this exact visible load is admitted.
      _pendingInitialGameState = message;
      return;
    }
    rt.onPageEvent(message.event, message.data);
  }

  void _handleSurfaceMessage(JavaScriptMessage message) {
    final rt = _runtime;
    if (rt == null) return;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map) {
        rt.onPageEvent(
          decoded['event']?.toString() ?? 'event',
          decoded['data'],
        );
      }
    } catch (_) {}
  }

  void _handleScopedWorkerLifecycle(JavaScriptMessage message) {
    final rt = _runtime;
    final lifecycle = SurfaceWorkerLifecycleMessage.tryParse(message.message);
    if (rt == null ||
        lifecycle == null ||
        lifecycle.session != rt.activeSession ||
        lifecycle.session == _reportedFatalSession) {
      return;
    }
    if (lifecycle.isReady) {
      _notifyFirstFrame(lifecycle.session);
      return;
    }
    _reportedFatalSession = lifecycle.session;
    widget.onWorkerFatal?.call(lifecycle.reason!);
  }

  void _loadDocument(String? document) {
    if (!_isConfigured) return;
    final requestedSession = _runtime?.activeSession;
    final previous = _loadSerial;
    _loadSerial = () async {
      try {
        await previous;
        await _loadDocumentNow(document);
      } catch (error) {
        if (_runtime?.activeProject.value?.rendering ==
            SurfaceRendering.webApp) {
          _failVisibleWebApp(
            SurfaceWorkerFatalReason.webViewLoadFailed,
            session: requestedSession,
          );
        }
        debugPrint('[SurfaceWebView] document load failed: $error');
      }
    }();
  }

  Future<void> _loadDocumentNow(String? document) async {
    final rt = _runtime;
    if (document != rt?.document.value) return;
    final gate = _workerHealthGate;
    if (document == null) {
      _resetVisibleWebAppValidation();
      gate?.releaseVisibleHost(this);
      _workerSuppressed = false;
      if (_loadedDocument != null) {
        _loadedDocument = null;
        await _loadInternalDocument(
          '<!doctype html><html><body></body></html>',
        );
      }
      return;
    }
    final project = rt?.activeProject.value;
    if (project?.rendering != SurfaceRendering.webApp &&
        project?.rendering != SurfaceRendering.projectBundle) {
      _resetVisibleWebAppValidation();
    }
    final requiresFirstFrameValidation =
        project != null && surfaceRequiresFirstFrameValidation(project);
    if (requiresFirstFrameValidation && gate != null) {
      final session = rt!.activeSession;
      if (gate.shouldSuppressVisibleSession(session) ||
          !gate.claimVisibleHost(this, session)) {
        if (!_workerSuppressed && _loadedDocument != null) {
          _workerSuppressed = true;
          _loadedDocument = null;
          await _loadInternalDocument(
            '<!doctype html><html><body></body></html>',
          );
        }
        return;
      }
      _workerSuppressed = false;
    } else {
      gate?.releaseVisibleHost(this);
      _workerSuppressed = false;
    }
    final shouldLoadDocument = document != _loadedDocument;
    if (shouldLoadDocument &&
        (project?.rendering == SurfaceRendering.webApp ||
            project?.rendering == SurfaceRendering.projectBundle)) {
      final session = rt!.activeSession;
      _armVisibleWebAppValidation(
        session,
        documentBaseUrl: project!.bundlePresentation != null
            ? SurfaceBundleDocument.baseUrl(
                project.bundlePresentation!.nonce,
                session,
              )
            : SurfaceWebAppHost.documentBaseUrl(
                project,
                lifecycleToken: session,
                role: SurfaceWebAppDocumentRole.visible,
              ),
      );
    }
    await _syncNativeChannels(
      enable: project?.rendering != SurfaceRendering.webApp,
    );
    if (document != rt?.document.value) return;
    if (!shouldLoadDocument) return;
    _reportedFatalSession = null;
    _loadedDocument = document;
    await _loadInternalDocument(
      document,
      baseUrl:
          (project?.rendering == SurfaceRendering.webApp ||
              project?.rendering == SurfaceRendering.projectBundle)
          ? _webAppDocumentBaseUrl
          : null,
    );
  }

  Future<void> _loadInternalDocument(String document, {String? baseUrl}) async {
    _loadingInternalDocument = true;
    try {
      await _controller.loadHtmlString(document, baseUrl: baseUrl);
    } finally {
      _loadingInternalDocument = false;
    }
  }

  Future<void> _syncNativeChannels({required bool enable}) async {
    final presentation = _runtime?.activeProject.value?.bundlePresentation;
    if (presentation != null) {
      if (_surfaceLifecycleChannelAdded) {
        await _controller.removeJavaScriptChannel('SurfaceLifecycle');
        _surfaceLifecycleChannelAdded = false;
      }
      if (_surfaceEventChannelAdded) {
        await _controller.removeJavaScriptChannel('SurfaceEvent');
        _surfaceEventChannelAdded = false;
      }
      if (_webAppValidationChannelAdded) {
        await _controller.removeJavaScriptChannel('SurfaceValidationLifecycle');
        _webAppValidationChannelAdded = false;
      }
      if (!_bundleChannelAdded) {
        await _controller.addJavaScriptChannel(
          'MaasoProjectBridge',
          onMessageReceived: _handleBundleMessage,
        );
        _bundleChannelAdded = true;
      }
      final attachedNonce = presentation.nonce;
      presentation.attach(
        (source) async {
          if (!mounted ||
              !presentation.isCurrent ||
              presentation.nonce != attachedNonce ||
              !identical(
                _runtime?.activeProject.value?.bundlePresentation,
                presentation,
              )) {
            return;
          }
          await _controller.runJavaScript(source);
        },
        evaluateResult: (source) async {
          if (!mounted ||
              !presentation.isCurrent ||
              presentation.nonce != attachedNonce ||
              !identical(
                _runtime?.activeProject.value?.bundlePresentation,
                presentation,
              )) {
            throw StateError('applet_document_changed');
          }
          return _controller.runJavaScriptReturningResult(source);
        },
        isVisible: () => _controlVisible,
      );
      return;
    }
    if (_bundleChannelAdded) {
      await _controller.removeJavaScriptChannel('MaasoProjectBridge');
      _bundleChannelAdded = false;
    }
    if (enable) {
      if (_webAppValidationChannelAdded) {
        await _controller.removeJavaScriptChannel('SurfaceValidationLifecycle');
        _webAppValidationChannelAdded = false;
      }
      if (!_surfaceEventChannelAdded) {
        await _controller.addJavaScriptChannel(
          'SurfaceEvent',
          onMessageReceived: _handleSurfaceMessage,
        );
        _surfaceEventChannelAdded = true;
      }
      if ((widget.onWorkerFatal != null || widget.onFirstFrameReady != null) &&
          !_surfaceLifecycleChannelAdded) {
        await _controller.addJavaScriptChannel(
          'SurfaceLifecycle',
          onMessageReceived: _handleScopedWorkerLifecycle,
        );
        _surfaceLifecycleChannelAdded = true;
      }
      return;
    }
    if (_surfaceLifecycleChannelAdded) {
      await _controller.removeJavaScriptChannel('SurfaceLifecycle');
      _surfaceLifecycleChannelAdded = false;
    }
    if (_surfaceEventChannelAdded) {
      await _controller.removeJavaScriptChannel('SurfaceEvent');
      _surfaceEventChannelAdded = false;
    }
    // Keep validation and visible webApp documents observationally equivalent.
    // The visible host authenticates its own final-size frame independently;
    // it never reuses the disposable preflight host's result.
    if (!_webAppValidationChannelAdded) {
      await _controller.addJavaScriptChannel(
        'SurfaceValidationLifecycle',
        onMessageReceived: (message) {
          _handleVisibleWebAppLifecycleMessage(message.message);
        },
      );
      _webAppValidationChannelAdded = true;
    }
  }

  Future<void> _handleBundleMessage(JavaScriptMessage message) async {
    final runtime = _runtime;
    final presentation = runtime?.activeProject.value?.bundlePresentation;
    if (runtime == null || presentation == null || !presentation.isCurrent) {
      return;
    }
    final session = runtime.activeSession;
    final receivedNonce = presentation.nonce;
    final response = await presentation.handle(message.message);
    if (!mounted ||
        response == null ||
        !presentation.isCurrent ||
        presentation.nonce != receivedNonce ||
        !runtime.isSessionCurrent(session)) {
      return;
    }
    if (response.frameReady != null) {
      if (response.frameReady == true &&
          (!(ModalRoute.of(context)?.isCurrent ?? true) ||
              (WidgetsBinding.instance.lifecycleState != null &&
                  WidgetsBinding.instance.lifecycleState !=
                      AppLifecycleState.resumed))) {
        return;
      }
      if (response.frameReady == true && !_webAppFirstFrameFailed) {
        _allowInitialWebAppNavigation = false;
        _webAppFirstFrameTimer?.cancel();
        _webAppFirstFrameReady = true;
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              presentation.isCurrent &&
              presentation.nonce == receivedNonce &&
              runtime.isSessionCurrent(session) &&
              (ModalRoute.of(context)?.isCurrent ?? true) &&
              (WidgetsBinding.instance.lifecycleState == null ||
                  WidgetsBinding.instance.lifecycleState ==
                      AppLifecycleState.resumed)) {
            presentation.reportFirstFrame(true);
          }
        });
        WidgetsBinding.instance.ensureVisualUpdate();
        _notifyFirstFrame(session);
      } else {
        _failVisibleWebApp(
          SurfaceWorkerFatalReason.webViewLoadFailed,
          session: session,
        );
      }
    }
    try {
      await _controller.runJavaScript(
        'globalThis.__maasoNativeReply?.(${SurfaceBundleDocument.safeJson(presentation.nonce)},'
        '${SurfaceBundleDocument.safeJson(response.id)},${SurfaceBundleDocument.safeJson(response.result)},'
        '${SurfaceBundleDocument.safeJson(response.error)})',
      );
    } catch (_) {
      /* The exact presentation may have left during the reply. */
    }
  }

  void _armVisibleWebAppValidation(
    int session, {
    required String documentBaseUrl,
  }) {
    _webAppFirstFrameTimer?.cancel();
    _webAppLifecycleSession = session;
    _webAppLifecycleNonce = null;
    _pendingInitialGameState = null;
    _webAppFirstFrameReady = false;
    _webAppFirstFrameFailed = false;
    _allowInitialWebAppNavigation = true;
    _webAppLoadEpoch += 1;
    _webAppStartedLoadEpoch = null;
    _webAppDocumentBaseUrl = documentBaseUrl;
    _webAppFirstFrameTimer = Timer(const Duration(seconds: 15), () {
      _failVisibleWebApp(
        SurfaceWorkerFatalReason.watchdogTimeout,
        session: session,
      );
    });
    if (mounted) setState(() {});
  }

  void _resetVisibleWebAppValidation() {
    _webAppFirstFrameTimer?.cancel();
    _webAppFirstFrameTimer = null;
    _webAppLifecycleSession = null;
    _webAppLifecycleNonce = null;
    _pendingInitialGameState = null;
    _webAppFirstFrameReady = false;
    _webAppFirstFrameFailed = false;
    _allowInitialWebAppNavigation = false;
    _webAppStartedLoadEpoch = null;
    _webAppDocumentBaseUrl = null;
  }

  void _handleVisibleWebAppLifecycleMessage(String source) {
    final message = SurfaceWebAppLifecycleMessage.tryParse(source);
    final rt = _runtime;
    if (message == null ||
        rt == null ||
        rt.activeProject.value?.rendering != SurfaceRendering.webApp ||
        message.session != rt.activeSession ||
        message.session != _webAppLifecycleSession ||
        _webAppFirstFrameFailed) {
      return;
    }
    if (message.kind == SurfaceWebAppLifecycleKind.bootstrap) {
      final nonce = _webAppLifecycleNonce;
      _allowInitialWebAppNavigation = false;
      if (nonce == null) {
        _webAppLifecycleNonce = message.nonce;
      } else if (nonce != message.nonce) {
        _failVisibleWebApp(
          SurfaceWorkerFatalReason.securityBoundaryFailed,
          session: message.session,
        );
      }
      return;
    }
    if (message.nonce != _webAppLifecycleNonce) return;
    if (message.diagnostic != null &&
        !message.diagnostic!.matchesProjectSource(
          html: rt.activeProject.value!.html,
          js: rt.activeProject.value!.js,
        )) {
      return;
    }
    if (message.kind == SurfaceWebAppLifecycleKind.fatal) {
      _failVisibleWebApp(
        SurfaceWorkerFatalReason.runtimeFailed,
        session: message.session,
      );
      return;
    }
    _webAppFirstFrameTimer?.cancel();
    _webAppFirstFrameTimer = null;
    _webAppFirstFrameReady = true;
    if (mounted) setState(() {});
    _notifyFirstFrame(message.session);
  }

  void _notifyFirstFrame(int session) {
    final initialState = _pendingInitialGameState;
    _pendingInitialGameState = null;
    final notifyCapture =
        widget.onFirstFrameReady != null &&
        _reportedFirstFrameSession != session;
    if (initialState == null && !notifyCapture) return;
    if (notifyCapture) _reportedFirstFrameSession = session;
    final loadEpoch = _webAppLoadEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _reportedFatalSession == session ||
          _runtime?.activeSession != session ||
          _runtime?.isVisible.value != true ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed)) {
        return;
      }
      if (initialState != null &&
          initialState.session == session &&
          _webAppLoadEpoch == loadEpoch &&
          _webAppLifecycleSession == session &&
          _webAppFirstFrameReady &&
          !_webAppFirstFrameFailed &&
          _runtime?.activeProject.value?.rendering == SurfaceRendering.webApp) {
        _runtime?.onPageEvent(initialState.event, initialState.data);
      }
      if (notifyCapture) widget.onFirstFrameReady?.call(_controller);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _failVisibleWebApp(
    SurfaceWorkerFatalReason reason, {
    required int? session,
  }) {
    final rt = _runtime;
    if (session == null ||
        rt == null ||
        session != rt.activeSession ||
        session != _webAppLifecycleSession ||
        _webAppFirstFrameFailed) {
      return;
    }
    rt.activeProject.value?.bundlePresentation?.reportFirstFrame(false);
    _webAppFirstFrameTimer?.cancel();
    _webAppFirstFrameTimer = null;
    _webAppFirstFrameReady = false;
    _webAppFirstFrameFailed = true;
    _pendingInitialGameState = null;
    _allowInitialWebAppNavigation = false;
    if (mounted) setState(() {});
    if (_reportedFatalSession != session) {
      _reportedFatalSession = session;
      widget.onWorkerFatal?.call(reason);
    }
    if (rt.activeProject.value?.rendering == SurfaceRendering.projectBundle ||
        rt.activeProject.value?.rendering == SurfaceRendering.webApp) {
      unawaited(rt.closeIfSession(session));
    }
  }
}

bool get _surfaceWebViewHostSupported {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => false,
  };
}

bool _isInternalWebAppDocumentUrl(String source) {
  if (source.isEmpty) return true;
  final uri = Uri.tryParse(source);
  return uri != null &&
      ((uri.scheme == 'about' && uri.path == 'blank') ||
          uri.scheme == 'data' ||
          uri.scheme == 'blob');
}

bool _isEmptyHostDocumentUrl(String source) {
  if (source == 'about:blank') return true;
  try {
    return Uri.tryParse(source)?.data?.contentAsString() ==
        '<!doctype html><html><body></body></html>';
  } catch (_) {
    return false;
  }
}

bool _isSupersededNavigationCancellation(WebResourceError error) {
  if (error.errorCode == -999) return true; // NSURLErrorCancelled.
  final description = error.description.toLowerCase();
  return error.errorType == WebResourceErrorType.unknown &&
      (description.contains('err_aborted') ||
          description.contains('cancelled') ||
          description.contains('canceled'));
}

bool _isSupersededWebAppDocumentUrl(String? source, String? expected) {
  return source != null &&
      expected != null &&
      SurfaceWebAppHost.isDocumentBaseUrl(source) &&
      !SurfaceWebAppHost.matchesDocumentBaseUrl(source, expected);
}

bool _isCurrentWebAppDocumentUrl(String? source, String? expected) {
  return source != null &&
      expected != null &&
      SurfaceWebAppHost.matchesDocumentBaseUrl(source, expected);
}

bool _isControllerLevelWebAppFailure(WebResourceError error) {
  return error.errorType == WebResourceErrorType.webContentProcessTerminated ||
      error.errorType == WebResourceErrorType.webViewInvalidated;
}
