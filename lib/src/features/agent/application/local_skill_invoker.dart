import 'dart:convert';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_execution_context.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_legacy_adapter.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/action_json_snapshot.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_skill_action_metadata.dart';
import 'package:maaso/src/features/agent/application/action/tool_outcome.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart'
    show SkillActionContractMetadata;
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

enum LocalSkillResultStatus {
  ok,
  invalidArguments,
  denied,
  commitRequired,
  unavailable,
  error,
}

class LocalSkillResult {
  final LocalSkillResultStatus status;
  final String skillId;
  final String output;

  const LocalSkillResult({
    required this.status,
    required this.skillId,
    required this.output,
  });
}

/// Executes local-agent skill actions through the shared Dart skill handlers.
///
/// The cloud runtime owns JS/native tool orchestration. This invoker is a
/// smaller local-only gate: it accepts a retrieved [LocalSkillManifest], checks
/// policy, then calls the same skill method implementation without touching
/// AgentRuntime's prompts or loops.
class LocalSkillInvoker {
  static const ActionSchemaValidator _schemaValidator = ActionSchemaValidator();
  static int _nextContractCallSerial = 0;

  LocalSkillInvoker({
    required SkillManager skillManager,
    String? actionContractAgentId,
    AppCapabilitySnapshotService? capabilitySnapshotService,
    Iterable<AppCapabilityKey>? Function(LocalSkillManifest manifest)?
    capabilityKeysResolver,
    bool Function(LocalSkillManifest manifest)? availabilityResolver,
  }) : _skillManager = skillManager,
       _capabilitySnapshotServiceOverride = capabilitySnapshotService,
       _capabilityKeysResolver = capabilityKeysResolver,
       _availabilityResolver = availabilityResolver,
       _actionContractAgentId =
           actionContractAgentId?.trim() ?? skillManager.actionContractAgentId;

  final SkillManager _skillManager;
  final String _actionContractAgentId;
  final AppCapabilitySnapshotService? _capabilitySnapshotServiceOverride;
  final Iterable<AppCapabilityKey>? Function(LocalSkillManifest manifest)?
  _capabilityKeysResolver;
  final bool Function(LocalSkillManifest manifest)? _availabilityResolver;

  Future<LocalSkillResult> invoke(
    LocalSkillManifest manifest,
    Map<String, dynamic> args, {
    bool confirmed = false,
    AppLocale? locale,
    String? contractCallId,
  }) {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    return AgentPromptCatalog.runWithLocale(
      turnLocale,
      () => _invoke(
        manifest,
        args,
        confirmed: confirmed,
        contractCallId: contractCallId,
      ),
    );
  }

