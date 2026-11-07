import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:maaso/src/offline/original_ui_local_catalog.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AppEnvironmentService environment;
  late AuthSessionService auth;
  late LocaleConfigService locale;
  late http.Client rejectingHttp;
  late int requests;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_MemoryStorage());
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    requests = 0;
    rejectingHttp = MockClient((_) async {
      requests++;
      throw StateError('No backend request is permitted');
    });
    auth = appServices.put(AuthSessionService(httpClient: rejectingHttp));
    await auth.init();
    auth.session.value = MaasoAuthSession(
      accountUuid: 'local-test',
      accessToken: 'local-session',
      refreshToken: 'local-refresh',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    locale = appServices.put(LocaleConfigService());
    database = appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'original-local-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
  });
  tearDown(appServices.reset);

  AppletCatalogService catalog() => AppletCatalogService(
    environment: environment,
    auth: auth,
    locale: locale,
    httpClient: rejectingHttp,
    localEdition: true,
  );

  AgentGameCloudService games({AgentGameShareGateway? share}) =>
      AgentGameCloudService(
        database: database,
        httpClient: rejectingHttp,
        localEdition: true,
        baseUri: () => environment.baseUri,
        accountScope: AppletLocalOwnership.currentScopeKey,
        shareGateway: share,
      );

  test(
    'original services sync, publish, reopen and remove local source without HTTP',
    () async {
      final widget = _game('snake');
      AppletLocalOwnership.stamp(widget);
      await database.saveAgentWidget(widget);
      final service = games();
      final synced = await service.syncNewBeforePresent(widget);
      expect(synced.syncState, AgentGameSyncState.synced);
      expect(synced.revisionNo, 1);
      final published = await service.publish(widget);
      expect(published.isCurrentPublished, isTrue);
      expect(published.shareUrl, isEmpty);
      final client = catalog();
      final page = await client.browse(type: AppletCatalogType.game);
      expect(page.items.single.title, 'Game snake');
      expect(page.items.single.shareUrl.scheme, 'maaso-local');
      final mine = await client.mine();
      expect(mine.items.single.published, isTrue);
      final document = await client.source(
        page.items.single.id,
        expectedContextKey: client.requestContextKey,
      );
      expect(document.surface['html'], widget.spec['html']);
      final versions = await service.listVersions(widget);
      expect(versions.items.single.revisionNo, 1);
      final historical = await service.revisionSource(widget, 1);
      expect(historical.sourceSha256, document.sourceSha256);
      await service.unpublish(widget);
      expect((await client.mine()).items.single.published, isFalse);
      await service.deleteRemote(widget);
      expect(await database.getAllWidgets(), isEmpty);
      expect(requests, 0);
    },
  );

  test(
    'local Hub keeps more than five works and scoped search pagination',
    () async {
      for (var i = 0; i < 7; i++) {
        final widget = _game('snake-$i');
        AppletLocalOwnership.stamp(widget);
        await database.saveAgentWidget(widget);
      }
      final other = _game('other');
      AppletLocalOwnership.stamp(other, scopeKey: 'other-account');
      await database.saveAgentWidget(other);
      final service = catalog();
      expect((await service.mine()).items.length, 7);
      expect((await service.quota()).remaining, greaterThan(0));
      final first = await service.search(query: 'snake', limit: 3);
      expect(first.items.length, 3);
      final second = await service.search(
        query: 'snake',
        limit: 3,
        cursor: first.nextCursor,
      );
      expect(second.items.length, 3);
      expect(
        first.items
            .map((e) => e.id)
            .toSet()
            .intersection(second.items.map((e) => e.id).toSet()),
        isEmpty,
      );
      final source = await service.source(
        first.items.first.id,
        expectedContextKey: service.requestContextKey,
      );
      expect(source.surface['html'], contains('button'));
      expect(requests, 0);
    },
  );

  test(
    'likes, comments and view deduplication persist in mounted local DB',
    () async {
      final widget = _game('snake');
      AppletLocalOwnership.stamp(widget);
      await database.saveAgentWidget(widget);
      final service = catalog();
      final item = (await service.browse(
        type: AppletCatalogType.game,
      )).items.single;
      final context = service.requestContextKey;
      expect(
        (await service.setLiked(
          item.id,
          true,
          expectedContextKey: context,
        )).likeCount,
        1,
      );
      await service.recordView(
        item.id,
        eventId: 'view-one',
        expectedContextKey: context,
      );
      await service.recordView(
        item.id,
        eventId: 'view-one',
        expectedContextKey: context,
      );
      final comment = await service.postComment(
        item.id,
        '本地评论',
        expectedContextKey: context,
      );
      expect(
        (await service.listComments(
          item.id,
          expectedContextKey: context,
        )).items.single.text,
        '本地评论',
      );
      expect(comment.displayName, 'Test User');
      final restored = await catalog().getEngagement(
        item.id,
        expectedContextKey: context,
      );
      expect(restored.likedByMe, isTrue);
      expect(restored.viewCount, 1);
      expect(restored.commentCount, 1);
      expect(requests, 0);
    },
  );

  test(
    'local sharing sends authored source, never a fictitious hosted URL',
    () async {
      final widget = _game('snake');
      AppletLocalOwnership.stamp(widget);
      await database.saveAgentWidget(widget);
      final share = _Share();
      expect(await games(share: share).publishAndShare(widget), isTrue);
      expect(share.text, contains(widget.spec['html']));
      expect(share.text, isNot(contains(environment.baseUri.origin)));
      expect(requests, 0);
    },
  );

  test(
    'local repository rejects an account change before mutating source',
    () async {
      var scope = 'account-one';
      final repo = OriginalUiLocalCatalog(
        database: database,
        scopeKey: () => scope,
      );
      scope = 'account-two';
      await expectLater(
        repo.mutateGame(
          Uri.parse('https://unused.invalid/v1/agent-games/by-client/game'),
          {'surface': {}},
          expectedScope: 'account-one',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'local catalog cover resolves the original saved-game screenshot identity',
    () async {
      final widget = _game('snake');
      AppletLocalOwnership.stamp(widget);
      await database.saveAgentWidget(widget);
      final client = appServices.put(catalog());
      final item = (await client.browse(
        type: AppletCatalogType.game,
      )).items.single;
      final fromCatalog = await GameScreenshotSource.resolve(
        identity: 'catalog',
        revision: 'same',
        shareUrl: item.shareUrl,
      );
      final fromLocal = await GameScreenshotSource.resolve(
        identity: 'saved',
        revision: 'same',
        localItem: widget,
      );
      expect(fromCatalog, isNotNull);
      expect(fromCatalog!.cacheKey, fromLocal!.cacheKey);
      expect(fromCatalog.localItem!.id, widget.id);
      expect(requests, 0);
    },
  );

  test(
    'editing a locally listed work preserves its previously listed revision',
    () async {
      final scope = AppletLocalOwnership.currentScopeKey();
      final repo = OriginalUiLocalCatalog(
        database: database,
        scopeKey: AppletLocalOwnership.currentScopeKey,
      );
      final uri = environment.baseUri.resolve(
        'v1/agent-games/by-client/local-edit',
      );
      final source = {'html': '<main>v1</main>'};
      final first = await repo.mutateGame(uri, {
        'title': 'Game',
        'experienceType': 'game',
        'surface': source,
      }, expectedScope: scope);
      await repo.mutateGame(
        environment.baseUri.resolve(
          'v1/agent-games/${first['gameId']}/publish',
        ),
        {},
        expectedScope: scope,
      );
      final edited = await repo.mutateGame(uri, {
        'title': 'Game',
        'experienceType': 'game',
        'surface': {'html': '<main>v2</main>'},
      }, expectedScope: scope);
      expect(edited['revisionNo'], 2);
      expect(edited['published'], isFalse);
      expect(edited['hasPublished'], isTrue);
      expect(edited['publishedRevisionNo'], 1);
      expect(edited['publishedSourceSha256'], first['sourceSha256']);
      expect(requests, 0);
    },
  );

  test(
    'original model store lists bundled mode without contacting catalog',
    () async {
      final session = auth.session.value!;
      final scope = AccountStorageScope(
        environmentKey: environment.environment.value.key,
        accountUuid: session.accountUuid,
      );
      final scopes = AccountStorageScopeService();
      final mount = scopes.mount(scope);
      final service = AvatarModelCatalogService(
        accountSession: session,
        accountMount: mount,
        agentScope: scope.agent('self'),
        storageScopes: scopes,
        httpClient: rejectingHttp,
        localEdition: true,
      );
      expect(await service.listApprovedModels(), isEmpty);
      expect(await service.listMyUploads(), isEmpty);
      expect(requests, 0);
      service.onClose();
    },
  );
}

AgentWidget _game(String id) => AgentWidget(
  agentId: 'self',
  title: 'Game $id',
  kind: 'surface',
  createdAt: DateTime.utc(2026, 11, 7),
  spec: {
    'surfaceId': id,
    'surfaceKind': 'fullscreen',
    'experienceType': 'game',
    'rendering': 'webApp',
    'html': '<main><button>Play</button></main>',
    'css': 'main{color:white;background:black}',
    'js': 'console.log("ready");',
    'transparent': false,
    'manifest': {'actions': [], 'events': []},
    'backend': {},
    'revisions': [],
  },
);

class _Share implements AgentGameShareGateway {
  String text = '';
  @override
  Future<bool> share({
    required String title,
    required String text,
    dynamic origin,
  }) async {
    this.text = text;
    return true;
  }
}

class _MemoryStorage extends SecureStorageService {
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
