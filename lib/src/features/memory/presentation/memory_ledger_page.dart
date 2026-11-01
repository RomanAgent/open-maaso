import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_page_adapter.dart';

import 'memory_ledger_page_adapter_scope.dart';

abstract final class MemoryLedgerKeys {
  static const retry = ValueKey<String>('memory-ledger-retry');
  static const confirmationSheet = ValueKey<String>(
    'memory-ledger-confirmation-sheet',
  );
  static const cancelConfirmation = ValueKey<String>(
    'memory-ledger-cancel-confirmation',
  );
  static const confirmAction = ValueKey<String>('memory-ledger-confirm-action');
  static const editField = ValueKey<String>('memory-ledger-edit-field');
  static const confirmationPayload = ValueKey<String>(
    'memory-ledger-confirmation-payload',
  );
  static const loadOlder = ValueKey<String>('memory-ledger-load-older');
  static const reviewError = ValueKey<String>('memory-ledger-review-error');

  static ValueKey<String> row(int episodeId) =>
      ValueKey<String>('memory-ledger-row-$episodeId');

  static ValueKey<String> expand(int episodeId) =>
      ValueKey<String>('memory-ledger-expand-$episodeId');

  static ValueKey<String> projectionPayload(int episodeId) =>
      ValueKey<String>('memory-ledger-projection-payload-$episodeId');

  static ValueKey<String> action(
    MemoryGovernanceAction action,
    int episodeId,
  ) => ValueKey<String>('memory-ledger-${action.name}-$episodeId');

  static ValueKey<String> filter(MemoryLedgerFilter filter) =>
      ValueKey<String>('memory-ledger-filter-${filter.semanticId}');
}

/// Owner-facing, append-only audit view over the account Memory Ledger.
class MemoryLedgerScreen extends ConsumerStatefulWidget {
  const MemoryLedgerScreen({super.key});

  @override
  ConsumerState<MemoryLedgerScreen> createState() => _MemoryLedgerScreenState();
}

