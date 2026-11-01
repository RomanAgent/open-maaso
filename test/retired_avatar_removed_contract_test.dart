import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy web avatar renderer is fully retired', () {
    const retiredRuntimeName =
        'live'
        '2d';
    const retiredWebRuntimeName =
        'avatar'
        '3d';

    expect(Directory('assets/$retiredRuntimeName').existsSync(), isFalse);
    expect(Directory('assets/$retiredWebRuntimeName').existsSync(), isFalse);
    expect(
      File('lib/pages/widget/${retiredWebRuntimeName}_view.dart').existsSync(),
      isFalse,
    );
    final forbiddenPatterns = <RegExp>[
      RegExp(retiredRuntimeName, caseSensitive: false),
      RegExp(retiredWebRuntimeName, caseSensitive: false),
    ];
    final filesToScan = <File>[
      File('pubspec.yaml'),
      File('docs/architecture/current.md'),
      ...Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];

    final offenders = <String>[];
    for (final file in filesToScan) {
      final source = file.readAsStringSync();
      if (forbiddenPatterns.any((pattern) => pattern.hasMatch(source))) {
        offenders.add(file.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'The app now uses the Unity avatar project only. Retired 2D, '
          'web avatar paths must not remain in active '
          'source, docs, or bundled assets.',
    );
  });
}
