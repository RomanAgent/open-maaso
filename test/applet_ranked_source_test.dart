import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'official likes use allowlisted authenticated durable endpoints',
    () async {
      final requests = <http.Request>[];
      final (catalog, _) = await _catalog((request) async {
        requests.add(request);
        return _ok({
          'id': 'ble_yoturetoys_projector',
          'viewCount': 0,
          'likeCount': request.method == 'POST' ? 1 : 0,
          'shareCount': 0,
          'commentCount': 0,
          'likedByMe': request.method == 'POST',
        });
      });
      final context = catalog.requestContextKey;
      await catalog.officialEngagement(
        'ble_yoturetoys_projector',
        expectedContextKey: context,
      );
      final liked = await catalog.setOfficialLiked(
        'ble_yoturetoys_projector',
        true,
        expectedContextKey: context,
      );
      expect(liked.likeCount, 1);
      expect(liked.likedByMe, isTrue);
      expect(
        requests.first.url.path,
        '/v1/official-applets/ble_yoturetoys_projector/engagement',
      );
      expect(
        requests.last.url.path,
        '/v1/official-applets/ble_yoturetoys_projector/likes/status',
      );
      expect(jsonDecode(requests.last.body), {'liked': true});
      expect(requests.last.headers['authorization'], 'Bearer token');
      await expectLater(
        catalog.setOfficialLiked('unknown', true, expectedContextKey: context),
        throwsFormatException,
      );
    },
  );

  test('ranked discovery sends category and global rating sort', () async {
    late http.Request request;
    final (catalog, _) = await _catalog((incoming) async {
      request = incoming;
      return _ok({
        'schemaVersion': 1,
        'items': [],
        'quota': {'used': 0, 'limit': 5},
      });
    });
    await catalog.searchRanked(query: '', category: 'travel');
    expect(request.url.queryParameters['sort'], 'rating');
    expect(request.url.queryParameters['category'], 'travel');
    expect(request.url.queryParameters['include_skill'], 'true');
    expect(request.headers['authorization'], 'Bearer token');
    await expectLater(
      catalog.searchRanked(query: '', category: '../travel'),
      throwsFormatException,
    );
  });

  test(
    'source verifies digest and immutable content; creates fullscreen project',
    () {
      final raw = _document();
      final source = AppletSourceDocument.fromJson(raw);
      final project = SurfaceProject.fromJson(
        source.toProjectJson(instanceId: 'instance-1'),
      );
      expect(project.id, 'instance-1');
      expect(project.kind, SurfaceKind.fullscreen);
      expect(project.category, 'travel');
      expect(() => source.surface['html'] = 'tampered', throwsUnsupportedError);
      (raw['surface'] as Map)['html'] = '<p>tampered</p>';
      expect(() => AppletSourceDocument.fromJson(raw), throwsFormatException);
    },
  );

  test(
    'source fetch binds account context and rejects cross-target response',
    () async {
      final gate = Completer<http.Response>();
      final (catalog, auth) = await _catalog((_) => gate.future);
      final pending = catalog.source(
        'ag_trip',
        expectedContextKey: catalog.requestContextKey,
      );
      await Future<void>.delayed(Duration.zero);
      auth.session.value = _session('other');
      gate.complete(_ok(_document()));
      await expectLater(pending, throwsStateError);
    },
  );

  test(
    'owned restore preserves ID and cloud revision with one local insert',
    () async {
      var reads = 0;
      final (catalog, _) = await _catalog((request) async {
        reads++;
        expect(request.url.path, '/v1/agent-games/ag_trip/source');
        return _ok(_document());
      });
      appServices.put<AppletCatalogService>(catalog);
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'restore_applet.db',
      );
      final scope = AppletLocalOwnership.currentScopeKey();
      final cloud = AgentGameCloudService(
        database: db,
        accountScope: () => scope,
      );
      final item = AppletInventoryItem(
        id: 'ag_trip',
        clientSurfaceId: 'surface_trip',
        title: 'Trip',
        type: AppletCatalogType.applet,
        summary: 'Travel planner',
        published: false,
        updatedAt: DateTime.utc(2026),
      );
      final first = await cloud.restoreOwned(item, expectedScopeKey: scope);
      final second = await cloud.restoreOwned(item, expectedScopeKey: scope);
      expect(first.id, second.id);
      expect(reads, 1);
      expect((await db.getAllWidgets()).length, 1);
      expect(first.spec['surfaceId'], 'surface_trip');
      expect(
        AgentGameCloudMetadata.fromSpec(first.spec['cloud']).revisionNo,
        2,
      );
      expect(AppletLocalOwnership.storedScopeKey(first), scope);
    },
  );

  test(
    'publication exposes automatic reviewing then exact-revision publishing',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'publish_phases.db',
      );
      final phases = <AgentGamePublicationPhase>[];
      final document = AppletSourceDocument.fromJson(_document());
      final widget = AgentWidget(
        agentId: 'self',
        title: 'Trip',
        kind: 'surface',
        spec: document.toProjectJson(),
        createdAt: DateTime.utc(2026),
      );
      AppletLocalOwnership.stamp(widget, scopeKey: 'test-scope');
      await db.saveAgentWidget(widget);
      var hash = '';
      final cloud = AgentGameCloudService(
        database: db,
        accessToken: () async => 'token',
        baseUri: () => Uri.parse('https://example.test/'),
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          final published = request.url.path.endsWith('/publish');
          if (!published) {
            hash = canonicalAgentGameSourceSha256(
              (body['surface'] as Map).cast<String, Object?>(),
            );
            expect((body['surface'] as Map)['category'], 'travel');
            expect(phases, [AgentGamePublicationPhase.reviewing]);
          } else {
            expect(phases.last, AgentGamePublicationPhase.publishing);
            expect(body['sourceSha256'], hash);
          }
          return _ok({
            'gameId': 'ag_trip',
            'experienceType': 'utility',
            'clientSurfaceId': 'surface_trip',
            'revisionNo': 1,
            'sourceSha256': hash,
            'published': published,
            if (published) 'shareUrl': 'https://example.test/g/trip',
          });
        }),
      );
      final result = await cloud.publish(widget, onPhase: phases.add);
      expect(phases, [
        AgentGamePublicationPhase.reviewing,
        AgentGamePublicationPhase.publishing,
      ]);
      expect(result.syncState, AgentGameSyncState.published);
    },
  );
}

