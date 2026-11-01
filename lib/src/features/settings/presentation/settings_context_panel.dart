import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/context_stats_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

/// A compact, read-only view of the active account's latest context estimate.
class SettingsContextPanel extends StatelessWidget {
  const SettingsContextPanel({super.key});

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: appProviderContainer,
    child: Consumer(
      builder: (context, ref, _) {
        ref.watch(appServiceGraphRevisionProvider);
        final service = appServices.peek<ContextStatsService>();
        if (service == null || service.isClosed) {
          return const SizedBox.shrink();
        }
        return _ContextPanel(
          key: ObjectKey(service),
          snapshot: service.snapshot.watch(ref),
        );
      },
    ),
  );
}

class _ContextPanel extends StatefulWidget {
  const _ContextPanel({super.key, required this.snapshot});

  final ContextSnapshot snapshot;

  @override
  State<_ContextPanel> createState() => _ContextPanelState();
}

class _ContextPanelState extends State<_ContextPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final snapshot = widget.snapshot;
    final hasData = snapshot.turnCount > 0;
    final utilization = hasData ? snapshot.utilization.clamp(0.0, 1.0) : 0.0;
    final percent = utilization * 100;
    final percentLabel = '${percent.toStringAsFixed(percent < 10 ? 1 : 0)}%';
    final amount = hasData
        ? '${_formatTokens(snapshot.estimatedTokens)} / '
              '${_formatTokens(snapshot.modelContextWindow)}'
        : 'settings.context_no_conversations'.tr;
    final age = hasData
        ? 'settings.context_turn'.trParams({
            'turn': snapshot.turnCount.toString(),
            'age': _formatAge(snapshot.updatedAt),
          })
        : 'settings.context_first_conversation'.tr;
    final detailHint = _expanded
        ? 'settings.context_collapse'.tr
        : 'settings.context_expand'.tr;
    final usageColor = utilization > .85
        ? Theme.of(context).colorScheme.error
        : glass.action;
    final secondaryStyle = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: glass.foregroundSecondary,
    );

    return Material(
      key: const ValueKey('settings-context-panel'),
      color: glass.muted,
      borderRadius: BorderRadius.circular(MaasoGlassTheme.surfaceRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(MaasoGlassTheme.spaceLg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(14) > 18;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  button: true,
                  expanded: _expanded,
                  label: 'settings.context_title'.tr,
                  value: amount,
                  hint: detailHint,
                  onTap: _toggleExpanded,
                  child: ExcludeSemantics(
                    child: Tooltip(
                      message: detailHint,
                      child: InkWell(
                        key: const ValueKey('settings-context-toggle'),
                        onTap: _toggleExpanded,
                        splashFactory: NoSplash.splashFactory,
                        borderRadius: BorderRadius.circular(
                          MaasoGlassTheme.fieldRadius,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: MaasoGlassTheme.controlTarget,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.layers_outlined,
                                    color: glass.foregroundSecondary,
                                    size: 20,
                                  ),
                                  const SizedBox(
                                    width: MaasoGlassTheme.spaceSm,
                                  ),
                                  Expanded(
                                    child: Text(
                                      'settings.context_title'.tr,
                                      style: TextStyle(
                                        fontSize: 14,
                                        height: 1.5,
                                        fontWeight: FontWeight.w600,
                                        color: glass.foregroundPrimary,
                                      ),
                                    ),
                                  ),
                                  if (!stacked) ...[
                                    const SizedBox(
                                      width: MaasoGlassTheme.spaceSm,
                                    ),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: constraints.maxWidth * .45,
                                      ),
                                      child: Text(
                                        amount,
                                        textAlign: TextAlign.end,
                                        style: secondaryStyle,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(
                                    width: MaasoGlassTheme.spaceXs,
                                  ),
                                  Icon(
                                    _expanded
                                        ? Icons.keyboard_arrow_up_rounded
                                        : Icons.keyboard_arrow_down_rounded,
                                    color: glass.foregroundSecondary,
                                    size: 20,
                                  ),
                                ],
                              ),
                              if (stacked) ...[
                                const SizedBox(height: MaasoGlassTheme.spaceXs),
                                Text(amount, style: secondaryStyle),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: MaasoGlassTheme.spaceSm),
                LinearProgressIndicator(
                  key: const ValueKey('settings-context-usage'),
                  value: utilization,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(
                    MaasoGlassTheme.capsuleRadius,
                  ),
                  backgroundColor: glass.divider,
                  color: usageColor,
                  semanticsLabel: 'settings.context_title'.tr,
                  semanticsValue: percentLabel,
                ),
                const SizedBox(height: MaasoGlassTheme.spaceSm),
                if (stacked)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(percentLabel, style: secondaryStyle),
                      Text(age, style: secondaryStyle),
                    ],
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(percentLabel, style: secondaryStyle),
                      const SizedBox(width: MaasoGlassTheme.spaceSm),
                      Expanded(
                        child: Text(
                          age,
                          textAlign: TextAlign.end,
                          style: secondaryStyle,
                        ),
                      ),
                    ],
                  ),
                if (_expanded) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: MaasoGlassTheme.spaceMd,
                    ),
                    child: Divider(height: 1, color: glass.divider),
                  ),
                  if (hasData) ...[
                    _DetailRow(
                      label: 'settings.model'.tr,
                      value: snapshot.modelName ?? '—',
                      stacked: stacked,
                    ),
                    _DetailRow(
                      label: 'settings.context_system_prompt'.tr,
                      value: _formatTokens(snapshot.systemTokens),
                      stacked: stacked,
                    ),
                    _DetailRow(
                      label: 'settings.context_user_input'.tr,
                      value: _formatTokens(snapshot.inputTokens),
                      stacked: stacked,
                    ),
                    _DetailRow(
                      label: 'settings.context_ai_response'.tr,
                      value: _formatTokens(snapshot.responseTokens),
                      stacked: stacked,
                    ),
                    const SizedBox(height: MaasoGlassTheme.spaceSm),
                  ],
                  Text('settings.context_note'.tr, style: secondaryStyle),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  void _toggleExpanded() => setState(() => _expanded = !_expanded);
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.stacked,
  });

  final String label;
  final String value;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final labelWidget = Text(
      label,
      style: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: glass.foregroundSecondary,
      ),
    );
    final valueWidget = Text(
      value,
      textAlign: stacked ? TextAlign.start : TextAlign.end,
      style: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: glass.foregroundPrimary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MaasoGlassTheme.spaceXs),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, valueWidget],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: labelWidget),
                const SizedBox(width: MaasoGlassTheme.spaceMd),
                Flexible(child: valueWidget),
              ],
            ),
    );
  }
}

String _formatTokens(int tokens) {
  if (tokens >= 1000000) {
    return '${(tokens / 1000000).toStringAsFixed(1)}M';
  }
  if (tokens >= 1000) {
    return '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}k';
  }
  return tokens.toString();
}

String _formatAge(DateTime timestamp) {
  if (timestamp.millisecondsSinceEpoch == 0) return '—';
  final seconds = DateTime.now()
      .difference(timestamp)
      .inSeconds
      .clamp(0, 1 << 53);
  if (seconds < 60) {
    return 'settings.context_age_seconds'.trParams({
      'count': seconds.toString(),
    });
  }
  final minutes = seconds ~/ 60;
  if (minutes < 60) {
    return 'settings.context_age_minutes'.trParams({
      'count': minutes.toString(),
    });
  }
  final hours = minutes ~/ 60;
  if (hours < 24) {
    return 'settings.context_age_hours'.trParams({'count': hours.toString()});
  }
  return 'settings.context_age_days'.trParams({
    'count': (hours ~/ 24).toString(),
  });
}
