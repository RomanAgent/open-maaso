import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';

/// Narrow typed mutation boundary shared by the Ledger controller and its
/// trusted AppControl Host executor.
abstract interface class MemoryLedgerReviewGateway {
  Object get authorityToken;
  bool get isAvailable;

  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command);
}

abstract interface class MemoryLedgerGateway
    implements MemoryLedgerReviewGateway {
  String get requestContextKey;

  Future<MemoryLedgerPage> list({int? beforeEpisodeId, int limit = 20});

  Future<MemoryLedgerDetail?> getDetail(int episodeId);

  Future<MemoryRevisionDiff> diff(int fromEpisodeId, int toEpisodeId);

  Future<MemorySourceTranscriptResult> sourceTranscript(
    EpisodeSourceRef source,
  );
}

final class MemoryLedgerServiceGateway implements MemoryLedgerGateway {
  const MemoryLedgerServiceGateway(this.service);

  final MemoryLedgerService service;

  @override
  Object get authorityToken => service;

  @override
  bool get isAvailable => service.acceptsRequests;

  @override
  String get requestContextKey => 'memory-ledger:${identityHashCode(service)}';

  @override
  Future<MemoryLedgerPage> list({int? beforeEpisodeId, int limit = 20}) =>
      service.list(beforeEpisodeId: beforeEpisodeId, limit: limit);

  @override
  Future<MemoryLedgerDetail?> getDetail(int episodeId) =>
      service.getDetail(episodeId);

  @override
  Future<MemoryRevisionDiff> diff(int fromEpisodeId, int toEpisodeId) =>
      service.diff(fromEpisodeId, toEpisodeId);

  @override
  Future<MemorySourceTranscriptResult> sourceTranscript(
    EpisodeSourceRef source,
  ) => service.sourceTranscript(source);

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) =>
      service.review(command);
}

MemoryLedgerReviewGateway? resolveRegisteredMemoryLedgerReviewGateway() {
  final service = appServices.maybeFind<MemoryLedgerService>();
  return service == null ? null : MemoryLedgerServiceGateway(service);
}

final memoryLedgerGatewayProvider = Provider<MemoryLedgerGateway>((ref) {
  final services = ref.watch(appServicesProvider);
  return MemoryLedgerServiceGateway(services.find<MemoryLedgerService>());
});

final memoryLedgerProvider =
    NotifierProvider.autoDispose<MemoryLedgerNotifier, MemoryLedgerState>(
      MemoryLedgerNotifier.new,
    );

/// Visible filters for the owner-facing Memory Ledger.
enum MemoryLedgerFilter {
  all('all'),
  needsReview('needs_review'),
  accepted('accepted'),
  rejected('rejected'),
  deleted('deleted');

  const MemoryLedgerFilter(this.semanticId);

  final String semanticId;

  static MemoryLedgerFilter? fromSemanticId(String raw) {
    final normalized = raw.trim();
    for (final filter in values) {
      if (filter.semanticId == normalized) return filter;
    }
    return null;
  }
}

/// Bounded detail payload for one explicitly expanded Ledger row.
final class MemoryLedgerInspection {
  const MemoryLedgerInspection({
    this.isLoading = false,
    this.detail,
    this.sourceTranscript,
    this.revisionDiff,
    this.errorKey,
  });

  final bool isLoading;
  final MemoryLedgerDetail? detail;
  final MemorySourceTranscriptResult? sourceTranscript;
  final MemoryRevisionDiff? revisionDiff;
  final String? errorKey;
}

final class MemoryLedgerState {
  const MemoryLedgerState({
    this.entries = const <MemoryLedgerEntry>[],
    this.nextBeforeEpisodeId,
    this.contextKey = '',
    this.filter = MemoryLedgerFilter.all,
    this.loaded = false,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.errorKey,
    this.paginationErrorKey,
    this.reviewErrorKey,
    this.reviewingEpisodeIds = const <int>{},
    this.expandedEpisodeIds = const <int>{},
    this.inspections = const <int, MemoryLedgerInspection>{},
  });

