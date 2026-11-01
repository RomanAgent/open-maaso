import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_hub_route_intent.dart';

void main() {
  test('round-trips the dedicated game feed and typed Hub categories', () {
    for (final category in AppletCategory.values) {
      final intent = AppletHubRouteIntent(
        category: category,
        openId: 'applet-1',
      );
      final parsed = AppletHubRouteIntent.parse(intent.location);

      expect(parsed.category, category);
      expect(parsed.openId, 'applet-1');
      expect(parsed.location, intent.location);
    }
    expect(
      AppletHubRouteIntent.parse('/widgets-hub').category,
      AppletCategory.all,
    );
    expect(
      AppletHubRouteIntent(
        category: AppletCategory.game,
        openId: 'applet-1',
      ).location,
      '/game-feed?open=applet-1',
    );
    expect(
      AppletHubRouteIntent(
        category: AppletCategory.travel,
        openId: 'applet-1',
      ).location,
      '/widgets-hub?category=travel&open=applet-1',
    );
  });

  test('parses legacy game Hub routes and canonicalizes them to the feed', () {
    final legacy = AppletHubRouteIntent.parse(
      '/widgets-hub?category=game&open=applet-1',
    );

    expect(legacy.category, AppletCategory.game);
    expect(legacy.openId, 'applet-1');
    expect(legacy.location, '/game-feed?open=applet-1');
    expect(legacy.matchesLocation('/game-feed?open=applet-1'), isTrue);
  });

  test('rejects external URLs, unknown query keys, duplicates and bad ids', () {
    for (final location in <String>[
      'https://example.test/widgets-hub?category=game',
      'https://example.test/game-feed',
      '/widgets-hub?category=news',
      '/game-feed?category=game',
      '/game-feed?category=travel',
      '/game-feed?url=https%3A%2F%2Fevil.test',
      '/widgets-hub?category=game&url=https%3A%2F%2Fevil.test',
      '/widgets-hub?category=game&category=tools',
      '/widgets-hub?category=game&open=',
      '/widgets-hub?category=game&open=https%3A%2F%2Fevil.test',
      '/widgets-hub?category=game&open=mailto%3Aevil',
      '/widgets-hub?category=game&open=ftp%3Aevil',
      '/widgets-hub?category=game&open=%20applet-1%20',
      '/widgets-hub?category=game&open=${List<String>.filled(41, 'a').join()}',
      '/widgets-hub?category=game#open',
      '/widgets-hub/child?category=game',
      '/game-feed/child',
    ]) {
      expect(AppletHubRouteIntent.tryParse(location), isNull, reason: location);
    }
  });

  test('a direct route without an issued grant cannot open an item', () {
    final item = _travelItem();
    final page = _page(item);
    final intent = AppletHubRouteIntent(
      category: AppletCategory.travel,
      openId: 'guessed-token',
    );
    final broker = AppletHubOpenBroker(tokenFactory: () => 'unused-token');

    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: intent,
        currentLocation: intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
  });

  test('issued route uses an opaque token and claims the exact item once', () {
    final now = DateTime.utc(2026, 8, 11, 12);
    final item = _travelItem();
    final page = _page(item);
    final broker = AppletHubOpenBroker(
      now: () => now,
      tokenFactory: () => 'one-time-token',
    );
    final ticket = broker.issue(
      ownerAgentId: 'self',
      category: AppletCategory.travel,
      requestContextKey: _contextKey,
      expiresAt: now.add(const Duration(seconds: 30)),
      page: page,
      item: item,
    );

    expect(ticket.intent.openId, 'one-time-token');
    expect(ticket.intent.location, isNot(contains(item.id)));
    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      same(item),
    );
    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
  });

  test('an expired or restored issued route has no open authority', () {
    var now = DateTime.utc(2026, 8, 11, 12);
    final item = _travelItem();
    final page = _page(item);
    final broker = AppletHubOpenBroker(
      now: () => now,
      tokenFactory: () => 'expiring-token',
    );
    final ticket = broker.issue(
      ownerAgentId: 'self',
      category: AppletCategory.travel,
      requestContextKey: _contextKey,
      expiresAt: now.add(const Duration(seconds: 30)),
      page: page,
      item: item,
    );
    now = now.add(const Duration(seconds: 30));

    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
  });

  test('latest-page replacement cannot swap the authorized item', () {
    final now = DateTime.utc(2026, 8, 11, 12);
    final item = _travelItem();
    final originalPage = _page(item);
    final replacement = _travelItem(title: 'Changed result');
    final broker = AppletHubOpenBroker(
      now: () => now,
      tokenFactory: () => 'page-bound-token',
    );
    final ticket = broker.issue(
      ownerAgentId: 'self',
      category: AppletCategory.travel,
      requestContextKey: _contextKey,
      expiresAt: now.add(const Duration(seconds: 30)),
      page: originalPage,
      item: item,
    );

    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: _page(replacement),
      ),
      isNull,
    );
    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: originalPage,
      ),
      isNull,
    );
  });

  test('owner, route or context mismatch consumes the one-shot grant', () {
    final now = DateTime.utc(2026, 8, 11, 12);
    final item = _travelItem();
    final page = _page(item);
    final broker = AppletHubOpenBroker(
      now: () => now,
      tokenFactory: () => 'context-token',
    );
    final ticket = broker.issue(
      ownerAgentId: 'self',
      category: AppletCategory.travel,
      requestContextKey: _contextKey,
      expiresAt: now.add(const Duration(seconds: 30)),
      page: page,
      item: item,
    );

    expect(
      broker.claim(
        ownerAgentId: 'peer',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
    expect(
      broker.claim(
        ownerAgentId: 'self',
        intent: ticket.intent,
        currentLocation: ticket.intent.location,
        requestContextKey: _contextKey,
        latestContextKey: _contextKey,
        latestPage: page,
      ),
      isNull,
    );
  });
}

const String _contextKey = 'prod|owner-a|zh-CN';

AppletCatalogItem _travelItem({String title = 'Kyoto Travel Guide'}) => _item(
  id: 'travel-1',
  title: title,
  summary: 'Three-day itinerary and hotel guide.',
);

AppletCatalogPage _page(AppletCatalogItem item) => AppletCatalogPage(
  items: <AppletCatalogItem>[item],
  quota: const AppletQuotaSnapshot(used: 1, limit: 5),
);

AppletCatalogItem _item({
  required String id,
  required String title,
  required String summary,
}) => AppletCatalogItem(
  id: id,
  title: title,
  type: AppletCatalogType.applet,
  summary: summary,
  author: const AppletCatalogAuthor(
    agentId: 'aa_0123456789abcdef0123456789abcdef',
    displayName: 'Agent 0123456789ABCDEF',
    verified: false,
  ),
  shareUrl: Uri.parse('https://api.example.test/g/$id'),
  updatedAt: DateTime.utc(2026, 8, 11),
);
