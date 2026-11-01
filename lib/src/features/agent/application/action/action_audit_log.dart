import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'action_definition.dart';

/// Stable lifecycle stages emitted around one agent-invocable action.
enum ActionAuditStage { asked, decided, executed, result }

/// Bounded outcome vocabulary for action lifecycle audit entries.
///
/// Detailed diagnostics must stay in host logs. Audit entries use [code] for a
/// short stable reason that is safe to aggregate and expose to tooling.
enum ActionAuditOutcome {
  proposed,
  confirmationRequired,
  allowed,
  rejected,
  cancelled,
  denied,
  started,
  succeeded,
  failed,
  unavailable,
}

/// A safe validation failure from the audit boundary.
///
/// The exception intentionally carries only a stable code. It never retains or
/// renders the rejected field value because that value may contain credentials
/// or user-authored content.
final class ActionAuditValidationException implements Exception {
  const ActionAuditValidationException(this.code);

  final String code;

  @override
  String toString() => 'ActionAuditValidationException($code)';
}

/// Immutable, content-safe record retained by [ActionAuditLog].
///
/// Raw arguments and display text are deliberately absent. [argumentsDigest]
/// is a process-private keyed digest of bounded, canonical JSON arguments.
final class ActionAuditEntry {
  const ActionAuditEntry._({
    required this.sequence,
    required this.auditId,
    required this.stage,
    required this.accountScope,
    required this.agentId,
    required this.runtimeGeneration,
    required this.callId,
    required this.actionId,
    required this.argumentsDigest,
    required this.target,
    required this.risk,
    required this.consequencePolicy,
    required this.outcome,
    required this.code,
    required this.occurredAt,
  });

  final int sequence;
  final String auditId;
  final ActionAuditStage stage;
  final String accountScope;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
  final String actionId;
  final String argumentsDigest;
  final String target;
  final ActionRisk risk;
  final ActionConsequencePolicy consequencePolicy;
  final ActionAuditOutcome outcome;
  final String code;
  final DateTime occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'sequence': sequence,
    'auditId': auditId,
    'stage': stage.name,
    'accountScope': accountScope,
    'agentId': agentId,
    'runtimeGeneration': runtimeGeneration,
    'callId': callId,
    'actionId': actionId,
    'argumentsDigest': argumentsDigest,
    'target': target,
    'risk': risk.name,
    'consequencePolicy': consequencePolicy.name,
    'outcome': outcome.name,
    'code': code,
    'occurredAt': occurredAt.toIso8601String(),
  };
}

/// Mandatory account/Agent/runtime fence for audit queries.
///
/// Requiring all three scope components prevents accidental cross-account or
/// stale-generation reads. Optional fields narrow the result further.
final class ActionAuditScope {
  const ActionAuditScope({
    required this.accountScope,
    required this.agentId,
    required this.runtimeGeneration,
    this.callId,
    this.actionId,
    this.auditId,
  });

  final String accountScope;
  final String agentId;
  final int runtimeGeneration;
  final String? callId;
  final String? actionId;
  final String? auditId;
}

/// Isolate-local, append-only audit window for agent actions.
///
/// The retained window is capacity bounded: successful appends evict only the
/// oldest entry once [capacity] is reached. There are no mutation or deletion
/// APIs, and every scoped query result is immutable. Validation and digesting
/// complete before the window is changed, so malformed or oversized input
/// fails closed without evicting a valid record.
final class ActionAuditLog {
  ActionAuditLog({this.capacity = defaultCapacity})
    : _digestKey = _newAuditDigestKey() {
    if (capacity < 1 || capacity > maxCapacity) {
      throw const ActionAuditValidationException('invalid_capacity');
    }
  }

  static const int defaultCapacity = 512;
  static const int maxCapacity = 16384;
  static const int _maxQueryLimit = 4096;
  static const int _maxArgumentDepth = 32;
  static const int _maxArgumentNodes = 4096;
  static const int _maxContainerEntries = 1024;
  static const int _maxArgumentCharacters = 65536;
  static const int _maxCanonicalArgumentBytes = 65536;

  final int capacity;
  final List<int> _digestKey;
  final ListQueue<ActionAuditEntry> _entries = ListQueue<ActionAuditEntry>();
  int _nextSequence = 0;
  int _evictedCount = 0;

  int get length => _entries.length;
  int get evictedCount => _evictedCount;

