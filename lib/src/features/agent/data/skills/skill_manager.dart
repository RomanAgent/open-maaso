import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_legacy_adapter.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/action_json_snapshot.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/tool_outcome.dart';

import 'agent_skill.dart';
import 'agent_skill_structured_action_schema.dart';

/// Output format for [SkillManager.toNativeTools].
///
/// OpenAI / DeepSeek / Moonshot / Anthropic-OpenAI-compat all eat the
/// `{"type":"function","function":{...}}` envelope.  Anthropic's native API
/// uses a flatter shape.  Gemini uses `{"functionDeclarations":[...]}` which
/// is also derivable from the same schema.
enum NativeToolFormat { openai, anthropic }

/// Optional local presentation for an admitted handler. The returned cleanup
/// must be synchronous and must not delay or change the capability's outcome.
typedef SkillHandlerPresentation =
    void Function()? Function(AgentSkill skill, String method);

/// Explicit security metadata for one Skill method at the V2 contract edge.
///
/// No method is inferred to be read-only from its name. Callers that do not
/// provide metadata get an `unsupported` definition, which remains observable
/// in shadow mode but cannot execute in enforce mode.
final class SkillActionContractMetadata {
  const SkillActionContractMetadata({
    required this.risk,
    required this.consequencePolicy,
    required this.enforcementEligibility,
    this.outputSchema = const <String, dynamic>{},
    this.scopes = const <AgentActionScope>{AgentActionScope.chat},
  });

  const SkillActionContractMetadata.readOnly({
    this.outputSchema = const <String, dynamic>{},
    this.scopes = const <AgentActionScope>{AgentActionScope.chat},
  }) : risk = ActionRisk.readOnly,
       consequencePolicy = ActionConsequencePolicy.reversible,
       enforcementEligibility = ActionEnforcementEligibility.readOnly;

  static const unsupported = SkillActionContractMetadata(
    risk: ActionRisk.destructive,
    consequencePolicy: ActionConsequencePolicy.destructive,
    enforcementEligibility: ActionEnforcementEligibility.unsupported,
  );

  final ActionRisk risk;
  final ActionConsequencePolicy consequencePolicy;
  final ActionEnforcementEligibility enforcementEligibility;
  final Map<String, dynamic> outputSchema;
  final Set<AgentActionScope> scopes;
}

typedef SkillActionContractMetadataResolver =
    SkillActionContractMetadata? Function(
      AgentSkill skill,
      String method,
      Map<String, dynamic> inputSchema,
    );

/// Contract disposition retained for channel owners that need retry handling.
final class SkillContractExecutionResult {
  const SkillContractExecutionResult({
    required this.status,
    required this.output,
  });

  final ActionContractExecutionStatus status;
  final Object? output;

  bool get isLegacy => status == ActionContractExecutionStatus.legacy;
  bool get isRejected => status == ActionContractExecutionStatus.rejected;
}

/// Stable, value-redacting failure raised before a native handler executes.
final class InvalidToolArgumentsException implements Exception {
  const InvalidToolArgumentsException({
    required this.toolName,
    required this.validation,
  });

  final String toolName;
  final ActionSchemaValidationResult validation;

  String get code => 'bad_arguments';

  @override
  String toString() =>
      'InvalidToolArgumentsException: $code for $toolName '
      '(${validation.schemaValid ? 'arguments' : 'host_schema'})';
}

class SkillManager {
  static int _nextGeneratedContractCallSerial = 0;

  SkillManager({
    ActionContractV2Service? actionContract,
    ProductionActionDefinitionCatalog? productionCatalog,
    String actionContractAgentId = 'self',
    SkillActionContractMetadataResolver? contractMetadataResolver,
    SkillUsageService? usageService,
    bool useAppServicesUsageFallback = true,
    bool requirePinnedActionContract = false,
    bool useAppServicesActionContractFallback = true,
    SkillHandlerPresentation? beginHandlerPresentation,
  }) : _injectedActionContract = actionContract,
       _injectedProductionCatalog = productionCatalog,
       _actionContractAgentId = actionContractAgentId.trim(),
       _contractMetadataResolver = contractMetadataResolver,
       _usageService =
           usageService ??
           (useAppServicesUsageFallback
               ? appServices.maybeFind<SkillUsageService>()
               : null),
       _requirePinnedActionContract = requirePinnedActionContract,
       _useAppServicesActionContractFallback =
           useAppServicesActionContractFallback,
       _beginHandlerPresentation = beginHandlerPresentation {
    if (_actionContractAgentId.isEmpty) {
      throw ArgumentError.value(
        actionContractAgentId,
        'actionContractAgentId',
        'must not be empty',
      );
    }
  }

