import 'dart:convert';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';

import '../action/action_approval_host.dart';
import '../action/action_definition.dart';
import 'agent_ui_control_state.dart';
import 'page_agent_adapter_registry.dart';

/// Declarative, side-effect-free recipe for approval display content.
///
/// [exactTextArgumentKey] may only select one value from the already-frozen,
/// schema-validated argument map. It is data, not an executable resolver, so
/// obtaining approval presentation cannot trigger page or network work.
final class AppControlApprovalArgumentSpec {
  const AppControlApprovalArgumentSpec({
    required this.argumentKey,
    required this.label,
    this.maxDisplayRunes = 4096,
  }) : assert(maxDisplayRunes >= 1 && maxDisplayRunes <= 32768);

  final String argumentKey;
  final String label;
  final int maxDisplayRunes;
}

final class AppControlApprovalPresentationSpec {
  AppControlApprovalPresentationSpec({
    required this.title,
    required this.description,
    required this.targetLabel,
    required this.consequenceLabel,
    this.exactTextArgumentKey,
    Iterable<AppControlApprovalArgumentSpec> argumentFields =
        const <AppControlApprovalArgumentSpec>[],
  }) : argumentFields = List<AppControlApprovalArgumentSpec>.unmodifiable(
         argumentFields,
       );

  final String title;
  final String description;
  final String targetLabel;
  final String consequenceLabel;
  final String? exactTextArgumentKey;
  final List<AppControlApprovalArgumentSpec> argumentFields;

  ActionApprovalPresentation? resolve({
    required Map<String, Object?> arguments,
    required ActionConsequencePolicy consequencePolicy,
  }) {
    final normalizedTitle = _singleLineDisplay(title, maxRunes: 160);
    final normalizedDescription = _multilineDisplay(
      description,
      maxRunes: 1024,
    );
    final normalizedTarget = _singleLineDisplay(targetLabel, maxRunes: 256);
    final normalizedConsequence = _multilineDisplay(
      consequenceLabel,
      maxRunes: 512,
    );
    if (normalizedTitle == null ||
        normalizedDescription == null ||
        normalizedTarget == null ||
        normalizedConsequence == null) {
      return null;
    }

    String? exactText;
    final displayedArgumentKeys = <String>{};
    final key = exactTextArgumentKey?.trim();
    if (key != null && key.isNotEmpty) {
      final value = arguments[key];
      if (value is! String || !_isBoundedExactText(value)) return null;
      exactText = value;
      displayedArgumentKeys.add(key);
    }
    if (consequencePolicy == ActionConsequencePolicy.exactTextCommit &&
        exactText == null) {
      return null;
    }
    final resolvedFields = <ActionApprovalPresentationField>[];
    for (final field in argumentFields) {
      final argumentKey = field.argumentKey.trim();
      final label = _singleLineDisplay(field.label, maxRunes: 128);
      if (argumentKey.isEmpty ||
          !displayedArgumentKeys.add(argumentKey) ||
          label == null ||
          field.maxDisplayRunes < 1 ||
          field.maxDisplayRunes > 32768 ||
          !arguments.containsKey(argumentKey)) {
        return null;
      }
      final displayValue = _approvalArgumentDisplay(
        arguments[argumentKey],
        maxRunes: field.maxDisplayRunes,
      );
      if (displayValue == null) return null;
      resolvedFields.add(
        ActionApprovalPresentationField(label: label, value: displayValue),
      );
    }
    // Approval must be informed about every argument capable of changing the
    // consequence. Consequential actions fail closed when an adapter adds an
    // argument without declaring how it is displayed.
    if (displayedArgumentKeys.length != arguments.length ||
        !displayedArgumentKeys.containsAll(arguments.keys)) {
      return null;
    }
    return ActionApprovalPresentation(
      title: normalizedTitle,
      description: normalizedDescription,
      targetLabel: normalizedTarget,
      consequenceLabel: normalizedConsequence,
      exactText: exactText,
      argumentFields: List<ActionApprovalPresentationField>.unmodifiable(
        resolvedFields,
      ),
    );
  }
}

