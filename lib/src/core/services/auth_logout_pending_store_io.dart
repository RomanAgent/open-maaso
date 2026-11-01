import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth_logout_pending_store.dart';
import 'auth_logout_pending_store_codec.dart';

const String _directoryName = 'auth_logout_fence_v1';
const String _lockFileName = 'fence.lock';
final Map<String, Future<void>> _processLockTails = <String, Future<void>>{};

AuthLogoutPendingStore createPlatformAuthLogoutPendingStore() =>
    FileAuthLogoutPendingStore();

/// A native two-slot journal whose absence and partial writes fail closed.
///
/// Both slots are permanent. They are never renamed or deleted, so a lost
/// directory entry or a crash during truncate/write is observed as a pending
/// fence on the next process start. The independent lock file serializes every
/// read-modify-write operation across native processes, including Windows.
final class FileAuthLogoutPendingStore implements AuthLogoutPendingStore {
  FileAuthLogoutPendingStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) =>
      _withLock((directory) => _readLocked(directory, environmentKey));

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) => _withLock((directory) async {
    final current = await _readLocked(directory, environmentKey);
    final record = AuthLogoutPendingRecord(
      environmentKey: environmentKey,
      revision: current.revision + 1,
      pending: true,
      token: newAuthLogoutPendingToken(),
      ownerFingerprint: ownerFingerprint,
    );
    await _writeBothLocked(directory, record);
    final committed = await _readLocked(directory, environmentKey);
    if (!committed.pending || committed.token != record.token) {
      throw StateError('Logout-pending native fence did not commit.');
    }
    return committed;
  });

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) => _withLock((directory) async {
    final current = await _readLocked(directory, environmentKey);
    if (!current.sameVersion(expected)) return null;
    final record = AuthLogoutPendingRecord(
      environmentKey: environmentKey,
      revision: current.revision + 1,
      pending: false,
      token: newAuthLogoutPendingToken(),
    );
    await _writeBothLocked(directory, record);
    final committed = await _readLocked(directory, environmentKey);
    if (committed.pending || committed.token != record.token) {
      throw StateError('Logout-pending native clear did not commit.');
    }
    return committed;
  });

  Future<T> _withLock<T>(Future<T> Function(Directory directory) action) async {
    final directory = await _resolveDirectory();
    final lockPath = p.join(directory.path, _lockFileName);
    final previous = _processLockTails[lockPath] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = previous.then((_) => release.future);
    _processLockTails[lockPath] = tail;
    await previous;
    try {
      final lockFile = File(lockPath);
      await _requireRegularOrMissing(lockFile);
      final lock = await lockFile.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await action(directory);
      } finally {
        try {
          await lock.unlock();
        } finally {
          await lock.close();
        }
      }
    } finally {
      release.complete();
      if (identical(_processLockTails[lockPath], tail)) {
        _processLockTails.remove(lockPath);
      }
    }
  }

  Future<Directory> _resolveDirectory() async {
    final root = await _supportDirectory();
    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType == FileSystemEntityType.link ||
        (rootType != FileSystemEntityType.notFound &&
            rootType != FileSystemEntityType.directory)) {
      throw StateError('Unsafe application-support directory.');
    }
    await root.create(recursive: true);
    final directory = Directory(p.join(root.path, _directoryName));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw StateError('Unsafe logout-fence directory.');
    }
    await directory.create();
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Logout-fence directory could not be established.');
    }
    return directory;
  }

  Future<AuthLogoutPendingSnapshot> _readLocked(
    Directory directory,
    String environmentKey,
  ) async {
    final files = _slotFiles(directory, environmentKey);
    final encoded = <String?>[];
    for (final file in files) {
      await _requireRegularOrMissing(file);
      if (!await file.exists()) {
        encoded.add(null);
        continue;
      }
      if (await file.length() > 4096) {
        encoded.add('<oversized>');
        continue;
      }
      encoded.add(utf8.decode(await file.readAsBytes(), allowMalformed: true));
    }
    return authLogoutPendingSnapshotFromRedundantSlots(
      environmentKey: environmentKey,
      encodedSlots: encoded,
    );
  }

  Future<void> _writeBothLocked(
    Directory directory,
    AuthLogoutPendingRecord record,
  ) async {
    final encoded = record.encode();
    for (final file in _slotFiles(directory, record.environmentKey)) {
      await _requireRegularOrMissing(file);
      final writer = await file.open(mode: FileMode.write);
      try {
        await writer.writeString(encoded);
        await writer.flush();
      } finally {
        await writer.close();
      }
    }
  }

  List<File> _slotFiles(Directory directory, String environmentKey) {
    final digest = sha256.convert(environmentKey.codeUnits).toString();
    return <File>[
      File(p.join(directory.path, '$digest.0.fence')),
      File(p.join(directory.path, '$digest.1.fence')),
    ];
  }

  Future<void> _requireRegularOrMissing(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('Unsafe logout-fence file component.');
    }
  }
}
