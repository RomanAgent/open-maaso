import 'package:flutter/material.dart';

/// Shared values from design-system/maaso-soft-frost/tokens.json.
/// Keep native widgets and offline generated surfaces on this same theme.
abstract final class MaasoFrostTokens {
  static const themeId = 'maaso-white-frost/v2';

  static const lightCanvas = Color(0xFFFFFFFF);
  static const darkCanvas = Color(0xFF101216);
  static const lightSurface = Color(0xFFFFFFFF);
  static const darkSurface = Color(0xFF1C2026);
  static const lightMuted = Color(0xFFF5F6F8);
  static const darkMuted = Color(0xFF282D35);
  static const lightTextPrimary = Color(0xFF202124);
  static const darkTextPrimary = Color(0xFFF6F8FC);
  static const lightTextSecondary = Color(0xFF5F636B);
  static const darkTextSecondary = Color(0xFFBCC3CE);
  static const action = Color(0xFF3B6DE4);
  static const composerAction = Color(0xFF000000);
  static const onAction = Color(0xFFFFFFFF);
  static const lightUserMessage = Color(0xFF24272B);
  static const lightOnUserMessage = Color(0xFFFFFFFF);
  static const darkUserMessage = Color(0xFFE7E9ED);
  static const darkOnUserMessage = Color(0xFF202124);
  static const lightAccent = Color(0xFF315FCC);
  static const darkAccent = Color(0xFF9ABBFF);
  static const lightAccentSoft = Color(0xFFEEF4FF);
  static const darkAccentSoft = Color(0xFF172945);
  static const lightDivider = Color(0xFFE5E7EB);
  static const darkDivider = Color(0xFF3A414C);
  static const lightControlBorder = Color(0xFF7D8590);
  static const darkControlBorder = Color(0xFF8B95A4);
  static const lightSuccess = Color(0xFF38654F);
  static const darkSuccess = Color(0xFF9DCEB1);
  static const lightDanger = Color(0xFFA13B4C);
  static const darkDanger = Color(0xFFF0A9B6);

  static const double touchMin = 48;
  static const double blurSigma = 8;
  static const double capsuleFillAlpha = 0.84;
  static const double inputFillAlpha = 0.86;
  // Blurred backgrounds already diffuse detail; avoid painting them opaque.
  static const double blurredInputFillAlpha = 0.64;
  static const double blurredCapsuleFillAlpha = 0.68;
  static const double messageFillAlpha = 0.82;
  static const double messageUserFillAlpha = 0.96;
  static const double overlayFillAlpha = 0.94;
  static const double cardRadius = 24;
  static const double inputRadius = 20;
  static const double compactRadius = 16;
  static const double messageRadius = 12;
  static const double sheetRadius = 28;
  static const double pillRadius = 999;

  static const motionPressed = Duration(milliseconds: 120);
  static const motionSegment = Duration(milliseconds: 180);
  static const motionPanel = Duration(milliseconds: 220);
}
