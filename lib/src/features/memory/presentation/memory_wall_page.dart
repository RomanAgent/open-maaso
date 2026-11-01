import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/features/memory/application/memory_wall_controller.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/services/theme_service.dart';

/// 共同回忆墙 — the timeline of "我们之间发生过什么".  Shows the relationship
/// stage (name only, never a number), days known, and current streak, then a
/// timeline of shared milestones.  This is the emotional anchor that makes the
/// bond feel cumulative rather than reset-every-session.
class MemoryWallPage extends AppView<MemoryWallController> {
  const MemoryWallPage({super.key, this.sectionNavigation});

  final Widget? sectionNavigation;

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      builder: (context, palette) => AppSecondaryScaffold(
        header: AppFrostSectionHeader(
          navigation: sectionNavigation,
          header: _Header(inRelationshipHub: sectionNavigation != null),
        ),
        body: Column(
          children: [
            AppReactiveBuilder(
              () =>
                  _StoryHeader(state: controller.state.value, palette: palette),
            ),
            Expanded(
              child: AppReactiveBuilder(() {
                final items = controller.milestones;
                if (items.isEmpty) {
                  return AppSecondaryStateView(
                    kind: AppSecondaryStateKind.empty,
                    title: 'memory.empty'.tr,
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _MilestoneTile(
                    milestone: items[i],
                    palette: palette,
                    isLast: i == items.length - 1,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.inRelationshipHub});

  final bool inRelationshipHub;

  @override
  Widget build(BuildContext context) {
    return AppSecondaryHeader(
      title: (inRelationshipHub ? 'relationship_hub.title' : 'memory.title').tr,
      onBack: () => appNavigation.pop(),
    );
  }
}

/// Stage + days-known + streak. No score, no progress bar — just the named
/// bond and how long it's been growing.
class _StoryHeader extends StatelessWidget {
  const _StoryHeader({required this.state, required this.palette});
  final RelationshipState? state;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final s = state;
    if (s == null) return const SizedBox.shrink();
    final days = s.daysKnown();
    return AppSecondaryCard(
      tone: AppSecondaryCardTone.selected,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 18, color: palette.seed),
              const SizedBox(width: 8),
              Text(
                s.expressionStage.promptLabel(),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: palette.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            s.currentStreak >= 2
                ? 'memory.days_known_streak'.trParams({
                    'days': days.toString(),
                    'streak': s.currentStreak.toString(),
                  })
                : 'memory.days_known'.trParams({'days': days.toString()}),
            style: TextStyle(fontSize: 14, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile({
    required this.milestone,
    required this.palette,
    required this.isLast,
  });

  final Milestone milestone;
  final AppPalette palette;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final m = milestone;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline rail: dot + connecting line.
          Column(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: palette.seed.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(_iconFor(m.type), size: 18, color: palette.seed),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: palette.divider,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Card.
          Expanded(
            child: AppSecondaryCard(
              tone: m.pinned
                  ? AppSecondaryCardTone.selected
                  : AppSecondaryCardTone.normal,
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(14),
              cornerRadius: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (m.pinned) ...[
                        Icon(
                          Icons.push_pin_rounded,
                          size: 13,
                          color: palette.seed,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          m.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: palette.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        _dateLabel(m.when),
                        style: TextStyle(
                          fontSize: 12,
                          color: palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  if (m.note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      m.note,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _dateLabel(DateTime d) =>
      '${d.year}.${_pad(d.month)}.${_pad(d.day)}';

  static String _pad(int n) => n < 10 ? '0$n' : '$n';

  static IconData _iconFor(String type) => switch (type) {
    'first_meet' => Icons.waving_hand_rounded,
    'deep_talk' => Icons.nights_stay_rounded,
    'goal_done' => Icons.emoji_events_rounded,
    'low_weathered' => Icons.umbrella_rounded,
    'anniversary' => Icons.cake_rounded,
    'streak' => Icons.local_fire_department_rounded,
    'inside_joke' => Icons.sentiment_very_satisfied_rounded,
    _ => Icons.favorite_border_rounded,
  };
}
