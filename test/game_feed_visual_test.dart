import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/data/game_document_loader.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_frost_chrome.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  for (final scenario in [
    (name: 'phone-375x812', size: const Size(375, 812), scale: 1.0),
    (
      name: 'landscape-812x375-large-text',
      size: const Size(812, 375),
      scale: 2.0,
    ),
  ]) {
    testWidgets('game feed cover and shared frost ${scenario.name}', (
      tester,
    ) async {
      await appServices.reset();
      appServices.testMode = true;
      addTearDown(() async {
        GameDocumentLoader.debugClientFactory = null;
        GameScreenshotStore.debugClientFactory = null;
        GameScreenshotPreview.clearCache();
        await appServices.reset();
      });
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      appServices.put<SecureStorageService>(SecureStorageService());
      appServices.put<AppEnvironmentService>(_VisualEnvironment());
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: scenario.name,
      );
      appServices.put<DBService>(db);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.gameFeedItems.assign(
        AppletCatalogItem(
          id: 'ag_cover_fixture',
          title: 'Neon Snake',
          type: AppletCatalogType.game,
          summary: 'Find a rhythm. Grow your score.',
          author: const AppletCatalogAuthor(
            agentId: 'agent_fixture',
            displayName: 'Demo',
            verified: false,
          ),
          shareUrl: Uri.parse('https://games.example/g/snake'),
          updatedAt: DateTime.utc(2026, 9, 15),
          viewCount: 1024,
          likeCount: 82,
        ),
      );
      final cover = await tester.runAsync(_coverFixture);
      GameScreenshotStore.debugClientFactory = () => MockClient(
        (_) async => http.Response.bytes(
          cover!,
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      var documentRequests = 0;
      GameDocumentLoader.debugClientFactory = () => MockClient((_) async {
        documentRequests++;
        return http.Response('', 500);
      });
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final font = File('/System/Library/Fonts/Supplemental/Arial.ttf');
        if (await font.exists()) {
          final loader = FontLoader('GameVisualTest')
            ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            );
          await loader.load();
        }
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'GameVisualTest'),
          home: MediaQuery(
            data: MediaQueryData(
              size: scenario.size,
              textScaler: TextScaler.linear(scenario.scale),
            ),
            child: RepaintBoundary(key: boundary, child: const GameFeedPage()),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(Image), findsOneWidget);
      await tester.runAsync(() async {
        final image = tester.widget<Image>(find.byType(Image)).image;
        await precacheImage(image, tester.element(find.byType(Image)));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.renderObject<RenderImage>(find.byType(RawImage)).image,
        isNotNull,
      );
      expect(find.byType(SurfaceWebView), findsNothing);
      expect(documentRequests, 0);
      expect(find.byKey(GameFrostGroup.blurKey), findsOneWidget);
      final railFilters = find.descendant(
        of: find.byKey(GameFrostGroup.blurKey),
        matching: find.byType(BackdropFilter),
      );
      expect(railFilters, findsNWidgets(4));
      final samplers = tester.renderObjectList<RenderBackdropFilter>(
        railFilters,
      );
      expect(
        samplers.map((sampler) => sampler.backdropKey).toSet(),
        hasLength(1),
      );
      expect(samplers.first.backdropKey, isNotNull);
      for (final sampler in samplers) {
        expect(sampler.size, const Size.square(48));
        expect(sampler.parent, isA<RenderClipRRect>());
      }
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('MAASO_CAPTURE_GAME_FEED')) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final output = File(
            'build/verification/game-cover-feed-20260915/${scenario.name}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

class _VisualEnvironment extends AppEnvironmentService {
  @override
  Uri get baseUri => Uri.parse('https://games.example/');
}

/// A controlled image fixture, not a snapshot of a user's published game.
Future<Uint8List> _coverFixture() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 480, 640),
    Paint()..color = const Color(0xFF092322),
  );
  final grid = Paint()
    ..color = const Color(0xFF164541)
    ..strokeWidth = 1;
  for (var x = 0.0; x <= 480; x += 32) {
    canvas.drawLine(Offset(x, 0), Offset(x, 640), grid);
  }
  for (var y = 0.0; y <= 640; y += 32) {
    canvas.drawLine(Offset(0, y), Offset(480, y), grid);
  }
  const body = [
    Offset(96, 352),
    Offset(128, 352),
    Offset(160, 352),
    Offset(192, 352),
    Offset(192, 320),
    Offset(192, 288),
    Offset(224, 288),
    Offset(256, 288),
  ];
  for (final segment in body) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(segment.dx + 3, segment.dy + 3, 27, 27),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xFF5EF0B2),
    );
  }
  canvas.drawCircle(
    const Offset(335, 240),
    12,
    Paint()..color = const Color(0xFFF58363),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(480, 640);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}
