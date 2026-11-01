import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_routing/page_skill_routing_policy.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';

void main() {
  test('page prior resolves an evidence-backed ambiguous page candidate', () {
    final creator = SkillDescriptor(
      id: 'Creator',
      summary: 'Create a short video draft',
      terms: const <String>['拍短视频'],
    );
    final other = SkillDescriptor(
      id: 'Other',
      summary: 'Another short video helper',
      terms: const <String>['拍短视频'],
    );
    final index = SkillIndex(<SkillDescriptor>[creator, other]);
    final selector = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    );

    final selection = selector.select(
      '帮我拍短视频',
      pageScope: 'selfie',
      pagePrior: PageSkillRoutingPolicy.defaults.forScope('selfie'),
    );

    expect(selection.decision.disposition, SkillRouteDisposition.clarify);
    expect(selection.grant.allowedSkillIds, <String>{'Creator'});
  });

  test('page alone and a mismatched page prior never create a grant', () {
    final creator = SkillDescriptor(
      id: 'Creator',
      summary: 'Create a short video draft',
      terms: const <String>['拍短视频'],
    );
    final other = SkillDescriptor(
      id: 'Other',
      summary: 'Another short video helper',
      terms: const <String>['拍短视频'],
    );
    final index = SkillIndex(<SkillDescriptor>[creator, other]);
    final selector = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    );
    final selfiePrior = PageSkillRoutingPolicy.defaults.forScope('selfie');

    expect(
      selector
          .select('你好', pageScope: 'selfie', pagePrior: selfiePrior)
          .grant
          .isEmpty,
      isTrue,
    );
    final mismatch = selector.select(
      '帮我拍短视频',
      pageScope: 'widgets_hub',
      pagePrior: selfiePrior,
    );
    expect(mismatch.decision.disposition, SkillRouteDisposition.clarify);
    expect(mismatch.grant.isEmpty, isTrue);
  });

  test('runtime supplies route prior and weak persona profession terms', () {
    final source = File(
      'lib/src/features/agent/application/agent_runtime.dart',
    ).readAsStringSync();

    expect(source, contains('PageSkillRoutingPolicy.defaults.forRoute('));
    expect(source, contains('pagePrior: pagePrior'));
    expect(source, contains('professions: profile.persona.routingPriorTerms'));
  });
}
