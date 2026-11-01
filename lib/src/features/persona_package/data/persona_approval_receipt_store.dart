import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sembast/sembast.dart';

import '../domain/persona_package_gates.dart';
import '../domain/persona_package_manifest.dart';

/// Account-generation scoped, transactionally durable replay ledger.
///
/// Receipt authenticity is established before this boundary. This store owns
/// atomic consume-once semantics only for one process/main isolate using one
/// shared global [Database] handle. It deliberately makes no cross-process
/// compare-and-set claim; production registration must enforce that topology.
final class SembastPersonaApprovalReceiptConsumer
    implements PersonaApprovalReceiptConsumer {
  SembastPersonaApprovalReceiptConsumer({
    required Database database,
    required this.scope,
  }) : _database = database;

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('persona_approval_receipts.v1');

  final Database _database;
  final PersonaPackageScope scope;
  final Set<Future<void>> _operations = <Future<void>>{};

  bool _active = true;
  Future<void>? _drainFuture;

  @override
  Future<bool> consumeOnce(
    PersonaOnceApprovalReceipt receipt, {
    required DateTime now,
  }) {
    _requireActive();
    if (!receipt.scope.matches(scope)) {
      return Future<bool>.value(false);
    }
    final recordKey = _recordKey(receipt);
    final operation = _database.transaction((transaction) async {
      await _store.delete(
        transaction,
        finder: Finder(
          filter: Filter.lessThan(
            'retainUntilEpochMs',
            now.toUtc().millisecondsSinceEpoch,
          ),
          limit: 64,
        ),
      );
      final record = _store.record(recordKey);
      if (await record.get(transaction) != null) return false;
      await record.put(transaction, <String, Object?>{
        'schemaVersion': 1,
        'issuer': receipt.issuer,
        'receiptId': receipt.id,
        'installationId': receipt.installationId,
        'manifestDigest': receipt.manifestDigest,
        'accountId': scope.accountId,
        'facadeGeneration': scope.facadeGeneration,
        'skillId': receipt.skillId,
        'skillVersion': receipt.skillVersion,
        'skillEntryRef': receipt.skillEntryRef,
        'method': receipt.method,
        'argsTargetDigest': receipt.argsTargetDigest,
        'callId': receipt.callId,
        'permission': receipt.permission.wireName,
        'consumedAt': now.toUtc().toIso8601String(),
        'expiresAt': receipt.expiresAt.toUtc().toIso8601String(),
        'retainUntilEpochMs': receipt.expiresAt
            .toUtc()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      });
      return true;
    });
    _track(operation);
    return operation;
  }

  Future<void> deactivateAndDrain() {
    final existing = _drainFuture;
    if (existing != null) return existing;
    _active = false;
    late final Future<void> draining;
    draining = _waitForOperations().whenComplete(() {
      if (identical(_drainFuture, draining)) _drainFuture = null;
    });
    _drainFuture = draining;
    return draining;
  }

  void _requireActive() {
    if (!_active) {
      throw StateError('persona_approval_receipt_store_inactive');
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

  static String _recordKey(PersonaOnceApprovalReceipt receipt) {
    final canonical = <String>[
      receipt.issuer,
      receipt.scope.accountId,
      receipt.scope.facadeGeneration.toString(),
      receipt.installationId,
      receipt.manifestDigest,
      receipt.id,
    ].join('\u0000');
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}
