import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ordinary text in migrated surfaces uses dynamic neutral foregrounds',
    () {
      const paths = <String>[
        'lib/src/features/settings/presentation/agent_settings_page.dart',
        'lib/src/core/widgets/agent_cards.dart',
        'lib/src/core/widgets/agent_card_stack.dart',
        'lib/src/core/widgets/agent_loading_card.dart',
        'lib/src/core/widgets/chat_input_bar.dart',
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ];
      final staticTextColor = RegExp(
        r'TextStyle\([\s\S]{0,200}?color:\s*'
        r'(?:ColorConstant\.(?:textPrimary|textSecondary|accentColor|errorColor)'
        r'|Colors\.(?:red|green|purple|brown|orange|amber|pink|yellow|blue)'
        r'(?:\.[A-Za-z0-9_]+)?'
        r'|(?:const\s+)?Color\(0xFF'
        r'(?:B71C1C|2E7D32|43A047|B39DDB|FF8A65|E53935)\))',
      );
      final coloredTextButton = RegExp(
        r'TextButton\.styleFrom\([\s\S]{0,220}?foregroundColor:\s*'
        r'(?:ColorConstant\.(?:primaryColor|accentColor|errorColor)'
        r'|Colors\.(?:red|green|purple|brown|orange|amber|pink|yellow|blue)'
        r'(?:\.[A-Za-z0-9_]+)?'
        r'|(?:const\s+)?Color\(0xFF'
        r'(?:B71C1C|2E7D32|43A047|B39DDB|FF8A65|E53935)\))',
      );

      for (final path in paths) {
        final source = File(path).readAsStringSync();
        expect(
          staticTextColor.hasMatch(source),
          isFalse,
          reason: '$path must not pin ordinary text to static or accent colors',
        );
        expect(
          coloredTextButton.hasMatch(source),
          isFalse,
          reason: '$path must keep button labels on a neutral foreground',
        );
      }
    },
  );
}
