import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';

void main() {
  group('AppletCategoryTaxonomy', () {
    test('explicit local category wins over the compatibility fallback', () {
      final item = _surface(<String, Object?>{
        'category': 'travel',
        'experienceType': 'utility',
      });

      expect(AppletCategoryTaxonomy.forWidget(item), AppletCategory.travel);
    });

    test(
      'canonical game experience cannot be downgraded by utility facets',
      () {
        final item = _surface(<String, Object?>{
          'experienceType': 'game',
          'category': 'tools',
          'tags': <String>['utility'],
        });

        expect(AppletCategoryTaxonomy.forWidget(item), AppletCategory.game);
      },
    );

    test('canonical utility experience cannot be promoted by game facets', () {
      final item = _surface(<String, Object?>{
        'experienceType': 'utility',
        'category': 'game',
        'tags': <String>['games'],
      });

      expect(AppletCategoryTaxonomy.forWidget(item), AppletCategory.tools);
    });

    test('reads compatible local tags without changing the wire schema', () {
      final item = _surface(<String, Object?>{
        'tags': <String>['实用', '工具'],
      });

      expect(AppletCategoryTaxonomy.forWidget(item), AppletCategory.tools);
    });

    test('falls back to experienceType and then tools for legacy surfaces', () {
      expect(
        AppletCategoryTaxonomy.forWidget(
          _surface(<String, Object?>{'experienceType': 'game'}),
        ),
        AppletCategory.game,
      );
      expect(
        AppletCategoryTaxonomy.forWidget(_surface(const <String, Object?>{})),
        AppletCategory.tools,
      );
    });

    test('infers travel from persisted user-facing metadata', () {
      final item = AgentWidget.fromJson(<String, Object?>{
        'title': '京都旅行攻略',
        'subtitle': '三日行程与酒店清单',
        'kind': 'surface',
        'spec': <String, Object?>{'experienceType': 'utility'},
        'createdAt': DateTime.fromMillisecondsSinceEpoch(0).toIso8601String(),
      });

      expect(AppletCategoryTaxonomy.forWidget(item), AppletCategory.travel);
    });

    test('catalog type remains the compatibility source for remote items', () {
      expect(
        AppletCategoryTaxonomy.forCatalogType(AppletCatalogType.game),
        AppletCategory.game,
      );
      expect(
        AppletCategoryTaxonomy.forCatalogType(AppletCatalogType.applet),
        AppletCategory.tools,
      );
    });

    test('infers remote travel Applets from catalog metadata', () {
      final item = AppletCatalogItem(
        id: 'travel-1',
        title: 'Kyoto Travel Guide',
        type: AppletCatalogType.applet,
        summary: 'A three-day itinerary with hotel suggestions.',
        author: const AppletCatalogAuthor(
          agentId: 'aa_0123456789abcdef0123456789abcdef',
          displayName: 'Agent 0123456789ABCDEF',
          verified: false,
        ),
        shareUrl: Uri.parse('https://example.com/g/kyoto'),
        updatedAt: DateTime.utc(2026, 8, 10),
      );

      expect(
        AppletCategoryTaxonomy.forCatalogItem(item),
        AppletCategory.travel,
      );
    });

    test('all filter matches every category while facets stay exact', () {
      expect(
        AppletCategoryTaxonomy.matches(
          selected: AppletCategory.all,
          item: AppletCategory.travel,
        ),
        isTrue,
      );
      expect(
        AppletCategoryTaxonomy.matches(
          selected: AppletCategory.game,
          item: AppletCategory.travel,
        ),
        isFalse,
      );
    });
  });
}

AgentWidget _surface(Map<String, Object?> spec) => AgentWidget(
  agentId: 'self',
  title: 'Applet',
  kind: 'surface',
  spec: spec,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);
