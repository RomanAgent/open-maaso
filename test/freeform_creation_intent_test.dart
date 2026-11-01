import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';

const _breakout =
    '生成一个底下有条杠，球会掉下来然后杠必须要接住，上面有很多小方块，'
    '球接触小方块小方块就会消失掉，全部小方块消失掉即可进入下一关，'
    '小方块消掉的时候会掉下道具，可以让球分裂开来';

void main() {
  final router = TurnRouterGateway(
    policyEngine: TurnPolicyEngine(agentId: 'self'),
    orchestrator: const AgentTurnOrchestrator(),
  );

  test('mixed requests keep the full brief and route the requested output', () {
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
    for (final entry in const {
      '你喜欢玩什么游戏，帮我做一个出来': SurfaceIntentKind.game,
      '如何制作小游戏，帮我做一个出来': SurfaceIntentKind.game,
      '你觉得怎样记账方便，帮我做一个可以添加支出、按分类汇总并删除记录的工具': SurfaceIntentKind.applet,
      'What kind of game do you prefer? Please build one with touch controls':
          SurfaceIntentKind.game,
      'I keep losing track of bills, make a tool that groups expenses by month':
          SurfaceIntentKind.applet,
    }.entries) {
      final hint = SurfaceIntent.fromResolvedCreation(
        userText: entry.key,
        kind: entry.value,
      );
      expect(hint.matchesResolvedRequest(entry.key), isTrue);
      expect(
        hint.matchesResolvedRequest(entry.key.split('，').last),
        entry.key.contains('，') ? isFalse : isTrue,
      );
      final decision = router.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(userText: entry.key, resolvedSurfaceIntent: hint),
      );
      expect(decision.primaryRoute, PrimaryRoute.surface, reason: entry.key);
      expect(decision.plan.requiresBackgroundJob, isTrue, reason: entry.key);
      expect(
        decision.plan.taskKind,
        entry.value == SurfaceIntentKind.game
            ? AgentTaskKind.gameGeneration
            : AgentTaskKind.surfaceGeneration,
        reason: entry.key,
      );
      final selection = selector.select(
        entry.key,
        preferredSkillIds: decision.policy.preferredSkills,
        resolvedCreation: decision.policy.surface,
      );
      expect(
        selection.decision.reason,
        isNot('non_action_context'),
        reason: entry.key,
      );
      expect(
        selection.grant.allows('FreeformSurface'),
        isTrue,
        reason: entry.key,
      );
      expect(selection.grant.allows('WebSearch'), isFalse, reason: entry.key);
    }
  });

  test(
    'instructions inside the requested product are content, not an outer inquiry',
    () {
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
      for (final request in const [
        '生成一个球掉下来、挡板接球、砖块会消失的作品，附一段说明如何操作',
        'Build a draggable puzzle and include instructions that explain how to restart',
        '生成一个可以拖动星星来改变重力的作品，首页告诉我怎么操作',
        '生成一个带挡板和砖块的作品，教程解释什么情况下进入下一关',
        '生成一个球接杠的小游戏，加入说明告诉我怎么玩',
      ]) {
        expect(
          SurfaceCreationAuthority.canResolveCreation(request),
          isTrue,
          reason: request,
        );
        final hint = SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        );
        final decision = router.resolve(
          origin: TurnOrigin.user,
          context: TurnContext(userText: request, resolvedSurfaceIntent: hint),
        );
        expect(
          decision.plan.taskKind,
          AgentTaskKind.gameGeneration,
          reason: request,
        );
        expect(decision.plan.requiresBackgroundJob, isTrue);
        final selection = selector.select(
          request,
          preferredSkillIds: ['FreeformSurface', 'WebSearch'],
          resolvedCreation: hint,
        );
        expect(
          selection.grant.allows('FreeformSurface'),
          isTrue,
          reason: request,
        );
        expect(selection.grant.allows('WebSearch'), isFalse, reason: request);
      }
      for (final request in const [
        '生成一个球接杠的作品需要多久？',
        '生成一个球接杠的作品，附一段操作说明，但不要保存',
        '生成一个球接杠的作品，首页告诉我怎么操作，先别展示',
        '生成一个球接杠的作品，说明如何生成这种作品？',
        '生成一个球接杠的小游戏，说明如何生成这种小游戏？',
        '生成一个球接杠的作品，加入操作说明，但选哪个更好？',
        'Build a puzzle and include instructions, but how much will building it cost?',
        'Write instructions that explain how to restart a ball-catching game',
        '“生成一个球接杠的作品，附说明如何操作”',
      ]) {
        expect(
          SurfaceCreationAuthority.canResolveCreation(request),
          isFalse,
          reason: request,
        );
        final hint = SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        );
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: request,
            interactiveHint: true,
            surfaceIntent: hint,
          ),
          isNull,
          reason: request,
        );
      }
    },
  );

  test(
    'game words modifying the utility object do not defeat a bound semantic type',
    () {
      for (final request in const [
        '生成一个记录游戏分数的工具，支持添加、修改和删除成绩',
        'Build a score tracker for games with add, edit and delete controls',
        '生成一个统计玩家游戏时长的工具，按日期显示报表',
      ]) {
        final hint = SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.applet,
        );
        final surface = SurfaceCreationAuthority.resolveSurfaceIntent(
          text: request,
          resolvedSurfaceIntent: hint,
        );
        expect(surface.kind, SurfaceIntentKind.applet, reason: request);
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: request,
            interactiveHint: true,
            surfaceIntent: surface,
          ),
          SurfaceExperienceType.utility,
        );
      }
    },
  );

  test('resolved arbitrary gameplay starts a typed task without product words', () {
    for (final request in const [
      _breakout,
      '写一个角色跟着我的手指跑，碰到星星就加分，收集够了就进下一关',
      '帮我做一个由声音改变重力、每次失误会重置地形的互动作品',
      '生成一个球会不断弹起、触屏可以改变方向并带有玩法说明的作品',
      'Build something where dragging a moon changes gravity and reaching a portal starts the next level',
      'Write something with a tutorial that lets me move stars by dragging them',
    ]) {
      expect(
        SurfaceCreationAuthority.canResolveCreation(request),
        isTrue,
        reason: request,
      );
      final hint = SurfaceIntent.fromResolvedCreation(
        userText: request,
        kind: SurfaceIntentKind.game,
      );
      final decision = router.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(userText: request, resolvedSurfaceIntent: hint),
      );
      expect(decision.primaryRoute, PrimaryRoute.surface, reason: request);
      expect(decision.policy.card, CardIntent.interactive, reason: request);
      expect(
        decision.policy.surface.kind,
        SurfaceIntentKind.game,
        reason: request,
      );
      expect(decision.policy.preferredSkills, contains('FreeformSurface'));
      expect(decision.plan.taskKind, AgentTaskKind.gameGeneration);
      expect(decision.plan.requiresBackgroundJob, isTrue);
      expect(decision.guards, isEmpty);
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: request,
          interactiveHint: true,
          surfaceIntent: hint,
        ),
        SurfaceExperienceType.game,
      );
    }
  });

  test('resolved utility does not require the mini-app product label', () {
    const request = '做一个可以添加支出、查看分类汇总并且能修改和删除记录的工具';
    final hint = SurfaceIntent.fromResolvedCreation(
      userText: request,
      kind: SurfaceIntentKind.applet,
    );
    final decision = router.resolve(
      origin: TurnOrigin.voice,
      context: TurnContext(userText: request, resolvedSurfaceIntent: hint),
    );
    expect(decision.policy.surface.kind, SurfaceIntentKind.applet);
    expect(decision.plan.taskKind, AgentTaskKind.surfaceGeneration);
    expect(decision.plan.requiresBackgroundJob, isTrue);
  });

  test(
    'semantic request binding normalizes only the existing user preamble',
    () {
      const imageRequest = '参考这张图片，生成一个球会掉下来而底部横杠要接住它的作品';
      const command = '生成一个球会掉下来而底部横杠要接住它的作品';
      final hint = SurfaceIntent.fromResolvedCreation(
        userText: imageRequest,
        kind: SurfaceIntentKind.game,
      );
      expect(hint.matchesResolvedRequest(command), isTrue);
      expect(hint.matchesResolvedRequest(imageRequest), isTrue);
      expect(hint.matchesResolvedRequest('$command，加入音效'), isFalse);
      expect(hint.matchesResolvedRequest('继续'), isFalse);
      expect(
        SurfaceCreationAuthority.experienceTypeFor(
          text: command,
          interactiveHint: true,
          surfaceIntent: hint,
        ),
        SurfaceExperienceType.game,
      );
    },
  );

  test(
    'generic hints and prior-turn hints do not acquire creation authority',
    () {
      final staleHint = SurfaceIntent.fromResolvedCreation(
        userText: _breakout,
        kind: SurfaceIntentKind.game,
      );
      for (final hint in [
        const SurfaceIntent(kind: SurfaceIntentKind.game),
        staleHint,
        SurfaceIntent.fromResolvedCreation(
          userText: '生成一个可以拖动星星的作品',
          kind: SurfaceIntentKind.scene,
        ),
      ]) {
        const request = '生成一个可以拖动星星的作品';
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: request,
            interactiveHint: true,
            surfaceIntent: hint,
          ),
          isNull,
        );
        final decision = router.resolve(
          origin: TurnOrigin.user,
          context: TurnContext(userText: request, resolvedSurfaceIntent: hint),
        );
        expect(decision.plan.requiresBackgroundJob, isFalse);
      }
    },
  );

  test(
    'explicit product remains authoritative over conflicting semantic type',
    () {
      const request = '生成一个记录游戏分数的小程序，带可删除的记录';
      final conflict = SurfaceIntent.fromResolvedCreation(
        userText: request,
        kind: SurfaceIntentKind.game,
      );
      final decision = router.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(
          userText: request,
          resolvedSurfaceIntent: conflict,
        ),
      );
      expect(decision.policy.surface.kind, SurfaceIntentKind.applet);
      expect(decision.plan.taskKind, AgentTaskKind.surfaceGeneration);
    },
  );

  test(
    'resolved type cannot override declined, quoted, informational or content requests',
    () {
      for (final request in const [
        '不要生成一个底下有条杠的作品，只讨论规则',
        '生成一个底下有条杠的作品，但不要保存',
        '生成一个底下有条杠的作品，但不要展示',
        '怎么做一个底下有条杠，球接触方块就消失的作品？',
        '生成一个底下有条杠的作品需要多久？',
        '生成一个底下有条杠的作品还是直接打开现成的更好？',
        '只讨论生成一个底下有条杠的作品',
        '他说“生成一个底下有条杠的作品”',
        '“生成一个底下有条杠的作品”',
        '继续',
        '生成器支持底下有条杠的作品',
        '开发团队正在制作底下有条杠的作品',
        '生成一个底下有条杠的作品的教程',
        '写一篇关于底下有条杠的玩法的文章',
        '写一个说明球如何弹起的故事',
        '生成一个玩法实现方案',
        '生成一张描述球与横杠的插画',
        '生成一个玩法示例代码',
        'Write a tutorial about a paddle catching a ball',
        'Build a plan for balls splitting after hitting blocks',
        'Create an article about an interactive gravity toy',
        "Create a ball-catching experience but don't save it",
        'How do I create something with a paddle and bouncing balls?',
      ]) {
        expect(
          SurfaceCreationAuthority.canResolveCreation(request),
          isFalse,
          reason: request,
        );
        final hostile = SurfaceIntent.fromResolvedCreation(
          userText: request,
          kind: SurfaceIntentKind.game,
        );
        expect(
          SurfaceCreationAuthority.experienceTypeFor(
            text: request,
            interactiveHint: true,
            surfaceIntent: hostile,
          ),
          isNull,
          reason: request,
        );
        final decision = router.resolve(
          origin: TurnOrigin.user,
          context: TurnContext(
            userText: request,
            resolvedSurfaceIntent: hostile,
          ),
        );
        expect(decision.plan.requiresBackgroundJob, isFalse, reason: request);
      }
    },
  );

  test(
    'creation authority remains unavailable to presence and live origins',
    () {
      final hint = SurfaceIntent.fromResolvedCreation(
        userText: _breakout,
        kind: SurfaceIntentKind.game,
      );
      for (final origin in [
        TurnOrigin.proactivePresence,
        TurnOrigin.notificationInteraction,
        TurnOrigin.live,
      ]) {
        final decision = router.resolve(
          origin: origin,
          context: TurnContext(
            userText: _breakout,
            resolvedSurfaceIntent: hint,
          ),
        );
        expect(decision.primaryRoute, PrimaryRoute.chat);
        expect(decision.plan.requiresBackgroundJob, isFalse);
      }
    },
  );
}
