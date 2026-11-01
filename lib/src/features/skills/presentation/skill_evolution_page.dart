import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class SkillEvolutionDetailPage extends StatefulWidget {
  const SkillEvolutionDetailPage({super.key, required this.skill});

  final MarketplaceSkill skill;

  @override
  State<SkillEvolutionDetailPage> createState() =>
      _SkillEvolutionDetailPageState();
}

class _SkillEvolutionDetailPageState extends State<SkillEvolutionDetailPage> {
  final SkillMarketplaceService _marketplace = appServices
      .find<SkillMarketplaceService>();
  late Future<List<SkillLineageNode>> _lineage;
  bool _forking = false;

  @override
  void initState() {
    super.initState();
    _lineage = _marketplace.getSkillLineage(widget.skill.skillVersionId);
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final canFork =
        widget.skill.visibility != SkillVisibility.private &&
        !widget.skill.isRejected;
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: widget.skill.title,
        subtitle: 'skill_evolution.subtitle'.tr,
        onBack: appNavigation.pop,
      ),
      bottomBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: AppGlassButton(
          label: !canFork
              ? 'skill_evolution.private_no_fork'.tr
              : _forking
              ? 'skill_evolution.forking'.tr
              : 'skill_evolution.fork_start'.tr,
          icon: Icons.fork_right_rounded,
          fullWidth: true,
          semanticLabel: 'skill_evolution.fork_semantics'.trParams({
            'title': widget.skill.title,
          }),
          onPressed: _forking || !canFork ? null : _fork,
        ),
      ),
      body: FutureBuilder<List<SkillLineageNode>>(
        future: _lineage,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return AppSecondaryStateView(
              kind: AppSecondaryStateKind.loading,
              title: 'skill_evolution.lineage_loading'.tr,
            );
          }
          if (snapshot.hasError) {
            return AppSecondaryStateView(
              kind: AppSecondaryStateKind.error,
              title: 'skill_evolution.lineage_failed'.tr,
              message: _message(snapshot.error),
              actionLabel: 'common.retry'.tr,
              onAction: () => setState(() {
                _lineage = _marketplace.getSkillLineage(
                  widget.skill.skillVersionId,
                );
              }),
            );
          }
          final nodes = snapshot.data ?? const <SkillLineageNode>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              AppSecondaryCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: ColorConstant.primaryColor.withValues(
                              alpha: 0.14,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.psychology_alt_rounded,
                            color: ColorConstant.primaryColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.skill.title,
                                style: TextStyle(
                                  color: glass.foregroundPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${widget.skill.category.displayName} · ${widget.skill.versionName} · ${widget.skill.publisherId}',
                                style: TextStyle(
                                  color: glass.foregroundSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (widget.skill.summary.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.skill.summary,
                        style: TextStyle(
                          color: glass.foregroundSecondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MetricChip(
                          icon: Icons.favorite_rounded,
                          label: 'skill_evolution.likes_count'.trParams({
                            'count': '${widget.skill.likeCount}',
                          }),
                        ),
                        _MetricChip(
                          icon: Icons.download_done_rounded,
                          label: 'skill_evolution.active_count'.trParams({
                            'count': '${widget.skill.activeInstallCount}',
                          }),
                        ),
                        _MetricChip(
                          icon: Icons.account_tree_rounded,
                          label: 'skill_evolution.lineage_count'.trParams({
                            'count': '${nodes.length}',
                          }),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              AppSecondarySection(
                title: 'skill_evolution.current_strategy'.tr,
                subtitle: 'skill_evolution.current_strategy_note'.tr,
                child: AppSecondaryCard(
                  child: Text(
                    widget.skill.instruction.isEmpty
                        ? 'skill_evolution.no_strategy'.tr
                        : widget.skill.instruction,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              AppSecondarySection(
                title: 'skill_evolution.lineage'.tr,
                subtitle: 'skill_evolution.lineage_note'.tr,
                child: nodes.isEmpty
                    ? AppSecondaryCard(
                        child: Text('skill_evolution.root_only'.tr),
                      )
                    : Column(
                        children: [
                          for (var index = 0; index < nodes.length; index++)
                            _LineageNodeCard(
                              node: nodes[index],
                              isLast: index == nodes.length - 1,
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _fork() async {
    setState(() => _forking = true);
    try {
      final draft = await _marketplace.forkSkill(widget.skill.skillVersionId);
      if (!mounted) return;
      await appNavigation.pushPage<void>(
        () => SkillEvolutionEditorPage(draftId: draft.id),
      );
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.fork_failed'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _forking = false);
    }
  }
}

class SkillEvolutionEditorPage extends StatefulWidget {
  const SkillEvolutionEditorPage({super.key, required this.draftId});

  final String draftId;

  @override
  State<SkillEvolutionEditorPage> createState() =>
      _SkillEvolutionEditorPageState();
}

class _SkillEvolutionEditorPageState extends State<SkillEvolutionEditorPage> {
  final SkillMarketplaceService _marketplace = appServices
      .find<SkillMarketplaceService>();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _summary = TextEditingController();
  final TextEditingController _strategy = TextEditingController();
  final TextEditingController _version = TextEditingController();
  SkillVisibility _visibility = SkillVisibility.private;
  SkillEvolutionDraft? _draft;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    _strategy.dispose();
    _version.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    if (_loading) {
      return AppSecondaryScaffold(
        header: AppSecondaryHeader(
          title: 'skill_evolution.title'.tr,
          onBack: appNavigation.pop,
        ),
        body: AppSecondaryStateView(
          kind: AppSecondaryStateKind.loading,
          title: 'skill_evolution.draft_loading'.tr,
        ),
      );
    }
    if (_error != null || draft == null) {
      return AppSecondaryScaffold(
        header: AppSecondaryHeader(
          title: 'skill_evolution.title'.tr,
          onBack: appNavigation.pop,
        ),
        body: AppSecondaryStateView(
          kind: AppSecondaryStateKind.error,
          title: 'skill_evolution.draft_open_failed'.tr,
          message: _error,
          actionLabel: 'common.retry'.tr,
          onAction: _load,
        ),
      );
    }
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryScaffold(
      header: AppSecondaryHeader(
        title: draft.title,
        subtitle: draft.isPublished
            ? 'skill_evolution.published'.tr
            : 'skill_evolution.revision'.trParams({
                'revision': '${draft.revision}',
              }),
        onBack: appNavigation.pop,
        trailing: AppGlassIconButton(
          icon: Icons.save_outlined,
          tooltip: 'skill_evolution.save_tooltip'.tr,
          onPressed: _busy || draft.isPublished ? null : _save,
        ),
      ),
      bottomBar: draft.isPublished
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: AppGlassButton(
                      label: _busy
                          ? 'skill_evolution.processing'.tr
                          : 'skill_evolution.standard_test'.tr,
                      icon: Icons.fact_check_outlined,
                      primary: false,
                      onPressed: _busy ? null : _runTest,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppGlassButton(
                      label: _busy
                          ? 'skill_evolution.processing'.tr
                          : 'skill_evolution.publish_version'.tr,
                      icon: Icons.rocket_launch_outlined,
                      onPressed: _busy || !draft.hasFreshPassingTest
                          ? null
                          : _publish,
                    ),
                  ),
                ],
              ),
            ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            AppSecondaryCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _EvolutionField(
                    controller: _title,
                    label: 'skill_evolution.name'.tr,
                    maxLength: 160,
                    enabled: !draft.isPublished,
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  _EvolutionField(
                    controller: _summary,
                    label: 'skill_evolution.summary'.tr,
                    maxLength: 1024,
                    maxLines: 3,
                    enabled: !draft.isPublished,
                  ),
                  const SizedBox(height: 12),
                  _EvolutionField(
                    controller: _version,
                    label: 'skill_evolution.version'.tr,
                    helper: 'skill_evolution.version_hint'.tr,
                    maxLength: 64,
                    enabled: !draft.isPublished,
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'skill_evolution.visibility'.tr,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  AppFrostSegmentedControl<SkillVisibility>(
                    blur: false,
                    segments: [
                      AppFrostSegment(
                        value: SkillVisibility.private,
                        icon: Icons.lock_outline_rounded,
                        label: 'common.private'.tr,
                      ),
                      AppFrostSegment(
                        value: SkillVisibility.public,
                        icon: Icons.public_rounded,
                        label: 'common.public'.tr,
                      ),
                    ],
                    selected: _visibility,
                    onSelected: draft.isPublished
                        ? null
                        : (selection) {
                            setState(() => _visibility = selection);
                          },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AppSecondarySection(
              title: 'skill_evolution.strategy'.tr,
              subtitle: 'skill_evolution.strategy_note'.tr,
              child: AppSecondaryCard(
                child: _EvolutionField(
                  controller: _strategy,
                  label: 'skill_evolution.execution_strategy'.tr,
                  helper: 'skill_evolution.strategy_helper'.tr,
                  maxLength: 1200,
                  maxLines: 8,
                  enabled: !draft.isPublished,
                  validator: (value) {
                    final normalized = value?.trim() ?? '';
                    if (normalized.length < 20) {
                      return 'skill_evolution.strategy_too_short'.tr;
                    }
                    return null;
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            AppSecondarySection(
              title: 'skill_evolution.cases_title'.trParams({
                'count': '${draft.cases.length}',
              }),
              subtitle: 'skill_evolution.cases_note'.tr,
              child: Column(
                children: [
                  if (draft.cases.isEmpty)
                    AppSecondaryCard(child: Text('skill_evolution.no_cases'.tr))
                  else
                    for (final trainingCase in draft.cases)
                      _TrainingCaseCard(
                        trainingCase: trainingCase,
                        enabled: !_busy && !draft.isPublished,
                        onDelete: () => _deleteCase(trainingCase.id),
                      ),
                  if (!draft.isPublished && draft.cases.length < 8) ...[
                    const SizedBox(height: 8),
                    AppGlassButton(
                      label: 'skill_evolution.add_case'.tr,
                      icon: Icons.add_rounded,
                      fullWidth: true,
                      primary: false,
                      onPressed: _busy ? null : _addCase,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            _StandardTestCard(draft: draft),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final draft = await _marketplace.getEvolutionDraft(widget.draftId);
      if (!mounted) return;
      _applyDraft(draft, replaceText: true);
    } catch (exception) {
      if (!mounted) return;
      setState(() => _error = _message(exception));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyDraft(SkillEvolutionDraft draft, {bool replaceText = false}) {
    setState(() {
      _draft = draft;
      _visibility = draft.visibility;
      if (replaceText) {
        _title.text = draft.title;
        _summary.text = draft.summary;
        _strategy.text = draft.strategy;
        _version.text = draft.versionName;
      }
    });
  }

  Future<SkillEvolutionDraft?> _save({bool notify = true}) async {
    if (_formKey.currentState?.validate() != true) return null;
    setState(() => _busy = true);
    try {
      final draft = await _marketplace.updateEvolutionDraft(
        draftId: widget.draftId,
        title: _title.text,
        summary: _summary.text,
        strategy: _strategy.text,
        visibility: _visibility,
        versionName: _version.text,
      );
      if (!mounted) return draft;
      _applyDraft(draft);
      if (notify) {
        AppGlassNotice.show(
          title: 'skill_evolution.saved_title'.tr,
          message: 'skill_evolution.revision_synced'.trParams({
            'revision': '${draft.revision}',
          }),
          icon: Icons.check_circle_outline_rounded,
        );
      }
      return draft;
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.save_failed'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runTest() async {
    final saved = await _save(notify: false);
    if (saved == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final tested = await _marketplace.runEvolutionStandardTest(
        widget.draftId,
      );
      if (!mounted) return;
      _applyDraft(tested);
      final passed = tested.lastTest?.passed == true;
      AppGlassNotice.show(
        title: passed
            ? 'skill_evolution.test_passed'.tr
            : 'skill_evolution.test_failed'.tr,
        message: passed
            ? 'skill_evolution.test_success_message'.trParams({
                'score': '${tested.lastTest?.score ?? 0}',
              })
            : 'skill_evolution.test_need_cases'.tr,
        icon: passed ? Icons.verified_rounded : Icons.rule_folder_outlined,
      );
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.test_error'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    final confirmed = await showAppGlassSheet<bool>(
      context: context,
      builder: (sheetContext) {
        final glass = MaasoGlassTheme.of(sheetContext);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'skill_evolution.publish_title'.trParams({
                'title': _title.text.trim(),
              }),
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _visibility == SkillVisibility.public
                  ? 'skill_evolution.public_publish_note'.tr
                  : 'skill_evolution.private_publish_note'.tr,
              style: TextStyle(color: glass.foregroundSecondary, height: 1.45),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: AppGlassButton(
                    label: 'common.cancel'.tr,
                    primary: false,
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppGlassButton(
                    label: 'skill_evolution.confirm_publish'.tr,
                    icon: Icons.rocket_launch_outlined,
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _marketplace.publishEvolutionDraft(widget.draftId);
      final refreshed = await _marketplace.getEvolutionDraft(widget.draftId);
      if (appServices.isRegistered<SkillStoreController>()) {
        await appServices.find<SkillStoreController>().reload();
      }
      if (!mounted) return;
      _applyDraft(refreshed);
      AppGlassNotice.show(
        title: 'skill_evolution.published_title'.tr,
        message: 'skill_evolution.version_published'.trParams({
          'version': _version.text.trim(),
          'id': '${result.skillVersionId}',
        }),
        icon: Icons.verified_rounded,
      );
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.publish_failed'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addCase() async {
    final prompt = TextEditingController();
    final expected = TextEditingController();
    final notes = TextEditingController();
    final caseKey = GlobalKey<FormState>();
    final input =
        await showAppGlassSheet<
          ({String prompt, String expected, String notes})
        >(
          context: context,
          builder: (sheetContext) {
            return Form(
              key: caseKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'skill_evolution.add_case_title'.tr,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _EvolutionField(
                    controller: prompt,
                    label: 'skill_evolution.user_prompt'.tr,
                    maxLength: 120,
                    maxLines: 3,
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  _EvolutionField(
                    controller: expected,
                    label: 'skill_evolution.expected_behavior'.tr,
                    maxLength: 120,
                    maxLines: 3,
                    validator: _required,
                  ),
                  const SizedBox(height: 12),
                  _EvolutionField(
                    controller: notes,
                    label: 'skill_evolution.note_optional'.tr,
                    maxLength: 1024,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  AppGlassButton(
                    label: 'skill_evolution.add_to_training'.tr,
                    icon: Icons.add_task_rounded,
                    fullWidth: true,
                    onPressed: () {
                      if (caseKey.currentState?.validate() != true) return;
                      Navigator.of(sheetContext).pop((
                        prompt: prompt.text,
                        expected: expected.text,
                        notes: notes.text,
                      ));
                    },
                  ),
                ],
              ),
            );
          },
        );
    prompt.dispose();
    expected.dispose();
    notes.dispose();
    if (input == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final draft = await _marketplace.addEvolutionCase(
        draftId: widget.draftId,
        prompt: input.prompt,
        expectedBehavior: input.expected,
        notes: input.notes,
      );
      if (mounted) _applyDraft(draft);
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.case_add_failed'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteCase(int caseId) async {
    setState(() => _busy = true);
    try {
      final draft = await _marketplace.deleteEvolutionCase(
        draftId: widget.draftId,
        caseId: caseId,
      );
      if (mounted) _applyDraft(draft);
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_evolution.case_delete_failed'.tr,
        message: _message(exception),
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _LineageNodeCard extends StatelessWidget {
  const _LineageNodeCard({required this.node, required this.isLast});

  final SkillLineageNode node;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 34,
          child: Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: node.isCurrent
                      ? ColorConstant.primaryColor
                      : ColorConstant.primaryColor.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${node.lineageDepth}',
                  style: TextStyle(
                    color: node.isCurrent
                        ? Colors.white
                        : glass.foregroundPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 76,
                  color: ColorConstant.primaryColor.withValues(alpha: 0.22),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: AppSecondaryCard(
            tone: node.isCurrent
                ? AppSecondaryCardTone.selected
                : AppSecondaryCardTone.normal,
            margin: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        node.skill.title,
                        style: TextStyle(
                          color: glass.foregroundPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      node.lineageDepth == 0
                          ? 'skill_evolution.root'.tr
                          : 'skill_evolution.generation'.trParams({
                              'depth': '${node.lineageDepth}',
                            }),
                      style: TextStyle(
                        color: glass.foregroundSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${node.skill.versionName} · ${node.skill.publisherId}',
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 12,
                  ),
                ),
                if (node.strategy.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    node.strategy,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrainingCaseCard extends StatelessWidget {
  const _TrainingCaseCard({
    required this.trainingCase,
    required this.enabled,
    required this.onDelete,
  });

  final SkillEvolutionTrainingCase trainingCase;
  final bool enabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ColorConstant.primaryColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${trainingCase.sortOrder + 1}',
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trainingCase.prompt,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'skill_evolution.expected'.trParams({
                    'behavior': trainingCase.expectedBehavior,
                  }),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'skill_evolution.delete_case_semantics'.trParams({
              'index': '${trainingCase.sortOrder + 1}',
            }),
            child: IconButton(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              tooltip: 'skill_evolution.delete_case_tooltip'.tr,
              onPressed: enabled ? onDelete : null,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _StandardTestCard extends StatelessWidget {
  const _StandardTestCard({required this.draft});

  final SkillEvolutionDraft draft;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final test = draft.lastTest;
    final fresh = draft.hasFreshPassingTest;
    final title = test == null
        ? 'skill_evolution.test_not_run'.tr
        : fresh
        ? 'skill_evolution.test_passed'.tr
        : test.passed
        ? 'skill_evolution.test_stale'.tr
        : 'skill_evolution.test_failed'.tr;
    final icon = fresh ? Icons.verified_rounded : Icons.fact_check_outlined;
    return AppSecondarySection(
      title: 'skill_evolution.standard_test'.tr,
      subtitle: 'skill_evolution.test_note'.tr,
      child: AppSecondaryCard(
        tone: fresh
            ? AppSecondaryCardTone.selected
            : AppSecondaryCardTone.normal,
        child: Row(
          children: [
            Icon(
              icon,
              color: fresh
                  ? ColorConstant.primaryColor
                  : glass.foregroundSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    test == null
                        ? 'skill_evolution.test_prepare'.tr
                        : 'skill_evolution.test_summary'.trParams({
                            'score': '${test.score}',
                            'passed': '${test.passedCases}',
                            'total': '${test.totalCases}',
                          }),
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: ColorConstant.primaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: ColorConstant.primaryColor),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EvolutionField extends StatelessWidget {
  const _EvolutionField({
    required this.controller,
    required this.label,
    this.helper,
    this.maxLength,
    this.maxLines = 1,
    this.enabled = true,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;
  final int? maxLength;
  final int maxLines;
  final bool enabled;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.field,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        maxLength: maxLength,
        maxLines: maxLines,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

String? _required(String? value) {
  if ((value ?? '').trim().isEmpty) return 'skill_evolution.required'.tr;
  return null;
}

String _message(Object? value) {
  return value
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');
}
