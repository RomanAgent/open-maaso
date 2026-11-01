import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_visible_host.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/app_invocation_recovery_fixture.dart';

late _Controller _controller;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InvocationRecoveryFixture fixture;
  late Directory temporary;
  late SurfaceBundleHostServices services;
  AppInvocationBackend? backend;
  Object? openError;
  WidgetTester? activeTester;
  var turnCurrent = true;
  var actionAuthorized = true;
  var compactLayout = false;

  setUp(() async {
    appServices.reset();
    turnCurrent = true;
    actionAuthorized = true;
    compactLayout = false;
    backend = null;
    openError = null;
    WebViewPlatform.instance = _Platform();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final method in [
      'nonPersistent',
      'setMediaTypesRequiringUserActionForPlayback',
      'setAllowsInlineMediaPlayback',
    ]) {
      messenger.setMockMessageHandler(
        'dev.flutter.pigeon.webview_flutter_wkwebview.WKWebViewConfiguration.$method',
        (_) async => const StandardMessageCodec().encodeMessage([null]),
      );
    }
    fixture = await InvocationRecoveryFixture.create(
      completed: false,
      action: false,
    );
    temporary = Directory.systemTemp.createTempSync('invocation-visible-host-');
    services = SurfaceBundleHostServices(
      installations: ProjectBundleInstallationStore(
        database: fixture.database.raw,
        accountScope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'owner',
        ),
        applicationSupportRoot: temporary,
        isCurrent: () => fixture.current,
      ),
      verifier: ProjectBundleVerificationService(
        trustedKeys: {},
        isCurrent: () => fixture.current,
      ),
    );
  });

  tearDown(() async {
    await activeTester!.runAsync(fixture.close);
    temporary.deleteSync(recursive: true);
    debugDefaultTargetPlatformOverride = null;
    appServices.reset();
  });

  Future<void> mount(WidgetTester tester) async {
    activeTester = tester;
    final resolved = (await tester.runAsync(
      () => fixture.catalog.revalidateStoredSelection(fixture.snapshot),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        builder: (context, child) => compactLayout
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  viewInsets: const EdgeInsets.only(bottom: 220),
                ),
                child: child!,
              )
            : child!,
        home: const Scaffold(body: Text('Home')),
      ),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppInvocationVisibleHost.open(
      AppInvocationHostRequest(
        run: fixture.run,
        descriptor: resolved.descriptor!,
        pinnedSource: resolved.executableSource!,
        inputImages: const [],
        isCurrent: () => fixture.current && turnCurrent,
        isOwnerCurrent: () => fixture.current,
      ),
      database: fixture.database,
      store: fixture.journal,
      bundleServices: services,
      isForeground: () => true,
    ).then<void>(
      (value) => backend = value,
      onError: (Object error, StackTrace _) => openError = error,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> allow(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    if (backend != null) {
      (backend as AppInvocationActionAuthorizationBackend)
          .bindInvocationAuthorization(() => actionAuthorized);
    }
  }

  testWidgets('cancel before network consent loads no authored document', (
    tester,
  ) async {
    await mount(tester);
    expect(_controller.documents, isEmpty);
    expect(_controller.channels, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(openError, isA<StateError>());
    expect(
      _controller.documents.where(
        (value) => value.contains('data-maaso-invocation'),
      ),
      isEmpty,
    );
    expect(backend, isNull);
  });

  testWidgets('consent loads DOM, denied action never dispatches', (
    tester,
  ) async {
    await mount(tester);
    await allow(tester);
    expect(openError, isNull);
    expect(backend, isNotNull);
    expect(_controller.documents.single, contains('data-maaso-invocation'));
    expect(_controller.baseUrl, contains('.maaso-invocation.invalid/'));
    expect(_controller.channels, isEmpty);
    final state = await backend!.describe();
    AppInvocationBackendResult? result;
    backend!
        .invoke(
          'any.function',
          {},
          requestId: 'request-denied',
          observationId: state['observationId'] as String,
          expectedStateVersion: 0,
          inputImages: const [],
        )
        .then((value) => result = value);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(result!.status, AppInvocationActionStatus.cancelled);
    expect(
      _controller.scripts.where((script) => script.contains('.dispatch(')),
      isEmpty,
    );
    await backend!.close();
    await tester.pump();
  });

  testWidgets('retiring the owner settles initial consent and closes', (
    tester,
  ) async {
    await mount(tester);
    fixture.current = false;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(openError, isA<StateError>());
    expect(
      _controller.documents.where(
        (value) => value.contains('data-maaso-invocation'),
      ),
      isEmpty,
    );
    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
  });

  testWidgets('stopping a turn during action consent prevents dispatch', (
    tester,
  ) async {
    await mount(tester);
    await allow(tester);
    final state = await backend!.describe();
    Object? actionError;
    backend!
        .invoke(
          'any.function',
          {},
          requestId: 'request-stop',
          observationId: state['observationId'] as String,
          expectedStateVersion: 0,
          inputImages: const [],
        )
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace _) => actionError = error,
        );
    await tester.pump();
    turnCurrent = false;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(actionError, isA<StateError>());
    expect(
      _controller.scripts.where((script) => script.contains('.dispatch(')),
      isEmpty,
    );
    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
  });

  testWidgets('authorization expiring during consent prevents dispatch', (
    tester,
  ) async {
    await mount(tester);
    await allow(tester);
    final state = await backend!.describe();
    Object? actionError;
    backend!
        .invoke(
          'any.function',
          {},
          requestId: 'request-expired',
          observationId: state['observationId'] as String,
          expectedStateVersion: 0,
          inputImages: const [],
        )
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace _) => actionError = error,
        );
    await tester.pump();
    actionAuthorized = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await tester.pump();
    expect(actionError, isA<StateError>());
    expect(
      _controller.scripts.where((script) => script.contains('.dispatch(')),
      isEmpty,
    );
    await backend!.close();
    await tester.pump();
  });

  testWidgets(
    'completed view survives turn end but closes on owner retirement',
    (tester) async {
      await mount(tester);
      await allow(tester);
      backend!.fence();
      await (backend as AppInvocationUserVisibleResultBackend)
          .releaseCompletedViewToUser();
      turnCurrent = false;
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Dialog), findsOneWidget);
      expect(
        _controller.scripts,
        contains('window.__maasoInvocationHost.release();'),
      );
      fixture.current = false;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'consent stays scrollable with narrow layout, large text and keyboard',
    (tester) async {
      compactLayout = true;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      expect(tester.takeException(), isNull);
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(openError, isA<StateError>());
      expect(
        _controller.documents.where(
          (value) => value.contains('data-maaso-invocation'),
        ),
        isEmpty,
      );
    },
  );
}

class _Platform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _controller = _Controller(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Navigation(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  final documents = <String>[];
  final scripts = <String>[];
  final channels = <String>[];
  String? baseUrl;
  _Navigation? navigation;
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    documents.add(html);
    this.baseUrl = baseUrl;
    if (baseUrl != null) navigation?.started?.call(baseUrl);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => navigation = handler as _Navigation;
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channels.add(params.name);
  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      jsonEncode({
        'ready': true,
        'actions': ['any.function'],
        'stateVersion': 0,
      });
}

class _Navigation extends PlatformNavigationDelegate {
  _Navigation(super.params) : super.implementation();
  PageEventCallback? started;
  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      started = onPageStarted;
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