  final List<MemoryLedgerEntry> entries;
  final int? nextBeforeEpisodeId;
  final String contextKey;
  final MemoryLedgerFilter filter;
  final bool loaded;
  final bool isLoading;
  final bool isLoadingMore;
  final String? errorKey;
  final String? paginationErrorKey;
  final String? reviewErrorKey;
  final Set<int> reviewingEpisodeIds;
  final Set<int> expandedEpisodeIds;
  final Map<int, MemoryLedgerInspection> inspections;

  List<MemoryLedgerEntry> get visibleEntries =>
      List<MemoryLedgerEntry>.unmodifiable(entries.where(_matchesFilter));

  bool _matchesFilter(MemoryLedgerEntry entry) {
    final episode = entry.episode;
    return switch (filter) {
      MemoryLedgerFilter.all => true,
      MemoryLedgerFilter.needsReview =>
        entry.isHead &&
            (episode.reviewState == EpisodeReviewState.pending ||
                episode.sourceType == EpisodeSourceType.legacyUnknown),
      MemoryLedgerFilter.accepted =>
        episode.reviewState == EpisodeReviewState.accepted,
      MemoryLedgerFilter.rejected =>
        episode.reviewState == EpisodeReviewState.rejected,
      MemoryLedgerFilter.deleted =>
        episode.reviewState == EpisodeReviewState.tombstoned,
    };
  }

  MemoryLedgerState copyWith({
    List<MemoryLedgerEntry>? entries,
    Object? nextBeforeEpisodeId = _unchanged,
    String? contextKey,
    MemoryLedgerFilter? filter,
    bool? loaded,
    bool? isLoading,
    bool? isLoadingMore,
    Object? errorKey = _unchanged,
    Object? paginationErrorKey = _unchanged,
    Object? reviewErrorKey = _unchanged,
    Set<int>? reviewingEpisodeIds,
    Set<int>? expandedEpisodeIds,
    Map<int, MemoryLedgerInspection>? inspections,
  }) => MemoryLedgerState(
    entries: entries ?? this.entries,
    nextBeforeEpisodeId: identical(nextBeforeEpisodeId, _unchanged)
        ? this.nextBeforeEpisodeId
        : nextBeforeEpisodeId as int?,
    contextKey: contextKey ?? this.contextKey,
    filter: filter ?? this.filter,
    loaded: loaded ?? this.loaded,
    isLoading: isLoading ?? this.isLoading,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    errorKey: identical(errorKey, _unchanged)
        ? this.errorKey
        : errorKey as String?,
    paginationErrorKey: identical(paginationErrorKey, _unchanged)
        ? this.paginationErrorKey
        : paginationErrorKey as String?,
    reviewErrorKey: identical(reviewErrorKey, _unchanged)
        ? this.reviewErrorKey
        : reviewErrorKey as String?,
    reviewingEpisodeIds: reviewingEpisodeIds ?? this.reviewingEpisodeIds,
    expandedEpisodeIds: expandedEpisodeIds ?? this.expandedEpisodeIds,
    inspections: inspections ?? this.inspections,
  );
}

final class MemoryLedgerNotifier extends Notifier<MemoryLedgerState> {
  static const int pageSize = 20;

  late MemoryLedgerGateway _gateway;
  int _generation = 0;
  int _inspectionGeneration = 0;
  final Map<int, int> _inspectionRequests = <int, int>{};
  bool _disposed = false;

  @override
  MemoryLedgerState build() {
    _disposed = false;
    _gateway = ref.watch(memoryLedgerGatewayProvider);
    ref.onDispose(() => _disposed = true);
    return MemoryLedgerState(contextKey: _gateway.requestContextKey);
  }

  Future<void> ensureLoaded() async {
    if (state.isLoading) return;
    if (state.contextKey != _gateway.requestContextKey || !state.loaded) {
      await refresh();
    }
  }

