import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/ui/world_portal.dart';
import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:sembast/sembast_memory.dart';

Future<DBService> _memoryDatabase() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'agent_game_cloud_${DateTime.now().microsecondsSinceEpoch}.db',
);

class _FailingDeleteMarkerDatabase extends DBService {
  @override
  Future<void> updateWidgetSpecFieldValidated(
    int id,
    String key,
    Object? value, {
    required bool Function(AgentWidget current) validate,
  }) {
    throw StateError('delete marker write failed');
  }
}

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('private sync posts only the web-safe Surface game source', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.title = '  Orbit\n  Game  ';
    await database.saveAgentWidget(widget);
    late Map<String, Object?> requestBody;
    late Uri requestUri;
    final client = MockClient((request) async {
      requestUri = request.url;
      requestBody = Map<String, Object?>.from(jsonDecode(request.body) as Map);
      final source = Map<String, Object?>.from(requestBody['surface'] as Map);
      return _ok(<String, Object?>{
        'gameId': 'game_42',
        'clientSurfaceId': 'surface_7',
        'revisionNo': 3,
        'sourceSha256': _sourceSha(source),
        'published': false,
      });
    });
    final service = AgentGameCloudService(
      database: database,
      httpClient: client,
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    final metadata = await service.syncPrivate(widget);

    expect(requestUri.path, '/v1/agent-games/by-client/surface_7');
    expect(requestBody.keys, <String>{'title', 'experienceType', 'surface'});
    expect(requestBody['title'], 'Orbit Game');
    expect(requestBody['experienceType'], 'game');
    final surface = Map<String, Object?>.from(requestBody['surface'] as Map);
    expect(surface['title'], requestBody['title']);
    expect(surface.keys, <String>{
      'title',
      'rendering',
      'html',
      'css',
      'js',
      'manifest',
    });
    expect(surface, isNot(contains('backend')));
    expect(surface, isNot(contains('revisions')));
    expect(surface, isNot(contains('cloud')));
    expect(metadata.gameId, 'game_42');
    expect(metadata.revisionNo, 3);
    expect(metadata.syncState, AgentGameSyncState.synced);

    final saved = (await database.getAllWidgets()).single;
    final cloud = AgentGameCloudMetadata.fromSpec(saved.spec['cloud']);
    expect(cloud.gameId, 'game_42');
    expect(cloud.revisionNo, 3);
    expect(cloud.sourceSha256, _sourceSha(surface));
    expect(cloud.syncState, AgentGameSyncState.synced);
  });

  test(
    'public-safe webApp publishes without rewriting its rendering',
    () async {
      final database = await _memoryDatabase();
      final widget = _webAppWidget();
      await database.saveAgentWidget(widget);
      final paths = <String>[];
      late Map<String, Object?> syncedSurface;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          if (request.url.path.endsWith('/publish')) {
            final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
            return _ok(<String, Object?>{
              'gameId': 'web_game_42',
              'revisionNo': cloud.revisionNo,
              'sourceSha256': cloud.sourceSha256,
              'published': true,
              'shareUrl': '/g/web-game-42',
            });
          }
          syncedSurface = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'web_game_42',
            'clientSurfaceId': 'surface_web_7',
            'experienceType': 'game',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(syncedSurface),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final published = await service.publish(widget);

      expect(isCloudAppletWidget(widget), isTrue);
      expect(paths, <String>[
        '/v1/agent-games/by-client/surface_web_7',
        '/v1/agent-games/web_game_42/publish',
      ]);
      expect(syncedSurface['rendering'], 'webApp');
      expect(syncedSurface['html'], widget.spec['html']);
      expect(syncedSurface['css'], widget.spec['css']);
      expect(syncedSurface['js'], widget.spec['js']);
      expect(syncedSurface['js'], isNot(contains('Game.define')));
      expect(published.syncState, AgentGameSyncState.published);
      expect(published.shareUrl, 'https://api.example.test/g/web-game-42');
    },
  );

  test(
    'network webApp enters initial sync without rewriting its source',
    () async {
      final database = await _memoryDatabase();
      final widget = _webAppWidget()..spec['js'] = 'fetch("/private-score");';
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          requestCount += 1;
          final source = Map<String, Object?>.from(
            (jsonDecode(request.body) as Map)['surface'] as Map,
          );
          expect(source['js'], 'fetch("/private-score");');
          return _ok(<String, Object?>{
            'gameId': 'network_game',
            'clientSurfaceId': 'surface_web_7',
            'experienceType': 'game',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );
      appServices.put<AgentGameCloudService>(service);

      expect(isAgentGameWidget(widget), isTrue);
      expect(isCloudAppletWidget(widget), isTrue);

      await syncNewAppletBeforePresent(widget);

      expect(requestCount, 1);
      expect((await database.getAllWidgets()).single.spec['cloud'], isNotNull);
      expect(
        (await database.getAllWidgets()).single.spec['js'],
        'fetch("/private-score");',
      );
    },
  );

  test(
    'webApp sync hashes the original validated HTML without serializing it',
    () async {
      final database = await _memoryDatabase();
      const originalHtml = '''
<main id="game">
  <br />
  <button id="play" type="button" title="A &amp; B">Play&nbsp;now</button>
</main>
''';
      final widget = _webAppWidget()..spec['html'] = originalHtml;
      await database.saveAgentWidget(widget);
      final expectedSurface = <String, Object?>{
        'title': widget.title,
        'rendering': 'webApp',
        'html': originalHtml,
        'css': widget.spec['css'],
        'js': widget.spec['js'],
        'manifest': widget.spec['manifest'],
      };
      late Map<String, Object?> syncedSurface;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          syncedSurface = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'web_game_original_source',
            'clientSurfaceId': 'surface_web_7',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(expectedSurface),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final metadata = await service.syncPrivate(widget);

      expect(isCloudAppletWidget(widget), isTrue);
      expect(syncedSurface, expectedSurface);
      expect(syncedSurface['html'], originalHtml);
      expect(metadata.sourceSha256, _sourceSha(expectedSurface));
    },
  );

  test('new Applets pin safe catalog metadata before first sync', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget()..subtitle = '  Tiny\n orbit challenge  ';
    var locale = 'zh-CN';
    final bodies = <Map<String, Object?>>[];
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        bodies.add(body);
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'applet_metadata',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 1,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
      catalogLocale: () => locale,
    );
    service.stampLocalOwnership(widget);
    await database.saveAgentWidget(widget);

    await service.syncPrivate(widget);
    locale = 'en-US';
    await service.syncPrivate(widget);

    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(body['summary'], 'Tiny orbit challenge');
      expect(body['locale'], 'zh-CN');
      expect(body, isNot(contains('authorDisplayName')));
      expect(body, isNot(contains('authorAgentId')));
    }
    final saved = (await database.getAllWidgets()).single;
    expect(saved.spec['appletCatalog'], <String, Object?>{
      'schemaVersion': 2,
      'summary': 'Tiny orbit challenge',
      'locale': 'zh-CN',
    });
  });

  test('startup recovery removes a previous-process pending Applet', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget()
      ..spec['rendering'] = 'dom'
      ..spec[appletPresentationPendingKey] = const <String, Object?>{
        'schemaVersion': 1,
        'owner': 'previous-process',
        'createdAt': '2026-08-12T00:00:00.000Z',
      };
    await database.saveAgentWidget(widget);
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((_) async {
        requestCount++;
        return _ok(const <String, Object?>{});
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await service.retryPendingOrFailed();

    expect(await database.getAllWidgets(), isEmpty);
    expect(requestCount, 0);
  });

  test(
    'unsigned startup recovers a device-legacy pending game locally',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget()
        ..spec['appletLocal'] = const <String, Object?>{
          'schemaVersion': 1,
          'scopeKey': AppletLocalOwnership.deviceLegacyScope,
        }
        ..spec[appletPresentationPendingKey] = true;
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestCount++;
          return _ok(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
      );
      addTearDown(service.onClose);

      await service.retryPendingOrFailed();

      expect(await database.getAllWidgets(), isEmpty);
      expect(requestCount, 0);
    },
  );

  test('recovery never races a current-process pending presentation', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    markAppletPresentationPending(widget);
    await database.saveAgentWidget(widget);
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((_) async {
        requestCount++;
        return _ok(const <String, Object?>{});
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await service.retryPendingOrFailed();

    expect(await database.getAllWidgets(), hasLength(1));
    expect(requestCount, 0);
  });

  test(
    'pending cancellation tombstone retries before presentation recovery',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      markAppletPresentationPending(widget);
      await database.saveAgentWidget(widget);
      var deleteCalls = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            '/v1/agent-games/by-client/surface_7/delete',
          );
          deleteCalls++;
          if (deleteCalls == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'code': 'UNAVAILABLE',
                'message': 'retry delete',
              }),
              503,
            );
          }
          return _ok(const <String, Object?>{
            'clientSurfaceId': 'surface_7',
            'deleted': true,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );
      addTearDown(service.onClose);

      await service.compensateUnpresented(
        widget,
        expectedScopeKey: 'test-scope',
      );
      final pending = (await database.getAllWidgets()).single;
      expect(isAppletPresentationPending(pending), isTrue);
      expect(pending.spec['cloudDelete'], isNotNull);

      await service.retryPendingOrFailed();

      expect(deleteCalls, 2);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test('canonical hash matches the server for raw HTML symbols', () {
    const serverFixtureSha =
        '14fb5eadc6e85e251abab9abfcd6e2b4485f51919cfd40ff5b14f94cb7c311eb';
    final source = <String, Object?>{
      'title': 'Orbit Game',
      'rendering': 'canvas',
      'html': '<canvas id="orbit">A & B</canvas>',
      'css': '#orbit{width:100%}',
      'js': 'window.ready=true;',
      'manifest': <String, Object?>{
        'events': <Object?>[],
        'actions': <Object?>[
          <String, Object?>{'name': 'pulse', 'schema': <String, Object?>{}},
        ],
      },
    };

    expect(canonicalAgentGameSourceSha256(source), serverFixtureSha);
  });

  test('canonical hash matches Go for Unicode line separators', () {
    const serverFixtureSha =
        'd780271f4f252dde8e24e96c1a780da0ee5b60a56c9e92667c8ecde17077ceb8';
    final source = <String, Object?>{
      'title': 'Separator Game',
      'rendering': 'dom',
      'html': '<main>A\u2028B\u2029C</main>',
      'css': '',
      'js': '',
      'manifest': <String, Object?>{
        'events': <Object?>[],
        'actions': <Object?>[],
      },
    };

    expect(canonicalAgentGameSourceSha256(source), serverFixtureSha);
  });

  test('server source hash mismatch marks the local sync as failed', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    await database.saveAgentWidget(widget);
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient(
        (_) async => _ok(<String, Object?>{
          'gameId': 'game_wrong_hash',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 1,
          'sourceSha256': List<String>.filled(64, '0').join(),
          'published': false,
        }),
      ),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await expectLater(service.syncPrivate(widget), throwsStateError);

    final saved = (await database.getAllWidgets()).single;
    final cloud = AgentGameCloudMetadata.fromSpec(saved.spec['cloud']);
    expect(cloud.syncState, AgentGameSyncState.failed);
    expect(cloud.error, contains('different source hash'));
  });

  test(
    'cloud quota keeps the local Applet pending and never deletes it',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final paths = <String>[];
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/delete')) {
            return _ok(const <String, Object?>{
              'clientSurfaceId': 'surface_7',
              'deleted': true,
            });
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'RATE_LIMITED',
              'message': 'agent game storage quota exceeded',
            }),
            429,
          );
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final deferred = await service.syncNewBeforePresent(widget);

      expect(paths, <String>['/v1/agent-games/by-client/surface_7']);
      expect(deferred.syncState, AgentGameSyncState.pending);
      expect(deferred.error, 'applet_quota_reached');
      expect(deferred.isCurrentInCloud, isFalse);
      expect(deferred.isCurrentPublished, isFalse);
      final saved = (await database.getAllWidgets()).single;
      expect(saved.spec['cloudDelete'], isNull);
      expect(saved.spec['js'], widget.spec['js']);
      expect(
        AgentGameCloudMetadata.fromSpec(saved.spec['cloud']).syncState,
        AgentGameSyncState.pending,
      );
      // Explicit cloud publication still submits to the server and obeys the
      // same rejection; successful local creation grants no cloud permission.
      await expectLater(
        service.publish(widget),
        throwsA(isA<AppletQuotaExceededException>()),
      );
      expect(paths, hasLength(2));
      expect(paths.every((path) => !path.endsWith('/publish')), isTrue);
      expect(await database.getAllWidgets(), hasLength(1));
      await service.retryPendingOrFailed();
      expect(
        paths,
        hasLength(2),
        reason: 'Quota must not trigger upload loops',
      );
    },
  );

  test(
    'actual preview cancellation still compensates deferred cloud sync once',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final paths = <String>[];
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/delete')) {
            return _ok(const <String, Object?>{
              'clientSurfaceId': 'surface_7',
              'deleted': true,
            });
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'RATE_LIMITED',
              'message': 'agent game storage quota exceeded',
            }),
            429,
          );
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final deferred = await service.syncNewBeforePresent(widget);
      expect(deferred.syncState, AgentGameSyncState.pending);
      expect(paths, <String>['/v1/agent-games/by-client/surface_7']);
      expect(await database.getAllWidgets(), hasLength(1));

      await service.compensateUnpresented(
        widget,
        expectedScopeKey: 'test-scope',
      );

      expect(paths, <String>[
        '/v1/agent-games/by-client/surface_7',
        '/v1/agent-games/by-client/surface_7/delete',
      ]);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'offline initial sync retains the exact local source for preview',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final originalSource = widget.spec['js'];
      var uploads = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          uploads++;
          throw const SocketException('offline');
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );
      addTearDown(service.closeLifecycle);

      final deferred = await service.syncNewBeforePresent(widget);

      expect(uploads, 1);
      expect(deferred.syncState, AgentGameSyncState.pending);
      expect(deferred.error, 'applet_cloud_sync_pending');
      expect(deferred.isCurrentInCloud, isFalse);
      final saved = (await database.getAllWidgets()).single;
      expect(saved.spec['js'], originalSource);
      expect(saved.spec['cloudDelete'], isNull);
    },
  );

  test(
    'initial cloud failure cannot cross the captured account scope',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      var scope = 'test-scope';
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestStarted.complete();
          await releaseRequest.future;
          return http.Response('server unavailable', 503);
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        accountScope: () => scope,
      );
      final outcome = expectLater(
        service.syncNewBeforePresent(widget),
        throwsStateError,
      );
      await requestStarted.future;
      scope = 'another-account';
      releaseRequest.complete();
      await outcome;

      final saved = (await database.getAllWidgets()).single;
      expect(AppletLocalOwnership.storedScopeKey(saved), 'test-scope');
      final metadata = AgentGameCloudMetadata.fromSpec(saved.spec['cloud']);
      expect(metadata.scopeKey, 'test-scope');
      expect(metadata.isCurrentInCloud, isFalse);
      expect(saved.spec['cloudDelete'], isNull);
    },
  );

  test(
    'failed tombstone write releases the in-memory deletion fence',
    () async {
      final database = _FailingDeleteMarkerDatabase();
      await database.init(
        factory: databaseFactoryMemory,
        path: 'delete_marker_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      var syncCalls = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          syncCalls++;
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          final source = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'game_after_marker_failure',
            'clientSurfaceId': 'surface_7',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await expectLater(service.deleteRemote(widget), throwsStateError);
      expect(widget.spec, isNot(contains('cloudDelete')));

      await service.syncPrivate(widget);

      expect(syncCalls, 1);
    },
  );

  test(
    'cancelled initial Applet sync is deleted before presentation',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final paths = <String>[];
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return _ok(const <String, Object?>{
            'clientSurfaceId': 'surface_7',
            'deleted': true,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await service.compensateUnpresented(
        widget,
        expectedScopeKey: 'test-scope',
      );

      expect(paths, <String>['/v1/agent-games/by-client/surface_7/delete']);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'device-legacy cancellation deletes locally without cloud auth',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget()
        ..spec['appletLocal'] = const <String, Object?>{
          'schemaVersion': 1,
          'scopeKey': AppletLocalOwnership.deviceLegacyScope,
        };
      markAppletPresentationPending(widget);
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestCount++;
          return _ok(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
      );

      await service.compensateUnpresented(
        widget,
        expectedScopeKey: AppletLocalOwnership.deviceLegacyScope,
      );

      expect(await database.getAllWidgets(), isEmpty);
      expect(requestCount, 0);
    },
  );

  test('cancel compensation blocks a stale clone from resyncing', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    await database.saveAgentWidget(widget);
    final staleClone = AgentWidget.fromJson(widget.toJson(), id: widget.id);
    final requestStarted = Completer<void>();
    final deleteResponse = Completer<http.Response>();
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestCount++;
        requestStarted.complete();
        return deleteResponse.future;
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    final compensating = service.compensateUnpresented(
      widget,
      expectedScopeKey: 'test-scope',
    );
    await requestStarted.future;

    expect(() => service.syncPrivate(staleClone), throwsStateError);
    expect(requestCount, 1);
    deleteResponse.complete(
      _ok(const <String, Object?>{
        'clientSurfaceId': 'surface_7',
        'deleted': true,
      }),
    );
    await compensating;
    expect(await database.getAllWidgets(), isEmpty);
  });

  test(
    'cross-scope cancellation persists a delete tombstone without using the new account',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestCount++;
          return _ok(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-other',
        accountScope: () => 'other-scope',
      );

      await service.compensateUnpresented(
        widget,
        expectedScopeKey: 'test-scope',
      );

      expect(requestCount, 0);
      final saved = (await database.getAllWidgets()).single;
      expect(saved.spec['cloudDelete'], <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': 'test-scope',
        'clientSurfaceId': 'surface_7',
      });
    },
  );

  test('an unscoped Applet cannot be synced into a new account', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.spec['appletLocal'] = const <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': 'scope-a',
    };
    widget.spec.remove('cloud');
    await database.saveAgentWidget(widget);
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((_) async {
        requestCount += 1;
        return _ok(const <String, Object?>{});
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-b',
      accountScope: () => 'scope-b',
    );

    expect(() => service.syncPrivate(widget), throwsStateError);
    expect(requestCount, 0);
    expect((await database.getAllWidgets()).single.spec['cloud'], isNull);
  });

  test(
    'non-worker local surfaces are never uploaded as public Applets',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget()
        ..spec['experienceType'] = 'utility'
        ..spec['rendering'] = 'canvas'
        ..spec['html'] = '<canvas id="utility"></canvas>'
        ..spec['css'] = '#utility{width:100%}'
        ..spec['js'] = 'window.ready=true;';
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestCount += 1;
          return _ok(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      expect(
        () => service.syncPrivate(widget),
        throwsA(isA<SurfaceProjectValidationException>()),
      );

      expect(requestCount, 0);
      expect((await database.getAllWidgets()).single.spec['cloud'], isNull);
    },
  );

  test(
    'workerCanvas utility Applets use the same private sync contract',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget()
        ..title = 'Pocket Planner'
        ..spec['title'] = 'Pocket Planner'
        ..spec['experienceType'] = 'utility';
      await database.saveAgentWidget(widget);
      late Map<String, Object?> body;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
          final source = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'applet_42',
            'clientSurfaceId': 'surface_7',
            'experienceType': 'utility',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final metadata = await service.syncPrivate(widget);

      expect(body['experienceType'], 'utility');
      expect(metadata.gameId, 'applet_42');
      expect(metadata.syncState, AgentGameSyncState.synced);
      expect(isAgentGameWidget(widget), isFalse);
      expect(isCloudAppletWidget(widget), isTrue);
    },
  );

  test(
    'failed background sync keeps the local game and records failure',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'code': 'UNAVAILABLE',
              'message': 'try later',
            }),
            503,
          ),
        ),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await service.schedulePrivateSync(widget);

      final saved = (await database.getAllWidgets()).single;
      expect(saved.title, 'Orbit Game');
      expect(saved.spec['html'], isEmpty);
      expect(saved.spec['js'], contains('Game.define'));
      final cloud = AgentGameCloudMetadata.fromSpec(saved.spec['cloud']);
      expect(cloud.syncState, AgentGameSyncState.failed);
      expect(cloud.error, 'try later');
    },
  );

  test('post-frame retry resumes pending or failed local games', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.spec['cloud'] = const <String, Object?>{
      'sourceSha256': 'old-attempt',
      'syncState': 'failed',
      'scopeKey': 'test-scope',
      'error': 'offline',
    };
    await database.saveAgentWidget(widget);
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestCount += 1;
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_retry',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 1,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await service.retryPendingOrFailed();

    expect(requestCount, 1);
    final cloud = AgentGameCloudMetadata.fromSpec(
      (await database.getAllWidgets()).single.spec['cloud'],
    );
    expect(cloud.syncState, AgentGameSyncState.synced);
    expect(cloud.gameId, 'game_retry');
  });

  test(
    'share syncs current revision before publish and opens system share',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final requests = <Map<String, Object?>>[];
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        requests.add(body);
        if (request.url.path.endsWith('/publish')) {
          return _ok(<String, Object?>{
            'gameId': 'game_42',
            'revisionNo': 4,
            'sourceSha256': AgentGameCloudMetadata.fromSpec(
              widget.spec['cloud'],
            ).sourceSha256,
            'published': true,
            'slug': 'orbit-42',
            'shareUrl': '/g/orbit-42',
          });
        }
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_42',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 4,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      });
      final share = _RecordingShareGateway();
      final service = AgentGameCloudService(
        database: database,
        httpClient: client,
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        shareGateway: share,
      );

      final opened = await service.publishAndShare(widget);

      expect(opened, isTrue);
      expect(paths, <String>[
        '/v1/agent-games/by-client/surface_7',
        '/v1/agent-games/game_42/publish',
      ]);
      expect(requests.last, <String, Object?>{
        'revisionNo': 4,
        'sourceSha256': AgentGameCloudMetadata.fromSpec(
          widget.spec['cloud'],
        ).sourceSha256,
      });
      expect(share.text, contains('https://api.example.test/g/orbit-42'));
      final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
      expect(cloud.syncState, AgentGameSyncState.published);
      expect(cloud.shareUrl, 'https://api.example.test/g/orbit-42');
    },
  );

  test('publish maps a disabled public catalog to a typed failure', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    await database.saveAgentWidget(widget);
    final share = _RecordingShareGateway();
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        if (request.url.path.endsWith('/publish')) {
          return http.Response(
            jsonEncode(const <String, Object?>{
              'code': 'SERVICE_UNAVAILABLE',
              'message': 'public Applet publication is unavailable',
              'data': <String, Object?>{},
            }),
            503,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_42',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 4,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
      shareGateway: share,
    );

    await expectLater(
      service.publishAndShare(widget),
      throwsA(isA<AppletPublicationUnavailableException>()),
    );

    expect(share.text, isEmpty);
    expect(
      AgentGameCloudMetadata.fromSpec(widget.spec['cloud']).syncState,
      AgentGameSyncState.synced,
    );
  });

  test('publish rejects a different server revision before sharing', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    await database.saveAgentWidget(widget);
    final share = _RecordingShareGateway();
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        if (request.url.path.endsWith('/publish')) {
          return _ok(<String, Object?>{
            'gameId': 'game_42',
            'revisionNo': 99,
            'sourceSha256': AgentGameCloudMetadata.fromSpec(
              widget.spec['cloud'],
            ).sourceSha256,
            'published': true,
            'shareUrl': '/g/wrong-revision',
          });
        }
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_42',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 4,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
      shareGateway: share,
    );

    await expectLater(service.publishAndShare(widget), throwsStateError);

    expect(share.text, isEmpty);
    final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    expect(cloud.syncState, AgentGameSyncState.synced);
    expect(cloud.revisionNo, 4);
  });

  test('unpublish revokes the public game before local deletion', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.spec['cloud'] = <String, Object?>{
      'gameId': 'game_42',
      'revisionNo': 4,
      'sourceSha256': canonicalAgentGameSourceSha256({
        'title': widget.title,
        'rendering': widget.spec['rendering'],
        'html': widget.spec['html'],
        'css': widget.spec['css'],
        'js': widget.spec['js'],
        'manifest': {
          'events': <Object?>[],
          ...(widget.spec['manifest'] as Map).cast<String, Object?>(),
        },
      }),
      'syncState': 'published',
      'scopeKey': 'test-scope',
      'shareUrl': 'https://play.example.test/g/orbit-42',
    };
    await database.saveAgentWidget(widget);
    late Uri requestUri;
    late Map<String, Object?> requestBody;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestUri = request.url;
        requestBody = Map<String, Object?>.from(
          jsonDecode(request.body) as Map,
        );
        return _ok(<String, Object?>{
          'gameId': 'game_42',
          'revisionNo': 4,
          'sourceSha256': AgentGameCloudMetadata.fromSpec(
            widget.spec['cloud'],
          ).sourceSha256,
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await service.unpublish(widget);

    expect(requestUri.path, '/v1/agent-games/game_42/unpublish');
    expect(requestBody, isEmpty);
    final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    expect(cloud.syncState, AgentGameSyncState.synced);
    expect(cloud.hasPublished, isFalse);
    expect(cloud.shareUrl, isEmpty);
  });

  test('remote delete removes the cloud game before local deletion', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.spec['cloud'] = const <String, Object?>{
      'gameId': 'game_42',
      'revisionNo': 4,
      'sourceSha256':
          '14fb5eadc6e85e251abab9abfcd6e2b4485f51919cfd40ff5b14f94cb7c311eb',
      'syncState': 'published',
      'scopeKey': 'test-scope',
      'shareUrl': 'https://play.example.test/g/orbit-42',
    };
    await database.saveAgentWidget(widget);
    late Uri requestUri;
    late Map<String, Object?> requestBody;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestUri = request.url;
        requestBody = Map<String, Object?>.from(
          jsonDecode(request.body) as Map,
        );
        return _ok(const <String, Object?>{
          'clientSurfaceId': 'surface_7',
          'deleted': true,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    await service.deleteRemote(widget);

    expect(requestUri.path, '/v1/agent-games/by-client/surface_7/delete');
    expect(requestBody, isEmpty);
    expect(await database.getAllWidgets(), isEmpty);
  });

  test(
    'remote delete follows cloud ownership after rendering becomes private',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      widget.spec['cloud'] = const <String, Object?>{
        'gameId': 'game_legacy_rendering',
        'revisionNo': 4,
        'sourceSha256':
            '14fb5eadc6e85e251abab9abfcd6e2b4485f51919cfd40ff5b14f94cb7c311eb',
        'syncState': 'published',
        'scopeKey': 'test-scope',
        'shareUrl': 'https://api.example.test/g/orbit-42',
      };
      widget.spec['rendering'] = 'dom';
      widget.spec['html'] = '<main>private edit</main>';
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          requestCount += 1;
          expect(
            request.url.path,
            '/v1/agent-games/by-client/surface_7/delete',
          );
          return _ok(const <String, Object?>{
            'clientSurfaceId': 'surface_7',
            'deleted': true,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await service.deleteRemote(widget);

      expect(requestCount, 1);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'delete waits for in-flight sync and tombstone prevents cloud resurrection',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      final syncStarted = Completer<Map<String, Object?>>();
      final releaseSync = Completer<void>();
      final paths = <String>[];
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          if (!request.url.path.endsWith('/delete')) {
            final source = Map<String, Object?>.from(body['surface'] as Map);
            syncStarted.complete(body);
            await releaseSync.future;
            return _ok(<String, Object?>{
              'gameId': 'game_delayed_delete',
              'clientSurfaceId': 'surface_7',
              'revisionNo': 1,
              'sourceSha256': _sourceSha(source),
              'published': false,
            });
          }
          return _ok(const <String, Object?>{
            'clientSurfaceId': 'surface_7',
            'deleted': true,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );
      service.stampLocalOwnership(widget);
      await database.saveAgentWidget(widget);

      final syncing = service.syncPrivate(widget);
      await syncStarted.future;
      final deleting = service.deleteRemote(widget);
      releaseSync.complete();

      await expectLater(syncing, throwsStateError);
      await deleting;
      expect(paths, <String>[
        '/v1/agent-games/by-client/surface_7',
        '/v1/agent-games/by-client/surface_7/delete',
      ]);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test(
    'account switch during delete preserves the original scoped tombstone',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      widget.spec['appletLocal'] = const <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': 'scope-a',
      };
      widget.spec['cloud'] = const <String, Object?>{
        'gameId': 'game_scope_a',
        'revisionNo': 1,
        'sourceSha256':
            '14fb5eadc6e85e251abab9abfcd6e2b4485f51919cfd40ff5b14f94cb7c311eb',
        'syncState': 'synced',
        'scopeKey': 'scope-a',
      };
      await database.saveAgentWidget(widget);
      var scopeKey = 'scope-a';
      final client = _PendingClient();
      final service = AgentGameCloudService(
        database: database,
        httpClient: client,
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        accountScope: () => scopeKey,
      );

      final deleting = service.deleteRemote(widget);
      final request = await client.request;
      expect(request.pathSegments, <String>[
        'v1',
        'agent-games',
        'by-client',
        'surface_7',
        'delete',
      ]);
      scopeKey = 'scope-b';
      client.complete(
        _ok(const <String, Object?>{
          'clientSurfaceId': 'surface_7',
          'deleted': true,
        }),
      );

      await expectLater(deleting, throwsStateError);
      final saved = (await database.getAllWidgets()).single;
      expect(saved.spec['cloudDelete'], <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': 'scope-a',
        'clientSurfaceId': 'surface_7',
      });
    },
  );

  test(
    'failed delete survives restart and retries only the delete intent',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      final firstPaths = <String>[];
      final firstService = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          firstPaths.add(request.url.path);
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'UNAVAILABLE',
              'message': 'delete later',
            }),
            503,
          );
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );
      firstService.stampLocalOwnership(widget);
      await database.saveAgentWidget(widget);

      await expectLater(firstService.deleteRemote(widget), throwsStateError);
      final pending = (await database.getAllWidgets()).single;
      expect(pending.spec['cloudDelete'], <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': 'test-scope',
        'clientSurfaceId': 'surface_7',
      });

      final restartedPaths = <String>[];
      final restartedService = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          restartedPaths.add(request.url.path);
          return _ok(const <String, Object?>{
            'clientSurfaceId': 'surface_7',
            'deleted': true,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await restartedService.retryPendingOrFailed();

      expect(firstPaths, <String>[
        '/v1/agent-games/by-client/surface_7/delete',
      ]);
      expect(restartedPaths, <String>[
        '/v1/agent-games/by-client/surface_7/delete',
      ]);
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test('delete tombstone cannot be overwritten by a stale editor', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    final deleteStarted = Completer<void>();
    final deleteResponse = Completer<http.Response>();
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestCount += 1;
        deleteStarted.complete();
        return deleteResponse.future;
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );
    service.stampLocalOwnership(widget);
    await database.saveAgentWidget(widget);
    final staleSpec = Map<String, Object?>.from(widget.spec)
      ..['title'] = 'Stale edit';

    final deleting = service.deleteRemote(widget);
    await deleteStarted.future;

    await expectLater(
      database.updateGeneratedSurface(
        widget.id!,
        title: 'Stale edit',
        spec: staleSpec,
      ),
      throwsStateError,
    );
    await service.schedulePrivateSync(widget);
    expect(requestCount, 1);

    deleteResponse.complete(
      http.Response(
        jsonEncode(<String, Object?>{
          'code': 'UNAVAILABLE',
          'message': 'delete later',
        }),
        503,
      ),
    );
    await expectLater(deleting, throwsStateError);
    final saved = (await database.getAllWidgets()).single;
    expect(saved.title, 'Orbit Game');
    expect(saved.spec['cloudDelete'], <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': 'test-scope',
      'clientSurfaceId': 'surface_7',
    });
  });

  test('160-character client id remains deletable', () async {
    final database = await _memoryDatabase();
    final clientSurfaceId = 'a${List<String>.filled(159, 'b').join()}';
    final widget = _gameWidget()..spec['surfaceId'] = clientSurfaceId;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        expect(request.url.pathSegments.last, 'delete');
        expect(request.url.pathSegments[3], clientSurfaceId);
        return _ok(<String, Object?>{
          'clientSurfaceId': clientSurfaceId,
          'deleted': true,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );
    service.stampLocalOwnership(widget);
    await database.saveAgentWidget(widget);

    await service.deleteRemote(widget);

    expect(await database.getAllWidgets(), isEmpty);
  });

  test('invalid client ids fail before private sync', () async {
    for (final clientSurfaceId in <String>[
      List<String>.filled(161, 'a').join(),
      'surface/escape',
      '-leading-dash',
    ]) {
      final database = await _memoryDatabase();
      final widget = _gameWidget()..spec['surfaceId'] = clientSurfaceId;
      await database.saveAgentWidget(widget);
      var requestCount = 0;
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          requestCount += 1;
          return _ok(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      expect(() => service.syncPrivate(widget), throwsStateError);
      expect(requestCount, 0, reason: clientSurfaceId);
    }
  });

  test('publish rejects a cross-origin or non-Applet share URL', () async {
    Future<void> expectRejected(String shareUrl) async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          if (request.url.path.endsWith('/publish')) {
            final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
            return _ok(<String, Object?>{
              'gameId': 'game_share_policy',
              'revisionNo': cloud.revisionNo,
              'sourceSha256': cloud.sourceSha256,
              'published': true,
              'shareUrl': shareUrl,
            });
          }
          final source = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'game_share_policy',
            'clientSurfaceId': 'surface_7',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      await expectLater(service.publish(widget), throwsStateError);
    }

    await expectRejected('https://evil.example/g/orbit');
    await expectRejected('https://api.example.test/account/orbit');
    await expectRejected('https://api.example.test/g/orbit?redirect=evil');
  });

  test('sync keeps the older published revision visible', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    widget.spec['cloud'] = const <String, Object?>{
      'gameId': 'game_42',
      'revisionNo': 1,
      'sourceSha256': 'old-source',
      'syncState': 'published',
      'scopeKey': 'test-scope',
      'shareUrl': 'https://api.example.test/g/orbit-42',
    };
    await database.saveAgentWidget(widget);
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_42',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 2,
          'sourceSha256': _sourceSha(source),
          'published': false,
          'hasPublished': true,
          'publishedRevisionNo': 1,
          'publishedSourceSha256': 'old-source',
          'shareUrl': '/g/orbit-42',
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
    );

    final cloud = await service.syncPrivate(widget);

    expect(cloud.syncState, AgentGameSyncState.synced);
    expect(cloud.hasPublished, isTrue);
    expect(cloud.isCurrentPublished, isFalse);
    expect(cloud.publishedRevisionNo, 1);
    expect(cloud.publishedSourceSha256, 'old-source');
    expect(cloud.shareUrl, 'https://api.example.test/g/orbit-42');
  });

  test('cloud metadata cannot cross account or environment scope', () async {
    final database = await _memoryDatabase();
    final widget = _gameWidget();
    var scope = 'https://test.example|account-a';
    widget.spec['appletLocal'] = <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': scope,
    };
    await database.saveAgentWidget(widget);
    var requestCount = 0;
    final service = AgentGameCloudService(
      database: database,
      httpClient: MockClient((request) async {
        requestCount += 1;
        final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        final source = Map<String, Object?>.from(body['surface'] as Map);
        return _ok(<String, Object?>{
          'gameId': 'game_scoped',
          'clientSurfaceId': 'surface_7',
          'revisionNo': 1,
          'sourceSha256': _sourceSha(source),
          'published': false,
        });
      }),
      baseUri: () => Uri.parse('https://api.example.test/'),
      accessToken: () async => 'token-1',
      accountScope: () => scope,
    );

    await service.syncPrivate(widget);
    scope = 'https://prod.example|account-b';

    expect(() => service.syncPrivate(widget), throwsStateError);
    expect(requestCount, 1);
    expect(service.isVisibleToCurrentAccount(widget), isFalse);
  });

  test(
    'account switch after publish response never opens the share sheet',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      var scope = 'https://api.example.test|account-a';
      widget.spec['appletLocal'] = <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': scope,
      };
      await database.saveAgentWidget(widget);
      var clockReads = 0;
      final share = _RecordingShareGateway();
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          if (request.url.path.endsWith('/publish')) {
            final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
            return _ok(<String, Object?>{
              'gameId': 'game_scope_race',
              'revisionNo': cloud.revisionNo,
              'sourceSha256': cloud.sourceSha256,
              'published': true,
              'shareUrl': '/g/scope-race',
            });
          }
          final source = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'game_scope_race',
            'clientSurfaceId': 'surface_7',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        accountScope: () => scope,
        shareGateway: share,
        now: () {
          clockReads += 1;
          if (clockReads == 2) {
            scope = 'https://api.example.test|account-b';
          }
          return DateTime.utc(2026, 8, 8, 12, clockReads);
        },
      );

      await expectLater(service.publishAndShare(widget), throwsStateError);

      expect(share.text, isEmpty);
      expect(service.isVisibleToCurrentAccount(widget), isFalse);
    },
  );

  test(
    'network timeout fails the durable local sync instead of hanging',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final service = AgentGameCloudService(
        database: database,
        httpClient: _NeverClient(),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        requestTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        service.syncPrivate(widget),
        throwsA(isA<TimeoutException>()),
      );

      final cloud = AgentGameCloudMetadata.fromSpec(
        (await database.getAllWidgets()).single.spec['cloud'],
      );
      expect(cloud.syncState, AgentGameSyncState.failed);
      expect(cloud.scopeKey, 'test-scope');
    },
  );

  test(
    'publish and unpublish are serialized for the same local game',
    () async {
      final database = await _memoryDatabase();
      final widget = _gameWidget();
      await database.saveAgentWidget(widget);
      final publishResponse = Completer<http.Response>();
      final publishStarted = Completer<void>();
      final paths = <String>[];
      final service = AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          final body = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          if (request.url.path.endsWith('/publish')) {
            publishStarted.complete();
            return publishResponse.future;
          }
          if (request.url.path.endsWith('/unpublish')) {
            final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
            return _ok(<String, Object?>{
              'gameId': 'game_serial',
              'revisionNo': cloud.revisionNo,
              'sourceSha256': cloud.sourceSha256,
              'published': false,
            });
          }
          final source = Map<String, Object?>.from(body['surface'] as Map);
          return _ok(<String, Object?>{
            'gameId': 'game_serial',
            'clientSurfaceId': 'surface_7',
            'revisionNo': 1,
            'sourceSha256': _sourceSha(source),
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
      );

      final publishing = service.publish(widget);
      await publishStarted.future;
      final unpublishing = service.unpublish(widget);
      await Future<void>.delayed(Duration.zero);
      expect(paths.where((path) => path.endsWith('/unpublish')), isEmpty);
      final synced = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
      publishResponse.complete(
        _ok(<String, Object?>{
          'gameId': 'game_serial',
          'revisionNo': synced.revisionNo,
          'sourceSha256': synced.sourceSha256,
          'published': true,
          'shareUrl': '/g/serial',
        }),
      );

      await publishing;
      await unpublishing;

      expect(paths, <String>[
        '/v1/agent-games/by-client/surface_7',
        '/v1/agent-games/game_serial/publish',
        '/v1/agent-games/game_serial/unpublish',
      ]);
      expect(
        AgentGameCloudMetadata.fromSpec(widget.spec['cloud']).syncState,
        AgentGameSyncState.synced,
      );
    },
  );

  test(
    'generated game save returns while private cloud request is pending',
    () async {
      final database = await _memoryDatabase();
      appServices.put<DBService>(database);
      final pendingClient = _PendingClient();
      appServices.put(
        AgentGameCloudService(
          database: database,
          httpClient: pendingClient,
          baseUri: () => Uri.parse('https://api.example.test/'),
          accessToken: () async => 'token-1',
          accountScope: () => 'device-legacy',
        ),
      );
      final runtime = SurfaceRuntime();
      final skill = FreeformSurfaceSkill(agentId: 'self', runtime: runtime);

      final raw =
          await (skill.methods['showSurface']!(<Object?>[
                    jsonEncode(_surfacePayload()),
                  ])
                  as Future<Object?>)
              .timeout(const Duration(seconds: 1));
      final result = jsonDecode(raw as String) as Map<String, Object?>;

      expect(result['widgetId'], isA<int>());
      expect(await database.getAllWidgets(), hasLength(1));
      final request = await pendingClient.request.timeout(
        const Duration(seconds: 1),
      );
      final surface = Map<String, Object?>.from(request.body['surface'] as Map);
      pendingClient.complete(
        _ok(<String, Object?>{
          'gameId': 'game_delayed',
          'clientSurfaceId': request.pathSegments.last,
          'revisionNo': 1,
          'sourceSha256': _sourceSha(surface),
          'published': false,
        }),
      );
      final synced = await _waitForCloudState(
        database,
        AgentGameSyncState.synced,
      );
      expect(synced.gameId, 'game_delayed');
    },
  );

  testWidgets('Surface portal renders an optional share control', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SurfacePortalStage(
          title: 'Orbit Game',
          onClose: () {},
          trailing: const SizedBox(key: ValueKey<String>('game-share')),
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );

    expect(find.byKey(const ValueKey<String>('game-share')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingShareGateway implements AgentGameShareGateway {
  String text = '';

  @override
  Future<bool> share({
    required String title,
    required String text,
    Rect? origin,
  }) async {
    this.text = text;
    return true;
  }
}

class _PendingClient extends http.BaseClient {
  final _request = Completer<_CapturedRequest>();
  final _response = Completer<http.Response>();

  Future<_CapturedRequest> get request => _request.future;

  void complete(http.Response response) => _response.complete(response);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final body = Map<String, Object?>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    _request.complete(
      _CapturedRequest(pathSegments: request.url.pathSegments, body: body),
    );
    final response = await _response.future;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

class _NeverClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

class _CapturedRequest {
  const _CapturedRequest({required this.pathSegments, required this.body});

  final List<String> pathSegments;
  final Map<String, Object?> body;
}

AgentWidget _gameWidget() => AgentWidget(
  agentId: 'self',
  title: 'Orbit Game',
  kind: 'surface',
  spec: <String, Object?>{
    'surfaceId': 'surface_7',
    'appletLocal': <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': 'test-scope',
    },
    'surfaceKind': 'fullscreen',
    'experienceType': 'game',
    'rendering': 'workerCanvas',
    'html': '',
    'css': '',
    'js': _workerGameJs,
    'transparent': false,
    'placement': <String, Object?>{'x': 0, 'y': 0, 'width': 1, 'height': 1},
    'manifest': <String, Object?>{
      'actions': <Object?>[
        <String, Object?>{'name': 'pulse', 'schema': <String, Object?>{}},
      ],
    },
    'backend': <String, Object?>{
      'collections': <Object?>['scores'],
    },
    'revisions': <Object?>[
      <String, Object?>{
        'id': 'rev_1',
        'html': '<canvas id="old"></canvas>',
        'css': '',
        'js': '',
      },
    ],
  },
  createdAt: DateTime(2026, 8, 7),
);

AgentWidget _webAppWidget() => AgentWidget(
  agentId: 'self',
  title: 'Web Orbit',
  kind: 'surface',
  spec: <String, Object?>{
    'surfaceId': 'surface_web_7',
    'appletLocal': <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': 'test-scope',
    },
    'surfaceKind': 'fullscreen',
    'experienceType': 'game',
    'rendering': 'webApp',
    'html': '''
<main id="game" class="game-shell">
  <button id="play" type="button">Play</button>
  <canvas id="stage" width="320" height="480"></canvas>
</main>
''',
    'css': '''
.game-shell{display:grid;min-height:100vh;background:#10131a;color:white}
#stage{width:100%;height:100%}
''',
    'js': '''
const play = document.querySelector('#play');
const stage = document.querySelector('#stage');
const context = stage.getContext('2d');
let history = [];
play.addEventListener('click', async () => {
  await Promise.resolve();
  const rect = stage.getBoundingClientRect();
  history = [];
  history.push({x: 8, y: rect.top});
  window.requestAnimationFrame(() => context.fillRect(8, rect.top, 24, 24));
});
''',
    'transparent': false,
    'placement': <String, Object?>{'x': 0, 'y': 0, 'width': 1, 'height': 1},
    'manifest': <String, Object?>{
      'events': <Object?>[],
      'actions': <Object?>[],
    },
    'backend': <String, Object?>{},
    'revisions': <Object?>[],
  },
  createdAt: DateTime(2026, 8, 15),
);

Map<String, Object?> _surfacePayload() => <String, Object?>{
  'title': 'Orbit Game',
  'experienceType': 'game',
  'surface': 'fullscreen',
  'rendering': 'workerCanvas',
  'html': '',
  'css': '',
  'js': _workerGameJs,
  'manifest': <String, Object?>{
    'actions': <Object?>[
      <String, Object?>{'name': 'pulse', 'schema': <String, Object?>{}},
    ],
  },
};

const String _workerGameJs = '''
Game.define({
  init({width,height,dpr}) { return {x: width / 2, y: height / 2}; },
  update(state, frame) { return state; },
  draw(state, frame) {
    return [
      {type: 'clear', color: '#10131a'},
      {type: 'circle', x: state.x, y: state.y, r: 12, fillColor: '#66ddff'}
    ];
  },
  input(state, event) { return state; }
});
''';

http.Response _ok(Map<String, Object?> data) {
  final responseData = <String, Object?>{...data};
  if (responseData.containsKey('clientSurfaceId')) {
    responseData.putIfAbsent('experienceType', () => 'game');
  }
  return http.Response(
    jsonEncode(<String, Object?>{'code': 'OK', 'data': responseData}),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

String _sourceSha(Map<String, Object?> surface) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonicalize(surface),
        ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029'),
      ),
    )
    .toString();

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries) entry.key: _canonicalize(entry.value),
    };
  }
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  return value;
}

Future<AgentGameCloudMetadata> _waitForCloudState(
  DBService database,
  AgentGameSyncState expected,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final saved = (await database.getAllWidgets()).single;
    final metadata = AgentGameCloudMetadata.fromSpec(saved.spec['cloud']);
    if (metadata.syncState == expected) return metadata;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Timed out waiting for Agent game cloud state $expected');
}
