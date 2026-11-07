import 'dart:async';
import 'dart:convert';
import 'package:maaso/src/offline/local_edition_policy.dart';
import 'package:maaso/src/offline/local_surface_host.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_data_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:uuid/uuid.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'app_invocation_compatibility.dart';
import 'app_invocation_descriptor.dart';
import 'app_invocation_execution_contract.dart';
import 'app_invocation_execution_service.dart';
import 'app_invocation_store.dart';
import 'app_invocation_web_document.dart';

/// Local, explicitly invoked execution host. No new navigation destination or
/// global player is registered; closing it cannot close the user's original app.
class AppInvocationVisibleHost extends StatefulWidget {
  const AppInvocationVisibleHost._(this._backend);
  final _InvocationBrowserBackend _backend;

  static Future<AppInvocationBackend> open(
    AppInvocationHostRequest request, {
    required DBService database,
    required AppInvocationStore store,
    required SurfaceBundleHostServices bundleServices,
    required bool Function() isForeground,
  }) async {
    if (!request.isCurrent() ||
        !store.isCurrent ||
        !isForeground() ||
        !store.usesDatabase(database.raw)) {
      throw StateError('invocation_host_unavailable');
    }
    final context = appNavigation.context;
    if (context == null || !context.mounted) {
      throw StateError('invocation_host_unavailable');
    }
    final controller = await _createIsolatedController();
    if (!context.mounted ||
        !request.isCurrent() ||
        !store.isCurrent ||
        !isForeground()) {
      await _disposeController(controller);
      throw StateError('invocation_host_retired');
    }
    final _InvocationBrowserBackend backend;
    if (request.pinnedSource.installedBundle != null) {
      backend = _BundleInvocationBackend(
        request,
        controller,
        store,
        isForeground,
        database,
        bundleServices,
      );
    } else if ((request.descriptor.runtimeKind ==
                AppInvocationRuntimeKind.surfaceWebApp ||
            request.descriptor.runtimeKind ==
                AppInvocationRuntimeKind.legacySurface) &&
        !request.descriptor.requiresGameAuthority) {
      backend = _WebInvocationBackend(request, controller, store, isForeground);
    } else {
      await _disposeController(controller);
      throw StateError('invocation_runtime_requires_manual_open');
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AppInvocationVisibleHost._(backend),
    );
    backend.dismiss = () {
      if (route.isActive) navigator.removeRoute(route);
    };
    unawaited(
      navigator.push(route).whenComplete(() {
        if (!backend.closing) backend.cancelFromUser();
      }),
    );
    try {
      // Reading the native network notice is user time, not a browser boot
      // timeout. The web backend starts its bounded timer after consent.
      if (backend is _WebInvocationBackend) {
        await backend.ready.future;
      } else {
        await backend.ready.future.timeout(const Duration(seconds: 25));
      }
      if (!backend.isCurrent) throw StateError('invocation_host_retired');
      return backend;
    } catch (_) {
      await backend.close();
      rethrow;
    }
  }

  @override
  State<AppInvocationVisibleHost> createState() =>
      _AppInvocationVisibleHostState();
}

class _AppInvocationVisibleHostState extends State<AppInvocationVisibleHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        widget._backend.start().then<void>(
          (_) {
            if (!widget._backend.ready.isCompleted) {
              widget._backend.ready.complete();
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!widget._backend.ready.isCompleted) {
              widget._backend.ready.completeError(error, stack);
            }
          },
        ),
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visibility();
  }

  void _visibility() {
    widget._backend.visible =
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false) &&
        (WidgetsBinding.instance.lifecycleState == null ||
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    if (!widget._backend.visible &&
        (widget._backend.ready.isCompleted ||
            widget._backend is _WebInvocationBackend)) {
      widget._backend.fence();
      if (widget._backend is _WebInvocationBackend) {
        unawaited(widget._backend.close().catchError((Object _) {}));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget._backend.visible = false;
    if (!widget._backend.closing) widget._backend.cancelFromUser();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget._backend;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SafeArea(
        child: SizedBox(
          width: 680,
          height: backend.requiresVisibleHost
              ? MediaQuery.sizeOf(context).height * .72
              : 180,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(
                  left: 16,
                  top: 8,
                  right: 8,
                  bottom: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        backend.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'common.close'.tr,
                      onPressed: backend.cancelFromUser,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(child: backend.buildContent()),
            ],
          ),
        ),
      ),
    );
  }
}