  static const ActionSchemaValidator _schemaValidator = ActionSchemaValidator();
  static const Map<String, dynamic> _genericObjectSchema = <String, dynamic>{
    'type': 'object',
  };

  final ActionContractV2Service? _injectedActionContract;
  final ProductionActionDefinitionCatalog? _injectedProductionCatalog;
  final String _actionContractAgentId;
  final SkillActionContractMetadataResolver? _contractMetadataResolver;
  final SkillUsageService? _usageService;
  final bool _requirePinnedActionContract;
  final bool _useAppServicesActionContractFallback;
  final SkillHandlerPresentation? _beginHandlerPresentation;

  final List<AgentSkill> _skills = [];
  final Map<String, AgentSkill> _firstSkillByName = <String, AgentSkill>{};
  final Map<String, _SkillMethodBinding> _firstMethodBindingByToolName =
      <String, _SkillMethodBinding>{};
  final List<_NativeToolBinding> _nativeBindingsInOrder =
      <_NativeToolBinding>[];
  final Map<String, _NativeToolBinding> _firstNativeBindingByToolName =
      <String, _NativeToolBinding>{};
  final Map<String, _ContractMethodBinding> _firstContractBindingByToolName =
      <String, _ContractMethodBinding>{};
  final Map<String, String> _contractOwnerByActionId = <String, String>{};
  final Set<String> _ambiguousContractActionIds = <String>{};
  List<AgentSkill>? _skillsSnapshot;

  String get actionContractAgentId => _actionContractAgentId;

  /// The original account's observer, never resolved again after a switch.
  SkillUsageService? get pinnedUsageService => _usageService;

  /// Immutable registration-order snapshot.
  ///
  /// Repeated reads within one registration generation reuse the same list.
  /// A later registration creates a new snapshot without mutating lists that
  /// callers already hold.
  List<AgentSkill> get skills =>
      _skillsSnapshot ??= List<AgentSkill>.unmodifiable(_skills);

  /// Whether at least one registered method has a native tool schema.
  bool get hasNativeTools => _nativeBindingsInOrder.isNotEmpty;

  /// Returns the first registered skill with the exact [skillName].
  AgentSkill? findSkill(String skillName) => _firstSkillByName[skillName];

  /// Whether a skill with the exact [skillName] has been registered.
  bool containsSkill(String skillName) =>
      _firstSkillByName.containsKey(skillName);

  /// A local account-bound observation of an admitted handler invocation.
  /// Call this inside the actual dispatch callback, after all owner/schema/
  /// permission gates. Bookkeeping never waits before the handler starts and
  /// never changes its result. Normal return is not proof of a business effect.
  Future<T> runTrackedHandler<T>({
    required AgentSkill skill,
    required String method,
    required SkillUsageChannel channel,
    required FutureOr<T> Function() operation,
  }) async {
    SkillUsageAttempt? attempt;
    void Function()? endPresentation;
    try {
      attempt = _usageService?.start(
        skillName: skill.skillName,
        method: method,
        channel: channel,
      );
    } catch (_) {
      // Statistics must not become an execution dependency.
    }
    try {
      endPresentation = _beginHandlerPresentation?.call(skill, method);
    } catch (_) {
      // Optional body presentation must not block a capability invocation.
    }
    try {
      final result = await Future<T>.sync(operation);
      if (attempt != null) {
        unawaited(attempt.finish(succeeded: _handlerReturnedNormally(result)));
      }
      return result;
    } catch (_) {
      if (attempt != null) unawaited(attempt.finish(succeeded: false));
      rethrow;
    } finally {
      try {
        endPresentation?.call();
      } catch (_) {
        // Cleanup cannot replace a tool result or its original failure.
      }
    }
  }

