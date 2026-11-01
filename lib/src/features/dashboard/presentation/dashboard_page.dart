import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/dashboard/application/dashboard_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/tts_warmup_service.dart';
import 'package:maaso/src/core/utils/byte_format.dart';

/// "Info Dashboard" — what used to live on the home pet-screen before the 3D avatar became
/// it over.  Status chips, TTS warm-up progress, quick-action grid.
class DashboardPage extends AppView<DashboardController> {
  const DashboardPage({super.key});

  static const compactLayoutKey = ValueKey<String>('dashboard-compact-layout');
  static const wideLayoutKey = ValueKey<String>('dashboard-wide-layout');

  @override
  Widget build(BuildContext context) {
    return AppSecondaryScaffold(
      contentMaxWidth: 1180,
      header: AppSecondaryHeader(
        title: 'dashboard.title'.tr,
        onBack: () => appNavigation.pop(),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final useWideLayout = constraints.maxWidth >= 900;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              key: useWideLayout ? wideLayoutKey : compactLayoutKey,
              children: [
                const _TtsWarmupBanner(),
                const SizedBox(height: 8),
                if (useWideLayout)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(flex: 5, child: _StatusRow()),
                      const SizedBox(width: 16),
                      const Expanded(flex: 7, child: _QuickActions()),
                    ],
                  )
                else ...<Widget>[
                  _StatusRow(),
                  const SizedBox(height: 16),
                  const _QuickActions(),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TtsWarmupBanner extends StatelessWidget {
  const _TtsWarmupBanner();

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<TtsWarmupService>()) {
      return const SizedBox.shrink();
    }
    final glass = MaasoGlassTheme.of(context);
    final svc = appServices.find<TtsWarmupService>();
    return AppReactiveBuilder(() {
      if (svc.isReady.value) return const SizedBox.shrink();
      final pct = (svc.progress.value * 100).clamp(0, 100).toStringAsFixed(0);
      // Compose the inflight hint from byte counters + ETA when we have
      // them; fall back to the old "checking cache" line before any
      // bytes have streamed in (or during extraction phase where total
      // bytes drops back to 0).
      String inflightHint() {
        final total = svc.totalBytes.value;
        final got = svc.downloadedBytes.value;
        if (total <= 0) return 'dashboard.tts_checking_cache'.tr;
        final eta = svc.etaSeconds.value;
        final left = eta == null
            ? ''
            : '  ·  ${'common.left_duration'.trParams({'duration': formatDuration(eta)})}';
        return 'dashboard.tts_downloading'.trParams({
          'received': formatBytes(got),
          'total': formatBytes(total),
          'eta': left,
        });
      }

      final hint = svc.isFailed.value
          ? 'dashboard.tts_failed'.tr
          : inflightHint();

      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: AppSecondaryCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          cornerRadius: 18,
          child: Row(
            children: [
              Icon(
                svc.isFailed.value
                    ? Icons.warning_amber_rounded
                    : Icons.graphic_eq_rounded,
                size: 16,
                color: svc.isFailed.value
                    ? ColorConstant.errorColor
                    : ColorConstant.primaryColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: glass.foregroundPrimary,
                            ),
                          ),
                        ),
                        if (!svc.isFailed.value)
                          Text(
                            '$pct%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: glass.foregroundPrimary,
                            ),
                          ),
                        if (svc.isFailed.value)
                          InkWell(
                            onTap: svc.retry,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.refresh_rounded,
                                    size: 13,
                                    color: ColorConstant.primaryColor,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'common.retry'.tr,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: glass.foregroundPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (svc.isFailed.value && svc.error.value != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'dashboard.tts_failed'.tr,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: glass.foregroundSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        value: svc.isFailed.value
                            ? 0
                            : (svc.isRunning.value && svc.progress.value <= 0
                                  ? null
                                  : svc.progress.value),
                        backgroundColor: ColorConstant.divider,
                        valueColor: AlwaysStoppedAnimation(
                          svc.isFailed.value
                              ? ColorConstant.errorColor
                              : ColorConstant.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _StatusRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = appServices.find<DashboardController>();
    return Row(
      children: [
        Expanded(
          child: AppReactiveBuilder(
            () => _StatusChip(
              icon: Icons.battery_charging_full,
              label: 'dashboard.status_battery'.tr,
              value: "${c.batteryLevel.value}%",
              color: ColorConstant.secondaryColor,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppReactiveBuilder(
            () => _StatusChip(
              icon: Icons.wifi,
              label: 'dashboard.status_network'.tr,
              value: c.isOnline.value
                  ? 'dashboard.status_online'.tr
                  : 'dashboard.status_offline'.tr,
              color: ColorConstant.primaryColor,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: AppReactiveBuilder(
            () => _StatusChip(
              icon: Icons.bluetooth,
              label: 'dashboard.status_hardware'.tr,
              value: c.isBluetoothLinked.value
                  ? 'dashboard.status_connected'.tr
                  : 'dashboard.status_disconnected'.tr,
              color: ColorConstant.accentColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppSecondaryCard(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      cornerRadius: 20,
      child: Column(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final actions = <_Action>[
      _Action(
        icon: Icons.favorite_rounded,
        title: 'dashboard.action_story'.tr,
        subtitle: 'dashboard.action_story_subtitle'.tr,
        color: ColorConstant.primaryColor,
        onTap: () => appNavigation.push(AppRouteCatalog.memoryWall),
      ),
      _Action(
        icon: Icons.history_rounded,
        title: 'dashboard.action_history'.tr,
        subtitle: 'dashboard.action_history_subtitle'.tr,
        color: ColorConstant.primaryColor,
        onTap: () => appNavigation.push(AppRouteCatalog.u2aChat),
      ),
      _Action(
        icon: Icons.auto_stories_rounded,
        title: 'dashboard.action_moments'.tr,
        subtitle: 'dashboard.action_moments_subtitle'.tr,
        color: ColorConstant.accentColor,
        onTap: () => appNavigation.push(AppRouteCatalog.moments),
      ),
      _Action(
        icon: Icons.extension_rounded,
        title: 'dashboard.action_skills'.tr,
        subtitle: 'dashboard.action_skills_subtitle'.tr,
        color: ColorConstant.primaryColor,
        onTap: () => appNavigation.push(AppRouteCatalog.skills),
      ),
      _Action(
        icon: Icons.dashboard_customize_rounded,
        title: 'dashboard.action_garden'.tr,
        subtitle: 'dashboard.action_garden_subtitle'.tr,
        color: ColorConstant.primaryColor,
        onTap: () => appNavigation.push(AppRouteCatalog.widgetsHub),
      ),
      _Action(
        icon: Icons.settings_rounded,
        title: 'dashboard.action_settings'.tr,
        subtitle: 'dashboard.action_settings_subtitle'.tr,
        color: ColorConstant.primaryColor,
        onTap: () => appNavigation.push(AppRouteCatalog.settings),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 3 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: columns == 3 ? 1.75 : 1.55,
          ),
          itemCount: actions.length,
          itemBuilder: (_, i) => actions[i],
        );
      },
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppSecondaryCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          AppGlassIconButton(
            icon: Icons.arrow_forward_rounded,
            tooltip: title,
            onPressed: onTap,
            size: 36,
            iconSize: 18,
            color: color.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}