class _MemoryLedgerScreenState extends ConsumerState<MemoryLedgerScreen>
    implements MemoryLedgerPageTarget {
  final ScrollController _scrollController = ScrollController();

  MemoryLedgerNotifier get _notifier => ref.read(memoryLedgerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(memoryLedgerProvider);
    if (!state.loaded && !state.isLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_notifier.ensureLoaded());
      });
    }
    return MemoryLedgerPageAdapterScope(
      target: this,
      child: AppSecondaryScaffold(
        contentMaxWidth: 920,
        header: AppSecondaryHeader(
          title: 'memory_ledger.title'.tr,
          subtitle: 'memory_ledger.subtitle'.tr,
          onBack: () => appNavigation.pop(),
          trailing: AppGlassIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'memory_ledger.refresh'.tr,
            onPressed: state.isLoading ? null : _notifier.refresh,
            size: 44,
          ),
        ),
        body: Column(
          children: <Widget>[
            _FilterBar(
              selected: state.filter,
              onSelected: (filter) {
                _takeOver();
                _notifier.setFilter(filter);
              },
            ),
            if (state.reviewErrorKey case final reviewErrorKey?)
              _ReviewErrorBanner(errorKey: reviewErrorKey),
            Expanded(child: _buildBody(state)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(MemoryLedgerState state) {
    if ((!state.loaded || state.isLoading) && state.entries.isEmpty) {
      return _scrollableState(
        AppSecondaryStateView(
          kind: AppSecondaryStateKind.loading,
          title: 'memory_ledger.loading'.tr,
        ),
      );
    }
    if (state.errorKey != null && state.entries.isEmpty) {
      return _scrollableState(
        AppSecondaryStateView(
          kind: AppSecondaryStateKind.error,
          title: 'memory_ledger.load_failed_title'.tr,
          message: state.errorKey!.tr,
          actionLabel: 'common.retry'.tr,
          onAction: () => _notifier.refresh(),
          key: MemoryLedgerKeys.retry,
        ),
      );
    }
    final entries = state.visibleEntries;
    if (entries.isEmpty) {
      if (state.isLoadingMore) {
        return _scrollableState(
          AppSecondaryStateView(
            kind: AppSecondaryStateKind.loading,
            title: 'memory_ledger.loading'.tr,
          ),
        );
      }
      final paginationError = state.paginationErrorKey;
      if (paginationError != null) {
        return _scrollableState(
          AppSecondaryStateView(
            kind: AppSecondaryStateKind.error,
            title: 'memory_ledger.load_failed_title'.tr,
            message: paginationError.tr,
            actionLabel: 'common.retry'.tr,
            onAction: () => _notifier.loadMore(),
          ),
        );
      }
      final canLoadOlder = state.nextBeforeEpisodeId != null;
      return _scrollableState(
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            AppSecondaryStateView(
              kind: AppSecondaryStateKind.empty,
              title: 'memory_ledger.empty_title'.tr,
              message: 'memory_ledger.empty_message'.tr,
            ),
            if (canLoadOlder) _LoadOlderButton(onPressed: _notifier.loadMore),
          ],
        ),
      );
    }
    final footerCount = state.nextBeforeEpisodeId == null ? 0 : 1;
    return RefreshIndicator(
      onRefresh: _notifier.refresh,
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          16,
          4,
          16,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        itemCount: entries.length + footerCount,
        itemBuilder: (context, index) {
          if (index == entries.length) {
            if (state.isLoadingMore) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (state.paginationErrorKey != null) {
              return _LoadMoreError(onRetry: _notifier.loadMore);
            }
            return _LoadOlderButton(onPressed: _notifier.loadMore);
          }
          final entry = entries[index];
          final episodeId = entry.episode.id!;
          return _MemoryLedgerCard(
            key: MemoryLedgerKeys.row(episodeId),
            entry: entry,
            expanded: state.expandedEpisodeIds.contains(episodeId),
            inspection: state.inspections[episodeId],
            reviewing: state.reviewingEpisodeIds.contains(episodeId),
            onToggleExpanded: () {
              _takeOver();
              unawaited(_notifier.toggleExpanded(episodeId));
            },
            onRetryInspection: () =>
                unawaited(_notifier.retryInspection(episodeId)),
            onReview: (action) => unawaited(_confirmReview(entry, action)),
          );
        },
      ),
    );
  }

  Widget _scrollableState(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter > 240) {
      return;
    }
    unawaited(_notifier.loadMore());
  }

  Future<void> _confirmReview(
    MemoryLedgerEntry entry,
    MemoryGovernanceAction action,
  ) async {
    _takeOver();
    final episode = entry.episode;
    final episodeId = episode.id;
    final expectedHeadEpisodeId = entry.expectedHeadEpisodeId;
    final expectedHeadRevision = entry.expectedHeadRevision;
    final expectedMemory =
        entry.governedProjectionPayload ?? episode.what.trim();
    if (episodeId == null ||
        expectedHeadEpisodeId == null ||
        expectedHeadRevision == null ||
        expectedMemory.isEmpty ||
        !entry.isReviewTarget) {
      return;
    }
    final exactText = await showAppGlassSheet<String>(
      context: context,
      builder: (_) => _ReviewConfirmationSheet(
        action: action,
        episodeWhat: episode.what,
        governedProjectionPayload: entry.governedProjectionPayload,
      ),
    );
    if (exactText == null || !mounted) return;
    if (!canApplyVisibleMemoryAction(
      action: action,
      episodeId: episodeId,
      expectedHeadEpisodeId: expectedHeadEpisodeId,
      expectedRevision: expectedHeadRevision,
      expectedMemory: expectedMemory,
    )) {
      return;
    }
    final result = await _notifier.review(
      MemoryGovernanceCommand(
        action: action,
        targetEpisodeId: episodeId,
        expectedHeadEpisodeId: expectedHeadEpisodeId,
        expectedRevision: expectedHeadRevision,
        edit: action == MemoryGovernanceAction.edit
            ? MemoryEpisodeEdit(what: exactText)
            : null,
      ),
    );
    if (!mounted || result.status == MemoryGovernanceStatus.applied) return;
    AppGlassNotice.show(
      title: 'memory_ledger.action_failed_title'.tr,
      message: 'memory_ledger.action_failed'.tr,
      icon: Icons.error_outline_rounded,
    );
  }

  void _takeOver() {
    appServices
        .maybeFind<AgentUiControlService>()
        ?.coordinator
        .pauseForUserActivity(reason: 'memory_ledger_user_input');
  }

  @override
  bool get isMemoryLedgerPageReady {
    final state = ref.read(memoryLedgerProvider);
    return mounted &&
        state.loaded &&
        !state.isLoading &&
        ref.read(memoryLedgerGatewayProvider).isAvailable;
  }

  @override
  MemoryLedgerFilter get memoryLedgerFilter =>
      ref.read(memoryLedgerProvider).filter;

  @override
  bool applyMemoryLedgerFilter(MemoryLedgerFilter filter) {
    if (!isMemoryLedgerPageReady) return false;
    _notifier.setFilter(filter);
    return true;
  }

  @override
  bool canApplyVisibleMemoryAction({
    required MemoryGovernanceAction action,
    required int episodeId,
    required int expectedHeadEpisodeId,
    required int expectedRevision,
    required String expectedMemory,
  }) {
    if (!isMemoryLedgerPageReady) return false;
    final state = ref.read(memoryLedgerProvider);
    if (state.reviewingEpisodeIds.contains(episodeId)) return false;
    for (final entry in state.visibleEntries) {
      final episode = entry.episode;
      if (episode.id != episodeId ||
          entry.expectedHeadEpisodeId != expectedHeadEpisodeId ||
          entry.expectedHeadRevision != expectedRevision ||
          (entry.governedProjectionPayload ?? episode.what.trim()) !=
              expectedMemory) {
        continue;
      }
      return MemoryLedgerActionEligibility.allows(
        action: action,
        isHead: entry.isReviewTarget,
        reviewState: episode.reviewState,
        sourceType: episode.sourceType,
        allowsTextEdit: entry.governedProjectionKind == null,
      );
    }
    return false;
  }

  @override
  void requestMemoryLedgerRefresh() => unawaited(_notifier.refresh());
}

