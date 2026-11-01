import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

class AppGlassDialog extends StatelessWidget {
  const AppGlassDialog({
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = const EdgeInsets.all(24),
    this.maxWidth = 440,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AppGlassSurface(
        role: AppGlassSurfaceRole.transient,
        behavior: AppGlassSurfaceBehavior.automatic,
        margin: margin,
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: padding,
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}

class AppGlassSheet extends StatelessWidget {
  const AppGlassSheet({
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.transient,
      behavior: AppGlassSurfaceBehavior.automatic,
      width: double.infinity,
      padding: padding,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(top: false, child: child),
      ),
    );
  }
}

class AppGlassNotice extends StatelessWidget {
  const AppGlassNotice({
    required this.title,
    required this.message,
    this.icon,
    super.key,
  });

  final String title;
  final String message;
  final IconData? icon;

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show({
    required String title,
    required String message,
    IconData? icon,
    Duration duration = const Duration(seconds: 3),
  }) {
    return showAppGlassNotice(
      title: title,
      message: message,
      icon: icon,
      duration: duration,
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      excludeSemantics: true,
      label: '$title. $message',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 20, color: glass.foregroundPrimary),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.3,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> showAppGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String? barrierLabel,
}) {
  final reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.24),
    transitionDuration: reducedMotion
        ? Duration.zero
        : MaasoGlassTheme.motionStandard,
    pageBuilder: (dialogContext, _, _) {
      return SafeArea(child: AppGlassDialog(child: builder(dialogContext)));
    },
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

Future<T?> showAppGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool enableDrag = true,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    isScrollControlled: isScrollControlled,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.22),
    elevation: 0,
    builder: (sheetContext) => AppGlassSheet(child: builder(sheetContext)),
  );
}

ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showAppGlassNotice({
  required String title,
  required String message,
  IconData? icon,
  Duration duration = const Duration(seconds: 3),
}) {
  return appNavigation.showSnackBar(
    snackPosition: AppSnackPosition.top,
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    duration: duration,
    messageText: AppGlassNotice(title: title, message: message, icon: icon),
  );
}
