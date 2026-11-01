import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

@immutable
class AppSecondaryPalette {
  const AppSecondaryPalette({
    required this.backgroundStart,
    required this.backgroundEnd,
    required this.surface,
    required this.surfaceMuted,
    required this.selectedSurface,
    required this.dangerSurface,
    required this.border,
    required this.shadow,
  });

  final Color backgroundStart;
  final Color backgroundEnd;
  final Color surface;
  final Color surfaceMuted;
  final Color selectedSurface;
  final Color dangerSurface;
  final Color border;
  final Color shadow;

  static AppSecondaryPalette of(BuildContext context) =>
      resolve(Theme.of(context).brightness);

  static AppSecondaryPalette resolve(Brightness brightness) {
    if (brightness == Brightness.dark) {
      const surface = MaasoFrostTokens.darkSurface;
      return AppSecondaryPalette(
        backgroundStart: MaasoFrostTokens.darkCanvas,
        backgroundEnd: MaasoFrostTokens.darkCanvas,
        surface: surface,
        surfaceMuted: MaasoFrostTokens.darkMuted,
        selectedSurface: MaasoFrostTokens.darkAccentSoft,
        dangerSurface: Color.alphaBlend(const Color(0x26FF453A), surface),
        border: MaasoFrostTokens.darkDivider,
        shadow: const Color(0x52000000),
      );
    }
    const surface = MaasoFrostTokens.lightCanvas;
    return AppSecondaryPalette(
      backgroundStart: MaasoFrostTokens.lightCanvas,
      backgroundEnd: MaasoFrostTokens.lightCanvas,
      surface: surface,
      surfaceMuted: MaasoFrostTokens.lightMuted,
      selectedSurface: MaasoFrostTokens.lightAccentSoft,
      dangerSurface: Color.alphaBlend(const Color(0x18FF3B30), surface),
      border: MaasoFrostTokens.lightDivider,
      shadow: const Color(0x14000000),
    );
  }
}
