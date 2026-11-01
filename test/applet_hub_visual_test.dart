import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

void main() {
  for (final scenario in [
    (name: 'hub-light', mine: false, brightness: Brightness.light, scale: 1.0),
    (name: 'mine-light', mine: true, brightness: Brightness.light, scale: 1.0),
    (
      name: 'mine-dark-large-text',
      mine: true,
      brightness: Brightness.dark,
      scale: 2.0,
    ),
  ]) {
    testWidgets('applet visual ${scenario.name}', (tester) async {
      await appServices.reset();
      appServices.testMode = true;
      final previousLocale = AppLocalization.locale;
      AppLocalization.updateLocale(const Locale('zh'));
      addTearDown(() async {
        AppLocalization.updateLocale(previousLocale);
        await appServices.reset();
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final local = AgentWidget(
        id: 7,
        agentId: 'self',
        title: '厦门三日旅行',
        kind: 'surface',
        subtitle: '按预算安排路线、交通和每日行程',
        spec: {
          'surfaceId': 'trip',
          'experienceType': 'utility',
          'category': 'travel',
        },
        createdAt: DateTime.utc(2026),
      );
      appServices.put<DBService>(_DB([local]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.appletDiscoveryItems.assignAll([
        _item('trip', '旅行规划助手', '根据目的地与出行天数，定制你的旅行计划', 'travel', 128),
        _item('budget', '旅行预算', '记录住宿、交通和餐饮，轻松掌握旅行开销', 'travel', 86),
        _item('timer', '专注计时', '安排专注时段，记录今天的完成进度', 'tools', 42),
      ]);
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final font = File('/System/Library/Fonts/STHeiti Light.ttc');
        if (await font.exists()) {
          await (FontLoader('AppletVisual')..addFont(
                Future.value(ByteData.sublistView(await font.readAsBytes())),
              ))
              .load();
        }
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme:
              AppTheme.build(
                AppPalette.of(scenario.brightness, AppAccent.blue),
              ).copyWith(
                textTheme: ThemeData(
                  brightness: scenario.brightness,
                  fontFamily: 'AppletVisual',
                ).textTheme,
              ),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(390, 844),
              padding: const EdgeInsets.only(top: 44, bottom: 24),
              textScaler: TextScaler.linear(scenario.scale),
            ),
            child: RepaintBoundary(
              key: boundary,
              child: scenario.mine
                  ? const MyAppletsPage()
                  : const WidgetsHubPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('MAASO_CAPTURE_APPLETS')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final output = File(
            'build/verification/applet-hub-20260916/${scenario.name}.png',
          );
          await output.parent.create(recursive: true);
          await output.writeAsBytes(data!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

AppletCatalogItem _item(
  String id,
  String title,
  String summary,
  String category,
  int likes,
) => AppletCatalogItem(
  id: id,
  title: title,
  summary: summary,
  category: category,
  type: AppletCatalogType.applet,
  likeCount: likes,
  author: const AppletCatalogAuthor(
    agentId: 'aa_0123456789abcdef0123456789abcdef',
    displayName: 'Agent A',
    verified: false,
  ),
  shareUrl: Uri.parse('https://example.test/g/$id'),
  updatedAt: DateTime.utc(2026),
);

class _DB extends DBService {
  _DB(this.items);
  final List<AgentWidget> items;
  @override
  Future<List<AgentWidget>> getAllWidgets() async => items;
}
