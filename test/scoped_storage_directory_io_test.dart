import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:maaso/src/core/services/persistence/scoped_storage_directory_io.dart';

void main() {
  late Directory supportRoot;
  final cleanupDirectories = <Directory>[];

  setUp(() async {
    supportRoot = await Directory.systemTemp.createTemp(
      'maaso_scoped_storage_test_',
    );
    cleanupDirectories.add(supportRoot);
  });

  tearDown(() async {
    for (final directory in cleanupDirectories.reversed) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    cleanupDirectories.clear();
  });

  test('creates the requested directory below application support', () async {
    final directory = await ensureScopedStorageDirectory(
      applicationSupportRoot: supportRoot,
      relativeSegments: const <String>[
        'maaso',
        'accounts',
        'v1',
        '0123456789abcdef',
      ],
    );

    expect(
      p.normalize(directory.path),
      p.normalize(
        p.join(supportRoot.path, 'maaso', 'accounts', 'v1', '0123456789abcdef'),
      ),
    );
    expect(await directory.exists(), isTrue);
  });

  test('rejects traversal and compound path segments', () async {
    for (final unsafeSegments in <List<String>>[
      <String>['maaso', '..', 'outside'],
      <String>['maaso', p.join('accounts', 'v1')],
    ]) {
      await expectLater(
        ensureScopedStorageDirectory(
          applicationSupportRoot: supportRoot,
          relativeSegments: unsafeSegments,
        ),
        throwsArgumentError,
      );
    }
  });

  test('rejects a symbolic-link component', () async {
    if (Platform.isWindows) return;

    final linkTarget = await Directory.systemTemp.createTemp(
      'maaso_scoped_storage_link_target_',
    );
    cleanupDirectories.add(linkTarget);
    await Link(p.join(supportRoot.path, 'maaso')).create(linkTarget.path);

    await expectLater(
      ensureScopedStorageDirectory(
        applicationSupportRoot: supportRoot,
        relativeSegments: const <String>['maaso', 'accounts'],
      ),
      throwsStateError,
    );
  });

  test('rejects a symbolic-link file', () async {
    if (Platform.isWindows) return;

    final linkTargetDirectory = await Directory.systemTemp.createTemp(
      'maaso_scoped_storage_file_link_target_',
    );
    cleanupDirectories.add(linkTargetDirectory);
    final linkTarget = File(p.join(linkTargetDirectory.path, 'outside.db'));
    await linkTarget.writeAsString('outside');
    final scopedDirectory = await ensureScopedStorageDirectory(
      applicationSupportRoot: supportRoot,
      relativeSegments: const <String>['maaso', 'accounts'],
    );
    await Link(
      p.join(scopedDirectory.path, 'state.db'),
    ).create(linkTarget.path);

    await expectLater(
      resolveScopedStorageFile(
        applicationSupportRoot: supportRoot,
        relativeDirectorySegments: const <String>['maaso', 'accounts'],
        fileName: 'state.db',
      ),
      throwsStateError,
    );
  });
}
