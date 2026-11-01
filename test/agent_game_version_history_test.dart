import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:sembast/sembast_memory.dart';

Map<String, Object?> _source(String text) => {
  'title': 'Counter',
  'rendering': 'webApp',
  'html': '<main><button id="counter">$text</button></main>',
  'css': '',
  'js':
      'document.getElementById("counter").onclick=function(){this.textContent="2";};',
  'manifest': <String, Object?>{},
};
http.Response _ok(Map<String, Object?> data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
Map<String, Object?> _cloud(Map<String, Object?> source, {int revision = 8}) =>
    {
      'gameId': 'ag_version',
      'clientSurfaceId': 'versioned',
      'experienceType': 'utility',
      'revisionNo': revision,
      'sourceSha256': canonicalAgentGameSourceSha256(source),
      'published': false,
      'hasPublished': false,
    };

void main() {
  late DBService db;
  late AgentWidget item;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'cloud-history-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final spec = <String, Object?>{
      ..._source('one'),
      'surfaceId': 'versioned',
      'surfaceKind': 'fullscreen',
      'experienceType': 'utility',
      'appletLocal': {'schemaVersion': 1, 'scopeKey': 'test-scope'},
    };
    spec['versionHistory'] = SurfaceVersionHistory.create(
      spec,
      title: 'Counter',
    ).toJson();
    item = AgentWidget(
      agentId: 'self',
      title: 'Counter',
      kind: 'surface',
      spec: spec,
      createdAt: DateTime(2026),
    );
    item.id = await db.saveAgentWidget(item);
  });
  tearDown(() async {
    await db.close();
    await appServices.reset();
  });

  AgentGameCloudService service(
    Future<http.Response> Function(http.Request) handler,
  ) => AgentGameCloudService(
    database: db,
    httpClient: MockClient(handler),
    baseUri: () => Uri.parse('https://api.example.test/'),
    accessToken: () async => 'token',
  );

  test(
    'owned source validates decoded UTF-8 byte capacity even with a correct digest',
    () {
      final source = _source('old')..['js'] = '😀' * (2 * 1024 * 1024);
      final payload = {
        'id': 'ag_version',
        'clientSurfaceId': 'versioned',
        'revisionNo': 1,
        'sourceSha256': canonicalAgentGameSourceSha256(source),
        'experienceType': 'utility',
        'category': 'tools',
        'skillInstructions': '',
        'surface': source,
      };
      // JS alone occupies 8MiB; the HTML pushes the complete work over the bound.
      expect(
        () => AppletSourceDocument.fromJson(payload),
        throwsFormatException,
      );
    },
  );

  test(
    'cloud mapping records remote revision without assuming local number equality',
    () async {
      final sync = service((request) async {
        final source = (jsonDecode(request.body) as Map)['surface'] as Map;
        return _ok(_cloud(source.cast<String, Object?>()));
      });
      await sync.syncPrivate(item);
      final saved = (await db.getAllWidgets()).single;
      final history = SurfaceVersionHistory.read(
        saved.spec,
        title: saved.title,
      );
      expect(history.current.number, 1);
      final binding =
          (saved.spec['versionCloudBindings'] as Map)[history.current.id]
              as Map;
      expect(binding['revisionNo'], 8);
      expect(binding['gameId'], 'ag_version');
    },
  );

  test(
    'late sync receipt does not mark a newer local source as synced',
    () async {
      final started = Completer<Map<String, Object?>>();
      final response = Completer<http.Response>();
      final sync = service((request) async {
        started.complete(
          ((jsonDecode(request.body) as Map)['surface'] as Map)
              .cast<String, Object?>(),
        );
        return response.future;
      });
      final pending = sync.syncPrivate(item);
      final oldSource = await started.future;
      final history = SurfaceVersionHistory.read(item.spec, title: item.title);
      final newer = <String, Object?>{
        ...item.spec,
        'html': '<main><button id="counter">newer</button></main>',
      };
      newer['versionHistory'] = history
          .append(newer, title: item.title)
          .toJson();
      await db.updateGeneratedSurface(item.id!, spec: newer);
      response.complete(_ok(_cloud(oldSource)));
      await pending;
      final saved = (await db.getAllWidgets()).single;
      expect(saved.spec['html'], contains('newer'));
      expect(
        AgentGameCloudMetadata.fromSpec(saved.spec['cloud']).syncState,
        AgentGameSyncState.pending,
      );
      expect(
        (saved.spec['versionCloudBindings'] as Map)[history.current.id],
        isNotNull,
      );
    },
  );

  test(
    '409 is durable conflict and is excluded from automatic retry',
    () async {
      var requests = 0;
      final sync = service((_) async {
        requests++;
        return http.Response(
          jsonEncode({'code': 'CONFLICT', 'message': 'stale base'}),
          409,
        );
      });
      await expectLater(
        sync.syncPrivate(item),
        throwsA(isA<AppletVersionConflictException>()),
      );
      final saved = (await db.getAllWidgets()).single;
      expect(
        AgentGameCloudMetadata.fromSpec(saved.spec['cloud']).syncState,
        AgentGameSyncState.conflict,
      );
      await sync.retryPendingOrFailed();
      expect(requests, 1);
    },
  );

  for (final largeSource in [false, true]) {
    test(
      'owner history is bounded and selected immutable source reopens offline (large: $largeSource)',
      () async {
        final source = _source('old');
        if (largeSource)
          source['js'] = '${source['js']}\n/*${'x' * (3 * 1024 * 1024)}*/';
        final hash = canonicalAgentGameSourceSha256(source);
        item.spec['cloud'] = {
          ..._cloud(_source('one')),
          'scopeKey': 'test-scope',
          'syncState': 'synced',
        };
        await db.updateWidget(item.id!, spec: item.spec);
        var requests = 0;
        final sync = service((request) async {
          requests++;
          expect(request.headers['Authorization'], 'Bearer token');
          if (request.url.path.endsWith('/revisions')) {
            expect(request.url.queryParameters, {'limit': '50'});
            return _ok({
              'gameId': 'ag_version',
              'clientSurfaceId': 'versioned',
              'currentRevisionNo': 8,
              'publishedRevisionNo': 1,
              'items': [
                {
                  'revisionNo': 1,
                  'sourceSha256': hash,
                  'createdAt': '2026-09-22T01:00:00Z',
                },
              ],
            });
          }
          return _ok({
            'id': 'ag_version',
            'clientSurfaceId': 'versioned',
            'revisionNo': 1,
            'sourceSha256': hash,
            'experienceType': 'utility',
            'category': 'tools',
            'skillInstructions': '',
            'surface': source,
          });
        });
        final page = await sync.listVersions(item);
        expect(page.items.single.revisionNo, 1);
        final first = await sync.revisionSource(
          item,
          1,
          expectedSourceSha256: hash,
        );
        expect(first.surface['html'], contains('old'));
        final cached = (await db.getAllWidgets()).single;
        final offline = service((_) async => throw StateError('offline'));
        expect(offline.cachedVersions(cached).single.revisionNo, 1);
        final reopened = await offline.revisionSource(
          cached,
          1,
          expectedSourceSha256: hash,
        );
        expect(reopened.sourceSha256, hash);
        expect(requests, 2);
        await expectLater(
          offline.revisionSource(cached, 1, expectedSourceSha256: 'a' * 64),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'same-source restoration keeps the earlier local public pointer until explicit publication',
    () async {
      var published = false;
      late String hash;
      final sync = service((request) async {
        final body = jsonDecode(request.body) as Map;
        if (request.url.path.endsWith('/publish')) {
          published = true;
        } else {
          hash = canonicalAgentGameSourceSha256(
            (body['surface'] as Map).cast<String, Object?>(),
          );
        }
        return _ok({
          'gameId': 'ag_version',
          'clientSurfaceId': 'versioned',
          'experienceType': 'utility',
          'revisionNo': 8,
          'sourceSha256': hash,
          'published': published,
          'hasPublished': published,
          if (published) 'publishedRevisionNo': 8,
          if (published) 'publishedSourceSha256': hash,
          if (published) 'shareUrl': 'https://api.example.test/g/identical',
        });
      });
      await sync.publish(item);
      final original = SurfaceVersionHistory.read(item.spec, title: item.title);
      expect(
        AgentGameCloudMetadata.fromSpec(
          item.spec['cloud'],
        ).publishedLocalVersionId,
        original.current.id,
      );
      final changed = {
        ...item.spec,
        'html': '<main><button id="counter">different</button></main>',
      };
      final history = original
          .append(changed, title: item.title)
          .append(
            item.spec,
            title: item.title,
            restoredFromId: original.current.id,
          );
      final restored = AgentWidget.fromJson({
        ...item.toJson(),
        'spec': {...item.spec, 'versionHistory': history.toJson()},
      }, id: item.id);
      await db.updateGeneratedSurface(item.id!, spec: restored.spec);
      final result = await sync.syncPrivate(restored);
      expect(result.revisionNo, 8);
      expect(result.localVersionId, history.current.id);
      expect(result.publishedLocalVersionId, original.current.id);
      expect(result.isCurrentPublished, isFalse);
      expect(
        AgentGameCloudMetadata.fromSpec(
          (await db.getAllWidgets()).single.spec['cloud'],
        ).isCurrentPublished,
        isFalse,
      );
      final explicitlyPublished = await sync.publish(restored);
      expect(explicitlyPublished.localVersionId, history.current.id);
      expect(explicitlyPublished.publishedLocalVersionId, history.current.id);
      expect(explicitlyPublished.isCurrentPublished, isTrue);
    },
  );

  test(
    'human reapplication uses displayed remote base and preserves both branches',
    () async {
      item.spec['cloud'] = {
        ..._cloud(_source('one'), revision: 1),
        'scopeKey': 'test-scope',
        'syncState': 'conflict',
      };
      await db.updateWidget(item.id!, spec: item.spec);
      final remote = _source('remote');
      final hash = canonicalAgentGameSourceSha256(remote);
      final sync = service((request) async {
        if (request.method == 'GET') {
          return _ok({
            'id': 'ag_version',
            'clientSurfaceId': 'versioned',
            'revisionNo': 8,
            'sourceSha256': hash,
            'experienceType': 'utility',
            'category': 'tools',
            'skillInstructions': '',
            'surface': remote,
            'cloud': _cloud(remote),
          });
        }
        final body = jsonDecode(request.body) as Map;
        expect(body['baseRevisionNo'], 8);
        expect((body['surface'] as Map)['html'], contains('one'));
        return _ok(
          _cloud((body['surface'] as Map).cast<String, Object?>(), revision: 9),
        );
      });
      final metadata = await sync.reapplyAfterConflict(
        item,
        expectedRemoteRevisionNo: 8,
      );
      expect(metadata.revisionNo, 9);
      expect((await db.getAllWidgets()).single.spec['html'], contains('one'));
    },
  );
}