  static bool _handlerReturnedNormally(Object? output) {
    try {
      final Object? value = output is String && output.length <= 16384
          ? jsonDecode(output)
          : output;
      if (value is! Map) return true;
      if (value['error'] != null || value['ok'] == false) return false;
      final status = value['status'];
      if (status is int) return status >= 200 && status < 300;
      return !const {
        'error',
        'failed',
        'denied',
        'unavailable',
        'invalid_arguments',
        'cancelled',
        'canceled',
      }.contains(status);
    } catch (_) {
      return true;
    }
  }

  /// Returns the first registered skill method whose generated name is
  /// [toolName], including methods without native schemas.
  ///
  /// This mirrors the legacy structured-action owner lookup. Native tool
  /// invocation intentionally has a separate schema-backed first-match index.
  AgentSkill? skillOwnerForTool(String toolName) =>
      _firstMethodBindingByToolName[toolName]?.skill;

  /// Returns the method owned by [skillOwnerForTool], if any.
  String? methodNameForTool(String toolName) =>
      _firstMethodBindingByToolName[toolName]?.method;

  /// Register a skill and snapshot its method/schema key vocabulary.
  ///
  /// Handler values are still resolved from [AgentSkill.methods] at invocation
  /// time. Rebuild the manager when a skill's advertised keys change.
  void registerSkill(AgentSkill skill) {
    final skillName = skill.skillName;
    final initialMethods = skill.methods;
    final schemas = skill.nativeToolSchemas;
    final nativeSchemas = schemas ?? const <String, Map<String, dynamic>>{};
    final structuredSchemas = skill is StructuredActionPromptSchemaProvider
        ? (skill as StructuredActionPromptSchemaProvider)
              .structuredActionPromptSchemas
        : StructuredActionPromptSchemas(nativeSchemas);
    final orderedContractMethods = <String>[
      ...initialMethods.keys,
      for (final method in structuredSchemas.methodNames)
        if (!initialMethods.containsKey(method)) method,
      for (final method in nativeSchemas.keys)
        if (!initialMethods.containsKey(method) &&
            !structuredSchemas.methodNames.contains(method))
          method,
    ];
    final contractBindingsByMethod = <String, _ContractMethodBinding>{};
    for (final method in orderedContractMethods) {
      final inputSchema =
          structuredSchemas.schemaFor(method) ??
          nativeSchemas[method] ??
          _genericObjectSchema;
      final binding = _createContractBinding(
        skill: skill,
        method: method,
        inputSchema: inputSchema,
        hasNativeSchema: nativeSchemas.containsKey(method),
      );
      contractBindingsByMethod[method] = binding;
      final previous = _firstContractBindingByToolName.putIfAbsent(
        binding.toolName,
        () => binding,
      );
      if (!_sameContractOwner(previous, binding)) {
        _ambiguousContractActionIds.add(binding.toolName);
      }
      _ensureProductionBinding(binding);
    }
    final methodBindings = <_SkillMethodBinding>[
      for (final method in initialMethods.keys)
        _SkillMethodBinding(
          skill: skill,
          method: method,
          toolName: nativeToolName(skill, method),
          contract: contractBindingsByMethod[method]!,
        ),
    ];
    final nativeBindings = <_NativeToolBinding>[
      for (final entry in nativeSchemas.entries)
        _NativeToolBinding(
          skill: skill,
          method: entry.key,
          toolName: nativeToolName(skill, entry.key),
          schema: entry.value,
          contract: contractBindingsByMethod[entry.key]!,
        ),
    ];

    _skills.add(skill);
    _skillsSnapshot = null;
    _firstSkillByName.putIfAbsent(skillName, () => skill);
    for (final binding in methodBindings) {
      _firstMethodBindingByToolName.putIfAbsent(
        binding.toolName,
        () => binding,
      );
    }
    for (final binding in nativeBindings) {
      _nativeBindingsInOrder.add(binding);
      _firstNativeBindingByToolName.putIfAbsent(
        binding.toolName,
        () => binding,
      );
    }
  }

  // ────────────────────── Native tool_calls channel ──────────────────────

