import 'package:sembast/sembast.dart';

import '../domain/identity_local_state.dart';
import '../domain/identity_profile.dart';

abstract interface class IdentityLocalStore {
  Future<IdentityLocalState?> read();
  Future<void> write(IdentityLocalState state);
}

/// Uses the existing account/environment database; never a shared preferences
/// record. The extra context and mount fence catch accidental handle reuse.
final class SembastIdentityLocalStore implements IdentityLocalStore {
  SembastIdentityLocalStore({
    required Database database,
    required String contextKey,
    required bool Function() isCurrent,
  }) : _database = database,
       _contextKey = contextKey,
       _isCurrent = isCurrent;

  static final _store = stringMapStoreFactory.store('identity_local.v1');
  final Database _database;
  final String _contextKey;
  final bool Function() _isCurrent;

  void _check() {
    if (!_isCurrent()) {
      throw const IdentityException(IdentityFailure.contextChanged);
    }
  }

  void _checkDocument(Map<String, Object?>? value) {
    if (value != null && value['contextKey'] != _contextKey) {
      throw const IdentityException(IdentityFailure.contextChanged);
    }
  }

  @override
  Future<IdentityLocalState?> read() async {
    _check();
    final value = await _store.record('self').get(_database);
    _check();
    _checkDocument(value);
    return value == null ? null : IdentityLocalState.fromJson(value['state']);
  }

  @override
  Future<void> write(IdentityLocalState state) async {
    _check();
    await _database.transaction((transaction) async {
      final record = _store.record('self');
      final previous = await record.get(transaction);
      _check();
      _checkDocument(previous);
      await record.put(transaction, {
        'contextKey': _contextKey,
        'state': state.toJson(),
      });
      // A retired mount aborts the transaction instead of committing a late
      // write into a database that another account might later open.
      _check();
    });
    _check();
  }
}
