import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

CapabilityRegistry _registryWith(
  List<String> navigated, {
  AppPlatformCapabilities? platformCapabilities,
}) {
  return CapabilityRegistry()..registerAll(
    buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => '/home',
      platformCapabilities: platformCapabilities,
    ),
  );
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('skill depends on route metadata without importing page router', () {
    final source = File(
      'lib/src/features/agent/application/skills/app_navigate_skill.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        "import 'package:maaso/src/app/routing/app_route_catalog.dart';",
      ),
    );
    expect(
      source,
      isNot(
        contains("import 'package:maaso/src/app/routing/router_config.dart';"),
      ),
    );
  });

  test('openPage navigates to a valid page and returns ok', () {
    final navigated = <String>[];
    final skill = AppNavigateSkill(registry: _registryWith(navigated));

    final out = skill.methods['openPage']!([
      jsonEncode({'page': 'settings'}),
    ]);
    final decoded = jsonDecode(out as String);

    expect(decoded['status'], 'ok');
    expect(decoded['page'], 'settings');
    expect(navigated, [AppRoutes.settings]);
  });

  test('openPage accepts a pre-decoded map (native tool channel)', () {
    final navigated = <String>[];
    final skill = AppNavigateSkill(registry: _registryWith(navigated));

    skill.methods['openPage']!([
      {'page': 'skills'},
    ]);
    expect(navigated, [AppRoutes.skills]);
  });

  test('openPage keeps Game Feed and Applets as distinct destinations', () {
    final navigated = <String>[];
    final skill = AppNavigateSkill(registry: _registryWith(navigated));

    final gameFeed = jsonDecode(
      skill.methods['openPage']!([
            {'page': 'game_feed'},
          ])
          as String,
    );
    final applets = jsonDecode(
      skill.methods['openPage']!([
            {'page': 'widgets_hub'},
          ])
          as String,
    );

    expect(gameFeed['status'], 'ok');
    expect(gameFeed['page'], 'game_feed');
    expect(applets['status'], 'ok');
    expect(applets['page'], 'widgets_hub');
    expect(navigated, [AppRoutes.gameFeed, AppRoutes.widgetsHub]);
  });

  test('openPage with an unknown page returns an error listing valid ids', () {
    final skill = AppNavigateSkill(registry: _registryWith(<String>[]));
    final decoded = jsonDecode(
      skill.methods['openPage']!([
            jsonEncode({'page': 'nope'}),
          ])
          as String,
    );

    expect(decoded['error'], isNotNull);
    expect((decoded['valid'] as List), contains('settings'));
  });

  test('listPages returns the destination catalog', () {
    final skill = AppNavigateSkill(registry: _registryWith(<String>[]));
    final decoded = jsonDecode(skill.methods['listPages']!(const []) as String);
    final ids = (decoded['pages'] as List).map((p) => p['id']).toList();

    expect(ids, contains('settings'));
    expect(ids, contains('game_feed'));
    expect(ids, contains('widgets_hub'));
    expect(ids, isNot(contains('agent_media')));
    expect(ids, isNot(contains('live')));
    expect(ids, isNot(contains('agent_videos')));
    expect(ids.length, AppRoutes.destinations.length);
  });

  test('web schema, list, and open all hide advanced settings', () {
    const web = AppPlatformCapabilities.forPlatform(AppHostPlatform.web);
    final navigated = <String>[];
    final skill = AppNavigateSkill(
      registry: _registryWith(navigated, platformCapabilities: web),
      platformCapabilities: web,
    );

    final pageEnum =
        skill.nativeToolSchemas!['openPage']!['properties']['page']['enum']
            as List;
    final listed = jsonDecode(skill.methods['listPages']!(const []) as String);
    final listedIds = (listed['pages'] as List)
        .map((page) => page['id'])
        .toList();
    final opened = jsonDecode(
      skill.methods['openPage']!([
            {'page': 'advanced_features'},
          ])
          as String,
    );

    expect(pageEnum, isNot(contains('advanced_features')));
    expect(listedIds, isNot(contains('advanced_features')));
    expect(opened['error'], 'unavailable_page');
    expect(navigated, isEmpty);
  });

  test('openPage with empty args returns error', () {
    final skill = AppNavigateSkill(registry: _registryWith(<String>[]));
    final decoded = jsonDecode(skill.methods['openPage']!(const []) as String);
    expect(decoded['error'], isNotNull);
  });

  test('openPage refuses non-self agents (peers cannot navigate the app)', () {
    final navigated = <String>[];
    final skill = AppNavigateSkill(
      registry: _registryWith(navigated),
      agentId: 'peer-1',
    );
    final decoded = jsonDecode(
      skill.methods['openPage']!([
            jsonEncode({'page': 'settings'}),
          ])
          as String,
    );

    expect(decoded['error'], isNotNull);
    expect(navigated, isEmpty);
  });

  test('catalog factory propagates agentId so a2a peers get the guard', () {
    final spec = SkillCatalog.byId('app_navigate')!;
    expect((spec.factory!('peer-1') as AppNavigateSkill).agentId, 'peer-1');
    expect((spec.factory!('self') as AppNavigateSkill).agentId, 'self');
  });

  test('app_navigate is a core skill in the catalog', () {
    final spec = SkillCatalog.byId('app_navigate');
    expect(spec, isNotNull);
    expect(spec!.isCore, isTrue);
    expect(SkillCatalog.defaultEnabled, contains('app_navigate'));
    expect(spec.factory, isNotNull);
    expect(spec.factory!('self').skillName, 'AppNavigate');
  });

  test('native tool schemas only advertise real method keys', () {
    final skill = AppNavigateSkill(registry: _registryWith(<String>[]));
    final advertised = skill.nativeToolSchemas!.keys.toSet();

    expect(advertised, isNotEmpty);
    for (final name in advertised) {
      expect(skill.methods.keys, contains(name), reason: name);
    }
  });
}
