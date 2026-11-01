@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/persistence/markdown_document_store.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';
import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default database persists through the browser IndexedDB backend',
    () async {
      final recordKey = 'record-${DateTime.now().microsecondsSinceEpoch}';
      final store = stringMapStoreFactory.store('web_startup_smoke');

      final first = await DBService().init();
      await store.record(recordKey).put(first.raw, <String, Object?>{
        'value': 'persisted',
      });
      await first.close();

      final second = await DBService().init();
      final restored = await store.record(recordKey).get(second.raw);
      expect(restored?['value'], 'persisted');
      await second.close();
    },
  );

  test('startup markdown services persist in browser storage', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final soul = await SoulService().init();
    await soul.update(
      name: 'Web Soul',
      age: 18,
      gender: 'neutral',
      notesReplace: 'Browser soul note',
    );
    final restoredSoul = await SoulService().init();
    expect(restoredSoul.name.value, 'Web Soul');
    expect(restoredSoul.age.value, 18);
    expect(restoredSoul.gender.value, 'neutral');
    expect(restoredSoul.notes.value, 'Browser soul note');

    final master = await MasterProfileService().init();
    await master.update(
      name: 'Web Master',
      pronouns: 'they/them',
      age: 30,
      notesReplace: 'Browser master note',
    );
    final restoredMaster = await MasterProfileService().init();
    expect(restoredMaster.name.value, 'Web Master');
    expect(restoredMaster.pronouns.value, 'they/them');
    expect(restoredMaster.age.value, 30);
    expect(restoredMaster.notes.value, 'Browser master note');

    final source = await openMarkdownDocumentStore('world.md');
    await source.write('# World\n\n## Notes\nBrowser world note\n');
    final world = await WorldKBService().init();
    final rejected = await world.update(
      notesReplace: 'Do not claim this source',
    );
    expect(rejected.disposition, MemoryWriteDisposition.rejected);
    final restoredWorld = await WorldKBService().init();
    expect(restoredWorld.notes.value, 'Browser world note');
  });

  test(
    'scoped profile services isolate accounts and never read legacy documents',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'maaso.markdown.soul.md': '''
# Agent Soul

- name: Legacy Soul
- age: 99
- gender: legacy

## Notes
legacy soul note
''',
        'maaso.markdown.master.md': '''
# Master

- name: Legacy Master

## Notes
legacy master note
''',
        'maaso.markdown.world.md': '''
# World

## Notes
legacy world note
''',
      });
      final runId = DateTime.now().microsecondsSinceEpoch;
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'profile-account-a-$runId',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'profile-account-b-$runId',
      );
      final agentA = accountA.agent('self');
      final agentB = accountB.agent('self');
      final worldSourceA = await openAgentMarkdownDocumentStore(
        agentA,
        AgentMarkdownDocumentKind.world,
      );
      await worldSourceA.write('# World\n\n## Notes\nA world note\n');

      final soulA = await SoulService().init(scope: agentA);
      final masterA = await MasterProfileService().init(scope: accountA);
      final worldA = await WorldKBService().init(scope: agentA);

      expect(soulA.name.value, isNull);
      expect(masterA.name.value, isNull);
      expect(worldA.notes.value, 'A world note');

      await soulA.update(
        name: 'Account A Soul',
        age: 18,
        gender: 'neutral',
        notesReplace: 'A soul note',
      );
      await masterA.update(
        name: 'Account A Master',
        pronouns: 'they/them',
        age: 30,
        notesReplace: 'A master note',
      );
      final rejected = await worldA.update(notesReplace: 'Unbound overwrite');
      expect(rejected.disposition, MemoryWriteDisposition.rejected);

      final soulB = await SoulService().init(scope: agentB);
      final masterB = await MasterProfileService().init(scope: accountB);
      final worldB = await WorldKBService().init(scope: agentB);
      expect(soulB.name.value, isNull);
      expect(masterB.name.value, isNull);
      expect(worldB.notes.value, isEmpty);

      final restoredSoulA = await SoulService().init(scope: agentA);
      final restoredMasterA = await MasterProfileService().init(
        scope: accountA,
      );
      final restoredWorldA = await WorldKBService().init(scope: agentA);
      expect(restoredSoulA.name.value, 'Account A Soul');
      expect(restoredSoulA.notes.value, 'A soul note');
      expect(restoredMasterA.name.value, 'Account A Master');
      expect(restoredMasterA.notes.value, 'A master note');
      expect(restoredWorldA.notes.value, 'A world note');
    },
  );
}