  Future<LocalSkillResult> _invoke(
    LocalSkillManifest manifest,
    Map<String, dynamic> args, {
    required bool confirmed,
    required String? contractCallId,
  }) async {
    if (!manifest.localEligible) {
      return LocalSkillResult(
        status: LocalSkillResultStatus.denied,
        skillId: manifest.id,
        output: jsonEncode({'error': 'local_skill_not_allowed'}),
      );
    }
    final capabilityService = _readCapabilitySnapshotService();
    AppCapabilitySnapshotLease? capabilityLease;
    if (!_isManifestAvailable(manifest)) {
      return _capabilityUnavailable(manifest.id);
    }
    if (capabilityService != null) {
      try {
        final capabilityKeys = _capabilityKeysResolver?.call(manifest);
        if (capabilityService.isClosed || capabilityKeys == null) {
          return _capabilityUnavailable(manifest.id);
        }
        final requiredKeys = Set<AppCapabilityKey>.unmodifiable(capabilityKeys);
        if (requiredKeys.isEmpty) return _capabilityUnavailable(manifest.id);
        capabilityLease = capabilityService
            .acquireLease(requiredKeys, requireVisible: true)
            .lease;
      } catch (_) {
        capabilityLease = null;
      }
      if (capabilityLease == null) {
        return _capabilityUnavailable(manifest.id);
      }
    }
    final finalArgs = Map<String, dynamic>.unmodifiable(<String, dynamic>{
      ...args,
      ...manifest.fixedArgs,
    });
    final validation = _schemaValidator.validate(
      schema: manifest.argsSchema,
      value: finalArgs,
    );
    if (!validation.isValid) {
      Log.w(
        '[LocalSkill] invalid_arguments for ${manifest.id} '
        '(${validation.schemaValid ? 'arguments' : 'host_schema'})',
      );
      return LocalSkillResult(
        status: LocalSkillResultStatus.invalidArguments,
        skillId: manifest.id,
        output: ToolOutcome.failure(
          status: ToolOutcomeStatus.invalidArguments,
          code: 'invalid_arguments',
        ).toJsonString(),
      );
    }
    final encodedFinalArgs = jsonEncode(finalArgs);
    final contractArguments = Map<String, dynamic>.from(
      jsonDecode(encodedFinalArgs) as Map,
    );
    if (manifest.requiresConfirmation && !confirmed) {
      return LocalSkillResult(
        status: LocalSkillResultStatus.commitRequired,
        skillId: manifest.id,
        output: jsonEncode({
          'status': 'confirmation_required',
          'skill': manifest.id,
          // Post-merge args: shows exactly what the handler will receive, so the
          // caller can render accurate confirmation UI.
          'args': jsonDecode(encodedFinalArgs),
        }),
      );
    }

    final skill = _skillManager.findSkill(manifest.skillName);
    if (skill == null) {
      return LocalSkillResult(
        status: LocalSkillResultStatus.unavailable,
        skillId: manifest.id,
        output: jsonEncode({'error': 'skill_unavailable'}),
      );
    }
    final handler = skill.methods[manifest.method];
    if (handler == null) {
      return LocalSkillResult(
        status: LocalSkillResultStatus.unavailable,
        skillId: manifest.id,
        output: jsonEncode({'error': 'method_unavailable'}),
      );
    }

    try {
      var capabilityRevoked = false;
      final actionId = _localActionId(manifest.id);
      SkillActionContractMetadata? sourceMetadata;
      if (actionId == 'local.avatar_camera') {
        // This ID is explicitly enabled in production. Its concrete built-in
        // handler and output contract, not caller-supplied manifest metadata,
        // must own that exception.
        sourceMetadata = productionSkillActionContractMetadata(
          skill,
          manifest.method,
          manifest.argsSchema,
        );
        if (manifest.id != 'avatar_camera' ||
            manifest.skillName != 'AvatarCamera' ||
            manifest.method != 'setFraming' ||
            sourceMetadata == null) {
          return LocalSkillResult(
            status: LocalSkillResultStatus.denied,
            skillId: manifest.id,
            output: ToolOutcome.failure(
              status: ToolOutcomeStatus.denied,
              code: 'local_skill_binding_mismatch',
            ).toJsonString(),
          );
        }
      }
      final definition = _localProductionDefinition(
        actionId: actionId,
        manifest: manifest,
        sourceMetadata: sourceMetadata,
        sourceInputSchema: sourceMetadata == null
            ? null
            : skill.nativeToolSchemas?[manifest.method],
      );
      final expectedDefinition = _skillManager.bindProductionActionDefinition(
        ownerKey:
            'local\u0000${manifest.id}\u0000${manifest.skillName}'
            '\u0000${manifest.method}',
        definition: definition,
      );
      final execution = await _skillManager.executeContractActionWithResult(
        actionId: actionId,
        arguments: contractArguments,
        expectedDefinition: expectedDefinition,
        channel: ActionContractChannel.localAgent,
        scope: AgentActionScope.chat,
        agentId: _actionContractAgentId,
        callId: contractCallId ?? _nextContractCallId(),
        legacyCallback: () async {
          if (!_isManifestAvailable(manifest) ||
              (capabilityService != null &&
                  (capabilityLease == null ||
                      !capabilityService.isCurrent(capabilityLease)))) {
            capabilityRevoked = true;
            return ActionContractLegacyResult.single(
              ToolOutcome.failure(
                status: ToolOutcomeStatus.unavailable,
                code: 'capability_unavailable',
              ).toJsonString(),
            );
          }
          final service = capabilityService;
          final lease = capabilityLease;
          Future<dynamic> startHandler() =>
              _skillManager.runTrackedHandler<dynamic>(
                skill: skill,
                method: manifest.method,
                channel: SkillUsageChannel.local,
                operation: () => handler([encodedFinalArgs]),
              );
          late final dynamic result;
          try {
            result = service == null || lease == null
                ? await startHandler()
                : await AppCapabilityExecutionContext.run<dynamic>(
                    service: service,
                    lease: lease,
                    operation: startHandler,
                  );
          } on StateError catch (error) {
            if (error.message != 'capability_snapshot_stale') rethrow;
            capabilityRevoked = true;
            return ActionContractLegacyResult.single(
              ToolOutcome.failure(
                status: ToolOutcomeStatus.unavailable,
                code: 'capability_unavailable',
              ).toJsonString(),
            );
          }
          final output = result == null ? '{}' : result.toString();
          return ActionContractLegacyResult.single(output);
        },
      );
      if (capabilityRevoked) {
        return _capabilityUnavailable(manifest.id);
      }
      final output = execution.output == null
          ? '{}'
          : execution.output.toString();
      return LocalSkillResult(
        status: execution.isLegacy
            ? LocalSkillResultStatus.ok
            : _typedLocalStatus(output),
        skillId: manifest.id,
        output: output,
      );
    } catch (error, stackTrace) {
      Log.e(
        '[LocalSkill] ${manifest.skillName}.${manifest.method} failed: '
        '$error\n$stackTrace',
      );
      return LocalSkillResult(
        status: LocalSkillResultStatus.error,
        skillId: manifest.id,
        output: jsonEncode({'error': 'execution_failed'}),
      );
    }
  }

