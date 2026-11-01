import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';

void main() {
  test('desktop menu exposes one local Agent space without map variants', () {
    final world = CompanionMenuCatalog.entries.singleWhere(
      (entry) => entry.destination.id == 'agent_space',
    );
    expect(world.destination.route, AppRouteCatalog.agentSpace);
    expect(world.destination.variants, isEmpty);
    expect(world.labelKey, 'home.menu.agent_space');
  });
  test('desktop chat opens Home while keeping the stable menu identity', () {
    final chat = CompanionMenuCatalog.preferredEntries.singleWhere(
      (entry) => entry.destination.id == 'chat',
    );
    expect(chat.destination.route, AppRouteCatalog.home);
    expect(chat.labelKey, 'chat.title');
    expect(chat.icon, CompanionMenuIcon.chat);
    expect(chat.searchTerms, containsAll(['chat', '聊天']));
  });

  test('desktop menu keeps games and hides wallet and Agent Feed entries', () {
    final expectedIds = AppRouteCatalog.menuDestinations
        .map((destination) => destination.id)
        .where((id) => id != 'agent_media')
        .toSet();
    final actualIds = CompanionMenuCatalog.entries
        .map((entry) => entry.destination.id)
        .toList(growable: false);

    expect(actualIds, contains('game_feed'));
    expect(actualIds, isNot(contains('agent_media')));
    expect(actualIds, isNot(contains('wallet')));
    expect(actualIds.toSet(), expectedIds);
    expect(actualIds.length, expectedIds.length);
    expect(CompanionMenuCatalog.coverageIssues, isEmpty);
    expect(
      AppRouteCatalog.destinations.map((destination) => destination.id),
      isNot(contains('agent_media')),
      reason: 'Retired destinations must not remain addressable.',
    );
    expect(
      AppRouteCatalog.destinations.map((destination) => destination.id),
      isNot(contains('wallet')),
      reason: 'The retired wallet must not remain a navigable destination.',
    );
  });

  test('every menu entry has stable presentation metadata', () {
    for (final entry in CompanionMenuCatalog.entries) {
      expect(entry.labelKey, isNotEmpty, reason: entry.destination.id);
      expect(entry.searchTerms, isNotEmpty, reason: entry.destination.id);
      expect(
        entry.searchTerms,
        containsAll(entry.destination.keywords),
        reason: entry.destination.id,
      );
    }
  });

  test('preferred entries are a unique subset of the complete catalog', () {
    final allIds = CompanionMenuCatalog.entries
        .map((entry) => entry.destination.id)
        .toSet();
    final preferredIds = CompanionMenuCatalog.preferredEntries
        .map((entry) => entry.destination.id)
        .toList(growable: false);

    expect(preferredIds, isNotEmpty);
    expect(preferredIds.toSet().length, preferredIds.length);
    expect(preferredIds.every(allIds.contains), isTrue);
    expect(preferredIds, contains('agent_space'));
    expect(preferredIds, isNot(contains('agent_media')));
    expect(preferredIds, isNot(contains('wallet')));
  });

  test('preferred native menu labels exist in every bundled language', () {
    for (final entry in CompanionMenuCatalog.preferredEntries) {
      final key = entry.labelKey;
      expect(enUS[key], isNotNull, reason: 'Missing English menu label: $key');
      expect(zhCH[key], isNotNull, reason: 'Missing Chinese menu label: $key');
    }
  });
}
