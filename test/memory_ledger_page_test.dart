import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';
import 'package:maaso/src/features/memory/presentation/memory_ledger_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AppLocalization.updateLocale(const Locale('en')));

  testWidgets('shows bounded loading, empty, and error states', (tester) async {
    final pending = Completer<MemoryLedgerPage>();
    await _pumpLedger(tester, _LedgerGateway(pendingPage: pending));
    expect(find.byKey(AppSecondarySkeletonList.itemKey), findsWidgets);

    pending.complete(
      const MemoryLedgerPage(
        entries: <MemoryLedgerEntry>[],
        nextBeforeEpisodeId: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No memories to review'), findsOneWidget);

    await _pumpLedger(tester, _LedgerGateway(listError: StateError('offline')));
    await tester.pumpAndSettle();
    expect(find.text('Memory Ledger could not load'), findsOneWidget);
    expect(find.byKey(MemoryLedgerKeys.retry), findsOneWidget);
  });

  testWidgets('only the visible lineage head exposes 44px governance targets', (
    tester,
  ) async {
    final gateway = _LedgerGateway(
      entries: <MemoryLedgerEntry>[
        _entry(13, reviewState: EpisodeReviewState.pending),
        _entry(
          11,
          reviewState: EpisodeReviewState.accepted,
          isHead: false,
          supersededByEpisodeId: 13,
        ),
      ],
    );
    final semantics = tester.ensureSemantics();
    await _pumpLedger(tester, gateway);
    await tester.pumpAndSettle();

    expect(find.byKey(MemoryLedgerKeys.row(13)), findsOneWidget);
    expect(find.byKey(MemoryLedgerKeys.row(11)), findsOneWidget);
    expect(
      find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.accept, 13)),
      findsOneWidget,
    );
    expect(
      find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.accept, 11)),
      findsNothing,
    );
    expect(find.text('Read-only revision'), findsOneWidget);

    for (final action in <MemoryGovernanceAction>[
      MemoryGovernanceAction.accept,
      MemoryGovernanceAction.edit,
      MemoryGovernanceAction.reject,
    ]) {
      final finder = find.byKey(MemoryLedgerKeys.action(action, 13));
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(44), reason: action.name);
      expect(size.height, greaterThanOrEqualTo(44), reason: action.name);
    }
    expect(find.bySemanticsLabel('Accept memory revision'), findsWidgets);
    expect(find.text('Confidence 50%'), findsWidgets);
    semantics.dispose();
  });

  testWidgets(
    'accepted legacy head exposes review accept while runtime head does not',
    (tester) async {
      await _pumpLedger(
        tester,
        _LedgerGateway(
          entries: <MemoryLedgerEntry>[
            _entry(
              14,
              reviewState: EpisodeReviewState.accepted,
              sourceType: EpisodeSourceType.legacyUnknown,
            ),
            _entry(13, reviewState: EpisodeReviewState.accepted),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.accept, 14)),
        findsOneWidget,
      );
      expect(
        find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.edit, 14)),
        findsOneWidget,
      );
      expect(
        find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.delete, 14)),
        findsOneWidget,
      );
      expect(
        find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.accept, 13)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(MemoryLedgerKeys.row(14)),
          matching: find.text('Needs review'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(MemoryLedgerKeys.row(13)),
          matching: find.text('Accepted'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'filtered empty and short pages expose an explicit load-older action',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final gateway = _LedgerGateway(
        pages: <MemoryLedgerPage>[
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(20, reviewState: EpisodeReviewState.accepted),
            ],
            nextBeforeEpisodeId: 20,
          ),
          MemoryLedgerPage(
            entries: <MemoryLedgerEntry>[
              _entry(10, reviewState: EpisodeReviewState.pending),
            ],
            nextBeforeEpisodeId: null,
          ),
        ],
      );
      await _pumpLedger(tester, gateway);
      await tester.pumpAndSettle();

      expect(find.byKey(MemoryLedgerKeys.row(20)), findsOneWidget);
      expect(find.byKey(MemoryLedgerKeys.loadOlder), findsOneWidget);
      expect(
        tester.getSize(find.byKey(MemoryLedgerKeys.loadOlder)).height,
        greaterThanOrEqualTo(44),
      );
      expect(find.bySemanticsLabel('Load older memories'), findsWidgets);

      await tester.tap(
        find.byKey(MemoryLedgerKeys.filter(MemoryLedgerFilter.needsReview)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(MemoryLedgerKeys.row(20)), findsNothing);
      expect(find.byKey(MemoryLedgerKeys.loadOlder), findsOneWidget);

      await tester.tap(find.byKey(MemoryLedgerKeys.loadOlder));
      await tester.pumpAndSettle();

      expect(gateway.listCalls, 2);
      expect(find.byKey(MemoryLedgerKeys.row(10)), findsOneWidget);
      expect(find.byKey(MemoryLedgerKeys.loadOlder), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('review failures never render as pagination failures', (
    tester,
  ) async {
    final gateway = _LedgerGateway(
      entries: <MemoryLedgerEntry>[
        _entry(13, reviewState: EpisodeReviewState.pending, revision: 3),
      ],
      reviewResult: const MemoryGovernanceResult.failure(
        status: MemoryGovernanceStatus.invalid,
        action: MemoryGovernanceAction.accept,
        reason: 'memory_accept_requires_pending',
        previousEpisodeId: 13,
      ),
    );
    await _pumpLedger(tester, gateway);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(MemoryLedgerKeys.action(MemoryGovernanceAction.accept, 13)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MemoryLedgerKeys.confirmAction));
    await tester.pumpAndSettle();

    expect(find.byKey(MemoryLedgerKeys.reviewError), findsOneWidget);
    expect(find.text('Older memories could not load.'), findsNothing);
    expect(find.byKey(MemoryLedgerKeys.loadOlder), findsNothing);
  });

  testWidgets('account context rebuild uses the current notifier callbacks', (
    tester,
  ) async {
    final firstGateway = _LedgerGateway(
      entries: <MemoryLedgerEntry>[
        _entry(11, reviewState: EpisodeReviewState.accepted),
      ],
    );
    final secondGateway = _LedgerGateway(
      requestContextKey: 'ledger-page-test-b',
      entries: <MemoryLedgerEntry>[
        _entry(22, reviewState: EpisodeReviewState.accepted),
      ],
    );
    final gatewayProvider = StateProvider<MemoryLedgerGateway>(
      (_) => firstGateway,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryLedgerGatewayProvider.overrideWith(
            (ref) => ref.watch(gatewayProvider),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(),
          home: const MemoryLedgerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(MemoryLedgerKeys.row(11)), findsOneWidget);
    expect(firstGateway.listCalls, 1);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MemoryLedgerScreen)),
    );
    container.read(gatewayProvider.notifier).state = secondGateway;
    await tester.pumpAndSettle();
    expect(container.read(memoryLedgerGatewayProvider), same(secondGateway));
    expect(
      container.read(memoryLedgerProvider).contextKey,
      secondGateway.requestContextKey,
    );
    expect(secondGateway.listCalls, 1);
    expect(find.byKey(MemoryLedgerKeys.row(22)), findsOneWidget);
    expect(firstGateway.listCalls, 1);
    expect(secondGateway.listCalls, 1);

    await tester.tap(find.byTooltip('Refresh Memory Ledger'));
    await tester.pumpAndSettle();
    expect(firstGateway.listCalls, 1);
    expect(secondGateway.listCalls, 2);
  });

  testWidgets('reflows on small, landscape, large-text, and dark surfaces', (
    tester,
  ) async {
    for (final configuration
        in <({Size size, Brightness brightness, double textScale})>[
          (
            size: const Size(375, 812),
            brightness: Brightness.light,
            textScale: 1,
          ),
          (
            size: const Size(812, 375),
            brightness: Brightness.light,
            textScale: 1,
          ),
          (
            size: const Size(375, 812),
            brightness: Brightness.light,
            textScale: 1.8,
          ),
          (
            size: const Size(1024, 768),
            brightness: Brightness.dark,
            textScale: 1,
          ),
        ]) {
      await _pumpLedger(
        tester,
        _LedgerGateway(
          entries: <MemoryLedgerEntry>[
            _entry(13, reviewState: EpisodeReviewState.pending),
          ],
        ),
        size: configuration.size,
        brightness: configuration.brightness,
        textScale: configuration.textScale,
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '$configuration');
      expect(find.byKey(MemoryLedgerKeys.row(13)), findsOneWidget);
      final frame = find.byKey(AppSecondaryScaffold.contentFrameKey);
      expect(frame, findsOneWidget);
      expect(tester.getSize(frame).width, lessThanOrEqualTo(920));
    }
  });

  for (final sourceStatus in MemorySourceTranscriptStatus.values) {
    testWidgets(
      'expanded row renders ${sourceStatus.name} source and previous diff',
      (tester) async {
        final source = EpisodeSourceRef(
          sourceId: 'chat_message:7',
          sessionId: 'session-7',
          origin: EpisodeSourceOrigin.user,
          contentHash: 'a' * 64,
        );
        final head = _entry(
          13,
          reviewState: EpisodeReviewState.accepted,
          revision: 3,
          supersedesId: 12,
          sourceRefs: <EpisodeSourceRef>[source],
        );
        final prior = _entry(
          12,
          reviewState: EpisodeReviewState.pending,
          revision: 2,
          isHead: false,
          supersededByEpisodeId: 13,
        );
        final gateway = _LedgerGateway(
          entries: <MemoryLedgerEntry>[head],
          details: <int, MemoryLedgerDetail>{
            13: MemoryLedgerDetail(
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
            (12, 13): const MemoryRevisionDiff(
              fromEpisodeId: 12,
              toEpisodeId: 13,
              sameLineage: true,
              changes: <MemoryRevisionFieldChange>[
                MemoryRevisionFieldChange(
                  field: 'what',
                  before: 'Memory 12',
                  after: 'Memory 13',
                ),
              ],
            ),
          },
        );
        await _pumpLedger(tester, gateway);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(MemoryLedgerKeys.expand(13)));
        await tester.pumpAndSettle();

        final statusLabel = switch (sourceStatus) {
          MemorySourceTranscriptStatus.verified => 'Source verified',
          MemorySourceTranscriptStatus.unavailable => 'Source unavailable',
          MemorySourceTranscriptStatus.integrityFailure =>
            'Source integrity check failed',
        };
        expect(find.text(statusLabel), findsOneWidget);
        if (sourceStatus == MemorySourceTranscriptStatus.verified) {
          expect(find.text('The exact user transcript.'), findsOneWidget);
        }
        expect(find.text('Memory 12'), findsOneWidget);
        expect(find.text('Memory 13'), findsWidgets);
      },
    );
  }

  for (final testCase
      in <
        ({
          MemoryGovernanceAction action,
          EpisodeReviewState reviewState,
          EpisodeSourceType sourceType,
        })
      >[
        (
          action: MemoryGovernanceAction.accept,
          reviewState: EpisodeReviewState.pending,
          sourceType: EpisodeSourceType.runtimeUnknown,
        ),
        (
          action: MemoryGovernanceAction.accept,
          reviewState: EpisodeReviewState.accepted,
          sourceType: EpisodeSourceType.legacyUnknown,
        ),
        (
          action: MemoryGovernanceAction.edit,
          reviewState: EpisodeReviewState.pending,
          sourceType: EpisodeSourceType.runtimeUnknown,
        ),
        (
          action: MemoryGovernanceAction.reject,
          reviewState: EpisodeReviewState.pending,
          sourceType: EpisodeSourceType.runtimeUnknown,
        ),
        (
          action: MemoryGovernanceAction.delete,
          reviewState: EpisodeReviewState.accepted,
          sourceType: EpisodeSourceType.runtimeUnknown,
        ),
        (
          action: MemoryGovernanceAction.restore,
          reviewState: EpisodeReviewState.rejected,
          sourceType: EpisodeSourceType.runtimeUnknown,
        ),
      ]) {
    testWidgets(
      'manual ${testCase.action.name} ${testCase.sourceType.name} requires '
      'confirmation before review',
      (tester) async {
        final gateway = _LedgerGateway(
          entries: <MemoryLedgerEntry>[
            _entry(
              13,
              reviewState: testCase.reviewState,
              revision: 3,
              sourceType: testCase.sourceType,
            ),
          ],
        );
        await _pumpLedger(tester, gateway);
        await tester.pumpAndSettle();
        final action = find.byKey(MemoryLedgerKeys.action(testCase.action, 13));

        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byKey(MemoryLedgerKeys.confirmationSheet), findsOneWidget);
        expect(gateway.commands, isEmpty);
        await tester.tap(find.byKey(MemoryLedgerKeys.cancelConfirmation));
        await tester.pumpAndSettle();
        expect(gateway.commands, isEmpty);

        await tester.tap(action);
        await tester.pumpAndSettle();
        if (testCase.action == MemoryGovernanceAction.edit) {
          await tester.enterText(
            find.byKey(MemoryLedgerKeys.editField),
            'A precisely edited memory.',
          );
        }
        await tester.tap(find.byKey(MemoryLedgerKeys.confirmAction));
        await tester.pumpAndSettle();

        expect(gateway.commands, hasLength(1));
        final command = gateway.commands.single;
        expect(command.action, testCase.action);
        expect(command.targetEpisodeId, 13);
        expect(command.expectedHeadEpisodeId, 13);
        expect(command.expectedRevision, 3);
        expect(
          command.edit?.what,
          testCase.action == MemoryGovernanceAction.edit
              ? 'A precisely edited memory.'
              : isNull,
        );
      },
    );
  }
}