  /// Collect every skill method that declares a [AgentSkill.nativeToolSchemas]
  /// entry and emit them as a `tools` array ready to send alongside the
  /// chat completion request.
  ///
  /// Naming convention is `skill_<skillName>_<methodName>` — lowercased,
  /// non-alphanumeric collapsed to `_`.  Stable + deterministic so the
  /// caller can round-trip tool_call names back to (skill, method) without
  /// extra state.
  List<Map<String, dynamic>> toNativeTools({
    NativeToolFormat format = NativeToolFormat.openai,
    AppLocale? locale,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final binding in _nativeBindingsInOrder) {
      final skill = binding.skill;
      final method = binding.method;
      final name = binding.toolName;
      final description = AgentSkillPromptMetadata.methodDescription(
        skill,
        method,
        locale: locale,
      );
      final localizedSchema = AgentSkillPromptMetadata.schema(
        skill,
        method,
        binding.schema,
        locale: locale,
      );
      switch (format) {
        case NativeToolFormat.openai:
          out.add({
            'type': 'function',
            'function': {
              'name': name,
              'description': description,
              'parameters': localizedSchema,
            },
          });
          break;
        case NativeToolFormat.anthropic:
          out.add({
            'name': name,
            'description': description,
            'input_schema': localizedSchema,
          });
          break;
      }
    }
    return out;
  }

  /// Resolve a tool name (as emitted by [toNativeTools]) back to (skill,
  /// method) and invoke it with the given arguments map.  Returns the JSON
  /// string result the skill produced — caller hands this to the LLM as
  /// the `tool` role response.
  ///
  /// Throws [StateError] when the tool name doesn't resolve.  Skill-level
  /// failures (validation, network, etc.) propagate as the JSON the skill
  /// chose to return (typically `{"error":"…"}`); we don't wrap them.
  ///
  /// Use [validateToolArguments] when a caller must validate a proposed tool
  /// invocation without executing its handler.
  Future<String> invokeTool(
    String toolName,
    Map<String, dynamic> args, {
    AppLocale? locale,
    String? callId,
    String? agentId,
    ActionContractChannel channel = ActionContractChannel.nativeTool,
    AgentActionScope actionScope = AgentActionScope.chat,
  }) async {
    final result = await invokeToolWithContract(
      toolName,
      args,
      locale: locale,
      callId: callId,
      agentId: agentId,
      channel: channel,
      actionScope: actionScope,
    );
    return result.output == null ? '{}' : result.output.toString();
  }

  /// Detailed variant used by owners that must restore a claimed operation
  /// after an enforced rejection or failed typed outcome.
  Future<SkillContractExecutionResult> invokeToolWithContract(
    String toolName,
    Map<String, dynamic> args, {
    AppLocale? locale,
    String? callId,
    String? agentId,
    ActionContractChannel channel = ActionContractChannel.nativeTool,
    AgentActionScope actionScope = AgentActionScope.chat,
  }) {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    return AgentPromptCatalog.runWithLocale(turnLocale, () async {
      final invocation = _preflightToolArguments(toolName, args);
      Future<ActionContractLegacyResult> invokeLegacy() async {
        // AgentSkill methods take a positional List<dynamic>. Keep passing one
        // JSON string so local and cloud callers share the same handlers.
        final result = await runTrackedHandler<dynamic>(
          skill: invocation.contract.skill,
          method: invocation.contract.method,
          channel: channel == ActionContractChannel.delayedTool
              ? SkillUsageChannel.delayed
              : SkillUsageChannel.native,
          operation: () => invocation.handler([jsonEncode(args)]),
        );
        final callerOutput = result == null ? '{}' : result.toString();
        return ActionContractLegacyResult.single(callerOutput);
      }

      final contract = _actionContract;
      if (contract == null) {
        if (_pinnedActionContractDependenciesUnavailable) {
          return SkillContractExecutionResult(
            status: ActionContractExecutionStatus.rejected,
            output: ToolOutcome.failure(
              status: ToolOutcomeStatus.unavailable,
              code: 'contract_dependency_unavailable',
            ).toJsonString(),
          );
        }
        final legacy = await invokeLegacy();
        return SkillContractExecutionResult(
          status: ActionContractExecutionStatus.legacy,
          output: legacy.callerOutput,
        );
      }
      final effectiveChannel = _effectiveContractChannel(
        invocation.contract,
        channel,
      );
      final expectedDefinition = _exactProductionDefinition(
        invocation.contract,
      );
      return _executeWithContractService(
        contract: contract,
        actionId: toolName,
        arguments: args,
        expectedDefinition: expectedDefinition,
        channel: effectiveChannel,
        scope: actionScope,
        agentId: agentId ?? _actionContractAgentId,
        callId: callId ?? _nextContractCallId(effectiveChannel),
        legacyCallback: invokeLegacy,
      );
    });
  }

