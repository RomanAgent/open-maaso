import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/agent/application/capability/capability.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('capability model depends on risk metadata without importing manifests', () {
    final source = File(
      'lib/src/features/agent/application/capability/capability.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        "import 'package:maaso/src/features/agent/application/local_skill_risk.dart';",
      ),
    );
    expect(
      source,
      isNot(
        contains(
          "import 'package:maaso/src/features/agent/application/local_skill_manifest.dart'",
        ),
      ),
    );
  });

  test('local skill manifest does not import the skill catalog', () {
    final source = File(
      'lib/src/features/agent/application/local_skill_manifest.dart',
    ).readAsStringSync();

    expect(
      source,
      isNot(
        contains(
          "import 'package:maaso/src/features/agent/application/skill_catalog.dart';",
        ),
      ),
    );
    expect(source, contains('abstract class LocalSkillManifestProvider'));
  });

  test(
    'intent gate: nav verbs/questions pass, plain keyword mentions do not',
    () {
      // Should pass — explicit navigation verbs or "where" questions.
      expect(looksLikeNavigationIntent('打开设置'), isTrue);
      expect(looksLikeNavigationIntent('带我去朋友圈'), isTrue);
      expect(looksLikeNavigationIntent('设置在哪'), isTrue);
      expect(looksLikeNavigationIntent('回主页'), isTrue);
      expect(looksLikeNavigationIntent('where is the memory wall'), isTrue);
      expect(looksLikeNavigationIntent('open settings'), isTrue);
      expect(looksLikeNavigationIntent('Show me my moments'), isTrue);
      // Should NOT pass — everyday sentences that merely contain nav keywords
      // (聊天/设置/…) without any navigation verb. These previously routed
      // chitchat into the 4-step local agent loop.
      expect(looksLikeNavigationIntent('我们聊聊天吧'), isFalse);
      expect(looksLikeNavigationIntent('帮我设置个闹钟'), isFalse);
      expect(looksLikeNavigationIntent("let's chat about movies"), isFalse);
      expect(looksLikeNavigationIntent('今天天气真好'), isFalse);
    },
  );

  test('one navigate capability per destination', () {
    final caps = buildNavigationCapabilities(
      navigate: (_) {},
      currentRoute: () => '/home',
    );
    expect(caps.length, AppRoutes.destinations.length);
    for (final cap in caps) {
      expect(cap.kind, CapabilityKind.navigate);
      expect(cap.id, startsWith('nav.'));
    }
    expect(caps.any((c) => c.id == 'nav.settings'), isTrue);
    expect(caps.any((c) => c.id == 'nav.agent_space'), isTrue);
    expect(caps.any((c) => c.id == 'nav.game_feed'), isTrue);
    expect(caps.any((c) => c.id == 'nav.widgets_hub'), isTrue);
    expect(caps.any((c) => c.id == 'nav.agent_media'), isFalse);
    expect(caps.any((c) => c.id == 'nav.live'), isFalse);
    expect(caps.any((c) => c.id == 'nav.agent_videos'), isFalse);
  });

  test('Agent space navigation exposes no map variants', () {
    final locations = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: locations.add,
      currentRoute: () => '/home',
    );
    caps.singleWhere((cap) => cap.id == 'nav.agent_space').run(const {});
    expect(locations, [AppRoutes.agentSpace]);
    expect(
      navigationManifests().any((manifest) => manifest.id == 'nav.agent_space'),
      isTrue,
    );
    expect(
      navigationManifests().where(
        (manifest) => manifest.id.startsWith('nav.agent_space.'),
      ),
      isEmpty,
    );
  });

  test('advanced navigation capability and manifest are desktop-only', () {
    const web = AppPlatformCapabilities.forPlatform(AppHostPlatform.web);
    const desktop = AppPlatformCapabilities.forPlatform(AppHostPlatform.macos);

    final webCaps = buildNavigationCapabilities(
      navigate: (_) {},
      currentRoute: () => '/home',
      platformCapabilities: web,
    );
    final desktopCaps = buildNavigationCapabilities(
      navigate: (_) {},
      currentRoute: () => '/home',
      platformCapabilities: desktop,
    );
    final webManifests = navigationManifests(platformCapabilities: web);
    final desktopManifests = navigationManifests(platformCapabilities: desktop);

    expect(webCaps.any((cap) => cap.id == 'nav.advanced_features'), isFalse);
    expect(desktopCaps.any((cap) => cap.id == 'nav.advanced_features'), isTrue);
    expect(
      webManifests.any((manifest) => manifest.id == 'nav.advanced_features'),
      isFalse,
    );
    expect(
      desktopManifests.any(
        (manifest) => manifest.id == 'nav.advanced_features',
      ),
      isTrue,
    );
  });

  test('slash discovery and resolution hide unavailable destinations', () {
    const web = AppPlatformCapabilities.forPlatform(AppHostPlatform.web);
    const desktop = AppPlatformCapabilities.forPlatform(AppHostPlatform.macos);

    expect(
      availableNavigationCommandList(platformCapabilities: web),
      isNot(contains('/advanced_features')),
    );
    expect(
      resolveAvailableNavigationCommand('/advanced', platformCapabilities: web),
      isNull,
    );
    expect(
      availableNavigationCommandList(platformCapabilities: desktop),
      contains('/advanced_features'),
    );
    expect(
      resolveAvailableNavigationCommand(
        '/advanced',
        platformCapabilities: desktop,
      ),
      AppRouteCatalog.advancedFeatures,
    );
    expect(
      resolveAvailableNavigationCommand(
        '/onboarding',
        platformCapabilities: web,
      ),
      AppRouteCatalog.onboarding,
    );
    for (final capabilities in <AppPlatformCapabilities>[web, desktop]) {
      expect(
        resolveAvailableNavigationCommand(
          '/live',
          platformCapabilities: capabilities,
        ),
        isNull,
      );
    }
  });

  test('running a capability calls navigate with the destination route', () {
    final navigated = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => '/home',
    );
    final settings = caps.firstWhere((c) => c.id == 'nav.settings');
    final result = settings.run(const {});

    expect(result.ok, isTrue);
    expect(navigated, [AppRoutes.settings]);
  });

  test('the Agent space capability opens the local room route', () {
    final navigated = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => '/home',
    );

    caps.firstWhere((c) => c.id == 'nav.agent_space').run(const {});

    expect(navigated, [AppRoutes.agentSpace]);
  });

  test('Game Feed and Applets capabilities open distinct routes', () {
    final navigated = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => '/home',
    );

    caps.firstWhere((cap) => cap.id == 'nav.game_feed').run(const {});
    caps.firstWhere((cap) => cap.id == 'nav.widgets_hub').run(const {});

    expect(navigated, [AppRoutes.gameFeed, AppRoutes.widgetsHub]);
  });

  test('does not re-navigate when already on the route', () {
    final navigated = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => AppRoutes.settings,
    );
    caps.firstWhere((c) => c.id == 'nav.settings').run(const {});
    expect(navigated, isEmpty);
  });

  test('registered navigation capability follows later locale changes', () {
    var locale = AppLocale.zh;
    final navigated = <String>[];
    final caps = buildNavigationCapabilities(
      navigate: navigated.add,
      currentRoute: () => '/home',
      localeProvider: () => locale,
    );
    final settings = caps.firstWhere((cap) => cap.id == 'nav.settings');

    expect(settings.title, '设置');
    expect(settings.description, contains('设置'));
    expect(settings.run(const {}).message, '已打开“设置”页面。');

    locale = AppLocale.en;
    expect(settings.title, 'Settings');
    expect(settings.description, 'Open the Settings page.');
    expect(settings.run(const {}).message, 'Opened Settings.');
  });

  test(
    'manifests bind page id via fixedArgs and target AppNavigate.openPage',
    () {
      final manifests = navigationManifests();
      final variantCount = AppRoutes.destinations.fold<int>(
        0,
        (count, destination) => count + destination.variants.length,
      );
      expect(manifests.length, AppRoutes.destinations.length + variantCount);
      final m = manifests.firstWhere((m) => m.id == 'nav.settings');
      expect(m.skillName, 'AppNavigate');
      expect(m.method, 'openPage');
      expect(m.fixedArgs, {'page': 'settings'});
      expect(m.tags, contains('设置'));
      expect(m.localEligible, isTrue);
      final gameFeed = manifests.firstWhere(
        (manifest) => manifest.id == 'nav.game_feed',
      );
      expect(gameFeed.fixedArgs, {'page': 'game_feed'});
      expect(gameFeed.tags, contains('小游戏'));
      final applets = manifests.firstWhere(
        (manifest) => manifest.id == 'nav.widgets_hub',
      );
      expect(applets.fixedArgs, {'page': 'widgets_hub'});
      expect(applets.tags, contains('小程序'));
    },
  );
}
