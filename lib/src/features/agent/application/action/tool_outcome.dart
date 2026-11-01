import 'dart:convert';

enum ToolOutcomeStatus {
  ok,
  invalidArguments,
  confirmationRequired,
  denied,
  unavailable,
  cancelled,
  failed;

  String get wireName => switch (this) {
    ToolOutcomeStatus.ok => 'ok',
    ToolOutcomeStatus.invalidArguments => 'invalid_arguments',
    ToolOutcomeStatus.confirmationRequired => 'confirmation_required',
    ToolOutcomeStatus.denied => 'denied',
    ToolOutcomeStatus.unavailable => 'unavailable',
    ToolOutcomeStatus.cancelled => 'cancelled',
    ToolOutcomeStatus.failed => 'failed',
  };
}

/// Stable, machine-readable result shared by model tool channels.
///
/// Internal exception strings never belong in this object. [code] is a bounded
/// identifier suitable for prompt observations, metrics, and tests; detailed
/// diagnostics stay in host logs and are correlated through [auditId].
class ToolOutcome {
  const ToolOutcome({
    required this.status,
    required this.code,
    this.data,
    this.display,
    this.retryable = false,
    this.auditId,
  });

  factory ToolOutcome.ok({
    Object? data,
    String code = 'ok',
    String? display,
    String? auditId,
  }) => ToolOutcome(
    status: ToolOutcomeStatus.ok,
    code: _safeCode(code, fallback: 'ok'),
    data: data,
    display: _boundedDisplay(display),
    auditId: _boundedAuditId(auditId),
  );

  factory ToolOutcome.failure({
    required ToolOutcomeStatus status,
    required String code,
    Object? data,
    String? display,
    bool retryable = false,
    String? auditId,
  }) {
    if (status == ToolOutcomeStatus.ok) {
      throw ArgumentError.value(status, 'status', 'must be a failure status');
    }
    return ToolOutcome(
      status: status,
      code: _safeCode(code, fallback: 'failed'),
      data: data,
      display: _boundedDisplay(display),
      retryable: retryable,
      auditId: _boundedAuditId(auditId),
    );
  }

  /// Compatibility adapter for handlers that still return arbitrary strings.
  factory ToolOutcome.fromLegacyResult(Object? result) {
    if (result == null) return ToolOutcome.ok(data: const <String, Object?>{});
    if (result is! String) return ToolOutcome.ok(data: result);

    final raw = result.trim();
    if (raw.isEmpty) return ToolOutcome.ok(data: const <String, Object?>{});
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return ToolOutcome.ok(data: <String, Object?>{'value': raw});
    }

    if (decoded is Map) {
      final map = Map<String, Object?>.fromEntries(
        decoded.entries.map(
          (entry) => MapEntry(entry.key.toString(), entry.value),
        ),
      );
      final error = map['error']?.toString().trim();
      if (error != null && error.isNotEmpty) {
        return ToolOutcome.failure(
          status: ToolOutcomeStatus.failed,
          code: _safeCode(error, fallback: 'legacy_error'),
          data: map,
        );
      }
      final status = map['status']?.toString().trim();
      if (status == 'confirmation_required' || status == 'commit_required') {
        return ToolOutcome.failure(
          status: ToolOutcomeStatus.confirmationRequired,
          code: status!,
          data: map,
        );
      }
      return ToolOutcome.ok(data: map);
    }
    return ToolOutcome.ok(data: decoded);
  }

  final ToolOutcomeStatus status;
  final String code;
  final Object? data;
  final String? display;
  final bool retryable;
  final String? auditId;

  bool get isOk => status == ToolOutcomeStatus.ok;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.wireName,
    'code': code,
    if (data != null) 'data': data,
    if (display != null) 'display': display,
    'retryable': retryable,
    if (auditId != null) 'auditId': auditId,
  };

  String toJsonString() => const ToolOutcomeModelRenderer().render(this);

  static String _safeCode(String raw, {required String fallback}) {
    final code = raw.trim().toLowerCase();
    return code.isNotEmpty &&
            code.length <= 64 &&
            RegExp(r'^[a-z0-9._-]+$').hasMatch(code)
        ? code
        : fallback;
  }

  static String? _boundedDisplay(String? raw) {
    final display = raw?.trim();
    if (display == null || display.isEmpty) return null;
    return display.length <= 240 ? display : display.substring(0, 240);
  }

  static String? _boundedAuditId(String? raw) {
    final auditId = raw?.trim();
    if (auditId == null || auditId.isEmpty) return null;
    if (auditId.length > 128 ||
        !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(auditId)) {
      throw ArgumentError.value(raw, 'auditId', 'invalid audit identifier');
    }
    return auditId;
  }
}

