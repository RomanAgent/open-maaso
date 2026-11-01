import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

/// Shared notification material for top notices and ScaffoldMessenger notices.
/// Foreground colors always come from the same palette as the frosted surface.
class AppGlassNoticeSurface extends StatelessWidget {
  const AppGlassNoticeSurface({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    this.cornerRadius = MaasoFrostTokens.compactRadius,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double cornerRadius;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final textStyle =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: glass.foregroundPrimary,
          decoration: TextDecoration.none,
          decorationColor: Colors.transparent,
        );
    return AppGlassSurface(
      role: AppGlassSurfaceRole.transient,
      // The root notice host sits outside routes. Without an explicit scope,
      // the visible backdrop may be a Unity/WebView native surface.
      blur:
          MaasoGlassBackdropScope.maybeOf(context)?.backdropKind ==
          GlassBackdropKind.flutter,
      cornerRadius: cornerRadius,
      child: Material(
        type: MaterialType.transparency,
        textStyle: textStyle,
        child: IconTheme.merge(
          data: IconThemeData(color: glass.foregroundPrimary),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Keeps ScaffoldMessenger queuing/dismissal while using the app's notice shell.
SnackBar appGlassSnackBar({
  required Widget content,
  Duration duration = const Duration(seconds: 4),
  EdgeInsetsGeometry? margin,
  EdgeInsetsGeometry? padding,
  double? cornerRadius,
}) => SnackBar(
  content: AppGlassNoticeSurface(
    padding:
        padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    cornerRadius: cornerRadius ?? MaasoFrostTokens.compactRadius,
    child: content,
  ),
  duration: duration,
  behavior: SnackBarBehavior.floating,
  backgroundColor: Colors.transparent,
  elevation: 0,
  margin: margin,
  padding: EdgeInsets.zero,
  clipBehavior: Clip.none,
);
