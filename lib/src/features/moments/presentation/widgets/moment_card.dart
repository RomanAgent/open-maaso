import 'package:flutter/material.dart';
import 'package:maaso/src/core/models/agent_moment.dart';
import 'package:maaso/src/core/widgets/agent_avatar.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class MomentCard extends StatelessWidget {
  final AgentMoment moment;

  const MomentCard({super.key, required this.moment});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AgentAvatarThumb(size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      moment.authorNickname,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                    Text(
                      _formatTime(context, moment.timestamp),
                      style: TextStyle(
                        color: glass.foregroundSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            moment.content,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _IconCount(
                icon: Icons.favorite_border,
                count: moment.likes.length,
              ),
              const SizedBox(width: 16),
              _IconCount(
                icon: Icons.mode_comment_outlined,
                count: moment.comments.length,
              ),
              const Spacer(),
              Icon(
                Icons.share_outlined,
                size: 18,
                color: glass.foregroundSecondary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatCompactDate(local);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '$date $time';
  }
}

class _IconCount extends StatelessWidget {
  final IconData icon;
  final int count;
  const _IconCount({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: glass.foregroundSecondary),
        const SizedBox(width: 4),
        Text(
          "$count",
          style: TextStyle(color: glass.foregroundSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