/// One bounded operation declared by a mounted page.
///
/// The contract is final so adapters cannot override approval classification
/// or target resolution to bypass the Host gate.
final class AppControlPageAction {
  AppControlPageAction({
    required this.id,
    required this.description,
    required Map<String, Object?> argumentsSchema,
    required Map<String, Object?> resultSchema,
    required this.risk,
    required this.consequencePolicy,
    this.approvalTarget,
    this.approvalPresentation,
    Iterable<AppCapabilityKey> requiredCapabilities =
        const <AppCapabilityKey>[],
  }) : argumentsSchema = _snapshotSchema(argumentsSchema),
       resultSchema = _snapshotSchema(resultSchema),
       requiredCapabilities = Set<AppCapabilityKey>.unmodifiable(
         requiredCapabilities,
       );

  final String id;
  final String description;
  final Map<String, Object?> argumentsSchema;
  final Map<String, Object?> resultSchema;
  final ActionRisk risk;
  final ActionConsequencePolicy consequencePolicy;
  final String? approvalTarget;
  final AppControlApprovalPresentationSpec? approvalPresentation;
  final Set<AppCapabilityKey> requiredCapabilities;

  bool get requiresApproval =>
      risk.requiresApproval || consequencePolicy.requiresApproval;

  /// Returns the declared opaque approval target, never display content.
  String? get normalizedApprovalTarget => _stableOpaqueTarget(approvalTarget);

  ActionApprovalPresentation? resolveApprovalPresentation(
    Map<String, Object?> arguments,
  ) => approvalPresentation?.resolve(
    arguments: arguments,
    consequencePolicy: consequencePolicy,
  );
}

/// Immutable command data handed to trusted app-owned consequential executors.
///
/// Mounted page adapters never receive or execute this command. AppControl
/// derives it only from the frozen, schema-validated arguments and the exact
/// approved route/action/target tuple.
final class AppControlHostCommand {
  const AppControlHostCommand.host({
    required this.actionId,
    required this.pageActionId,
    required this.targetRoute,
    required this.target,
    required this.arguments,
  });

  final String actionId;
  final String pageActionId;
  final String targetRoute;
  final String target;
  final Map<String, Object?> arguments;
}

/// Trusted application boundary for consequential AppControl commands.
///
/// Implementations are registered by the app Host, never by a mounted page.
/// [supports] must be pure. [execute] may prepare with [guardedAwait], must call
/// [AppControlActionExecutionContext.beginHostCommit] exactly once immediately
/// before the irreversible operation, and must await the real operation result.
abstract interface class AppControlHostCommandExecutor {
  bool supports(AppControlHostCommand command);

  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AppControlHostCommand command,
    required AppControlActionExecutionContext executionContext,
  });
}

/// Stable failure raised by the Host-owned action execution fence.
final class AppControlActionExecutionException implements Exception {
  const AppControlActionExecutionException(this.code);

  final String code;

  @override
  String toString() => 'AppControlActionExecutionException($code)';
}

/// One-shot linearization fence for a page-declared operation.
///
/// Preparation may use [guardedAwait]. Only a trusted
/// [AppControlHostCommandExecutor] receives a commit-capable instance. Mounted
/// page adapters receive a non-commit instance for ordinary actions, so they
/// cannot perform an approved write or smuggle an unawaited async closure across
/// the linearization point.
final class AppControlActionExecutionContext {
  AppControlActionExecutionContext.host({
    required bool requiresCommit,
    required bool Function() authorityIsCurrent,
    required String staleCode,
    bool Function()? recordExecutionStarted,
  }) : _requiresCommit = requiresCommit,
       _authorityIsCurrent = authorityIsCurrent,
       _staleCode = staleCode,
       _recordExecutionStarted = recordExecutionStarted;

  final bool _requiresCommit;
  final bool Function() _authorityIsCurrent;
  final String _staleCode;
  final bool Function()? _recordExecutionStarted;
  bool _commitStarted = false;

  bool get commitStarted => _commitStarted;

  void checkpoint() {
    bool current;
    try {
      current = _authorityIsCurrent();
    } catch (_) {
      current = false;
    }
    if (!current) {
      throw AppControlActionExecutionException(_staleCode);
    }
  }

  Future<T> guardedAwait<T>(Future<T> operation) async {
    checkpoint();
    final value = await operation;
    checkpoint();
    return value;
  }

