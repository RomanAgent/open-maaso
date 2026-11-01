import 'package:flutter/material.dart';

class MassoTypography {
  static const String? displayFontFamily = null;
  static const String? bodyFontFamily = null;

  static TextStyle display({
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    double? height,
  }) {
    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      letterSpacing: -0.35,
    );
  }

  static TextStyle body({
    required Color color,
    required double fontSize,
    FontWeight? fontWeight,
    double? height,
    FontStyle? fontStyle,
  }) {
    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
      fontStyle: fontStyle,
      letterSpacing: -0.1,
    );
  }
}
