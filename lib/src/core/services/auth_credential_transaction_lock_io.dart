import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'auth_credential_transaction_lock.dart';
import 'persistence/scoped_storage_directory_io.dart';

AuthCredentialTransactionLock createPlatformAuthCredentialTransactionLock() {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return InProcessAuthCredentialTransactionLock();
  }
  return FileAuthCredentialTransactionLock();
}

/// Device-global native credential transaction lock.
///
/// The static tail serializes service instances in this isolate. The fixed
/// Application Support lock file extends the exclusion across app processes.
/// Maaso performs auth work on the main isolate; the OS file lock is advisory
/// on Unix platforms, so other native participants must use this same file.
final class FileAuthCredentialTransactionLock
    implements AuthCredentialTransactionLock {
  FileAuthCredentialTransactionLock({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static Future<void> _processTail = Future<void>.value();
  static const _lockFileName = 'credential_transaction.lock';

  final Future<Directory> Function() _supportDirectory;

  @override
  Future<T> synchronized<T>(Future<T> Function() action) {
    final completion = Completer<T>();
    _processTail = _processTail.then((_) async {
      RandomAccessFile? lockHandle;
      var locked = false;
      Object? result;
      Object? primaryError;
      StackTrace? primaryStackTrace;
      try {
        final support = await _supportDirectory();
        final supportType = await FileSystemEntity.type(
          support.path,
          followLinks: false,
        );
        if (supportType == FileSystemEntityType.link ||
            (supportType != FileSystemEntityType.notFound &&
                supportType != FileSystemEntityType.directory)) {
          throw StateError('Unsafe application-support directory.');
        }
        await support.create(recursive: true);
        final lockFile = await resolveScopedStorageFile(
          applicationSupportRoot: support,
          relativeDirectorySegments: const <String>['maaso', 'auth'],
          fileName: _lockFileName,
        );
        lockHandle = await lockFile.open(mode: FileMode.append);
        await lockHandle.lock(FileLock.blockingExclusive);
        locked = true;
        result = await Future<T>.sync(action);
      } catch (error, stackTrace) {
        primaryError = error;
        primaryStackTrace = stackTrace;
      } finally {
        if (locked) {
          try {
            await lockHandle?.unlock();
          } catch (error, stackTrace) {
            primaryError ??= error;
            primaryStackTrace ??= stackTrace;
          }
        }
        try {
          await lockHandle?.close();
        } catch (error, stackTrace) {
          primaryError ??= error;
          primaryStackTrace ??= stackTrace;
        }
        // Do not let a caller start its next cross-process transaction until
        // the OS lease is fully released. Unlock/close failures are therefore
        // part of this transaction's fail-closed result.
        if (primaryError != null) {
          completion.completeError(primaryError, primaryStackTrace!);
        } else {
          completion.complete(result as T);
        }
      }
    });
    return completion.future;
  }
}
