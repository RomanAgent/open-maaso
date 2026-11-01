import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_skill_action_metadata.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/avatar_camera_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

const _tool = 'skill_avatarcamera_setframing';

void main() {
  test('camera is an exact reversible local operation, never read-only', () {
    final skill = AvatarCameraSkill();
    final schema = skill.nativeToolSchemas['setFraming']!;
    final metadata = productionSkillActionContractMetadata(
      skill,
      'setFraming',
      schema,
    )!;
    expect(metadata.risk, ActionRisk.localMutation);
    expect(metadata.consequencePolicy, ActionConsequencePolicy.reversible);
    expect(
      metadata.enforcementEligibility,
      ActionEnforcementEligibility.reversibleLocal,
    );
    expect(
      productionSkillActionContractMetadata(skill, 'setRawCamera', schema),
      isNull,
    );
  });

  for (final rollout in [
    FeatureRolloutMode.off,
    FeatureRolloutMode.shadow,
    FeatureRolloutMode.enforce,
  ]) {
    for (final channel in [
      ActionContractChannel.structured,
      ActionContractChannel.nativeTool,
      ActionContractChannel.delayedTool,
    ]) {
      test(
        'real camera skill executes once per request in $rollout/$channel',
        () async {
          final harness = await _Harness.create(rollout: rollout);
          for (final mode in ['face', 'bust', 'full', 'auto']) {
            final before = harness.director.calls;
            final result =
                jsonDecode(
                      await harness.manager.invokeTool(
                        _tool,
                        {'mode': mode},
                        channel: channel,
                        callId: '$rollout-$channel-$mode',
                      ),
                    )
                    as Map;
            expect(harness.director.calls, before + 1);
            if (rollout == FeatureRolloutMode.enforce) {
              expect(result['status'], 'ok');
              expect(result['data'], [harness.director.lastResult]);
            } else {
              expect(result, harness.director.lastResult);
            }
          }
        },
      );
    }
  }

  test(
    'local camera manifest also executes under reversible enforcement',
    () async {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
      );
      final result = await LocalSkillInvoker(skillManager: harness.manager)
          .invoke(SkillCatalog.byId('avatar_camera')!.localManifest!, {
            'mode': 'face',
          }, contractCallId: 'local-camera');
      expect(result.status, LocalSkillResultStatus.ok);
      expect(harness.director.calls, 1);
      expect(jsonDecode(result.output)['data'], [harness.director.lastResult]);
    },
  );

  test('existing read-only enforcement configuration stays closed', () async {
    final harness = await _Harness.create(
      rollout: FeatureRolloutMode.enforce,
      allowedIds: const {},
    );
    final result = jsonDecode(
      await harness.manager.invokeTool(_tool, {
        'mode': 'face',
      }, callId: 'read-only-policy'),
    );
    expect(result['status'], isNot('ok'));
    expect(harness.director.calls, 0);
    expect(
      harness.contract.recentDiagnostics.map((d) => d.code),
      contains('enforcement_ineligible'),
    );
  });

  test(
    'camera allowlist never admits another reversible local operation',
    () async {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        metadataResolver: (skill, method, schema) => skill is AvatarCameraSkill
            ? productionSkillActionContractMetadata(skill, method, schema)
            : const SkillActionContractMetadata(
                risk: ActionRisk.localMutation,
                consequencePolicy: ActionConsequencePolicy.reversible,
                enforcementEligibility:
                    ActionEnforcementEligibility.reversibleLocal,
              ),
      );
      final other = _OtherSkill('OtherCamera');
      harness.manager.registerSkill(other);
      final result = jsonDecode(
        await harness.manager.invokeTool(
          SkillManager.nativeToolName(other, 'setFraming'),
          {'mode': 'face'},
          callId: 'other-camera',
        ),
      );
      expect(result['status'], isNot('ok'));
      expect(other.calls, 0);
      expect(
        harness.contract.recentDiagnostics.map((d) => d.code),
        contains('enforcement_ineligible'),
      );
    },
  );

  test('an exact ID cannot bypass risk or domain eligibility checks', () async {
    for (final entry in [
      (
        ActionRisk.externalWrite,
        ActionConsequencePolicy.reversible,
        ActionEnforcementEligibility.reversibleLocal,
        'enforcement_ineligible',
      ),
      (
        ActionRisk.localMutation,
        ActionConsequencePolicy.exactTextCommit,
        ActionEnforcementEligibility.reversibleLocal,
        'enforcement_ineligible',
      ),
      (
        ActionRisk.localMutation,
        ActionConsequencePolicy.reversible,
        ActionEnforcementEligibility.domainAuthorized,
        'domain_authority_required',
      ),
      (
        ActionRisk.localMutation,
        ActionConsequencePolicy.reversible,
        ActionEnforcementEligibility.unsupported,
        'enforcement_unsupported',
      ),
    ]) {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        metadataResolver: (_, _, _) => SkillActionContractMetadata(
          risk: entry.$1,
          consequencePolicy: entry.$2,
          enforcementEligibility: entry.$3,
        ),
      );
      final result = jsonDecode(
        await harness.manager.invokeTool(_tool, {
          'mode': 'face',
        }, callId: 'wrong-classification'),
      );
      expect(result['status'], isNot('ok'));
      expect(harness.director.calls, 0);
      expect(
        harness.contract.recentDiagnostics.map((d) => d.code),
        contains(entry.$4),
      );
    }
  });

  test(
    'host allowlist is immutable and rejects wildcard configuration',
    () async {
      final ids = <String>{};
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        allowedIds: ids,
      );
      ids.add(_tool);
      final result = jsonDecode(
        await harness.manager.invokeTool(_tool, {
          'mode': 'face',
        }, callId: 'late-allowlist-mutation'),
      );
      expect(result['status'], isNot('ok'));
      expect(harness.director.calls, 0);
      await expectLater(
        _Harness.create(
          rollout: FeatureRolloutMode.enforce,
          allowedIds: {'skill_*'},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'reusing the native camera name cannot admit another skill handler',
    () async {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        registerCamera: false,
      );
      final other = _OtherSkill('AvatarCamera');
      harness.manager.registerSkill(other);
      final result = jsonDecode(
        await harness.manager.invokeTool(_tool, {
          'mode': 'face',
        }, callId: 'forged-native-camera'),
      );
      expect(result['status'], isNot('ok'));
      expect(other.calls, 0);
      expect(
        harness.contract.recentDiagnostics.map((d) => d.code),
        contains('enforcement_unsupported'),
      );
    },
  );

  test(
    'reusing local camera ID cannot invoke a different concrete handler',
    () async {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        registerCamera: false,
      );
      final other = _OtherSkill('AvatarCamera');
      harness.manager.registerSkill(other);
      final forged = LocalSkillManifest(
        id: 'avatar_camera',
        skillName: 'AvatarCamera',
        method: 'setFraming',
        summary: 'forged',
        tags: const [],
        argsSchema: AvatarCameraSkill.argumentsSchema,
        risk: LocalSkillRisk.writeLocal,
      );
      final result = await LocalSkillInvoker(
        skillManager: harness.manager,
      ).invoke(forged, {'mode': 'face'}, contractCallId: 'forged-local-camera');
      expect(result.status, LocalSkillResultStatus.denied);
      expect(jsonDecode(result.output)['code'], 'local_skill_binding_mismatch');
      expect(other.calls, 0);
    },
  );

  test(
    'local camera success also uses the strict production output schema',
    () async {
      final harness = await _Harness.create(
        rollout: FeatureRolloutMode.enforce,
        output: {'ok': true},
      );
      final result = await LocalSkillInvoker(skillManager: harness.manager)
          .invoke(SkillCatalog.byId('avatar_camera')!.localManifest!, {
            'mode': 'face',
          }, contractCallId: 'malformed-local-camera');
      expect(result.status, LocalSkillResultStatus.error);
      expect(jsonDecode(result.output)['code'], 'invalid_tool_outcome');
      expect(harness.director.calls, 1);
    },
  );

  test(
    'enforcement rejects incomplete or invented successful camera output',
    () async {
      final malformed = <Map<String, dynamic>>[
        {'ok': true},
        {..._success('face'), 'ok': false},
        {..._success('face'), 'mode': 'raw'},
        {..._success('face'), 'framing': 'custom'},
        {..._success('face'), 'automatic': 'false'},
        {..._success('face'), 'idleTimeoutSeconds': 100000},
        {..._success('face'), 'internal': 'private-sentinel'},
      ];
      for (final malformedOutput in malformed) {
        final harness = await _Harness.create(
          rollout: FeatureRolloutMode.enforce,
          output: malformedOutput,
        );
        final raw = await harness.manager.invokeTool(_tool, {
          'mode': 'face',
        }, callId: 'malformed-camera');
        final result = jsonDecode(raw);
        expect(result['status'], 'failed');
        expect(result['code'], 'invalid_tool_outcome');
        expect(raw, isNot(contains('private-sentinel')));
        expect(harness.director.calls, 1);
      }
    },
  );

  test('director failure remains failure with no success payload', () async {
    final harness = await _Harness.create(
      rollout: FeatureRolloutMode.enforce,
      output: {'ok': false, 'error': 'camera_request_superseded'},
    );
    final result = jsonDecode(
      await harness.manager.invokeTool(_tool, {
        'mode': 'face',
      }, callId: 'superseded-camera'),
    );
    expect(result['status'], 'failed');
    expect(result['code'], 'camera_request_superseded');
    expect(result['data'], [
      {
        'actionIndex': 0,
        'status': 'failed',
        'code': 'camera_request_superseded',
        'retryable': false,
      },
    ]);
  });
}

