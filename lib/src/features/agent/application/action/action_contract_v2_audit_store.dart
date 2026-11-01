import 'dart:collection';

import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

import 'action_audit_log.dart';

/// Durable, account-scoped append target for content-safe Action Contract V2
/// audit entries.
abstract interface class ActionContractV2AuditPersistence {
  Future<void> append(ActionAuditEntry entry);
}

/// Persists only [ActionAuditEntry.toJson] in the mounted account database.
///
/// Raw arguments and targets have already been replaced by keyed digests at
/// this boundary. The auto-incrementing record key avoids relying on the
/// isolate-local audit sequence when an account runtime is mounted again.
final class SembastActionContractV2AuditPersistence
    implements ActionContractV2AuditPersistence {
  SembastActionContractV2AuditPersistence({required DBService accountDatabase})
    : _accountDatabase = accountDatabase;

  static final StoreRef<int, Map<String, Object?>> _store = intMapStoreFactory
      .store('action_contract_v2_audit.v1');

  final DBService _accountDatabase;

  @override
  Future<void> append(ActionAuditEntry entry) async {
    await _store.add(_accountDatabase.raw, entry.toJson());
  }

  /// Returns an immutable chronological snapshot for diagnostics and export.
  ///
  /// The account database itself is the isolation boundary; callers never
  /// receive a mutable Sembast record map.
  Future<List<Map<String, Object?>>> readAll() async {
    final records = await _store.find(_accountDatabase.raw);
    return List<Map<String, Object?>>.unmodifiable(
      records.map(
        (record) => UnmodifiableMapView<String, Object?>(
          Map<String, Object?>.from(record.value),
        ),
      ),
    );
  }
}
