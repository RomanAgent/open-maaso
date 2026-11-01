import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

/// Accent (seed) colour the agent can pick for the active theme.
///
/// Each accent maps to a single seed [Color]; the rest of the palette
/// (background / surface / text) is derived per-brightness in [AppPalette].
/// Keys are persisted on [AgentProfile.themeAccent] — keep them frozen.
enum AppAccent {
  blue('blue', MaasoFrostTokens.action),
  graphite('graphite', Color(0xFF8E8E93)),
  indigo('indigo', Color(0xFF5856D6)),
  cyan('cyan', Color(0xFF5AC8FA)),
  green('green', Color(0xFF34C759)),
  pink('pink', Color(0xFFFF2D55));

  const AppAccent(this.key, this.seed);

  /// Stable string persisted in [AgentProfile.themeAccent] and resolved by
  /// [ThemeService].
  final String key;

  /// Seed colour fed to [ColorScheme.fromSeed] + used as the app primary.
  final Color seed;

  /// Tolerant parse — unknown / null falls back to the default accent so old
  /// rows and bad LLM input never crash the UI.
  static AppAccent fromKey(String? key) => AppAccent.values.firstWhere(
    (a) => a.key == key,
    orElse: () => AppAccent.blue,
  );

  /// Short human label for the settings picker.
  String get label => switch (this) {
    AppAccent.blue => 'Blue',
    AppAccent.graphite => 'Graphite',
    AppAccent.indigo => 'Indigo',
    AppAccent.cyan => 'Cyan',
    AppAccent.green => 'Green',
    AppAccent.pink => 'Pink',
  };
}

/// The fully-resolved set of colours for one (brightness, accent) combination.
///
/// Light mode uses the Maaso White Frost palette; dark mode supplies the
/// matching elevated system surfaces. The accent's [AppAccent.seed] becomes
/// the primary in both.
class AppPalette {
  const AppPalette({
    required this.brightness,
    required this.accent,
    required this.seed,
    required this.background,
    required this.surface,
    required this.card,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
  });

  final Brightness brightness;
  final AppAccent accent;
  final Color seed;
  final Color background;
  final Color surface;
  final Color card;
  final Color textPrimary;
  final Color textSecondary;
  final Color divider;

  bool get isDark => brightness == Brightness.dark;

  /// Resolve the palette for a brightness + accent.
  static AppPalette of(Brightness brightness, AppAccent accent) {
    final seed = accent.seed;
    if (brightness == Brightness.dark) {
      const bg = MaasoFrostTokens.darkCanvas;
      const surface = MaasoFrostTokens.darkSurface;
      return AppPalette(
        brightness: Brightness.dark,
        accent: accent,
        seed: seed,
        background: bg,
        surface: surface,
        card: MaasoFrostTokens.darkSurface,
        textPrimary: MaasoFrostTokens.darkTextPrimary,
        textSecondary: MaasoFrostTokens.darkTextSecondary,
        divider: MaasoFrostTokens.darkDivider,
      );
    }
    return AppPalette(
      brightness: Brightness.light,
      accent: accent,
      seed: seed,
      background: ColorConstant.backgroundColor,
      surface: ColorConstant.surfaceColor,
      card: ColorConstant.cardColor,
      textPrimary: ColorConstant.textPrimary,
      textSecondary: ColorConstant.textSecondary,
      divider: ColorConstant.divider,
    );
  }
}