Future<WebViewController> _createIsolatedController() async {
  if (kIsWeb) throw StateError('invocation_browser_isolation_unavailable');
  final PlatformWebViewControllerCreationParams parameters;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      parameters = WebKitWebViewControllerCreationParams(
        useNonPersistentDataStore: true,
        javaScriptCanOpenWindowsAutomatically: false,
      );
    case TargetPlatform.android:
      if (!await AndroidWebViewController.supportsInvocationProfiles()) {
        throw StateError('invocation_browser_isolation_unavailable');
      }
      parameters = AndroidWebViewControllerCreationParams(
        invocationProfileName:
            '${kOpenMaasoLocalEdition ? 'maaso_offline' : 'maaso_invocation'}_${const Uuid().v4().replaceAll('-', '')}',
      );
    default:
      throw StateError('invocation_browser_isolation_unavailable');
  }
  final controller = WebViewController.fromPlatformCreationParams(parameters);
  await configureLocalSurfaceController(controller);
  await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
  await controller.platform.setOnPlatformPermissionRequest(
    (request) => request.deny(),
  );
  return controller;
}

Future<void> _disposeController(WebViewController controller) async {
  // No clearCache/global CookieManager calls: these could affect another work.
  if (controller.platform case final AndroidWebViewController android) {
    await android.disposeInvocationProfile();
  }
}

