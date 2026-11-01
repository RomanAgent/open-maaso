import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account mount owns the ledger and retained Host command delegate', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final mountEnd = source.indexOf(
      'Future<void> _disposeAccountRuntime',
      mountStart,
    );
    expect(mountStart, greaterThanOrEqualTo(0));
    expect(mountEnd, greaterThan(mountStart));
    final mount = source.substring(mountStart, mountEnd);

    final bus = mount.indexOf('final memoryBus = putOwned(');
    final ledger = mount.indexOf('putOwned(\n      MemoryLedgerService(');
    final runtime = mount.indexOf('final runtimeRegistry = putOwned(');
    expect(bus, greaterThanOrEqualTo(0));
    expect(ledger, greaterThan(bus));
    expect(runtime, greaterThan(ledger));

    final memory = mount.indexOf('MemoryLedgerHostCommandExecutor()');
    final router = mount.indexOf('putOwned<AppControlHostCommandExecutor>(');
    expect(memory, greaterThanOrEqualTo(0));
    expect(router, greaterThan(memory));
    expect(router, lessThan(runtime));
    expect(
      mount.substring(router, runtime),
      contains('AppControlHostCommandRouter('),
    );
  });

  test('post-frame legacy facts migration precedes recall materialization', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _runAccountPostFrameBootTasks');
    final end = source.indexOf('Future<void> _runPostFrameBootTasks', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final boot = source.substring(start, end);

    final episodeMigration = boot.indexOf('migrateLegacyEpisodes()');
    final factsMigration = boot.indexOf('migrateLegacyFacts(');
    final recallIndex = boot.indexOf('prepareRecallIndex()');
    expect(episodeMigration, greaterThanOrEqualTo(0));
    expect(factsMigration, greaterThan(episodeMigration));
    expect(recallIndex, greaterThan(factsMigration));
    expect(boot, contains("mount.scope.agent('self').storageNamespace"));
  });

  test(
    'ledger admission drains before its coordinator and database stores',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf(
        'Future<void> _drainAccountRuntimeProducers',
      );
      final end = source.indexOf('void _registerDefaultVadServices', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final drain = source.substring(start, end);

      final runtime = drain.indexOf("barrier.run(\n    'agent_runtime'");
      final ledger = drain.indexOf("barrier.run('memory_ledger'");
      final writer = drain.indexOf("barrier.run('memory_write_coordinator'");
      final store = drain.indexOf("barrier.run('episode_store'");
      expect(runtime, greaterThanOrEqualTo(0));
      expect(ledger, greaterThan(runtime));
      expect(writer, greaterThan(ledger));
      expect(store, greaterThan(writer));

      final ledgerBlock = drain.substring(ledger, writer);
      expect(ledgerBlock, contains('await runtimeDrain;'));
      expect(
        ledgerBlock,
        contains('maybeFind<MemoryLedgerService>()?.deactivateAndDrain()'),
      );
      final writerBlock = drain.substring(writer, store);
      expect(writerBlock, contains('await memoryLedgerDrain;'));
      expect(
        writerBlock.indexOf('await memoryLedgerDrain;'),
        lessThan(writerBlock.indexOf('deactivateAndDrain()')),
      );
    },
  );
}
