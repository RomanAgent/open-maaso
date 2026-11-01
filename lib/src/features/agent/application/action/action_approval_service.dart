import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The only terminal outcomes an action approval boundary may expose.
enum ActionApprovalOutcome {
  /// The exact request was approved for this invocation only.
  allowedOnce,

  /// The user explicitly rejected the exact request.
  rejected,

  /// The exact request was cancelled before execution.
  cancelled,

  /// No valid approval can be supplied. Callers must fail closed.
  unavailable,

  /// The exact request is waiting for an out-of-band user confirmation.
  confirmationRequired,
}

/// A decision supplied by the confirmation host for one pending request.
enum ActionApprovalDecision { allowOnce, reject, cancel }

/// Immutable inputs that make one approval distinct from every other action.
///
/// [callId] may identify either the enclosing turn or a native tool call.
/// [actionId] may identify a structured action or a native tool. Arguments are
/// canonicalized as JSON when the request enters [ActionApprovalService].
final class ActionApprovalRequest {
  const ActionApprovalRequest({
    required this.accountScope,
    required this.agentId,
    required this.runtimeGeneration,
    required this.callId,
    required this.actionId,
    required this.arguments,
    required this.target,
    required this.expiresAt,
  });

  final String accountScope;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
  final String actionId;
  final Object? arguments;
  final String target;
  final DateTime expiresAt;
}

/// Result returned by the in-memory approval boundary.
///
/// [fingerprint] is intentionally absent for [ActionApprovalOutcome.unavailable]
/// so an invalid request cannot probe whether a pending authority exists.
final class ActionApprovalResult {
  const ActionApprovalResult._(this.outcome, this.fingerprint);

  final ActionApprovalOutcome outcome;
  final String? fingerprint;

  bool get isAllowedOnce => outcome == ActionApprovalOutcome.allowedOnce;
}

/// Pure, isolate-local, one-shot approval authority for consequential actions.
///
/// The service never displays UI. A host first calls [requestConfirmation],
/// presents the returned fingerprint alongside the exact request, and then
/// calls [resolve] with the user's decision. Every resolve attempt consumes
/// the pending authority before checking its binding, so mismatches and replay
/// attempts fail closed instead of becoming reusable approval oracles.
final class ActionApprovalService {
  ActionApprovalService({
    this.maxArgumentDepth = 64,
    this.maxArgumentNodes = 4096,
    this.maxArgumentStringRunes = 16384,
  }) : assert(maxArgumentDepth > 0),
       assert(maxArgumentNodes > 0),
       assert(maxArgumentStringRunes > 0);

  final int maxArgumentDepth;
  final int maxArgumentNodes;
  final int maxArgumentStringRunes;
  final Map<String, _ApprovalRecord> _records = <String, _ApprovalRecord>{};

  /// Registers one exact request for confirmation.
  ///
  /// Repeating the same still-pending request returns the same fingerprint.
  /// A request that has already reached a terminal state cannot be re-issued
  /// until its fingerprint naturally changes (for example, on a new call ID).
  ActionApprovalResult requestConfirmation({
    required ActionApprovalRequest request,
    required DateTime now,
    bool confirmationAvailable = true,
  }) {
    _pruneExpired(now);
    if (!confirmationAvailable) return _unavailable;

    final binding = _tryBinding(
      request,
      maxArgumentDepth: maxArgumentDepth.clamp(1, 128),
      maxArgumentNodes: maxArgumentNodes.clamp(1, 65536),
      maxArgumentStringRunes: maxArgumentStringRunes.clamp(1, 65536),
    );
    if (binding == null || !now.isBefore(binding.expiresAt)) {
      return _unavailable;
    }

    final existing = _records[binding.fingerprint];
    if (existing != null) {
      if (existing.state != _ApprovalRecordState.pending ||
          existing.canonicalBinding != binding.canonicalBinding) {
        return _unavailable;
      }
      return ActionApprovalResult._(
        ActionApprovalOutcome.confirmationRequired,
        binding.fingerprint,
      );
    }

    _records[binding.fingerprint] = _ApprovalRecord(
      canonicalBinding: binding.canonicalBinding,
      expiresAt: binding.expiresAt,
    );
    return ActionApprovalResult._(
      ActionApprovalOutcome.confirmationRequired,
      binding.fingerprint,
    );
  }

