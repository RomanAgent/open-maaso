import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/persona_package/data/persona_approval_receipt_store.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_gates.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_manifest.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);
  final scope = PersonaPackageScope(
    accountId: 'account-a',
    facadeGeneration: 3,
  );

  test('consume-once survives database close and reopen', () async {
    const path = 'persona-receipt-restart.db';
    addTearDown(() => databaseFactoryMemory.deleteDatabase(path));
    final receipt = _receipt(scope, now);

    final firstDatabase = await databaseFactoryMemory.openDatabase(path);
    final first = SembastPersonaApprovalReceiptConsumer(
      database: firstDatabase,
      scope: scope,
    );
    expect(await first.consumeOnce(receipt, now: now), isTrue);
    await first.deactivateAndDrain();
    await firstDatabase.close();

    final reopenedDatabase = await databaseFactoryMemory.openDatabase(path);
    final reopened = SembastPersonaApprovalReceiptConsumer(
      database: reopenedDatabase,
      scope: scope,
    );
    expect(await reopened.consumeOnce(receipt, now: now), isFalse);
    await reopened.deactivateAndDrain();
    await reopenedDatabase.close();
  });

  test('consume-once survives real file database close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'maaso-persona-receipt-',
    );
    final path = '${directory.path}/receipts.db';
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final receipt = _receipt(scope, now);

    final firstDatabase = await databaseFactoryIo.openDatabase(path);
    final first = SembastPersonaApprovalReceiptConsumer(
      database: firstDatabase,
      scope: scope,
    );
    expect(await first.consumeOnce(receipt, now: now), isTrue);
    await first.deactivateAndDrain();
    await firstDatabase.close();

    final reopenedDatabase = await databaseFactoryIo.openDatabase(path);
    final reopened = SembastPersonaApprovalReceiptConsumer(
      database: reopenedDatabase,
      scope: scope,
    );
    expect(await reopened.consumeOnce(receipt, now: now), isFalse);
    await reopened.deactivateAndDrain();
    await reopenedDatabase.close();
  });

  test('concurrent consumers atomically admit exactly one caller', () async {
    const path = 'persona-receipt-concurrent.db';
    addTearDown(() => databaseFactoryMemory.deleteDatabase(path));
    final database = await databaseFactoryMemory.openDatabase(path);
    final first = SembastPersonaApprovalReceiptConsumer(
      database: database,
      scope: scope,
    );
    final second = SembastPersonaApprovalReceiptConsumer(
      database: database,
      scope: scope,
    );
    final receipt = _receipt(scope, now);

    final results = await Future.wait<bool>(<Future<bool>>[
      first.consumeOnce(receipt, now: now),
      second.consumeOnce(receipt, now: now),
    ]);

    expect(results.where((accepted) => accepted), hasLength(1));
    await first.deactivateAndDrain();
    await second.deactivateAndDrain();
    await database.close();
  });

  test('receipt ids are scoped by account and generation', () async {
    const path = 'persona-receipt-scope.db';
    addTearDown(() => databaseFactoryMemory.deleteDatabase(path));
    final database = await databaseFactoryMemory.openDatabase(path);
    final otherScope = PersonaPackageScope(
      accountId: 'account-b',
      facadeGeneration: 1,
    );
    final accountA = SembastPersonaApprovalReceiptConsumer(
      database: database,
      scope: scope,
    );
    final accountB = SembastPersonaApprovalReceiptConsumer(
      database: database,
      scope: otherScope,
    );

    expect(await accountA.consumeOnce(_receipt(scope, now), now: now), isTrue);
    expect(
      await accountB.consumeOnce(_receipt(otherScope, now), now: now),
      isTrue,
    );
    expect(
      await accountA.consumeOnce(_receipt(otherScope, now), now: now),
      isFalse,
    );

    await accountA.deactivateAndDrain();
    await accountB.deactivateAndDrain();
    expect(
      () => accountA.consumeOnce(_receipt(scope, now), now: now),
      throwsStateError,
    );
    await database.close();
  });
}

PersonaOnceApprovalReceipt _receipt(PersonaPackageScope scope, DateTime now) =>
    PersonaOnceApprovalReceipt(
      id: 'approval-1',
      issuer: 'maaso.host',
      installationId: 'persona:${_hex('a')}',
      manifestDigest: _hex('a'),
      scope: scope,
      skillId: 'companion.chat',
      skillVersion: '1.0.0',
      skillEntryRef: 'package://skills/companion-chat',
      method: 'run',
      argsTargetDigest: _hex('b'),
      callId: 'call-1',
      permission: PersonaPermission.deviceMotion,
      issuedAt: now.subtract(const Duration(seconds: 5)),
      expiresAt: now.add(const Duration(minutes: 1)),
    );

String _hex(String character) => List<String>.filled(64, character).join();
