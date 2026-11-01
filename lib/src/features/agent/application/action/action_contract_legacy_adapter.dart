import 'dart:async';
import 'dart:convert';

import 'tool_outcome.dart';

/// Result returned by the existing execution owner after one admitted batch.
///
/// [callerOutput] is returned byte-for-byte in `off` and `shadow`. The V2
/// boundary reads [actionOutputs] only for output-contract observation or
/// enforcement; it never invokes a second handler to manufacture them.
final class ActionContractLegacyResult {
  const ActionContractLegacyResult({
    required this.callerOutput,
    required this.actionOutputs,
  });

  factory ActionContractLegacyResult.single(Object? output) =>
      ActionContractLegacyResult(
        callerOutput: output,
        actionOutputs: <Object?>[output],
      );

  final Object? callerOutput;
  final List<Object?> actionOutputs;
}

typedef ActionContractLegacyCallback =
    FutureOr<ActionContractLegacyResult> Function();

/// Per-admission compatibility adapter that can invoke its callback once.
///
/// This deliberately has no reference to `ActionDefinition.handler`.
/// Definitions are metadata; the already-existing caller remains the sole
/// owner of real effects in every rollout mode.
final class ActionContractLegacyAdapter {
  static const int _maximumLegacyStringRunes = 65536;
  static const int _maximumLegacyStringBytes = 65536;
  static const int _maximumLegacyMapEntries = 4096;

  bool _invoked = false;

  bool get wasInvoked => _invoked;

  Future<ActionContractLegacyResult> invokeOnce(
    ActionContractLegacyCallback callback,
  ) async {
    if (_invoked) {
      throw const ActionContractLegacyInvocationException(
        'legacy_callback_consumed',
      );
    }
    _invoked = true;
    return Future<ActionContractLegacyResult>.sync(callback);
  }

  /// Converts legacy or already-typed output into one bounded semantic result.
  ///
  /// Failure payloads are deliberately discarded. Legacy handlers frequently
  /// put exception text in `error`/`data`; returning that text to the model
  /// would defeat [ToolOutcome]'s content-safety boundary.
  ToolOutcome adaptOutput(Object? output) {
    try {
      return _adaptOutput(output);
    } on Object {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }
  }

  ToolOutcome _adaptOutput(Object? output) {
    if (output is ToolOutcome) return _sanitizeTypedOutcome(output);
    if (output == null) {
      return ToolOutcome.ok(data: const <String, Object?>{});
    }
    if (output is! String) return _adaptDecoded(output);

    final raw = output.trim();
    if (raw.isEmpty) {
      return ToolOutcome.ok(data: const <String, Object?>{});
    }
    if (raw.runes.length > _maximumLegacyStringRunes ||
        utf8.encode(raw).length > _maximumLegacyStringBytes) {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }
    try {
      return _adaptDecoded(jsonDecode(raw));
    } on FormatException {
      return ToolOutcome.ok(data: <String, Object?>{'value': raw});
    }
  }

  ToolOutcome _adaptDecoded(Object? decoded) {
    if (decoded is ToolOutcome) return _sanitizeTypedOutcome(decoded);
    if (decoded is! Map) return ToolOutcome.ok(data: decoded);
    if (decoded.length > _maximumLegacyMapEntries) {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }

    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        return ToolOutcome.failure(
          status: ToolOutcomeStatus.failed,
          code: 'invalid_tool_outcome',
        );
      }
      map[entry.key as String] = entry.value;
    }

    final rawError = map['error'];
    final error = rawError is String ? rawError.trim() : null;
    if ((error != null && error.isNotEmpty) ||
        (rawError != null && rawError is! String)) {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: error == null
            ? 'legacy_error'
            : _safeLegacyCode(error, fallback: 'legacy_error'),
      );
    }

    final statusValue = map['status'];
    if (statusValue != null && statusValue is! String) {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }
    final rawStatus = (statusValue as String?)?.trim();
    final status = _statusFromWire(rawStatus);
    if (status == null) return ToolOutcome.ok(data: map);

    final codeValue = map['code'];
    if (codeValue != null && codeValue is! String) {
      return ToolOutcome.failure(
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }
    final rawCode = codeValue as String? ?? rawStatus ?? status.wireName;
    final retryable = map['retryable'] is bool && map['retryable'] == true;
    if (status != ToolOutcomeStatus.ok) {
      return ToolOutcome.failure(
        status: status,
        code: _safeLegacyCode(rawCode, fallback: status.wireName),
        retryable: retryable,
      );
    }
    return ToolOutcome.ok(
      code: _safeLegacyCode(rawCode, fallback: 'ok'),
      data: map.containsKey('data') ? map['data'] : map,
      display: map['display'] is String ? map['display'] as String : null,
    );
  }

  ToolOutcome _sanitizeTypedOutcome(ToolOutcome outcome) {
    if (!outcome.isOk) {
      return ToolOutcome.failure(
        status: outcome.status,
        code: _safeLegacyCode(outcome.code, fallback: outcome.status.wireName),
        retryable: outcome.retryable,
      );
    }
    return ToolOutcome.ok(
      code: _safeLegacyCode(outcome.code, fallback: 'ok'),
      data: outcome.data,
      display: outcome.display,
    );
  }
}

ToolOutcomeStatus? _statusFromWire(String? raw) => switch (raw) {
  'ok' => ToolOutcomeStatus.ok,
  'invalid_arguments' => ToolOutcomeStatus.invalidArguments,
  'confirmation_required' ||
  'commit_required' => ToolOutcomeStatus.confirmationRequired,
  'denied' => ToolOutcomeStatus.denied,
  'unavailable' => ToolOutcomeStatus.unavailable,
  'cancelled' => ToolOutcomeStatus.cancelled,
  'failed' => ToolOutcomeStatus.failed,
  _ => null,
};

String _safeLegacyCode(String raw, {required String fallback}) {
  final code = raw.trim().toLowerCase();
  return code.isNotEmpty &&
          code.length <= 64 &&
          RegExp(r'^[a-z0-9._-]+$').hasMatch(code)
      ? code
      : fallback;
}

/// Stable, value-redacting legacy invocation failure.
final class ActionContractLegacyInvocationException implements Exception {
  const ActionContractLegacyInvocationException(this.code);

  final String code;

  @override
  String toString() => 'ActionContractLegacyInvocationException($code)';
}