abstract class _InvocationBrowserBackend implements AppInvocationBackend {
  _InvocationBrowserBackend(
    this.request,
    this.controller,
    this.store,
    this.foreground,
  ) : title = request.pinnedSource.title {
    // A route may be retired before its first frame attaches the start waiter.
    unawaited(
      ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final AppInvocationHostRequest request;
  final WebViewController controller;
  final AppInvocationStore store;
  final bool Function() foreground;
  final ready = Completer<void>();
  bool visible = false, live = true, closing = false;
  VoidCallback? dismiss;
  Future<void>? _closeFuture;
  final String title;
  @override
  bool get isCurrent =>
      live && request.isCurrent() && store.isCurrent && foreground();
  @override
  bool get isVisible => visible && foreground();
  @override
  bool get supportsGameAuthority => false;
  @override
  Set<AppInvocationIsolationBoundary> get verifiedBoundaries => {
    AppInvocationIsolationBoundary.sourceReadOnly,
    AppInvocationIsolationBoundary.applicationData,
    AppInvocationIsolationBoundary.browserData,
    AppInvocationIsolationBoundary.externalEffects,
  };
  Future<void> start();
  Widget buildContent();
  void guard() {
    if (!isCurrent || (requiresVisibleHost && !isVisible)) {
      throw StateError('invocation_host_retired');
    }
  }

  @override
  void fence() {
    live = false;
    if (!ready.isCompleted) {
      ready.completeError(StateError('invocation_host_retired'));
    }
  }

  void cancelFromUser() {
    fence();
    if (store.isCurrent) {
      unawaited(
        store.cancel(request.run.invocationId).catchError((Object _) {}),
      );
    }
    unawaited(close().catchError((Object _) {}));
  }

  Future<void> closeRuntime();
  @override
  Future<void> close() {
    fence();
    closing = true;
    return _closeFuture ??= () async {
      try {
        await closeRuntime();
      } finally {
        try {
          await controller
              .loadHtmlString(
                '<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src \'none\'">',
              )
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
        dismiss?.call();
        await _disposeController(controller);
      }
    }();
  }
}

final class _WebInvocationApproval {
  _WebInvocationApproval(this.title, this.message, {this.arguments});
  final String title, message;
  final String? arguments;
  final completion = Completer<bool>();
}

/// A real browser document with no native JS channel. The native side owns
/// consent, source identity, action schema validation, request IDs and expiry;
/// everything returned by the authored document remains untrusted data.
final class _WebInvocationBackend extends _InvocationBrowserBackend
    implements
        AppInvocationExternalEffectsConsentBackend,
        AppInvocationActionAuthorizationBackend,
        AppInvocationUserVisibleResultBackend {
  _WebInvocationBackend(
    super.request,
    super.controller,
    super.store,
    super.foreground,
  ) {
    // Preparation can be waiting for human consent before the conversation
    // runner owns a cancellation subscription. Account/turn retirement must
    // settle that wait too; retained results follow owner lifetime instead.
    _ownerWatch = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final current = _retained
          ? request.isOwnerCurrent()
          : request.isCurrent();
      if (!current || !foreground()) {
        fence();
        unawaited(close().catchError((Object _) {}));
      }
    });
  }

  final _revision = ValueNotifier<int>(0);
  final _observations = <String, int>{};
  final _baseUrl =
      'https://${const Uuid().v4().replaceAll('-', '')}.maaso-invocation.invalid/';
  _WebInvocationApproval? _approval;
  bool _networkConsent = false, _retained = false, _documentStarted = false;
  bool _operational = false;
  Timer? _ownerWatch;
  bool Function()? _invocationAuthorization;

  @override
  void bindInvocationAuthorization(bool Function() isAuthorized) {
    if (_invocationAuthorization != null) {
      throw StateError('invocation_authorization_already_bound');
    }
    _invocationAuthorization = isAuthorized;
  }

  void _guardActionAuthorization() {
    guard();
    if (_invocationAuthorization?.call() != true) {
      throw StateError('invocation_authorization_expired');
    }
  }

  @override
  AppInvocationRuntimeProtocol get protocol =>
      AppInvocationRuntimeProtocol.correlatedSurface;
  @override
  bool get requiresVisibleHost => true;
  @override
  bool get externalEffectsAllowedByUser => _networkConsent;
  @override
  Set<AppInvocationIsolationBoundary> get verifiedBoundaries => {
    AppInvocationIsolationBoundary.sourceReadOnly,
    AppInvocationIsolationBoundary.applicationData,
    AppInvocationIsolationBoundary.browserData,
  };

  bool get _zh =>
      appNavigation.context != null &&
      Localizations.localeOf(appNavigation.context!).languageCode == 'zh';

  Future<bool> _confirm(_WebInvocationApproval approval) async {
    guard();
    if (_approval != null) throw StateError('invocation_confirmation_busy');
    _approval = approval;
    _revision.value++;
    final allowed = await approval.completion.future;
    if (identical(_approval, approval)) {
      _approval = null;
      _revision.value++;
    }
    guard();
    return allowed;
  }

  @override
  Future<void> start() async {
    final allowed = await _confirm(
      _WebInvocationApproval(
        _zh ? '运行这个作品' : 'Run this work',
        _zh
            ? '作品将在独立临时会话中运行，不使用已安装作品的数据。它可以加载联网资源、访问外部服务；传给它的内容也可能发送到这些服务。'
            : 'This work runs in a separate temporary session without installed '
                  'work data. It may load online resources and contact external '
                  'services, including sending content you give it.',
      ),
    );
    if (!allowed) throw StateError('invocation_user_cancelled');
    _networkConsent = true;
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (navigation) {
          if (!navigation.isMainFrame) {
            return navigation.url.startsWith('maaso-surface:')
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          }
          final url = Uri.tryParse(navigation.url);
          if (url?.replace(fragment: '') ==
              Uri.parse(_baseUrl).replace(fragment: '')) {
            return NavigationDecision.navigate;
          }
          fence();
          return NavigationDecision.prevent;
        },
        onPageStarted: (url) {
          // Android can omit shouldOverrideUrlLoading for POST. A new main
          // document must never inherit the prepared invocation's authority.
          if (Uri.tryParse(url)?.replace(fragment: '') !=
                  Uri.parse(_baseUrl).replace(fragment: '') ||
              _documentStarted) {
            fence();
          }
          _documentStarted = true;
        },
      ),
    );
    guard();
    await controller.loadHtmlString(
      localSurfaceDocument(
        AppInvocationWebDocument.build(
          source: request.pinnedSource.surface!,
          descriptor: request.descriptor,
        ),
        const {},
        enableStorage: false,
      ),
      baseUrl: _baseUrl,
    );
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 25)) {
      guard();
      try {
        final snapshot = _object(
          await _read('describe()', maximumBytes: 65536),
        );
        if (snapshot['errorCode'] != null) {
          throw StateError('invocation_runtime_dependency_unavailable');
        }
        if (snapshot['ready'] == true) {
          _operational = true;
          return;
        }
      } on StateError {
        rethrow;
      } catch (_) {
        // A newly mounted WebView has not necessarily evaluated its bootstrap.
        // The bounded boot deadline still applies to every retry.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('invocation_web_boot_timeout');
  }

  static String _json(Object? value) => jsonEncode(
    value,
  ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');

  Future<Object> _read(String operation, {required int maximumBytes}) async {
    guard();
    final result = await controller
        .runJavaScriptReturningResult(
          '(()=>{const value=window.__maasoInvocationHost.$operation;'
          'if(typeof value!=="string"||value.length>$maximumBytes)'
          'throw Error("invocation_response_limit");return value;})()',
        )
        .timeout(const Duration(seconds: 3));
    guard();
    if (result.toString().length > maximumBytes * 2 + 2) {
      throw const FormatException('invocation_response_limit');
    }
    return result;
  }

  @override
  Future<Map<String, Object?>> describe() async {
    guard();
    if (!_operational) throw StateError('invocation_web_unavailable');
    final snapshot = _object(await _read('describe()', maximumBytes: 65536));
    final observationId = const Uuid().v4();
    _observations[observationId] = snapshot['stateVersion']! as int;
    while (_observations.length > 16) {
      _observations.remove(_observations.keys.first);
    }
    return {...snapshot, 'observationId': observationId};
  }

  @override
  Future<AppInvocationBackendResult> invoke(
    String actionId,
    Map<String, Object?> arguments, {
    required String requestId,
    required String observationId,
    required int expectedStateVersion,
    required List<AppInvocationInputImage> inputImages,
  }) async {
    _guardActionAuthorization();
    if (!_operational || _observations[observationId] != expectedStateVersion) {
      throw StateError('invocation_observation_stale');
    }
    final allowed = await _confirm(
      _WebInvocationApproval(
        _zh ? '执行这次操作？' : 'Allow this operation?',
        _zh
            ? '将这些参数交给「$title」执行。作品可能访问外部服务。'
            : 'Pass these arguments to “$title”. The work may contact external services.',
        arguments: const JsonEncoder.withIndent('  ').convert(arguments),
      ),
    );
    if (!allowed) {
      return AppInvocationBackendResult(
        status: AppInvocationActionStatus.cancelled,
        stateVersion: expectedStateVersion,
        errorCode: 'user_declined_action',
      );
    }
    _guardActionAuthorization();
    final command = {
      'requestId': requestId,
      'actionId': actionId,
      'args': arguments,
      'expectedStateVersion': expectedStateVersion,
      'inputImages': [
        for (final input in inputImages)
          {
            'id': input.id,
            'mime': input.mime,
            'base64': base64Encode(input.bytes),
          },
      ],
    };
    await controller
        .runJavaScript(
          'window.__maasoInvocationHost.dispatch(${_json(command)});',
        )
        .timeout(const Duration(seconds: 3));
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 12)) {
      final result = await receipt(requestId);
      if (result != null) return result;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('invocation_web_action_timeout');
  }

  @override
  Future<AppInvocationBackendResult?> receipt(String requestId) async {
    final raw = await _read(
      'receipt(${_json(requestId)})',
      maximumBytes: 70 * 1024 * 1024,
    );
    Object? decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded == null) return null;
    if (decoded is! Map || decoded['requestId'] != requestId) {
      throw const FormatException('invocation_receipt_mismatch');
    }
    final outputs = decoded['outputs'] ?? const [];
    if (outputs is! List || outputs.length > appInvocationMaximumImages) {
      throw const FormatException('invocation_output_invalid');
    }
    return AppInvocationBackendResult(
      status: AppInvocationActionStatus.values.byName(
        decoded['status'] as String,
      ),
      stateVersion: decoded['stateVersion'] as int,
      result: decoded['result'],
      errorCode: decoded['errorCode'] as String?,
      outputs: [
        for (final value in outputs)
          AppInvocationProducedImage(
            producerOutputKey: (value as Map)['producerOutputKey'] as String,
            mime: value['mime'] as String,
            bytes: Uint8List.fromList(base64Decode(value['base64'] as String)),
          ),
      ],
    );
  }

  @override
  void fence() {
    super.fence();
    _operational = false;
    final approval = _approval;
    if (approval != null && !approval.completion.isCompleted) {
      approval.completion.complete(false);
    }
    if (_retained) {
      _retained = false;
      unawaited(close().catchError((Object _) {}));
    }
  }

  @override
  Future<void> releaseCompletedViewToUser() async {
    if (!request.isOwnerCurrent() || !foreground() || !isVisible || closing) {
      throw StateError('invocation_host_retired');
    }
    await controller
        .runJavaScript('window.__maasoInvocationHost.release();')
        .timeout(const Duration(seconds: 3));
    if (!request.isOwnerCurrent() || !foreground() || closing) {
      throw StateError('invocation_host_retired');
    }
    _retained = true;
    _revision.value++;
  }

  @override
  void cancelFromUser() {
    if (_retained) {
      unawaited(close().catchError((Object _) {}));
    } else {
      super.cancelFromUser();
    }
  }

  @override
  Future<void> closeRuntime() async {
    _ownerWatch?.cancel();
    _ownerWatch = null;
    _retained = false;
    try {
      await controller
          .runJavaScript('window.__maasoInvocationHost?.close();')
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  @override
  Widget buildContent() => ValueListenableBuilder<int>(
    valueListenable: _revision,
    builder: (context, _, _) {
      final approval = _approval;
      return Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            excluding: !_retained,
            child: IgnorePointer(
              ignoring: !_retained,
              child: WebViewWidget(controller: controller),
            ),
          ),
          if (approval != null)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      approval.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(approval.message),
                    if (approval.arguments != null) ...[
                      const SizedBox(height: 16),
                      SelectableText(approval.arguments!),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: () {
                            if (!approval.completion.isCompleted) {
                              approval.completion.complete(false);
                            }
                          },
                          child: Text(_zh ? '取消' : 'Cancel'),
                        ),
                        FilledButton(
                          onPressed: () {
                            if (!approval.completion.isCompleted) {
                              approval.completion.complete(true);
                            }
                          },
                          child: Text(_zh ? '允许' : 'Allow'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

final class _BundleInvocationBackend extends _InvocationBrowserBackend {
  _BundleInvocationBackend(
    super.request,
    super.controller,
    super.store,
    super.foreground,
    this.database,
    this.originalServices,
  );
  final DBService database;
  final SurfaceBundleHostServices originalServices;
  final SurfaceRuntime runtime = SurfaceRuntime();
  ProjectAppletControlService? control;
  ProjectAppletGrant? appletGrant;
  SurfacePlayService? play;
  SurfacePlayGrant? playGrant;
  final Map<String, SurfacePlayObservation> observations = {};
  bool get game => request.descriptor.requiresGameAuthority;
  bool get _ownerCurrent => super.isCurrent;
  @override
  bool get requiresVisibleHost => true;
  @override
  bool get supportsGameAuthority => game;
  @override
  AppInvocationRuntimeProtocol get protocol => game
      ? AppInvocationRuntimeProtocol.trustedGameControl
      : AppInvocationRuntimeProtocol.projectBundleControl;
  @override
  Set<AppInvocationIsolationBoundary> get verifiedBoundaries => {
    ...super.verifiedBoundaries,
    if (game) AppInvocationIsolationBoundary.gameState,
  };
  @override
  bool get isCurrent =>
      super.isCurrent &&
      (appletGrant == null || appletGrant!.isCurrent) &&
      (playGrant == null ||
          play?.activeSession?.grantIsCurrent(playGrant!) == true);
  @override
  Future<void> start() async {
    guard();
    final installed = request.pinnedSource.installedBundle!;
    final permit = await originalServices.verifier.verifyReport(
      installed.bundle,
      installed.verificationReport,
    );
    guard();
    final creatorScope =
        originalServices.installations.projectBuildScopeKey ?? store.scopeKey;
    final dataContract = ProjectBundleDataContract.fromProject(
      installed.bundle.project,
    );
    final data = store.applicationDataPort(
      request.run.invocationId,
      canContinue: () => _ownerCurrent,
      validate: dataContract?.validateData,
    );
    if (game) {
      final namespace =
          'invocation:${sha256.convert(utf8.encode(jsonEncode([store.scopeKey, request.run.invocationId])))}';
      play = SurfacePlayService(
        scopeKey: namespace,
        projectBuildScopeKey: creatorScope,
        persistence: SurfacePlayStore(
          database: database,
          scopeKey: namespace,
          projectBuildScopeKey: creatorScope,
          isCurrent: () => _ownerCurrent,
        ),
        isCurrent: () => _ownerCurrent,
        authorizeAgentControl: (_, _) async => _ownerCurrent && isVisible,
      );
    } else {
      control = ProjectAppletControlService(
        scopeKey: installed.scopeKey,
        appletScopeKey: store.scopeKey,
        journal: ProjectAppletActionJournal(
          database: database.raw,
          scopeKey:
              '${installed.scopeKey}|invocation:${request.run.invocationId}',
          repositoryScopeKey: creatorScope,
          processId: store.processId,
          isCurrent: () => _ownerCurrent,
        ),
        isCurrent: () => _ownerCurrent,
        isForeground: () => isVisible,
      );
    }
    final services = SurfaceBundleHostServices(
      installations: originalServices.installations,
      verifier: originalServices.verifier,
      agentId: 'self',
      appletControl: control,
      invocationData: data,
      invocationPlayService: play,
    );
    final session = await runtime.showInstalledBundle(
      installed,
      permit: permit,
      hostServices: services,
      canContinue: () => _ownerCurrent && isVisible,
    );
    await runtime.waitForBundleFirstFrame(session);
    guard();
    if (game) {
      playGrant = await play!.activeSession!.grantAgentControl();
    } else {
      appletGrant = await control!.grantFromNative(
        runtime.activeProject.value!.bundlePresentation!,
        purpose: 'Use the selected app in this isolated chat invocation.',
      );
    }
    guard();
  }

  @override
  Future<Map<String, Object?>> describe() async {
    guard();
    if (game) {
      final view = play!.activeSession!.observe(playGrant!);
      observations[view.observationId] = view;
      while (observations.length > 16) {
        observations.remove(observations.keys.first);
      }
      return {
        'ready': true,
        'actions': request.descriptor.actions
            .where(
              (action) =>
                  action.sourceContract['roles'] is List &&
                  (action.sourceContract['roles']! as List).contains(
                    playGrant!.seatId,
                  ),
            )
            .map((action) => action.name)
            .toList(),
        'observationId': view.observationId,
        'stateVersion': view.decisionRevision,
        'state': {
          'allowedView': view.allowedView,
          'legalActions': view.legalActions,
        },
      };
    }
    final view = await control!.observe(appletGrant!);
    final described = control!.describe(appletGrant!);
    final actions =
        (described['projectDescription']! as Map)['actions']! as List;
    return {
      'ready': view['ready'],
      'actions': actions.map((action) => (action as Map)['id']).toList(),
      'observationId': view['observationId'],
      'stateVersion': view['stateVersion'],
      'state': view['visibleState'],
    };
  }

  @override
  Future<AppInvocationBackendResult> invoke(
    String actionId,
    Map<String, Object?> arguments, {
    required String requestId,
    required String observationId,
    required int expectedStateVersion,
    required List<AppInvocationInputImage> inputImages,
  }) async {
    guard();
    if (inputImages.isNotEmpty) {
      throw StateError('invocation_bundle_image_input_unavailable');
    }
    if (!game) {
      return _appletResult(
        await control!.act(
          appletGrant!,
          requestId: requestId,
          observationId: observationId,
          actionId: actionId,
          args: arguments,
          expectedStateVersion: expectedStateVersion,
          canContinue: () => _ownerCurrent,
        ),
      );
    }
    final view = observations[observationId];
    if (view == null || view.decisionRevision != expectedStateVersion) {
      throw StateError('invocation_observation_stale');
    }
    final matches = view.legalActions.where(
      (action) =>
          action['actionId'] == actionId &&
          const ProjectJsonCanonicalizer().canonicalize(action['args']) ==
              const ProjectJsonCanonicalizer().canonicalize(arguments),
    );
    if (matches.length != 1) {
      throw StateError('invocation_legal_action_required');
    }
    return _gameResult(
      await play!.activeSession!.submit(
        playGrant!,
        view.commandFor(matches.single, requestId: requestId),
      ),
    );
  }

  AppInvocationBackendResult _appletResult(Map<String, Object?> receipt) =>
      AppInvocationBackendResult(
        status: switch (receipt['status']) {
          'applied' => AppInvocationActionStatus.completed,
          'failed' || 'rejected' => AppInvocationActionStatus.failed,
          _ => AppInvocationActionStatus.outcomeUnknown,
        },
        stateVersion: receipt['stateVersion'] is int
            ? receipt['stateVersion']! as int
            : 0,
        result: receipt['result'],
        errorCode: receipt['status'] == 'applied'
            ? null
            : 'applet_action_unconfirmed',
      );
  AppInvocationBackendResult _gameResult(SurfacePlayReceipt receipt) =>
      AppInvocationBackendResult(
        status: switch (receipt.status) {
          SurfacePlayReceiptStatus.applied ||
          SurfacePlayReceiptStatus.duplicate =>
            AppInvocationActionStatus.completed,
          SurfacePlayReceiptStatus.rejected => AppInvocationActionStatus.failed,
          _ => AppInvocationActionStatus.outcomeUnknown,
        },
        stateVersion: receipt.afterRevision,
        result: receipt.toJson(),
        errorCode: receipt.errorCode.isEmpty ? null : 'game_action_rejected',
      );
  @override
  Future<AppInvocationBackendResult?> receipt(String requestId) async {
    guard();
    if (!game) {
      final value = await control!.receipt(appletGrant!, requestId);
      return value['status'] == 'not_found' ? null : _appletResult(value);
    }
    final value = await play!.activeSession!.receipt(playGrant!, requestId);
    return value == null ? null : _gameResult(value);
  }

  @override
  Future<void> closeRuntime() async {
    await runtime.close();
    await control?.deactivateAndDrain();
    await play?.deactivateAndDrain();
    runtime.onClose();
  }

  @override
  Widget buildContent() =>
      SurfaceWebView(runtime: runtime, controller: controller);
}

Map<String, Object?> _object(Object? raw) {
  Object? value = raw;
  for (var i = 0; i < 2 && value is String; i++) {
    value = jsonDecode(value);
  }
  if (value is! Map) throw const FormatException('invocation_bridge_object');
  return Map<String, Object?>.from(value);
}
