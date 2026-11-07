import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/features/relationship/presentation/relationship_hub_page.dart';
import 'package:maaso/src/offline/local_edition_policy.dart';

void main() {
  test(
    'personality configuration selects only a bounded existing hub section',
    () {
      expect(
        relationshipSectionForLocation(
          Uri.parse('${AppRoutes.memoryWall}?section=profile'),
        ),
        RelationshipHubSection.profile,
      );
      expect(
        relationshipSectionForLocation(
          Uri.parse('${AppRoutes.memoryWall}?section=moments'),
        ),
        RelationshipHubSection.moments,
      );
      for (final suffix in [
        '',
        '?section=memories',
        '?section=unknown',
        '?section=profile&section=memories',
      ]) {
        expect(
          relationshipSectionForLocation(
            Uri.parse('${AppRoutes.memoryWall}$suffix'),
          ),
          RelationshipHubSection.memories,
          reason: suffix,
        );
      }
    },
  );
  test(
    'routed screens depend on the route catalog instead of router config',
    () {
      const files = [
        'lib/src/features/home/presentation/home_page.dart',
        'lib/src/features/home/application/home_controller.dart',
        'lib/src/features/auth/application/login_controller.dart',
        'lib/src/features/dashboard/presentation/dashboard_page.dart',
        'lib/src/features/settings/presentation/agent_settings_page.dart',
        'lib/src/features/settings/application/agent_settings_controller.dart',
        'lib/src/core/services/startup_route_service.dart',
      ];

      for (final path in files) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          isNot(
            contains(
              "import 'package:maaso/src/app/routing/router_config.dart';",
            ),
          ),
          reason: path,
        );
        expect(
          source,
          contains(
            "import 'package:maaso/src/app/routing/app_route_catalog.dart';",
          ),
          reason: path,
        );
      }
    },
  );

  test('every destination has a non-empty route and EN+ZH keywords', () {
    expect(AppRoutes.destinations, isNotEmpty);
    for (final d in AppRoutes.destinations) {
      expect(d.route, isNotEmpty, reason: '${d.id} route');
      expect(
        d.keywords.any((k) => RegExp(r'[a-z]').hasMatch(k)),
        isTrue,
        reason: '${d.id} needs an English keyword',
      );
      expect(
        d.keywords.any((k) => RegExp(r'[一-鿿]').hasMatch(k)),
        isTrue,
        reason: '${d.id} needs a Chinese keyword',
      );
    }
  });

  test('first naming remains available without a public identity editor', () {
    expect(AppRoutes.destinations.any((d) => d.id == 'onboarding'), isTrue);
    expect(AppRoutes.destinations.any((d) => d.id == 'identity'), isFalse);
    expect(appRoutePaths, contains(AppRoutes.onboarding));
    expect(appRoutePaths, isNot(contains(AppRoutes.identity)));
    expect(AppRoutes.resolveCommand('/identity'), isNull);
    expect(AppRoutes.resolveCommand('/publicnames'), isNull);
    expect(AppRoutes.resolveCommand('/公开身份'), isNull);
  });

  test('skill store is a navigable destination', () {
    expect(AppRoutes.skillStore, '/skill-store');
    expect(
      AppRoutes.destinations.any((d) => d.route == AppRoutes.skillStore),
      isTrue,
    );
  });

  test('skill store page is registered with go_router', () {
    expect(appRoutePaths, contains(AppRoutes.skillStore));
  });

  test('Game Feed and Applets are independent public destinations', () {
    expect(AppRoutes.gameFeed, '/game-feed');
    expect(AppRoutes.widgetsHub, '/widgets-hub');

    final gameFeed = AppRoutes.destinations.singleWhere(
      (destination) => destination.id == 'game_feed',
    );
    final applets = AppRoutes.destinations.singleWhere(
      (destination) => destination.id == 'widgets_hub',
    );

    expect(gameFeed.route, AppRoutes.gameFeed);
    expect(gameFeed.title, 'Game Feed');
    expect(applets.route, AppRoutes.widgetsHub);
    expect(applets.title, 'Applets');
    expect(
      appRoutePaths,
      containsAll([AppRoutes.gameFeed, AppRoutes.widgetsHub]),
    );
    expect(AppRoutes.resolveCommand('/game-feed'), AppRoutes.gameFeed);
    expect(AppRoutes.resolveCommand('/小游戏'), AppRoutes.gameFeed);
    expect(AppRoutes.resolveCommand('/applet'), AppRoutes.widgetsHub);
    expect(AppRoutes.resolveCommand('/小程序'), AppRoutes.widgetsHub);
  });

  test('Agent space is the only local room destination', () {
    expect(AppRoutes.agentSpace, '/agent-space');
    expect(
      AppRoutes.destinations.any((d) => d.route == AppRoutes.agentSpace),
      isTrue,
    );
    expect(appRoutePaths, contains(AppRoutes.agentSpace));
    expect(AppRoutes.resolveCommand('/Agent空间'), AppRoutes.agentSpace);
    expect(AppRoutes.resolveCommand('/平行世界'), isNull);
    expect(AppRoutes.resolveCommand('/微世界'), isNull);
  });

  test('personal space keywords open the same room without a variant', () {
    final world = AppRoutes.destinations.singleWhere(
      (item) => item.id == 'agent_space',
    );
    expect(world.variants, isEmpty);
    expect(AppRoutes.resolveCommand('/个人空间'), AppRoutes.agentSpace);
    expect(AppRoutes.resolveCommand('/personal-space'), AppRoutes.agentSpace);
    final location = Uri.parse(AppRoutes.agentSpace);
    expect(location.path, '/agent-space');
    expect(location.queryParameters, isEmpty);
    expect(appRoutePaths, contains(location.path));
  });

  test('Home HUD exposes the local Agent space destination', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    expect(source, contains("label: 'home.menu.agent_space'"));
    expect(source, contains('route: AppRouteCatalog.agentSpace'));
  });

  test('avatar destination remains addressable inside the unified Store', () {
    final destination = AppRoutes.destinations.singleWhere(
      (item) => item.route == AppRoutes.avatars,
    );
    expect(destination.id, 'avatars');
    expect(destination.title, 'Model Store');
    expect(destination.keywords, containsAll(['avatar', 'modelstore', '模型商店']));
    expect(AppRoutes.resolveCommand('/model-store'), AppRoutes.avatars);
    expect(AppRoutes.resolveCommand('/模型商店'), AppRoutes.avatars);

    final homeSource = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    expect(homeSource, contains("label: 'store_hub.marketplace'"));
    expect(homeSource, contains('route: AppRouteCatalog.avatars'));
    expect(homeSource, isNot(contains("label: 'home.menu.model_store'")));
    expect(homeSource, isNot(contains('route: AppRouteCatalog.skillStore')));
  });

  test('resolveCommand still resolves representative aliases', () {
    expect(AppRoutes.resolveCommand('/settings'), AppRoutes.settings);
    expect(AppRoutes.resolveCommand('/setting'), AppRoutes.settings);
    expect(AppRoutes.resolveCommand('/wall'), AppRoutes.memoryWall);
    expect(AppRoutes.resolveCommand('/game-feed'), AppRoutes.gameFeed);
    expect(AppRoutes.resolveCommand('/小游戏'), AppRoutes.gameFeed);
    expect(AppRoutes.resolveCommand('/widget-hub'), AppRoutes.widgetsHub);
    expect(AppRoutes.resolveCommand('/applet'), AppRoutes.widgetsHub);
    expect(AppRoutes.resolveCommand('/小程序'), AppRoutes.widgetsHub);
    expect(AppRoutes.resolveCommand('/qr'), isNull);
    expect(AppRoutes.resolveCommand('/个人信息'), AppRoutes.profile);
    expect(
      AppRoutes.resolveCommand('/会员'),
      kOpenMaasoLocalEdition ? null : AppRoutes.membership,
    );
    expect(AppRoutes.resolveCommand('/钱包'), isNull);
    expect(AppRoutes.resolveCommand('/chat'), AppRoutes.u2aChat);
    expect(AppRoutes.resolveCommand('/onboarding'), AppRoutes.onboarding);
    expect(AppRoutes.resolveCommand('/设置'), AppRoutes.settings);
    expect(AppRoutes.resolveCommand('/nope-xyz'), isNull);
  });

  test('commandList is one /<id> per destination', () {
    expect(AppRoutes.commandList, contains('/settings'));
    expect(AppRoutes.commandList, contains('/game_feed'));
    expect(AppRoutes.commandList, contains('/widgets_hub'));
    expect(AppRoutes.commandList.length, AppRoutes.destinations.length);
  });

  test('opaque secondary routes are unique and registered exactly once', () {
    const secondaryRoutes = <String>{
      AppRoutes.u2aChat,
      AppRoutes.moments,
      AppRoutes.memoryWall,
      AppRoutes.settings,
      AppRoutes.advancedFeatures,
      AppRoutes.skills,
      AppRoutes.skillStore,
      AppRoutes.dashboard,
      AppRoutes.gameFeed,
      AppRoutes.widgetsHub,
      AppRoutes.profile,
      AppRoutes.membership,
      AppRoutes.avatars,
      AppRoutes.bleProjector,
    };
    final registeredNames = appRoutePaths;

    expect(secondaryRoutes, hasLength(14));
    for (final route in secondaryRoutes) {
      expect(
        registeredNames.where((name) => name == route),
        hasLength(1),
        reason: route,
      );
    }
  });

  test('no two destinations share a normalized keyword', () {
    String normalize(String s) => s
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'[\s_-]'), '');
    final seen = <String, String>{};
    for (final d in AppRoutes.destinations) {
      for (final kw in d.allKeywords) {
        final key = normalize(kw);
        final prior = seen[key];
        expect(
          prior == null || prior == d.route,
          isTrue,
          reason: '"$kw" (→ "$key") collides between $prior and ${d.route}',
        );
        seen[key] = d.route;
      }
    }
  });
}
