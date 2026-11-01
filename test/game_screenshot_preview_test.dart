import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as images;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:sembast/sembast_memory.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AppEnvironmentService environment;
  late Uint8List png;
  late Uint8List jpeg;
  var serial = 0;
  final covers = stringMapStoreFactory.store('game_covers.v1');
  final requests = <http.BaseRequest>[];
  final clients = <_CoverClient>[];
  late Future<http.StreamedResponse> Function(http.BaseRequest) reply;
  Uri share(String id) => Uri.parse('https://api-test.futurpals.com.cn/g/$id');
  Future<GameScreenshotSource?> publicSource(
    String id, {
    String revision = 'r1',
  }) => GameScreenshotSource.resolve(
    identity: id,
    revision: revision,
    shareUrl: share(id),
  );
  Future<GameScreenshotSource?> localSource(AgentWidget item) =>
      GameScreenshotSource.resolve(
        identity: 'local-${item.id}',
        revision: 'same-created-at',
        localItem: item,
      );
  Future<bool> record(AgentWidget item, {Uint8List? image}) =>
      GameScreenshotStore.captureOpenedPlayer(
        identity: 'local',
        revision: 'same-created-at',
        localItem: item,
        capture: () async => image ?? png,
        isCurrent: () => true,
      );
  http.StreamedResponse response({
    List<int>? image,
    int status = 200,
    String mime = 'image/png',
    int? contentLength,
  }) => http.StreamedResponse(
    Stream.value(image ?? png),
    status,
    headers: {'content-type': mime, 'cache-control': 'no-store'},
    contentLength: contentLength,
  );

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await appServices.reset();
    appServices.testMode = true;
    appServices.put(SecureStorageService());
    environment = appServices.put(AppEnvironmentService());
    database = appServices.put(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'static-game-covers-${serial++}.db',
      ),
    );
    final image = images.fill(
      images.Image(width: 4, height: 3),
      color: images.ColorRgba8(40, 90, 180, 255),
    );
    png = images.encodePng(image);
    jpeg = images.encodeJpg(image);
    requests.clear();
    clients.clear();
    reply = (_) async => response(status: 404);
    GameScreenshotStore.debugClientFactory = () {
      final client = _CoverClient((request) {
        requests.add(request);
        return reply(request);
      });
      clients.add(client);
      return client;
    };
    GameScreenshotPreview.clearCache();
  });
  tearDown(() async {
    GameScreenshotStore.debugClientFactory = null;
    GameScreenshotPreview.clearCache();
    await appServices.reset();
  });

  test(
    'public source trusts current origin and shares cache identity between feed and owned rows',
    () async {
      final first = (await publicSource('a'))!;
      final owned = (await GameScreenshotSource.resolve(
        identity: 'cloud-inventory-a',
        revision: 'r1',
        shareUrl: share('a'),
      ))!;
      expect(owned.cacheKey, first.cacheKey);
      expect(
        (await publicSource('a', revision: 'r2'))!.cacheKey,
        isNot(first.cacheKey),
      );
      for (final url in [
        'http://api-test.futurpals.com.cn/g/a',
        'https://evil.example/g/a',
        '${share('a')}?token=x',
        '${share('a')}#part',
        '${share('a')}/embed',
        'https://u:p@api-test.futurpals.com.cn/g/a',
      ]) {
        expect(
          await GameScreenshotSource.resolve(
            identity: 'a',
            revision: '1',
            shareUrl: Uri.parse(url),
          ),
          isNull,
          reason: url,
        );
      }
      environment.environment.value = MaasoEnvironment.production;
      expect(
        first.isCurrent,
        isFalse,
        reason: 'device-legacy account still separates environment',
      );
      expect(await GameScreenshotStore.load(first), isNull);
      expect(requests, isEmpty);
    },
  );

  test(
    'local cover identity follows persisted content and admits safe DOM games',
    () async {
      final item = _game();
      await database.saveAgentWidget(item);
      final first = (await localSource(item))!;
      await database.updateWidgetSpecField(
        item.id!,
        'js',
        _gameJs.replaceAll('#3267CC', '#CC6732'),
      );
      expect(await localSource(item), isNull);
      final updated = (await database.getAllWidgets()).single;
      expect((await localSource(updated))!.cacheKey, isNot(first.cacheKey));
      expect(updated.createdAt, item.createdAt);
      final domGame = _game(id: 'dom-game')
        ..spec.addAll({
          'rendering': 'webApp',
          'html': '<button id="score">Score 0</button>',
          'css': 'button{width:100px;height:100px}',
          'js':
              'let count=0;document.getElementById("score").addEventListener("click",function(){this.textContent="Score "+(++count);});',
        });
      await database.saveAgentWidget(domGame);
      expect(await localSource(domGame), isNotNull);
      await database.deleteWidget(item.id!);
      expect(await GameScreenshotStore.load(first), isNull);
    },
  );

  test(
    'hidden, foreign, deleted, legacy and unsafe projects cannot expose covers',
    () async {
      for (final extra in <Map<String, Object?>>[
        {'presentationPending': true},
        {
          'cloudDelete': {'pending': true},
        },
        {'js': 'fetch("https://evil.example");'},
        {'experienceType': 'utility'},
      ]) {
        final item = _game()..spec.addAll(extra);
        await database.saveAgentWidget(item);
        expect(await localSource(item), isNull, reason: '$extra');
      }
      final foreign = _game();
      AppletLocalOwnership.stamp(foreign, scopeKey: 'another-account');
      await database.saveAgentWidget(foreign);
      expect(await localSource(foreign), isNull);
      final legacy = _game()..kind = 'widget';
      await database.saveAgentWidget(legacy);
      expect(await localSource(legacy), isNull);
      expect(await localSource(_game()), isNull);
    },
  );

  test(
    'image admission decodes bounded real PNG and JPEG, rejects corrupt or oversized data',
    () async {
      expect(await GameScreenshotSource.validateImage(png), same(png));
      expect(await GameScreenshotSource.validateImage(jpeg), same(jpeg));
      expect(await GameScreenshotSource.validateImage(Uint8List(30)), isNull);
      expect(
        await GameScreenshotSource.validateImage(png.sublist(0, 24)),
        isNull,
      );
      expect(
        await GameScreenshotSource.validateImage(jpeg.sublist(0, 24)),
        isNull,
      );
      expect(
        await GameScreenshotSource.validateImage(
          Uint8List(GameScreenshotPreview.maxImageBytes + 1),
        ),
        isNull,
      );
      for (final width in [640, 641]) {
        final image = images.encodePng(images.Image(width: width, height: 1));
        expect(
          await GameScreenshotSource.validateImage(image),
          width == 640 ? isNotNull : isNull,
        );
      }
    },
  );

  test(
    'actual-open local snapshot survives memory eviction without any network',
    () async {
      final item = _game();
      await database.saveAgentWidget(item);
      expect(await record(item, image: jpeg), isTrue);
      expect(await covers.count(database.raw), 1);
      GameScreenshotPreview.clearCache();
      expect(
        await GameScreenshotStore.load((await localSource(item))!),
        orderedEquals(jpeg),
      );
      var snapshots = 0;
      expect(
        await GameScreenshotStore.captureOpenedPlayer(
          identity: 'same-game-new-row',
          revision: 'anything',
          localItem: item,
          capture: () async {
            snapshots++;
            return png;
          },
          isCurrent: () => true,
        ),
        isTrue,
      );
      expect(snapshots, 0);
      expect(requests, isEmpty);
    },
  );

  test('persistent and memory storage remain bounded', () async {
    AgentWidget? first;
    for (var index = 0; index <= GameScreenshotStore.maxEntries; index++) {
      final item = _game(id: 'game-$index');
      await database.saveAgentWidget(item);
      first ??= item;
      expect(await record(item), isTrue);
    }
    expect(await covers.count(database.raw), GameScreenshotStore.maxEntries);
    expect(
      await GameScreenshotStore.load((await localSource(first!))!),
      isNull,
    );
  });

  test(
    'persisted local cover validates bytes again instead of trusting storage',
    () async {
      final item = _game();
      await database.saveAgentWidget(item);
      final source = (await localSource(item))!;
      await covers.record(source.cacheKey).put(database.raw, {
        'schemaVersion': 1,
        'image': base64Encode(Uint8List(30)),
        'savedAt': 1,
      });
      expect(await GameScreenshotStore.load(source), isNull);
      await covers.record(source.cacheKey).put(database.raw, {
        'schemaVersion': 1,
        'image': '<invalid-base64>',
        'savedAt': 1,
      });
      expect(await GameScreenshotStore.load(source), isNull);
    },
  );

  test(
    'snapshot is never requested when the player is absent or in background',
    () async {
      var snapshots = 0;
      final item = _game();
      await database.saveAgentWidget(item);
      Future<bool> capture(bool current) =>
          GameScreenshotStore.captureOpenedPlayer(
            identity: 'a',
            revision: 'r1',
            localItem: item,
            capture: () async {
              snapshots++;
              return png;
            },
            isCurrent: () => current,
          );
      expect(await capture(false), isFalse);
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await capture(true), isFalse);
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(snapshots, 0);
      expect(await covers.count(database.raw), 0);
    },
  );

  test(
    'late snapshot after route change, environment switch or deletion is discarded',
    () async {
      for (final change in ['route', 'environment', 'delete', 'revision']) {
        var current = true;
        final item = _game();
        await database.saveAgentWidget(item);
        final started = Completer<void>();
        final gate = Completer<Uint8List?>();
        final capture = GameScreenshotStore.captureOpenedPlayer(
          identity: 'local',
          revision: '1',
          localItem: item,
          capture: () {
            started.complete();
            return gate.future;
          },
          isCurrent: () => current,
        );
        await started.future;
        switch (change) {
          case 'route':
            current = false;
          case 'environment':
            environment.environment.value = MaasoEnvironment.production;
          case 'delete':
            await database.deleteWidget(item.id!);
          case 'revision':
            await database.updateWidgetSpecField(
              item.id!,
              'js',
              _gameJs.replaceAll('#3267CC', '#CC6732'),
            );
        }
        gate.complete(png);
        expect(await capture, isFalse, reason: change);
        expect(await covers.count(database.raw), 0, reason: change);
        environment.environment.value = MaasoEnvironment.test;
      }
    },
  );

  test(
    'published thumbnail request is exact image endpoint with redirects disabled',
    () async {
      reply = (_) async => response(image: jpeg, mime: 'image/jpeg');
      final source = (await publicSource('a'))!;
      expect(await GameScreenshotStore.load(source), orderedEquals(jpeg));
      expect(requests.single.url, Uri.parse('${share('a')}/cover'));
      expect(requests.single.followRedirects, isFalse);
      expect(requests.single.headers.containsKey('authorization'), isFalse);
      expect(clients.single.closed, isTrue);
      expect(await covers.count(database.raw), 1);
    },
  );

  test(
    'public cover withdrawal or unavailable origin cannot reuse saved pixels',
    () async {
      final source = (await publicSource('a'))!;
      reply = (_) async => response();
      expect(await GameScreenshotStore.load(source), isNotNull);
      for (final status in [404, 503, 302]) {
        reply = (_) async => response(status: status);
        expect(
          await GameScreenshotStore.load(source),
          isNull,
          reason: '$status',
        );
        expect(await covers.count(database.raw), 0);
      }
      reply = (_) async => throw http.ClientException('offline');
      expect(await GameScreenshotStore.load(source), isNull);
    },
  );

  test(
    'wrong mime, mismatched signature, oversized body and invalid dimensions are rejected',
    () async {
      final source = (await publicSource('a'))!;
      final responses = [
        response(mime: 'text/html'),
        response(image: png, mime: 'image/jpeg'),
        response(contentLength: GameScreenshotPreview.maxImageBytes + 1),
        response(image: Uint8List(GameScreenshotPreview.maxImageBytes + 1)),
        response(image: images.encodePng(images.Image(width: 641, height: 1))),
      ];
      for (final result in responses) {
        reply = (_) async => result;
        expect(await GameScreenshotStore.load(source), isNull);
      }
      expect(clients.every((client) => client.closed), isTrue);
      expect(await covers.count(database.raw), 0);
    },
  );

  test(
    'late server response after environment switch cannot write or display a cover',
    () async {
      final started = Completer<void>();
      final gate = Completer<http.StreamedResponse>();
      reply = (_) {
        started.complete();
        return gate.future;
      };
      final loading = GameScreenshotStore.load((await publicSource('a'))!);
      await started.future;
      environment.environment.value = MaasoEnvironment.production;
      gate.complete(response());
      expect(await loading, isNull);
      expect(await covers.count(database.raw), 0);
      expect(clients.single.closed, isTrue);
    },
  );

  testWidgets(
    'stalled thumbnail requests close their client and discard late pixels',
    (tester) async {
      final gate = Completer<http.StreamedResponse>();
      reply = (_) => gate.future;
      await tester.pumpWidget(
        _page(
          GameScreenshotPreview(
            identity: 'a',
            revision: 'r1',
            title: 'Snake',
            shareUrl: share('a'),
          ),
        ),
      );
      await _until(tester, () => requests.isNotEmpty);
      await tester.pump(const Duration(seconds: 9));
      expect(clients.single.closed, isTrue);
      expect(find.byType(Image), findsNothing);
      gate.complete(response());
      await tester.pumpAndSettle();
      final count = await tester.runAsync(() => covers.count(database.raw));
      expect(count, 0);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'stalled opened-player snapshot times out without writing a late result',
    (tester) async {
      final item = _game();
      await tester.runAsync(() => database.saveAgentWidget(item));
      var started = false;
      final gate = Completer<Uint8List?>();
      final saving = GameScreenshotStore.captureOpenedPlayer(
        identity: 'a',
        revision: 'r1',
        localItem: item,
        capture: () {
          started = true;
          return gate.future;
        },
        isCurrent: () => true,
      );
      await _until(tester, () => started);
      await tester.pump(const Duration(seconds: 4));
      expect(await saving, isFalse);
      gate.complete(png);
      await tester.pumpAndSettle();
      final count = await tester.runAsync(() => covers.count(database.raw));
      expect(count, 0);
    },
  );

  testWidgets(
    'missing cover stays dark and browsing never constructs any WebView',
    (tester) async {
      final platform = _NoPreviewPlayersPlatform();
      WebViewPlatform.instance = platform;
      await tester.pumpWidget(
        _page(
          GameScreenshotPreview(
            identity: 'a',
            revision: 'r1',
            title: 'Snake',
            shareUrl: share('a'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.createdPlayers, 0);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(
        find.byKey(const ValueKey('game-static-cover-placeholder')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ColoredBox>(
              find
                  .descendant(
                    of: find.byType(GameScreenshotPreview),
                    matching: find.byType(ColoredBox),
                  )
                  .first,
            )
            .color,
        MaasoFrostTokens.darkCanvas,
      );
      expect(
        requests.every((request) => request.url.path.endsWith('/cover')),
        isTrue,
      );
      expect(find.text('game_feed.preview_unavailable'.tr), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first public visit loads a thumbnail without waiting for gameplay',
    (tester) async {
      final platform = _NoPreviewPlayersPlatform();
      WebViewPlatform.instance = platform;
      reply = (_) async => response();
      await tester.pumpWidget(
        _page(
          GameScreenshotPreview(
            identity: 'a',
            revision: 'r1',
            title: 'Snake',
            shareUrl: share('a'),
          ),
        ),
      );
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(platform.createdPlayers, 0);
      expect(requests.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local cover appears after gameplay then reloads persisted pixels',
    (tester) async {
      final item = _game();
      await tester.runAsync(() => database.saveAgentWidget(item));
      Widget page() => _page(
        GameScreenshotPreview(
          identity: 'a',
          revision: 'r1',
          title: 'Snake',
          localItem: item,
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      await tester.runAsync(() => record(item));
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      GameScreenshotPreview.clearCache();
      await tester.pumpWidget(page());
      await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('environment changes remove an already visible public cover', (
    tester,
  ) async {
    reply = (_) async => response();
    await tester.pumpWidget(
      _page(
        GameScreenshotPreview(
          identity: 'a',
          revision: 'r1',
          title: 'Snake',
          shareUrl: share('a'),
        ),
      ),
    );
    await _until(tester, () => find.byType(Image).evaluate().isNotEmpty);
    environment.environment.value = MaasoEnvironment.production;
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _page(Widget preview) => MaterialApp(
  home: Center(child: SizedBox(width: 180, height: 140, child: preview)),
);
Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (condition()) return;
  }
  expect(
    condition(),
    isTrue,
    reason: 'Static cover did not reach expected state',
  );
}

AgentWidget _game({String id = 'local-game'}) => AgentWidget(
  agentId: 'self',
  title: 'Actual canvas game',
  kind: 'surface',
  createdAt: DateTime.utc(2026, 9, 15),
  spec: {
    'surfaceId': id,
    'surfaceKind': 'fullScreen',
    'rendering': 'workerCanvas',
    'experienceType': 'game',
    'html': '',
    'css': '',
    'js': _gameJs,
  },
);
const _gameJs = '''
Game.define({
  init(){return {score:0};},
  update(state){return state;},
  draw(state){return [{type:'clear',color:'#3267CC'},{type:'text',text:'Score '+state.score,x:10,y:20,size:16,color:'#FFFFFF'}];},
  input(state,event){return {score:state.score+1};}
});
''';

class _NoPreviewPlayersPlatform extends WebViewPlatform {
  int createdPlayers = 0;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    createdPlayers++;
    throw StateError('Browsing must never instantiate a game player');
  }
}

class _CoverClient extends http.BaseClient {
  _CoverClient(this.reply);
  final Future<http.StreamedResponse> Function(http.BaseRequest) reply;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      reply(request);
  @override
  void close() {
    closed = true;
  }
}
