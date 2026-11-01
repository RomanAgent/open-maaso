import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Hub route effect validates typed route and latest context before open',
    () {
      final source = File(
        'lib/src/features/widgets_hub/presentation/widgets_hub_page.dart',
      ).readAsStringSync();

      expect(source, contains('AppletHubRouteIntent.tryParse'));
      expect(source, contains('intent.category == AppletCategory.game'));
      expect(source, contains('AppletHubSection.games'));
      expect(source, contains('AppletHubSection.applets'));
      expect(source, contains('controller.selectCategory(intent.category)'));
      expect(source, contains('WidgetsBinding.instance.addPostFrameCallback'));
      expect(source, contains('appletHubOpenBroker.claim('));
      expect(source, contains('ownerAgentId: \'self\''));
      expect(source, contains('currentLocation: appNavigation.currentRoute'));
      expect(source, contains('requestContextKey: catalog.requestContextKey'));
      expect(
        source,
        contains('latestContextKey: catalog.latestContextKey.value'),
      );
      expect(source, contains('latestPage: catalog.latestPage.value'));
      expect(source, contains('_openCatalogItem(item)'));
      expect(source, contains('void dispose()'));
      expect(source, contains('appletHubOpenBroker.revokeIntent('));
      expect(source, isNot(contains('globalPosition')));
    },
  );

  test(
    'dedicated game player reserves route chrome outside opaque WebView',
    () {
      final source = File(
        'lib/src/features/widgets_hub/presentation/widgets_hub_page.dart',
      ).readAsStringSync();

      expect(source, contains('runtime: widget.runtime'));
      expect(
        source,
        contains("hostKey: const ValueKey<String>('game-player-host')"),
      );
      expect(source, contains('SafeArea('));
      expect(source, contains('bottom: false'));
      expect(source, contains('shouldPresentAgentWidgetOnHome(item)'));
      expect(
        source,
        isNot(contains('child: const SurfaceStage(showBackButton: false)')),
      );
    },
  );
}
