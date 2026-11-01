import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  test('every executable built-in has pure routing metadata', () {
    final executable = SkillCatalog.all.where(
      (spec) => !spec.isComingSoon && spec.factory != null,
    );

    expect(executable, isNotEmpty);
    expect(executable.every((spec) => spec.hostRouting != null), isTrue);
    expect(
      SkillCatalog.all
          .where((spec) => spec.isComingSoon || spec.factory == null)
          .every((spec) => spec.hostRouting == null),
      isTrue,
    );
  });

  test(
    'catalog preserves core defaults while retired World control is absent',
    () {
      final expectedDefaults = SkillCatalog.all
          .where((spec) => !spec.isComingSoon && spec.isAvailable)
          .map((spec) => spec.id)
          .toSet();
      expect(SkillCatalog.defaultEnabled, expectedDefaults);
      expect(SkillCatalog.defaultEnabled, containsAll(SkillCatalog.coreIds));
      expect(SkillCatalog.byId('world_control'), isNull);
      expect(
        SkillCatalog.all.any(
          (spec) => spec.hostRouting?.skillName == 'WorldControl',
        ),
        isFalse,
      );
      expect(SkillCatalog.coreIds, isNot(contains('world_control')));
      expect(SkillCatalog.byId('set_world'), isNotNull);
    },
  );

  test('manifest projection preserves existing built-in routing semantics', () {
    for (final spec in SkillCatalog.all.where(
      (item) => item.factory != null && item.hostRouting != null,
    )) {
      final skill = spec.factory!('agent-test');
      final manifest = spec.hostRouting!;
      final legacy = AgentSkillDescriptorFactory.fromSkill(
        skill,
        locale: AppLocale.en,
      );
      final projected = AgentSkillDescriptorFactory.fromManifest(
        manifest,
        locale: AppLocale.en,
      );

      expect(manifest.skillName, skill.skillName, reason: spec.id);
      expect(
        manifest.methods.toSet(),
        skill.methods.keys.toSet(),
        reason: spec.id,
      );
      expect(
        manifest.nativeMethods.toSet(),
        (skill.nativeToolSchemas ?? const <String, dynamic>{}).keys.toSet(),
        reason: spec.id,
      );
      expect(
        manifest.nativeToolNames,
        manifest.nativeMethods
            .map((method) => SkillManager.nativeToolName(skill, method))
            .toList(growable: false),
        reason: spec.id,
      );
      expect(projected.id, legacy.id, reason: spec.id);
      expect(projected.summary, legacy.summary, reason: spec.id);
      expect(projected.terms, containsAll(legacy.terms), reason: spec.id);
      expect(
        projected.positiveExamples,
        containsAll(legacy.positiveExamples),
        reason: spec.id,
      );
      expect(
        projected.negativeTerms,
        containsAll(legacy.negativeTerms),
        reason: spec.id,
      );
      expect(
        projected.negativeExamples,
        containsAll(legacy.negativeExamples),
        reason: spec.id,
      );
      expect(
        projected.pageScopes,
        containsAll(legacy.pageScopes),
        reason: spec.id,
      );
      expect(
        projected.professions,
        containsAll(legacy.professions),
        reason: spec.id,
      );
    }

    final appControl = AgentSkillDescriptorFactory.fromManifest(
      SkillCatalog.byId('app_control')!.hostRouting!,
      locale: AppLocale.en,
    );
    expect(appControl.terms, contains('操作app'));
    expect(appControl.terms, isNot(contains('发帖子')));
    expect(
      appControl.positiveExamples.any((example) => example.contains('讨论社区')),
      isFalse,
    );
  });

  test('manifest rejects native methods outside the executable method set', () {
    expect(
      () => HostSkillRoutingManifest(
        skillName: 'Broken',
        summary: 'Broken metadata.',
        methods: const <String>['run'],
        nativeMethods: const <String>['missing'],
      ),
      throwsArgumentError,
    );
  });
}
