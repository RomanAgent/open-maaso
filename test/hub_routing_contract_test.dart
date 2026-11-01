import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/router_config.dart';

void main() {
  test('legacy relationship and store deep links remain registered', () {
    expect(AppRoutes.moments, '/moments');
    expect(AppRoutes.memoryWall, '/memory-wall');
    expect(AppRoutes.skillStore, '/skill-store');
    expect(AppRoutes.skills, '/skills');
    expect(AppRoutes.avatars, '/avatars');
    expect(AppRoutes.gameFeed, '/game-feed');
    expect(AppRoutes.widgetsHub, '/widgets-hub');

    expect(
      appRoutePaths,
      containsAll(<String>[
        AppRoutes.moments,
        AppRoutes.memoryWall,
        AppRoutes.skillStore,
        AppRoutes.skills,
        AppRoutes.avatars,
        AppRoutes.gameFeed,
        AppRoutes.widgetsHub,
      ]),
    );
  });

  test(
    'legacy routes keep shared hubs while Game Feed and Applets own routes',
    () {
      final source = File(
        'lib/src/app/routing/router_config.dart',
      ).readAsStringSync();

      expect(source, contains('RelationshipHubPage('));
      expect(source, contains('RelationshipHubSection.moments'));
      expect(source, contains('RelationshipHubSection.memories'));
      expect(source, contains('StoreHubPage('));
      expect(source, contains('StoreHubSection.marketplace'));
      expect(source, contains('StoreHubSection.skills'));
      expect(source, contains('StoreHubSection.models'));
      expect(source, isNot(contains('StoreHubSection.applets')));
      expect(source, contains('(_) => const GameFeedPage()'));
      expect(source, contains('(_) => const WidgetsHubPage()'));
      expect(
        RegExp(
          RegExp.escape('WidgetsHubRouteDependencies.new'),
        ).allMatches(source),
        hasLength(3),
      );
    },
  );
}
