import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/app_typography.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

class AppTheme {
  /// Build the active [ThemeData] from the resolved [AppPalette].  Both
  /// brightness (light/dark) and accent (seed colour) flow from [palette], so
  /// every Material widget that reads `Theme.of(context)` flips automatically
  /// when the agent changes the theme.
  static ThemeData build(AppPalette palette) {
    final frost = MaasoGlassTheme.fromPalette(palette);
    final muted = palette.isDark
        ? MaasoFrostTokens.darkMuted
        : MaasoFrostTokens.lightMuted;
    final seededScheme = ColorScheme.fromSeed(
      seedColor: palette.seed,
      primary: palette.seed,
      brightness: palette.brightness,
      surface: palette.surface,
    );
    final scheme = seededScheme.copyWith(
      primary: palette.seed,
      onPrimary: palette.seed.computeLuminance() <= 0.1833
          ? Colors.white
          : Colors.black,
      secondary: frost.accentText,
      primaryContainer: frost.accentSoft,
      secondaryContainer: frost.accentSoft,
      surfaceContainerLowest: palette.surface,
      surfaceContainerLow: muted,
      surfaceContainer: muted,
      surfaceContainerHigh: muted,
      surfaceContainerHighest: muted,
      surfaceTint: Colors.transparent,
      outline: palette.divider,
      outlineVariant: palette.divider,
      error: palette.isDark
          ? MaasoFrostTokens.darkDanger
          : MaasoFrostTokens.lightDanger,
      onSurface: palette.textPrimary,
      onSurfaceVariant: palette.textSecondary,
      onPrimaryContainer: palette.textPrimary,
      onSecondaryContainer: palette.textPrimary,
      onTertiaryContainer: palette.textPrimary,
      inverseSurface: palette.isDark
          ? ColorConstant.backgroundColor
          : ColorConstant.textPrimary,
      onInverseSurface: palette.isDark
          ? MaasoFrostTokens.lightTextPrimary
          : ColorConstant.backgroundColor,
    );
    final baseTextTheme =
        (palette.isDark
                ? ThemeData.dark(useMaterial3: true)
                : ThemeData.light(useMaterial3: true))
            .textTheme
            .apply(
              bodyColor: palette.textPrimary,
              displayColor: palette.textPrimary,
            );

    return ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[frost],
      // Move complete pages without fading their background into Unity's
      // native underlay. The shared slide also avoids Android's fallback
      // scrim and desktop zoom/fade exposing a blank frame during navigation.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
        },
      ),
      scaffoldBackgroundColor: palette.background,
      // All Material controls inherit the same quiet press treatment. Keep
      // focus/hover feedback, but never paint an expanding ink ripple.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        iconTheme: IconThemeData(color: palette.textPrimary),
        titleTextStyle: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.card,
        surfaceTintColor: Colors.transparent,
        elevation: palette.isDark ? 0 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.cardRadius),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: muted.withValues(alpha: MaasoFrostTokens.inputFillAlpha),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide.none,
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide.none,
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide.none,
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.inputRadius),
          borderSide: BorderSide(color: palette.seed, width: 2),
        ),
        labelStyle: MassoTypography.body(
          color: palette.textSecondary,
          fontSize: 15,
        ),
      ),
      textTheme: baseTextTheme.copyWith(
        headlineMedium: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 36 / 28,
        ),
        titleLarge: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          height: 32 / 24,
        ),
        titleMedium: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        bodyMedium: MassoTypography.body(
          color: palette.textPrimary,
          fontSize: 15,
          height: 24 / 15,
        ),
        bodySmall: MassoTypography.body(
          color: palette.textSecondary,
          fontSize: 13,
          height: 20 / 13,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? palette.textPrimary : palette.textSecondary,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return MassoTypography.display(
            color: selected ? palette.textPrimary : palette.textSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            height: 1.2,
          );
        }),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: palette.textPrimary,
        unselectedItemColor: palette.textSecondary,
        selectedLabelStyle: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: MassoTypography.display(
          color: palette.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        selectedIconTheme: IconThemeData(color: palette.textPrimary),
        unselectedIconTheme: IconThemeData(color: palette.textSecondary),
        selectedLabelTextStyle: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: MassoTypography.display(
          color: palette.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: palette.textPrimary,
        unselectedLabelColor: palette.textSecondary,
        labelStyle: MassoTypography.display(
          color: palette.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: MassoTypography.display(
          color: palette.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      listTileTheme: ListTileThemeData(
        textColor: palette.textPrimary,
        iconColor: palette.textSecondary,
        titleTextStyle: MassoTypography.body(
          color: palette.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: MassoTypography.body(
          color: palette.textSecondary,
          fontSize: 13,
        ),
        leadingAndTrailingTextStyle: MassoTypography.body(
          color: palette.textSecondary,
          fontSize: 13,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        textStyle: MassoTypography.body(
          color: palette.textPrimary,
          fontSize: 14,
        ),
        labelTextStyle: WidgetStatePropertyAll(
          MassoTypography.body(color: palette.textPrimary, fontSize: 14),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(palette.textPrimary),
          textStyle: WidgetStatePropertyAll(
            MassoTypography.body(color: palette.textPrimary, fontSize: 14),
          ),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: MassoTypography.body(
          color: palette.textPrimary,
          fontSize: 14,
        ),
      ),
      dividerColor: palette.divider,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.padded,
          foregroundColor: palette.textPrimary,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: frost.onAction,
          backgroundColor: frost.action,
          minimumSize: const Size.fromHeight(54),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: MassoTypography.display(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.padded,
          foregroundColor: palette.textPrimary,
          textStyle: MassoTypography.display(
            color: palette.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50),
          foregroundColor: palette.textPrimary,
          side: BorderSide.none,
          backgroundColor: muted.withValues(
            alpha: MaasoFrostTokens.capsuleFillAlpha,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          textStyle: MassoTypography.display(
            color: palette.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          side: const WidgetStatePropertyAll(BorderSide.none),
          foregroundColor: WidgetStatePropertyAll(palette.textPrimary),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? palette.surface : muted,
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          ),
          textStyle: WidgetStatePropertyAll(
            MassoTypography.display(
              color: palette.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: muted,
        selectedColor: palette.surface,
        disabledColor: muted,
        surfaceTintColor: Colors.transparent,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        elevation: 0,
        pressElevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        labelStyle: TextStyle(
          color: palette.textSecondary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: frost.accentText,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return palette.seed;
          return palette.textSecondary.withValues(alpha: 0.72);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return palette.seed.withValues(alpha: 0.28);
          }
          return palette.divider.withValues(alpha: 0.72);
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: palette.isDark
            ? const Color(0xFFF5F5F5)
            : const Color(0xFF171717),
        contentTextStyle: MassoTypography.body(
          color: palette.isDark ? Colors.black : Colors.white,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.card,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MaasoFrostTokens.sheetRadius),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.card.withValues(alpha: 0.98),
        modalBackgroundColor: palette.card.withValues(alpha: 0.98),
        modalBarrierColor: Colors.black.withValues(alpha: 0.48),
        elevation: 8,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.seed,
        selectionColor: palette.seed.withValues(alpha: 0.22),
        selectionHandleColor: palette.seed,
      ),
    );
  }
}
