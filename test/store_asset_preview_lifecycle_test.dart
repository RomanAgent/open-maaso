import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_preview.dart';
import 'asset_store_service_test.dart' show assetJson;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Players extends VideoPlayerPlatform {
  final files = <File>[];
  final streams = <StreamController<VideoEvent>>[];
  final played = <int>[];
  final disposed = <int>[];
  Duration position = Duration.zero;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    files.add(File.fromUri(Uri.parse(options.dataSource.uri!)));
    final events = StreamController<VideoEvent>();
    streams.add(events);
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 1),
        size: const Size(512, 512),
      ),
    );
    return streams.length - 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId].stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await streams[playerId].close();
  }

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.blue);
  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Players players;
  late PathProviderPlatform oldPaths;
  late VideoPlayerPlatform oldVideo;
  late AssetStoreService service;
  late List<int> mediaBytes;
  List<int>? responseBytes;
  var downloads = 0;
  StoreAsset item() => StoreAsset.fromJson({
    ...assetJson(),
    'preview': {
      'state': 'available',
      'kind': 'video',
      'url': 'https://media.example/preview.mp4',
      'sha256': sha256.convert(mediaBytes).toString(),
    },
  });
  http.Client mediaClient() => MockClient((request) async {
    expect(request.method, 'GET');
    expect(request.url, Uri.parse('https://media.example/preview.mp4'));
    expect(request.followRedirects, false);
    expect(request.headers.containsKey('Authorization'), false);
    downloads++;
    return http.Response.bytes(responseBytes ?? mediaBytes, 200);
  });
  late Completer<void> invalidated;
  var scope = 'a';
  var views = 0;
  setUp(() async {
    appServices.testMode = true;
    root = await Directory.systemTemp.createTemp('maaso-store-preview-test-');
    oldPaths = PathProviderPlatform.instance;
    oldVideo = VideoPlayerPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    players = _Players();
    VideoPlayerPlatform.instance = players;
    scope = 'a';
    views = 0;
    invalidated = Completer<void>();
    mediaBytes = [1, 2, 3, 4];
    responseBytes = null;
    downloads = 0;
    service = AssetStoreService(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path.endsWith('/skill/wave/previews'), isTrue);
        final body = jsonDecode(request.body) as Map;
        expect(body['versionId'], '1');
        expect(body['completed'], true);
        expect(body['eventId'], isNotEmpty);
        expect(body.containsKey('previewSha256'), false);
        views++;
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'data': {'recorded': true},
          }),
          200,
        );
      }),
      baseUri: () => Uri.parse('https://local-test.invalid/'),
      token: () async => 'synthetic',
      scope: () => scope,
    );
  });
  tearDown(() async {
    service.close();
    PathProviderPlatform.instance = oldPaths;
    VideoPlayerPlatform.instance = oldVideo;
    if (await root.exists()) await root.delete(recursive: true);
    appServices.reset();
  });

  Widget page({bool reduced = false, bool hidden = false}) => MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          disableAnimations: reduced,
        ),
        child: Offstage(
          offstage: hidden,
          child: StoreAssetPreview(
            item: item(),
            service: service,
            previewClientFactory: mediaClient,
            whenInvalidated: invalidated.future,
            canContinue: () => scope == 'a',
          ),
        ),
      ),
    ),
  );
  Future<void> settleIO(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(VideoPlayer, skipOffstage: false).evaluate().isNotEmpty) {
        return;
      }
    }
    fail(
      'Native player did not initialize: files=${players.files.length}, disposed=${players.disposed}, downloads=$downloads, texts=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}',
    );
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Retirement waits for the native player's disposal before deleting the
    // directory. Drive both widget microtasks and real filesystem work until
    // the actual cleanup boundary, instead of assuming it finishes in 30 ms.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump();
      final empty = await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return (await root.list(recursive: true).toList()).every(
          (entry) =>
              entry is Directory &&
              !entry.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('asset-preview-'),
        );
      });
      if (empty == true) return;
    }
    fail('Preview retirement did not remove its native files and directories');
  }

  testWidgets(
    'visible first frame alone never counts before playback advances',
    (tester) async {
      await tester.pumpWidget(page());
      await settleIO(tester);
      expect(views, 0);
      expect(players.played, isNotEmpty);
      players.position = const Duration(milliseconds: 500);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(views, 1);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(views, 1);
      await clean(tester);
    },
  );
  testWidgets('reduced motion initializes a still frame until explicit play', (
    tester,
  ) async {
    await tester.pumpWidget(page(reduced: true));
    await settleIO(tester);
    expect(players.played, isEmpty);
    expect(views, 0);
    await tester.tap(find.byKey(const ValueKey('asset-preview-play-pause')));
    await tester.pump();
    expect(players.played, hasLength(1));
    players.position = const Duration(milliseconds: 500);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(views, 1);
    await clean(tester);
  });
  testWidgets('first preview creates a missing native cache directory', (
    tester,
  ) async {
    final cache = Directory('${root.path}/fresh-native-cache');
    PathProviderPlatform.instance = _Paths(cache.path);
    expect(cache.existsSync(), isFalse);
    await tester.pumpWidget(page());
    await settleIO(tester);
    expect(players.files, hasLength(1));
    expect(players.files.single.path, startsWith(cache.path));
    expect(cache.existsSync(), isTrue);
    await clean(tester);
    expect(await tester.runAsync(() => cache.list().toList()), isEmpty);
    expect(views, 0);
  });
  testWidgets('offstage preview neither starts nor counts a video', (
    tester,
  ) async {
    await tester.pumpWidget(page(hidden: true));
    await settleIO(tester);
    players.position = const Duration(milliseconds: 500);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(players.played, isEmpty);
    expect(views, 0);
    await clean(tester);
  });
  testWidgets(
    'account invalidation immediately disposes and removes private media',
    (tester) async {
      await tester.pumpWidget(page());
      await settleIO(tester);
      scope = 'b';
      invalidated.complete();
      await tester.pump();
      for (var i = 0; i < 20 && players.disposed.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(players.disposed, [0]);
      expect(views, 0);
      expect(await tester.runAsync(() => root.list().toList()), isEmpty);
      expect(find.byType(VideoPlayer), findsNothing);
      await clean(tester);
    },
  );
  testWidgets(
    'closing preview cancels playback and cleans verified temp bytes',
    (tester) async {
      await tester.pumpWidget(page());
      await settleIO(tester);
      await clean(tester);
      expect(players.disposed, [0]);
      expect(await tester.runAsync(() => root.list().toList()), isEmpty);
      expect(views, 0);
    },
  );
  testWidgets('mismatched HTTPS bytes never reach the native decoder', (
    tester,
  ) async {
    responseBytes = [1, 2, 3, 5];
    await tester.pumpWidget(page());
    // HTTPS response streaming adds asynchronous work beyond widget frames.
    // Wait for the actual rejection boundary before asserting decoder safety.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.text('asset_store.preview_failed'.tr).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(downloads, 1);
    expect(players.files, isEmpty);
    expect(views, 0);
    expect(find.text('asset_store.preview_failed'.tr), findsOneWidget);
    await clean(tester);
  });
}