  Future<void> refresh() async {
    final request = ++_generation;
    _inspectionGeneration++;
    _inspectionRequests.clear();
    final contextKey = _gateway.requestContextKey;
    final previous = state;
    state = MemoryLedgerState(
      contextKey: contextKey,
      filter: previous.filter,
      isLoading: true,
      reviewingEpisodeIds: previous.reviewingEpisodeIds,
      expandedEpisodeIds: previous.expandedEpisodeIds,
      inspections: previous.inspections,
    );
    try {
      final page = await _gateway.list(limit: pageSize);
      if (!_isCurrent(request, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      state = MemoryLedgerState(
        entries: List<MemoryLedgerEntry>.unmodifiable(page.entries),
        nextBeforeEpisodeId: page.nextBeforeEpisodeId,
        contextKey: contextKey,
        filter: state.filter,
        loaded: true,
        reviewingEpisodeIds: state.reviewingEpisodeIds,
        expandedEpisodeIds: state.expandedEpisodeIds,
        inspections: state.inspections,
      );
    } catch (_) {
      if (!_isCurrent(request, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      state = MemoryLedgerState(
        contextKey: contextKey,
        filter: state.filter,
        loaded: true,
        errorKey: 'memory_ledger.load_failed_message',
        reviewingEpisodeIds: state.reviewingEpisodeIds,
        expandedEpisodeIds: state.expandedEpisodeIds,
        inspections: state.inspections,
      );
    }
  }

  Future<void> loadMore() async {
    final cursor = state.nextBeforeEpisodeId;
    if (cursor == null ||
        state.isLoading ||
        state.isLoadingMore ||
        state.contextKey != _gateway.requestContextKey) {
      return;
    }
    final request = ++_generation;
    final contextKey = state.contextKey;
    state = state.copyWith(isLoadingMore: true, paginationErrorKey: null);
    try {
      final page = await _gateway.list(
        beforeEpisodeId: cursor,
        limit: pageSize,
      );
      if (!_isCurrent(request, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      final current = state;
      final known = current.entries
          .map((entry) => entry.episode.id)
          .whereType<int>()
          .toSet();
      final merged = <MemoryLedgerEntry>[
        ...current.entries,
        ...page.entries.where((entry) {
          final id = entry.episode.id;
          return id != null && known.add(id);
        }),
      ];
      state = current.copyWith(
        entries: List<MemoryLedgerEntry>.unmodifiable(merged),
        nextBeforeEpisodeId: page.nextBeforeEpisodeId,
        isLoadingMore: false,
        paginationErrorKey: null,
      );
    } catch (_) {
      if (!_isCurrent(request, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      state = state.copyWith(
        isLoadingMore: false,
        paginationErrorKey: 'memory_ledger.load_more_failed',
      );
    }
  }

  void setFilter(MemoryLedgerFilter filter) {
    if (state.filter == filter) return;
    state = state.copyWith(filter: filter);
  }

  Future<void> toggleExpanded(int episodeId) async {
    final entryExists = state.entries.any(
      (entry) => entry.episode.id == episodeId,
    );
    if (!entryExists) return;
    final expanded = Set<int>.of(state.expandedEpisodeIds);
    if (!expanded.add(episodeId)) {
      expanded.remove(episodeId);
      state = state.copyWith(
        expandedEpisodeIds: Set<int>.unmodifiable(expanded),
      );
      return;
    }
    state = state.copyWith(expandedEpisodeIds: Set<int>.unmodifiable(expanded));
    if (state.inspections[episodeId]?.detail == null) {
      await _loadInspection(episodeId);
    }
  }

  Future<void> retryInspection(int episodeId) async {
    if (!state.expandedEpisodeIds.contains(episodeId)) return;
    await _loadInspection(episodeId);
  }

  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) async {
    final contextKey = _gateway.requestContextKey;
    final targetId = command.targetEpisodeId;
    state = state.copyWith(
      reviewingEpisodeIds: Set<int>.unmodifiable(<int>{
        ...state.reviewingEpisodeIds,
        targetId,
      }),
      reviewErrorKey: null,
    );
    try {
      final result = await _gateway.review(command);
      if (_disposed || contextKey != _gateway.requestContextKey) {
        _resetForCurrentContext();
        return result;
      }
      if (result.status == MemoryGovernanceStatus.applied ||
          result.status == MemoryGovernanceStatus.conflict) {
        await refresh();
      } else {
        state = state.copyWith(reviewErrorKey: 'memory_ledger.action_failed');
      }
      return result;
    } catch (_) {
      final failure = MemoryGovernanceResult.failure(
        status: MemoryGovernanceStatus.invalid,
        action: command.action,
        reason: 'memory_review_unavailable',
        previousEpisodeId: command.expectedHeadEpisodeId,
      );
      if (_disposed || contextKey != _gateway.requestContextKey) {
        _resetForCurrentContext();
        return failure;
      }
      state = state.copyWith(reviewErrorKey: 'memory_ledger.action_failed');
      return failure;
    } finally {
      if (!_disposed) {
        final reviewing = Set<int>.of(state.reviewingEpisodeIds)
          ..remove(targetId);
        state = state.copyWith(
          reviewingEpisodeIds: Set<int>.unmodifiable(reviewing),
        );
      }
    }
  }

  Future<void> _loadInspection(int episodeId) async {
    final request = ++_inspectionGeneration;
    _inspectionRequests[episodeId] = request;
    final contextKey = _gateway.requestContextKey;
    _setInspection(episodeId, const MemoryLedgerInspection(isLoading: true));
    try {
      final detail = await _gateway.getDetail(episodeId);
      if (detail == null) {
        throw StateError('memory_ledger_detail_not_found');
      }
      final sourceRefs = detail.entry.episode.sourceRefs;
      final sourceTranscript = sourceRefs.isEmpty
          ? const MemorySourceTranscriptResult(
              status: MemorySourceTranscriptStatus.unavailable,
              sourceId: '',
              reason: 'source_ref_unavailable',
            )
          : await _gateway.sourceTranscript(sourceRefs.first);
      MemoryRevisionDiff? revisionDiff;
      final toEpisodeId = detail.entry.episode.id;
      final fromEpisodeId = detail.entry.episode.supersedesId;
      if (fromEpisodeId != null && toEpisodeId != null) {
        revisionDiff = await _gateway.diff(fromEpisodeId, toEpisodeId);
      }
      if (!_isInspectionCurrent(request, episodeId, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      _setInspection(
        episodeId,
        MemoryLedgerInspection(
          detail: detail,
          sourceTranscript: sourceTranscript,
          revisionDiff: revisionDiff,
        ),
      );
    } catch (_) {
      if (!_isInspectionCurrent(request, episodeId, contextKey)) {
        if (!_disposed && contextKey != _gateway.requestContextKey) {
          _resetForCurrentContext();
        }
        return;
      }
      _setInspection(
        episodeId,
        const MemoryLedgerInspection(
          errorKey: 'memory_ledger.detail_failed_message',
        ),
      );
    }
  }

  bool _isInspectionCurrent(int request, int episodeId, String contextKey) =>
      !_disposed &&
      _inspectionRequests[episodeId] == request &&
      contextKey == _gateway.requestContextKey;

  void _setInspection(int episodeId, MemoryLedgerInspection inspection) {
    if (_disposed) return;
    state = state.copyWith(
      inspections: Map<int, MemoryLedgerInspection>.unmodifiable(
        <int, MemoryLedgerInspection>{
          ...state.inspections,
          episodeId: inspection,
        },
      ),
    );
  }

  bool _isCurrent(int request, String contextKey) =>
      !_disposed &&
      request == _generation &&
      contextKey == _gateway.requestContextKey;

  void _resetForCurrentContext() {
    if (_disposed) return;
    _generation++;
    _inspectionGeneration++;
    _inspectionRequests.clear();
    state = MemoryLedgerState(
      contextKey: _gateway.requestContextKey,
      filter: state.filter,
    );
  }
}

const Object _unchanged = Object();