Future<void> _pumpLedger(
  WidgetTester tester,
  MemoryLedgerGateway gateway, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [memoryLedgerGatewayProvider.overrideWithValue(gateway)],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const MemoryLedgerScreen(),
      ),
    ),
  );
  await tester.pump();
}

MemoryLedgerEntry _entry(
  int id, {
  required EpisodeReviewState reviewState,
  int revision = 1,
  int? supersedesId,
  bool isHead = true,
  int? supersededByEpisodeId,
  List<EpisodeSourceRef> sourceRefs = const <EpisodeSourceRef>[],
  EpisodeSourceType? sourceType,
}) {
  final current = Episode(
    id: id,
    when: DateTime.utc(2026, 8, 30),
    what: 'Memory $id',
    reviewState: reviewState,
    revision: revision,
    supersedesId: supersedesId,
    sourceRefs: sourceRefs,
    sourceType:
        sourceType == null || sourceType == EpisodeSourceType.legacyUnknown
        ? (sourceRefs.isEmpty
              ? EpisodeSourceType.runtimeUnknown
              : EpisodeSourceType.conversation)
        : sourceType,
  );
  final episode = sourceType == EpisodeSourceType.legacyUnknown
      ? (Episode.fromJson(<String, Object?>{
          ...current.toJson(),
          'sourceType': EpisodeSourceType.legacyUnknown.name,
        })..id = id)
      : current;
  return MemoryLedgerEntry(
    episode: episode,
    current: isHead && reviewState == EpisodeReviewState.accepted,
    isHead: isHead,
    lineageId: 11,
    supersededByEpisodeId: supersededByEpisodeId,
  );
}