  /// Returns the exact catalog object for [toolName] on [channel].
  ///
  /// `null` means the binding is absent, ambiguous, changed since
  /// registration, or no longer identical to the account-owned catalog.
  ProductionActionDefinition? productionDefinitionForTool(
    String toolName, {
    ActionContractChannel channel = ActionContractChannel.nativeTool,
  }) {
    final binding = switch (channel) {
      ActionContractChannel.nativeTool || ActionContractChannel.delayedTool =>
        _firstNativeBindingByToolName[toolName]?.contract,
      _ => _firstMethodBindingByToolName[toolName]?.contract,
    };
    return binding == null ? null : _exactProductionDefinition(binding);
  }

  /// Creates one exact method-specific call for a batch owner such as the
  /// structured-action runtime. This method performs no effect.
  ActionContractCall contractCallForTool({
    required String toolName,
    required Map<String, dynamic> arguments,
    required ActionContractChannel channel,
    String? target,
  }) {
    final binding = switch (channel) {
      ActionContractChannel.nativeTool || ActionContractChannel.delayedTool =>
        _firstNativeBindingByToolName[toolName]?.contract,
      _ => _firstMethodBindingByToolName[toolName]?.contract,
    };
    final effectiveChannel = binding == null
        ? channel
        : _effectiveContractChannel(binding, channel);
    return ActionContractCall(
      actionId: toolName,
      arguments: arguments,
      target: target,
      channel: effectiveChannel,
      expectedDefinition: binding == null
          ? null
          : _exactProductionDefinition(binding),
    );
  }

  /// Binds non-native channel metadata, for example a local manifest, into the
  /// same account catalog without replacing an existing definition.
  ProductionActionDefinition? bindProductionActionDefinition({
    required String ownerKey,
    required ProductionActionDefinition definition,
  }) {
    final normalizedOwner = ownerKey.trim();
    if (normalizedOwner.isEmpty) return null;
    return _bindDefinition(
      actionId: definition.definition.id,
      ownerKey: normalizedOwner,
      candidate: definition,
    );
  }

  /// Runs an existing owner callback through one Action Contract admission.
  ///
  /// With no account contract registered this is the exact legacy path. When
  /// a contract exists, its opaque admission owns callback one-shot semantics.
  Future<Object?> executeContractAction({
    required String actionId,
    required Map<String, dynamic> arguments,
    required ProductionActionDefinition? expectedDefinition,
    required ActionContractChannel channel,
    required AgentActionScope scope,
    required String agentId,
    required String callId,
    required ActionContractLegacyCallback legacyCallback,
    String? target,
  }) async {
    final result = await executeContractActionWithResult(
      actionId: actionId,
      arguments: arguments,
      expectedDefinition: expectedDefinition,
      channel: channel,
      scope: scope,
      agentId: agentId,
      callId: callId,
      legacyCallback: legacyCallback,
      target: target,
    );
    return result.output;
  }

  Future<SkillContractExecutionResult> executeContractActionWithResult({
    required String actionId,
    required Map<String, dynamic> arguments,
    required ProductionActionDefinition? expectedDefinition,
    required ActionContractChannel channel,
    required AgentActionScope scope,
    required String agentId,
    required String callId,
    required ActionContractLegacyCallback legacyCallback,
    String? target,
  }) async {
    final contract = _actionContract;
    if (contract == null) {
      if (_pinnedActionContractDependenciesUnavailable) {
        return SkillContractExecutionResult(
          status: ActionContractExecutionStatus.rejected,
          output: ToolOutcome.failure(
            status: ToolOutcomeStatus.unavailable,
            code: 'contract_dependency_unavailable',
          ).toJsonString(),
        );
      }
      final legacy = await Future<ActionContractLegacyResult>.sync(
        legacyCallback,
      );
      return SkillContractExecutionResult(
        status: ActionContractExecutionStatus.legacy,
        output: legacy.callerOutput,
      );
    }
    return _executeWithContractService(
      contract: contract,
      actionId: actionId,
      arguments: arguments,
      expectedDefinition: expectedDefinition,
      channel: channel,
      scope: scope,
      agentId: agentId,
      callId: callId,
      legacyCallback: legacyCallback,
      target: target,
    );
  }

