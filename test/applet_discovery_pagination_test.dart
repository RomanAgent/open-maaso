import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skills/applet_discovery_skill.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

void main() {
  Future<Map<String, dynamic>> search(
    AppletDiscoverySkill skill, {
    Object? cursor,
  }) async =>
      jsonDecode(
            await skill.methods['search']!([
                  {'query': '', 'category': 'travel', 'cursor': ?cursor},
                ])
                as String,
          )
          as Map<String, dynamic>;

  test(
    'empty ranked page continues with the same filters and grants its result',
    () async {
      final gateway = _PagedCatalog([
        _page(nextCursor: 'page-2'),
        _page(items: [_item('travel-best', 17), _item('travel-next', 3)]),
      ]);
      final skill = AppletDiscoverySkill(gateway: gateway);
      final result = await search(skill);
      expect(gateway.cursors, [null, 'page-2']);
      expect(gateway.categories, everyElement('travel'));
      expect(gateway.queries, everyElement(''));
      expect(gateway.types, everyElement(AppletCatalogType.applet));
      expect(result['status'], 'found');
      expect(result['items'], [
        {
          'id': 'travel-best',
          'type': 'applet',
          'title': 'Trip',
          'category': 'travel',
          'ratingScore': 17,
          'skillInstructions': '',
        },
        {
          'id': 'travel-next',
          'type': 'applet',
          'title': 'Trip',
          'category': 'travel',
          'ratingScore': 3,
          'skillInstructions': '',
        },
      ]);
      expect(result['mayOfferGeneration'], isFalse);
      final describe = jsonDecode(
        await skill.methods['describeApplet']!([
              {'id': 'travel-best'},
            ])
            as String,
      );
      expect(gateway.sourceIds, ['travel-best']);
      expect(describe['error'], 'source_unavailable');
    },
  );

  test(
    'bounded empty scans expose a cursor that can resume instead of reporting no match',
    () async {
      final gateway = _PagedCatalog([
        _page(nextCursor: 'page-2'),
        _page(nextCursor: 'page-3'),
        _page(nextCursor: 'page-4'),
        _page(items: [_item('travel-best', 17)]),
      ]);
      final skill = AppletDiscoverySkill(gateway: gateway);
      final incomplete = await search(skill);
      expect(incomplete['status'], 'incomplete');
      expect(incomplete['nextCursor'], 'page-4');
      expect(incomplete['mayOfferGeneration'], isFalse);
      expect(incomplete['mustDeleteBeforeGeneration'], isFalse);
      expect(gateway.cursors, [null, 'page-2', 'page-3']);
      final resumed = await search(skill, cursor: incomplete['nextCursor']);
      expect(resumed['status'], 'found');
      expect(gateway.cursors.last, 'page-4');
    },
  );

  test('continuing a search revokes previous-page result authority', () async {
    final gateway = _PagedCatalog([
      _page(items: [_item('previous', 17)], nextCursor: 'page-2'),
      _page(items: [_item('current', 3)]),
    ]);
    final skill = AppletDiscoverySkill(gateway: gateway);
    await search(skill);
    await search(skill, cursor: 'page-2');
    final rejected = jsonDecode(
      await skill.methods['describeApplet']!([
            {'id': 'previous'},
          ])
          as String,
    );
    expect(rejected['error'], 'search_required');
    expect(gateway.sourceIds, isEmpty);
  });

  test(
    'account changes stop automatic continuation before another request',
    () async {
      final gateway = _PagedCatalog([_page(nextCursor: 'page-2')])
        ..changeContextOnSearch = true;
      final result = await search(AppletDiscoverySkill(gateway: gateway));
      expect(result['error'], 'request_context_changed');
      expect(gateway.cursors, [null]);
    },
  );

  test(
    'malformed and oversized cursors are rejected before catalog access',
    () async {
      final gateway = _PagedCatalog([]);
      final skill = AppletDiscoverySkill(gateway: gateway);
      for (final cursor in ['', ' page-2', 'page\n2', 'a' * 513, 7]) {
        expect((await search(skill, cursor: cursor))['error'], 'invalid_query');
      }
      expect(gateway.cursors, isEmpty);
    },
  );
}

AppletCatalogPage _page({
  List<AppletCatalogItem> items = const [],
  String? nextCursor,
}) => AppletCatalogPage(
  items: items,
  nextCursor: nextCursor,
  quota: const AppletQuotaSnapshot(used: 0, limit: 5),
);

AppletCatalogItem _item(String id, int likes) => AppletCatalogItem(
  id: id,
  title: 'Trip',
  type: AppletCatalogType.applet,
  summary: '',
  category: 'travel',
  likeCount: likes,
  author: const AppletCatalogAuthor(
    agentId: 'self',
    displayName: 'Guide',
    verified: false,
  ),
  shareUrl: Uri.parse('https://example.test/g/$id'),
  updatedAt: DateTime.utc(2026),
);

class _PagedCatalog implements AppletCatalogGateway, AppletDiscoveryGateway {
  _PagedCatalog(this.pages);
  final List<AppletCatalogPage> pages;
  final List<String?> cursors = [];
  final List<String?> categories = [];
  final List<String> queries = [];
  final List<AppletCatalogType?> types = [];
  final List<String> sourceIds = [];
  bool changeContextOnSearch = false;
  String context = 'account-1';
  @override
  String get requestContextKey => context;
  @override
  Future<AppletCatalogPage> searchRanked({
    required String query,
    String? category,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    cursors.add(cursor);
    categories.add(category);
    queries.add(query);
    types.add(type);
    if (changeContextOnSearch) context = 'account-2';
    return pages[cursors.length - 1];
  }

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async {
    sourceIds.add(id);
    throw StateError('No source needed for search grant verification');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
