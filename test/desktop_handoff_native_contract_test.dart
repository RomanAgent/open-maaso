import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native desktop dispatch keeps local display and retires visual handoff',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final result = await Process.run('python3', const <String>[
        '-m',
        'unittest',
        'discover',
        '-s',
        'test/tool',
        '-p',
        'desktop_companion_native_dispatch_test.py',
        '-v',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
