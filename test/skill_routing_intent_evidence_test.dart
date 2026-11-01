import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_index.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_router.dart';
import 'package:maaso/src/features/agent/application/skill_routing/turn_skill_selector.dart';

void main() {
  test(
    'online device queries route to discovery while retired transfers do not',
    () {
      final descriptor = AgentSkillDescriptorFactory.fromManifest(
        SkillCatalog.byId('device_handoff')!.hostRouting!,
      );
      final router = SkillRouter(index: SkillIndex([descriptor]));
      expect(
        router
            .route('My laptop is slow; why?', pageScope: 'home')
            .grant
            .isEmpty,
        isTrue,
      );
      expect(
        router.route('Come over to my laptop', pageScope: 'home').grant.isEmpty,
        isTrue,
      );
      expect(
        router
            .route('List my online devices', pageScope: 'home')
            .grant
            .allowedSkillIds,
        {'DeviceHandoff'},
      );
    },
  );
  test(
    'home prior cannot convert conversational stop words into a creation grant',
    () {
      final index = SkillIndex([
        SkillDescriptor(
          id: 'FreeformSurface',
          summary:
              'Create an explicitly requested interface, or edit and revert only the currently visible generated interface.',
          terms: ['build applet', 'generate game'],
          pageScopes: ['home'],
        ),
      ]);
      final result = SkillRouter(
        index: index,
      ).route('I am tired and only want to chat', pageScope: 'home');
      expect(result.disposition, SkillRouteDisposition.noTool);
      expect(result.grant.isEmpty, isTrue);
    },
  );

  test('a summary-only word cannot acquire a page execution hint', () {
    final index = SkillIndex([
      SkillDescriptor(
        id: 'Finance',
        summary: 'Review financial reports and notes',
        terms: ['financial analysis'],
        pageScopes: ['wallet'],
      ),
    ]);
    final result = SkillRouter(
      index: index,
    ).route('notes', pageScope: 'wallet');
    expect(result.grant.isEmpty, isTrue);
  });

  test(
    'two capability tokens still support natural wording with an intervening adjective',
    () {
      final index = SkillIndex([
        SkillDescriptor(
          id: 'GameBuilder',
          summary: 'Create playable games',
          terms: ['build game'],
          pageScopes: ['home'],
        ),
      ]);
      final result = SkillRouter(
        index: index,
      ).route('build a tiny game', pageScope: 'home');
      expect(result.grant.allowedSkillIds, {'GameBuilder'});
    },
  );

  test('a transport method name cannot claim an unrelated ordinary phrase', () {
    final descriptor = AgentSkillDescriptorFactory.fromManifest(
      HostSkillRoutingManifest(
        skillName: 'Http',
        summary: 'Explicit HTTPS API requests',
        methods: ['get', 'post'],
        terms: ['api request'],
      ),
    );
    final index = SkillIndex([descriptor]);
    expect(
      SkillRouter(index: index).route('get some sleep').grant.isEmpty,
      isTrue,
    );
    expect(
      SkillRouter(
        index: index,
      ).route('Http GET api request').grant.allowedSkillIds,
      {'Http'},
    );
  });

  test('policy preferences do not bypass explicit descriptor prohibitions', () {
    final index = SkillIndex([
      SkillDescriptor(
        id: 'Builder',
        summary: 'Build a game',
        terms: ['generate game'],
        negativeTerms: ['do not generate'],
      ),
    ]);
    final selection = TurnSkillSelector(
      index: index,
      router: SkillRouter(index: index),
    ).select('do not generate game', preferredSkillIds: ['Builder']);
    expect(selection.decision.grant.isEmpty, isTrue);
    expect(selection.grant.isEmpty, isTrue);
  });
}
