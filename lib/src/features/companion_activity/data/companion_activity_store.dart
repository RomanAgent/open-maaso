import 'dart:async';

import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast.dart';

typedef CompanionActivityStoreTransaction<T> =
    FutureOr<CompanionActivityStoreMutation<T>> Function(
      Map<String, Object?>? document,
    );

final class CompanionActivityStoreMutation<T> {
  const CompanionActivityStoreMutation({
    required this.value,
    required this.document,
    this.write = true,
    this.finalWriteFence,
  });

  const CompanionActivityStoreMutation.readOnly(T value)
    : this(value: value, document: null, write: false);

  final T value;
  final Map<String, Object?>? document;
  final bool write;
  final bool Function()? finalWriteFence;
}

/// Account-scoped durable persistence with a generation write fence.
abstract interface class CompanionActivityStore {
  ActivityScope get scope;

  Future<T> transaction<T>(CompanionActivityStoreTransaction<T> mutation);

  Future<Map<String, Object?>?> read();

  /// Synchronously fences new work, then waits for admitted work to settle.
  Future<void> deactivateAndDrain();
}

/// Sembast implementation backed by one account-scoped database.
///
/// The record still carries account + generation identity. This prevents a
/// database handle accidentally mounted for another runtime generation from
/// accepting a stale service instance.
final class SembastCompanionActivityStore implements CompanionActivityStore {
  SembastCompanionActivityStore({
    required Database database,
    required this.scope,
  }) : _database = database;

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('companion_activity.v1');
  static const String _recordKey = 'current';

  final Database _database;

  @override
  final ActivityScope scope;

  final Set<Future<void>> _operations = <Future<void>>{};
  bool _active = true;
  Future<void>? _drainFuture;

  @override
  Future<T> transaction<T>(CompanionActivityStoreTransaction<T> mutation) {
    _requireActive();
    final operation = _database.transaction((databaseTransaction) async {
      final record = _store.record(_recordKey);
      final current = await record.get(databaseTransaction);
      _requireReadableScope(current);
      final result = await mutation(_copy(current));
      if (result.write) {
        if (result.finalWriteFence?.call() == false) {
          throw StateError('companion_activity_final_write_fenced');
        }
        final next = result.document;
        if (next == null) {
          throw StateError('companion_activity_document_missing');
        }
        _requireWritableScope(next);
        await record.put(databaseTransaction, next);
      }
      return result.value;
    });
    _track(operation);
    return operation;
  }

  @override
  Future<Map<String, Object?>?> read() {
    _requireActive();
    final operation = _store.record(_recordKey).get(_database).then((value) {
      _requireReadableScope(value);
      return _copy(value);
    });
    _track(operation);
    return operation;
  }

  @override
  Future<void> deactivateAndDrain() {
    final existing = _drainFuture;
    if (existing != null) return existing;
    _active = false;
    late final Future<void> draining;
    draining = _waitForOperations().whenComplete(() {
      if (identical(_drainFuture, draining)) {
        _drainFuture = null;
      }
    });
    _drainFuture = draining;
    return draining;
  }

  void _requireActive() {
    if (!_active) {
      throw StateError('companion_activity_store_inactive');
    }
  }

  void _requireReadableScope(Map<String, Object?>? document) {
    if (document == null) return;
    final storedGeneration = document['facadeGeneration'];
    if (document['accountId'] != scope.accountId ||
        storedGeneration is! int ||
        storedGeneration < 1 ||
        storedGeneration > scope.facadeGeneration) {
      throw StateError('companion_activity_store_scope_mismatch');
    }
  }

  void _requireWritableScope(Map<String, Object?> document) {
    if (document['accountId'] != scope.accountId ||
        document['facadeGeneration'] != scope.facadeGeneration) {
      throw StateError('companion_activity_store_scope_mismatch');
    }
  }

  void _track(Future<Object?> operation) {
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
  }

  Future<void> _waitForOperations() async {
    while (_operations.isNotEmpty) {
      await Future.wait<void>(_operations.toList(growable: false));
    }
  }

  static Map<String, Object?>? _copy(Map<String, Object?>? source) =>
      source == null ? null : Map<String, Object?>.from(source);
}
