import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'conversation_preference_controls.dart';
import 'proactive_conversation_controls.dart';

/// Persona memories and user-owned contact choices share one destination.
/// Opening it reads the mounted services without creating a settings controller,
/// saving defaults, or starting a cloud session.
class AgentPersonaCard extends StatelessWidget {
  const AgentPersonaCard({super.key});

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final glass = MaasoGlassTheme.of(context);
    return Column(
      key: const ValueKey('relationship-agent-persona'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'settings.section_persona'.tr,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'settings.section_persona_subtitle'.tr,
          style: TextStyle(color: glass.foregroundSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        const ConversationPreferenceControls(),
        const SizedBox(height: 14),
        const ProactiveConversationControls(),
        const SizedBox(height: 14),
        AppSecondaryCard(
          padding: EdgeInsets.zero,
          child: ExpansionTile(
            key: const ValueKey('relationship-agent-profile-details'),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('settings.agent_profile_title'.tr),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              SelectableText(
                _readMarkdown(),
                style: TextStyle(
                  color: glass.foregroundPrimary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'settings.persona_edit_hint'.tr,
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  });

  String _readMarkdown() {
    final buf = StringBuffer();
    final p = appServices.maybeFind<AgentCoreController>()?.profile.value;
    String days(int count) =>
        'settings.profile_days'.trParams({'count': count.toString()});

    buf.writeln('# ${'settings.agent_profile_title'.tr}');
    buf.writeln();
    buf.writeln("- **${'settings.nickname'.tr}**: ${p?.nickname ?? '—'}");
    buf.writeln("- **${'settings.personality_bio'.tr}**: ${p?.bio ?? '—'}");
    buf.writeln("- **${'settings.catchphrase'.tr}**: ${p?.catchphrase ?? '—'}");
    buf.writeln("- **${'settings.profile_gender'.tr}**: ${p?.gender ?? '—'}");
    buf.writeln(
      "- **${'settings.profile_wake_up'.tr}**: ${p == null ? '—' : '${p.wakeUpHour}:00'}",
    );
    buf.writeln(
      "- **${'settings.profile_sleep'.tr}**: ${p == null ? '—' : '${p.sleepHour}:00'}",
    );
    if (p?.personalityTraits.isNotEmpty ?? false) {
      buf.writeln(
        "- **${'settings.profile_traits'.tr}**: "
        '${p?.personalityTraits.join(", ")}',
      );
    }
    buf.writeln();

    if (appServices.isRegistered<SoulService>()) {
      final soul = appServices.find<SoulService>();
      buf.writeln('## ${'settings.profile_soul'.tr}');
      buf.writeln();
      buf.writeln(
        "- **${'settings.profile_name'.tr}**: ${soul.name.value ?? '—'}",
      );
      buf.writeln(
        "- **${'settings.profile_age'.tr}**: ${soul.age.value ?? '—'}",
      );
      buf.writeln(
        "- **${'settings.profile_gender'.tr}**: ${soul.gender.value ?? '—'}",
      );
      if (soul.notes.value.trim().isNotEmpty) {
        buf.writeln();
        buf.writeln('### ${'settings.profile_notes'.tr}');
        buf.writeln(soul.notes.value.trim());
      }
      buf.writeln();
    }

    if (appServices.isRegistered<MasterProfileService>()) {
      final master = appServices.find<MasterProfileService>();
      if (master.hasAnything) {
        buf.writeln('## ${'settings.profile_master'.tr}');
        buf.writeln();
        buf.writeln(
          "- **${'settings.profile_name'.tr}**: ${master.name.value ?? '—'}",
        );
        buf.writeln(
          "- **${'settings.profile_pronouns'.tr}**: "
          "${master.pronouns.value ?? '—'}",
        );
        buf.writeln(
          "- **${'settings.profile_age'.tr}**: ${master.age.value ?? '—'}",
        );
        if (master.notes.value.trim().isNotEmpty) {
          buf.writeln();
          buf.writeln('### ${'settings.profile_notes'.tr}');
          buf.writeln(master.notes.value.trim());
        }
        buf.writeln();
      }
    }

    if (appServices.isRegistered<RelationshipService>()) {
      final rel = appServices.find<RelationshipService>();
      final s = rel.state.value;
      if (s != null) {
        buf.writeln('## ${'settings.profile_relationship'.tr}');
        buf.writeln();
        buf.writeln(
          "- **${'settings.profile_days_known'.tr}**: ${days(s.daysKnown())}",
        );
        buf.writeln(
          "- **${'settings.profile_stage'.tr}**: ${s.expressionStage.promptLabel()}",
        );
        buf.writeln(
          "- **${'settings.profile_current_streak'.tr}**: "
          '${days(s.currentStreak)}',
        );
        buf.writeln(
          "- **${'settings.profile_longest_streak'.tr}**: "
          '${days(s.longestStreak)}',
        );
        buf.writeln();
      }
    }

    return buf.toString().trim();
  }
}
