import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_observability.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test('snapshot has complete fixed-cardinality dimensions', () {
    var now = Duration.zero;
    final observability = AvatarSelectionObservability(
      monotonicClock: () => now,
    );

    observability.observeLifecycle(
      AvatarSelectionObservabilityLifecycle.sealing,
    );
    observability.observeCurrent(proven: true, version: 7);
    final observation = observability.begin(
      AvatarSelectionObservedOperation.selectionCommit,
    );
    observability.retry(observation);
    now = const Duration(milliseconds: 720);
    observability.end(
      observation,
      outcome: AvatarSelectionObservedOutcome.succeeded,
    );

    final snapshot = observability.snapshot;
    expect(snapshot.lifecycle, AvatarSelectionObservabilityLifecycle.sealing);
    expect(snapshot.currentProven, isTrue);
    expect(snapshot.currentVersion, 7);
    expect(snapshot.outboxObserved, isFalse);
    expect(snapshot.outboxPresent, isFalse);
    expect(snapshot.outboxStage, isNull);
    expect(snapshot.outboxResolution, isNull);
    expect(snapshot.outboxAgeBucket, isNull);
    expect(snapshot.inFlight, 0);
    expect(snapshot.retryTotal, 1);
    expect(snapshot.retryMax, 1);
    expect(snapshot.operationCounts.keys.toSet(), {
      ...AvatarSelectionObservedOperation.values,
    });
    expect(snapshot.outcomeCounts.keys.toSet(), {
      ...AvatarSelectionObservedOutcome.values,
    });
    expect(snapshot.latencyBuckets.keys.toSet(), {
      ...AvatarSelectionLatencyBucket.values,
    });
    expect(
      snapshot.operationCounts[AvatarSelectionObservedOperation
          .selectionCommit],
      1,
    );
    expect(snapshot.outcomeCounts[AvatarSelectionObservedOutcome.succeeded], 1);
    expect(snapshot.latencyBuckets[AvatarSelectionLatencyBucket.under2s], 1);

    final metrics = snapshot.toMetrics();
    expect(metrics.keys.toSet(), <String>{
      'lifecycle',
      'currentProven',
      'currentVersion',
      'outboxObserved',
      'outboxPresent',
      'outboxStage',
      'outboxResolution',
      'outboxAgeBucket',
      'inFlight',
      'operationCounts',
      'outcomeCounts',
      'retryTotal',
      'retryMax',
      'latencyBuckets',
    });
    expect(
      (metrics['operationCounts']! as Map<String, int>).length,
      AvatarSelectionObservedOperation.values.length,
    );
    expect(
      (metrics['outcomeCounts']! as Map<String, int>).length,
      AvatarSelectionObservedOutcome.values.length,
    );
    expect(
      (metrics['latencyBuckets']! as Map<String, int>).length,
      AvatarSelectionLatencyBucket.values.length,
    );
  });

  test('counters, retries, and in-flight state saturate safely', () {
    var now = Duration.zero;
    final observability = AvatarSelectionObservability(
      monotonicClock: () => now,
      maximumCounter: 2,
    );

    final first = observability.begin(
      AvatarSelectionObservedOperation.exactReplay,
    );
    final second = observability.begin(
      AvatarSelectionObservedOperation.exactReplay,
    );
    final overflow = observability.begin(
      AvatarSelectionObservedOperation.exactReplay,
    );
    expect(observability.snapshot.inFlight, 2);

    for (var index = 0; index < 4; index += 1) {
      observability.retry(first);
    }
    now = const Duration(seconds: 12);
    observability.end(
      first,
      outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
    );
    observability.end(
      second,
      outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
    );
    observability.end(
      overflow,
      outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
    );
    observability.end(first, outcome: AvatarSelectionObservedOutcome.failed);

    observability.record(
      operation: AvatarSelectionObservedOperation.exactReplay,
      outcome: AvatarSelectionObservedOutcome.ambiguousFailure,
      latency: const Duration(seconds: 30),
      retries: 50,
    );

    final snapshot = observability.snapshot;
    expect(snapshot.inFlight, 0);
    expect(snapshot.retryTotal, 2);
    expect(snapshot.retryMax, 2);
    expect(
      snapshot.operationCounts[AvatarSelectionObservedOperation.exactReplay],
      2,
    );
    expect(
      snapshot.outcomeCounts[AvatarSelectionObservedOutcome.ambiguousFailure],
      2,
    );
    expect(snapshot.outcomeCounts[AvatarSelectionObservedOutcome.failed], 0);
    expect(
      snapshot.latencyBuckets[AvatarSelectionLatencyBucket.tenSecondsOrMore],
      2,
    );
  });

  test('foreign handles and failing clocks cannot affect production', () {
    final first = AvatarSelectionObservability(
      monotonicClock: () => throw StateError('raw-error-must-not-escape'),
    );
    final second = AvatarSelectionObservability();
    final observation = first.begin(
      AvatarSelectionObservedOperation.currentRead,
    );

    expect(() => second.retry(observation), returnsNormally);
    expect(
      () => second.end(
        observation,
        outcome: AvatarSelectionObservedOutcome.failed,
      ),
      returnsNormally,
    );
    expect(second.snapshot.inFlight, 0);
    expect(
      second.snapshot.outcomeCounts[AvatarSelectionObservedOutcome.failed],
      0,
    );

    expect(
      () => first.end(
        observation,
        outcome: AvatarSelectionObservedOutcome.succeeded,
      ),
      returnsNormally,
    );
    expect(first.snapshot.inFlight, 0);
    expect(
      first.snapshot.latencyBuckets[AvatarSelectionLatencyBucket.under100ms],
      1,
    );
  });

  test('invalid current versions fail closed without throwing', () {
    final observability = AvatarSelectionObservability();

    observability.observeCurrent(proven: true, version: -1);
    expect(observability.snapshot.currentProven, isFalse);
    expect(observability.snapshot.currentVersion, isNull);

    observability.observeCurrent(
      proven: true,
      version: maxAvatarSelectionJsonSafeInteger + 1,
    );
    expect(observability.snapshot.currentProven, isFalse);
    expect(observability.snapshot.currentVersion, isNull);
  });

  test('latency boundaries use a fixed five-bucket schema', () {
    final observability = AvatarSelectionObservability();
    for (final latency in <Duration>[
      const Duration(milliseconds: -1),
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 500),
      const Duration(seconds: 2),
      const Duration(seconds: 10),
    ]) {
      observability.record(
        operation: AvatarSelectionObservedOperation.currentRead,
        outcome: AvatarSelectionObservedOutcome.succeeded,
        latency: latency,
        retries: -1,
      );
    }

    final snapshot = observability.snapshot;
    expect(snapshot.latencyBuckets, <AvatarSelectionLatencyBucket, int>{
      AvatarSelectionLatencyBucket.under100ms: 1,
      AvatarSelectionLatencyBucket.under500ms: 1,
      AvatarSelectionLatencyBucket.under2s: 1,
      AvatarSelectionLatencyBucket.under10s: 1,
      AvatarSelectionLatencyBucket.tenSecondsOrMore: 1,
    });
    expect(snapshot.retryTotal, 0);
    expect(
      () =>
          snapshot.latencyBuckets[AvatarSelectionLatencyBucket.under100ms] = 2,
      throwsUnsupportedError,
    );
  });

  test('outbox observation exposes only stage and resolution', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'avatar-observability-privacy.db',
    );
    final storageScopes = AccountStorageScopeService();
    final scope = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'raw-account-secret-sentinel',
    );
    final mount = storageScopes.mount(scope);
    final agentScope = scope.agent('raw-agent-secret-sentinel');
    final outbox = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: mount,
      agentScope: agentScope,
      storageScopes: storageScopes,
    );
    addTearDown(() async {
      await outbox.deactivateAndDrain();
      if (storageScopes.isCurrent(mount)) storageScopes.unmount(mount);
      await database.close();
    });
    final entry = await outbox.prepare(
      request: AvatarSelectionCommitRequest(
        agentId: agentScope.agentId,
        modelId: 987654321,
        expectedVersion: 0,
        idempotencyKey: 'raw_request_token_secret_123456',
        assetOptions: const AvatarSelectionAssetOptions.none(),
      ),
      previousSelection: AvatarSelectionState(
        selectionId: null,
        agentId: agentScope.agentId,
        modelId: null,
        version: 0,
        selectedAt: null,
      ),
      compensationKey: 'raw_compensation_token_secret_123456',
    );
    var wallNow = entry.createdAt.add(const Duration(seconds: 30));
    final observability = AvatarSelectionObservability(
      wallClock: () => wallNow,
    );

    observability.observeOutbox(entry);
    final snapshot = observability.snapshot;
    expect(snapshot.outboxObserved, isTrue);
    expect(snapshot.outboxPresent, isTrue);
    expect(snapshot.outboxStage, AvatarSelectionOutboxStage.prepared);
    expect(
      snapshot.outboxResolution,
      AvatarSelectionOutboxResolution.rollForward,
    );
    expect(snapshot.outboxAgeBucket, AvatarSelectionOutboxAgeBucket.under1m);

    wallNow = entry.createdAt.add(const Duration(days: 2));
    expect(
      observability.snapshot.outboxAgeBucket,
      AvatarSelectionOutboxAgeBucket.dayOrMore,
    );

    final exported = snapshot.toMetrics().toString().toLowerCase();
    for (final forbidden in <String>[
      'raw-account-secret-sentinel',
      'raw-agent-secret-sentinel',
      '987654321',
      'raw_request_token_secret_123456',
      'raw_compensation_token_secret_123456',
      scope.accountDigest.toLowerCase(),
      agentScope.agentDigest.toLowerCase(),
      'idempotency',
      'request',
      'model',
      'url',
      'path',
      'token',
      'error',
    ]) {
      expect(exported, isNot(contains(forbidden)));
    }

    observability.observeOutbox(null);
    expect(observability.snapshot.outboxObserved, isTrue);
    expect(observability.snapshot.outboxPresent, isFalse);
    expect(observability.snapshot.outboxStage, isNull);
    expect(observability.snapshot.outboxResolution, isNull);
    expect(observability.snapshot.outboxAgeBucket, isNull);
  });
}
