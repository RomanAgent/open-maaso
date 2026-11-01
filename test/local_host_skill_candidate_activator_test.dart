import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/local_host_skill_candidate_activator.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  test('10k local specs construct zero hosts and activate only candidates', () {
    var factoryCalls = 0;
    final specs = List<SkillSpec>.generate(10000, (index) {
      final name = 'Local$index';
      return _spec(
        id: 'local_$index',
        skillName: name,
        factory: (_) {
          factoryCalls++;
          return _FakeLocalSkill(name);
        },
      );
    }, growable: false);

    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: specs,
    );

    expect(factoryCalls, 0);
    expect(activator.manifests, hasLength(10000));
    expect(activator.activateCandidates(const []).skills, isEmpty);
    expect(factoryCalls, 0);

    final candidates = <LocalSkillManifest>[
      activator.manifests[3],
      activator.manifests[9876],
      activator.manifests[3],
    ];
    final first = activator.activateCandidates(candidates);
    final repeated = activator.activateCandidates(candidates);

    expect(first.skills.map((skill) => skill.skillName), <String>[
      'Local3',
      'Local9876',
    ]);
    expect(factoryCalls, 2);
    expect(identical(first.skills.first, repeated.skills.first), isTrue);
    expect(activator.activeCount, 2);
  });

  test('navigation is lazy, deduplicated, and cached separately', () {
    var navigationCalls = 0;
    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: const <SkillSpec>[],
    );
    final navigation = _manifest(id: 'nav.settings', skillName: 'AppNavigate');

    expect(
      activator.activateCandidates(const <LocalSkillManifest>[]).skills,
      isEmpty,
    );
    final first = activator.activateCandidates(
      <LocalSkillManifest>[navigation, navigation],
      navigationFactory: () {
        navigationCalls++;
        return _FakeLocalSkill('AppNavigate');
      },
    );
    final repeated = activator.activateCandidates(
      <LocalSkillManifest>[navigation],
      navigationFactory: () {
        navigationCalls++;
        return _FakeLocalSkill('AppNavigate');
      },
    );

    expect(first.skills, hasLength(1));
    expect(navigationCalls, 1);
    expect(identical(first.skills.single, repeated.skills.single), isTrue);
  });

  test('factory metadata mismatch fails closed and is not cached', () {
    var factoryCalls = 0;
    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: <SkillSpec>[
        _spec(
          id: 'broken',
          skillName: 'Declared',
          factory: (_) {
            factoryCalls++;
            return _FakeLocalSkill('Different');
          },
        ),
      ],
    );

    expect(
      () => activator.activateCandidates(activator.manifests),
      throwsStateError,
    );
    expect(factoryCalls, 1);
    expect(activator.activeCount, 0);
  });

  test(
    'availability snapshot removes cached host and admits it when enabled',
    () {
      var available = false;
      var calls = 0;
      final activator = LocalHostSkillCandidateActivator(
        agentId: 'self',
        specs: <SkillSpec>[
          _spec(
            id: 'activity',
            skillName: 'CompanionActivity',
            availability: () => available,
            factory: (_) {
              calls++;
              return _FakeLocalSkill('CompanionActivity');
            },
          ),
        ],
      );
      final candidate = activator.manifests.single;
      expect(activator.availableManifests, isEmpty);
      expect(
        activator.activateCandidates(<LocalSkillManifest>[candidate]).skills,
        isEmpty,
      );

      available = true;
      expect(activator.availableManifests, <LocalSkillManifest>[candidate]);
      expect(
        activator.activateCandidates(<LocalSkillManifest>[candidate]).skills,
        hasLength(1),
      );
      expect(calls, 1);

      available = false;
      expect(activator.synchronizeAvailability(), isTrue);
      expect(activator.activeCount, 0);
      expect(
        activator.activateCandidates(<LocalSkillManifest>[candidate]).skills,
        isEmpty,
      );
    },
  );

  test('snapshot revocation removes cached candidate before activation', () {
    var admitted = true;
    final snapshots = AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{},
        skillIds: const <String>{'activity'},
        skillAdmission: (_) => admitted,
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: 0,
      ),
    );
    addTearDown(snapshots.closeLifecycle);
    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: <SkillSpec>[
        _spec(
          id: 'activity',
          skillName: 'CompanionActivity',
          factory: (_) => _FakeLocalSkill('CompanionActivity'),
        ),
      ],
      capabilitySnapshotService: snapshots,
    );
    final candidate = activator.manifests.single;

    expect(
      activator.activateCandidates(<LocalSkillManifest>[candidate]).skills,
      hasLength(1),
    );
    expect(activator.activeCount, 1);
    expect(activator.capabilityKeysFor(candidate), <AppCapabilityKey>{
      AppCapabilityKey.skill('activity'),
    });

    admitted = false;
    snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));

    expect(activator.synchronizeAvailability(), isTrue);
    expect(activator.activeCount, 0);
    expect(activator.isManifestAvailable(candidate), isFalse);
    expect(
      activator.activateCandidates(<LocalSkillManifest>[candidate]).skills,
      isEmpty,
    );
  });

  test('unknown keys and a closed snapshot service fail closed', () {
    final snapshots = AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{},
        skillIds: const <String>{},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: 0,
      ),
    );
    final activator = LocalHostSkillCandidateActivator(
      agentId: 'self',
      specs: <SkillSpec>[
        _spec(
          id: 'activity',
          skillName: 'CompanionActivity',
          factory: (_) => _FakeLocalSkill('CompanionActivity'),
        ),
      ],
      capabilitySnapshotService: snapshots,
    );
    final candidate = activator.manifests.single;

    expect(activator.availableManifests, isEmpty);
    expect(activator.isManifestAvailable(candidate), isFalse);

    snapshots.closeLifecycle();
    expect(activator.synchronizeAvailability(), isTrue);
    expect(activator.availableManifests, isEmpty);
    expect(activator.isManifestAvailable(candidate), isFalse);
  });
}

SkillSpec _spec({
  required String id,
  required String skillName,
  required AgentSkill Function(String agentId) factory,
  bool Function()? availability,
}) => SkillSpec(
  id: id,
  name: id,
  description: id,
  icon: Icons.extension_rounded,
  color: Colors.blue,
  category: SkillCategory.core,
  factory: factory,
  availability: availability,
  localManifest: _manifest(id: id, skillName: skillName),
);

LocalSkillManifest _manifest({required String id, required String skillName}) =>
    LocalSkillManifest(
      id: id,
      skillName: skillName,
      method: 'run',
      summary: id,
      tags: <String>[id],
      argsSchema: const <String, dynamic>{},
    );

class _FakeLocalSkill extends AgentSkill {
  _FakeLocalSkill(this._name);

  final String _name;

  @override
  String get skillName => _name;

  @override
  String get description => 'fake';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{'run': (_) => '{}'};
}
