import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';

void main() {
  test('loads bounded pages and merges unique entries', () async {
    final gateway = _FakeLedgerGateway(
      pages: <MemoryLedgerPage>[
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[_entry(5), _entry(4)],
          nextBeforeEpisodeId: 4,
        ),
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[_entry(4), _entry(3)],
          nextBeforeEpisodeId: null,
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(memoryLedgerProvider.notifier);

    await notifier.refresh();
    await notifier.loadMore();

    final state = container.read(memoryLedgerProvider);
    expect(state.entries.map((entry) => entry.episode.id), <int?>[5, 4, 3]);
    expect(state.nextBeforeEpisodeId, isNull);
    expect(gateway.requests, <({int? beforeEpisodeId, int limit})>[
      (beforeEpisodeId: null, limit: 20),
      (beforeEpisodeId: 4, limit: 20),
    ]);
  });

  test(
    'filters review queues without changing the immutable source page',
    () async {
      final gateway = _FakeLedgerGateway(
        pages: <MemoryLedgerPage>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(6, reviewState: EpisodeReviewState.pending, isHead: false),
              _entry(5, reviewState: EpisodeReviewState.pending),
              _entry(4, reviewState: EpisodeReviewState.accepted),
              _entry(3, reviewState: EpisodeReviewState.rejected),
              _entry(2, reviewState: EpisodeReviewState.tombstoned),
              _entry(
                1,
                reviewState: EpisodeReviewState.accepted,
                sourceType: EpisodeSourceType.legacyUnknown,
              ),
            ],
            nextBeforeEpisodeId: null,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);
      await notifier.refresh();

      notifier.setFilter(MemoryLedgerFilter.needsReview);
      expect(
        container
            .read(memoryLedgerProvider)
            .visibleEntries
            .map((entry) => entry.episode.id),
        <int?>[5, 1],
      );
      notifier.setFilter(MemoryLedgerFilter.deleted);
      expect(
        container
            .read(memoryLedgerProvider)
            .visibleEntries
            .map((entry) => entry.episode.id),
        <int?>[2],
      );
      expect(container.read(memoryLedgerProvider).entries, hasLength(6));
    },
  );

  test('drops a stale response when the account context changes', () async {
    final gate = Completer<MemoryLedgerPage>();
    final gateway = _FakeLedgerGateway(pendingPage: gate);
    final container = ProviderContainer(
      overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);
    final refresh = container.read(memoryLedgerProvider.notifier).refresh();

    gateway.contextKey = 'account-b';
    gate.complete(
      MemoryLedgerPage(
        entries: <MemoryLedgerEntry>[_entry(99)],
        nextBeforeEpisodeId: null,
      ),
    );
    await refresh;

    expect(container.read(memoryLedgerProvider).entries, isEmpty);
    expect(container.read(memoryLedgerProvider).contextKey, 'account-b');
  });

  test(
    'review forwards typed CAS command and refreshes after success',
    () async {
      final gateway = _FakeLedgerGateway(
        pages: <MemoryLedgerPage>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(1, reviewState: EpisodeReviewState.pending),
            ],
            nextBeforeEpisodeId: null,
          ),
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(2, reviewState: EpisodeReviewState.accepted, revision: 2),
            ],
            nextBeforeEpisodeId: null,
          ),
        ],
        reviewResult: MemoryGovernanceResult(
          status: MemoryGovernanceStatus.applied,
          action: MemoryGovernanceAction.accept,
          previousEpisodeId: 1,
          episode: _entry(
            2,
            reviewState: EpisodeReviewState.accepted,
            revision: 2,
          ).episode,
        ),
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);
      await notifier.refresh();
      final command = MemoryGovernanceCommand(
        action: MemoryGovernanceAction.accept,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: 1,
        expectedRevision: 1,
      );

      final result = await notifier.review(command);

      expect(result.status, MemoryGovernanceStatus.applied);
      expect(gateway.commands, <MemoryGovernanceCommand>[command]);
      expect(container.read(memoryLedgerProvider).entries.single.episode.id, 2);
      expect(container.read(memoryLedgerProvider).reviewingEpisodeIds, isEmpty);
    },
  );

  test('review gateway failure becomes a typed invalid result', () async {
    final gateway = _FakeLedgerGateway(
      pages: <MemoryLedgerPage>[
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(1, reviewState: EpisodeReviewState.pending),
          ],
          nextBeforeEpisodeId: null,
        ),
      ],
      reviewError: StateError('retired'),
    );
    final container = ProviderContainer(
      overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(memoryLedgerProvider.notifier);
    await notifier.refresh();
    final command = MemoryGovernanceCommand(
      action: MemoryGovernanceAction.reject,
      targetEpisodeId: 1,
      expectedHeadEpisodeId: 1,
      expectedRevision: 1,
    );

    final result = await notifier.review(command);

    expect(result.status, MemoryGovernanceStatus.invalid);
    expect(result.action, MemoryGovernanceAction.reject);
    expect(result.reason, 'memory_review_unavailable');
    expect(
      container.read(memoryLedgerProvider).reviewErrorKey,
      'memory_ledger.action_failed',
    );
    expect(container.read(memoryLedgerProvider).paginationErrorKey, isNull);
    expect(container.read(memoryLedgerProvider).reviewingEpisodeIds, isEmpty);
  });

  test('conflict refreshes the head and removes stale controls', () async {
    final gateway = _FakeLedgerGateway(
      pages: <FutureOr<MemoryLedgerPage>>[
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(1, reviewState: EpisodeReviewState.pending),
          ],
          nextBeforeEpisodeId: null,
        ),
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(
              2,
              reviewState: EpisodeReviewState.accepted,
              revision: 2,
              supersedesId: 1,
            ),
          ],
          nextBeforeEpisodeId: null,
        ),
      ],
      reviewResult: const MemoryGovernanceResult.failure(
        status: MemoryGovernanceStatus.conflict,
        action: MemoryGovernanceAction.accept,
        reason: 'stale_memory_revision',
        previousEpisodeId: 1,
      ),
    );
    final container = ProviderContainer(
      overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(memoryLedgerProvider.notifier);
    await notifier.refresh();

    final result = await notifier.review(
      MemoryGovernanceCommand(
        action: MemoryGovernanceAction.accept,
        targetEpisodeId: 1,
        expectedHeadEpisodeId: 1,
        expectedRevision: 1,
      ),
    );

    final state = container.read(memoryLedgerProvider);
    expect(result.status, MemoryGovernanceStatus.conflict);
    expect(gateway.requests, hasLength(2));
    expect(state.entries.single.episode.id, 2);
    expect(state.entries.single.episode.revision, 2);
    expect(state.reviewingEpisodeIds, isEmpty);
    expect(state.reviewErrorKey, isNull);
  });

  test(
    'delayed refresh and pagination preserve current filter and expanded rows',
    () async {
      final delayedRefresh = Completer<MemoryLedgerPage>();
      final delayedPage = Completer<MemoryLedgerPage>();
      final entry = _entry(5, reviewState: EpisodeReviewState.accepted);
      final gateway = _FakeLedgerGateway(
        pages: <FutureOr<MemoryLedgerPage>>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[entry],
            nextBeforeEpisodeId: 5,
          ),
          delayedRefresh.future,
          delayedPage.future,
        ],
        details: <int, MemoryLedgerDetail>{
          5: MemoryLedgerDetail(
            entry: entry,
            revisions: <MemoryRevisionSummary>[_revision(entry, isHead: true)],
          ),
        },
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);
      await notifier.refresh();
      await notifier.toggleExpanded(5);

      final refreshing = notifier.refresh();
      notifier.setFilter(MemoryLedgerFilter.accepted);
      delayedRefresh.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[entry],
          nextBeforeEpisodeId: 5,
        ),
      );
      await refreshing;
      expect(
        container.read(memoryLedgerProvider).filter,
        MemoryLedgerFilter.accepted,
      );
      expect(container.read(memoryLedgerProvider).expandedEpisodeIds, <int>{5});

      final loadingMore = notifier.loadMore();
      notifier.setFilter(MemoryLedgerFilter.needsReview);
      await notifier.toggleExpanded(5);
      delayedPage.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(4, reviewState: EpisodeReviewState.pending),
          ],
          nextBeforeEpisodeId: null,
        ),
      );
      await loadingMore;

      final state = container.read(memoryLedgerProvider);
      expect(state.filter, MemoryLedgerFilter.needsReview);
      expect(state.expandedEpisodeIds, isEmpty);
      expect(state.entries.map((entry) => entry.episode.id), <int?>[5, 4]);
    },
  );

  test(
    'older pagination completion cannot clear a newer refresh in one account',
    () async {
      final delayedPage = Completer<MemoryLedgerPage>();
      final delayedRefresh = Completer<MemoryLedgerPage>();
      final gateway = _FakeLedgerGateway(
        pages: <FutureOr<MemoryLedgerPage>>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(5, reviewState: EpisodeReviewState.accepted),
            ],
            nextBeforeEpisodeId: 5,
          ),
          delayedPage.future,
          delayedRefresh.future,
        ],
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);
      await notifier.refresh();

      final loadingMore = notifier.loadMore();
      final refreshing = notifier.refresh();
      delayedRefresh.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(9, reviewState: EpisodeReviewState.accepted),
          ],
          nextBeforeEpisodeId: null,
        ),
      );
      await refreshing;
      delayedPage.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(4, reviewState: EpisodeReviewState.pending),
          ],
          nextBeforeEpisodeId: null,
        ),
      );
      await loadingMore;

      final state = container.read(memoryLedgerProvider);
      expect(state.loaded, isTrue);
      expect(state.entries.map((entry) => entry.episode.id), <int?>[9]);
      expect(state.contextKey, gateway.requestContextKey);
    },
  );

  test(
    'older refresh completion cannot clear a newer refresh in one account',
    () async {
      final olderRefresh = Completer<MemoryLedgerPage>();
      final newerRefresh = Completer<MemoryLedgerPage>();
      final gateway = _FakeLedgerGateway(
        pages: <FutureOr<MemoryLedgerPage>>[
          olderRefresh.future,
          newerRefresh.future,
        ],
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);

      final older = notifier.refresh();
      final newer = notifier.refresh();
      notifier.setFilter(MemoryLedgerFilter.accepted);
      newerRefresh.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(9, reviewState: EpisodeReviewState.accepted),
          ],
          nextBeforeEpisodeId: null,
        ),
      );
      await newer;
      olderRefresh.complete(
        MemoryLedgerPage(
          entries: <MemoryLedgerEntry>[
            _entry(4, reviewState: EpisodeReviewState.pending),
          ],
          nextBeforeEpisodeId: null,
        ),
      );
      await older;

      final state = container.read(memoryLedgerProvider);
      expect(state.loaded, isTrue);
      expect(state.filter, MemoryLedgerFilter.accepted);
      expect(state.entries.map((entry) => entry.episode.id), <int?>[9]);
      expect(state.contextKey, gateway.requestContextKey);
    },
  );

  for (final sourceStatus in MemorySourceTranscriptStatus.values) {
    test(
      'expands one bounded row with ${sourceStatus.name} source and revision diff',
      () async {
        final source = EpisodeSourceRef(
          sourceId: 'chat_message:7',
          sessionId: 'session-7',
          origin: EpisodeSourceOrigin.user,
          contentHash: 'a' * 64,
        );
        final head = _entry(
          3,
          revision: 2,
          supersedesId: 2,
          sourceRefs: <EpisodeSourceRef>[source],
        );
        final prior = _entry(2);
        final gateway = _FakeLedgerGateway(
          pages: <MemoryLedgerPage>[
            MemoryLedgerPage(
              entries: <MemoryLedgerEntry>[head],
              nextBeforeEpisodeId: null,
            ),
          ],
          details: <int, MemoryLedgerDetail>{
            3: MemoryLedgerDetail(
              entry: head,
              revisions: <MemoryRevisionSummary>[
                _revision(head, isHead: true),
                _revision(prior, isHead: false),
              ],
            ),
          },
          transcripts: <String, MemorySourceTranscriptResult>{
            source.sourceId: MemorySourceTranscriptResult(
              status: sourceStatus,
              sourceId: source.sourceId,
              content: sourceStatus == MemorySourceTranscriptStatus.verified
                  ? 'The exact user transcript.'
                  : null,
              reason: sourceStatus == MemorySourceTranscriptStatus.verified
                  ? null
                  : 'source_${sourceStatus.name}',
            ),
          },
          diffs: <(int, int), MemoryRevisionDiff>{
            (2, 3): const MemoryRevisionDiff(
              fromEpisodeId: 2,
              toEpisodeId: 3,
              sameLineage: true,
              changes: <MemoryRevisionFieldChange>[
                MemoryRevisionFieldChange(
                  field: 'what',
                  before: 'Memory 2',
                  after: 'Memory 3',
                ),
              ],
            ),
          },
        );
        final container = ProviderContainer(
          overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
        );
        addTearDown(container.dispose);
        final notifier = container.read(memoryLedgerProvider.notifier);

        await notifier.refresh();
        await notifier.toggleExpanded(3);

        final state = container.read(memoryLedgerProvider);
        expect(state.expandedEpisodeIds, <int>{3});
        final inspection = state.inspections[3]!;
        expect(inspection.isLoading, isFalse);
        expect(inspection.errorKey, isNull);
        expect(inspection.detail?.entry.episode.id, 3);
        expect(inspection.sourceTranscript?.status, sourceStatus);
        expect(inspection.revisionDiff?.changes.single.field, 'what');
        expect(gateway.detailRequests, <int>[3]);
        expect(gateway.transcriptRequests, <String>['chat_message:7']);
        expect(gateway.diffRequests, <(int, int)>[(2, 3)]);

        await notifier.toggleExpanded(3);
        expect(
          container.read(memoryLedgerProvider).expandedEpisodeIds,
          isEmpty,
        );
        expect(gateway.detailRequests, <int>[3]);
      },
    );
  }

  test(
    'historical row diff uses its own predecessor instead of latest head',
    () async {
      final root = _entry(1, isHead: false);
      final historical = _entry(2, supersedesId: 1, isHead: false);
      final head = _entry(3, revision: 3, supersedesId: 2);
      final gateway = _FakeLedgerGateway(
        pages: <MemoryLedgerPage>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[historical],
            nextBeforeEpisodeId: null,
          ),
        ],
        details: <int, MemoryLedgerDetail>{
          2: MemoryLedgerDetail(
            entry: historical,
            revisions: <MemoryRevisionSummary>[
              _revision(head, isHead: true),
              _revision(historical, isHead: false),
              _revision(root, isHead: false),
            ],
          ),
        },
        diffs: <(int, int), MemoryRevisionDiff>{
          (1, 2): const MemoryRevisionDiff(
            fromEpisodeId: 1,
            toEpisodeId: 2,
            sameLineage: true,
            changes: <MemoryRevisionFieldChange>[
              MemoryRevisionFieldChange(
                field: 'what',
                before: 'Memory 1',
                after: 'Memory 2',
              ),
            ],
          ),
        },
      );
      final container = ProviderContainer(
        overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(memoryLedgerProvider.notifier);

      await notifier.refresh();
      await notifier.toggleExpanded(2);

      final inspection = container.read(memoryLedgerProvider).inspections[2]!;
      expect(inspection.errorKey, isNull);
      expect(inspection.revisionDiff?.fromEpisodeId, 1);
      expect(inspection.revisionDiff?.toEpisodeId, 2);
      expect(gateway.diffRequests, <(int, int)>[(1, 2)]);
    },
  );
}