  Future<SkillContractExecutionResult> _executeWithContractService({
    required ActionContractV2Service contract,
    required String actionId,
    required Map<String, dynamic> arguments,
    required ProductionActionDefinition? expectedDefinition,
    required ActionContractChannel channel,
    required AgentActionScope scope,
    required String agentId,
    required String callId,
    required ActionContractLegacyCallback legacyCallback,
    String? target,
  }) async {
    final invocation = contract.issueInvocation(
      agentId: agentId,
      callId: callId,
    );
    if (invocation == null) {
      return SkillContractExecutionResult(
        status: ActionContractExecutionStatus.rejected,
        output: ToolOutcome.failure(
          status: ToolOutcomeStatus.unavailable,
          code: 'contract_authority_unavailable',
        ).toJsonString(),
      );
    }
    final request = ActionContractEnvelopeRequest(
      invocation: invocation,
      scope: scope,
      channel: channel,
      actions: <ActionContractCall>[
        ActionContractCall(
          actionId: actionId,
          arguments: arguments,
          target: target,
          channel: channel,
          expectedDefinition: expectedDefinition,
        ),
      ],
    );
    final admission = await contract.prepare(request);
    final result = await contract.execute(
      admission: admission,
      currentRequest: request,
      legacyCallback: legacyCallback,
    );
    return SkillContractExecutionResult(
      status: result.status,
      output: result.outputForCaller,
    );
  }

  /// Validates a native tool invocation without executing its handler.
  ///
  /// Throws [StateError] when [toolName] is unknown or its registered handler
  /// is missing, and [InvalidToolArgumentsException] when the captured schema
  /// rejects [args].
  void validateToolArguments(String toolName, Map<String, dynamic> args) {
    _preflightToolArguments(toolName, args);
  }

  _ValidatedToolInvocation _preflightToolArguments(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final binding = _firstNativeBindingByToolName[toolName];
    if (binding == null) {
      throw StateError('Unknown tool: $toolName');
    }
    final skill = binding.skill;
    final method = binding.method;
    final handler = skill.methods[method];
    if (handler == null) {
      throw StateError(
        'Tool $toolName found, but skill "${skill.skillName}" has no '
        'method "$method" in its methods map',
      );
    }
    final validation = _schemaValidator.validate(
      schema: binding.schema,
      value: args,
    );
    if (!validation.isValid) {
      throw InvalidToolArgumentsException(
        toolName: toolName,
        validation: validation,
      );
    }
    return _ValidatedToolInvocation(handler, binding.contract);
  }

  bool get _hasPinnedActionContractDependency =>
      _injectedActionContract != null || _injectedProductionCatalog != null;

  bool get _pinnedActionContractDependenciesUnavailable =>
      _requirePinnedActionContract &&
          (_injectedActionContract == null ||
              _injectedProductionCatalog == null) ||
      _hasPinnedActionContractDependency &&
          (_injectedActionContract == null ||
              _injectedProductionCatalog == null);

  ActionContractV2Service? get _actionContract {
    if (_hasPinnedActionContractDependency) return _injectedActionContract;
    if (_requirePinnedActionContract ||
        !_useAppServicesActionContractFallback) {
      return null;
    }
    return appServices.maybeFind<ActionContractV2Service>();
  }

  ProductionActionDefinitionCatalog? get _productionCatalog {
    if (_hasPinnedActionContractDependency) {
      return _injectedProductionCatalog;
    }
    if (_requirePinnedActionContract ||
        !_useAppServicesActionContractFallback) {
      return null;
    }
    return appServices.maybeFind<ProductionActionDefinitionCatalog>();
  }

