import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the feature-first Riverpod source layout', () {
    for (final path in <String>[
      'lib/src/app',
      'lib/src/core',
      'lib/src/features',
      'lib/src/features/agent/application',
      'lib/src/features/home/presentation',
      'lib/src/features/agent_space/application',
    ]) {
      expect(Directory(path).existsSync(), isTrue, reason: path);
    }
  });

  test('does not recreate legacy top-level source folders', () {
    for (final path in <String>[
      'lib/agent',
      'lib/controllers',
      'lib/foundation',
      'lib/pages',
      'lib/router',
      'lib/service',
    ]) {
      expect(Directory(path).existsSync(), isFalse, reason: path);
    }
  });

  test('route lifecycle files no longer use GetX binding directories', () {
    final legacyFiles = Directory('lib/src/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.contains('/binding/'))
        .toList();

    expect(legacyFiles, isEmpty);
  });
}
