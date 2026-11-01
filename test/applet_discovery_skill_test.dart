import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/skills/applet_discovery_skill.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_hub_route_intent.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test(
    'returns matches from public search without proposing generation',
    () async {
      final locations = <String>[];
      final gateway = _FakeCatalog(
        _page(items: <AppletCatalogItem>[_catalogItem()], used: 2),
      );
      final broker = AppletHubOpenBroker(tokenFactory: () => 'grant-token-1');
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        navigate: locations.add,
        openBroker: broker,
      );

      final raw = await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': '跑酷', 'type': 'game'}),
      ]);
      final result = Map<String, Object?>.from(
        jsonDecode(raw as String) as Map,
      );

      expect(gateway.query, '跑酷');
      expect(gateway.type, AppletCatalogType.game);
      expect(result['status'], 'found');
      expect(result['resultCount'], 1);
      expect(result['displaySurface'], '/game-feed');
      expect(result['category'], 'game');
      expect(result['navigation_requested'], isTrue);
      expect(locations, <String>['/game-feed']);
      expect(result['mayOfferGeneration'], isFalse);
      expect((result['items'] as List).single, <String, Object?>{
        'id': 'applet-1',
        'type': 'game',
      });
      expect(raw, isNot(contains('Orbit Runner')));
      expect(raw, isNot(contains('Mochi')));
      expect(raw, isNot(contains('tiny runner')));

      final opened = _json(
        await skill.methods['open']!(<Object?>[
          jsonEncode(<String, Object?>{'id': 'applet-1'}),
        ]),
      );
      expect(opened, <String, Object?>{
        'status': 'navigation_requested',
        'navigation_requested': true,
        'id': 'applet-1',
        'category': 'game',
        'displaySurface': '/game-feed',
      });
      expect(locations.last, '/game-feed?open=grant-token-1');
      final intent = AppletHubRouteIntent.parse(locations.last);
      expect(
        broker.claim(
          ownerAgentId: 'self',
          intent: intent,
          currentLocation: intent.location,
          requestContextKey: gateway.requestContextKey,
          latestContextKey: gateway.requestContextKey,
          latestPage: gateway.page,
        ),
        same(gateway.page.items.single),
      );
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'applet-1'}),
          ]),
        )['error'],
        'search_required',
      );
    },
  );

  test('filters one bounded page across all four Hub categories', () async {
    final gateway = _FakeCatalog(
      _page(
        items: <AppletCatalogItem>[
          _catalogItem(id: 'game-1'),
          _catalogItem(
            id: 'travel-1',
            type: AppletCatalogType.applet,
            title: 'Kyoto Travel Guide',
            summary: 'A three-day itinerary with hotel suggestions.',
          ),
          _catalogItem(
            id: 'tool-1',
            type: AppletCatalogType.applet,
            title: 'Unit Converter',
            summary: 'Convert measurements locally.',
          ),
        ],
        used: 3,
      ),
    );
    final skill = AppletDiscoverySkill(gateway: gateway, navigate: (_) {});

    final expected = <String, List<String>>{
      'all': <String>['game-1', 'travel-1', 'tool-1'],
      'game': <String>['game-1'],
      'travel': <String>['travel-1'],
      'tools': <String>['tool-1'],
    };
    for (final entry in expected.entries) {
      final result = _json(
        await skill.methods['search']!(<Object?>[
          jsonEncode(<String, Object?>{
            'query': 'find useful applets',
            'category': entry.key,
          }),
        ]),
      );
      expect(result['status'], 'found', reason: entry.key);
      expect(
        (result['items'] as List)
            .map((item) => (item as Map)['id'] as String)
            .toList(),
        entry.value,
        reason: entry.key,
      );
      expect(gateway.type, switch (entry.key) {
        'game' => AppletCatalogType.game,
        'travel' || 'tools' => AppletCatalogType.applet,
        _ => null,
      });
    }
    expect(gateway.calls, 4);
  });

  test('keeps legacy any, applet and game type filters compatible', () async {
    final gateway = _FakeCatalog(
      _page(items: <AppletCatalogItem>[_catalogItem()], used: 1),
    );
    final skill = AppletDiscoverySkill(gateway: gateway);

    for (final entry in <String, AppletCatalogType?>{
      'any': null,
      'applet': AppletCatalogType.applet,
      'game': AppletCatalogType.game,
    }.entries) {
      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'legacy', 'type': entry.key}),
      ]);
      expect(gateway.type, entry.value, reason: entry.key);
    }
  });

  test('rejects conflicting legacy and category filters', () async {
    final gateway = _FakeCatalog(
      _page(items: <AppletCatalogItem>[_catalogItem()], used: 1),
    );
    final skill = AppletDiscoverySkill(gateway: gateway);

    final result = _json(
      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{
          'query': 'trip',
          'type': 'game',
          'category': 'travel',
        }),
      ]),
    );

    expect(result['error'], 'invalid_query');
    expect(gateway.calls, 0);
  });

  test('not-found result offers generation only when quota has room', () async {
    final available = AppletDiscoverySkill(
      gateway: _FakeCatalog(_page(items: const <AppletCatalogItem>[], used: 4)),
    );
    final full = AppletDiscoverySkill(
      gateway: _FakeCatalog(_page(items: const <AppletCatalogItem>[], used: 5)),
    );

    final availableResult = _json(
      await available.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': '塔防'}),
      ]),
    );
    final fullResult = _json(
      await full.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': '塔防'}),
      ]),
    );

    expect(availableResult['status'], 'not_found');
    expect(availableResult['mayOfferGeneration'], isTrue);
    expect(availableResult['mustDeleteBeforeGeneration'], isFalse);
    expect(fullResult['mayOfferGeneration'], isFalse);
    expect(fullResult['mustDeleteBeforeGeneration'], isTrue);
  });

  test('an exhausted scan page never becomes a false not-found', () async {
    final skill = AppletDiscoverySkill(
      gateway: _FakeCatalog(
        _page(
          items: const <AppletCatalogItem>[],
          used: 5,
          nextCursor: 'catalog-next',
        ),
      ),
    );

    final result = _json(
      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': '稀有类型小游戏'}),
      ]),
    );

    expect(result['status'], 'incomplete');
    expect(result['mayOfferGeneration'], isFalse);
    expect(result['mustDeleteBeforeGeneration'], isFalse);
  });

  test(
    'a category miss with nextCursor stays incomplete without paging',
    () async {
      final locations = <String>[];
      final gateway = _FakeCatalog(
        _page(
          items: <AppletCatalogItem>[
            _catalogItem(
              id: 'tool-1',
              type: AppletCatalogType.applet,
              title: 'Unit Converter',
              summary: 'Conversion tool.',
            ),
          ],
          used: 1,
          nextCursor: 'catalog-next',
        ),
      );
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        navigate: locations.add,
      );

      final result = _json(
        await skill.methods['search']!(<Object?>[
          jsonEncode(<String, Object?>{'query': 'Kyoto', 'category': 'travel'}),
        ]),
      );

      expect(result['status'], 'incomplete');
      expect(result['resultCount'], 0);
      expect(result['displaySurface'], '/widgets-hub');
      expect(result['mayOfferGeneration'], isFalse);
      expect(gateway.calls, 1);
      expect(locations, <String>['/widgets-hub?category=travel']);
    },
  );

  test(
    'open grant expires and is bound to the search request context',
    () async {
      var now = DateTime.utc(2026, 8, 11, 12);
      final gateway = _FakeCatalog(
        _page(items: <AppletCatalogItem>[_catalogItem()], used: 1),
      );
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        navigate: (_) {},
        now: () => now,
        resultTtl: const Duration(seconds: 30),
      );

      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'runner', 'category': 'game'}),
      ]);
      gateway.contextKey = 'test|other-owner|zh-CN';
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'applet-1'}),
          ]),
        )['error'],
        'search_context_changed',
      );

      gateway.contextKey = 'test|owner|zh-CN';
      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'runner', 'category': 'game'}),
      ]);
      now = now.add(const Duration(seconds: 30));
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'applet-1'}),
          ]),
        )['error'],
        'search_expired',
      );
    },
  );

  test(
    'a context switch during search exposes no results or open grant',
    () async {
      final gateway = _FakeCatalog(
        _page(items: <AppletCatalogItem>[_catalogItem()], used: 1),
      )..contextAfterSearch = 'test|other-owner|zh-CN';
      final skill = AppletDiscoverySkill(gateway: gateway, navigate: (_) {});

      final search = _json(
        await skill.methods['search']!(<Object?>[
          jsonEncode(<String, Object?>{'query': 'runner'}),
        ]),
      );
      expect(search, <String, Object?>{'error': 'request_context_changed'});
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'applet-1'}),
          ]),
        )['error'],
        'search_required',
      );
    },
  );

  test(
    'open consumes authority on invalid ids and rejects display metadata',
    () async {
      final gateway = _FakeCatalog(
        _page(items: <AppletCatalogItem>[_catalogItem()], used: 1),
      );
      final skill = AppletDiscoverySkill(gateway: gateway, navigate: (_) {});

      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'runner'}),
      ]);
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'other-applet'}),
          ]),
        )['error'],
        'result_not_granted',
      );

      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'runner'}),
      ]);
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{
              'id': 'applet-1',
              'title': 'Orbit Runner',
            }),
          ]),
        )['error'],
        'invalid_open',
      );
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'applet-1'}),
          ]),
        )['error'],
        'search_required',
      );

      await skill.methods['search']!(<Object?>[
        jsonEncode(<String, Object?>{'query': 'runner'}),
      ]);
      expect(
        _json(
          await skill.methods['open']!(<Object?>[
            jsonEncode(<String, Object?>{'id': 'https://evil.test/game'}),
          ]),
        )['error'],
        'invalid_open',
      );
    },
  );

  test('rejects unknown input fields and non-self use', () async {
    final gateway = _FakeCatalog(
      _page(items: const <AppletCatalogItem>[], used: 0),
    );
    final self = AppletDiscoverySkill(gateway: gateway);
    final peer = AppletDiscoverySkill(agentId: 'peer', gateway: gateway);

    expect(
      _json(
        await self.methods['search']!(<Object?>[
          jsonEncode(<String, Object?>{'query': 'quiz', 'extra': true}),
        ]),
      )['error'],
      'invalid_query',
    );
    expect(
      _json(
        await peer.methods['search']!(<Object?>[
          jsonEncode(<String, Object?>{'query': 'quiz'}),
        ]),
      )['error'],
      'owner_only',
    );
    expect(
      _json(
        await peer.methods['open']!(<Object?>[
          jsonEncode(<String, Object?>{'id': 'applet-1'}),
        ]),
      )['error'],
      'owner_only',
    );
  });
}

