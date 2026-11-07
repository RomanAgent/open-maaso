import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/offline/offline_models.dart';
import 'package:maaso/src/offline/offline_samples.dart';
import 'package:maaso/src/offline/offline_store.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

OfflineWork work(String id, {String html = '<html>local content</html>'}) =>
    OfflineWork(
      id: id,
      title: 'Local $id',
      kind: OfflineWorkKind.applet,
      html: html,
      createdAt: DateTime.utc(2026, 11, 7),
      updatedAt: DateTime.utc(2026, 11, 7),
    );

OfflineMessage message(String id) => OfflineMessage(
  id: id,
  role: 'user',
  text: 'An offline message',
  createdAt: DateTime.utc(2026, 11, 7),
);

OfflineCreationTask task(
  String id, {
  OfflineTaskStatus status = OfflineTaskStatus.queued,
  String errorCode = '',
  List<String> results = const [],
}) => OfflineCreationTask(
  id: id,
  kind: OfflineWorkKind.applet,
  request: 'Make a local checklist',
  status: status,
  createdAt: DateTime.utc(2026, 11, 7),
  updatedAt: DateTime.utc(2026, 11, 7),
  resultWorkIds: results,
  errorCode: errorCode,
);

void main() {
  late OfflineStore store;
  var counter = 0;

  setUp(() async {
    store = await OfflineStore.open(
      factory: databaseFactoryMemory,
      path: 'offline-store-${counter++}.db',
      seedSamples: false,
    );
  });
  tearDown(() => store.close());

  test(
    'local demo login needs no account server and defaults to no provider',
    () async {
      expect(await store.isLoggedIn(), false);
      expect(await store.login(username: 'test', password: 'wrong'), false);
      expect(await store.isLoggedIn(), false);
      expect(
        await store.login(
          username: OfflineStore.demoUsername,
          password: OfflineStore.demoPassword,
        ),
        true,
      );
      expect(await store.isLoggedIn(), true);
      final settings = await store.readSettings();
      expect(settings.providerEnabled, false);
      expect(settings.companionEnabled, false);
      expect(settings.ttsEnabled, true);
    },
  );

  test(
    'native disk reopen restores session, records, settings, and isolated state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'open-maaso-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/state.db';
      final first = await OfflineStore.open(
        factory: databaseFactoryIo,
        path: path,
        seedSamples: false,
      );
      await first.login(username: 'test', password: 'test123456');
      await first.saveProfile(
        const OfflineProfile(
          name: 'Local user',
          agentName: 'Buddy',
          persona: 'Brief replies',
        ),
      );
      await first.saveSettings(
        const OfflineSettings(
          providerId: 'custom',
          baseUrl: 'https://example.com/v1',
          model: 'example-model',
        ),
      );
      await first.upsertWork(work('work-one'));
      await first.upsertWork(work('work-two'));
      await first.saveWorkState('work-one', {'tasks': '["first"]'});
      await first.saveWorkState('work-two', {'tasks': '["second"]'});
      await first.appendMessage(message('message-one'));
      await first.saveMemories(['Prefers short replies.']);
      await first.close();

      final reopened = await OfflineStore.open(
        factory: databaseFactoryIo,
        path: path,
      );
      addTearDown(reopened.close);
      expect(await reopened.isLoggedIn(), true);
      expect((await reopened.readProfile()).agentName, 'Buddy');
      expect((await reopened.readSettings()).model, 'example-model');
      expect((await reopened.listWorks()).length, 2);
      expect(await reopened.readWorkState('work-one'), {'tasks': '["first"]'});
      expect(await reopened.readWorkState('work-two'), {'tasks': '["second"]'});
      expect((await reopened.listMessages()).single.text, 'An offline message');
      expect(await reopened.listMemories(), ['Prefers short replies.']);
    },
  );

  test(
    'starter games and applet seed only once and have no remote resources',
    () async {
      final path = 'offline-seeded-${counter++}.db';
      final seeded = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      final samples = await seeded.listWorks();
      expect(samples.length, 3);
      expect(samples.where((w) => w.kind == OfflineWorkKind.game).length, 2);
      for (final sample in samples) {
        expect(sample.html.toLowerCase(), contains('<script>'));
        expect(
          RegExp(
            r'https?://|<script[^>]+src=|<link[^>]+href=',
          ).hasMatch(sample.html),
          false,
        );
        expect(sample.html, contains('<button'));
      }
      await seeded.deleteWork('sample-snake');
      await seeded.close();
      final reopened = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(reopened.close);
      expect((await reopened.listWorks()).length, 2);
      expect(await reopened.getWork('sample-snake'), isNull);
      expect(offlineSampleWorks().map((w) => w.id).toSet().length, 3);
    },
  );

  test(
    'logout keeps local data and deleting a work clears only its state',
    () async {
      await store.login(username: 'test', password: 'test123456');
      await store.upsertWork(work('first'));
      await store.upsertWork(work('second'));
      await store.saveWorkState('first', {'progress': '3'});
      await store.saveWorkState('second', {'progress': '9'});
      await store.appendMessage(message('one'));
      await store.logout();
      expect(await store.isLoggedIn(), false);
      expect((await store.listMessages()).length, 1);
      await store.deleteWork('first');
      expect(await store.readWorkState('first'), isEmpty);
      expect(await store.readWorkState('second'), {'progress': '9'});
      await expectLater(
        store.saveWorkState('first', {'progress': '4'}),
        throwsFormatException,
      );
    },
  );

  test(
    'account reset clears every owned record and does not reseed on reopen',
    () async {
      final path = 'offline-reset-${counter++}.db';
      final owned = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      await owned.login(username: 'test', password: 'test123456');
      await owned.saveProfile(const OfflineProfile(agentName: 'Previous'));
      await owned.appendMessage(message('old-message'));
      await owned.saveMemories(['Old memory']);
      await owned.saveWorkState('sample-todo', {'tasks': '["old"]'});
      await owned.deleteAccount();
      await owned.close();
      final reopened = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(reopened.close);
      expect(await reopened.isLoggedIn(), false);
      expect(await reopened.listWorks(), isEmpty);
      expect(await reopened.listMessages(), isEmpty);
      expect(await reopened.listMemories(), isEmpty);
      expect(await reopened.readWorkState('sample-todo'), isEmpty);
      expect((await reopened.readProfile()).agentName, 'Maaso');
    },
  );

  test(
    'backup roundtrip preserves content and work state but cannot enable network or login',
    () async {
      await store.login(username: 'test', password: 'test123456');
      await store.upsertWork(work('todo'));
      await store.saveWorkState('todo', {'tasks': '[{"done":true}]'});
      await store.appendMessage(message('chat-one'));
      await store.saveMemories(['A local memory']);
      await store.saveSettings(
        const OfflineSettings(
          providerEnabled: true,
          baseUrl: 'https://example.com/v1',
          model: 'example-model',
        ),
      );
      final backup = await store.exportJson();
      final decoded = jsonDecode(backup) as Map;
      expect(decoded.containsKey('loggedIn'), false);
      expect((decoded['settings'] as Map).containsKey('apiKey'), false);
      final restored = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: 'restore-${counter++}.db',
        seedSamples: false,
      );
      addTearDown(restored.close);
      await restored.importJson(backup, replace: true);
      expect(await restored.isLoggedIn(), false);
      expect((await restored.readSettings()).providerEnabled, false);
      expect((await restored.readSettings()).baseUrl, 'https://example.com/v1');
      expect((await restored.listWorks()).single.html, work('todo').html);
      expect(await restored.readWorkState('todo'), {
        'tasks': '[{"done":true}]',
      });
      expect(await restored.listMemories(), ['A local memory']);
      expect((await restored.listMessages()).single.id, 'chat-one');
    },
  );

  test(
    'invalid backup validation is all-or-nothing even for replacement',
    () async {
      await store.upsertWork(work('kept'));
      await store.saveWorkState('kept', {'value': 'preserved'});
      await store.saveProfile(const OfflineProfile(name: 'Kept profile'));
      final backup =
          jsonDecode(await store.exportJson()) as Map<String, dynamic>;
      backup['works'] = [
        work('replacement').toJson(),
        {'id': 'broken'},
      ];
      await expectLater(
        store.importJson(jsonEncode(backup), replace: true),
        throwsFormatException,
      );
      expect((await store.listWorks()).single.id, 'kept');
      expect(await store.readWorkState('kept'), {'value': 'preserved'});
      expect((await store.readProfile()).name, 'Kept profile');
    },
  );

  test(
    'backup rejects credential/session fields, duplicate IDs and orphan app state',
    () async {
      final original =
          jsonDecode(await store.exportJson()) as Map<String, dynamic>;
      final withKey = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      (withKey['settings'] as Map)['apiKey'] = 'not-a-real-credential';
      await expectLater(
        store.importJson(jsonEncode(withKey)),
        throwsFormatException,
      );
      final withSession = {...original, 'loggedIn': true};
      await expectLater(
        store.importJson(jsonEncode(withSession)),
        throwsFormatException,
      );
      final duplicates = {
        ...original,
        'works': [work('same').toJson(), work('same').toJson()],
      };
      await expectLater(
        store.importJson(jsonEncode(duplicates)),
        throwsFormatException,
      );
      final orphan = {
        ...original,
        'workStates': {
          'missing': {'key': 'value'},
        },
      };
      await expectLater(
        store.importJson(jsonEncode(orphan)),
        throwsFormatException,
      );
      expect(await store.listWorks(), isEmpty);
    },
  );

  test(
    'state, HTML, record count and URL bounds fail without partial writes',
    () async {
      await store.upsertWork(work('valid'));
      await store.saveWorkState('valid', {'key': 'kept'});
      await expectLater(
        store.saveWorkState('valid', {'huge': 'x' * 65537}),
        throwsFormatException,
      );
      await expectLater(
        store.saveWorkState('valid', {
          for (var i = 0; i < 129; i++) 'k$i': 'v',
        }),
        throwsFormatException,
      );
      await expectLater(
        store.saveWorkState('valid', {
          for (var i = 0; i < 5; i++) 'k$i': 'x' * 60000,
        }),
        throwsFormatException,
      );
      expect(await store.readWorkState('valid'), {'key': 'kept'});
      await expectLater(
        store.upsertWork(
          work('oversized', html: 'x' * (OfflineWork.maxHtmlBytes + 1)),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.saveSettings(
          const OfflineSettings(baseUrl: 'https://user:pass@example.com/v1'),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.saveSettings(
          const OfflineSettings(baseUrl: 'https://example.com/v1?key=example'),
        ),
        throwsFormatException,
      );
      final backup =
          jsonDecode(await store.exportJson()) as Map<String, dynamic>;
      backup['works'] = [
        for (var i = 0; i < 251; i++) work('work-$i').toJson(),
      ];
      await expectLater(
        store.importJson(jsonEncode(backup)),
        throwsFormatException,
      );
      expect((await store.listWorks()).single.id, 'valid');
    },
  );

  test(
    'message retries are idempotent and conflicting content is rejected',
    () async {
      await store.appendMessage(message('same'));
      await store.appendMessage(message('same'));
      expect((await store.listMessages()).length, 1);
      await expectLater(
        store.appendMessage(
          OfflineMessage(
            id: 'same',
            role: 'assistant',
            text: 'different',
            createdAt: DateTime.utc(2026, 11, 7),
          ),
        ),
        throwsFormatException,
      );
      expect((await store.listMessages()).single.role, 'user');
      await store.clearMessages();
      expect(await store.listMessages(), isEmpty);
    },
  );

  test(
    'future schema is rejected instead of overwriting existing data',
    () async {
      final path = 'future-schema-${counter++}.db';
      final database = await databaseFactoryMemory.openDatabase(path);
      await StoreRef<String, Object?>(
        'offline_meta',
      ).record('schemaVersion').put(database, 99);
      await database.close();
      await expectLater(
        OfflineStore.open(factory: databaseFactoryMemory, path: path),
        throwsFormatException,
      );
      final checked = await databaseFactoryMemory.openDatabase(path);
      expect(
        await StoreRef<String, Object?>(
          'offline_meta',
        ).record('schemaVersion').get(checked),
        99,
      );
      await checked.close();
    },
  );

  test(
    'generated work batches validate all items and revoke atomically',
    () async {
      await store.upsertWork(work('kept'));
      final invalid = work('invalid', html: '');
      await expectLater(
        store.upsertWorks([work('first'), invalid]),
        throwsFormatException,
      );
      expect((await store.listWorks()).map((w) => w.id), ['kept']);
      var checks = 0;
      await expectLater(
        store.upsertWorks([
          work('first'),
          work('second'),
        ], mayWrite: () => ++checks < 3),
        throwsStateError,
      );
      expect((await store.listWorks()).map((w) => w.id), ['kept']);
      await store.upsertWorks([
        work('first'),
        work('second'),
      ], mayWrite: () => true);
      expect((await store.listWorks()).map((w) => w.id).toSet(), {
        'kept',
        'first',
        'second',
      });
    },
  );

  test(
    'message transaction checks cancellation before and after writes',
    () async {
      await expectLater(
        store.appendMessage(message('blocked'), mayWrite: () => false),
        throwsStateError,
      );
      expect(await store.listMessages(), isEmpty);
      var checks = 0;
      await expectLater(
        store.appendMessage(message('revoked'), mayWrite: () => ++checks < 3),
        throwsStateError,
      );
      expect(await store.listMessages(), isEmpty);
      await store.appendMessage(message('allowed'), mayWrite: () => true);
      expect((await store.listMessages()).single.id, 'allowed');
    },
  );

  test(
    'state reads and backups drain queued writes before observing data',
    () async {
      await store.upsertWork(work('tasks'));
      final first = store.saveWorkState('tasks', {'tasks': 'first'});
      final second = store.saveWorkState('tasks', {
        'tasks': 'second',
        '': 'empty key',
        '__proto__': 'ordinary storage value',
      });
      final latest = await store.readWorkState('tasks');
      expect(latest['tasks'], 'second');
      expect(latest[''], 'empty key');
      expect(latest['__proto__'], 'ordinary storage value');
      await Future.wait([first, second]);
      final last = store.saveWorkState('tasks', {'tasks': 'export latest'});
      final backup = jsonDecode(await store.exportJson()) as Map;
      expect((backup['workStates'] as Map)['tasks'], {
        'tasks': 'export latest',
      });
      await last;
    },
  );

  test(
    'closing and reopening waits for accepted pending app state writes',
    () async {
      final path = 'state-drain-${counter++}.db';
      final first = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
        seedSamples: false,
      );
      await first.upsertWork(work('tasks'));
      final a = first.saveWorkState('tasks', {'progress': 'one'});
      final b = first.saveWorkState('tasks', {'progress': 'two'});
      await first.close();
      await Future.wait([a, b]);
      final reopened = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(reopened.close);
      expect(await reopened.readWorkState('tasks'), {'progress': 'two'});
    },
  );

  test(
    'deletion revokes pending state writes before a work ID can be reused',
    () async {
      await store.upsertWork(work('reused'));
      final write = store.saveWorkState('reused', {'old': 'private state'});
      final expectedFailure = expectLater(write, throwsStateError);
      await store.deleteWork('reused');
      await store.upsertWork(work('reused'));
      await expectedFailure;
      expect(await store.readWorkState('reused'), isEmpty);
    },
  );

  test(
    'journal recovery marks pending tasks interrupted without retrying',
    () async {
      final path = 'task-recovery-${counter++}.db';
      final first = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
        seedSamples: false,
      );
      await first.upsertTask(task('queued'));
      await first.upsertTask(
        task('running', status: OfflineTaskStatus.running),
      );
      await first.upsertTask(
        task(
          'done',
          status: OfflineTaskStatus.completed,
          results: ['saved-work'],
        ),
      );
      await first.close();
      final reopened = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(reopened.close);
      final tasks = {for (final t in await reopened.listTasks()) t.id: t};
      expect(tasks['queued']!.status, OfflineTaskStatus.failed);
      expect(tasks['running']!.errorCode, 'interrupted');
      expect(tasks['done']!.status, OfflineTaskStatus.completed);
      expect(tasks['done']!.resultWorkIds, ['saved-work']);
      expect(await reopened.listWorks(), isEmpty);
    },
  );

  test(
    'schema one migration preserves records and supports old backups',
    () async {
      final path = 'schema-one-${counter++}.db';
      final database = await databaseFactoryMemory.openDatabase(path);
      await StoreRef<String, Object?>(
        'offline_meta',
      ).record('schemaVersion').put(database, 1);
      await StoreRef<String, Object?>(
        'offline_meta',
      ).record('loggedIn').put(database, true);
      await stringMapStoreFactory
          .store('offline_works')
          .record('existing')
          .put(database, work('existing').toJson());
      await database.close();
      final migrated = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: path,
      );
      addTearDown(migrated.close);
      expect(await migrated.isLoggedIn(), true);
      expect((await migrated.listWorks()).single.id, 'existing');
      expect(await migrated.listTasks(), isEmpty);
      final backup =
          jsonDecode(await migrated.exportJson()) as Map<String, dynamic>;
      expect(backup['version'], 3);
      backup['version'] = 1;
      backup.remove('tasks');
      backup.remove('reminders');
      backup.remove('skills');
      await store.importJson(jsonEncode(backup));
      expect((await store.listWorks()).single.id, 'existing');
      expect(await store.listTasks(), isEmpty);
      expect(await store.isLoggedIn(), false);
    },
  );

  test(
    'task backups preserve outcomes and reject arbitrary errors atomically',
    () async {
      await store.upsertTask(
        task(
          'completed',
          status: OfflineTaskStatus.completed,
          results: ['deleted-historical-work'],
        ),
      );
      await store.upsertTask(task('pending'));
      final backup = await store.exportJson();
      final restored = await OfflineStore.open(
        factory: databaseFactoryMemory,
        path: 'tasks-restore-${counter++}',
        seedSamples: false,
      );
      addTearDown(restored.close);
      await restored.importJson(backup);
      final tasks = {for (final t in await restored.listTasks()) t.id: t};
      expect(tasks['completed']!.resultWorkIds, ['deleted-historical-work']);
      expect(tasks['pending']!.errorCode, 'interrupted');
      final bad = jsonDecode(backup) as Map<String, dynamic>;
      (bad['tasks'] as List).first['errorCode'] = 'raw provider diagnostics';
      await expectLater(
        restored.importJson(jsonEncode(bad), replace: true),
        throwsFormatException,
      );
      expect((await restored.listTasks()).length, 2);
      await expectLater(
        store.upsertTask(
          task('invalid-success', status: OfflineTaskStatus.completed),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.upsertTask(
          task('invalid-error', status: OfflineTaskStatus.failed),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.upsertTask(
          task(
            'cancelled',
            status: OfflineTaskStatus.cancelled,
            errorCode: 'cancelled',
          ),
          mayWrite: () => false,
        ),
        throwsStateError,
      );
      await restored.deleteAccount();
      expect(await restored.listTasks(), isEmpty);
    },
  );

  test(
    'work outputs and completion receipt commit or roll back together',
    () async {
      final queued = task('create-one');
      await store.upsertTask(queued);
      final completion = queued.copyWith(
        status: OfflineTaskStatus.completed,
        resultWorkIds: ['output'],
      );
      var checks = 0;
      await expectLater(
        store.upsertWorks(
          [work('output')],
          completedTask: completion,
          mayWrite: () => ++checks < 4,
        ),
        throwsStateError,
      );
      expect(await store.listWorks(), isEmpty);
      expect((await store.listTasks()).single.status, OfflineTaskStatus.queued);
      await store.upsertWorks([work('output')], completedTask: completion);
      expect((await store.listWorks()).single.id, 'output');
      expect(
        (await store.listTasks()).single.status,
        OfflineTaskStatus.completed,
      );
      await expectLater(
        store.upsertWorks([work('different')], completedTask: completion),
        throwsFormatException,
      );
      await store.clearTasks();
      expect(await store.listTasks(), isEmpty);
      expect((await store.listWorks()).single.id, 'output');
    },
  );
}
