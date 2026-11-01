import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store_io.dart';

const _ownerFingerprint =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory supportDirectory;
  late Future<Directory> Function() resolveSupportDirectory;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'maaso-auth-fence-',
    );
    resolveSupportDirectory = () async => supportDirectory;
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test(
    'missing and partial native records stay pending across reopen',
    () async {
      final first = FileAuthLogoutPendingStore(
        supportDirectory: resolveSupportDirectory,
      );

      final missing = await first.read('test');
      expect(missing.pending, isTrue);
      expect(missing.revision, 0);

      final baseline = await first.clearPending('test', expected: missing);
      expect(baseline?.pending, isFalse);

      final reopened = FileAuthLogoutPendingStore(
        supportDirectory: resolveSupportDirectory,
      );
      expect((await reopened.read('test')).pending, isFalse);

      final files = await _slotFiles(supportDirectory);
      expect(files, hasLength(2));
      await files.first.writeAsString('{"partial":');

      final afterCrash = await reopened.read('test');
      expect(afterCrash.pending, isTrue);
      expect(afterCrash.revision, baseline!.revision);

      final repaired = await reopened.clearPending(
        'test',
        expected: afterCrash,
      );
      expect(repaired?.pending, isFalse);
      expect((await first.read('test')).sameVersion(repaired!), isTrue);
    },
  );

  test(
    'newer native mark defeats a stale clear from another instance',
    () async {
      final first = FileAuthLogoutPendingStore(
        supportDirectory: resolveSupportDirectory,
      );
      final second = FileAuthLogoutPendingStore(
        supportDirectory: resolveSupportDirectory,
      );
      final missing = await first.read('production');
      final baseline = await first.clearPending(
        'production',
        expected: missing,
      );

      final pending = await second.markPending(
        'production',
        ownerFingerprint: _ownerFingerprint,
      );
      final staleClear = await first.clearPending(
        'production',
        expected: baseline!,
      );

      expect(staleClear, isNull);
      expect((await first.read('production')).sameVersion(pending), isTrue);
    },
  );

  test('same-process stores serialize without losing a newer mark', () async {
    final first = FileAuthLogoutPendingStore(
      supportDirectory: resolveSupportDirectory,
    );
    final second = FileAuthLogoutPendingStore(
      supportDirectory: resolveSupportDirectory,
    );
    final missing = await first.read('test');
    final baseline = await first.clearPending('test', expected: missing);

    final results = await Future.wait<Object?>(<Future<Object?>>[
      second.markPending('test', ownerFingerprint: _ownerFingerprint),
      first.clearPending('test', expected: baseline!),
    ]);

    final marked = results.first as AuthLogoutPendingSnapshot;
    final cleared = results.last as AuthLogoutPendingSnapshot?;
    if (cleared != null) {
      // Directory resolution happens before the process-local tail, so either
      // request may acquire the lock first. A successful clear must still be
      // ordered before the subsequent mark rather than erasing it.
      expect(cleared.pending, isFalse);
      expect(cleared.revision, lessThan(marked.revision));
    }
    expect((await first.read('test')).sameVersion(marked), isTrue);
  });
}

Future<List<File>> _slotFiles(Directory supportDirectory) async {
  final fenceDirectory = Directory(
    '${supportDirectory.path}/auth_logout_fence_v1',
  );
  return fenceDirectory
      .list()
      .where((entry) => entry is File && entry.path.endsWith('.fence'))
      .cast<File>()
      .toList();
}