Map<String, Object?> _json(Object? raw) =>
    Map<String, Object?>.from(jsonDecode(raw as String) as Map);

AppletCatalogPage _page({
  required List<AppletCatalogItem> items,
  required int used,
  String? nextCursor,
}) => AppletCatalogPage(
  items: items,
  quota: AppletQuotaSnapshot(used: used, limit: 5),
  nextCursor: nextCursor,
);

AppletCatalogItem _catalogItem({
  String id = 'applet-1',
  String title = 'Orbit Runner',
  AppletCatalogType type = AppletCatalogType.game,
  String summary = 'A tiny runner.',
}) => AppletCatalogItem(
  id: id,
  title: title,
  type: type,
  summary: summary,
  author: const AppletCatalogAuthor(
    agentId: 'aa_0123456789abcdef0123456789abcdef',
    displayName: 'Agent 0123456789ABCDEF',
    verified: false,
  ),
  shareUrl: Uri.parse('https://api.example.test/g/$id'),
  updatedAt: DateTime.utc(2026, 8, 8),
);

class _FakeCatalog implements AppletCatalogGateway {
  _FakeCatalog(this.page);

  final AppletCatalogPage page;
  String query = '';
  AppletCatalogType? type;
  int calls = 0;
  String contextKey = 'test|owner|zh-CN';
  String? contextAfterSearch;

  @override
  String get requestContextKey => contextKey;

  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async => page;

  @override
  Future<AppletCommentPage> listComments(
    String appletId, {
    String? cursor,
    int limit = 30,
    required String expectedContextKey,
  }) => throw UnsupportedError('catalog discovery is read-only');

  @override
  Future<AppletComment> postComment(
    String appletId,
    String text, {
    required String expectedContextKey,
  }) => throw UnsupportedError('catalog discovery is read-only');

  @override
  Future<AppletEngagementSnapshot> recordShare(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  }) => throw UnsupportedError('catalog discovery is read-only');

  @override
  Future<AppletEngagementSnapshot> recordView(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  }) => throw UnsupportedError('catalog discovery is read-only');

  @override
  Future<AppletEngagementSnapshot> setLiked(
    String appletId,
    bool liked, {
    required String expectedContextKey,
  }) => throw UnsupportedError('catalog discovery is read-only');

  @override
  Future<AppletCatalogPage> search({
    required String query,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    calls++;
    this.query = query;
    this.type = type;
    contextKey = contextAfterSearch ?? contextKey;
    return page;
  }
}
