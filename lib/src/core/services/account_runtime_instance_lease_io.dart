import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'account_runtime_instance_lease.dart';
import 'persistence/scoped_storage_directory_io.dart';

AccountRuntimeInstanceLeaseGate
createPlatformAccountRuntimeInstanceLeaseGate() {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return InProcessAccountRuntimeInstanceLeaseGate();
  }
  return FileAccountRuntimeInstanceLeaseGate();
}

/// Installation-local account-runtime lease for native platforms.
///
/// A static owner fences independent graphs in this isolate. The fixed
/// Application Support lock file extends the lease across app processes. The
/// non-blocking OS lock makes a second window fail immediately instead of
/// waiting while its login flow appears hung.
final class FileAccountRuntimeInstanceLeaseGate
    implements AccountRuntimeInstanceLeaseGate {
  FileAccountRuntimeInstanceLeaseGate({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static Future<void> _processTail = Future<void>.value();
  static Object? _processOwner;
  static const _lockFileName = 'account_runtime_instance.lock';

  final Future<Directory> Function() _supportDirectory;

  @override
  Future<AccountRuntimeInstanceLease> acquire() {
    final completion = Completer<AccountRuntimeInstanceLease>();
    _processTail = _processTail.then((_) async {
      RandomAccessFile? handle;
      try {
        if (_processOwner != null) {
          throw const AccountRuntimeInstanceUnavailable();
        }
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
          relativeDirectorySegments: const <String>['maaso', 'runtime'],
          fileName: _lockFileName,
        );
        handle = await lockFile.open(mode: FileMode.append);
        try {
          await handle.lock(FileLock.exclusive);
        } catch (error) {
          try {
            await handle.close();
          } catch (_) {
            // The acquisition error remains the actionable failure.
          }
          handle = null;
          throw AccountRuntimeInstanceUnavailable(error);
        }
        final token = Object();
        _processOwner = token;
        completion.complete(
          _FileAccountRuntimeInstanceLease(
            owner: this,
            token: token,
            handle: handle,
          ),
        );
      } on AccountRuntimeInstanceUnavailable catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      } catch (error, stackTrace) {
        try {
          await handle?.close();
        } catch (_) {
          // Preserve the primary path/open/validation failure.
        }
        completion.completeError(
          AccountRuntimeInstanceLockFailure(error),
          stackTrace,
        );
      }
    });
    return completion.future;
  }

  Future<void> _release(_FileAccountRuntimeInstanceLease lease) {
    final completion = Completer<void>();
    _processTail = _processTail.then((_) async {
      try {
        if (lease._released) {
          completion.complete();
          return;
        }
        if (!identical(_processOwner, lease._token)) {
          throw StateError('Account runtime instance lease owner changed.');
        }
        if (lease._locked) {
          // Do not close after an unlock failure: retaining the handle keeps
          // ownership retryable and fail-closed.
          await lease._handle.unlock();
          lease._locked = false;
        }
        if (!lease._closed) {
          await lease._handle.close();
          lease._closed = true;
        }
        _processOwner = null;
        lease._released = true;
        completion.complete();
      } catch (error, stackTrace) {
        completion.completeError(
          AccountRuntimeInstanceLockFailure(error),
          stackTrace,
        );
      }
    });
    return completion.future;
  }
}

final class _FileAccountRuntimeInstanceLease
    implements AccountRuntimeInstanceLease {
  _FileAccountRuntimeInstanceLease({
    required FileAccountRuntimeInstanceLeaseGate owner,
    required Object token,
    required RandomAccessFile handle,
  }) : _owner = owner,
       _token = token,
       _handle = handle;

  final FileAccountRuntimeInstanceLeaseGate _owner;
  final Object _token;
  final RandomAccessFile _handle;
  Future<void>? _inFlight;
  bool _locked = true;
  bool _closed = false;
  bool _released = false;

  @override
  Future<void> release() {
    if (_released) return Future<void>.value();
    return _inFlight ??= _releaseOnce();
  }

  Future<void> _releaseOnce() async {
    try {
      await _owner._release(this);
    } finally {
      _inFlight = null;
    }
  }
}