MemoryRevisionSummary _revision(
  MemoryLedgerEntry entry, {
  required bool isHead,
}) => MemoryRevisionSummary(
  episode: entry.episode,
  current: entry.current,
  isHead: isHead,
  lineageId: entry.lineageId,
);

final class _LedgerGateway implements MemoryLedgerGateway {
  _LedgerGateway({
    List<MemoryLedgerEntry> entries = const <MemoryLedgerEntry>[],
    List<MemoryLedgerPage>? pages,
    this.requestContextKey = 'ledger-page-test',
    this.pendingPage,
    this.listError,
    this.reviewResult,
    Map<int, MemoryLedgerDetail> details = const <int, MemoryLedgerDetail>{},
    Map<String, MemorySourceTranscriptResult> transcripts =
        const <String, MemorySourceTranscriptResult>{},
    Map<(int, int), MemoryRevisionDiff> diffs =
        const <(int, int), MemoryRevisionDiff>{},
  }) : entries = List<MemoryLedgerEntry>.unmodifiable(entries),
       pages = pages == null
           ? null
           : List<MemoryLedgerPage>.unmodifiable(pages),
       details = Map<int, MemoryLedgerDetail>.unmodifiable(details),
       transcripts = Map<String, MemorySourceTranscriptResult>.unmodifiable(
         transcripts,
       ),
       diffs = Map<(int, int), MemoryRevisionDiff>.unmodifiable(diffs);

