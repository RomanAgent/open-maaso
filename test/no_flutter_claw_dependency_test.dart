import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'maaso has no flutter_claw dependency, imports, or project-name residue',
    () {
      final dependencyFiles = [
        File('pubspec.yaml'),
        if (File('pubspec.lock').existsSync()) File('pubspec.lock'),
      ];
      for (final file in dependencyFiles) {
        final source = file.readAsStringSync();
        expect(source, isNot(contains('flutter_claw')), reason: file.path);
      }

      final dartFiles = Directory('.')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                !file.path.startsWith('./.dart_tool/') &&
                !file.path.startsWith('./build/') &&
                !file.path.endsWith('no_flutter_claw_dependency_test.dart'),
          );

      final offenders = <String>[];
      for (final file in dartFiles) {
        final source = file.readAsStringSync();
        if (source.contains('flutter_claw')) {
          offenders.add(file.path);
        }
      }

      expect(offenders, isEmpty);
    },
  );
}
