import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';

void main() {
  test('the unified Store is a top-level menu destination', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    final menu = _classBody(
      source,
      'class _HomeHudLayerState extends State<_HomeHudLayer>',
    );

    expect(menu, contains("label: 'store_hub.marketplace'"));
    expect(menu, contains('route: AppRouteCatalog.avatars'));
    expect(menu, isNot(contains('route: AppRouteCatalog.skills')));
    expect(menu, isNot(contains('route: AppRouteCatalog.skillStore')));
  });

  test('personal Workshop owns the My Skills entry', () {
    final source = File(
      'lib/src/features/store/presentation/store_hub_page.dart',
    ).readAsStringSync();
    expect(source, contains("'skills.my_skills'.tr"));
    expect(
      source,
      contains('appNavigation.push<void>(AppRouteCatalog.skills)'),
    );
    final settings = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    expect(settings, isNot(contains('AppRouteCatalog.skills')));

    final destination = AppRouteCatalog.destinations.firstWhere(
      (item) => item.route == AppRouteCatalog.skills,
    );
    expect(destination.title, 'My Workshop');
    expect(destination.keywords, contains('我的技能'));
  });

  test('store and personal Skill management are separate surfaces', () {
    final store = File(
      'lib/src/features/skills/presentation/skill_store_page.dart',
    ).readAsStringSync();
    final storePage = _classBody(store, 'class SkillStorePage');
    final mine = File(
      'lib/src/features/skills/presentation/skills_page.dart',
    ).readAsStringSync();

    expect(storePage, contains('body: const _FlatSkillCatalog()'));
    expect(storePage, isNot(contains('DefaultTabController')));
    expect(storePage, isNot(contains('MarketplaceMySkillsView(')));
    expect(mine, contains('MarketplaceMySkillsView(view: _communityView)'));
    expect(mine, contains("'skills.built_in'.tr"));
    expect(mine, contains("'skills.community'.tr"));
  });

  test('Skill catalog sorting is a single control, not another tab layer', () {
    final source = File(
      'lib/src/features/skills/presentation/skill_store_page.dart',
    ).readAsStringSync();
    final catalog = _classBody(source, 'class _FlatSkillCatalogState');
    expect(catalog, contains("ValueKey('skill-store-sort')"));
    expect(catalog, contains('DropdownButtonFormField<bool>'));
    expect(source, isNot(contains('class _SkillTabs')));
  });
}

String _classBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: signature);
  final openBrace = source.indexOf('{', start);
  expect(openBrace, greaterThan(start), reason: signature);

  var depth = 0;
  for (var index = openBrace; index < source.length; index += 1) {
    final character = source[index];
    if (character == '{') depth += 1;
    if (character == '}') {
      depth -= 1;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  fail('Could not find class end for $signature');
}