class _ReviewConfirmationSheet extends StatefulWidget {
  const _ReviewConfirmationSheet({
    required this.action,
    required this.episodeWhat,
    required this.governedProjectionPayload,
  });

  final MemoryGovernanceAction action;
  final String episodeWhat;
  final String? governedProjectionPayload;

  @override
  State<_ReviewConfirmationSheet> createState() =>
      _ReviewConfirmationSheetState();
}

class _ReviewConfirmationSheetState extends State<_ReviewConfirmationSheet> {
  late final TextEditingController _textController = TextEditingController(
    text: widget.episodeWhat,
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final isEdit = widget.action == MemoryGovernanceAction.edit;
    final validEdit = !isEdit || _isValidExactText(_textController.text);
    return SingleChildScrollView(
      child: Column(
        key: MemoryLedgerKeys.confirmationSheet,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'memory_ledger.confirm_title'.tr,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'memory_ledger.confirm_message'.tr,
            style: TextStyle(color: glass.foregroundSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(
            widget.episodeWhat,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (widget.governedProjectionPayload case final payload?) ...<Widget>[
            const SizedBox(height: 12),
            SelectableText(
              payload,
              key: MemoryLedgerKeys.confirmationPayload,
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          if (isEdit) ...<Widget>[
            const SizedBox(height: 14),
            TextField(
              key: MemoryLedgerKeys.editField,
              controller: _textController,
              minLines: 2,
              maxLines: 5,
              maxLength: 4096,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'memory_ledger.edit_field_label'.tr,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: AppGlassButton(
                  key: MemoryLedgerKeys.cancelConfirmation,
                  label: 'common.cancel'.tr,
                  primary: false,
                  minHeight: 44,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppGlassButton(
                  key: MemoryLedgerKeys.confirmAction,
                  label: _actionLabel(widget.action),
                  icon: _actionIcon(widget.action),
                  minHeight: 44,
                  color: _isDestructive(widget.action)
                      ? Theme.of(context).colorScheme.error
                      : null,
                  onPressed: validEdit
                      ? () => Navigator.of(
                          context,
                        ).pop(isEdit ? _textController.text : '')
                      : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelected});

  final MemoryLedgerFilter selected;
  final ValueChanged<MemoryLedgerFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppSecondaryCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.all(8),
      cornerRadius: 18,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: MemoryLedgerFilter.values
            .map((filter) {
              final active = filter == selected;
              return ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: ChoiceChip(
                  key: MemoryLedgerKeys.filter(filter),
                  label: Text('memory_ledger.filter.${filter.semanticId}'.tr),
                  selected: active,
                  onSelected: (_) => onSelected(filter),
                  labelStyle: TextStyle(
                    color: active
                        ? glass.accentText
                        : glass.foregroundSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: glass.muted,
                  selectedColor: glass.accentSoft,
                  side: BorderSide.none,
                  showCheckmark: MediaQuery.highContrastOf(context),
                  checkmarkColor: glass.accentText,
                  visualDensity: VisualDensity.standard,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

class _ReviewErrorBanner extends StatelessWidget {
  const _ReviewErrorBanner({required this.errorKey});

  final String errorKey;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final error = Theme.of(context).colorScheme.error;
    return Semantics(
      key: MemoryLedgerKeys.reviewError,
      liveRegion: true,
      label: errorKey.tr,
      child: AppSecondaryCard(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline_rounded, color: error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                errorKey.tr,
                style: TextStyle(
                  color: glass.foregroundPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryLedgerCard extends StatelessWidget {
  const _MemoryLedgerCard({
    super.key,
    required this.entry,
    required this.expanded,
    required this.inspection,
    required this.reviewing,
    required this.onToggleExpanded,
    required this.onRetryInspection,
    required this.onReview,
  });

  final MemoryLedgerEntry entry;
  final bool expanded;
  final MemoryLedgerInspection? inspection;
  final bool reviewing;
  final VoidCallback onToggleExpanded;
  final VoidCallback onRetryInspection;
  final ValueChanged<MemoryGovernanceAction> onReview;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final episode = entry.episode;
    final episodeId = episode.id!;
    return AppSecondaryCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      tone: AppSecondaryCardTone.normal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _StatusBadge(
                state: episode.reviewState,
                needsReview:
                    entry.isHead &&
                    episode.sourceType == EpisodeSourceType.legacyUnknown,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'memory_ledger.revision'.trParams(<String, String>{
                    'revision': episode.revision.toString(),
                  }),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppGlassIconButton(
                key: MemoryLedgerKeys.expand(episodeId),
                icon: expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                tooltip: expanded
                    ? 'memory_ledger.collapse'.tr
                    : 'memory_ledger.expand'.tr,
                onPressed: onToggleExpanded,
                size: 44,
                iconSize: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            episode.what,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 15,
              height: 1.42,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (entry.governedProjectionPayload case final payload?) ...<Widget>[
            const SizedBox(height: 10),
            SelectableText(
              payload,
              key: MemoryLedgerKeys.projectionPayload(episodeId),
              maxLines: 8,
              style: TextStyle(
                color: glass.foregroundSecondary,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 5,
            children: <Widget>[
              _MetaLabel(
                icon: Icons.category_outlined,
                text: 'memory_ledger.kind.${episode.kind.name}'.tr,
              ),
              _MetaLabel(
                icon: Icons.analytics_outlined,
                text: 'memory_ledger.confidence'.trParams(<String, String>{
                  'percent': (episode.confidence * 100).round().toString(),
                }),
              ),
              _MetaLabel(
                icon: Icons.schedule_rounded,
                text: _dateLabel(episode.updatedAt),
              ),
            ],
          ),
          if (!entry.isReviewTarget) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'memory_ledger.read_only_revision'.tr,
              style: TextStyle(
                color: glass.foregroundSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 12),
            _GovernanceActions(
              episodeId: episodeId,
              actions: MemoryLedgerActionEligibility.actionsFor(
                isHead: entry.isReviewTarget,
                reviewState: episode.reviewState,
                sourceType: episode.sourceType,
                allowsTextEdit: entry.governedProjectionKind == null,
              ),
              reviewing: reviewing,
              onReview: onReview,
            ),
          ],
          if (expanded) ...<Widget>[
            const SizedBox(height: 14),
            Divider(color: glass.border, height: 1),
            const SizedBox(height: 14),
            _InspectionPanel(
              inspection: inspection,
              onRetry: onRetryInspection,
            ),
          ],
        ],
      ),
    );
  }
}

class _GovernanceActions extends StatelessWidget {
  const _GovernanceActions({
    required this.episodeId,
    required this.actions,
    required this.reviewing,
    required this.onReview,
  });

  final int episodeId;
  final List<MemoryGovernanceAction> actions;
  final bool reviewing;
  final ValueChanged<MemoryGovernanceAction> onReview;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: actions
          .map(
            (action) => AppGlassButton(
              key: MemoryLedgerKeys.action(action, episodeId),
              label: _actionLabel(action),
              semanticLabel: 'memory_ledger.action_semantic'.trParams(
                <String, String>{'action': _actionLabel(action)},
              ),
              icon: _actionIcon(action),
              primary: action == MemoryGovernanceAction.accept,
              minHeight: 44,
              color: _isDestructive(action)
                  ? Theme.of(context).colorScheme.error
                  : null,
              onPressed: reviewing ? null : () => onReview(action),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _InspectionPanel extends StatelessWidget {
  const _InspectionPanel({required this.inspection, required this.onRetry});

  final MemoryLedgerInspection? inspection;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final current = inspection;
    if (current == null || current.isLoading) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (current.errorKey != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            current.errorKey!.tr,
            style: TextStyle(color: glass.foregroundSecondary),
          ),
          const SizedBox(height: 8),
          AppGlassButton(
            label: 'common.retry'.tr,
            onPressed: onRetry,
            minHeight: 44,
            primary: false,
          ),
        ],
      );
    }
    final source = current.sourceTranscript;
    final diff = current.revisionDiff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'memory_ledger.source_title'.tr,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        _SourceStatus(status: source?.status),
        if (source?.status == MemorySourceTranscriptStatus.verified &&
            source?.content != null) ...<Widget>[
          const SizedBox(height: 8),
          SelectableText(
            source!.content!,
            style: TextStyle(
              color: glass.foregroundSecondary,
              fontSize: 13,
              height: 1.42,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'memory_ledger.diff_title'.tr,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        if (diff == null || diff.changes.isEmpty)
          Text(
            'memory_ledger.diff_empty'.tr,
            style: TextStyle(color: glass.foregroundSecondary, fontSize: 12),
          )
        else
          ...diff.changes.map((change) => _DiffRow(change: change)),
      ],
    );
  }
}

class _SourceStatus extends StatelessWidget {
  const _SourceStatus({required this.status});

  final MemorySourceTranscriptStatus? status;

  @override
  Widget build(BuildContext context) {
    final (labelKey, icon, color) = switch (status) {
      MemorySourceTranscriptStatus.verified => (
        'memory_ledger.source_verified',
        Icons.verified_outlined,
        ColorConstant.successColor,
      ),
      MemorySourceTranscriptStatus.integrityFailure => (
        'memory_ledger.source_integrity_failure',
        Icons.gpp_bad_outlined,
        ColorConstant.errorColor,
      ),
      MemorySourceTranscriptStatus.unavailable || null => (
        'memory_ledger.source_unavailable',
        Icons.link_off_rounded,
        MaasoGlassTheme.of(context).foregroundSecondary,
      ),
    };
    return Semantics(
      label: labelKey.tr,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              labelKey.tr,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.change});

  final MemoryRevisionFieldChange change;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'memory_ledger.diff_field.${change.field}'.tr,
            style: TextStyle(
              color: glass.foregroundPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _displayValue(change.before),
            style: TextStyle(
              color: ColorConstant.errorColor,
              fontSize: 12,
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _displayValue(change.after),
            style: TextStyle(color: ColorConstant.successColor, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.state, required this.needsReview});

  final EpisodeReviewState state;
  final bool needsReview;

  @override
  Widget build(BuildContext context) {
    final color = needsReview
        ? Theme.of(context).colorScheme.tertiary
        : switch (state) {
            EpisodeReviewState.pending => Theme.of(
              context,
            ).colorScheme.tertiary,
            EpisodeReviewState.accepted => ColorConstant.successColor,
            EpisodeReviewState.rejected => ColorConstant.errorColor,
            EpisodeReviewState.tombstoned => MaasoGlassTheme.of(
              context,
            ).foregroundSecondary,
          };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          needsReview
              ? 'memory_ledger.filter.needs_review'.tr
              : 'memory_ledger.status.${state.name}'.tr,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _MetaLabel extends StatelessWidget {
  const _MetaLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = MaasoGlassTheme.of(context).foregroundSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: color, size: 14),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}

class _LoadMoreError extends StatelessWidget {
  const _LoadMoreError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('memory_ledger.load_more_failed'.tr)),
          const SizedBox(width: 8),
          AppGlassButton(
            label: 'common.retry'.tr,
            onPressed: onRetry,
            minHeight: 44,
            primary: false,
          ),
        ],
      ),
    );
  }
}

class _LoadOlderButton extends StatelessWidget {
  const _LoadOlderButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: AppGlassButton(
          key: MemoryLedgerKeys.loadOlder,
          label: 'memory_ledger.load_older'.tr,
          icon: Icons.history_rounded,
          onPressed: onPressed,
          minHeight: 44,
          primary: false,
        ),
      ),
    );
  }
}

String _actionLabel(MemoryGovernanceAction action) =>
    'memory_ledger.${action.name}'.tr;

IconData _actionIcon(MemoryGovernanceAction action) => switch (action) {
  MemoryGovernanceAction.accept => Icons.check_rounded,
  MemoryGovernanceAction.edit => Icons.edit_outlined,
  MemoryGovernanceAction.reject => Icons.close_rounded,
  MemoryGovernanceAction.delete => Icons.delete_outline_rounded,
  MemoryGovernanceAction.restore => Icons.restore_rounded,
};

bool _isDestructive(MemoryGovernanceAction action) =>
    action == MemoryGovernanceAction.reject ||
    action == MemoryGovernanceAction.delete;

bool _isValidExactText(String value) =>
    value.isNotEmpty &&
    value == value.trim() &&
    value.runes.length <= 4096 &&
    !RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(value);

String _dateLabel(DateTime date) {
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${pad(date.month)}-${pad(date.day)}';
}

String _displayValue(Object? value) {
  if (value == null) return 'memory_ledger.value_empty'.tr;
  if (value is List) return value.join(', ');
  return value.toString();
}
