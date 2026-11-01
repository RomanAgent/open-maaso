import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/desktop_local_asr_preference_store.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test('round-trips an account-scoped default-off preference', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'desktop-local-asr-preference.db',
    );
    addTearDown(database.close);
    final store = SembastDesktopLocalAsrPreferenceStore(database);
    expect(await store.read(), isNull);

    final snapshot = DesktopLocalAsrPreferenceSnapshot(
      accountScopeDigest: _scope,
      revision: 1,
      enabled: false,
      selectedModelId: 'moonshine-tiny-en-int8-bf2b762c',
    );
    await store.write(snapshot);

    final restored = await store.read();
    expect(restored, isNotNull);
    expect(restored!.accountScopeDigest, _scope);
    expect(restored.revision, 1);
    expect(restored.enabled, isFalse);
    expect(restored.selectedModelId, 'moonshine-tiny-en-int8-bf2b762c');
  });

  test('strict codec rejects extra fields and enabled-without-model', () {
    final valid = <String, Object?>{
      'schemaVersion': 1,
      'accountScopeDigest': _scope,
      'revision': 1,
      'enabled': false,
      'selectedModelId': null,
    };
    expect(
      () => SembastDesktopLocalAsrPreferenceStore.decode(<String, Object?>{
        ...valid,
        'unexpected': true,
      }),
      throwsFormatException,
    );
    expect(
      () => SembastDesktopLocalAsrPreferenceStore.decode(<String, Object?>{
        ...valid,
        'enabled': true,
      }),
      throwsFormatException,
    );
  });
}

const String _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
