import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

void main() {
  final index = SkillIndex([
    for (final spec in SkillCatalog.all)
      if (spec.hostRouting != null && spec.isAvailable)
        AgentSkillDescriptorFactory.fromManifest(
          spec.hostRouting!,
          locale: AppLocale.en,
        ),
  ]);
  final selector = TurnSkillSelector(
    index: index,
    router: SkillRouter(index: index),
  );

  test('authorized creation beside a question retains its task route', () {
    for (final request in const [
      '你喜欢玩什么游戏，帮我做一个出来',
      '你比较喜欢什么游戏？给我做一个小游戏',
      '什么是游戏，帮我做一个小游戏',
      '先说什么是游戏，然后帮我做一个小游戏',
    ]) {
      final selection = selector.select(
        request,
        preferredSkillIds: ['FreeformSurface', 'Creator', 'AppControl'],
        resolvedCreation: SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        ),
      );
      // AgentRuntime uses this reason to neutralize every execution path.
      expect(
        selection.decision.reason,
        isNot('non_action_context'),
        reason: request,
      );
      expect(selection.grant.allowedSkillIds, {
        'FreeformSurface',
      }, reason: request);
    }
  });

  test('typed hints cannot convert quoted or declined requests into tasks', () {
    for (final request in const [
      '什么是“帮我做一个小游戏”？',
      '翻译“帮我做一个小游戏”',
      '你喜欢什么游戏，只聊天，不要生成小游戏',
      '什么是游戏，先不要生成小游戏',
      '帮我做一个小游戏需要多久？',
      '什么是游戏，帮我做一个小游戏，但不要保存',
    ]) {
      final selection = selector.select(
        request,
        preferredSkillIds: ['FreeformSurface'],
        resolvedCreation: SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        ),
      );
      expect(
        selection.grant.allows('FreeformSurface'),
        isFalse,
        reason: request,
      );
    }
  });

  test('another request type cannot bypass lexical abstention', () {
    const request = '什么是游戏，先不要生成小游戏';
    final selection = selector.select(
      request,
      preferredSkillIds: ['FreeformSurface'],
      resolvedCreation: SurfaceIntent.fromResolvedCreation(
        userText: '生成一个小游戏',
        kind: SurfaceIntentKind.game,
      ),
    );
    expect(selection.decision.reason, 'non_action_context');
    expect(selection.grant.isEmpty, isTrue);
  });
}
