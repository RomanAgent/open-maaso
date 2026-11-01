import 'package:flutter/material.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/memory/presentation/memory_wall_page.dart';
import 'package:maaso/src/features/moments/presentation/moments_page.dart';
import 'agent_persona_card.dart';

enum RelationshipHubSection { profile, moments, memories }

typedef RelationshipHubSectionBuilder = Widget Function(BuildContext context);

/// One emotional home for what the Agent knows about the user, Moments and
/// Our Memories. The existing controllers and persisted models stay separate.
class RelationshipHubPage extends StatefulWidget {
  const RelationshipHubPage({
    super.key,
    this.initialSection = RelationshipHubSection.memories,
    @visibleForTesting this.sectionBuilders,
  });

  final RelationshipHubSection initialSection;

  @visibleForTesting
  final Map<RelationshipHubSection, RelationshipHubSectionBuilder>?
  sectionBuilders;

  @override
  State<RelationshipHubPage> createState() => _RelationshipHubPageState();
}

class _RelationshipHubPageState extends State<RelationshipHubPage> {
  late RelationshipHubSection _section = widget.initialSection;

  @override
  void didUpdateWidget(covariant RelationshipHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      _section = widget.initialSection;
    }
  }

  @override
  Widget build(BuildContext context) {
    final navigation = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: AppFrostSegmentedControl<RelationshipHubSection>(
        selected: _section,
        blur: true,
        onSelected: (next) {
          if (next != _section) setState(() => _section = next);
        },
        segments: <AppFrostSegment<RelationshipHubSection>>[
          AppFrostSegment(
            value: RelationshipHubSection.profile,
            label: 'relationship_hub.profile'.tr,
            key: const ValueKey<String>('relationship-hub-profile'),
          ),
          AppFrostSegment(
            value: RelationshipHubSection.moments,
            label: 'moments.title'.tr,
            key: const ValueKey<String>('relationship-hub-moments'),
          ),
          AppFrostSegment(
            value: RelationshipHubSection.memories,
            label: 'memory.title'.tr,
            key: const ValueKey<String>('relationship-hub-memories'),
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: AppSecondaryPalette.of(context).backgroundStart,
      body: KeyedSubtree(
        key: ValueKey<RelationshipHubSection>(_section),
        child: _buildSection(context, navigation),
      ),
    );
  }

  Widget _buildSection(BuildContext context, Widget navigation) {
    final override = widget.sectionBuilders?[_section];
    if (override != null) {
      return AppSecondaryScaffold(
        header: AppFrostSectionHeader(
          header: AppSecondaryHeader(
            title: 'relationship_hub.title'.tr,
            onBack: appNavigation.pop,
          ),
          navigation: navigation,
        ),
        body: override(context),
      );
    }
    return switch (_section) {
      RelationshipHubSection.profile => _RelationshipProfilePage(
        sectionNavigation: navigation,
      ),
      RelationshipHubSection.moments => MomentsPage(
        sectionNavigation: navigation,
      ),
      RelationshipHubSection.memories => MemoryWallPage(
        sectionNavigation: navigation,
      ),
    };
  }
}

class _RelationshipProfilePage extends StatelessWidget {
  const _RelationshipProfilePage({this.sectionNavigation});

  final Widget? sectionNavigation;

  @override
  Widget build(BuildContext context) {
    final master = appServices.maybeFind<MasterProfileService>();
    final relationship = appServices.maybeFind<RelationshipService>();
    return AppSecondaryScaffold(
      header: AppFrostSectionHeader(
        navigation: sectionNavigation,
        header: AppSecondaryHeader(
          title: 'relationship_hub.title'.tr,
          subtitle: 'relationship_hub.subtitle'.tr,
          onBack: appNavigation.pop,
        ),
      ),
      body: AppReactiveBuilder(() {
        final state = relationship?.state.value;
        final glass = MaasoGlassTheme.of(context);
        return ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: <Widget>[
            AppSecondaryCard(
              tone: AppSecondaryCardTone.selected,
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.favorite_rounded, color: glass.accent, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          state?.expressionStage.promptLabel() ??
                              'relationship_hub.not_ready'.tr,
                          style: TextStyle(
                            color: glass.foregroundPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          state == null
                              ? 'relationship_hub.story_waiting'.tr
                              : 'relationship_hub.story_summary'
                                    .trParams(<String, String>{
                                      'days': state.daysKnown().toString(),
                                      'streak': state.currentStreak.toString(),
                                    }),
                          style: TextStyle(
                            color: glass.foregroundSecondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppSecondaryCard(
              key: const ValueKey('relationship-memory-ledger-entry'),
              padding: EdgeInsets.zero,
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: Icon(Icons.fact_check_outlined, color: glass.accent),
                title: Text('memory_ledger.settings_title'.tr),
                subtitle: Text('memory_ledger.settings_subtitle'.tr),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => appNavigation.push(AppRouteCatalog.memoryLedger),
              ),
            ),
            const SizedBox(height: 14),
            const AgentPersonaCard(),
            const SizedBox(height: 14),
            _ProfileCard(
              title: 'relationship_hub.about_you'.tr,
              icon: Icons.badge_outlined,
              rows: <_ProfileRowData>[
                _ProfileRowData(
                  'relationship_hub.name'.tr,
                  _present(master?.name.value),
                ),
                _ProfileRowData(
                  'relationship_hub.pronouns'.tr,
                  _present(master?.pronouns.value),
                ),
                _ProfileRowData(
                  'relationship_hub.age'.tr,
                  master?.age.value?.toString() ??
                      'relationship_hub.not_set'.tr,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _ProfileNoteCard(
              title: 'relationship_hub.notes'.tr,
              icon: Icons.notes_rounded,
              text: _present(master?.notes.value),
            ),
            if ((master?.importantSummary.value ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              _ProfileNoteCard(
                title: 'relationship_hub.agent_summary'.tr,
                icon: Icons.psychology_alt_outlined,
                text: master!.importantSummary.value!.trim(),
              ),
            ],
          ],
        );
      }),
    );
  }

  static String _present(String? value) {
    final normalized = value?.trim() ?? '';
    return normalized.isEmpty ? 'relationship_hub.not_set'.tr : normalized;
  }
}

class _ProfileRowData {
  const _ProfileRowData(this.label, this.value);

  final String label;
  final String value;
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<_ProfileRowData> rows;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ProfileCardTitle(title: title, icon: icon),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...<Widget>[
            if (index > 0) const Divider(height: 17),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 88,
                  child: Text(
                    rows[index].label,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rows[index].value,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfileNoteCard extends StatelessWidget {
  const _ProfileNoteCard({
    required this.title,
    required this.icon,
    required this.text,
  });

  final String title;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ProfileCardTitle(title: title, icon: icon),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              color: glass.foregroundSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileCardTitle extends StatelessWidget {
  const _ProfileCardTitle({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: glass.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
