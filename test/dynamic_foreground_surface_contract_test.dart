import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const targetFiles = <String>[
    'lib/src/core/widgets/ui/world_portal.dart',
    'lib/src/features/applets/presentation/ble_projector/ble_projector_applet.dart',
    'lib/src/features/agent_space/presentation/agent_space_page.dart',
  ];

  test('ordinary surface text uses theme-aware neutral foregrounds', () {
    for (final path in targetFiles) {
      final source = File(path).readAsStringSync();

      expect(
        source,
        contains('MaasoGlassTheme.of(context)'),
        reason: '$path must resolve foreground colors from the active theme',
      );
      expect(
        source,
        isNot(contains('ColorConstant.textPrimary')),
        reason: '$path must not pin text or icons to the light foreground',
      );
      expect(
        source,
        isNot(contains('ColorConstant.textSecondary')),
        reason: '$path must not pin text or icons to the light foreground',
      );
      expect(
        source,
        isNot(contains('Color(0xFFFFD632)')),
        reason: '$path must keep fixed dark-scene text white or white-gray',
      );
    }
  });
}
