import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates and validates a storage directory below [applicationSupportRoot].
///
/// Scoped storage only passes fixed path segments and opaque digests here. The
/// additional containment and link checks make that contract fail closed if a
/// local filesystem entry has been replaced with a file or symbolic link.
Future<Directory> ensureScopedStorageDirectory({
  required Directory applicationSupportRoot,
  required List<String> relativeSegments,
}) async {
  if (relativeSegments.isEmpty) {
    throw ArgumentError.value(
      relativeSegments,
      'relativeSegments',
      'must select a directory below the application-support root',
    );
  }

  for (final segment in relativeSegments) {
    if (!_isSafePathSegment(segment)) {
      throw ArgumentError.value(
        relativeSegments,
        'relativeSegments',
        'must contain safe single path segments',
      );
    }
  }

  final rootPath = p.normalize(p.absolute(applicationSupportRoot.path));
  final directoryPath = p.normalize(
    p.joinAll(<String>[rootPath, ...relativeSegments]),
  );
  if (!p.isWithin(rootPath, directoryPath)) {
    throw StateError('Scoped storage path escaped application support.');
  }

  final components = <Directory>[];
  var currentPath = rootPath;
  for (final segment in relativeSegments) {
    currentPath = p.join(currentPath, segment);
    components.add(Directory(currentPath));
  }

  await _rejectUnsafeComponents(components, allowMissing: true);
  final directory = components.last;
  await directory.create(recursive: true);
  await _rejectUnsafeComponents(components, allowMissing: false);

  final resolvedRoot = p.normalize(
    await Directory(rootPath).resolveSymbolicLinks(),
  );
  final resolvedDirectory = p.normalize(await directory.resolveSymbolicLinks());
  if (!p.isWithin(resolvedRoot, resolvedDirectory)) {
    throw StateError('Scoped storage path escaped application support.');
  }
  return directory;
}

/// Resolves a safe file below a scoped directory, without creating the file.
Future<File> resolveScopedStorageFile({
  required Directory applicationSupportRoot,
  required List<String> relativeDirectorySegments,
  required String fileName,
}) async {
  if (!_isSafePathSegment(fileName)) {
    throw ArgumentError.value(
      fileName,
      'fileName',
      'must be a safe single path segment',
    );
  }

  final directory = await ensureScopedStorageDirectory(
    applicationSupportRoot: applicationSupportRoot,
    relativeSegments: relativeDirectorySegments,
  );
  final file = File(p.join(directory.path, fileName));
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw StateError('Scoped storage contains an unsafe file component.');
  }
  return file;
}

Future<void> _rejectUnsafeComponents(
  List<Directory> components, {
  required bool allowMissing,
}) async {
  for (final component in components) {
    final type = await FileSystemEntity.type(
      component.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (!allowMissing && type != FileSystemEntityType.directory) ||
        (allowMissing &&
            type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw StateError('Scoped storage contains an unsafe path component.');
    }
  }
}

bool _isSafePathSegment(String segment) {
  return segment.isNotEmpty &&
      segment != '.' &&
      segment != '..' &&
      !p.isAbsolute(segment) &&
      p.basename(segment) == segment;
}
