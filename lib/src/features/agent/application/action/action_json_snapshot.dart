/// Stable, value-redacting failure raised by [snapshotActionJson].
final class ActionJsonSnapshotException implements Exception {
  const ActionJsonSnapshotException(this.code);

  final String code;

  @override
  String toString() => 'ActionJsonSnapshotException($code)';
}

/// Produces a recursively immutable, bounded JSON snapshot.
///
/// This closes async mutation windows between schema validation, approval,
/// audit, and execution. Rejected values are never rendered in exceptions.
Object? snapshotActionJson(
  Object? value, {
  int maxDepth = 64,
  int maxNodes = 4096,
  int maxStringRunes = 16384,
}) {
  if (maxDepth < 1 || maxNodes < 1 || maxStringRunes < 1) {
    throw const ActionJsonSnapshotException('invalid_limits');
  }
  try {
    return _snapshot(
      value,
      depth: 0,
      maxDepth: maxDepth,
      maxStringRunes: maxStringRunes,
      budget: _SnapshotBudget(maxNodes),
      activeContainers: Set<Object>.identity(),
    );
  } on ActionJsonSnapshotException {
    rethrow;
  } on Object {
    throw const ActionJsonSnapshotException('invalid_json');
  }
}

Object? _snapshot(
  Object? value, {
  required int depth,
  required int maxDepth,
  required int maxStringRunes,
  required _SnapshotBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > maxDepth) {
    throw const ActionJsonSnapshotException('too_deep');
  }
  budget.take();
  if (value == null || value is bool) return value;
  if (value is String) {
    if (value.runes.length > maxStringRunes) {
      throw const ActionJsonSnapshotException('string_too_long');
    }
    return value;
  }
  if (value is int) {
    if (value.bitLength > 425) {
      throw const ActionJsonSnapshotException('number_too_large');
    }
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw const ActionJsonSnapshotException('non_finite_number');
    }
    return value;
  }
  if (value is List) {
    if (!activeContainers.add(value)) {
      throw const ActionJsonSnapshotException('cyclic_json');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map(
          (item) => _snapshot(
            item,
            depth: depth + 1,
            maxDepth: maxDepth,
            maxStringRunes: maxStringRunes,
            budget: budget,
            activeContainers: activeContainers,
          ),
        ),
      );
    } finally {
      activeContainers.remove(value);
    }
  }
  if (value is Map) {
    if (!activeContainers.add(value)) {
      throw const ActionJsonSnapshotException('cyclic_json');
    }
    final snapshot = <String, Object?>{};
    try {
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const ActionJsonSnapshotException('non_string_key');
        }
        snapshot[key] = _snapshot(
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
    return Map<String, Object?>.unmodifiable(snapshot);
  }
  throw const ActionJsonSnapshotException('unsupported_json_value');
}

final class _SnapshotBudget {
  _SnapshotBudget(this.remaining);

  int remaining;

  void take() {
    if (remaining <= 0) {
      throw const ActionJsonSnapshotException('too_many_nodes');
    }
    remaining -= 1;
  }
}
