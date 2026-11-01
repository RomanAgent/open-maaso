import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/auth_credential_transaction_lock_io.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'native credential lock serializes separate service instances',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'maaso-auth-transaction-lock-',
      );
      addTearDown(() async {
        if (await support.exists()) await support.delete(recursive: true);
      });
      final firstLock = FileAuthCredentialTransactionLock(
        supportDirectory: () async => support,
      );
      final secondLock = FileAuthCredentialTransactionLock(
        supportDirectory: () async => support,
      );
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondEntered = false;

      final first = firstLock.synchronized(() async {
        firstEntered.complete();
        await releaseFirst.future;
        return 'first';
      });
      await firstEntered.future;
      final second = secondLock.synchronized(() async {
        secondEntered = true;
        return 'second';
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(secondEntered, isFalse);
      releaseFirst.complete();
      expect(await first, 'first');
      expect(await second, 'second');
    },
  );

  test('native credential lock rejects a symbolic-link lock leaf', () async {
    final support = await Directory.systemTemp.createTemp(
      'maaso-auth-transaction-link-',
    );
    addTearDown(() async {
      if (await support.exists()) await support.delete(recursive: true);
    });
    final authDirectory = Directory(p.join(support.path, 'maaso', 'auth'));
    await authDirectory.create(recursive: true);
    final target = File(p.join(support.path, 'outside.lock'));
    await target.writeAsString('outside');
    final link = Link(
      p.join(authDirectory.path, 'credential_transaction.lock'),
    );
    try {
      await link.create(target.path);
    } on FileSystemException {
      return;
    }
    var actionRan = false;
    final lock = FileAuthCredentialTransactionLock(
      supportDirectory: () async => support,
    );

    await expectLater(
      lock.synchronized(() async {
        actionRan = true;
      }),
      throwsA(isA<StateError>()),
    );
    expect(actionRan, isFalse);
  });

  test('native action failure does not poison the process tail', () async {
    final support = await Directory.systemTemp.createTemp(
      'maaso-auth-transaction-retry-',
    );
    addTearDown(() async {
      if (await support.exists()) await support.delete(recursive: true);
    });
    final firstLock = FileAuthCredentialTransactionLock(
      supportDirectory: () async => support,
    );
    final secondLock = FileAuthCredentialTransactionLock(
      supportDirectory: () async => support,
    );

    await expectLater(
      firstLock.synchronized<void>(() async {
        throw StateError('action failed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await secondLock.synchronized(() async => 'recovered'), 'recovered');
  });
}