  /// Resolves and consumes one pending approval.
  ///
  /// Consumption happens before expiry and exact-binding checks. Supplying a
  /// valid fingerprint with the wrong account, Agent, runtime generation,
  /// call, action, arguments or target therefore invalidates that authority.
  ActionApprovalResult resolve({
    required String fingerprint,
    required ActionApprovalRequest request,
    required ActionApprovalDecision decision,
    required DateTime now,
  }) {
    final normalizedFingerprint = _normalizeFingerprint(fingerprint);
    if (normalizedFingerprint == null) return _unavailable;

    final record = _records[normalizedFingerprint];
    if (record == null || record.state != _ApprovalRecordState.pending) {
      return _unavailable;
    }

    // Atomically make this authority terminal in the current isolate before
    // running any checks that could fail or throw. The exact canonical binding
    // is removed from the retained tombstone as soon as it is consumed.
    final expectedCanonicalBinding = record.consumeCanonicalBinding();
    if (expectedCanonicalBinding == null) return _unavailable;

    if (!now.isBefore(record.expiresAt)) return _unavailable;
    final binding = _tryBinding(
      request,
      maxArgumentDepth: maxArgumentDepth.clamp(1, 128),
      maxArgumentNodes: maxArgumentNodes.clamp(1, 65536),
      maxArgumentStringRunes: maxArgumentStringRunes.clamp(1, 65536),
    );
    if (binding == null ||
        binding.fingerprint != normalizedFingerprint ||
        binding.canonicalBinding != expectedCanonicalBinding) {
      return _unavailable;
    }

    final outcome = switch (decision) {
      ActionApprovalDecision.allowOnce => ActionApprovalOutcome.allowedOnce,
      ActionApprovalDecision.reject => ActionApprovalOutcome.rejected,
      ActionApprovalDecision.cancel => ActionApprovalOutcome.cancelled,
    };
    return ActionApprovalResult._(outcome, normalizedFingerprint);
  }

  static const ActionApprovalResult _unavailable = ActionApprovalResult._(
    ActionApprovalOutcome.unavailable,
    null,
  );

  void _pruneExpired(DateTime now) {
    _records.removeWhere((_, record) => !now.isBefore(record.expiresAt));
  }
}

enum _ApprovalRecordState { pending, consumed }

final class _ApprovalRecord {
  _ApprovalRecord({required String canonicalBinding, required this.expiresAt})
    : _canonicalBinding = canonicalBinding;

  String? _canonicalBinding;
  final DateTime expiresAt;
  _ApprovalRecordState state = _ApprovalRecordState.pending;

  String? get canonicalBinding => _canonicalBinding;

  String? consumeCanonicalBinding() {
    if (state != _ApprovalRecordState.pending) return null;
    state = _ApprovalRecordState.consumed;
    final binding = _canonicalBinding;
    _canonicalBinding = null;
    return binding;
  }
}

final class _ApprovalBinding {
  const _ApprovalBinding({
    required this.canonicalBinding,
    required this.fingerprint,
    required this.expiresAt,
  });

  final String canonicalBinding;
  final String fingerprint;
  final DateTime expiresAt;
}

