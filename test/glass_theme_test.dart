import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

void main() {
  test('White Frost constants stay aligned with the durable design anchor', () {
    final tokens =
        jsonDecode(
              File(
                'design-system/maaso-soft-frost/tokens.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(tokens['id'], MaasoFrostTokens.themeId);
    expect(tokens['size']['touchMin'], MaasoGlassTheme.controlTarget);
    expect(tokens['radius']['card'], MaasoGlassTheme.surfaceRadius);
    expect(tokens['radius']['input'], MaasoGlassTheme.fieldRadius);
    expect(tokens['radius']['sheet'], MaasoGlassTheme.sheetRadius);
    expect(
      tokens['material']['frostedChromeBlurSigma'],
      MaasoFrostTokens.blurSigma,
    );
    expect(
      tokens['motionMs']['pressed'],
      MaasoGlassTheme.motionFast.inMilliseconds,
    );
    expect(
      tokens['motionMs']['segment'],
      MaasoGlassTheme.motionStandard.inMilliseconds,
    );
    expect(
      tokens['motionMs']['panel'],
      MaasoGlassTheme.motionEmphasized.inMilliseconds,
    );
  });

  test('light and dark frost have no rim, refraction or list blur', () {
    for (final brightness in Brightness.values) {
      final glass = MaasoGlassTheme.fromPalette(
        AppPalette.of(brightness, AppAccent.blue),
      );
      expect(glass.border.a, 0);
      expect(glass.staticBorder.a, 0);
      expect(glass.staticTint.a, 1);
      expect(glass.staticBlur, 0);
      expect(glass.distortion, 0);
      expect(glass.chromaticAberration, 0);
      expect(glass.tint.a, closeTo(.84, .005));
      expect(glass.tint.r, closeTo(glass.surface.r, .001));
      expect(glass.tint.g, closeTo(glass.surface.g, .001));
      expect(glass.tint.b, closeTo(glass.surface.b, .001));
    }
  });

  test('persisted accents retain white-label action contrast', () {
    for (final brightness in Brightness.values) {
      for (final accent in AppAccent.values) {
        final glass = MaasoGlassTheme.fromPalette(
          AppPalette.of(brightness, accent),
        );
        final contrast =
            (glass.onAction.computeLuminance() + .05) /
            (glass.action.computeLuminance() + .05);
        expect(
          contrast,
          greaterThanOrEqualTo(4.5),
          reason: '$brightness $accent',
        );
        expect(glass.action.a, 1);
        final textLuminance = glass.accentText.computeLuminance();
        final fillLuminance = glass.accentSoft.computeLuminance();
        final textContrast = textLuminance > fillLuminance
            ? (textLuminance + .05) / (fillLuminance + .05)
            : (fillLuminance + .05) / (textLuminance + .05);
        expect(
          textContrast,
          greaterThanOrEqualTo(4.5),
          reason: '$brightness $accent chip',
        );
        if (accent == AppAccent.blue) {
          expect(
            glass.accentText,
            brightness == Brightness.dark
                ? MaasoFrostTokens.darkAccent
                : MaasoFrostTokens.lightAccent,
          );
          expect(
            glass.accentSoft,
            brightness == Brightness.dark
                ? MaasoFrostTokens.darkAccentSoft
                : MaasoFrostTokens.lightAccentSoft,
          );
        }
      }
    }
  });

  test('AppTheme installs matching compatible extensions', () {
    for (final brightness in Brightness.values) {
      final palette = AppPalette.of(brightness, AppAccent.cyan);
      final glass = AppTheme.build(palette).extension<MaasoGlassTheme>();
      expect(glass, isNotNull);
      expect(glass?.brightness, brightness);
      expect(glass?.accent, palette.seed);
      expect(glass!.copyWith(accent: Colors.red).accent, Colors.red);
      expect(glass.lerp(glass, .5).foregroundPrimary, glass.foregroundPrimary);
    }
  });
}
