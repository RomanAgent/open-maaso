import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:sembast/sembast.dart';

/// Strict account-database codec for the desktop local-ASR opt-in.
///
/// The selected pack id is metadata only. Model bytes and source paths never
/// enter Sembast, and a malformed row is rejected so the service initializes
/// fail-closed instead of guessing at consent.
final class SembastDesktopLocalAsrPreferenceStore
    implements DesktopLocalAsrPreferenceStore {
  SembastDesktopLocalAsrPreferenceStore(this.database);

  static const int schemaVersion = 1;
  static const String _recordKey = 'self';
  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>(
        'desktop_local_asr_preferences.v1',
      );

  final DBService database;

  @override
  Future<DesktopLocalAsrPreferenceSnapshot?> read() async {
    final row = await _store.record(_recordKey).get(database.raw);
    if (row == null) return null;
    return decode(Map<String, Object?>.from(row));
  }

  @override
  Future<void> write(DesktopLocalAsrPreferenceSnapshot snapshot) =>
      _store.record(_recordKey).put(database.raw, encode(snapshot));

  static Map<String, Object?> encode(
    DesktopLocalAsrPreferenceSnapshot snapshot,
  ) => <String, Object?>{
    'schemaVersion': schemaVersion,
    'accountScopeDigest': snapshot.accountScopeDigest,
    'revision': snapshot.revision,
    'enabled': snapshot.enabled,
    'selectedModelId': snapshot.selectedModelId,
  };

  static DesktopLocalAsrPreferenceSnapshot decode(Object? source) {
    if (source is! Map) {
      throw const FormatException('desktop local ASR preference is invalid');
    }
    final json = Map<String, Object?>.from(source);
    const fields = <String>{
      'schemaVersion',
      'accountScopeDigest',
      'revision',
      'enabled',
      'selectedModelId',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException(
        'desktop local ASR preference schema is invalid',
      );
    }

    final digest = json['accountScopeDigest'];
    final revision = json['revision'];
    final enabled = json['enabled'];
    final selectedModelId = json['selectedModelId'];
    if (digest is! String ||
        revision is! int ||
        enabled is! bool ||
        (selectedModelId != null && selectedModelId is! String)) {
      throw const FormatException(
        'desktop local ASR preference values are invalid',
      );
    }
    try {
      return DesktopLocalAsrPreferenceSnapshot(
        accountScopeDigest: digest,
        revision: revision,
        enabled: enabled,
        selectedModelId: selectedModelId as String?,
      );
    } on Object {
      throw const FormatException(
        'desktop local ASR preference values are invalid',
      );
    }
  }
}
