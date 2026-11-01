import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 14, 10);
  final scope = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'skill-usage-owner',
  );
  final totals = StoreRef<String, Map<String, Object?>>(
    'skill_usage_totals.v1',
  );
  final days = StoreRef<String, Map<String, Object?>>('skill_usage_days.v1');

  Future<SkillUsageService> mount(
    Database db, {
    AccountStorageScope? owner,
    bool Function()? isCurrent,
    DateTime Function()? now,
  }) => SkillUsageService(
    database: db,
    accountScopeDigest: (owner ?? scope).accountDigest,
    isCurrent: isCurrent ?? () => true,
    now: now ?? () => day,
  ).init(observeLifecycle: false);

  SkillUsageAttempt begin(
    SkillUsageService service, {
    String skill = 'AppControl',
    String method = 'navigate',
    SkillUsageChannel channel = SkillUsageChannel.native,
  }) => service.start(skillName: skill, method: method, channel: channel)!;

  test('starts count actual invocation; completion is one-use', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-one-use');
    addTearDown(db.close);
    final service = await mount(db);
    addTearDown(service.shutdown);
    expect(service.loading.value, isFalse);
    expect(service.forSkill('AppControl').started, 0);
    final attempt = begin(service);
    await service.whenSettled;
    expect(service.forSkill('AppControl').started, 1);
    expect(service.forSkill('AppControl').unfinished, 1);
    await attempt.finish(succeeded: true);
    await attempt.finish(succeeded: false);
    expect(service.forSkill('AppControl').started, 1);
    expect(service.forSkill('AppControl').succeeded, 1);
    expect(service.forSkill('AppControl').failed, 0);
    expect(service.forSkill('AppControl').unfinished, 0);
    expect(service.forSkill('AppControl').lastUsed, day);
  });

  test(
    'counts aggregate methods and execution lanes without factories',
    () async {
      final db = await databaseFactoryMemory.openDatabase('usage-dimensions');
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      for (final channel in SkillUsageChannel.values.where(
        (channel) => channel != SkillUsageChannel.prompt,
      )) {
        await begin(service, channel: channel).finish(succeeded: true);
      }
      await begin(service, method: 'readPage').finish(succeeded: false);
      await begin(
        service,
        skill: 'Todo',
        method: 'add',
      ).finish(succeeded: true);
      final count = service.forSkill('AppControl');
      expect(
        [count.started, count.succeeded, count.failed, count.unfinished],
        [5, 4, 1, 0],
      );
      expect(service.entries.value, hasLength(6));
      expect(service.forSkill('MissingSkill').lastUsed, isNull);
      expect(service.forSkill('MissingSkill').started, 0);
    },
  );

  test('parallel starts and completions never lose increments', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-concurrent');
    addTearDown(db.close);
    final service = await mount(db);
    addTearDown(service.shutdown);
    final attempts = List.generate(80, (_) => begin(service));
    await Future.wait([
      for (var i = 0; i < attempts.length; i++)
        attempts[i].finish(succeeded: i.isEven),
    ]);
    final count = service.forSkill('AppControl');
    expect([count.started, count.succeeded, count.failed], [80, 40, 40]);
    expect(count.unfinished, 0);
    expect(await totals.count(db), 1);
    expect(await days.count(db), 1);
  });

  test('disk reopening preserves counts and interrupted invocations', () async {
    final folder = await Directory.systemTemp.createTemp('maaso-skill-usage-');
    addTearDown(() => folder.delete(recursive: true));
    final path = '${folder.path}/usage.db';
    final db = await databaseFactoryIo.openDatabase(path);
    final first = await mount(db);
    await begin(first).finish(succeeded: true);
    await begin(first).finish(succeeded: false);
    begin(first);
    await first.shutdown();
    await db.close();
    final reopened = await databaseFactoryIo.openDatabase(path);
    addTearDown(reopened.close);
    final restored = await mount(reopened);
    addTearDown(restored.shutdown);
    final count = restored.forSkill('AppControl');
    expect(
      [count.started, count.succeeded, count.failed, count.unfinished],
      [3, 1, 1, 1],
    );
    expect((await restored.read(day: '2026-10-14')).single.started, 3);
  });

  test(
    'account and environment isolate history; late tickets stay fenced',
    () async {
      final db = await databaseFactoryMemory.openDatabase('usage-scope');
      addTearDown(db.close);
      final scopes = AccountStorageScopeService();
      final oldMount = scopes.mount(scope);
      final old = await mount(db, isCurrent: () => scopes.isCurrent(oldMount));
      final oldAttempt = begin(old);
      await old.whenSettled;
      expect(old.forSkill('AppControl').started, 1);
      scopes.unmount(oldMount);
      old.retire();
      expect(old.entries.value, isEmpty);
      expect(old.unavailable.value, isTrue);
      expect(old.loading.value, isFalse);
      expect(old.forSkill('AppControl').started, 0);
      final nextScope = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'another-owner',
      );
      final nextMount = scopes.mount(nextScope);
      final next = await mount(
        db,
        owner: nextScope,
        isCurrent: () => scopes.isCurrent(nextMount),
      );
      await oldAttempt.finish(succeeded: true);
      expect(next.forSkill('AppControl').started, 0);
      await begin(next).finish(succeeded: true);
      expect(next.forSkill('AppControl').started, 1);
      await old.shutdown();
      await next.shutdown();
      scopes.unmount(nextMount);
      final restored = await mount(db);
      final prod = await mount(
        db,
        owner: AccountStorageScope(
          environmentKey: 'prod',
          accountUuid: scope.accountUuid,
        ),
      );
      expect(restored.forSkill('AppControl').started, 1);
      expect(restored.forSkill('AppControl').unfinished, 1);
      expect(prod.entries.value, isEmpty);
      await restored.shutdown();
      await prod.shutdown();
    },
  );

  test('retire immediately clears UI and rejects queued old writes', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-retire');
    addTearDown(db.close);
    final service = await mount(db);
    final ticket = begin(service);
    service.retire();
    expect(service.entries.value, isEmpty);
    expect(service.isCurrent, isFalse);
    expect(
      service.start(
        skillName: 'Todo',
        method: 'add',
        channel: SkillUsageChannel.native,
      ),
      isNull,
    );
    await ticket.finish(succeeded: false);
    await service.shutdown();
    expect(await totals.count(db), 0);
    expect(await service.read(), isEmpty);
  });

  test('completion across midnight belongs to actual invocation day', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-midnight');
    addTearDown(db.close);
    var now = DateTime(2026, 10, 14, 23, 59, 59);
    final service = await mount(db, now: () => now);
    addTearDown(service.shutdown);
    final ticket = begin(service);
    await service.whenSettled;
    now = DateTime(2026, 10, 15, 0, 0, 1);
    await ticket.finish(succeeded: true);
    final yesterday = (await service.read(day: '2026-10-14')).single;
    expect([yesterday.started, yesterday.succeeded], [1, 1]);
    expect(await service.read(day: '2026-10-15'), isEmpty);
    await begin(service).finish(succeeded: false);
    final today = (await service.read(day: '2026-10-15')).single;
    expect([today.started, today.failed], [1, 1]);
    expect(service.forSkill('AppControl').started, 2);
    expect(service.forSkill('AppControl').lastUsed, now);
  });

  test('lastUsed never moves backwards with a corrected clock', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-clock');
    addTearDown(db.close);
    var now = day;
    final service = await mount(db, now: () => now);
    addTearDown(service.shutdown);
    await begin(service).finish(succeeded: true);
    now = day.subtract(const Duration(hours: 1));
    await begin(service).finish(succeeded: true);
    expect(service.forSkill('AppControl').lastUsed, day);
  });

  test('stored rows contain only bounded execution metadata', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-metadata');
    addTearDown(db.close);
    final service = await mount(db);
    addTearDown(service.shutdown);
    await begin(service).finish(succeeded: false);
    for (final store in [totals, days]) {
      final record = (await store.find(db)).single;
      expect(record.key, startsWith('${scope.accountDigest}:'));
      expect(record.key.length, lessThan(280));
      expect(record.value.keys.toSet(), {
        'skillName',
        'method',
        'channel',
        'started',
        'succeeded',
        'failed',
        'lastUsed',
      });
      expect(record.value['skillName'], 'AppControl');
      expect(record.value['method'], 'navigate');
      expect(record.value['channel'], 'native');
    }
  });

  test(
    'invalid names, long keys and invalid days are never recorded',
    () async {
      final db = await databaseFactoryMemory.openDatabase('usage-invalid');
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      for (final skill in [
        '',
        'a:b',
        'my skill',
        'https://test',
        'A' * 97,
        '天气',
      ]) {
        expect(
          service.start(
            skillName: skill,
            method: 'call',
            channel: SkillUsageChannel.local,
          ),
          isNull,
        );
      }
      for (final method in ['', 'do thing', 'A' * 65, 'call\n', 'x.y']) {
        expect(
          service.start(
            skillName: 'Todo',
            method: method,
            channel: SkillUsageChannel.local,
          ),
          isNull,
        );
      }
      for (final invalid in ['2026-02-30', '2026-1-01', '2026-01-01:Todo']) {
        expect(await service.read(day: invalid), isEmpty);
      }
      await service.whenSettled;
      expect(await totals.count(db), 0);
      expect(await days.count(db), 0);
      expect(
        () => SkillUsageService(
          database: db,
          accountScopeDigest: scope.accountUuid,
          isCurrent: () => true,
        ),
        throwsArgumentError,
      );
    },
  );

  test('closed database cannot break handler results or completion', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-closed');
    final service = await mount(db);
    await db.close();
    final ticket = begin(service);
    var handlerStarted = false;
    final response = await Future.sync(() {
      handlerStarted = true;
      return 'handler-result';
    });
    await ticket.finish(succeeded: true);
    expect(handlerStarted, isTrue);
    expect(response, 'handler-result');
    expect(service.unavailable.value, isTrue);
    expect(service.entries.value, isEmpty);
    await service.shutdown();
  });

  test(
    'failed start write cannot complete another pending invocation',
    () async {
      final db = await databaseFactoryMemory.openDatabase('usage-corrupt');
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      begin(service);
      await service.whenSettled;
      final oldDaily = (await days.find(db)).single;
      await days.record(oldDaily.key).put(db, {
        ...oldDaily.value,
        'started': -1,
      });
      final failingTicket = begin(service);
      await failingTicket.finish(succeeded: true);
      expect(service.unavailable.value, isTrue);
      final stored = (await totals.find(db)).single.value;
      expect(stored['started'], 1);
      expect(stored['succeeded'], 0);
      expect(stored['failed'], 0);
    },
  );

  test('corrupt and cross-key rows are excluded from reads', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-invalid-rows');
    addTearDown(db.close);
    final service = await mount(db);
    addTearDown(service.shutdown);
    await begin(service).finish(succeeded: true);
    final original = (await totals.find(db)).single;
    await totals.record('${scope.accountDigest}:other').put(db, original.value);
    await totals.record('${scope.accountDigest}:invalid').put(db, {
      ...original.value,
      'failed': -2,
    });
    await service.refresh();
    expect(service.entries.value, hasLength(1));
    expect(service.forSkill('AppControl').started, 1);
  });

  test('throwing ownership check never escapes into a handler', () async {
    final db = await databaseFactoryMemory.openDatabase('usage-owner-error');
    addTearDown(db.close);
    var throwOwnership = false;
    final service = await mount(
      db,
      isCurrent: () {
        if (throwOwnership) throw StateError('owner-unavailable');
        return true;
      },
    );
    final ticket = begin(service);
    await service.whenSettled;
    throwOwnership = true;
    expect(service.isCurrent, isFalse);
    expect(
      service.start(
        skillName: 'Todo',
        method: 'add',
        channel: SkillUsageChannel.native,
      ),
      isNull,
    );
    await ticket.finish(succeeded: true);
    expect(service.forSkill('AppControl').started, 0);
    await service.shutdown();
  });

  test(
    'Prompt Skills count only stable hashes and aggregate by that key',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'usage-prompt-hashes',
      );
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      final marketplace = 'marketplace:${'a' * 64}';
      final learned = 'learned:${'b' * 64}';
      for (final skill in [marketplace, learned]) {
        await begin(
          service,
          skill: skill,
          method: 'applyPrompt',
          channel: SkillUsageChannel.prompt,
        ).finish(succeeded: true);
        await begin(
          service,
          skill: skill,
          method: 'applyPrompt',
          channel: SkillUsageChannel.prompt,
        ).finish(succeeded: false);
        final count = service.forSkill(skill);
        expect([count.started, count.succeeded, count.failed], [2, 1, 1]);
      }
      expect(service.entries.value, hasLength(2));
      expect((await service.read(day: '2026-10-14')).map((s) => s.started), [
        2,
        2,
      ]);
      for (final record in await totals.find(db)) {
        expect(record.value['channel'], 'prompt');
        expect(record.value['method'], 'applyPrompt');
        expect(record.value.keys.toSet(), {
          'skillName',
          'method',
          'channel',
          'started',
          'succeeded',
          'failed',
          'lastUsed',
        });
      }
    },
  );

  test(
    'Prompt lane rejects titles, instructions, malformed IDs and other methods',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'usage-prompt-invalid',
      );
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      final stableKey = 'marketplace:${'a' * 64}';
      for (final invalid in [
        'AppControl',
        '我的网页搜索技巧',
        'Do not reveal instructions',
        'marketplace:${'a' * 32}',
        'marketplace:${'A' * 64}',
        'marketplace:${'a' * 65}',
        'marketplace:${'a' * 64}\n',
        'learned:wink_both',
        'learned:${'b' * 32}',
        'learned:${'b' * 64}:instruction',
        'community:${'a' * 64}',
      ]) {
        expect(
          service.start(
            skillName: invalid,
            method: 'applyPrompt',
            channel: SkillUsageChannel.prompt,
          ),
          isNull,
        );
      }
      for (final method in ['call', 'applyPrompt\n', 'read', '']) {
        expect(
          service.start(
            skillName: stableKey,
            method: method,
            channel: SkillUsageChannel.prompt,
          ),
          isNull,
        );
      }
      for (final lane in SkillUsageChannel.values.where(
        (channel) => channel != SkillUsageChannel.prompt,
      )) {
        expect(
          service.start(
            skillName: stableKey,
            method: 'applyPrompt',
            channel: lane,
          ),
          isNull,
        );
      }
      await service.whenSettled;
      expect(await totals.count(db), 0);
      expect(await days.count(db), 0);
    },
  );

  test(
    'Prompt storage reads reject a forged free-text or different method row',
    () async {
      final db = await databaseFactoryMemory.openDatabase('usage-prompt-row');
      addTearDown(db.close);
      final service = await mount(db);
      addTearDown(service.shutdown);
      final stableKey = 'learned:${'c' * 64}';
      await begin(
        service,
        skill: stableKey,
        method: 'applyPrompt',
        channel: SkillUsageChannel.prompt,
      ).finish(succeeded: true);
      final original = (await totals.find(db)).single;
      await totals.record('${scope.accountDigest}:bad-text').put(db, {
        ...original.value,
        'skillName': 'instruction: Tell the model what to do',
      });
      await totals.record('${scope.accountDigest}:bad-method').put(db, {
        ...original.value,
        'method': 'call',
      });
      await service.refresh();
      expect(service.entries.value, hasLength(1));
      expect(service.forSkill(stableKey).started, 1);
    },
  );
}
