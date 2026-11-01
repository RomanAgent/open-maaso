import 'package:sembast/sembast.dart';
import '../domain/companion_profile.dart';

abstract interface class CompanionProfileStore {
  Future<CompanionProfile?> read();
  Future<void> write(CompanionProfile profile);
}

final class SembastCompanionProfileStore implements CompanionProfileStore {
  SembastCompanionProfileStore({
    required Database database,
    required String contextKey,
    required bool Function() isCurrent,
  }) : _database = database,
       _contextKey = contextKey,
       _isCurrent = isCurrent;
  final Database _database;
  final String _contextKey;
  final bool Function() _isCurrent;
  static final _store = stringMapStoreFactory.store('companion_profile.v1');
  void _check([Map<String, Object?>? value]) {
    if (!_isCurrent() ||
        (value != null && value['contextKey'] != _contextKey)) {
      throw const CompanionProfileException(
        CompanionProfileFailure.contextChanged,
      );
    }
  }

  @override
  Future<CompanionProfile?> read() async {
    _check();
    final value = await _store.record('self').get(_database);
    _check(value);
    return value == null ? null : CompanionProfile.fromJson(value['profile']);
  }

  @override
  Future<void> write(CompanionProfile profile) async {
    _check();
    await _database.transaction((tx) async {
      final record = _store.record('self');
      _check(await record.get(tx));
      await record.put(tx, {
        'contextKey': _contextKey,
        'profile': profile.toJson(),
      });
      _check();
    });
    _check();
  }
}
