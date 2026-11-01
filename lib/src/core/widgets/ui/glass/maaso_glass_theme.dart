import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';

@immutable
class MaasoGlassTheme extends ThemeExtension<MaasoGlassTheme> {
  const MaasoGlassTheme({
    required this.brightness,
    required this.accent,
    required this.foregroundPrimary,
    required this.foregroundSecondary,
    required this.tint,
    required this.staticTint,
    required this.staticBorder,
    required this.staticShadow,
    required this.border,
    required this.shadow,
    required this.blur,
    required this.staticBlur,
    required this.distortion,
    required this.distortionWidth,
    required this.chromaticAberration,
  });

  factory MaasoGlassTheme.light(AppPalette palette) =>
      MaasoGlassTheme.fromPalette(palette);

  factory MaasoGlassTheme.dark(AppPalette palette) =>
      MaasoGlassTheme.fromPalette(palette);

  factory MaasoGlassTheme.fromPalette(AppPalette palette) {
    final surface = palette.isDark
        ? MaasoFrostTokens.darkSurface
        : MaasoFrostTokens.lightSurface;
    return MaasoGlassTheme(
      brightness: palette.brightness,
      accent: palette.seed,
      foregroundPrimary: palette.textPrimary,
      foregroundSecondary: palette.textSecondary,
      tint: surface.withValues(alpha: MaasoFrostTokens.capsuleFillAlpha),
      staticTint: palette.isDark
          ? MaasoFrostTokens.darkMuted
          : MaasoFrostTokens.lightMuted,
      staticBorder: Colors.transparent,
      staticShadow: Colors.black.withValues(
        alpha: palette.isDark ? 0.16 : 0.04,
      ),
      border: Colors.transparent,
      shadow: Colors.black.withValues(alpha: palette.isDark ? 0.16 : 0.04),
      blur: MaasoFrostTokens.blurSigma,
      staticBlur: 0,
      distortion: 0,
      distortionWidth: 0,
      chromaticAberration: 0,
    );
  }

