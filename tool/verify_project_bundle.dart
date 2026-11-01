import 'dart:convert';
import 'dart:io';

import 'package:maaso/src/features/agent/application/project_build/project_bundle_contract.dart';

/// Read-only preflight for an unpacked, caller-controlled project workspace.
/// Passing preflight does not authorize execution, publishing, or Agent control.
VerifiedProjectBundle verifyProjectBundleDirectory(Directory directory) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Bundle root must be a regular directory.');
  }
  final root = Directory(directory.resolveSymbolicLinksSync());
  final manifestFile = File('${root.path}/project.json');
  if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('project.json must be a regular file.');
  }
  if (manifestFile.lengthSync() > ProjectBundleLimits.maxDocumentBytes) {
    throw const FormatException('project.json exceeds the preflight limit.');
  }
  final manifest = ProjectBundleManifest.parse(
    utf8.decode(manifestFile.readAsBytesSync()),
  );
  final files = <ProjectBundleFile>[];
  var visited = 0;
  var bytesRead = 0;

  void readDirectory(Directory current, String relative, int depth) {
    if (depth > 16) {
      throw const FormatException(
        'Bundle directory nesting exceeds the limit.',
      );
    }
    for (final entity in current.listSync(followLinks: false)) {
      if (++visited > ProjectBundleLimits.maxFiles * 2) {
        throw const FormatException('Bundle entry count exceeds the limit.');
      }
      final name = entity.path.substring(current.path.length + 1);
      final path = relative.isEmpty ? name : '$relative/$name';
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        readDirectory(Directory(entity.path), path, depth + 1);
      } else if (type == FileSystemEntityType.file) {
        if (path == 'project.json') continue;
        final file = File(entity.path);
        final length = file.lengthSync();
        if (length > ProjectBundleLimits.maxFileBytes ||
            bytesRead + length > ProjectBundleLimits.maxBundleBytes) {
          throw const FormatException(
            'Bundle bytes exceed the preflight limit.',
          );
        }
        final bytes = file.readAsBytesSync();
        bytesRead += bytes.length;
        if (bytes.length != length ||
            bytesRead > ProjectBundleLimits.maxBundleBytes) {
          throw const FormatException('Bundle changed during preflight.');
        }
        files.add(ProjectBundleFile(path: path, bytes: bytes));
      } else {
        throw const FormatException(
          'Bundle may contain only regular files and directories.',
        );
      }
    }
  }

  readDirectory(root, '', 0);
  return const ProjectBundleValidator().verify(manifest, files);
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/verify_project_bundle.dart <directory>',
    );
    exitCode = 64;
    return;
  }
  try {
    final result = verifyProjectBundleDirectory(Directory(arguments.single));
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'validation': 'package-preflight-only',
        'bundleDigest': result.bundleDigest,
        'executionAuthorized': false,
        'publishingAuthorized': false,
      }),
    );
  } on Object catch (error) {
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'error': 'project_bundle_preflight_failed',
        'message': error.toString(),
      }),
    );
    exitCode = 65;
  }
}
