import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

/// Caller first drains/unmounts the captured account runtime. No unscoped legacy
/// directory, shared asset cache or other account/environment path is selected.
Future<void> purgeDeletedAccountScope(
  AccountStorageScope scope, {
  Directory? applicationSupportRoot,
}) async {
  final root = applicationSupportRoot ?? await getApplicationSupportDirectory();
  final canonical = await root.resolveSymbolicLinks();
  var current = canonical;
  for (final part in scope.accountDirectorySegments) {
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Account directory is not a regular directory',
        current,
      );
    }
    final resolved = await Directory(current).resolveSymbolicLinks();
    if (!p.isWithin(canonical, resolved)) {
      throw FileSystemException(
        'Account directory escapes its storage root',
        current,
      );
    }
  }
  final owned = Directory(current);
  await for (final entity in owned.list(recursive: true, followLinks: false)) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException(
        'Account directory contains a symbolic link',
        entity.path,
      );
    }
  }
  await owned.delete(recursive: true);
}