  /// Rechecks authority before the Host is allowed to create an operation.
  ///
  /// This avoids starting a Future that could become unobserved when the
  /// pre-await checkpoint fails.
  Future<T> guardedCall<T>(Future<T> Function() operation) async {
    checkpoint();
    final value = await operation();
    checkpoint();
    return value;
  }

  void beginHostCommit() {
    if (!_requiresCommit || _commitStarted) {
      throw const AppControlActionExecutionException('execution_fence_invalid');
    }
    checkpoint();
    bool recorded;
    try {
      recorded = _recordExecutionStarted?.call() == true;
    } catch (_) {
      recorded = false;
    }
    if (!recorded) {
      throw const AppControlActionExecutionException('audit_unavailable');
    }
    checkpoint();
    _commitStarted = true;
  }
}

String? _stableOpaqueTarget(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.runes.length > 512 ||
      RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _singleLineDisplay(String value, {required int maxRunes}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.runes.length > maxRunes ||
      RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

String? _multilineDisplay(String value, {required int maxRunes}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.runes.length > maxRunes ||
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(normalized)) {
    return null;
  }
  return normalized;
}

bool _isBoundedExactText(String value) =>
    value.isNotEmpty &&
    value.runes.length <= 16384 &&
    !RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(value);

String? _approvalArgumentDisplay(Object? value, {required int maxRunes}) {
  try {
    final display = value is String ? value : jsonEncode(value);
    return _multilineDisplay(display, maxRunes: maxRunes);
  } catch (_) {
    return null;
  }
}

const int _maxSchemaSnapshotDepth = 64;
const int _maxSchemaSnapshotNodes = 4096;
const _InvalidSchemaSnapshot _invalidSchemaSnapshot = _InvalidSchemaSnapshot();

final class _InvalidSchemaSnapshot {
  const _InvalidSchemaSnapshot();
}

final class _SchemaSnapshotBudget {
  _SchemaSnapshotBudget(this.remaining);

  int remaining;

  bool take() {
    if (remaining <= 0) return false;
    remaining -= 1;
    return true;
  }
}

Map<String, Object?> _snapshotSchema(Map<String, Object?> schema) {
  final budget = _SchemaSnapshotBudget(_maxSchemaSnapshotNodes);
  final snapshot = _snapshotSchemaValue(
    schema,
    depth: 0,
    budget: budget,
    activeContainers: Set<Object>.identity(),
  );
  if (snapshot is Map<String, Object?>) return snapshot;
  return const <String, Object?>{
    'maaso.invalid_schema_snapshot': _invalidSchemaSnapshot,
  };
}

Object? _snapshotSchemaValue(
  Object? value, {
  required int depth,
  required _SchemaSnapshotBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > _maxSchemaSnapshotDepth || !budget.take()) {
    return _invalidSchemaSnapshot;
  }
  if (value is Map) {
    if (!activeContainers.add(value)) return _invalidSchemaSnapshot;
    final snapshot = <Object?, Object?>{};
    try {
      for (final entry in value.entries) {
        snapshot[entry.key] = _snapshotSchemaValue(
          entry.value,
          depth: depth + 1,
          budget: budget,
          activeContainers: activeContainers,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    if (snapshot.keys.every((key) => key is String)) {
      return Map<String, Object?>.unmodifiable(
        snapshot.cast<String, Object?>(),
      );
    }
    return Map<Object?, Object?>.unmodifiable(snapshot);
  }
  if (value is List) {
    if (!activeContainers.add(value)) return _invalidSchemaSnapshot;
    try {
      return List<Object?>.unmodifiable(
        value.map(
          (item) => _snapshotSchemaValue(
            item,
            depth: depth + 1,
            budget: budget,
            activeContainers: activeContainers,
          ),
        ),
      );
    } finally {
      activeContainers.remove(value);
    }
  }
  return value;
}

/// Page-owned extension seam for the generic AppControl Host Skill.
///
/// Implementations expose semantic actions only. Coordinates, widget keys,
/// reflection and undeclared callbacks are intentionally outside the contract.
abstract interface class AppControlPageAdapter implements PageAgentAdapter {
  List<AppControlPageAction> get appControlActions;

  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  });
}

extension AppControlPageAdapterActions on AppControlPageAdapter {
  AppControlPageAction? actionById(String rawId) {
    final id = rawId.trim();
    for (final action in appControlActions) {
      if (action.id == id) return action;
    }
    return null;
  }
}