  _ContractMethodBinding _createContractBinding({
    required AgentSkill skill,
    required String method,
    required Map<String, dynamic> inputSchema,
    required bool hasNativeSchema,
  }) {
    final schemaSnapshot = _snapshotSchema(inputSchema);
    final metadata =
        _contractMetadataResolver?.call(skill, method, schemaSnapshot) ??
        SkillActionContractMetadata.unsupported;
    final outputSchema = _snapshotSchema(metadata.outputSchema);
    final toolName = nativeToolName(skill, method);
    final ownerKey = '${skill.skillName}\u0000$method';
    final ownerTarget =
        'skill:${Uri.encodeComponent(skill.skillName)}:'
        '${Uri.encodeComponent(method)}';
    final channels = <ActionContractChannel>{
      if (skill.skillName == 'AppControl')
        ActionContractChannel.appControl
      else if (skill.skillName == 'FreeformSurface')
        ActionContractChannel.surface
      else
        ActionContractChannel.structured,
    };
    if (hasNativeSchema &&
        skill.skillName != 'AppControl' &&
        skill.skillName != 'FreeformSurface') {
      channels
        ..add(ActionContractChannel.nativeTool)
        ..add(ActionContractChannel.delayedTool);
    }
    final candidate = ProductionActionDefinition(
      definition: ActionDefinition(
        id: toolName,
        inputSchema: schemaSnapshot,
        outputSchema: outputSchema,
        scopes: metadata.scopes,
        risk: metadata.risk,
        consequencePolicy: metadata.consequencePolicy,
        targetResolver: (_) => ownerTarget,
        handler: _metadataHandlerMustNotRun,
      ),
      channels: channels,
      enforcementEligibility: metadata.enforcementEligibility,
    );
    return _ContractMethodBinding(
      skill: skill,
      method: method,
      toolName: toolName,
      ownerKey: ownerKey,
      schemaSnapshot: schemaSnapshot,
      candidate: candidate,
    );
  }

  ProductionActionDefinition? _ensureProductionBinding(
    _ContractMethodBinding binding,
  ) {
    final bound = _bindDefinition(
      actionId: binding.toolName,
      ownerKey: binding.ownerKey,
      candidate: binding.candidate,
    );
    binding.boundDefinition = bound;
    return bound;
  }

  ProductionActionDefinition? _bindDefinition({
    required String actionId,
    required String ownerKey,
    required ProductionActionDefinition candidate,
  }) {
    final catalog = _productionCatalog;
    if (catalog?.isConflicted(actionId) ?? false) {
      _ambiguousContractActionIds.add(actionId);
      return null;
    }
    final previousOwner = _contractOwnerByActionId[actionId];
    if (previousOwner != null && previousOwner != ownerKey) {
      _ambiguousContractActionIds.add(actionId);
      catalog?.markConflict(actionId);
      return null;
    }
    _contractOwnerByActionId.putIfAbsent(actionId, () => ownerKey);
    if (catalog == null) return null;
    final existing = catalog.findExact(actionId);
    if (existing == null) {
      try {
        catalog.register(candidate);
        return candidate;
      } on Object {
        _ambiguousContractActionIds.add(actionId);
        catalog.markConflict(actionId);
        return null;
      }
    }
    if (!_sameProductionDefinition(existing, candidate)) {
      _ambiguousContractActionIds.add(actionId);
      catalog.markConflict(actionId);
      return null;
    }
    return existing;
  }

  ProductionActionDefinition? _exactProductionDefinition(
    _ContractMethodBinding binding,
  ) {
    final catalog = _productionCatalog;
    if (_ambiguousContractActionIds.contains(binding.toolName)) {
      catalog?.markConflict(binding.toolName);
      return null;
    }
    if (catalog?.isConflicted(binding.toolName) ?? false) {
      return null;
    }
    final currentSchema = _currentContractSchema(binding);
    if (currentSchema == null ||
        !_sameJson(currentSchema, binding.schemaSnapshot)) {
      return null;
    }
    final bound = binding.boundDefinition ?? _ensureProductionBinding(binding);
    if (bound == null ||
        !identical(catalog?.findExact(binding.toolName), bound)) {
      return null;
    }
    return bound;
  }