  /// Appends one content-safe action lifecycle entry.
  ///
  /// [arguments] is canonicalized and digested while this method runs, then
  /// discarded. It is never retained by the log or included in validation
  /// errors. [code] accepts only a short stable identifier, not display text.
  ActionAuditEntry append({
    required ActionAuditStage stage,
    required String accountScope,
    required String agentId,
    required int runtimeGeneration,
    required String callId,
    required String actionId,
    required Object? arguments,
    required String target,
    required ActionRisk risk,
    required ActionConsequencePolicy consequencePolicy,
    required ActionAuditOutcome outcome,
    required String code,
    required DateTime occurredAt,
  }) {
    final normalizedAccountScope = _stableIdentifier(
      accountScope,
      field: 'account_scope',
      maxLength: 512,
    );
    final normalizedAgentId = _stableIdentifier(
      agentId,
      field: 'agent_id',
      maxLength: 256,
    );
    if (runtimeGeneration < 0) {
      throw const ActionAuditValidationException('invalid_runtime_generation');
    }
    final normalizedCallId = _stableIdentifier(
      callId,
      field: 'call_id',
      maxLength: 256,
    );
    final normalizedActionId = _stableIdentifier(
      actionId,
      field: 'action_id',
      maxLength: 256,
    );
    final normalizedTarget = _stableIdentifier(
      target,
      field: 'target',
      maxLength: 1024,
    );
    final normalizedCode = _stableCode(code);
    final normalizedTimestamp = _boundedTimestamp(occurredAt);
    final argumentsDigest = _digestArguments(arguments, _digestKey);
    final targetDigest = _keyedDigest(
      key: _digestKey,
      domain: 'maaso.action-audit.target.v1',
      payload: utf8.encode(normalizedTarget),
    );

    final auditId = _auditIdFor(<String, Object?>{
      'accountScope': normalizedAccountScope,
      'actionId': normalizedActionId,
      'agentId': normalizedAgentId,
      'argumentsDigest': argumentsDigest,
      'callId': normalizedCallId,
      'consequencePolicy': consequencePolicy.name,
      'risk': risk.name,
      'runtimeGeneration': runtimeGeneration,
      'target': targetDigest,
    }, _digestKey);

    final entry = ActionAuditEntry._(
      sequence: _nextSequence,
      auditId: auditId,
      stage: stage,
      accountScope: normalizedAccountScope,
      agentId: normalizedAgentId,
      runtimeGeneration: runtimeGeneration,
      callId: normalizedCallId,
      actionId: normalizedActionId,
      argumentsDigest: argumentsDigest,
      target: targetDigest,
      risk: risk,
      consequencePolicy: consequencePolicy,
      outcome: outcome,
      code: normalizedCode,
      occurredAt: normalizedTimestamp,
    );

    if (_entries.length == capacity) {
      _entries.removeFirst();
      _evictedCount += 1;
    }
    _entries.addLast(entry);
    _nextSequence += 1;
    return entry;
  }

  /// Returns the latest matching entries in chronological order.
  ///
  /// Every query is fenced by account, Agent, and runtime generation. [limit]
  /// bounds both work and the returned allocation.
  List<ActionAuditEntry> query({
    required ActionAuditScope scope,
    int limit = 100,
  }) {
    final accountScope = _stableIdentifier(
      scope.accountScope,
      field: 'account_scope',
      maxLength: 512,
    );
    final agentId = _stableIdentifier(
      scope.agentId,
      field: 'agent_id',
      maxLength: 256,
    );
    if (scope.runtimeGeneration < 0) {
      throw const ActionAuditValidationException('invalid_runtime_generation');
    }
    final callId = scope.callId == null
        ? null
        : _stableIdentifier(scope.callId!, field: 'call_id', maxLength: 256);
    final actionId = scope.actionId == null
        ? null
        : _stableIdentifier(
            scope.actionId!,
            field: 'action_id',
            maxLength: 256,
          );
    final auditId = scope.auditId == null
        ? null
        : _validatedAuditId(scope.auditId!);
    if (limit < 1 || limit > _maxQueryLimit) {
      throw const ActionAuditValidationException('invalid_query_limit');
    }

    final matches = <ActionAuditEntry>[];
    for (final entry in _entries.toList(growable: false).reversed) {
      if (entry.accountScope != accountScope ||
          entry.agentId != agentId ||
          entry.runtimeGeneration != scope.runtimeGeneration ||
          (callId != null && entry.callId != callId) ||
          (actionId != null && entry.actionId != actionId) ||
          (auditId != null && entry.auditId != auditId)) {
        continue;
      }
      matches.add(entry);
      if (matches.length == limit) break;
    }
    return List<ActionAuditEntry>.unmodifiable(matches.reversed);
  }
}

String _digestArguments(Object? arguments, List<int> digestKey) {
  try {
    final budget = _CanonicalBudget(
      nodesRemaining: ActionAuditLog._maxArgumentNodes,
      charactersRemaining: ActionAuditLog._maxArgumentCharacters,
    );
    final canonical = _canonicalizeJson(
      arguments,
      depth: 0,
      budget: budget,
      activeContainers: Set<Object>.identity(),
    );
    final encoded = utf8.encode(jsonEncode(canonical));
    if (encoded.length > ActionAuditLog._maxCanonicalArgumentBytes) {
      throw const ActionAuditValidationException('arguments_too_large');
    }
    return _keyedDigest(
      key: digestKey,
      domain: 'maaso.action-audit.arguments.v1',
      payload: encoded,
    );
  } on ActionAuditValidationException {
    rethrow;
  } on Object {
    // Custom or concurrently-mutated collection implementations must not leak
    // their exception messages across this content-safety boundary.
    throw const ActionAuditValidationException('arguments_invalid');
  }
}

