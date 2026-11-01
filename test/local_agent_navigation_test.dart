import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_skill_retriever.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/app/routing/router_config.dart';

class _ScriptedPlanner implements LocalAgentPlanner {
  _ScriptedPlanner(this._actions);
  final List<LocalAgentAction> _actions;
  @override
  Future<LocalAgentAction> next(LocalAgentTurn turn) async =>
      _actions[turn.step - 1];
}

List<LocalSkillManifest> _combinedManifests() => [
  ...LocalSkillManifest.fromCatalog(SkillCatalog.all),
  ...navigationManifests(),
];

void main() {
  test('retriever surfaces nav.settings for EN + ZH navigation phrasing', () {
    final r = LocalSkillRetriever(_combinedManifests());
    expect(
      r.retrieve('open the settings page').map((m) => m.id),
      contains('nav.settings'),
    );
    expect(r.retrieve('去设置看看').map((m) => m.id), contains('nav.settings'));
  });

  test(
    'local agent: nav.settings call → AppNavigate.openPage → navigates',
    () async {
      final navigated = <String>[];
      final registry = CapabilityRegistry()
        ..registerAll(
          buildNavigationCapabilities(
            navigate: navigated.add,
            currentRoute: () => '/home',
          ),
        );
      final manager = SkillManager()
        ..registerSkill(AppNavigateSkill(registry: registry));
      final planner = _ScriptedPlanner([
        LocalAgentAction.call('nav.settings', const {}),
        LocalAgentAction.finish('好的，已经打开设置。'),
      ]);

      // The runtime only honours a call whose skill is in this turn's retrieved
      // candidates — assert retrieval surfaces nav.settings so a failure points
      // unambiguously at retrieval vs. invocation.
      expect(
        LocalSkillRetriever(
          _combinedManifests(),
        ).retrieve('打开设置').map((m) => m.id),
        contains('nav.settings'),
      );

      final result = await LocalAgentRuntime(
        skillManager: manager,
        manifests: _combinedManifests(),
        planner: planner,
      ).run('打开设置');

      expect(result.status, LocalAgentRunStatus.finished);
      expect(navigated, [AppRoutes.settings]);
    },
  );
}
