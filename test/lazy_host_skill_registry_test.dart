import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

void main() {
  test('catalog routing and descriptors instantiate zero host skills', () {
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'search',
          skillName: 'Search',
          terms: const <String>['search'],
          factory: (_) {
            created++;
            return _FakeSkill('Search');
          },
        ),
      ],
      enabledSkillIds: const <String>{'search'},
    );

    expect(registry.enabledManifests.single.skillName, 'Search');
    expect(registry.descriptors().single.id, 'Search');
    expect(created, 0);
    expect(registry.activeCount, 0);
  });

  test('real catalog keeps core enabled without constructing host skills', () {
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: SkillCatalog.all,
      enabledSkillIds: const <String>{},
    );

    expect(registry.isEnabled('WorldControl'), isFalse);
    expect(registry.descriptorFor('WorldControl'), isNull);
    expect(registry.isEnabled('AppNavigate'), isTrue);
    expect(registry.isEnabled('RealWeather'), isFalse);
    expect(
      registry.enabledManifests.map((manifest) => manifest.skillName),
      containsAll(<String>['AppControl', 'AppNavigate']),
    );
    expect(
      registry.enabledManifests.map((manifest) => manifest.skillName),
      isNot(contains('WorldControl')),
    );
    expect(registry.activeCount, 0);
  });

  test('factory-only and prompt-only entries cannot become host grants', () {
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        SkillSpec(
          id: 'prompt_only',
          name: 'prompt_only',
          description: 'prompt_only',
          icon: Icons.description_rounded,
          color: Colors.blue,
          category: SkillCategory.knowledge,
          factory: (_) {
            created++;
            return _FakeSkill('PromptOnly');
          },
        ),
      ],
      enabledSkillIds: const <String>{'prompt_only'},
    );

    expect(registry.enabledManifests, isEmpty);
    expect(registry.isEnabled('PromptOnly'), isFalse);
    expect(() => registry.activate('PromptOnly'), throwsStateError);
    expect(created, 0);
  });

  test('only registry-owned descriptor identity can mint a host grant', () {
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'alpha',
          skillName: 'AlphaHost',
          factory: (_) {
            created++;
            return _FakeSkill('AlphaHost');
          },
        ),
      ],
    );
    final owned = registry.descriptorFor('AlphaHost')!;
    final copied = SkillDescriptor(
      id: owned.id,
      summary: owned.summary,
      terms: owned.terms,
      promptCost: owned.promptCost,
    );

    final copiedGrant = registry.issueGrant(_promptGrant(copied));

    expect(copiedGrant, same(ExecutableHostGrant.none));
    expect(created, 0);

    final executable = registry.issueGrant(_promptGrant(owned));
    final tool = HostSkillRoutingManifest.nativeToolName('AlphaHost', 'run');

    expect(created, 1);
    expect(executable.isCurrent, isTrue);
    expect(executable.allowedSkillNames, const <String>{'AlphaHost'});
    expect(executable.activatedSkills.single.skillName, 'AlphaHost');
    expect(
      executable.authorize(agentId: 'agent-test', tool: tool)?.method,
      'run',
    );
    expect(executable.authorize(agentId: 'other-agent', tool: tool), isNull);
  });

  test(
    'changed reload permanently invalidates old executable grants',
    () async {
      final registry = LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[_spec(id: 'alpha', skillName: 'AlphaHost')],
      );
      final descriptor = registry.descriptorFor('AlphaHost')!;
      final oldGrant = registry.issueGrant(_promptGrant(descriptor));
      final invalidated = expectLater(oldGrant.whenInvalidated, completes);

      registry.reload(const <String>{});
      await invalidated;

      expect(oldGrant.isCurrent, isFalse);
      expect(
        oldGrant.authorize(
          agentId: 'agent-test',
          tool: HostSkillRoutingManifest.nativeToolName('AlphaHost', 'run'),
        ),
        isNull,
      );
      expect(
        registry.issueGrant(_promptGrant(descriptor)),
        same(ExecutableHostGrant.none),
        reason: 'a descriptor from the previous generation is not provenance',
      );

      registry.reload(const <String>{'alpha'});
      final freshDescriptor = registry.descriptorFor('AlphaHost')!;
      expect(
        registry.issueGrant(_promptGrant(freshDescriptor)).isCurrent,
        isTrue,
      );
    },
  );

  test('identical effective reload preserves descriptors and grants', () async {
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'alpha',
          skillName: 'AlphaHost',
          factory: (_) {
            created++;
            return _FakeSkill('AlphaHost');
          },
        ),
      ],
      enabledSkillIds: const <String>{'alpha'},
    );
    final descriptor = registry.descriptorFor('AlphaHost')!;
    final grant = registry.issueGrant(_promptGrant(descriptor));
    var invalidated = false;
    grant.whenInvalidated.then((_) => invalidated = true);

    registry.reload(const <String>{'alpha', 'unknown'});
    await Future<void>.delayed(Duration.zero);

    expect(registry.descriptorFor('AlphaHost'), same(descriptor));
    expect(grant.isCurrent, isTrue);
    expect(invalidated, isFalse);
    expect(
      registry.issueGrant(_promptGrant(descriptor)).activatedSkills.single,
      same(grant.activatedSkills.single),
    );
    expect(created, 1);
    registry.invalidate();
    await Future<void>.delayed(Duration.zero);
    expect(invalidated, isTrue);
  });

  test(
    'availability off-enforce-off refresh revokes the active grant',
    () async {
      var available = false;
      final registry = LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(
            id: 'activity',
            skillName: 'CompanionActivity',
            availability: () => available,
          ),
        ],
        enabledSkillIds: const <String>{'activity'},
      );

      expect(registry.descriptors(), isEmpty);
      available = true;
      expect(registry.synchronizeAvailability(), isTrue);
      final descriptor = registry.descriptorFor('CompanionActivity')!;
      final grant = registry.issueGrant(_promptGrant(descriptor));
      expect(grant.isCurrent, isTrue);

      available = false;
      final invalidated = expectLater(grant.whenInvalidated, completes);
      expect(registry.synchronizeAvailability(), isTrue);
      await invalidated;
      expect(grant.isCurrent, isFalse);
      expect(registry.descriptors(), isEmpty);
      expect(registry.issueGrant(_promptGrant(descriptor)).isEmpty, isTrue);
    },
  );

  test('ten thousand specs initialize none, activate one, and reuse it', () {
    var created = 0;
    final specs = List<SkillSpec>.generate(10000, (index) {
      final skillName = 'Host$index';
      return _spec(
        id: 'host_$index',
        skillName: skillName,
        terms: <String>['term_$index'],
        factory: (_) {
          created++;
          return _FakeSkill(skillName);
        },
      );
    }, growable: false);
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: specs,
      enabledSkillIds: const <String>{'host_9876'},
    );

    expect(created, 0);
    expect(registry.enabledManifests.single.skillName, 'Host9876');

    final first = registry.activateSelected(const <String>['Host9876']).single;
    final second = registry.activate('Host9876');

    expect(created, 1);
    expect(identical(first, second), isTrue);
    expect(registry.activeCount, 1);
  });

  test('duplicate host names and native tool names fail closed', () {
    expect(
      () => LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(id: 'one', skillName: 'Duplicate'),
          _spec(id: 'two', skillName: 'Duplicate'),
        ],
      ),
      throwsStateError,
    );

    expect(
      () => LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(
            id: 'one',
            skillName: 'Alpha.Beta',
            methods: const <String>['run'],
            nativeMethods: const <String>['run'],
          ),
          _spec(
            id: 'two',
            skillName: 'Alpha@Beta',
            methods: const <String>['run'],
            nativeMethods: const <String>['run'],
          ),
        ],
      ),
      throwsStateError,
    );
  });

  test('factory skillName mismatch is rejected before caching', () {
    var created = 0;
    final registry = LazyHostSkillRegistry(
      agentId: 'agent-test',
      specs: <SkillSpec>[
        _spec(
          id: 'declared',
          skillName: 'Declared',
          factory: (_) {
            created++;
            return _FakeSkill('Different');
          },
        ),
      ],
    );

    expect(() => registry.activate('Declared'), throwsStateError);
    expect(created, 1);
    expect(registry.activeCount, 0);
  });

  test(
    'reload keeps core, evicts disabled optionals, and recreates on re-enable',
    () {
      var coreCreated = 0;
      var optionalCreated = 0;
      final registry = LazyHostSkillRegistry(
        agentId: 'agent-test',
        specs: <SkillSpec>[
          _spec(
            id: 'core',
            skillName: 'CoreHost',
            isCore: true,
            factory: (_) {
              coreCreated++;
              return _FakeSkill('CoreHost');
            },
          ),
          _spec(
            id: 'optional',
            skillName: 'OptionalHost',
            factory: (_) {
              optionalCreated++;
              return _FakeSkill('OptionalHost');
            },
          ),
        ],
        enabledSkillIds: const <String>{'optional'},
      );

      final core = registry.activate('CoreHost');
      registry.activate('OptionalHost');
      expect(coreCreated, 1);
      expect(optionalCreated, 1);

      registry.reload(const <String>{});

      expect(registry.isEnabled('CoreHost'), isTrue);
      expect(registry.isEnabled('OptionalHost'), isFalse);
      expect(identical(registry.activate('CoreHost'), core), isTrue);
      expect(() => registry.activate('OptionalHost'), throwsStateError);
      expect(registry.activeCount, 1);

      registry.reload(const <String>{'optional'});
      registry.activate('OptionalHost');
      expect(optionalCreated, 2);
    },
  );
}

