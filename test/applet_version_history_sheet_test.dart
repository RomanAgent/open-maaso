import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/presentation/applet_version_history_sheet.dart';
import 'package:sembast/sembast_memory.dart';

Map<String, Object?> _spec(String content) => {
  'surfaceId': 'history-ui',
  'surfaceKind': 'card',
  'rendering': 'dom',
  'html': '<main>$content</main>',
  'css': '',
  'js': '',
  'manifest': {'actions': <Object?>[], 'events': <Object?>[]},
  'backend': <String, Object?>{},
  'experienceType': 'utility',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentWidget item;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    WebViewPlatform.instance = _FakeWebViewPlatform();
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'history-sheet-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final spec = _spec('V2');
    final first = SurfaceVersionHistory.read(_spec('V1'), title: 'My applet');
    spec['versionHistory'] = first.append(spec, title: 'My applet').toJson();
    item = AgentWidget(
      agentId: 'self',
      title: 'My applet',
      kind: 'surface',
      spec: spec,
      createdAt: DateTime(2026),
      seen: true,
    );
    AppletLocalOwnership.stamp(item);
    item.id = await database.saveAgentWidget(item);
  });
  tearDown(appServices.reset);

  Future<void> flushIO(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        await database.getAllWidgets();
      }
    });
  }

  Future<void> show(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: AppletVersionHistorySheet(
                item: item,
                scopeKey: AppletLocalOwnership.currentScopeKey(),
              ),
            ),
          ),
        ),
      ),
    );
    await flushIO(tester);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'pending draft remains unapplied until the visible apply confirmation',
    (tester) async {
      final draft = SurfaceVersionDraft.create(
        source: _spec('candidate'),
        title: item.title,
        baseFingerprint: surfaceVersionFingerprint(
          item.spec,
          title: item.title,
        ),
      );
      item.spec['pendingVersionDraft'] = draft.toJson();
      await tester.runAsync(
        () => database.updateWidget(item.id!, spec: item.spec),
      );
      await show(tester);
      await tester.tap(
        find.byKey(const ValueKey('applet-version-pending-draft')),
      );
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(database.getAllWidgets))!.single.spec['html'],
        '<main>V2</main>',
      );
      await tester.tap(find.byKey(const ValueKey('applet-version-restore')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('applet-version-restore-confirmation')),
        findsOneWidget,
      );
      expect(
        (await tester.runAsync(database.getAllWidgets))!.single.spec['html'],
        '<main>V2</main>',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('applet-version-confirm')));
        await database.getAllWidgets();
      });
      await tester.pumpAndSettle();
      final saved = (await tester.runAsync(database.getAllWidgets))!.single;
      expect(saved.spec['html'], '<main>candidate</main>');
      expect(saved.spec['pendingVersionDraft'], isNull);
      expect(
        SurfaceVersionHistory.read(
          saved.spec,
          title: saved.title,
        ).current.number,
        3,
      );
    },
  );

  testWidgets(
    'cloud revision can be previewed and restored without renumbering local history',
    (tester) async {
      final source = <String, Object?>{
        'title': item.title,
        'rendering': 'webApp',
        'html': '<main><button id="go">Cloud old</button></main>',
        'css': '',
        'js':
            'document.getElementById("go").onclick=function(){this.textContent="ready";};',
        'manifest': {'events': <Object?>[], 'actions': <Object?>[]},
      };
      final hash = canonicalAgentGameSourceSha256(source);
      item.spec['cloud'] = {
        'gameId': 'ag_cloud',
        'revisionNo': 8,
        'sourceSha256': hash,
        'scopeKey': AppletLocalOwnership.currentScopeKey(),
        'syncState': 'synced',
      };
      await tester.runAsync(
        () => database.updateWidget(item.id!, spec: item.spec),
      );
      appServices.put<AgentGameCloudService>(
        _HistoryCloud(
          database,
          MockClient((request) async {
            final data = request.url.path.endsWith('/revisions')
                ? {
                    'gameId': 'ag_cloud',
                    'clientSurfaceId': 'history-ui',
                    'currentRevisionNo': 8,
                    'publishedRevisionNo': 1,
                    'items': [
                      {
                        'revisionNo': 1,
                        'sourceSha256': hash,
                        'createdAt': '2026-09-22T01:00:00Z',
                      },
                    ],
                  }
                : {
                    'id': 'ag_cloud',
                    'clientSurfaceId': 'history-ui',
                    'revisionNo': 1,
                    'sourceSha256': hash,
                    'experienceType': 'utility',
                    'category': 'tools',
                    'skillInstructions': '',
                    'surface': source,
                  };
            return http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
          }),
        ),
      );
      await show(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('applet-cloud-revision-1')),
        120,
      );
      await tester.tap(find.byKey(const ValueKey('applet-cloud-revision-1')));
      await flushIO(tester);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('applet-version-preview-cloud_1')),
        120,
      );
      final preview = tester.widget<SurfaceWebView>(
        find.byType(SurfaceWebView),
      );
      preview.onFirstFrameReady!(_Controller());
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('applet-version-restore')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('applet-version-confirm')));
        await database.getAllWidgets();
      });
      await tester.pumpAndSettle();
      final saved = (await tester.runAsync(database.getAllWidgets))!.single;
      final history = SurfaceVersionHistory.read(
        saved.spec,
        title: saved.title,
      );
      expect(history.current.number, 3);
      expect(history.current.restoredFromCloudRevisionNo, 1);
      expect(history.current.source['html'], contains('Cloud old'));
      expect(history.versions[1].source['html'], '<main>V2</main>');
    },
  );

  testWidgets('selecting a historical preview never writes saved source', (
    tester,
  ) async {
    final before = jsonEncode(
      (await tester.runAsync(database.getAllWidgets))!.single.toJson(),
    );
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('applet-version-1')));
    await tester.pumpAndSettle();
    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(
      jsonEncode(
        (await tester.runAsync(database.getAllWidgets))!.single.toJson(),
      ),
      before,
    );
    final preview = tester.widget<SurfaceWebView>(find.byType(SurfaceWebView));
    expect(preview.runtime!.activeProject.value!.html, '<main>V1</main>');
    expect(preview.runtime!.activeSurfaceId, startsWith('preview_'));
  });

  testWidgets('restore needs visible confirmation and then appends V3', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('applet-version-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('applet-version-restore')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('applet-version-restore-confirmation')),
      findsOneWidget,
    );
    expect(
      (await tester.runAsync(database.getAllWidgets))!.single.spec['html'],
      '<main>V2</main>',
    );
    await tester.tap(find.byKey(const ValueKey('applet-version-cancel')));
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(database.getAllWidgets))!.single.spec['html'],
      '<main>V2</main>',
    );
    await tester.tap(find.byKey(const ValueKey('applet-version-restore')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('applet-version-confirm')));
      await database.getAllWidgets();
    });
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(database.getAllWidgets))!.single;
    expect(saved.spec['html'], '<main>V1</main>');
    expect(
      SurfaceVersionHistory.read(saved.spec, title: saved.title).current.number,
      3,
    );
    expect(find.byKey(const ValueKey('applet-version-2')), findsOneWidget);
  });

  testWidgets(
    'stale first-frame and fatal callbacks cannot authorize another preview',
    (tester) async {
      final first = SurfaceVersionHistory.read(_spec('V1'), title: item.title);
      final second = {..._spec('V2'), 'rendering': 'webApp'};
      final history = first
          .append(second, title: item.title)
          .append(_spec('V3'), title: item.title);
      item.spec = {
        ...item.spec,
        ..._spec('V3'),
        'versionHistory': history.toJson(),
      };
      await tester.runAsync(
        () => database.updateWidget(item.id!, spec: item.spec),
      );
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('applet-version-1')));
      await tester.pumpAndSettle();
      final old = tester.widget<SurfaceWebView>(find.byType(SurfaceWebView));
      await tester.tap(find.byKey(const ValueKey('applet-version-2')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(
          ValueKey('applet-version-preview-${history.versions[1].id}'),
        ),
        120,
      );
      await tester.pump();
      final current = tester.widget<SurfaceWebView>(
        find.byType(SurfaceWebView),
      );
      final button = find.byKey(const ValueKey('applet-version-restore'));
      expect(tester.widget<AppGlassButton>(button).onPressed, isNull);
      old.onFirstFrameReady!(_Controller());
      await tester.pump();
      expect(tester.widget<AppGlassButton>(button).onPressed, isNull);
      current.onFirstFrameReady!(_Controller());
      await tester.pump();
      expect(tester.widget<AppGlassButton>(button).onPressed, isNotNull);
      old.onWorkerFatal!(SurfaceWorkerFatalReason.runtimeFailed);
      await tester.pump();
      expect(tester.widget<AppGlassButton>(button).onPressed, isNotNull);
    },
  );

  testWidgets(
    'account invalidation immediately removes preview and revokes callbacks',
    (tester) async {
      appServices.put<SecureStorageService>(_Storage());
      appServices.put(AppEnvironmentService());
      final auth = appServices.put(AuthSessionService());
      auth.session.value = MaasoAuthSession(
        accountUuid: 'account-a',
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
      AppletLocalOwnership.stamp(item);
      await tester.runAsync(
        () => database.updateWidget(item.id!, spec: item.spec),
      );
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('applet-version-1')));
      await tester.pumpAndSettle();
      final old = tester.widget<SurfaceWebView>(find.byType(SurfaceWebView));
      auth.session.value = null;
      await tester.pumpAndSettle();
      expect(find.byType(SurfaceWebView), findsNothing);
      expect(
        find.byKey(const ValueKey('applet-version-revoked')),
        findsOneWidget,
      );
      expect(old.runtime!.isVisible.value, isFalse);
      old.onFirstFrameReady!(_Controller());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('applet-version-restore')),
        findsNothing,
      );
    },
  );

  testWidgets('switching previews detaches the previous runtime', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('applet-version-1')));
    await tester.pumpAndSettle();
    final first = tester
        .widget<SurfaceWebView>(find.byType(SurfaceWebView))
        .runtime!;
    await tester.tap(find.byKey(const ValueKey('applet-version-2')));
    await tester.pumpAndSettle();
    final second = tester
        .widget<SurfaceWebView>(find.byType(SurfaceWebView))
        .runtime!;
    expect(identical(first, second), isFalse);
    expect(first.isVisible.value, isFalse);
    expect(second.activeProject.value!.html, '<main>V2</main>');
  });

  testWidgets('history stays scrollable on a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, scale: 2);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Chinese and English version controls have complete localized copy', () {
    for (final key in [
      'widgets.version_history',
      'widgets.version_restore',
      'widgets.version_restore_confirm',
      'widgets.version_conflict',
      'widgets.action_history',
    ]) {
      expect(enUS[key], isNotEmpty);
      expect(zhCH[key], isNotEmpty);
    }
  });
}

class _Controller extends Fake implements WebViewController {}

class _Storage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String? value) async => true;
  @override
  Future<bool> delete(String key) async => true;
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return _FakePlatformWebViewController(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformWebViewWidget(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _FakePlatformNavigationDelegate(params);
  }
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {}

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
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}

class _HistoryCloud extends AgentGameCloudService {
  _HistoryCloud(DBService db, http.Client client)
    : super(
        database: db,
        httpClient: client,
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token',
        accountScope: () => AppletLocalOwnership.currentScopeKey(),
      );
  @override
  Future<void> schedulePrivateSync(AgentWidget widget) async {}
}
