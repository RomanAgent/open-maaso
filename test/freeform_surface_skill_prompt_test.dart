import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';

const _authoringSkillIds = {
  'freeform_surface',
  'card',
  'artifact',
  'playable_game',
};

void main() {
  test('freeform surface skill is registered with all surface methods', () {
    final catalogSource = File(
      'lib/src/features/agent/application/skill_catalog.dart',
    ).readAsStringSync();
    final skillFile = File(
      'lib/src/features/agent/application/skills/freeform_surface_skill.dart',
    );
    final runtimeSource = skillFile.existsSync()
        ? skillFile.readAsStringSync()
        : '';
    final skill = SkillCatalog.byId('freeform_surface')!.factory!.call('agent');
    const methods = {
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    };

    expect(catalogSource, contains('FreeformSurfaceSkill'));
    expect(catalogSource, contains("id: 'freeform_surface'"));
    expect(skill.methods.keys, containsAll(methods));
    final schemas = skill.modelStructuredActionPromptSchemas;
    expect(skill.nativeToolSchemas, isNull);
    expect(schemas.methodNames, <String>['editSurface', 'revertSurface']);
    expect(schemas.schemaFor('listSurfaces'), isNull);
    expect(schemas.schemaFor('showSurface'), isNull);
    expect(schemas.schemaFor('reopenSurface'), isNull);
    expect(
      schemas.schemaFor('editSurface')?['required'],
      contains('surfaceId'),
    );
    expect(
      schemas.schemaFor('revertSurface')?['properties'],
      contains('revisionId'),
    );
    for (final method in methods) {
      expect(runtimeSource, contains("'$method'"));
    }
    expect(runtimeSource, isNot(contains('warm design system')));
    expect(runtimeSource, isNot(contains('template:"tictactoe"')));
  });

  test('active generated UI authoring prompt uses only FreeformSurface', () {
    final activeAuthoringSpecs = SkillCatalog.all
        .where((spec) => SkillCatalog.defaultEnabled.contains(spec.id))
        .where((spec) => _authoringSkillIds.contains(spec.id))
        .toList();
    final promptSections = activeAuthoringSpecs
        .map((spec) {
          final skill = spec.factory?.call('agent');
          if (skill == null) return '';
          return '${skill.description}\n${skill.methods.keys.join('\n')}';
        })
        .join('\n');
    final violations = <String>[];

    if (activeAuthoringSpecs.map((spec) => spec.id).toSet().join(',') !=
        'freeform_surface') {
      violations.add(
        'Active generated UI authoring ids are '
        '${activeAuthoringSpecs.map((spec) => spec.id).join(', ')}.',
      );
    }

    if (!promptSections.contains('showSurface')) {
      violations.add('showSurface is not present in the active UI prompt.');
    }

    const forbiddenLegacyTerms = [
      'CardControl',
      'PlayableGame',
      'Artifact',
      'showCard',
      'createPlayableGame',
      'createArtifact',
    ];
    for (final term in forbiddenLegacyTerms) {
      if (promptSections.contains(term)) {
        violations.add('Legacy authoring term "$term" is model-visible.');
      }
    }

    final forbiddenTemplateDocs = [
      RegExp(r'\{html,\s*manifest,\s*backend\}'),
      RegExp(r'\bhtml:\s*"'),
      RegExp(r'\bmanifest:\s*\{'),
      RegExp(r'\bbackend:\s*\{'),
      RegExp(r'\bStatic dashboard; no card events\.'),
      RegExp(r"\bToday's market movers\b", caseSensitive: false),
    ];
    for (final pattern in forbiddenTemplateDocs) {
      if (pattern.hasMatch(promptSections)) {
        violations.add('Legacy card/template docs are model-visible: $pattern');
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'AgentRuntime prompts preserve browser creative freedom in both locales',
    () {
      final source = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();
      final promptCatalogs = <String, String>{
        'en': File(
          'lib/src/core/prompts/bundles/runtime_prompts_en.dart',
        ).readAsStringSync(),
        'zh': File(
          'lib/src/core/prompts/bundles/runtime_prompts_zh.dart',
        ).readAsStringSync(),
      };
      final promptSections = [
        _slice(
          source,
          'String _responseTracksBlock(',
          'List<_PromptSection> _structuredPrompt(',
        ),
        _slice(
          source,
          'List<_PromptSection> _structuredPrompt(',
          'static String _plain',
        ),
        _slice(
          source,
          'String _compactWidgetGuide',
          'String _compactGossipGuide',
        ),
        ...promptCatalogs.values,
      ].join('\n');
      final violations = <String>[];

      if (!promptSections.contains('surface.show')) {
        violations.add(
          'AgentRuntime prompt sections do not name surface.show.',
        );
      }
      if (!promptSections.contains('"experienceType":"game|utility"')) {
        violations.add('AgentRuntime prompt does not type game surfaces.');
      }

      const requiredMarkers = <String, List<String>>{
        'en': [
          'ordinary browser HTML, CSS and JavaScript',
          'External dependencies may require a connection',
          'not by itself a reason to reject',
          'not a precondition for creating a working project',
          'host-app theme or a fixed template',
          'legacy Game.define contract',
          '"rendering":"dom|canvas|svg|three|pixi|hybrid|webApp|workerCanvas"',
        ],
        'zh': [
          '普通浏览器 HTML、CSS 和 JavaScript',
          '外部依赖可能需要联网',
          '不是拒绝作品、删除功能或改写成离线替代品的理由',
          '不是先做出可用作品的前提',
          '不强制继承 Maaso 宿主主题',
          '旧版 Game.define 协议',
          '"rendering":"dom|canvas|svg|three|pixi|hybrid|webApp|workerCanvas"',
        ],
      };
      for (final catalog in promptCatalogs.entries) {
        final normalized = catalog.value.replaceAll(RegExp(r'\s+'), ' ');
        for (final marker in requiredMarkers[catalog.key]!) {
          if (!normalized.contains(marker)) {
            violations.add(
              '${catalog.key} creative-authoring prompt is missing "$marker".',
            );
          }
        }
      }

      final normalizedPromptSections = promptSections.replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      const forbiddenWorkerDefaults = <String>[
        'Every new game must be publicly publishable',
        'self-contained public-safe webApp',
        'CSS must not use url()',
        'no network, storage, navigation, dynamic code, innerHTML, src, or href',
        'setAttribute is allowed only with a fixed literal safe name',
        'maaso-white-frost/v2',
        '每个新游戏都必须可公开发布',
        '自包含公开安全 webApp',
        'CSS 不能使用 url()',
        '不能使用网络、存储、导航、动态代码、innerHTML、src 或 href',
        'setAttribute 只允许使用固定字面量安全属性名',

        'Games must use the declarative workerCanvas contract',
        'A game must use rendering workerCanvas',
        'Every game must set rendering to workerCanvas',
        'implement gameplay only with declarative workerCanvas',
        'For workerCanvas, keep html and css empty',
        'Use update frame time (time/dt) instead of timers',
        'Do not use Canvas, getContext, DOM, Window',
        '游戏必须使用声明式 workerCanvas 协议',
        '游戏必须把 rendering 设为 workerCanvas',
        '每个游戏都必须把 rendering 设为 workerCanvas',
        '玩法只能通过声明式 workerCanvas',
        'workerCanvas 的 html 和 css 必须为空',
        '不要使用计时器或异步 API',
        '不要使用 Canvas、getContext、DOM',
        '必须使用 workerCanvas，以便',
        'Use workerCanvas only for legacy content or when the user explicitly asks for public sharing',
        '仅对 legacy 内容或用户明确要求公开分享时使用 workerCanvas',
        'Rich local games default to rendering webApp',
        'Rich local games default to webApp',
        'remain local by default',
        '富本地游戏默认使用 rendering=webApp',
        '富本地游戏默认使用 webApp',
        '默认只保留在本地',
      ];
      for (final staleRule in forbiddenWorkerDefaults) {
        if (normalizedPromptSections.contains(staleRule)) {
          violations.add('AgentRuntime prompt retains "$staleRule".');
        }
      }

      const forbiddenLegacyTerms = [
        'CardControl',
        'PlayableGame',
        'Artifact',
        'showCard',
        'createPlayableGame',
        'createArtifact',
      ];
      for (final term in forbiddenLegacyTerms) {
        if (promptSections.contains(term)) {
          violations.add('AgentRuntime prompt leaks "$term".');
        }
      }

      final forbiddenTemplateDocs = [
        RegExp(r'\{html,\s*manifest,\s*backend\}'),
        RegExp(r'\bhtml:\s*"'),
        RegExp(r'\bmanifest:\s*\{'),
        RegExp(r'\bbackend:\s*\{'),
        RegExp(r'\bStatic dashboard; no card events\.'),
        RegExp(r"\bToday's market movers\b", caseSensitive: false),
      ];
      for (final pattern in forbiddenTemplateDocs) {
        if (pattern.hasMatch(promptSections)) {
          violations.add(
            'AgentRuntime prompt leaks old template docs: $pattern',
          );
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('generated UI local brain cues route to FreeformSurface', () async {
    final backend = HeuristicLocalBackend();
    for (final text in const [
      "let's play a game",
      'build me a floating canvas animation',
      'write a blog post about today',
      'show me a stats dashboard',
      '做一个小程序看板',
    ]) {
      final route = await backend.route(text);
      expect(route.needsTools, contains('freeform_surface'), reason: text);
      expect(route.needsTools, isNot(contains('card')), reason: text);
      expect(route.intent, LocalIntent.task, reason: text);
    }
  });

  test('turn policy requires an explicit game or mini-app creation noun', () {
    final engine = TurnPolicyEngine(agentId: 'self');
    for (final (text, shouldCreateSurface) in const <(String, bool)>[
      ('make me an Aippy-like mini game', true),
      ('create an interactive rainy cyberpunk scene', false),
      ('turn this into a dashboard', false),
      ('write a blog post as a mini app', true),
    ]) {
      final policy = engine.decide(
        TurnContext(
          userText: text,
          routing: const RoutingDecision(
            intent: LocalIntent.task,
            confidence: 0.8,
            emotionPreemit: 'neutral',
            needsTools: ['freeform_surface'],
          ),
        ),
      );

      if (shouldCreateSurface) {
        expect(
          policy.preferredSkills,
          contains('FreeformSurface'),
          reason: text,
        );
        expect(policy.promptBlock, contains('FreeformSurface'), reason: text);
      } else {
        expect(
          policy.preferredSkills,
          isNot(contains('FreeformSurface')),
          reason: text,
        );
      }
      expect(
        policy.preferredSkills,
        isNot(contains('CardControl')),
        reason: text,
      );
      expect(policy.preferredSkills, isNot(contains('Artifact')), reason: text);
      expect(
        policy.preferredSkills,
        isNot(contains('PlayableGame')),
        reason: text,
      );
      expect(policy.promptBlock, isNot(contains('CardControl')), reason: text);
      expect(policy.promptBlock, isNot(contains('Artifact')), reason: text);
      expect(policy.promptBlock, isNot(contains('PlayableGame')), reason: text);
    }
  });
}

String _slice(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  expect(start, isNonNegative, reason: 'Missing $startMarker');
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, isNonNegative, reason: 'Missing $endMarker after $startMarker');
  return source.substring(start, end);
}