_ApprovalBinding? _tryBinding(
  ActionApprovalRequest request, {
  required int maxArgumentDepth,
  required int maxArgumentNodes,
  required int maxArgumentStringRunes,
}) {
  try {
    final accountScope = _requiredText(
      request.accountScope,
      'accountScope',
      maxLength: 512,
    );
    final agentId = _requiredText(request.agentId, 'agentId', maxLength: 256);
    final callId = _requiredText(request.callId, 'callId', maxLength: 256);
    final actionId = _requiredText(
      request.actionId,
      'actionId',
      maxLength: 256,
    );
    final target = _requiredText(request.target, 'target', maxLength: 1024);
    if (request.runtimeGeneration < 0) return null;

    final canonicalArguments = _canonicalizeJson(
      request.arguments,
      depth: 0,
      maxDepth: maxArgumentDepth,
      maxStringRunes: maxArgumentStringRunes,
      budget: _CanonicalizationBudget(maxArgumentNodes),
      activeContainers: Set<Object>.identity(),
    );
    final expiresAt = request.expiresAt.toUtc();
    final canonicalBinding = jsonEncode(
      _canonicalizeJson(
        <String, Object?>{
          'accountScope': accountScope,
          'actionId': actionId,
          'agentId': agentId,
          'arguments': canonicalArguments,
          'callId': callId,
          'expiresAtMicros': expiresAt.microsecondsSinceEpoch,
          'runtimeGeneration': request.runtimeGeneration,
          'target': target,
        },
        depth: 0,
        maxDepth: maxArgumentDepth,
        maxStringRunes: maxArgumentStringRunes,
        budget: _CanonicalizationBudget(maxArgumentNodes + 16),
        activeContainers: Set<Object>.identity(),
      ),
    );
    return _ApprovalBinding(
      canonicalBinding: canonicalBinding,
      fingerprint: sha256.convert(utf8.encode(canonicalBinding)).toString(),
      expiresAt: expiresAt,
    );
  } on Object {
    // Canonicalization is a security boundary. Unsupported or malformed input
    // is deliberately indistinguishable from missing approval.
    return null;
  }
}

Object? _canonicalizeJson(
  Object? value, {
  required int depth,
  required int maxDepth,
  required int maxStringRunes,
  required _CanonicalizationBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > maxDepth || !budget.take()) {
    throw ArgumentError.value(value, 'value', 'exceeds canonical limits');
  }
  if (value == null || value is bool || value is int) {
    return value;
  }
  if (value is String) {
    if (value.runes.length > maxStringRunes) {
      throw ArgumentError.value(value, 'value', 'string is too long');
    }
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'must be finite');
    }
    return value;
  }
  if (value is List) {
    if (!activeContainers.add(value)) {
      throw ArgumentError.value(value, 'value', 'must not contain a cycle');
    }
    try {
      return <Object?>[
        for (final element in value)
          _canonicalizeJson(
            element,
            depth: depth + 1,
            maxDepth: maxDepth,
            maxStringRunes: maxStringRunes,
            budget: budget,
            activeContainers: activeContainers,
          ),
      ];
    } finally {
      activeContainers.remove(value);
    }
  }
  if (value is Map) {
    if (!activeContainers.add(value)) {
      throw ArgumentError.value(value, 'value', 'must not contain a cycle');
    }
    try {
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String || key.runes.length > maxStringRunes) {
          throw ArgumentError.value(key, 'key', 'must be a JSON string');
        }
        keys.add(key);
      }
      keys.sort();
      return <String, Object?>{
        for (final key in keys)
          key: _canonicalizeJson(
            value[key],
            depth: depth + 1,
            maxDepth: maxDepth,
            maxStringRunes: maxStringRunes,
            budget: budget,
            activeContainers: activeContainers,
          ),
      };
    } finally {
      activeContainers.remove(value);
    }
  }
  throw ArgumentError.value(value, 'value', 'is not supported JSON');
}

final class _CanonicalizationBudget {
  _CanonicalizationBudget(this.remaining);

  int remaining;

  bool take() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}

String _requiredText(String value, String name, {required int maxLength}) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw ArgumentError.value(
      value,
      name,
      'must contain 1-$maxLength characters',
    );
  }
  return normalized;
}

String? _normalizeFingerprint(String value) {
  if (value.length != 64 || value.toLowerCase() != value) return null;
  for (final codeUnit in value.codeUnits) {
    final isDigit = codeUnit >= 48 && codeUnit <= 57;
    final isLowerHex = codeUnit >= 97 && codeUnit <= 102;
    if (!isDigit && !isLowerHex) return null;
  }
  return value;
}
