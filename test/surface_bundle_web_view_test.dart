import 'support/project_bundle_install_authority.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/surface_bundle_controls.dart';
import 'package:maaso/src/features/project_build/application/project_applet_control_service.dart';
import 'package:maaso/src/features/project_build/data/project_applet_action_journal.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:sembast/sembast_io.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';

final _loadedDocuments = <String>[];
final _loadedBaseUrls = <String?>[];
final _channels = <String, JavaScriptChannelParams>{};
NavigationRequestCallback? _navigationRequest;
PageEventCallback? _pageStarted;
WebResourceErrorCallback? _webResourceError;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Database db;
  late ProjectBundleInstallationStore store;
  late SurfaceRuntime runtime;
  ProjectAppletControlService? appletControl;
  setUp(() {
    appServices.reset();
    _loadedDocuments.clear();
    _loadedBaseUrls.clear();
    _channels.clear();
    _navigationRequest = null;
    _pageStarted = null;
    _webResourceError = null;
    appletControl = null;
    WebViewPlatform.instance = _FakeWebViewPlatform();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    appServices.reset();
  });
  Future<void> prepare({bool withControl = false}) async {
    dir = await Directory.systemTemp.createTemp('bundle-webview-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/db');
    store = ProjectBundleInstallationStore(
      projectBuildScopeKey: 'test|owner',
      database: db,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'one',
      ),
      applicationSupportRoot: dir,
      isCurrent: () => true,
    );
    final bundle = productionBundleFixture();
    final auth = await testBundlePermit(bundle);
    final installed = await testInstallBundle(
      store,
      bundle,
      expectedScopeKey: store.scopeKey,
      expectedCurrentCandidateDigest: null,
      verificationReport: auth.report,
      permit: auth.permit,
    );
    runtime = SurfaceRuntime();
    if (withControl) {
      appletControl = ProjectAppletControlService(
        scopeKey: store.scopeKey,
        appletScopeKey: 'origin|owner',
        journal: ProjectAppletActionJournal(
          database: db,
          scopeKey: store.scopeKey,
          repositoryScopeKey: 'test|owner',
          processId: 'widget-test',
          isCurrent: () => true,
        ),
        isCurrent: () => true,
        isForeground: () => true,
      );
    }
    await runtime.showInstalledBundle(
      installed,
      permit: auth.permit,
      hostServices: SurfaceBundleHostServices(
        installations: store,
        verifier: auth.verifier,
        appletControl: appletControl,
      ),
    );
  }

  Future<void> cleanup() async {
    await runtime.close();
    await appletControl?.deactivateAndDrain();
    await store.deactivateAndDrain();
    await db.close();
    await dir.delete(recursive: true);
  }

  testWidgets(
    'native confirmation grants control; first touch fences old document without changing the owned native session',
    (tester) async {
      try {
        await tester.runAsync(() => prepare(withControl: true));
        final presentation = runtime.activeProject.value!.bundlePresentation!;
        final session = runtime.activeSession;
        final oldNonce = presentation.nonce;
        final oldJsSession = presentation.sessionId;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SurfaceBundleControls(presentation: presentation),
                  Expanded(child: SurfaceWebView(runtime: runtime)),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(appletControl!.currentGrant('self'), isNull);
        final oldFrame = {
          'nonce': oldNonce,
          'sessionId': oldJsSession,
          'projectId': presentation.controlProjectId,
          'revisionId': presentation.controlRevisionId,
          'candidateDigest': presentation.controlCandidateDigest,
          'id': '1',
          'operation': 'frame',
          'payload': {'ready': true},
        };
        _channels['MaasoProjectBridge']!.onMessageReceived(
          JavaScriptMessage(message: jsonEncode(oldFrame)),
        );
        await tester.pump();
        await tester.pump();
        expect(presentation.canGrantApplet, isTrue);
        await tester.tap(find.byKey(const ValueKey('project-control-grant')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('project-control-confirmation')),
          findsOneWidget,
        );
        expect(appletControl!.currentGrant('self'), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('project-control-purpose')),
          'Open details',
        );
        await tester.tap(find.byKey(const ValueKey('project-control-confirm')));
        await tester.pumpAndSettle();
        final grant = appletControl!.currentGrant('self')!;
        expect(grant.purpose, 'Open details');
        await tester.runAsync(() async {
          await tester.tap(find.byType(SurfaceWebView));
          await presentation.restoreAppletDocument();
        });
        await tester.pump();
        await tester.pump();
        expect(await grant.onRevoked, 'user_takeover');
        expect(appletControl!.currentGrant('self'), isNull);
        expect(runtime.activeSession, session);
        expect(presentation.nonce, isNot(oldNonce));
        expect(presentation.sessionId, isNot(oldJsSession));
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsOneWidget,
        );
        _channels['MaasoProjectBridge']!.onMessageReceived(
          JavaScriptMessage(message: jsonEncode(oldFrame)),
        );
        await tester.pump();
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsOneWidget,
        );
        expect(presentation.canGrantApplet, isFalse);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(cleanup);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'v2 exposes only scoped bridge, blocks navigation, validates frame identity and revokes on failure',
    (tester) async {
      try {
        await tester.runAsync(prepare);
        await tester.pumpWidget(
          MaterialApp(home: SurfaceWebView(runtime: runtime)),
        );
        await tester.pump();
        await tester.pump();
        expect(_channels.keys, unorderedEquals(['MaasoProjectBridge']));
        expect(_loadedDocuments, hasLength(1));
        expect(_loadedBaseUrls.single, contains('.maaso-bundle.invalid/'));
        expect(_pageStarted, isNotNull);
        expect(_webResourceError, isNotNull);
        expect(
          await _navigationRequest!(
            NavigationRequest(url: 'https://example.com', isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
        expect(
          await _navigationRequest!(
            NavigationRequest(url: 'data:text/html,unsafe', isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
        expect(
          await _navigationRequest!(
            NavigationRequest(url: _loadedBaseUrls.single!, isMainFrame: true),
          ),
          NavigationDecision.navigate,
        );
        expect(
          await _navigationRequest!(
            NavigationRequest(url: _loadedBaseUrls.single!, isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsOneWidget,
        );
        final presentation = runtime.activeProject.value!.bundlePresentation!;
        var readyCompleted = false;
        final readyFuture = runtime
            .waitForBundleFirstFrame(runtime.activeSession)
            .then((_) => readyCompleted = true);
        Map<String, Object?> message(bool ready) => {
          'nonce': presentation.nonce,
          'sessionId': presentation.sessionId,
          'projectId': presentation.installed.bundle.manifest.projectId,
          'revisionId': presentation.installed.bundle.manifest.revisionId,
          'candidateDigest': presentation.installed.candidateDigest,
          'id': '1',
          'operation': 'frame',
          'payload': {'ready': ready},
        };
        expect(readyCompleted, isFalse);
        final stale = message(true)..['nonce'] = 'wrong';
        _channels['MaasoProjectBridge']!.onMessageReceived(
          JavaScriptMessage(message: jsonEncode(stale)),
        );
        await tester.pump();
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsOneWidget,
        );
        _channels['MaasoProjectBridge']!.onMessageReceived(
          JavaScriptMessage(message: jsonEncode(message(true))),
        );
        await tester.pump();
        expect(
          find.byKey(SurfaceWebView.webAppFirstFrameCoverKey),
          findsNothing,
        );
        await readyFuture;
        expect(readyCompleted, isTrue);
        _channels['MaasoProjectBridge']!.onMessageReceived(
          JavaScriptMessage(message: jsonEncode(message(false))),
        );
        await tester.pump();
        expect(runtime.isVisible.value, isFalse);
        expect(presentation.isCurrent, isFalse);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(cleanup);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakePlatformWebViewController(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    _channels[params.name] = params;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    _loadedDocuments.add(html);
    _loadedBaseUrls.add(baseUrl);
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {
    _channels.remove(javaScriptChannelName);
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      jsonEncode({
        'controlProtocolVersion': 1,
        'ready': true,
        'projectKind': 'applet',
      });

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    covariant PlatformNavigationDelegate handler,
  ) async {}
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    _navigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    _pageStarted = onPageStarted;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    _webResourceError = onWebResourceError;
  }
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