/// Bounded serializer for returning tool outcomes to a model.
///
/// Invalid, cyclic, non-finite, excessively deep, or oversized handler data
/// is replaced by one fixed failure. This prevents internal serialization
/// details and arbitrary host objects from becoming model observations.
final class ToolOutcomeModelRenderer {
  const ToolOutcomeModelRenderer({
    this.maxDepth = 32,
    this.maxNodes = 4096,
    this.maxStringRunes = 16384,
    this.maxEncodedBytes = 65536,
  }) : assert(maxDepth > 0),
       assert(maxNodes > 0),
       assert(maxStringRunes > 0),
       assert(maxEncodedBytes > 0);

  final int maxDepth;
  final int maxNodes;
  final int maxStringRunes;
  final int maxEncodedBytes;

  String render(ToolOutcome outcome) {
    try {
      final budget = _OutcomeRenderBudget(maxNodes.clamp(1, 65536));
      _validateModelJson(
        outcome.toJson(),
        depth: 0,
        maxDepth: maxDepth.clamp(1, 128),
        maxStringRunes: maxStringRunes.clamp(1, 65536),
        budget: budget,
        activeContainers: Set<Object>.identity(),
      );
      final encoded = jsonEncode(outcome.toJson());
      if (utf8.encode(encoded).length > maxEncodedBytes.clamp(128, 1048576)) {
        return _invalidOutcomeJson;
      }
      return encoded;
    } on Object {
      return _invalidOutcomeJson;
    }
  }

  static const String _invalidOutcomeJson =
      '{"status":"failed","code":"invalid_tool_outcome",'
      '"retryable":false}';
}

void _validateModelJson(
  Object? value, {
  required int depth,
  required int maxDepth,
  required int maxStringRunes,
  required _OutcomeRenderBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > maxDepth || !budget.take()) {
    throw const FormatException('tool outcome exceeds render limits');
  }
  if (value == null || value is bool) return;
  if (value is String) {
    if (value.runes.length > maxStringRunes) {
      throw const FormatException('tool outcome string exceeds render limit');
    }
    return;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw const FormatException('tool outcome contains non-finite number');
    }
    return;
  }
  if (value is List) {
    if (!activeContainers.add(value)) {
      throw const FormatException('tool outcome contains a cycle');
    }
    try {
      for (final element in value) {
        _validateModelJson(
          element,
          depth: depth + 1,
          maxDepth: maxDepth,
          maxStringRunes: maxStringRunes,
          budget: budget,
          activeContainers: activeContainers,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return;
  }
  if (value is Map) {
    if (!activeContainers.add(value)) {
      throw const FormatException('tool outcome contains a cycle');
    }
    try {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || key.runes.length > maxStringRunes) {
          throw const FormatException('tool outcome contains invalid key');
        }
        _validateModelJson(
          entry.value,
          depth: depth + 1,
          maxDepth: maxDepth,
          maxStringRunes: maxStringRunes,
          budget: budget,
          activeContainers: activeContainers,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return;
  }
  throw const FormatException('tool outcome contains non-JSON data');
}

final class _OutcomeRenderBudget {
  _OutcomeRenderBudget(this.remaining);

  int remaining;

  bool take() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}
