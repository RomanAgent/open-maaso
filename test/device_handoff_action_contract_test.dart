import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_skill_action_metadata.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

import 'support/device_handoff_skill_fixture.dart';

const _retiredRequestSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'targetPresenceSessionId': {'type': 'string'},
  },
  'required': ['targetPresenceSessionId'],
  'additionalProperties': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HandoffSkillFixture fixture;
  setUp(() async => fixture = await HandoffSkillFixture.create());
  tearDown(() => fixture.dispose());

  test('retired handoff methods have no production metadata', () {
    for (final method in ['request', 'cancel']) {
      expect(
        productionSkillActionContractMetadata(
          fixture.skill,
          method,
          _retiredRequestSchema,
        ),
        isNull,
      );
    }
  });

  for (final mode in FeatureRolloutMode.values) {
    for (final channel in ActionContractChannel.values) {
      test('retired requests are unavailable in $mode/$channel', () async {
        final h = await _Harness.create(fixture.skill, mode: mode);
        for (final method in ['request', 'cancel']) {
          await expectLater(
            h.manager.invokeTool(
              'skill_devicehandoff_$method',
              method == 'request'
                  ? {'targetPresenceSessionId': handoffTestTarget}
                  : {},
              channel: channel,
              callId: 'retired-$method',
            ),
            throwsStateError,
          );
        }
        expect(fixture.gateway.commands, isEmpty);
        expect(fixture.gateway.requestBodies, isEmpty);
        expect(fixture.bridge.calls, isEmpty);
        final tools = h.manager.toNativeTools();
        expect(tools.map((tool) => (tool['function'] as Map)['name']), [
          'skill_devicehandoff_listdevices',
        ]);
      });
    }
  }

  test(
    'a same-named handler cannot recover retired domain authorization',
    () async {
      for (final risk in [ActionRisk.externalWrite, ActionRisk.readOnly]) {
        final fake = _Impostor();
        final h = await _Harness.create(
          fake,
          metadata: (_, _, _) => SkillActionContractMetadata(
            risk: risk,
            consequencePolicy: ActionConsequencePolicy.reversible,
            enforcementEligibility:
                ActionEnforcementEligibility.domainAuthorized,
          ),
        );
        final result = jsonDecode(
          await h.manager.invokeTool('skill_devicehandoff_request', {
            'targetPresenceSessionId': handoffTestTarget,
          }, callId: 'spoof-$risk'),
        );
        expect(result['status'], isNot('ok'));
        expect(fake.calls, 0);
        expect(
          h.contract.recentDiagnostics.map((d) => d.code),
          contains('domain_authority_required'),
        );
      }
    },
  );

  test('online device discovery retains read-only enforcement', () async {
    final h = await _Harness.create(fixture.skill);
    final result = jsonDecode(
      await h.manager.invokeTool(
        'skill_devicehandoff_listdevices',
        {},
        callId: 'list',
      ),
    );
    expect(result['status'], 'ok', reason: result.toString());
    expect(fixture.gateway.commands, isEmpty);
    expect(fixture.bridge.calls, isEmpty);
  });
}

class _Harness {
  _Harness(this.manager, this.contract);
  final SkillManager manager;
  final ActionContractV2Service contract;
  static Future<_Harness> create(
    AgentSkill skill, {
    FeatureRolloutMode mode = FeatureRolloutMode.enforce,
    SkillActionContractMetadataResolver? metadata,
  }) async {
    final flags = await MaasoFeatureFlagService(
      store: _FlagStore(),
      clock: () => handoffTestNow,
      compileMaximums: const {
        MaasoFeatureFlag.actionContractV2: FeatureRolloutMode.enforce,
      },
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.actionContractV2,
      mode: mode,
      revision: 1,
      expiresAt: handoffTestNow.add(const Duration(hours: 1)),
    );
    final catalog = ProductionActionDefinitionCatalog();
    final contract = ActionContractV2Service(
      featureFlags: flags,
      catalog: catalog,
      audit: _Audit(),
      accountScope: 'handoff-owner',
      accountGeneration: 1,
      mountIsCurrent: () => true,
    );
    addTearDown(contract.onClose);
    addTearDown(flags.onClose);
    final manager = SkillManager(
      actionContract: contract,
      productionCatalog: catalog,
      actionContractAgentId: 'self',
      contractMetadataResolver:
          metadata ?? productionSkillActionContractMetadata,
    )..registerSkill(skill);
    return _Harness(manager, contract);
  }
}

class _Impostor extends AgentSkill {
  int calls = 0;
  @override
  String get skillName => 'DeviceHandoff';
  @override
  String get description => 'Spoof probe';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'request': (_) {
      calls++;
      return '{"ok":true}';
    },
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'request': _retiredRequestSchema,
  };
}

class _Audit implements ActionContractV2AuditSink {
  @override
  String record(ActionContractAuditRecord record) =>
      'handoff-${record.invocation.callId}';
}

class _FlagStore implements MaasoFeatureFlagAssignmentStore {
  final rows = <Map<String, Object?>>[];
  @override
  Future<List<Map<String, Object?>>> readAll() async => rows;
  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    rows.add(assignment.toJson());
  }
}
