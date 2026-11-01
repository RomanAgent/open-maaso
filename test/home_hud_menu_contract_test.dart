import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home HUD keeps settings in the menu and task history beside it', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final hud = _classBody(
      source,
      'class _HomeHudLayerState extends State<_HomeHudLayer>',
    );

    expect(_count(hud, 'HomeStatusHeader('), 1);
    final header = File(
      'lib/src/features/home/presentation/widgets/home_status_header.dart',
    ).readAsStringSync();
    expect(_count(header, "ValueKey('home-menu-toggle')"), 1);
    expect(header, isNot(contains("ValueKey('home-wallet-button')")));
    expect(hud, isNot(contains("label: 'home.menu.wallet'")));
    expect(_count(hud, 'route: AppRouteCatalog.wallet'), 0);
    expect(hud, isNot(contains("label: 'agent_media.title'")));
    expect(_count(hud, 'route: AppRouteCatalog.agentMedia'), 0);
    expect(_count(header, "ValueKey('home-task-history-button')"), 1);
    expect(_count(hud, 'onTaskHistory: _openTaskHistory'), 1);
    expect(source, isNot(contains("ValueKey('home-menu-task-history')")));
    expect(hud, contains("label: 'settings.title'"));
    expect(_count(hud, 'route: AppRouteCatalog.settings'), 1);
    expect(header, isNot(contains('onSettings')));
    expect(header, isNot(contains("ValueKey('home-settings-button')")));
    expect(hud, contains('Icons.settings_rounded'));
    expect(hud, isNot(contains("label: 'Dashboard'")));
    expect(hud, isNot(contains('route: AppRouteCatalog.dashboard')));
    expect(hud, isNot(contains('Icons.dashboard_customize_rounded')));
  });

  test('home HUD exposes one Store hub and leaves relationship in profile', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final hud = _classBody(
      source,
      'class _HomeHudLayerState extends State<_HomeHudLayer>',
    );

    expect(_count(hud, "label: 'store_hub.marketplace'"), 1);
    expect(_count(hud, 'route: AppRouteCatalog.avatars'), 1);
    expect(_count(hud, "label: 'relationship_hub.title'"), 0);
    expect(_count(hud, 'route: AppRouteCatalog.memoryWall'), 0);
    expect(hud, isNot(contains("label: 'skills.store'")));
    expect(hud, isNot(contains("label: 'home.menu.model_store'")));
    expect(hud, isNot(contains('route: AppRouteCatalog.skillStore')));
    expect(hud, isNot(contains("label: 'moments.title'")));
    expect(hud, isNot(contains("label: 'memory.title'")));
    expect(hud, isNot(contains('route: AppRouteCatalog.moments')));
  });

  test('home HUD exposes separate Game Feed and Applets menu items', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final hud = _classBody(
      source,
      'class _HomeHudLayerState extends State<_HomeHudLayer>',
    );

    expect(_count(hud, "label: 'game_feed.title'"), 1);
    expect(_count(hud, 'route: AppRouteCatalog.gameFeed'), 1);
    expect(_count(hud, 'Icons.sports_esports_rounded'), 1);
    expect(_count(hud, "label: 'widgets.title'"), 1);
    expect(_count(hud, 'route: AppRouteCatalog.widgetsHub'), 1);
    expect(_count(hud, 'Icons.widgets_rounded'), 1);
  });

  test('home HUD has one Agent space entry without a world or map option', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final hud = _classBody(
      source,
      'class _HomeHudLayerState extends State<_HomeHudLayer>',
    );
    expect(_count(hud, "label: 'home.menu.personal_space'"), 0);
    expect(_count(hud, 'route: AppRouteCatalog.agentSpace'), 1);
    expect(_count(hud, "label: 'home.menu.agent_space'"), 1);
    expect(_count(hud, "label: 'home.menu.world'"), 0);
    expect(_count(hud, 'route: AppRouteCatalog.world'), 0);
  });
}

String _classBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: signature);

  final openBrace = source.indexOf('{', start);
  expect(openBrace, greaterThan(start), reason: signature);

  var depth = 0;
  for (var i = openBrace; i < source.length; i += 1) {
    final char = source[i];
    if (char == '{') depth += 1;
    if (char == '}') {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }

  fail('Could not find class end for $signature');
}

int _count(String source, String needle) =>
    RegExp(RegExp.escape(needle)).allMatches(source).length;