  String _nextContractCallId() {
    _nextContractCallSerial += 1;
    return 'localAgent-$_nextContractCallSerial';
  }

  AppCapabilitySnapshotService? _readCapabilitySnapshotService() {
    try {
      return _capabilitySnapshotServiceOverride ??
          appServices.maybeFind<AppCapabilitySnapshotService>();
    } catch (_) {
      return _capabilitySnapshotServiceOverride;
    }
  }

  bool _isManifestAvailable(LocalSkillManifest manifest) {
    final resolver = _availabilityResolver;
    if (resolver == null) return true;
    try {
      return resolver(manifest);
    } catch (_) {
      return false;
    }
  }

  LocalSkillResult _capabilityUnavailable(String skillId) => LocalSkillResult(
    status: LocalSkillResultStatus.unavailable,
    skillId: skillId,
    output: jsonEncode({'error': 'capability_unavailable'}),
  );
}

String _localActionId(String manifestId) {
  final sanitized = manifestId.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9_-]'),
    '_',
  );
  final bounded = sanitized.isEmpty ? 'unknown' : sanitized;
  final suffix = bounded.length > 122 ? bounded.substring(0, 122) : bounded;
  return 'local.$suffix';
}

ProductionActionDefinition _localProductionDefinition({
  required String actionId,
  required LocalSkillManifest manifest,
  SkillActionContractMetadata? sourceMetadata,
  Map<String, dynamic>? sourceInputSchema,
}) {
  final input = snapshotActionJson(sourceInputSchema ?? manifest.argsSchema);
  if (input is! Map<String, Object?>) {
    throw const ActionJsonSnapshotException('schema_not_object');
  }
  final metadata = _localRiskMetadata(manifest.risk);
  return ProductionActionDefinition(
    definition: ActionDefinition(
      id: actionId,
      inputSchema: Map<String, dynamic>.unmodifiable(input),
      outputSchema: sourceMetadata?.outputSchema,
      scopes: const <AgentActionScope>{AgentActionScope.chat},
      risk: sourceMetadata?.risk ?? metadata.risk,
      consequencePolicy:
          sourceMetadata?.consequencePolicy ?? metadata.consequence,
      targetResolver: (_) => 'local:${Uri.encodeComponent(manifest.id)}',
      handler: _localDefinitionHandlerMustNotRun,
    ),
    channels: const <ActionContractChannel>{ActionContractChannel.localAgent},
    enforcementEligibility:
        sourceMetadata?.enforcementEligibility ?? metadata.eligibility,
  );
}

({
  ActionRisk risk,
  ActionConsequencePolicy consequence,
  ActionEnforcementEligibility eligibility,
})
_localRiskMetadata(LocalSkillRisk risk) => switch (risk) {
  LocalSkillRisk.read => (
    risk: ActionRisk.readOnly,
    consequence: ActionConsequencePolicy.reversible,
    // Local manifests do not yet declare a bounded successful-output schema.
    // Keep them observable in off/shadow, but fail closed in enforce instead
    // of treating a generic `{}` as an output contract.
    eligibility: ActionEnforcementEligibility.unsupported,
  ),
  LocalSkillRisk.writeLocal => (
    risk: ActionRisk.localMutation,
    consequence: ActionConsequencePolicy.reversible,
    eligibility: ActionEnforcementEligibility.reversibleLocal,
  ),
  LocalSkillRisk.external || LocalSkillRisk.sideEffect => (
    risk: ActionRisk.externalWrite,
    consequence: ActionConsequencePolicy.exactTextCommit,
    eligibility: ActionEnforcementEligibility.domainAuthorized,
  ),
  LocalSkillRisk.unsafe => (
    risk: ActionRisk.destructive,
    consequence: ActionConsequencePolicy.destructive,
    eligibility: ActionEnforcementEligibility.unsupported,
  ),
};

LocalSkillResultStatus _typedLocalStatus(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        !decoded.containsKey('code') ||
        !decoded.containsKey('retryable')) {
      return LocalSkillResultStatus.error;
    }
    return switch (decoded['status']) {
      'ok' => LocalSkillResultStatus.ok,
      'invalid_arguments' => LocalSkillResultStatus.invalidArguments,
      'confirmation_required' => LocalSkillResultStatus.commitRequired,
      'denied' => LocalSkillResultStatus.denied,
      'unavailable' => LocalSkillResultStatus.unavailable,
      _ => LocalSkillResultStatus.error,
    };
  } on Object {
    return LocalSkillResultStatus.error;
  }
}

Object? _localDefinitionHandlerMustNotRun(Map<String, dynamic> _) =>
    throw StateError('action_definition_handler_is_metadata_only');