MemoryLedgerEntry _entry(
  int id, {
  EpisodeReviewState reviewState = EpisodeReviewState.accepted,
  EpisodeSourceType sourceType = EpisodeSourceType.runtimeUnknown,
  int revision = 1,
  int? supersedesId,
  bool isHead = true,
  List<EpisodeSourceRef> sourceRefs = const <EpisodeSourceRef>[],
}) {
  final current = Episode(
    id: id,
    when: DateTime.utc(2026, 8, 30),
    what: 'Memory $id',
    reviewState: reviewState,
    revision: revision,
    supersedesId: supersedesId,
    sourceRefs: sourceRefs,
    sourceType: sourceRefs.isEmpty
        ? EpisodeSourceType.runtimeUnknown
        : EpisodeSourceType.conversation,
  );
  final episode = sourceType == EpisodeSourceType.legacyUnknown
      ? (Episode.fromJson(<String, Object?>{
          ...current.toJson(),
          'sourceType': EpisodeSourceType.legacyUnknown.name,
        })..id = id)
      : current;
  return MemoryLedgerEntry(
    episode: episode,
    current: true,
    isHead: isHead,
    lineageId: id,
    supersededByEpisodeId: null,
  );
}

MemoryRevisionSummary _revision(
  MemoryLedgerEntry entry, {
  required bool isHead,
}) => MemoryRevisionSummary(
  episode: entry.episode,
  current: entry.current,
  isHead: isHead,
  lineageId: 2,
);

