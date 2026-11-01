import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';

void main() {
  test('explicit CJK intent selects a bounded executable grant', () {
    final router = SkillRouter(
      index: SkillIndex([
        SkillDescriptor(
          id: 'game.gomoku',
          summary: '生成一个可玩的五子棋小游戏',
          terms: const ['生成五子棋', '五子棋', '五子棋小游戏'],
          positiveExamples: const ['帮我生成一个五子棋小游戏'],
        ),
        SkillDescriptor(
          id: 'text.idiom_chain',
          summary: '直接用文字玩成语接龙',
          terms: const ['成语接龙'],
        ),
      ]),
    );

    final decision = router.route('帮我生成一个五子棋小游戏');

    expect(decision.disposition, SkillRouteDisposition.selected);
    expect(decision.topMatch?.descriptor.id, 'game.gomoku');
    expect(decision.confidence, greaterThan(0.52));
    expect(decision.matches.length, lessThanOrEqualTo(4));
    expect(decision.grant.allows('game.gomoku'), isTrue);
    expect(decision.grant.allows('text.idiom_chain'), isFalse);
  });

  test('unrelated text returns noTool without a grant', () {
    final router = SkillRouter(
      index: SkillIndex([
        SkillDescriptor(
          id: 'web_search',
          summary: '搜索实时新闻',
          terms: const ['新闻', '联网搜索'],
        ),
      ]),
    );

    final decision = router.route('今天心情不错');

    expect(decision.disposition, SkillRouteDisposition.noTool);
    expect(decision.grant.isEmpty, isTrue);
  });

  test('negative terms and examples veto otherwise matching skills', () {
    final router = SkillRouter(
      index: SkillIndex([
        SkillDescriptor(
          id: 'game.generate',
          summary: '生成互动游戏',
          terms: const ['生成游戏', '游戏'],
          negativeTerms: const ['不要生成'],
          negativeExamples: const ['只想聊聊游戏'],
        ),
      ]),
    );

    expect(
      router.route('不要生成游戏，告诉我规则').disposition,
      SkillRouteDisposition.noTool,
    );
    expect(router.route('我只想聊聊游戏').disposition, SkillRouteDisposition.noTool);
  });

  test('page scope is a strong prior while profession stays weak', () {
    final descriptors = [
      SkillDescriptor(
        id: 'comment.news',
        summary: '评论当前新闻',
        terms: const ['评论'],
        pageScopes: const ['agent_media.news'],
        professions: const ['记者'],
      ),
      SkillDescriptor(
        id: 'comment.video',
        summary: '评论当前短视频',
        terms: const ['评论'],
        pageScopes: const ['agent_media.recommended'],
        professions: const ['视频创作者'],
      ),
    ];
    final router = SkillRouter(index: SkillIndex(descriptors));

    final neutral = router.route('帮我评论一下');
    final pageScoped = router.route('帮我评论一下', pageScope: 'agent_media.news');
    final professionOnly = router.route('帮我评论一下', professions: const ['记者']);

    expect(neutral.disposition, SkillRouteDisposition.clarify);
    expect(pageScoped.disposition, SkillRouteDisposition.selected);
    expect(pageScoped.topMatch?.descriptor.id, 'comment.news');
    expect(pageScoped.topMatch?.pagePriorApplied, isTrue);
    expect(professionOnly.disposition, SkillRouteDisposition.clarify);
    expect(professionOnly.topMatch?.descriptor.id, 'comment.news');
    expect(professionOnly.topMatch?.professionPriorApplied, isTrue);
  });

  test('requested results cannot exceed configured Top-K', () {
    final router = SkillRouter(
      index: SkillIndex([
        for (var i = 0; i < 10; i++)
          SkillDescriptor(
            id: 'shared.${i.toString().padLeft(2, '0')}',
            summary: '共享工具 $i',
            terms: const ['共享工具'],
          ),
      ]),
      config: const SkillRouterConfig(defaultTopK: 2, maxTopK: 3),
    );

    final decision = router.route('使用共享工具', maxResults: 999);

    expect(decision.disposition, SkillRouteDisposition.clarify);
    expect(decision.matches, hasLength(3));
    expect(decision.matches.map((match) => match.descriptor.id), [
      'shared.00',
      'shared.01',
      'shared.02',
    ]);
  });

  test('10k descriptor index produces stable bounded results', () {
    final descriptors = [
      for (var i = 0; i < 10000; i++)
        SkillDescriptor(
          id: 'scale.${i.toString().padLeft(5, '0')}',
          summary: 'Scale skill $i',
          terms: ['intent_${i.toString().padLeft(5, '0')}'],
        ),
    ];
    final forwardIndex = SkillIndex(descriptors);
    final reverseIndex = SkillIndex(descriptors.reversed);
    final forward = SkillRouter(index: forwardIndex);
    final reverse = SkillRouter(index: reverseIndex);

    List<String> routeIds(SkillRouter router) => router
        .route('please run intent_08342 now', maxResults: 6)
        .matches
        .map((match) => match.descriptor.id)
        .toList(growable: false);

    final expected = routeIds(forward);
    expect(expected.first, 'scale.08342');
    expect(expected.length, lessThanOrEqualTo(6));
    expect(routeIds(forward), expected);
    expect(routeIds(reverse), expected);
    expect(
      forwardIndex.lookup('please run intent_08342 now').candidates.length,
      lessThanOrEqualTo(256),
    );
  });
}