TurnSkillGrant _promptGrant(SkillDescriptor descriptor) =>
    TurnSkillGrant.bounded(
      rankedDescriptors: <SkillDescriptor>[descriptor],
      maxSkills: 1,
      promptBudget: 4096,
    );

SkillSpec _spec({
  required String id,
  required String skillName,
  bool isCore = false,
  List<String> methods = const <String>['run'],
  List<String> nativeMethods = const <String>[],
  List<String> terms = const <String>[],
  AgentSkill Function(String agentId)? factory,
  bool Function()? availability,
}) {
  return SkillSpec(
    id: id,
    name: id,
    description: id,
    icon: Icons.extension_rounded,
    color: Colors.blue,
    category: SkillCategory.core,
    isCore: isCore,
    factory: factory ?? (_) => _FakeSkill(skillName, methods: methods),
    availability: availability,
    hostRouting: HostSkillRoutingManifest(
      skillName: skillName,
      summary: '$skillName routing summary.',
      methods: methods,
      nativeMethods: nativeMethods,
      terms: terms,
    ),
  );
}

class _FakeSkill extends AgentSkill {
  _FakeSkill(this._skillName, {List<String> methods = const <String>['run']})
    : _methodNames = methods;

  final String _skillName;
  final List<String> _methodNames;

  @override
  String get skillName => _skillName;

  @override
  String get description => 'fake';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        for (final method in _methodNames) method: (_) => '{}',
      };
}
