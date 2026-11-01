import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/verify_project_bundle.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('maaso-bundle-preflight-');
    final source = Directory('tool/fixtures/project_bundle_checklist');
    for (final item in source.listSync(recursive: true, followLinks: false)) {
      final relative = item.path.substring(source.path.length + 1);
      if (item is Directory) {
        Directory('${temporary.path}/$relative').createSync(recursive: true);
      } else if (item is File) {
        final destination = File('${temporary.path}/$relative');
        destination.parent.createSync(recursive: true);
        item.copySync(destination.path);
      }
    }
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  test('preflights the actual offline multi-page fixture bytes', () {
    final verified = verifyProjectBundleDirectory(temporary);
    expect(verified.bundleDigest, isNotEmpty);
    expect(verified.agentMarkdown, contains('当前不支持对战'));
  });

  test('rejects a changed page even when its filename is unchanged', () {
    File('${temporary.path}/pages/details.html').writeAsStringSync('changed');
    expect(
      () => verifyProjectBundleDirectory(temporary),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects files missing from the declared package', () {
    File('${temporary.path}/extra.js').writeAsStringSync('undeclared');
    expect(
      () => verifyProjectBundleDirectory(temporary),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects symbolic links instead of reading outside the bundle', () {
    final page = File('${temporary.path}/pages/details.html');
    page.deleteSync();
    Link(
      page.path,
    ).createSync(File('${temporary.path}/index.html').absolute.path);
    expect(
      () => verifyProjectBundleDirectory(temporary),
      throwsA(isA<FormatException>()),
    );
  });

  test('requires a regular project manifest', () {
    final manifest = File('${temporary.path}/project.json');
    manifest.deleteSync();
    expect(
      () => verifyProjectBundleDirectory(temporary),
      throwsA(isA<FormatException>()),
    );
  });
}
