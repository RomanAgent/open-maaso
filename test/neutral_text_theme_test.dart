import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';

void main() {
  test('app palettes expose neutral White Frost foregrounds', () {
    final light = AppPalette.of(Brightness.light, AppAccent.blue);
    final dark = AppPalette.of(Brightness.dark, AppAccent.blue);

    expect(ColorConstant.textPrimary, const Color(0xFF202124));
    expect(ColorConstant.textSecondary, const Color(0xFF5F636B));
    expect(light.textPrimary, ColorConstant.textPrimary);
    expect(light.textSecondary, ColorConstant.textSecondary);
    expect(dark.textPrimary, const Color(0xFFF6F8FC));
    expect(dark.textSecondary, const Color(0xFFBCC3CE));
  });

  test('Material text and navigation foregrounds stay neutral', () {
    for (final brightness in Brightness.values) {
      final palette = AppPalette.of(brightness, AppAccent.pink);
      final theme = AppTheme.build(palette);
      final selected = <WidgetState>{WidgetState.selected};
      final unselected = <WidgetState>{};

      expect(theme.colorScheme.onSurface, palette.textPrimary);
      expect(theme.colorScheme.onSurfaceVariant, palette.textSecondary);
      expect(theme.textTheme.labelLarge?.color, palette.textPrimary);
      expect(theme.textTheme.bodyLarge?.color, palette.textPrimary);
      expect(
        theme.navigationBarTheme.labelTextStyle?.resolve(selected)?.color,
        palette.textPrimary,
      );
      expect(
        theme.navigationBarTheme.labelTextStyle?.resolve(unselected)?.color,
        palette.textSecondary,
      );
      expect(
        theme.navigationBarTheme.iconTheme?.resolve(selected)?.color,
        palette.textPrimary,
      );
      expect(
        theme.navigationBarTheme.iconTheme?.resolve(unselected)?.color,
        palette.textSecondary,
      );
      expect(
        theme.textButtonTheme.style?.foregroundColor?.resolve(unselected),
        palette.textPrimary,
      );
      expect(
        theme.bottomNavigationBarTheme.selectedItemColor,
        palette.textPrimary,
      );
      expect(
        theme.bottomNavigationBarTheme.unselectedItemColor,
        palette.textSecondary,
      );
      expect(theme.tabBarTheme.labelColor, palette.textPrimary);
      expect(theme.tabBarTheme.unselectedLabelColor, palette.textSecondary);
      expect(theme.listTileTheme.textColor, palette.textPrimary);
      expect(
        theme.listTileTheme.subtitleTextStyle?.color,
        palette.textSecondary,
      );
      expect(
        theme.popupMenuTheme.labelTextStyle?.resolve(unselected)?.color,
        palette.textPrimary,
      );
      expect(
        theme.menuButtonTheme.style?.foregroundColor?.resolve(unselected),
        palette.textPrimary,
      );
      expect(theme.dropdownMenuTheme.textStyle?.color, palette.textPrimary);
    }
  });
}
