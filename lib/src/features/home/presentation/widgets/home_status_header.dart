import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';

import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/presentation/companion_avatar.dart';

/// Compact, account-owned status above the Home conversation.
class HomeStatusHeader extends StatelessWidget {
  const HomeStatusHeader({
    required this.avatar,
    required this.expanded,
    required this.onMenuToggle,
    required this.onTaskHistory,
    this.onProfile,
    super.key,
  });

  final bool avatar;
  final bool expanded;
  final VoidCallback onMenuToggle;
  final VoidCallback onTaskHistory;
  final VoidCallback? onProfile;

  static const double avatarDiameter = 40;

  /// Home positions the header 14 logical pixels inside the horizontal safe
  /// area. Keep its reserved height identical to the layout below.
  static double heightFor(BuildContext context) {
    return _controlsHeight(MediaQuery.textScalerOf(context));
  }

  static double _controlsHeight(TextScaler scaler) =>
      math.max(48.0, scaler.scale(14) * 1.25 + 16);

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final height = _controlsHeight(MediaQuery.textScalerOf(context));
    return SizedBox(
      key: const ValueKey('home-status-header'),
      height: height,
      child: Align(
        alignment: Alignment.centerRight,
        child: _controls(context, height),
      ),
    );
  });

  Widget _controls(BuildContext context, double height) {
    final glass = MaasoGlassTheme.of(context);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final profileService = appServices.maybeFind<CompanionProfileService>();
    final profile = profileService?.isCurrent == true
        ? profileService?.profile.value
        : null;
    final glassInset = math.max(
      0.0,
      (height - HomeStatusHeader.avatarDiameter) / 2,
    );
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppNativeFrostGroup(
            enabled: avatar,
            fit: StackFit.loose,
            topFadeHeight: 0,
            bottomFadeHeight: 0,
            child: Builder(
              builder: (context) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _actionButton(
                    context,
                    key: const ValueKey('home-task-history-button'),
                    icon: Icons.history_rounded,
                    tooltip: 'home.task.history'.tr,
                    onPressed: onTaskHistory,
                    height: height,
                    glassInset: glassInset,
                    color: glass.foregroundPrimary,
                  ),
                  const SizedBox(width: 8),
                  _actionButton(
                    context,
                    key: const ValueKey('home-menu-toggle'),
                    icon: expanded
                        ? Icons.close_rounded
                        : Icons.grid_view_rounded,
                    tooltip: expanded
                        ? 'home.menu_close'.tr
                        : 'home.menu_open'.tr,
                    onPressed: onMenuToggle,
                    height: height,
                    glassInset: glassInset,
                    color: glass.foregroundPrimary,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('home-profile-button'),
            tooltip: chinese ? '个人信息' : 'Personal information',
            onPressed: onProfile,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            padding: const EdgeInsets.all(4),
            icon: CompanionAvatar(
              profile: profile,
              size: HomeStatusHeader.avatarDiameter,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required double height,
    required double glassInset,
    required Color color,
  }) => SizedBox(
    width: 48,
    height: height,
    child: Stack(
      children: [
        Positioned.fill(
          top: glassInset,
          bottom: glassInset,
          left: 4,
          right: 4,
          child: AppNativeFrostRegion.available(context)
              ? const AppNativeFrostRegion(radius: 20, child: SizedBox.expand())
              : const MaasoGlassBackdropScope(
                  backdropKind: GlassBackdropKind.flutter,
                  renderMode: GlassRenderMode.frosted,
                  allowBlur: false,
                  child: AppFrostedInputBackground(cornerRadius: 20),
                ),
        ),
        Center(
          child: IconButton(
            key: key,
            tooltip: tooltip,
            onPressed: onPressed,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            icon: Icon(icon, size: 18, color: color),
          ),
        ),
      ],
    ),
  );
}
