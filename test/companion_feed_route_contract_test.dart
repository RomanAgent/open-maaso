import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feed routes leave the companion summon surface to Home', () {
    final router = File(
      'lib/src/app/routing/router_config.dart',
    ).readAsStringSync();
    final shell = File('lib/src/app/app_agent_shell.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(router, isNot(contains('CompanionFeedHost')));
    expect(
      router,
      matches(
        r'_route\(\s*AppRoutes\.gameFeed,\s*'
        r'\([^)]*\)\s*=>\s*(?:const\s+)?GameFeedPage\(',
      ),
    );
    expect(router, contains('dependencies: AgentMediaRouteDependencies()'));
    expect(router, contains('child: AgentMediaHubPage('));

    expect(
      router,
      matches(
        r'_route\(\s*AppRoutes\.agentSpace,\s*'
        r'\([^)]*\)\s*=>\s*(?:const\s+)?AgentSpacePage\(',
      ),
    );
    expect(router, isNot(contains('WorldPage(')));
    expect(shell, contains('AppRouteCatalog.agentSpace'));
    final space = File(
      'lib/src/features/agent_space/presentation/agent_space_page.dart',
    ).readAsStringSync();
    expect(space, contains('includeWorld: true'));
    expect(space, contains('holdToWalk: true'));
    expect(
      router,
      matches(
        r'_route\(\s*AppRoutes\.widgetsHub,\s*'
        r'\([^)]*\)\s*=>\s*(?:const\s+)?WidgetsHubPage\(',
      ),
    );

    expect(shell, contains('CompanionSessionScope('));
    expect(shell, isNot(contains('CompanionAgentOverlay(')));
    expect(pubspec, isNot(contains('avatar-female-cutout.png')));
    expect(
      File(
        'lib/src/features/agent/presentation/companion/'
        'companion_agent_overlay.dart',
      ).existsSync(),
      isFalse,
    );
  });
}
