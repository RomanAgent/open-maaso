import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/proactive_category_persona_memory.dart';
import 'package:maaso/src/core/services/agent_persona_memory_store.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _accountA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _accountB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _legacyKey = ProactiveCategoryPersonaLegacyMigration.legacyKey;
final _memories = StoreRef<String, Map<String, Object?>>(
  AgentPersonaMemoryStore.storeName,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late SharedPreferences shared;
  var sequence = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    shared = await SharedPreferences.getInstance();
    database = await databaseFactoryMemory.openDatabase(
      'categories-${sequence++}.db',
    );
  });
  tearDown(() => database.close());

  SembastProactiveCategoryPersonaMemoryStore store([
    String account = _accountA,
  ]) => SembastProactiveCategoryPersonaMemoryStore(
    database: database,
    accountScopeDigest: account,
  );
  Future<NotificationPreferencesService> service() async {
    final result = await NotificationPreferencesService(
      preferences: shared,
    ).init();
    addTearDown(result.deactivatePersonaMemoryAndDrain);
    return result;
  }

  test(
    'missing choices never become explicit memories or grant permission',
    () async {
      final preferences = await service();
      expect(preferences.personaMemoryAvailable, isFalse);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      await expectLater(
        preferences.setGreetingsEnabled(true),
        throwsStateError,
      );
      await preferences.bindPersonaMemory(store());
      expect(preferences.personaMemoryAvailable, isTrue);
      expect(preferences.state.value.greetingsEnabled, isTrue);
      expect(preferences.state.value.randomCheckInsEnabled, isTrue);
      expect(preferences.state.value.canNotify, isFalse);
      expect(await _memories.count(database), 0);
      await preferences.setConsent(enabled: true, permissionGranted: true);
      final device = jsonDecode(shared.getString(_legacyKey)!) as Map;
      expect(device.containsKey('greetingsEnabled'), isFalse);
      expect(device.containsKey('randomCheckInsEnabled'), isFalse);
      expect(await _memories.count(database), 0);
    },
  );

  test(
    'legacy categories migrate once with honest provenance and retain device gates',
    () async {
      await shared.setString(
        _legacyKey,
        jsonEncode(
          const NotificationPreferences(
            enabled: true,
            permissionGranted: true,
            greetingsEnabled: false,
            randomCheckInsEnabled: true,
            scheduledTasksEnabled: false,
            quietStartMinutes: 21 * 60,
          ).toJson(),
        ),
      );
      final preferences = await service();
      await preferences.bindPersonaMemory(store());
      final memory = (await store().read())!;
      expect(memory.greetings, isFalse);
      expect(memory.randomCheckIns, isTrue);
      expect(memory.greetingsSource, 'legacy_configuration');
      expect(memory.randomCheckInsSource, 'legacy_configuration');
      final row = (await _memories
          .record('$_accountA:self:proactiveCategories')
          .get(database))!;
      expect(row['source'], 'owner_configuration');
      expect(preferences.state.value.canNotify, isTrue);
      expect(preferences.state.value.scheduledTasksEnabled, isFalse);
      final device = jsonDecode(shared.getString(_legacyKey)!) as Map;
      expect(device.containsKey('greetingsEnabled'), isFalse);
      expect(device.containsKey('randomCheckInsEnabled'), isFalse);
      expect(device['scheduledTasksEnabled'], isFalse);
      expect(device['quietStartMinutes'], 21 * 60);
      await preferences.bindPersonaMemory(store(_accountB));
      expect(preferences.state.value.greetingsEnabled, isTrue);
      expect(await store(_accountB).read(), isNull);
      await preferences.bindPersonaMemory(store());
      expect(preferences.state.value.greetingsEnabled, isFalse);
    },
  );

  test(
    'canonical choices persist together and device writes never create another source',
    () async {
      final preferences = await service();
      await preferences.bindPersonaMemory(store());
      await Future.wait([
        preferences.setGreetingsEnabled(false),
        preferences.setRandomCheckInsEnabled(false),
      ]);
      await preferences.setConsent(enabled: true, permissionGranted: true);
      await preferences.setScheduledTasksEnabled(false);
      await preferences.setQuietHours(start: 23 * 60, end: 8 * 60);
      final saved = (await store().read())!;
      expect(saved.revision, 2);
      expect(saved.greetings, isFalse);
      expect(saved.randomCheckIns, isFalse);
      expect(saved.greetingsSource, 'user_choice');
      expect(saved.randomCheckInsSource, 'user_choice');
      final device = jsonDecode(shared.getString(_legacyKey)!) as Map;
      expect(device.containsKey('greetingsEnabled'), isFalse);
      expect(device.containsKey('randomCheckInsEnabled'), isFalse);
      final reboot = await service();
      await reboot.bindPersonaMemory(store());
      expect(reboot.state.value.greetingsEnabled, isFalse);
      expect(reboot.state.value.randomCheckInsEnabled, isFalse);
      expect(reboot.state.value.canNotify, isTrue);
      expect(reboot.state.value.scheduledTasksEnabled, isFalse);
      expect(await _memories.count(database), 1);
    },
  );

  test(
    'invalid legacy payload remains recoverable and is not silently replaced',
    () async {
      const invalid = '{"greetingsEnabled":"maybe","enabled":false}';
      await shared.setString(_legacyKey, invalid);
      final preferences = await service();
      await preferences.bindPersonaMemory(store());
      expect(preferences.personaMemoryAvailable, isFalse);
      expect(shared.getString(_legacyKey), invalid);
      expect(await _memories.count(database), 0);
      await expectLater(
        preferences.setGreetingsEnabled(true),
        throwsStateError,
      );
    },
  );

  test(
    'corrupted canonical memory cannot fall back to legacy choices',
    () async {
      await store().write(
        const ProactiveCategoryPersonaMemory(
          greetings: false,
          greetingsSource: 'user_choice',
        ),
      );
      final key = '$_accountA:self:proactiveCategories';
      final row = (await _memories.record(key).get(database))!;
      final corrupted = {...row, 'accountScopeDigest': _accountB};
      await _memories.record(key).put(database, corrupted);
      final legacy = jsonEncode({'greetingsEnabled': true});
      await shared.setString(_legacyKey, legacy);
      final preferences = await service();
      await preferences.bindPersonaMemory(store());
      expect(preferences.personaMemoryAvailable, isFalse);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      expect(await _memories.record(key).get(database), corrupted);
      expect(shared.getString(_legacyKey), legacy);
    },
  );

  test(
    'valid canonical memory remains authoritative beside an invalid migration journal',
    () async {
      await store().write(
        const ProactiveCategoryPersonaMemory(
          greetings: false,
          greetingsSource: 'user_choice',
        ),
      );
      const invalidJournal = '{"complete":"unknown"}';
      await shared.setString(
        ProactiveCategoryPersonaLegacyMigration.journalKey,
        invalidJournal,
      );
      await shared.setString(
        _legacyKey,
        jsonEncode({'greetingsEnabled': true}),
      );
      final preferences = await service();
      await preferences.bindPersonaMemory(store());
      expect(preferences.personaMemoryAvailable, isTrue);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      expect(
        shared.getString(ProactiveCategoryPersonaLegacyMigration.journalKey),
        invalidJournal,
      );
      expect(
        (jsonDecode(shared.getString(_legacyKey)!) as Map)['greetingsEnabled'],
        isTrue,
      );
    },
  );

  test(
    'a failed category write is not published and the queue recovers',
    () async {
      final memory = _HeldStore(_accountA)..failNext = true;
      final preferences = await service();
      await preferences.bindPersonaMemory(memory);
      await expectLater(
        preferences.setGreetingsEnabled(false),
        throwsStateError,
      );
      expect(preferences.state.value.greetingsEnabled, isTrue);
      expect(memory.value, isNull);
      await preferences.setRandomCheckInsEnabled(false);
      expect(preferences.state.value.greetingsEnabled, isTrue);
      expect(preferences.state.value.randomCheckInsEnabled, isFalse);
      expect(memory.value!.greetings, isNull);
      expect(memory.value!.randomCheckInsSource, 'user_choice');
    },
  );

  test(
    'retirement drains a delayed read without publishing old categories',
    () async {
      final memory = _HeldStore(_accountA)
        ..readGate = Completer<void>()
        ..value = const ProactiveCategoryPersonaMemory(
          greetings: true,
          greetingsSource: 'user_choice',
        );
      final preferences = await service();
      final bind = preferences.bindPersonaMemory(memory);
      await memory.readStarted.future;
      var drained = false;
      final drain = preferences.deactivatePersonaMemoryAndDrain().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(preferences.personaMemoryAvailable, isFalse);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      memory.readGate!.complete();
      await Future.wait([bind, drain]);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      expect(preferences.personaMemoryAccount, isNull);
    },
  );

  test(
    'retirement fences queued writes and never publishes late old-account choices',
    () async {
      final memory = _HeldStore(_accountA)..writeGate = Completer<void>();
      final preferences = await service();
      await preferences.bindPersonaMemory(memory);
      final write = preferences.setGreetingsEnabled(true);
      await memory.writeStarted.future;
      final queued = preferences.setRandomCheckInsEnabled(false);
      final rejected = expectLater(queued, throwsStateError);
      var drained = false;
      final drain = preferences.deactivatePersonaMemoryAndDrain().then(
        (_) => drained = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      memory.writeGate!.complete();
      await Future.wait([write, rejected, drain]);
      expect(memory.writeCount, 1);
      expect(preferences.state.value.greetingsEnabled, isFalse);
      await preferences.bindPersonaMemory(store(_accountB));
      expect(await store(_accountB).read(), isNull);
      expect(preferences.personaMemoryAccount, _accountB);
    },
  );

  test('migration crash pins the exact payload to the first account', () async {
    await shared.setString(_legacyKey, jsonEncode({'greetingsEnabled': false}));
    final migration = ProactiveCategoryPersonaLegacyMigration(shared);
    final selected = await migration.claim(_accountA);
    await shared.setString(_legacyKey, jsonEncode({'greetingsEnabled': true}));
    expect(await migration.claim(_accountB), isNull);
    expect((await migration.claim(_accountA))!.greetings, isFalse);
    await store().write(selected!);
    final preferences = await service();
    await preferences.bindPersonaMemory(store());
    expect(preferences.state.value.greetingsEnabled, isFalse);
    expect(await migration.claim(_accountA), isNull);
    expect(await migration.claim(_accountB), isNull);
    final journal =
        jsonDecode(
              shared.getString(
                ProactiveCategoryPersonaLegacyMigration.journalKey,
              )!,
            )
            as Map;
    expect(journal.containsKey('payload'), isFalse);
  });

  test(
    'production bootstrap is strict and the account drain fences categories',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source,
        contains('NotificationPreferencesService(requirePersonaMemory: true)'),
      );
      expect(source, contains('SembastProactiveCategoryPersonaMemoryStore('));
      expect(
        source,
        contains('accountScopeDigest: accountScope.accountDigest'),
      );
      expect(source, contains("'persona_proactive_categories'"));
      expect(source, contains('?.deactivatePersonaMemoryAndDrain()'));
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))) {
        if (file.path.endsWith('/notification_preferences_service.dart')) {
          continue;
        }
        expect(
          file.readAsStringSync(),
          isNot(contains('NotificationPreferencesService.forTesting(')),
          reason: file.path,
        );
      }
    },
  );
}

final class _HeldStore implements ProactiveCategoryPersonaMemoryStore {
  _HeldStore(this.accountScopeDigest);
  @override
  final String accountScopeDigest;
  ProactiveCategoryPersonaMemory? value;
  bool failNext = false;
  int writeCount = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();

  @override
  Future<ProactiveCategoryPersonaMemory?> read() async {
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    return value;
  }

  @override
  Future<void> write(ProactiveCategoryPersonaMemory next) async {
    writeCount++;
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('write failed');
    }
    value = next;
  }
}
