@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/auth_credential_transaction_lock_web.dart';

void main() {
  test(
    'Web Locks keeps the lease until the Dart action Future settles',
    () async {
      final firstLock = WebAuthCredentialTransactionLock();
      final secondLock = WebAuthCredentialTransactionLock();
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

  test('Web Locks releases the lease when an action fails', () async {
    final firstLock = WebAuthCredentialTransactionLock();
    final secondLock = WebAuthCredentialTransactionLock();

    await expectLater(
      firstLock.synchronized<void>(() async {
        throw StateError('action failed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await secondLock.synchronized(() async => 'recovered'), 'recovered');
  });
}