  final List<MemoryLedgerEntry> entries;
  final List<MemoryLedgerPage>? pages;
  @override
  final String requestContextKey;
  final Completer<MemoryLedgerPage>? pendingPage;
  final Object? listError;
  final MemoryGovernanceResult? reviewResult;
  final Map<int, MemoryLedgerDetail> details;
  final Map<String, MemorySourceTranscriptResult> transcripts;
  final Map<(int, int), MemoryRevisionDiff> diffs;
  final List<MemoryGovernanceCommand> commands = <MemoryGovernanceCommand>[];
  int listCalls = 0;
  final Object _authority = Object();

  @override
  Object get authorityToken => _authority;

  @override
  bool get isAvailable => true;

  @override
  Future<MemoryLedgerPage> list({int? beforeEpisodeId, int limit = 20}) async {
    listCalls += 1;
    if (listError != null) throw listError!;
    if (pendingPage != null) return pendingPage!.future;
    final configuredPages = pages;
    if (configuredPages != null) {
      final requestedIndex = listCalls - 1;
      final index = requestedIndex < configuredPages.length
          ? requestedIndex
          : configuredPages.length - 1;
      return configuredPages[index];
    }
    return MemoryLedgerPage(entries: entries, nextBeforeEpisodeId: null);
  }

  @override
  Future<MemoryLedgerDetail?> getDetail(int episodeId) async =>
      details[episodeId];

  @override
  Future<MemoryRevisionDiff> diff(int fromEpisodeId, int toEpisodeId) async =>
      diffs[(fromEpisodeId, toEpisodeId)]!;

  @override
  Future<MemorySourceTranscriptResult> sourceTranscript(
    EpisodeSourceRef source,
  ) async => transcripts[source.sourceId]!;

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) async {
    commands.add(command);
    final configuredResult = reviewResult;
    if (configuredResult != null) return configuredResult;
    final reviewState = switch (command.action) {
      MemoryGovernanceAction.reject => EpisodeReviewState.rejected,
      MemoryGovernanceAction.delete => EpisodeReviewState.tombstoned,
      _ => EpisodeReviewState.accepted,
    };
    return MemoryGovernanceResult(
      status: MemoryGovernanceStatus.applied,
      action: command.action,
      previousEpisodeId: command.expectedHeadEpisodeId,
      episode: Episode(
        id: 14,
        when: DateTime.utc(2026, 8, 30),
        what: command.edit?.what ?? 'Memory 13',
        reviewState: reviewState,
        revision: 4,
        supersedesId: 13,
      ),
    );
  }
}