Map<String, Object?> _document() {
  final surface = <String, Object?>{
    'title': 'Trip',
    'rendering': 'webApp',
    'html': '<main><h1>Trip</h1><button id="plan">Plan</button></main>',
    'css': 'body{margin:0}',
    'js': 'document.getElementById("plan").onclick=function(){};',
    'manifest': {'actions': [], 'events': [], 'instructions': ''},
    'category': 'travel',
    'skillInstructions': 'Present the itinerary for the requested destination.',
  };
  return {
    'id': 'ag_trip',
    'clientSurfaceId': 'surface_trip',
    'revisionNo': 2,
    'sourceSha256': canonicalAgentGameSourceSha256(surface),
    'experienceType': 'utility',
    'category': 'travel',
    'skillInstructions': surface['skillInstructions'],
    'surface': surface,
    'cloud': {'published': false, 'hasPublished': false, 'shareUrl': ''},
  };
}

Future<(AppletCatalogService, AuthSessionService)> _catalog(
  Future<http.Response> Function(http.Request) respond,
) async {
  appServices.put<SecureStorageService>(_Storage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient(
        (_) async => throw StateError('unexpected refresh'),
      ),
    ),
  );
  await auth.init();
  auth.session.value = _session('owner');
  final locale = appServices.put(LocaleConfigService());
  await locale.setLocale(AppLocale.en);
  return (
    AppletCatalogService(
      httpClient: MockClient(respond),
      environment: environment,
      auth: auth,
      locale: locale,
    ),
    auth,
  );
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);
http.Response _ok(Object data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);

class _Storage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
