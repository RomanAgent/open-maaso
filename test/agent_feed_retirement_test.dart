import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/capability/app_route_capability_policy.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_hub_route_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retired Feed routes and commands cannot open a destination', () {
    for (final path in const [
      '/agent-media',
      '/agent-videos',
      '/live',
      '/live/setup',
      '/live/feed',
      '/live/host',
      '/selfie',
      '/creator-studio',
    ]) {
      expect(appRoutePaths, isNot(contains(path)), reason: path);
      expect(snapshotRouteCapabilityKeysForLocation(path), isNull);
    }
    for (final command in const [
      '/agentfeed',
      '/直播',
      '/短视频',
      '/新闻',
      '/社区',
      '/连载',
      '/自拍',
      '/creator-studio',
    ]) {
      expect(AppRouteCatalog.resolveCommand(command), isNull, reason: command);
    }
    expect(AppletHubRouteIntent.tryParse('/agent-media?channel=games'), isNull);
    expect(AppletHubRouteIntent.tryParse('/game-feed'), isNotNull);
  });

  test('stale model requests cannot revive Feed on any host', () {
    for (final platform in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      final navigated = <String>[];
      final registry = CapabilityRegistry()
        ..registerAll(
          buildNavigationCapabilities(
            navigate: navigated.add,
            currentRoute: () => AppRouteCatalog.home,
            platformCapabilities: capabilities,
          ),
        );
      final skill = AppNavigateSkill(
        registry: registry,
        platformCapabilities: capabilities,
      );
      expect(
        skill.nativeToolSchemas!['openPage']!['properties'],
        isNot(contains('channel')),
      );
      for (final id in const [
        'agent_media',
        'creator_studio',
        'live',
        'selfie',
      ]) {
        final response =
            jsonDecode(
                  skill.methods['openPage']!([
                        {'page': id},
                      ])
                      as String,
                )
                as Map;
        expect(response['error'], 'unavailable_page', reason: '$platform: $id');
      }
      expect(navigated, isEmpty);
    }
    expect(SkillCatalog.all.any((skill) => skill.id == 'creator'), isFalse);
  });

  test('retained product destinations remain registered', () {
    for (final route in const [
      AppRouteCatalog.gameFeed,
      AppRouteCatalog.widgetsHub,
      AppRouteCatalog.myApplets,
      AppRouteCatalog.skillStore,
      AppRouteCatalog.avatars,
      AppRouteCatalog.agentSpace,
      AppRouteCatalog.settings,
    ]) {
      expect(appRoutePaths, contains(route));
      expect(
        AppRouteCatalog.destinations.any(
          (destination) => destination.route == route,
        ),
        isTrue,
      );
    }
  });
}
