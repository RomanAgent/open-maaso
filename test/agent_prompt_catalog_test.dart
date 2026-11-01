import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/legacy_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/legacy_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_zh.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  group('AgentPromptCatalog', () {
    test('English and Chinese bundles expose exactly the same keys', () {
      expect(
        AgentPromptCatalog.keysFor(AppLocale.zh),
        AgentPromptCatalog.keysFor(AppLocale.en),
      );
    });

    test('translated templates expose exactly the same placeholders', () {
      final en = AgentPromptCatalog.resourcesFor(AppLocale.en);
      final zh = AgentPromptCatalog.resourcesFor(AppLocale.zh);
      final placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');

      for (final key in en.keys) {
        final enNames = placeholder
            .allMatches(en[key]!)
            .map((match) => match.group(0))
            .toSet();
        final zhNames = placeholder
            .allMatches(zh[key]!)
            .map((match) => match.group(0))
            .toSet();
        expect(zhNames, enNames, reason: 'placeholder mismatch for $key');
      }
    });

    test('each prompt domain has independent bilingual key parity', () {
      final domains = <String, (Map<String, String>, Map<String, String>)>{
        'runtime': (runtimePromptsEn, runtimePromptsZh),
        'app': (appPromptsEn, appPromptsZh),
        'legacy': (legacyPromptsEn, legacyPromptsZh),
        'skill': (skillPromptsEn, skillPromptsZh),
      };
      for (final entry in domains.entries) {
        expect(
          entry.value.$2.keys.toSet(),
          entry.value.$1.keys.toSet(),
          reason: '${entry.key} prompt bundle key mismatch',
        );
      }
    });

    test('English fixed prompts contain no Chinese prose', () {
      final han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]');
      for (final entry in AgentPromptCatalog.resourcesFor(
        AppLocale.en,
      ).entries) {
        expect(
          han.hasMatch(entry.value),
          isFalse,
          reason: 'English prompt ${entry.key} contains Chinese prose',
        );
      }
    });

    test('Chinese fixed prompts are backed by Chinese resources', () {
      final han = RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]');
      final placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');
      final latinProse = RegExp(r'[A-Za-z]');
      for (final entry in AgentPromptCatalog.resourcesFor(
        AppLocale.zh,
      ).entries) {
        final literal = entry.value.replaceAll(placeholder, '');
        if (!latinProse.hasMatch(literal)) continue;
        expect(
          han.hasMatch(entry.value),
          isTrue,
          reason: 'Chinese prompt ${entry.key} has no Chinese resource text',
        );
      }
    });

    test('Chinese fixed prompts contain no known English prose fragments', () {
      const forbidden = <String>[
        'CURRENT_USER_MESSAGE',
        '从 context、memory',
        'voice line',
        '点击 Start 后',
        'plain text shown in chat history',
        'short spoken line',
        'short user request',
      ];
      final zh = AgentPromptCatalog.resourcesFor(AppLocale.zh);
      for (final entry in zh.entries) {
        for (final phrase in forbidden) {
          expect(
            entry.value,
            isNot(contains(phrase)),
            reason: 'Chinese prompt ${entry.key} contains "$phrase"',
          );
        }
      }
    });

    test('Chinese fixed prompts contain no unapproved English phrases', () {
      final placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');
      final latinPhrase = RegExp(
        r'[A-Za-z][A-Za-z0-9_.-]*\s+[A-Za-z][A-Za-z0-9_.-]*',
      );
      const allowedTechnicalPhrases = <String>{
        'HTTPS GET',
        'HTTPS POST',
        'KiB UTF-8',
        'creation.intent JSON',
      };

      for (final entry in AgentPromptCatalog.resourcesFor(
        AppLocale.zh,
      ).entries) {
        // Interpolation names are not prose. Keep a separator so removing a
        // placeholder cannot join the frame markers on either side of it.
        final literal = entry.value.replaceAll(placeholder, '…');
        for (final match in latinPhrase.allMatches(literal)) {
          expect(
            allowedTechnicalPhrases,
            contains(match.group(0)),
            reason:
                'Chinese prompt ${entry.key} contains English prose '
                '"${match.group(0)}"',
          );
        }
      }
    });

    test('missing translations fail closed instead of falling back', () {
      expect(
        () => AgentPromptCatalog.text(
          'prompt.that.does.not.exist',
          locale: AppLocale.zh,
        ),
        throwsStateError,
      );
    });

    test('missing interpolation parameters fail closed', () {
      expect(
        () => AgentPromptCatalog.text(
          'runtime.policy.wrapper',
          locale: AppLocale.en,
        ),
        throwsStateError,
      );
      expect(
        AgentPromptCatalog.text(
          'runtime.policy.wrapper',
          locale: AppLocale.en,
          params: const {'parts': 'search'},
        ),
        '[policy: search]',
      );
    });
  });

  test('built-in native tool prose is localized without changing protocol', () {
    final manager = SkillManager()..registerSkill(AppNavigateSkill());
    bool isOpenPage(Map<String, dynamic> tool) =>
        (tool['function'] as Map)['name'] == 'skill_appnavigate_openpage';
    final en = manager
        .toNativeTools(locale: AppLocale.en)
        .singleWhere(isOpenPage);
    final zh = manager
        .toNativeTools(locale: AppLocale.zh)
        .singleWhere(isOpenPage);
    final enFunction = en['function'] as Map<String, dynamic>;
    final zhFunction = zh['function'] as Map<String, dynamic>;

    expect(zhFunction['name'], enFunction['name']);
    expect(zhFunction['name'], 'skill_appnavigate_openpage');
    expect(enFunction['description'], contains('Navigate'));
    expect(zhFunction['description'], contains('页面'));

    final enParameters = enFunction['parameters'] as Map<String, dynamic>;
    final zhParameters = zhFunction['parameters'] as Map<String, dynamic>;
    expect(zhParameters['type'], enParameters['type']);
    expect(zhParameters['required'], enParameters['required']);
    final enPage = (enParameters['properties'] as Map)['page'] as Map;
    final zhPage = (zhParameters['properties'] as Map)['page'] as Map;
    expect(zhPage['type'], enPage['type']);
    expect(zhPage['enum'], enPage['enum']);
    expect(enPage['description'], contains('page'));
    expect(zhPage['description'], contains('页面'));
  });

  test('third-party tool fallback preserves author prose verbatim', () {
    const authorDescription = '作者原文 @other must stay unchanged';
    final skill = _ThirdPartyPromptSkill(authorDescription);

    expect(
      AgentSkillPromptMetadata.methodDescription(
        skill,
        'custom_method',
        locale: AppLocale.zh,
      ),
      '$authorDescription\n[custom_method]',
    );
  });

  test('every registered built-in Skill has complete bilingual metadata', () {
    for (final spec in SkillCatalog.all.where((item) => item.factory != null)) {
      final skill = spec.factory!('prompt-catalog-test');
      expect(
        AgentSkillPromptMetadata.builtInSkillNames,
        contains(skill.skillName),
        reason: '${skill.skillName} is not registered as a built-in Skill',
      );
      expect(
        AgentSkillPromptMetadata.description(skill, locale: AppLocale.en),
        isNotEmpty,
      );
      expect(
        AgentSkillPromptMetadata.description(skill, locale: AppLocale.zh),
        isNotEmpty,
      );

      final schemas = skill.nativeToolSchemas ?? const {};
      for (final entry in schemas.entries) {
        expect(
          AgentSkillPromptMetadata.methodDescription(
            skill,
            entry.key,
            locale: AppLocale.en,
          ),
          isNotEmpty,
        );
        expect(
          AgentSkillPromptMetadata.methodDescription(
            skill,
            entry.key,
            locale: AppLocale.zh,
          ),
          isNotEmpty,
        );
        expect(
          AgentSkillPromptMetadata.schema(
            skill,
            entry.key,
            entry.value,
            locale: AppLocale.en,
          ),
          isNotEmpty,
        );
        expect(
          AgentSkillPromptMetadata.schema(
            skill,
            entry.key,
            entry.value,
            locale: AppLocale.zh,
          ),
          isNotEmpty,
        );
      }
    }
  });

  test('surface wrappers localize host prose but preserve author content', () {
    const manifest = SurfaceManifest(
      events: [
        SurfaceEntry('won', {'score': 'number'}),
      ],
      actions: [
        SurfaceEntry('jump', {'height': 'number'}),
      ],
      instructions: '作者原始说明 Author-owned instructions',
    );

    final en = manifest.toPromptText(
      'game-1',
      title: 'Orbit',
      locale: AppLocale.en,
    );
    final zh = manifest.toPromptText(
      'game-1',
      title: 'Orbit',
      locale: AppLocale.zh,
    );

    expect(en, contains('Active Surface'));
    expect(zh, contains('当前界面'));
    expect(en, contains(manifest.instructions));
    expect(zh, contains(manifest.instructions));
    expect(zh, isNot(contains('Active Surface')));
  });

  test('navigation prompt labels follow the selected locale', () {
    expect(
      navigationDestinationTitle('skill_store', locale: AppLocale.en),
      'Skill Store',
    );
    expect(
      navigationDestinationTitle('skill_store', locale: AppLocale.zh),
      '技能商店',
    );
  });
}

final class _ThirdPartyPromptSkill extends AgentSkill {
  _ThirdPartyPromptSkill(this._description);

  final String _description;

  @override
  String get skillName => 'ThirdPartyPromptSkill';

  @override
  String get description => _description;

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => const {};
}