  static MaasoGlassTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<MaasoGlassTheme>() ??
        MaasoGlassTheme.fromPalette(
          AppPalette.of(theme.brightness, AppAccent.blue),
        );
  }

  static const double controlTarget = MaasoFrostTokens.touchMin;
  static const double chromeRadius = MaasoFrostTokens.pillRadius;
  static const double fieldRadius = MaasoFrostTokens.inputRadius;
  static const double surfaceRadius = MaasoFrostTokens.cardRadius;
  static const double sheetRadius = MaasoFrostTokens.sheetRadius;
  static const double capsuleRadius = MaasoFrostTokens.pillRadius;
  static const double staticShadowBlur = 12;
  static const Offset staticShadowOffset = Offset(0, 3);

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double space2Xl = 32;

  static const Duration motionFast = MaasoFrostTokens.motionPressed;
  static const Duration motionStandard = MaasoFrostTokens.motionSegment;
  static const Duration motionEmphasized = MaasoFrostTokens.motionPanel;

  final Brightness brightness;
  final Color accent;
  final Color foregroundPrimary;
  final Color foregroundSecondary;
  final Color tint;
  final Color staticTint;
  final Color staticBorder;
  final Color staticShadow;
  final Color border;
  final Color shadow;
  final double blur;
  final double staticBlur;
  final double distortion;
  final double distortionWidth;
  final double chromaticAberration;

  Color get surface => brightness == Brightness.dark
      ? MaasoFrostTokens.darkSurface
      : MaasoFrostTokens.lightSurface;
  Color get muted => brightness == Brightness.dark
      ? MaasoFrostTokens.darkMuted
      : MaasoFrostTokens.lightMuted;
  Color get divider => brightness == Brightness.dark
      ? MaasoFrostTokens.darkDivider
      : MaasoFrostTokens.lightDivider;
  Color get accentSoft {
    if (accent == MaasoFrostTokens.action) {
      return brightness == Brightness.dark
          ? MaasoFrostTokens.darkAccentSoft
          : MaasoFrostTokens.lightAccentSoft;
    }
    return Color.alphaBlend(
      accent.withValues(alpha: brightness == Brightness.dark ? .20 : .10),
      surface,
    );
  }

  Color get accentText {
    if (accent == MaasoFrostTokens.action) {
      return brightness == Brightness.dark
          ? MaasoFrostTokens.darkAccent
          : MaasoFrostTokens.lightAccent;
    }
    final isDark = brightness == Brightness.dark;
    var color = isDark ? accent.withValues(alpha: 1) : action;
    final hsl = HSLColor.fromColor(color);
    var lightness = hsl.lightness;
    while (_contrastRatio(color, accentSoft) < 4.5 &&
        (isDark ? lightness < 1 : lightness > 0)) {
      lightness = (lightness + (isDark ? .01 : -.01)).clamp(0.0, 1.0);
      color = hsl.withLightness(lightness).toColor();
    }
    return color;
  }

  Color get onAction => MaasoFrostTokens.onAction;

  /// User accents stay recognizable while white action labels remain readable.
  Color get action {
    var color = accent.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(color);
    var lightness = hsl.lightness;
    while ((1.05 / (color.computeLuminance() + 0.05)) < 4.5 && lightness > 0) {
      lightness = (lightness - 0.01).clamp(0.0, 1.0);
      color = hsl.withLightness(lightness).toColor();
    }
    return color;
  }

  @override
  MaasoGlassTheme copyWith({
    Brightness? brightness,
    Color? accent,
    Color? foregroundPrimary,
    Color? foregroundSecondary,
    Color? tint,
    Color? staticTint,
    Color? staticBorder,
    Color? staticShadow,
    Color? border,
    Color? shadow,
    double? blur,
    double? staticBlur,
    double? distortion,
    double? distortionWidth,
    double? chromaticAberration,
  }) {
    return MaasoGlassTheme(
      brightness: brightness ?? this.brightness,
      accent: accent ?? this.accent,
      foregroundPrimary: foregroundPrimary ?? this.foregroundPrimary,
      foregroundSecondary: foregroundSecondary ?? this.foregroundSecondary,
      tint: tint ?? this.tint,
      staticTint: staticTint ?? this.staticTint,
      staticBorder: staticBorder ?? this.staticBorder,
      staticShadow: staticShadow ?? this.staticShadow,
      border: border ?? this.border,
      shadow: shadow ?? this.shadow,
      blur: blur ?? this.blur,
      staticBlur: staticBlur ?? this.staticBlur,
      distortion: distortion ?? this.distortion,
      distortionWidth: distortionWidth ?? this.distortionWidth,
      chromaticAberration: chromaticAberration ?? this.chromaticAberration,
    );
  }

  @override
  MaasoGlassTheme lerp(covariant MaasoGlassTheme? other, double t) {
    if (other == null) return this;
    return MaasoGlassTheme(
      brightness: t < 0.5 ? brightness : other.brightness,
      accent: Color.lerp(accent, other.accent, t)!,
      foregroundPrimary: Color.lerp(
        foregroundPrimary,
        other.foregroundPrimary,
        t,
      )!,
      foregroundSecondary: Color.lerp(
        foregroundSecondary,
        other.foregroundSecondary,
        t,
      )!,
      tint: Color.lerp(tint, other.tint, t)!,
      staticTint: Color.lerp(staticTint, other.staticTint, t)!,
      staticBorder: Color.lerp(staticBorder, other.staticBorder, t)!,
      staticShadow: Color.lerp(staticShadow, other.staticShadow, t)!,
      border: Color.lerp(border, other.border, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      blur: _lerpDouble(blur, other.blur, t),
      staticBlur: _lerpDouble(staticBlur, other.staticBlur, t),
      distortion: _lerpDouble(distortion, other.distortion, t),
      distortionWidth: _lerpDouble(distortionWidth, other.distortionWidth, t),
      chromaticAberration: _lerpDouble(
        chromaticAberration,
        other.chromaticAberration,
        t,
      ),
    );
  }

  static double _lerpDouble(double a, double b, double t) {
    return a + (b - a) * t;
  }

  static double _contrastRatio(Color a, Color b) {
    final first = a.computeLuminance();
    final second = b.computeLuminance();
    return first > second
        ? (first + .05) / (second + .05)
        : (second + .05) / (first + .05);
  }
}
