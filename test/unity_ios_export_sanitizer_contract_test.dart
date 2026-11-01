import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Unity iOS export always removes duplicate build phase references', () {
    final exporter = File(
      'unity/masso_avatar/Assets/MaasoAvatar/Editor/'
      'MaasoUnityLibraryExporter.cs',
    ).readAsStringSync();

    expect(exporter, contains('SanitizeIOSDuplicateBuildPhases(outputPath);'));
    expect(
      exporter,
      contains('private static int SanitizeIOSDuplicateBuildPhases('),
    );
  });
}