final class _FakeLedgerGateway implements MemoryLedgerGateway {
  _FakeLedgerGateway({
    List<FutureOr<MemoryLedgerPage>> pages =
        const <FutureOr<MemoryLedgerPage>>[],
    this.pendingPage,
    this.reviewResult,
    this.reviewError,
    Map<int, MemoryLedgerDetail> details = const <int, MemoryLedgerDetail>{},
    Map<String, MemorySourceTranscriptResult> transcripts =
        const <String, MemorySourceTranscriptResult>{},
    Map<(int, int), MemoryRevisionDiff> diffs =
        const <(int, int), MemoryRevisionDiff>{},
  }) : pages = List<FutureOr<MemoryLedgerPage>>.of(pages),
       details = Map<int, MemoryLedgerDetail>.of(details),
       transcripts = Map<String, MemorySourceTranscriptResult>.of(transcripts),
       diffs = Map<(int, int), MemoryRevisionDiff>.of(diffs);

  final List<FutureOr<MemoryLedgerPage>> pages;
  final Completer<MemoryLedgerPage>? pendingPage;
  final MemoryGovernanceResult? reviewResult;
  final Object? reviewError;
  final Map<int, MemoryLedgerDetail> details;
  final Map<String, MemorySourceTranscriptResult> transcripts;
  final Map<(int, int), MemoryRevisionDiff> diffs;
  final List<({int? beforeEpisodeId, int limit})> requests =
      <({int? beforeEpisodeId, int limit})>[];
  final List<MemoryGovernanceCommand> commands = <MemoryGovernanceCommand>[];
  final List<int> detailRequests = <int>[];
  final List<String> transcriptRequests = <String>[];
  final List<(int, int)> diffRequests = <(int, int)>[];
  final Object _token = Object();
  String contextKey = 'account-a';

  @override
  Object get authorityToken => _token;

  @override
  bool get isAvailable => true;

  @override
  String get requestContextKey => contextKey;

  @override
  Future<MemoryLedgerPage> list({int? beforeEpisodeId, int limit = 20}) async {
    requests.add((beforeEpisodeId: beforeEpisodeId, limit: limit));
    final pending = pendingPage;
    if (pending != null) return pending.future;
    return await pages.removeAt(0);
  }

  @override
  Future<MemoryLedgerDetail?> getDetail(int episodeId) async {
    detailRequests.add(episodeId);
    return details[episodeId];
  }

  @override
  Future<MemoryRevisionDiff> diff(int fromEpisodeId, int toEpisodeId) async {
    diffRequests.add((fromEpisodeId, toEpisodeId));
    return diffs[(fromEpisodeId, toEpisodeId)]!;
  }

  @override
  Future<MemorySourceTranscriptResult> sourceTranscript(
    EpisodeSourceRef source,
  ) async {
    transcriptRequests.add(source.sourceId);
    return transcripts[source.sourceId]!;
  }

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) async {
    commands.add(command);
    if (reviewError != null) throw reviewError!;
    return reviewResult!;
  }
}