  Map<String, dynamic>? _currentContractSchema(_ContractMethodBinding binding) {
    try {
      final nativeSchemas =
          binding.skill.nativeToolSchemas ??
          const <String, Map<String, dynamic>>{};
      final structuredSchemas =
          binding.skill is StructuredActionPromptSchemaProvider
          ? (binding.skill as StructuredActionPromptSchemaProvider)
                .structuredActionPromptSchemas
          : StructuredActionPromptSchemas(nativeSchemas);
      final structured = structuredSchemas.schemaFor(binding.method);
      final native = nativeSchemas[binding.method];
      return _snapshotSchema(structured ?? native ?? _genericObjectSchema);
    } on Object {
      return null;
    }
  }

  bool _sameContractOwner(
    _ContractMethodBinding left,
    _ContractMethodBinding right,
  ) =>
      left.ownerKey == right.ownerKey &&
      _sameProductionDefinition(left.candidate, right.candidate);

  String _nextContractCallId(ActionContractChannel channel) {
    _nextGeneratedContractCallSerial += 1;
    return '${channel.name}-$_nextGeneratedContractCallSerial';
  }

  ActionContractChannel _effectiveContractChannel(
    _ContractMethodBinding binding,
    ActionContractChannel requested,
  ) => switch (binding.skill.skillName) {
    'AppControl' => ActionContractChannel.appControl,
    'FreeformSurface' => ActionContractChannel.surface,
    _ => requested,
  };

  /// Sanitize a (skill, method) pair into the OpenAI-allowed tool-name
  /// charset (`[a-zA-Z0-9_-]{1,64}`).  Lowercased so the model sees a
  /// consistent style.
  static String nativeToolName(AgentSkill skill, String method) {
    final raw = 'skill_${skill.skillName}_$method';
    final sanitized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return sanitized.length > 64 ? sanitized.substring(0, 64) : sanitized;
  }
}

class _SkillMethodBinding {
  const _SkillMethodBinding({
    required this.skill,
    required this.method,
    required this.toolName,
    required this.contract,
  });

  final AgentSkill skill;
  final String method;
  final String toolName;
  final _ContractMethodBinding contract;
}

class _NativeToolBinding {
  const _NativeToolBinding({
    required this.skill,
    required this.method,
    required this.toolName,
    required this.schema,
    required this.contract,
  });

  final AgentSkill skill;
  final String method;
  final String toolName;
  final Map<String, dynamic> schema;
  final _ContractMethodBinding contract;
}

class _ValidatedToolInvocation {
  const _ValidatedToolInvocation(this.handler, this.contract);

  final dynamic Function(List<dynamic>) handler;
  final _ContractMethodBinding contract;
}

final class _ContractMethodBinding {
  _ContractMethodBinding({
    required this.skill,
    required this.method,
    required this.toolName,
    required this.ownerKey,
    required this.schemaSnapshot,
    required this.candidate,
  });

  final AgentSkill skill;
  final String method;
  final String toolName;
  final String ownerKey;
  final Map<String, dynamic> schemaSnapshot;
  final ProductionActionDefinition candidate;
  ProductionActionDefinition? boundDefinition;
}

Map<String, dynamic> _snapshotSchema(Map<String, dynamic> schema) {
  final snapshot = snapshotActionJson(schema);
  if (snapshot is! Map<String, Object?>) {
    throw const ActionJsonSnapshotException('schema_not_object');
  }
  return Map<String, dynamic>.unmodifiable(snapshot);
}

bool _sameProductionDefinition(
  ProductionActionDefinition left,
  ProductionActionDefinition right,
) {
  final a = left.definition;
  final b = right.definition;
  if (a.id != b.id ||
      a.risk != b.risk ||
      a.consequencePolicy != b.consequencePolicy ||
      left.enforcementEligibility != right.enforcementEligibility ||
      !_sameSet(a.scopes, b.scopes) ||
      !_sameSet(left.channels, right.channels) ||
      !_sameJson(a.inputSchema, b.inputSchema) ||
      !_sameJson(a.outputSchema, b.outputSchema)) {
    return false;
  }
  try {
    return a.resolveTarget(const <String, dynamic>{}) ==
        b.resolveTarget(const <String, dynamic>{});
  } on Object {
    return false;
  }
}

bool _sameSet<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameJson(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_sameJson(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_sameJson(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

Object? _metadataHandlerMustNotRun(Map<String, dynamic> _) =>
    throw StateError('action_definition_handler_is_metadata_only');
