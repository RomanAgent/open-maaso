import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

/// Compact, read-only local telemetry below the membership card.
class DailyTokenUsageCard extends StatefulWidget {
  const DailyTokenUsageCard({
    super.key,
    required this.usage,
    this.loading = false,
    this.unavailable = false,
    this.onInteraction,
    this.enabled = true,
  });
  final DailyTokenUsage? usage;
  final bool loading, unavailable, enabled;
  final VoidCallback? onInteraction;

  @override
  State<DailyTokenUsageCard> createState() => _DailyTokenUsageCardState();
}

class _DailyTokenUsageCardState extends State<DailyTokenUsageCard> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant DailyTokenUsageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.unavailable ||
        widget.usage == null ||
        !widget.enabled ||
        oldWidget.usage?.day != widget.usage?.day) {
      _expanded = false;
    }
  }

  void _toggleExpanded() {
    if (!widget.enabled) return;
    widget.onInteraction?.call();
    if (!mounted) return;
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final zh = locale.languageCode == 'zh';
    String tr(String en, String cn) => zh ? cn : en;
    final stats = widget.usage;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final number = NumberFormat.decimalPattern(locale.toLanguageTag());
    final waiting = stats == null || widget.unavailable || widget.loading;
    final missing =
        stats != null &&
        stats.reportedRequests == 0 &&
        stats.unreportedRequests > 0;
    final total = waiting || missing ? '—' : number.format(stats.total);
    String metric(int? value, bool incomplete) =>
        waiting || incomplete ? '—' : number.format(value ?? 0);
    final title = tr('Today’s tokens', '今日 Token');
    final summary = widget.unavailable
        ? tr('This device · Unavailable', '本设备 · 暂不可用')
        : widget.loading
        ? tr('This device · Loading…', '本设备 · 读取中…')
        : stats == null
        ? tr('This device · Unavailable', '本设备 · 暂不可用')
        : missing
        ? tr('This device · Usage not reported', '本设备 · 用量未回报')
        : stats.partial
        ? tr('This device · Partial total', '本设备 · 已统计部分')
        : tr('This device · Reported total', '本设备 · 已统计总量');
    final detailHint = _expanded
        ? tr('Hide usage details', '收起用量明细')
        : tr('Show usage details', '展开用量明细');
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 13,
      height: 20 / 13,
      color: colors.onSurfaceVariant,
    );
    final radius = BorderRadius.circular(MaasoFrostTokens.cardRadius);
    return Material(
      key: const ValueKey('profile-daily-token-card'),
      color: AppSecondaryPalette.of(context).surfaceMuted,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            enabled: widget.enabled,
            expanded: _expanded,
            label: title,
            value: '$total; $summary',
            hint: detailHint,
            onTap: widget.enabled ? _toggleExpanded : null,
            child: ExcludeSemantics(
              child: InkWell(
                key: const ValueKey('profile-daily-token-toggle'),
                onTap: widget.enabled ? _toggleExpanded : null,
                borderRadius: radius,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 80),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final stacked =
                            constraints.maxWidth < 280 ||
                            MediaQuery.textScalerOf(context).scale(15) > 18;
                        final labels = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 15,
                                height: 20 / 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              summary,
                              key: const ValueKey(
                                'profile-daily-token-summary',
                              ),
                              style: secondaryStyle,
                            ),
                          ],
                        );
                        final amount = Text(
                          total,
                          key: const ValueKey('profile-daily-token-total'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: 24,
                            height: 32 / 24,
                            fontWeight: FontWeight.w600,
                          ),
                        );
                        final arrow = Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: colors.onSurfaceVariant,
                        );
                        if (stacked) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              labels,
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(child: amount),
                                  const SizedBox(width: 12),
                                  arrow,
                                ],
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: labels),
                            const SizedBox(width: 12),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth / 2,
                              ),
                              child: amount,
                            ),
                            const SizedBox(width: 8),
                            arrow,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              key: const ValueKey('profile-daily-token-details'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stats != null) ...[
                    Text(
                      stats.day.substring(5).replaceAll('-', '/'),
                      style: secondaryStyle,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    children: [
                      Text(
                        '${tr('Input', '输入')}  ${metric(stats?.input, missing || (stats?.missingInput ?? 0) > 0)}',
                        key: const ValueKey('profile-daily-token-input'),
                      ),
                      Text(
                        '${tr('Output', '输出')}  ${metric(stats?.output, missing || (stats?.missingOutput ?? 0) > 0)}',
                        key: const ValueKey('profile-daily-token-output'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.unavailable
                        ? tr('Usage is temporarily unavailable.', '用量暂时不可用。')
                        : widget.loading
                        ? tr('Loading usage…', '正在读取用量…')
                        : stats == null
                        ? tr('Usage is temporarily unavailable.', '用量暂时不可用。')
                        : stats.partial
                        ? stats.incompleteRequests > 0
                              ? tr(
                                  'Some requests ended before usage was finalized. This is a partial total.',
                                  '部分请求中断，用量尚未最终确认，当前为已统计部分。',
                                )
                              : tr(
                                  'Some requests did not report usage. This is a partial total.',
                                  '部分请求未回报用量，当前为已统计部分。',
                                )
                        : tr(
                            'Provider-reported usage for chats and creation on this device.',
                            '本设备聊天与制作的服务实际回报用量。',
                          ),
                    key: const ValueKey('profile-daily-token-status'),
                    style: secondaryStyle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr(
                      'Recorded from this version; local models and real-time audio do not report tokens.',
                      '从此版本开始记录；本地模型与实时音频暂不回报 Token。',
                    ),
                    style: secondaryStyle,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