Map<String, dynamic> _success(String mode) => {
  'ok': true,
  'mode': mode,
  'framing': switch (mode) {
    'face' => 'head',
    'bust' || 'auto' => 'upper_body',
    _ => 'hero_full_body',
  },
  'automatic': mode == 'auto',
  'idleTimeoutSeconds': 45,
};

class _Director implements AvatarCameraDirector {
  _Director(this.output);

  final Map<String, dynamic>? output;
  Map<String, dynamic>? lastResult;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> setFraming(
    String mode, {
    String agentId = 'self',
  }) async {
    expect(agentId, 'self');
    calls++;
    return lastResult = output ?? _success(mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness(this.manager, this.director, this.contract);

  final SkillManager manager;
  final _Director director;
  final ActionContractV2Service contract;

  static Future<_Harness> create({
    required FeatureRolloutMode rollout,
    Set<String> allowedIds = const {_tool, 'local.avatar_camera'},
    SkillActionContractMetadataResolver? metadataResolver,
    bool registerCamera = true,
    Map<String, dynamic>? output,
  }) async {
    final now = DateTime.utc(2026, 9, 8);
    final flags = await MaasoFeatureFlagService(
      store: _FlagStore(),
      compileMaximums: const {
        MaasoFeatureFlag.actionContractV2: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.actionContractV2,
      mode: rollout,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final catalog = ProductionActionDefinitionCatalog();
    final contract = ActionContractV2Service(
      featureFlags: flags,
      catalog: catalog,
      audit: _AuditSink(),
      accountScope: 'camera-account',
      accountGeneration: 1,
      mountIsCurrent: () => true,
      enforcedReversibleLocalActionIds: allowedIds,
    );
    addTearDown(contract.onClose);
    addTearDown(flags.onClose);
    final director = _Director(output);
    final manager = SkillManager(
      actionContract: contract,
      productionCatalog: catalog,
      actionContractAgentId: 'self',
      contractMetadataResolver:
          metadataResolver ?? productionSkillActionContractMetadata,
    );
    if (registerCamera) {
      manager.registerSkill(AvatarCameraSkill(director: director));
    }
    return _Harness(manager, director, contract);
  }
}

class _OtherSkill extends AgentSkill {
  _OtherSkill(this.skillName);

  @override
  final String skillName;
  int calls = 0;
  @override
  String get description => 'Probe';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setFraming': (_) {
      calls++;
      return jsonEncode(_success('face'));
    },
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'setFraming': AvatarCameraSkill.argumentsSchema,
  };
}

class _AuditSink implements ActionContractV2AuditSink {
  @override
  String record(ActionContractAuditRecord record) =>
      'camera-${record.invocation.callId}-${record.definition.id}';
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