Object? _canonicalizeJson(
  Object? value, {
  required int depth,
  required _CanonicalBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > ActionAuditLog._maxArgumentDepth) {
    throw const ActionAuditValidationException('arguments_too_deep');
  }
  budget.consumeNode();

  if (value == null || value is bool) return value;
  if (value is String) {
    budget.consumeCharacters(value.length);
    return value;
  }
  if (value is int) {
    if (value.bitLength > 425) {
      throw const ActionAuditValidationException('arguments_number_too_large');
    }
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const ActionAuditValidationException('arguments_non_finite');
    }
    return value;
  }
  if (value is List) {
    if (value.length > ActionAuditLog._maxContainerEntries) {
      throw const ActionAuditValidationException('arguments_too_many_entries');
    }
    if (!activeContainers.add(value)) {
      throw const ActionAuditValidationException('arguments_cycle');
    }
    try {
      return <Object?>[
        for (final element in value)
          _canonicalizeJson(
            element,
            depth: depth + 1,
            budget: budget,
            activeContainers: activeContainers,
          ),
      ];
    } finally {
      activeContainers.remove(value);
    }
  }
  if (value is Map) {
    if (value.length > ActionAuditLog._maxContainerEntries) {
      throw const ActionAuditValidationException('arguments_too_many_entries');
    }
    if (!activeContainers.add(value)) {
      throw const ActionAuditValidationException('arguments_cycle');
    }
    try {
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String) {
          throw const ActionAuditValidationException(
            'arguments_non_string_key',
          );
        }
        budget.consumeCharacters(key.length);
        keys.add(key);
      }
      keys.sort();
      return <String, Object?>{
        for (final key in keys)
          key: _canonicalizeJson(
            value[key],
            depth: depth + 1,
            budget: budget,
            activeContainers: activeContainers,
          ),
      };
    } finally {
      activeContainers.remove(value);
    }
  }
  throw const ActionAuditValidationException('arguments_unsupported_type');
}

final class _CanonicalBudget {
  _CanonicalBudget({
    required this.nodesRemaining,
    required this.charactersRemaining,
  });

  int nodesRemaining;
  int charactersRemaining;

  void consumeNode() {
    nodesRemaining -= 1;
    if (nodesRemaining < 0) {
      throw const ActionAuditValidationException('arguments_too_many_nodes');
    }
  }

  void consumeCharacters(int count) {
    charactersRemaining -= count;
    if (charactersRemaining < 0) {
      throw const ActionAuditValidationException('arguments_too_large');
    }
  }
}

String _auditIdFor(Map<String, Object?> binding, List<int> digestKey) {
  final digest = _keyedDigest(
    key: digestKey,
    domain: 'maaso.action-audit.id.v1',
    payload: utf8.encode(jsonEncode(binding)),
  );
  return 'audit:$digest';
}

String _keyedDigest({
  required List<int> key,
  required String domain,
  required List<int> payload,
}) {
  final digest = Hmac(
    sha256,
    key,
  ).convert(<int>[...utf8.encode(domain), 0, ...payload]);
  return digest.toString();
}

List<int> _newAuditDigestKey() {
  try {
    final random = Random.secure();
    return List<int>.unmodifiable(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    );
  } catch (_) {
    throw const ActionAuditValidationException('digest_key_unavailable');
  }
}

String _stableIdentifier(
  String raw, {
  required String field,
  required int maxLength,
}) {
  final value = raw.trim();
  if (value.isEmpty ||
      value.runes.length > maxLength ||
      _controlCharacterPattern.hasMatch(value)) {
    throw ActionAuditValidationException('invalid_$field');
  }
  return value;
}

String _stableCode(String raw) {
  final code = raw.trim().toLowerCase();
  if (code.isEmpty ||
      code.length > 64 ||
      !RegExp(r'^[a-z0-9._-]+$').hasMatch(code)) {
    throw const ActionAuditValidationException('invalid_code');
  }
  return code;
}

DateTime _boundedTimestamp(DateTime value) {
  final timestamp = value.toUtc();
  if (timestamp.year < 1970 || timestamp.year > 9999) {
    throw const ActionAuditValidationException('invalid_timestamp');
  }
  return timestamp;
}

String _validatedAuditId(String raw) {
  final value = raw.trim();
  if (!RegExp(r'^audit:[0-9a-f]{64}$').hasMatch(value)) {
    throw const ActionAuditValidationException('invalid_audit_id');
  }
  return value;
}

final RegExp _controlCharacterPattern = RegExp(
  '[\\u0000-\\u001f\\u007f-\\u009f]',
);
