import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

enum AppletCategory { all, game, travel, tools }

extension AppletCategoryMetadata on AppletCategory {
  String get labelKey => 'widgets.category_$name';
}

/// A compatibility taxonomy for Applets already persisted or returned by the
/// current catalog wire format. Explicit local metadata wins, while legacy
/// records keep deterministic game/tool fallbacks.
final class AppletCategoryTaxonomy {
  const AppletCategoryTaxonomy._();

  static AppletCategory forWidget(AgentWidget item) {
    // The generated Surface contract is authoritative for the player/runtime
    // boundary. Utility facets may refine Applets, but cannot reclassify a
    // game into Home's utility overlay path.
    final experienceType = _normalized(item.spec['experienceType']);
    if (experienceType == 'game') {
      return AppletCategory.game;
    }
    final explicit = _fromRaw(item.spec['category']);
    if (explicit != null &&
        (experienceType.isEmpty || explicit != AppletCategory.game)) {
      return explicit;
    }

    final rawTags = item.spec['tags'];
    final tags = rawTags is Iterable ? rawTags : <Object?>[rawTags];
    for (final tag in tags) {
      final category = _fromRaw(tag);
      if (category != null &&
          (experienceType.isEmpty || category != AppletCategory.game)) {
        return category;
      }
    }

    return _travelCategoryForText(<Object?>[
          item.title,
          item.subtitle,
          item.spec['summary'],
        ]) ??
        AppletCategory.tools;
  }

  static AppletCategory forCatalogType(AppletCatalogType type) =>
      type == AppletCatalogType.game
      ? AppletCategory.game
      : AppletCategory.tools;

  static AppletCategory forCatalogItem(AppletCatalogItem item) =>
      item.type == AppletCatalogType.game
      ? AppletCategory.game
      : _fromRaw(item.category) ??
            _travelCategoryForText(<Object?>[item.title, item.summary]) ??
            AppletCategory.tools;

  static AppletCategory forInventoryItem(AppletInventoryItem item) =>
      item.type == AppletCatalogType.game
      ? AppletCategory.game
      : _fromRaw(item.category) ??
            _travelCategoryForText(<Object?>[item.title, item.summary]) ??
            AppletCategory.tools;

  static AppletCategory forOfficialId(String id) => AppletCategory.tools;

  static bool matches({
    required AppletCategory selected,
    required AppletCategory item,
  }) => selected == AppletCategory.all || selected == item;

  static AppletCategory? _fromRaw(Object? raw) {
    return switch (_normalized(raw)) {
      'game' || 'games' || 'minigame' || '游戏' || '小游戏' => AppletCategory.game,
      'travel' ||
      'trip' ||
      'tourism' ||
      'guide' ||
      '旅行' ||
      '旅游' ||
      '攻略' => AppletCategory.travel,
      'tool' ||
      'tools' ||
      'utility' ||
      'utilities' ||
      '工具' ||
      '实用' => AppletCategory.tools,
      _ => null,
    };
  }

  static String _normalized(Object? raw) =>
      raw?.toString().trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '') ??
      '';

  static AppletCategory? _travelCategoryForText(Iterable<Object?> values) {
    final text = values
        .whereType<Object>()
        .map((value) => value.toString().trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .join(' ');
    if (text.isEmpty) return null;
    if (RegExp(
          r'\b(travel|trip|tourism|vacation|itinerary|hotel|flight|travel guide|city guide)\b',
        ).hasMatch(text) ||
        const <String>[
          '旅行',
          '旅游',
          '行程',
          '攻略',
          '景点',
          '酒店',
          '航班',
        ].any(text.contains)) {
      return AppletCategory.travel;
    }
    return null;
  }
}
