import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  group('AccountStorageScope', () {
    test('derives stable account and agent namespaces', () {
      final first = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'Account-Case-Sensitive',
      );
      final second = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'Account-Case-Sensitive',
      );
      final firstAgent = first.agent('Agent-Primary');
      final secondAgent = second.agent('Agent-Primary');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.accountDigest, second.accountDigest);
      expect(first.accountDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(first.databaseName, 'maaso.account.v1.${first.accountDigest}.db');
      expect(first.webDatabaseName, first.databaseName);
      expect(firstAgent, secondAgent);
      expect(firstAgent.agentDigest, secondAgent.agentDigest);
      expect(firstAgent.agentDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
    });

    test('normalizes boundary whitespace but preserves opaque ID case', () {
      final normalized = AccountStorageScope(
        environmentKey: ' test ',
        accountUuid: ' Account-A ',
      );
      final plain = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'Account-A',
      );
      final differentCase = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );

      expect(normalized, plain);
      expect(normalized.environmentKey, 'test');
      expect(normalized.accountUuid, 'Account-A');
      expect(differentCase.accountDigest, isNot(plain.accountDigest));
    });

    test('isolates accounts, environments, and agent children', () {
      final testAccountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final testAccountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      final prodAccountA = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-a',
      );
      final agentA = testAccountA.agent('agent-a');
      final agentB = testAccountA.agent('agent-b');
      final accountBAgentA = testAccountB.agent('agent-a');

      expect(<String>{
        testAccountA.accountDigest,
        testAccountB.accountDigest,
        prodAccountA.accountDigest,
      }, hasLength(3));
      expect(<String>{
        testAccountA.databaseName,
        testAccountB.databaseName,
        prodAccountA.databaseName,
      }, hasLength(3));
      expect(agentA.agentDigest, isNot(agentB.agentDigest));
      expect(agentA.agentDigest, isNot(accountBAgentA.agentDigest));
      expect(
        agentA.nativeRelativeDirectory,
        isNot(agentB.nativeRelativeDirectory),
      );
      expect(agentA.webKeyPrefix, isNot(agentB.webKeyPrefix));
    });

    test('never exposes raw IDs in generated names or relative paths', () {
      const rawAccountId = 'Raw/Account:UUID@example.test';
      const rawAgentId = r'Raw\Agent/ID:@example.test';
      final account = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: rawAccountId,
      );
      final agent = account.agent(rawAgentId);
      final generatedNames = <String>[
        account.storageNamespace,
        account.databaseName,
        account.webDatabaseName,
        account.webKeyPrefix,
        account.nativeRelativeDirectory,
        account.nativeDatabaseRelativePath,
        ...account.accountDirectorySegments,
        ...account.nativeDatabasePathSegments,
        agent.storageNamespace,
        agent.webKeyPrefix,
        agent.nativeRelativeDirectory,
        ...agent.agentDirectorySegments,
      ];

      for (final generatedName in generatedNames) {
        expect(generatedName, isNot(contains(rawAccountId)));
        expect(generatedName, isNot(contains(rawAgentId)));
      }
    });

    test('returns safe native path segments and database basename', () {
      final account = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account/with:path-separators',
      );
      final agent = account.agent(r'agent\with/more:separators');
      final safeSegment = RegExp(r'^[a-z0-9][a-z0-9._-]*$');

      expect(
        account.accountDirectorySegments,
        everyElement(matches(safeSegment)),
      );
      expect(agent.agentDirectorySegments, everyElement(matches(safeSegment)));
      expect(account.databaseName, matches(safeSegment));
      expect(account.webKeyPrefix, matches(safeSegment));
      expect(agent.webKeyPrefix, matches(safeSegment));
      expect(
        account.nativeDatabasePathSegments.last,
        AccountStorageScope.nativeDatabaseFileName,
      );
      expect(
        account.nativeDatabaseRelativePath.split('/').last,
        AccountStorageScope.nativeDatabaseFileName,
      );
      expect(account.nativeDatabaseRelativePath, isNot(contains('..')));
      expect(agent.nativeRelativeDirectory, isNot(contains('..')));
    });

    test('rejects unsupported environments and invalid account IDs', () {
      final overlong = List<String>.filled(
        AccountStorageScope.maxIdentityLength + 1,
        'a',
      ).join();

      for (final environmentKey in <String>['', 'staging', 'test\u0000']) {
        expect(
          () => AccountStorageScope(
            environmentKey: environmentKey,
            accountUuid: 'account-a',
          ),
          throwsArgumentError,
        );
      }
      for (final accountUuid in <String>[
        '',
        '   ',
        'account\u0000id',
        'account\u001fid',
        'account\u007fid',
        'account\u009fid',
        overlong,
      ]) {
        expect(
          () => AccountStorageScope(
            environmentKey: 'test',
            accountUuid: accountUuid,
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects invalid agent IDs', () {
      final account = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final overlong = List<String>.filled(
        AccountStorageScope.maxIdentityLength + 1,
        'a',
      ).join();

      for (final agentId in <String>[
        '',
        '   ',
        'agent\u0000id',
        'agent\u001fid',
        'agent\u007fid',
        'agent\u009fid',
        overlong,
      ]) {
        expect(() => account.agent(agentId), throwsArgumentError);
      }
    });

    test('keeps unowned legacy names quarantined from scoped APIs', () {
      final account = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'account-a',
      );
      final agent = account.agent('agent-a');
      final scopedNames = <String>{
        account.databaseName,
        account.webDatabaseName,
        account.webKeyPrefix,
        account.nativeRelativeDirectory,
        account.nativeDatabaseRelativePath,
        agent.webKeyPrefix,
        agent.nativeRelativeDirectory,
      };

      expect(LegacyAccountStorageQuarantine.automaticClaimAllowed, isFalse);
      expect(LegacyAccountStorageQuarantine.ownership, 'unclaimed');
      expect(LegacyAccountStorageQuarantine.databaseName, 'maaso.db');
      expect(
        LegacyAccountStorageQuarantine.documentNames,
        unorderedEquals(<String>{'soul.md', 'master.md', 'world.md'}),
      );
      expect(
        LegacyAccountStorageQuarantine.webMarkdownKeyPrefix,
        'maaso.markdown.',
      );
      expect(
        scopedNames,
        isNot(contains(LegacyAccountStorageQuarantine.databaseName)),
      );
      expect(
        account.webKeyPrefix,
        isNot(startsWith(LegacyAccountStorageQuarantine.webMarkdownKeyPrefix)),
      );
      expect(
        agent.webKeyPrefix,
        isNot(startsWith(LegacyAccountStorageQuarantine.webMarkdownKeyPrefix)),
      );
    });
  });

  group('AccountStorageScopeService', () {
    test('requires explicit unmount before switching accounts', () async {
      final service = AccountStorageScopeService();
      final accountA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final equivalentA = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final accountB = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );

      final mountA = service.mount(accountA);
      final invalidated = expectLater(mountA.whenInvalidated, completes);
      final sameMount = service.mount(equivalentA);

      expect(sameMount, same(mountA));
      expect(service.activeScope, accountA);
      expect(service.isCurrent(mountA), isTrue);
      expect(() => service.mount(accountB), throwsStateError);

      service.unmount(mountA);
      await invalidated;

      expect(service.activeScope, isNull);
      expect(service.isCurrent(mountA), isFalse);
      expect(() => service.requireCurrent(mountA), throwsStateError);

      final mountB = service.mount(accountB);
      expect(mountB.generation, greaterThan(mountA.generation));
      expect(service.activeScope, accountB);
      expect(() => service.unmount(mountA), throwsStateError);
    });

    test(
      'all sensitive UI holds must drain before a replacement mount',
      () async {
        final service = AccountStorageScopeService();
        final accountA = AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'account-a',
        );
        final accountB = AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'account-b',
        );
        await service.whenBoundaryReleased;

        final mountA = service.mount(accountA);
        final first = service.acquireBoundaryHold(mountA);
        final second = service.acquireBoundaryHold(mountA);
        var drained = false;
        final drain = service.whenBoundaryReleased.then((_) => drained = true);

        service.unmount(mountA);
        expect(
          () => service.mount(accountB),
          throwsA(isA<AccountStorageScopeBoundaryPendingException>()),
        );

        first.release();
        first.release();
        await Future<void>.delayed(Duration.zero);
        expect(first.isReleased, isTrue);
        expect(drained, isFalse);
        expect(
          () => service.mount(accountB),
          throwsA(isA<AccountStorageScopeBoundaryPendingException>()),
        );

        second.release();
        await drain;
        expect(drained, isTrue);
        expect(service.mount(accountB).scope, accountB);
      },
    );
  });

  test('derived database names isolate account records in memory', () async {
    final accountA = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'memory-account-a',
    );
    final accountB = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'memory-account-b',
    );
    addTearDown(() async {
      await databaseFactoryMemory.deleteDatabase(accountA.webDatabaseName);
      await databaseFactoryMemory.deleteDatabase(accountB.webDatabaseName);
    });
    await databaseFactoryMemory.deleteDatabase(accountA.webDatabaseName);
    await databaseFactoryMemory.deleteDatabase(accountB.webDatabaseName);

    await _withMemoryDatabase(accountA.webDatabaseName, (database) async {
      await database.saveAgentPresenceState('self', <String, Object?>{
        'owner': 'account-a',
      });
    });
    await _withMemoryDatabase(accountB.webDatabaseName, (database) async {
      expect(await database.getAgentPresenceState('self'), isNull);
      await database.saveAgentPresenceState('self', <String, Object?>{
        'owner': 'account-b',
      });
    });
    await _withMemoryDatabase(accountA.webDatabaseName, (database) async {
      final restored = await database.getAgentPresenceState('self');
      expect(restored?['owner'], 'account-a');
    });
  });

  test('DBService close is idempotent and rejects later access', () async {
    final path = 'close-${DateTime.now().microsecondsSinceEpoch}.db';
    addTearDown(() => databaseFactoryMemory.deleteDatabase(path));

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    await database.saveAgentPresenceState('self', <String, Object?>{
      'owner': 'account-a',
    });

    final firstClose = database.close();
    final secondClose = database.close();

    expect(secondClose, same(firstClose));
    await firstClose;
    expect(() => database.raw, throwsStateError);
    await expectLater(
      database.saveAgentPresenceState('self', <String, Object?>{
        'owner': 'late-write',
      }),
      throwsStateError,
    );
  });

  test('DBService close can retry after a transient close failure', () async {
    final path = 'close-retry-${DateTime.now().microsecondsSinceEpoch}.db';
    var closeAttempts = 0;
    final database = await DBService(
      closeDatabase: (handle) async {
        closeAttempts++;
        if (closeAttempts == 1) throw StateError('transient close failure');
        await handle.close();
      },
    ).init(factory: databaseFactoryMemory, path: path);
    addTearDown(() async {
      if (closeAttempts < 2) {
        try {
          await database.close();
        } catch (_) {}
      }
      await databaseFactoryMemory.deleteDatabase(path);
    });

    await expectLater(database.close(), throwsStateError);
    expect(closeAttempts, 1);
    expect(() => database.raw, throwsStateError);

    await database.close();
    expect(closeAttempts, 2);
    await database.close();
    expect(closeAttempts, 2);
  });

  test(
    'an injected factory keeps its explicit path when scope is present',
    () async {
      final account = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'factory-account',
      );
      final explicitPath =
          'explicit-${DateTime.now().microsecondsSinceEpoch}.db';
      addTearDown(() async {
        await databaseFactoryMemory.deleteDatabase(explicitPath);
        await databaseFactoryMemory.deleteDatabase(account.databaseName);
      });

      final scoped = await DBService().init(
        factory: databaseFactoryMemory,
        path: explicitPath,
        scope: account,
      );
      await scoped.saveAgentPresenceState('self', <String, Object?>{
        'owner': 'explicit-path',
      });
      await scoped.close();

      await _withMemoryDatabase(explicitPath, (database) async {
        expect(await database.getAgentPresenceState('self'), <String, Object?>{
          'owner': 'explicit-path',
        });
      });
      await _withMemoryDatabase(account.databaseName, (database) async {
        expect(await database.getAgentPresenceState('self'), isNull);
      });
    },
  );
}

Future<T> _withMemoryDatabase<T>(
  String path,
  Future<T> Function(DBService database) action,
) async {
  final database = await DBService().init(
    factory: databaseFactoryMemory,
    path: path,
  );
  try {
    return await action(database);
  } finally {
    await database.close();
  }
}
