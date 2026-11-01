import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/page_skill_routing_policy.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';

void main() {
  group('PageSkillRoutingPolicy defaults', () {
    final policy = PageSkillRoutingPolicy.defaults;

    test('maps canonical routes to bounded built-in Host candidates', () {
      expect(policy.forRoute('/widgets-hub').preferredHostSkillIds, <String>[
        'AppletDiscovery',
      ]);
      expect(policy.forRoute('/game-feed').preferredHostSkillIds, <String>[
        'AppletDiscovery',
      ]);
      expect(policy.forRoute('/creator-studio?source=agent').isEmpty, isTrue);
      expect(policy.forRoute('/selfie').isEmpty, isTrue);
      expect(policy.forRoute('/agent-media?channel=news').isEmpty, isTrue);
    });

    test('normalizes query and fragment but rejects unknown page scopes', () {
      expect(
        policy.forRoute('/game-feed?source=agent#item-42').pageScope,
        'game_feed',
      );
      expect(policy.forRoute('/agent-media?channel=unknown').isEmpty, isTrue);
      expect(policy.forRoute('/community').isEmpty, isTrue);
      expect(policy.forScope('agent_media.news?unsafe=true').isEmpty, isTrue);
    });

    test('policy data is immutable and ids are hard capped', () {
      final prior = policy.forScope('widgets_hub');
      expect(
        () => prior.preferredHostSkillIds.add('WebSearch'),
        throwsUnsupportedError,
      );
      expect(
        () => policy.supportedPageScopes.add('community'),
        throwsUnsupportedError,
      );
      expect(
        () => policy.snapshot['community'] = prior,
        throwsUnsupportedError,
      );
      expect(
        () => PageSkillRoutingPrior(
          pageScope: 'selfie',
          preferredHostSkillIds: const <String>[
            'Creator',
            'WebSearch',
            'AppletDiscovery',
            'FreeformSurface',
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  test('page alone produces no preference and no executable grant', () {
    final creator = SkillDescriptor(
      id: 'AppletDiscovery',
      summary: 'Find available games and applets',
      terms: const <String>['查找小游戏'],
      pageScopes: const <String>['widgets_hub'],
    );
    final index = SkillIndex(<SkillDescriptor>[creator]);
    final router = SkillRouter(index: index);
    final prior = PageSkillRoutingPolicy.defaults.forRoute('/widgets-hub');
    final decision = router.route('你好呀', pageScope: prior.pageScope);
    final eligible = prior.eligiblePreferredHostSkillIds(decision.matches);
    final selection = TurnSkillSelector(
      index: index,
      router: router,
    ).select('你好呀', pageScope: prior.pageScope, preferredSkillIds: eligible);

    expect(decision.disposition, SkillRouteDisposition.noTool);
    expect(eligible, isEmpty);
    expect(selection.grant.isEmpty, isTrue);
  });

  test('explicit lexical intent receives only the bounded page prior', () {
    final creator = SkillDescriptor(
      id: 'AppletDiscovery',
      summary: 'Find available games and applets',
      terms: const <String>['查找小游戏'],
      pageScopes: const <String>['widgets_hub'],
    );
    final webSearch = SkillDescriptor(
      id: 'WebSearch',
      summary: 'Search the web',
      terms: const <String>['查新闻'],
    );
    final router = SkillRouter(
      index: SkillIndex(<SkillDescriptor>[creator, webSearch]),
    );
    final prior = PageSkillRoutingPolicy.defaults.forRoute('/widgets-hub');
    final decision = router.route('查找小游戏', pageScope: prior.pageScope);

    expect(decision.disposition, SkillRouteDisposition.selected);
    expect(prior.eligiblePreferredHostSkillIds(decision.matches), <String>[
      'AppletDiscovery',
    ]);
  });

  test('confidence threshold and activation budget cap eligible matches', () {
    final prior = PageSkillRoutingPrior(
      pageScope: 'selfie',
      preferredHostSkillIds: const <String>[
        'Creator',
        'WebSearch',
        'AppletDiscovery',
      ],
      activationBudget: 2,
      minimumIntentConfidence: 0.6,
    );
    SkillRouteMatch match(String id, double confidence) => SkillRouteMatch(
      descriptor: SkillDescriptor(id: id, summary: id),
      score: 10,
      confidence: confidence,
      matchedTerms: const <String>['explicit'],
      matchedExamples: const <String>[],
      pagePriorApplied: false,
      professionPriorApplied: false,
      semanticScore: 0,
    );

    expect(
      prior.eligiblePreferredHostSkillIds(<SkillRouteMatch>[
        match('AppletDiscovery', 0.9),
        match('Creator', 0.8),
        match('WebSearch', 0.59),
      ]),
      <String>['Creator', 'AppletDiscovery'],
    );
  });
}
