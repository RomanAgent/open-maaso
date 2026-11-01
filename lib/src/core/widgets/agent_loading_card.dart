import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';
import 'package:maaso/src/core/widgets/ui/app_card.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Cards stacked above the chat input that show the live model-download
/// state as one aggregate progress bar even when subsystems download in
/// parallel.
///
/// Sits inside [AgentCardStack] on top of the action queue, so users see
/// every active status without the loading UI ever crowding the avatar.
class AgentLoadingCards extends StatelessWidget {
  const AgentLoadingCards({super.key});

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<AgentBootController>()) {
      return const SizedBox.shrink();
    }
    final boot = appServices.find<AgentBootController>();
    return AppReactiveBuilder(() {
      if (boot.modelLoading.value) {
        return _LoadingCard(
          icon: '↓',
          label: 'loading.models_loading'.tr,
          progress: boot.modelProgress.value,
          received: boot.modelReceivedBytes.value,
          total: boot.modelTotalBytes.value,
          etaSeconds: boot.modelEtaSeconds.value,
        );
      }
      // Optional model initialization is not a Home startup failure. Keep
      // errors and recovery beside the feature that requested the model.
      return const SizedBox.shrink();
    });
  }
}

// ─────────────────── loading card ───────────────────

class _LoadingCard extends StatelessWidget {
  final String icon;
  final String label;
  final double progress;
  final int received;
  final int total;
  final int? etaSeconds;

  const _LoadingCard({
    required this.icon,
    required this.label,
    required this.progress,
    required this.received,
    required this.total,
    required this.etaSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final indeterminate = progress < 0 || total <= 0;
    final pct = indeterminate ? null : (progress.clamp(0.0, 1.0) * 100).round();
    final subtitle = _subtitle(indeterminate);

    return AppCard(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      panelTintOpacity: 0.26,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                icon,
                style: TextStyle(fontSize: 16, color: glass.foregroundPrimary),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: glass.foregroundPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (pct != null)
                Text(
                  '$pct%',
                  style: TextStyle(
                    fontSize: 12,
                    color: glass.foregroundSecondary,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                )
              else
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: ColorConstant.primaryColor,
                  ),
                ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 11,
                color: glass.foregroundSecondary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: indeterminate ? null : progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: Colors.black.withValues(alpha: 0.08),
              valueColor: const AlwaysStoppedAnimation<Color>(
                ColorConstant.primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _subtitle(bool indeterminate) {
    final pieces = <String>[];
    if (!indeterminate && total > 0) {
      pieces.add('${_humanBytes(received)} / ${_humanBytes(total)}');
    } else if (received > 0) {
      pieces.add(_humanBytes(received));
    }
    final eta = etaSeconds;
    if (eta != null && eta > 0) {
      pieces.add(
        'loading.remaining'.trParams({'duration': _humanDuration(eta)}),
      );
    }
    if (pieces.isEmpty) return null;
    return pieces.join(' · ');
  }

  static String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final precision = (v < 10 && i > 0) ? 1 : 0;
    return '${v.toStringAsFixed(precision)} ${units[i]}';
  }

  static String _humanDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return s == 0 ? '${m}m' : '${m}m ${s}s';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '${h}h' : '${h}h ${mm}m';
  }
}
