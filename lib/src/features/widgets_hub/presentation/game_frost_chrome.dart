import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

/// Shares one backdrop input across the fixed discovery controls. Only the
/// rounded controls sample it; the spaces and counts between them stay clear.
class GameFrostGroup extends StatelessWidget {
  const GameFrostGroup({required this.child, super.key});
  static const blurKey = ValueKey('game-feed-shared-rail-frost');
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!_canSampleGameBackdrop(context)) return child;
    return BackdropGroup(key: blurKey, child: child);
  }
}

bool _canSampleGameBackdrop(BuildContext context) {
  final scope = MaasoGlassBackdropScope.maybeOf(context);
  final media = MediaQuery.of(context);
  final service = appServices.maybeFind<GlassUiService>();
  return (scope == null || scope.backdropKind == GlassBackdropKind.flutter) &&
      !media.highContrast &&
      !media.accessibleNavigation &&
      service?.forceFrosted.value != true &&
      service?.shaderFailed.value != true &&
      scope?.allowBlur != false;
}

/// Borderless neutral frost for controls over immersive game artwork.
/// Fixed discovery controls share the group's Flutter cover input. Controls
/// over a platform player use the same material's non-sampling fallback.
class GameFrostChrome extends StatelessWidget {
  const GameFrostChrome({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.blur = false,
    super.key,
  });

  static const canvas = Color(0xFF0D0D0D);
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    // A surrounding group must not bypass this control's host/accessibility
    // policy when GameFrostGroup itself takes the non-sampling path.
    final grouped =
        BackdropGroup.of(context) != null && _canSampleGameBackdrop(context);
    final surface = AppGlassSurface(
      role: AppGlassSurfaceRole.chrome,
      tintColor: MaasoFrostTokens.darkMuted.withValues(
        alpha: MaasoFrostTokens.blurredCapsuleFillAlpha,
      ),
      cornerRadius: MaasoGlassTheme.capsuleRadius,
      padding: padding,
      blur: blur && !grouped,
      child: child,
    );
    if (!grouped) return surface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MaasoGlassTheme.capsuleRadius),
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(
          sigmaX: MaasoFrostTokens.blurSigma,
          sigmaY: MaasoFrostTokens.blurSigma,
        ),
        child: surface,
      ),
    );
  }
}

class GameFrostIconButton extends StatelessWidget {
  const GameFrostIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.foregroundColor = Colors.white,
    this.busy = false,
    this.blur = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color foregroundColor;
  final bool busy;
  final bool blur;

  @override
  Widget build(BuildContext context) => GameFrostChrome(
    blur: blur,
    child: IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        maximumSize: const Size.square(48),
        foregroundColor: foregroundColor,
        disabledForegroundColor: foregroundColor.withValues(alpha: .42),
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
      ),
      icon: busy
          ? SizedBox.square(
              dimension: 18,
              child: MediaQuery.disableAnimationsOf(context)
                  ? Icon(
                      Icons.hourglass_top_rounded,
                      color: foregroundColor,
                      size: 18,
                    )
                  : CircularProgressIndicator(
                      color: foregroundColor,
                      strokeWidth: 2,
                    ),
            )
          : Icon(icon, size: 24),
    ),
  );
}
