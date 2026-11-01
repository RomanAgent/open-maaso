import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_zh.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';

void main() {
  test('AppletDiscovery manifest exactly matches four executable methods', () {
    final spec = SkillCatalog.byId('applet_discovery')!;
    final manifest = spec.hostRouting!;
    final skill = spec.factory!('self');

    expect(manifest.methods, const <String>[
      'search',
      'open',
      'describeApplet',
      'useApplet',
    ]);
    expect(manifest.nativeMethods, const <String>[
      'search',
      'open',
      'describeApplet',
      'useApplet',
    ]);
    expect(manifest.methods.toSet(), skill.methods.keys.toSet());
    expect(
      manifest.nativeMethods.toSet(),
      skill.nativeToolSchemas!.keys.toSet(),
    );
    expect(manifest.nativeToolNames, <String>[
      HostSkillRoutingManifest.nativeToolName('AppletDiscovery', 'search'),
      HostSkillRoutingManifest.nativeToolName('AppletDiscovery', 'open'),
      HostSkillRoutingManifest.nativeToolName(
        'AppletDiscovery',
        'describeApplet',
      ),
      HostSkillRoutingManifest.nativeToolName('AppletDiscovery', 'useApplet'),
    ]);
    expect(manifest.terms, containsAll(<String>['旅游小程序', '工具小程序']));
  });

  test('lazy registry activates AppletDiscovery only after an exact grant', () {
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: <SkillSpec>[SkillCatalog.byId('applet_discovery')!],
    );
    final descriptor = registry.descriptorFor('AppletDiscovery')!;

    expect(registry.activeCount, 0);
    final executable = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: <SkillDescriptor>[descriptor],
        maxSkills: 1,
        promptBudget: descriptor.promptCost,
      ),
    );

    expect(registry.activeCount, 1);
    expect(executable.allowedSkillNames, const <String>{'AppletDiscovery'});
    expect(
      executable
          .authorize(
            agentId: 'self',
            tool: HostSkillRoutingManifest.nativeToolName(
              'AppletDiscovery',
              'open',
            ),
          )
          ?.method,
      'open',
    );
  });

  test('bounded prompts describe category search and opaque one-shot open', () {
    expect(
      skillPromptsEn['skill.AppletDiscovery.schema.search.category'],
      contains('travel'),
    );
    expect(
      skillPromptsZh['skill.AppletDiscovery.schema.search.category'],
      contains('旅游'),
    );
    expect(
      skillPromptsEn['skill.AppletDiscovery.schema.open.id'],
      allOf(contains('opaque'), contains('never pass a title or URL')),
    );
    expect(
      skillPromptsZh['skill.AppletDiscovery.schema.open.id'],
      allOf(contains('不透明 ID'), contains('不得传入标题或网址')),
    );
    expect(
      runtimePromptsEn['runtime.policy.applet_discovery'],
      allOf(contains('bounded first page'), contains('AppletDiscovery.open')),
    );
    expect(
      runtimePromptsZh['runtime.policy.applet_discovery'],
      allOf(contains('有界首屏'), contains('AppletDiscovery.open')),
    );
    for (final prompt in <String>[
      runtimePromptsEn['runtime.policy.applet_discovery']!,
      runtimePromptsZh['runtime.policy.applet_discovery']!,
    ]) {
      expect(prompt, contains('AppletDiscovery.describeApplet'));
      expect(prompt, contains('AppletDiscovery.useApplet'));
    }
  });
}
