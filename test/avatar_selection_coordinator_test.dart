import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_observability.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'asset version rejection restores the proven avatar and releases the durable obligation',
    () async {
      final harness = await _Harness.create(
        'coordinator-asset-pin-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(harness.close);
      final previous = _snapshot(modelId: null, version: 0);
      var restored = 0;
      final transport = _FakeTransport(
        currentHandler: (_, _) async => previous,
        commitHandler: (_) async =>
            throw const AvatarSelectionValidationException(
              code: 'AVATAR_ASSET_VERSION_CHANGED',
              statusCode: 409,
            ),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys('asset_set_pin_01', 'asset_comp_pin_01'),
      );
      addTearDown(coordinator.deactivateAndDrain);
      await expectLater(
        coordinator.commit(
          modelId: 42,
          assetOptions: const AvatarSelectionAssetOptions.none(),
          expectedAssetVersionDigest: 'a' * 64,
          local: AvatarSelectionLocalPhases(
            restore: (value) async {
              expect(value.selection.version, 0);
              restored++;
            },
          ),
        ),
        throwsA(isA<AvatarSelectionValidationException>()),
      );
      expect(transport.commitRequests, hasLength(1));
      expect(restored, 1);
      expect(await harness.outbox.read(), isNull);
      expect(coordinator.current?.selection.version, 0);
    },
  );
  test(
    'prepare is durable before exact ambiguous replay and receipt before local commit',
    () async {
      final harness = await _Harness.create('coordinator-ordering.db');
      addTearDown(harness.close);
      final events = <String>[];
      final outbox = _RecordingOutbox(harness.outbox, events);
      final previous = _snapshot(modelId: null, version: 0);
      var attempts = 0;
      final transport = _FakeTransport(
        events: events,
        currentHandler: (_, _) async => previous,
        commitHandler: (request) async {
          attempts += 1;
          if (attempts == 1) {
            throw const AvatarSelectionAmbiguousTransportException();
          }
          return _result(request, previous.selection);
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_ordering_1',
          'avatar_comp_ordering_1',
        ),
        retryDelay: (attempt) => events.add('retry:$attempt'),
      );
      addTearDown(coordinator.deactivateAndDrain);
      final publishedVersions = <int>[];
      final subscription = coordinator.snapshots.listen(
        (snapshot) => publishedVersions.add(snapshot.selection.version),
      );
      addTearDown(subscription.cancel);

      final committed = await coordinator.commit(
        modelId: 42,
        expectedAssetVersionDigest: 'a' * 64,
        assetOptions: AvatarSelectionAssetOptions.forPlatform('ios'),
        local: AvatarSelectionLocalPhases(
          preview: () => events.add('local.preview'),
          commit: (_) => events.add('local.commit'),
        ),
      );

      expect(committed.receipt.selection.modelId, 42);
      expect(transport.commitRequests, hasLength(2));
      expect(
        transport.commitRequests.first.expectedAssetVersionDigest,
        'a' * 64,
      );
      expect(
        transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.setReplay,
      );
      expect(
        transport.recoveryClaims.single.ownerGeneration,
        harness.mount.generation,
      );
      expect(
        identical(
          transport.commitRequests.first,
          transport.commitRequests.last,
        ),
        isTrue,
      );
      expect(
        transport.commitRequests.first.toPersistenceJson(),
        transport.commitRequests.last.toPersistenceJson(),
      );
      expect(events, <String>[
        'outbox.inspectForRecovery',
        'transport.get',
        'local.preview',
        'outbox.prepare:start',
        'outbox.prepare:done',
        'transport.post:avatar_set_ordering_1',
        'retry:1',
        'transport.post:avatar_set_ordering_1',
        'outbox.recordApplied:start',
        'outbox.recordApplied:done',
        'local.commit',
        'outbox.completeLocalCommit:start',
        'outbox.completeLocalCommit:done',
      ]);
      expect(await harness.outbox.read(), isNull);
      expect(publishedVersions, <int>[0, 1]);
      final diagnostics = coordinator.observabilitySnapshot;
      expect(diagnostics.currentProven, isTrue);
      expect(diagnostics.currentVersion, 1);
      expect(diagnostics.outboxPresent, isFalse);
      expect(diagnostics.retryTotal, 1);
      expect(diagnostics.retryMax, 1);
      expect(
        diagnostics.operationCounts[AvatarSelectionObservedOperation
            .selectionCommit],
        1,
      );
      expect(
        diagnostics.operationCounts[AvatarSelectionObservedOperation
            .exactReplay],
        1,
      );
    },
  );

  test(
    'initial ambiguous then recovery authorization error stays unresolved',
    () async {
      final harness = await _Harness.create('coordinator-ambiguous-auth.db');
      addTearDown(harness.close);
      var calls = 0;
      final transport = _FakeTransport(
        currentHandler: (_, _) async => _snapshot(modelId: null, version: 0),
        commitHandler: (_) async {
          calls += 1;
          if (calls == 1) {
            throw const AvatarSelectionAmbiguousTransportException();
          }
          throw const AvatarSelectionAuthorizationException(
            code: 'UNAUTHORIZED',
            statusCode: 401,
          );
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_ambiguous_auth_1',
          'avatar_comp_ambiguous_auth_1',
        ),
      );
      addTearDown(coordinator.deactivateAndDrain);

      await expectLater(
        coordinator.commit(
          modelId: 42,
          assetOptions: const AvatarSelectionAssetOptions.none(),
        ),
        throwsA(
          isA<AvatarSelectionAmbiguousTransportException>().having(
            (error) => error.cause,
            'cause',
            isA<AvatarSelectionAuthorizationException>(),
          ),
        ),
      );

      expect(transport.currentCalls, 1);
      expect(transport.commitRequests, hasLength(2));
      expect(
        identical(
          transport.commitRequests.first,
          transport.commitRequests.last,
        ),
        isTrue,
      );
      final retained = await harness.outbox.read();
      expect(retained?.stage, AvatarSelectionOutboxStage.prepared);
      expect(retained?.operationKey, 'avatar_set_ambiguous_auth_1');
      expect(
        retained?.request.toPersistenceJson(),
        transport.commitRequests.first.toPersistenceJson(),
      );
    },
  );

  test(
    'startup prepared replay maps contract unavailable to unresolved without GET',
    () async {
      final harness = await _Harness.create(
        'coordinator-startup-unavailable.db',
      );
      addTearDown(harness.close);
      final request = _request(
        key: 'avatar_set_startup_unavailable_1',
        modelId: 42,
      );
      await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_startup_unavailable_1',
      );
      final transport = _FakeTransport(
        currentHandler: (_, _) async =>
            throw StateError('historical replay must not GET'),
        commitHandler: (_) async =>
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            ),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: () =>
            throw StateError('historical replay must not allocate a key'),
      );
      addTearDown(coordinator.deactivateAndDrain);

      await expectLater(
        coordinator.recover(
          decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
        ),
        throwsA(
          isA<AvatarSelectionAmbiguousTransportException>().having(
            (error) => error.cause,
            'cause',
            isA<AvatarSelectionContractUnavailableException>(),
          ),
        ),
      );

      expect(transport.currentCalls, 0);
      expect(transport.commitRequests, hasLength(1));
      expect(
        transport.commitRequests.single.idempotencyKey,
        request.idempotencyKey,
      );
      expect(
        transport.commitRequests.single.toPersistenceJson(),
        request.toPersistenceJson(),
      );
      final retained = await harness.outbox.read();
      expect(retained?.stage, AvatarSelectionOutboxStage.prepared);
      expect(retained?.request.hasSameSemanticValue(request), isTrue);
    },
  );

  test(
    'recovery without an outbox returns current without invoking local phases',
    () async {
      final harness = await _Harness.create('coordinator-current-only.db');
      addTearDown(harness.close);
      final events = <String>[];
      final authoritative = _snapshot(modelId: 42, version: 3, selectionId: 8);
      final transport = _FakeTransport(
        events: events,
        currentHandler: (_, _) async => authoritative,
        commitHandler: (_) async =>
            throw StateError('current-only recovery must not POST'),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: _RecordingOutbox(harness.outbox, events),
        idempotencyKeyFactory: () =>
            throw StateError('current-only recovery must not allocate a key'),
      );
      addTearDown(coordinator.deactivateAndDrain);

      final recovery = await coordinator.recover(
        decide: (_) {
          events.add('local.decide');
          return AvatarSelectionRecoveryResolution.rollForward;
        },
        local: AvatarSelectionLocalPhases(
          preview: () => events.add('local.preview'),
          commit: (_) => events.add('local.commit'),
          restore: (_) => events.add('local.restore'),
        ),
      );

      expect(
        recovery.outcome,
        AvatarSelectionRecoveryOutcome.reconciledCurrent,
      );
      expect(recovery.current.hasSameSemanticValue(authoritative), isTrue);
      expect(coordinator.current?.hasSameSemanticValue(authoritative), isTrue);
      expect(transport.currentCalls, 1);
      expect(transport.commitRequests, isEmpty);
      expect(events, <String>['outbox.inspectForRecovery', 'transport.get']);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'force refresh bypasses proven cache and serializes behind mutation',
    () async {
      final harness = await _Harness.create('coordinator-force-refresh.db');
      addTearDown(harness.close);
      final postStarted = Completer<void>();
      final releasePost = Completer<void>();
      var authoritative = _snapshot(modelId: null, version: 0);
      final transport = _FakeTransport(
        currentHandler: (_, _) async => authoritative,
        commitHandler: (request) async {
          postStarted.complete();
          await releasePost.future;
          final result = _result(request, authoritative.selection);
          authoritative = AvatarSelectionSnapshot(
            selection: result.receipt.selection,
            asset: result.receipt.asset,
            selectionAvailable: result.receipt.selectionAvailable,
          );
          return result;
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_force_refresh_1',
          'avatar_comp_force_refresh_1',
        ),
      );
      addTearDown(coordinator.deactivateAndDrain);

      final initial = await coordinator.ensureCurrent();
      expect(initial.selection.version, 0);
      expect(transport.currentCalls, 1);

      final mutation = coordinator.commit(
        modelId: 42,
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );
      await postStarted.future;
      final refresh = coordinator.refreshCurrent();
      await Future<void>.delayed(Duration.zero);
      expect(transport.currentCalls, 1);

      releasePost.complete();
      await mutation;
      final refreshed = await refresh;

      expect(refreshed.selection.modelId, 42);
      expect(refreshed.selection.version, 1);
      expect(coordinator.current?.selection.version, 1);
      expect(coordinator.isReady, isTrue);
      expect(transport.currentCalls, 2);
    },
  );

  test('force refresh rejects after the coordinator is sealed', () async {
    final harness = await _Harness.create('coordinator-refresh-sealed.db');
    addTearDown(harness.close);
    final transport = _FakeTransport(
      currentHandler: (_, _) async => _snapshot(modelId: null, version: 0),
      commitHandler: (_) async =>
          throw StateError('sealed refresh must not POST'),
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: harness.outbox,
    );
    final drained = await coordinator.deactivateAndDrain();
    expect(drained.fullyDrained, isTrue);

    await expectLater(
      coordinator.refreshCurrent(),
      throwsA(isA<AvatarSelectionCoordinatorUnavailableException>()),
    );
    expect(transport.currentCalls, 0);
  });

  test('sealed committed evidence durably reconstructs retirement', () async {
    final harness = await _Harness.create('coordinator-retirement.db');
    addTearDown(harness.close);
    final events = <String>[];
    final previous = _snapshot(modelId: 10, version: 1, selectionId: 6);
    late AvatarSelectionState applied;
    final transport = _FakeTransport(
      events: events,
      currentHandler: (_, _) async => previous,
      commitHandler: (request) async {
        if (request.idempotencyKey == 'avatar_set_retire_1') {
          final result = _result(request, previous.selection);
          applied = result.receipt.selection;
          return result;
        }
        expect(request.idempotencyKey, 'avatar_comp_retire_1');
        expect(request.modelId, 10);
        expect(request.expectedVersion, 2);
        return _result(request, applied);
      },
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: _RecordingOutbox(harness.outbox, events),
      idempotencyKeyFactory: _keys(
        'avatar_set_retire_1',
        'avatar_comp_retire_1',
      ),
    );
    addTearDown(coordinator.deactivateAndDrain);

    final committed = await coordinator.commit(
      modelId: 20,
      assetOptions: const AvatarSelectionAssetOptions.none(),
    );
    expect(await harness.outbox.read(), isNull);
    final beforeRetire = events.length;

    final retired = await coordinator.retireCommittedSelection(
      committed,
      local: AvatarSelectionLocalPhases(
        preview: () => events.add('local.retireFallback'),
      ),
    );

    expect(retired.outcome, AvatarSelectionRecoveryOutcome.compensated);
    expect(retired.current.selection.modelId, 10);
    expect(transport.currentCalls, 1);
    expect(transport.commitRequests, hasLength(2));
    expect(
      transport.recoveryClaims.single.operation,
      AvatarSelectionRecoveryOperation.compensation,
    );
    expect(
      transport.recoveryClaims.single.agentScopeDigest,
      harness.agentScope.agentDigest,
    );
    expect(
      events.sublist(beforeRetire),
      containsAllInOrder(<String>[
        'outbox.inspectForRecovery',
        'outbox.prepare:done',
        'outbox.recordApplied:done',
        'outbox.requestCompensation:done',
        'local.retireFallback',
        'outbox.beginCompensation:done',
        'transport.post:avatar_comp_retire_1',
      ]),
    );
    expect(await harness.outbox.read(), isNull);
    await expectLater(
      coordinator.retireCommittedSelection(committed),
      throwsStateError,
    );
  });

  test(
    'mutations are serialized and the second uses the first version',
    () async {
      final harness = await _Harness.create('coordinator-serialization.db');
      addTearDown(harness.close);
      final events = <String>[];
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var server = _snapshot(modelId: null, version: 0);
      var call = 0;
      final transport = _FakeTransport(
        events: events,
        currentHandler: (_, _) async => server,
        commitHandler: (request) async {
          call += 1;
          if (call == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          final result = _result(request, server.selection);
          server = _snapshotFromReceipt(result.receipt);
          return result;
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_serial_one_1',
          'avatar_comp_serial_one_1',
          'avatar_set_serial_two_1',
          'avatar_comp_serial_two_1',
        ),
      );
      addTearDown(coordinator.deactivateAndDrain);

      final first = coordinator.commit(
        modelId: 41,
        assetOptions: const AvatarSelectionAssetOptions.none(),
        local: AvatarSelectionLocalPhases(
          preview: () => events.add('preview:first'),
        ),
      );
      await firstStarted.future;
      final second = coordinator.commit(
        modelId: 42,
        assetOptions: const AvatarSelectionAssetOptions.none(),
        local: AvatarSelectionLocalPhases(
          preview: () => events.add('preview:second'),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(transport.commitRequests, hasLength(1));
      expect(events, isNot(contains('preview:second')));
      releaseFirst.complete();
      await Future.wait<AvatarSelectionCommittedSelection>(
        <Future<AvatarSelectionCommittedSelection>>[first, second],
      );

      expect(transport.commitRequests, hasLength(2));
      expect(transport.commitRequests[0].expectedVersion, 0);
      expect(transport.commitRequests[1].expectedVersion, 1);
      expect(transport.currentCalls, 1);
      expect(
        events.indexOf('preview:first'),
        lessThan(events.indexOf('preview:second')),
      );
    },
  );

  test('local commit failure compensates with the fixed prior tuple', () async {
    final harness = await _Harness.create('coordinator-compensation.db');
    addTearDown(harness.close);
    final previous = _snapshot(modelId: 10, version: 1, selectionId: 7);
    final restored = <AvatarSelectionSnapshot>[];
    final transport = _FakeTransport(
      currentHandler: (_, _) async => previous,
      commitHandler: (request) async {
        if (request.idempotencyKey == 'avatar_set_compensate_1') {
          return _result(request, previous.selection);
        }
        expect(request.idempotencyKey, 'avatar_comp_compensate_1');
        expect(request.modelId, 10);
        expect(request.expectedVersion, 2);
        return _result(
          request,
          _state(modelId: 20, version: 2, selectionId: 7),
        );
      },
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: harness.outbox,
      idempotencyKeyFactory: _keys(
        'avatar_set_compensate_1',
        'avatar_comp_compensate_1',
      ),
    );
    addTearDown(coordinator.deactivateAndDrain);

    await expectLater(
      coordinator.commit(
        modelId: 20,
        assetOptions: const AvatarSelectionAssetOptions.none(),
        local: AvatarSelectionLocalPhases(
          commit: (_) => throw StateError('local write failed'),
          restore: restored.add,
        ),
      ),
      throwsA(
        isA<AvatarSelectionLocalCommitCompensatedException>().having(
          (error) => error.compensationReceipt.idempotencyKey,
          'compensation key',
          'avatar_comp_compensate_1',
        ),
      ),
    );

    expect(transport.commitRequests, hasLength(2));
    expect(restored, hasLength(2));
    expect(restored.last.selection.modelId, 10);
    expect(restored.last.selection.version, 3);
    expect(await harness.outbox.read(), isNull);
    final diagnostics = coordinator.observabilitySnapshot;
    expect(diagnostics.outboxPresent, isFalse);
    expect(
      diagnostics.operationCounts[AvatarSelectionObservedOperation
          .compensation],
      1,
    );
    expect(
      diagnostics.outcomeCounts[AvatarSelectionObservedOutcome.compensated],
      2,
    );
  });

  test(
    'compensation version conflict is superseded without version raising',
    () async {
      final harness = await _Harness.create('coordinator-comp-conflict.db');
      addTearDown(harness.close);
      final previous = _snapshot(modelId: 10, version: 1, selectionId: 8);
      final newer = _snapshot(modelId: 99, version: 3, selectionId: 8);
      final restored = <AvatarSelectionSnapshot>[];
      final transport = _FakeTransport(
        currentHandler: (_, _) async => previous,
        commitHandler: (request) async {
          if (request.idempotencyKey == 'avatar_set_comp_conflict_1') {
            return _result(request, previous.selection);
          }
          throw AvatarSelectionVersionChangedException(currentSelection: newer);
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_comp_conflict_1',
          'avatar_comp_comp_conflict_1',
        ),
      );
      addTearDown(coordinator.deactivateAndDrain);

      await expectLater(
        coordinator.commit(
          modelId: 20,
          assetOptions: const AvatarSelectionAssetOptions.none(),
          local: AvatarSelectionLocalPhases(
            commit: (_) => throw StateError('local write failed'),
            restore: restored.add,
          ),
        ),
        throwsA(isA<AvatarSelectionCompensationSupersededException>()),
      );

      expect(transport.commitRequests, hasLength(2));
      expect(transport.commitRequests.last.expectedVersion, 2);
      expect(transport.commitRequests.last.modelId, 10);
      expect(restored, hasLength(2));
      expect(restored.last.hasSameSemanticValue(newer), isTrue);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test('ambiguous compensation retains one exact durable obligation', () async {
    final harness = await _Harness.create('coordinator-comp-ambiguous.db');
    addTearDown(harness.close);
    final previous = _snapshot(modelId: 10, version: 1, selectionId: 11);
    final transport = _FakeTransport(
      currentHandler: (_, _) async => previous,
      commitHandler: (request) async {
        if (request.idempotencyKey == 'avatar_set_comp_ambiguous_1') {
          return _result(request, previous.selection);
        }
        throw const AvatarSelectionAmbiguousTransportException();
      },
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: harness.outbox,
      idempotencyKeyFactory: _keys(
        'avatar_set_comp_ambiguous_1',
        'avatar_comp_comp_ambiguous_1',
      ),
      maxAmbiguousAttempts: 2,
    );
    addTearDown(coordinator.deactivateAndDrain);

    await expectLater(
      coordinator.commit(
        modelId: 20,
        assetOptions: const AvatarSelectionAssetOptions.none(),
        local: AvatarSelectionLocalPhases(
          commit: (_) => throw StateError('local write failed'),
        ),
      ),
      throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
    );

    expect(transport.commitRequests, hasLength(3));
    expect(
      identical(transport.commitRequests[1], transport.commitRequests[2]),
      isTrue,
    );
    expect(
      transport.commitRequests[1].toPersistenceJson(),
      transport.commitRequests[2].toPersistenceJson(),
    );
    final durable = await harness.outbox.read();
    expect(durable?.stage, AvatarSelectionOutboxStage.compensating);
    expect(durable?.compensationKey, 'avatar_comp_comp_ambiguous_1');
    expect(coordinator.isReady, isFalse);
  });

  test(
    'set version conflict records superseded before restoring current',
    () async {
      final harness = await _Harness.create('coordinator-set-conflict.db');
      addTearDown(harness.close);
      final events = <String>[];
      final previous = _snapshot(modelId: 10, version: 1, selectionId: 9);
      final newer = _snapshot(modelId: 99, version: 2, selectionId: 9);
      final transport = _FakeTransport(
        events: events,
        currentHandler: (_, _) async => previous,
        commitHandler: (_) async =>
            throw AvatarSelectionVersionChangedException(
              currentSelection: newer,
            ),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: _RecordingOutbox(harness.outbox, events),
        idempotencyKeyFactory: _keys(
          'avatar_set_conflict_1',
          'avatar_comp_conflict_1',
        ),
      );
      addTearDown(coordinator.deactivateAndDrain);

      await expectLater(
        coordinator.commit(
          modelId: 20,
          assetOptions: const AvatarSelectionAssetOptions.none(),
          local: AvatarSelectionLocalPhases(
            restore: (_) => events.add('local.restore'),
          ),
        ),
        throwsA(isA<AvatarSelectionVersionChangedException>()),
      );

      expect(transport.commitRequests.single.expectedVersion, 1);
      expect(
        events.indexOf('outbox.markSuperseded:done'),
        lessThan(events.indexOf('local.restore')),
      );
      expect(
        events.indexOf('local.restore'),
        lessThan(events.indexOf('outbox.completeSuperseded:start')),
      );
      expect(coordinator.current?.hasSameSemanticValue(newer), isTrue);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'prepared recovery replays persisted tuple then verifies current without a new key',
    () async {
      final harness = await _Harness.create('coordinator-replay.db');
      addTearDown(harness.close);
      final firstTransport = _FakeTransport(
        currentHandler: (_, _) async => _snapshot(modelId: null, version: 0),
        commitHandler: (_) async =>
            throw const AvatarSelectionAmbiguousTransportException(),
      );
      final firstCoordinator = AvatarSelectionCoordinator(
        transport: firstTransport,
        recoveryTransport: firstTransport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_recovery_1',
          'avatar_comp_recovery_1',
        ),
        maxAmbiguousAttempts: 1,
      );
      await expectLater(
        firstCoordinator.commit(
          modelId: 42,
          assetOptions: AvatarSelectionAssetOptions.forPlatform('ios'),
        ),
        throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
      );
      final original = firstTransport.commitRequests.single;
      await expectLater(
        firstCoordinator.commit(
          modelId: 43,
          assetOptions: const AvatarSelectionAssetOptions.none(),
        ),
        throwsA(isA<AvatarSelectionOutstandingObligationException>()),
      );
      await expectLater(
        firstCoordinator.ensureCurrent(),
        throwsA(isA<AvatarSelectionOutstandingObligationException>()),
      );
      expect(firstTransport.currentCalls, 1);
      expect(firstTransport.commitRequests, hasLength(1));
      await firstCoordinator.deactivateAndDrain();

      final reconstructed = SembastAvatarSelectionOutbox(
        accountDatabase: harness.database,
        mount: harness.mount,
        agentScope: harness.agentScope,
        storageScopes: harness.storageScopes,
      );
      addTearDown(reconstructed.deactivateAndDrain);
      final secondTransport = _FakeTransport(
        currentHandler: (_, _) async => _snapshot(modelId: 42, version: 1),
        commitHandler: (request) async => _result(request, _emptyState()),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: secondTransport,
        recoveryTransport: secondTransport,
        outbox: reconstructed,
        idempotencyKeyFactory: () =>
            throw StateError('recovery must not allocate a key'),
      );
      addTearDown(coordinator.deactivateAndDrain);

      final recovery = await coordinator.recover(
        decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
      );

      expect(recovery.outcome, AvatarSelectionRecoveryOutcome.rolledForward);
      expect(secondTransport.currentCalls, 1);
      expect(
        secondTransport.commitRequests.single.idempotencyKey,
        original.idempotencyKey,
      );
      expect(
        secondTransport.commitRequests.single.toPersistenceJson(),
        original.toPersistenceJson(),
      );
      expect(await reconstructed.read(), isNull);
    },
  );

  test(
    'applied recovery supersedes stale receipt with forced current snapshot',
    () async {
      final harness = await _Harness.create('coordinator-stale-applied.db');
      addTearDown(harness.close);
      final request = _request(key: 'avatar_set_stale_applied_1', modelId: 42);
      var entry = await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_stale_applied_1',
      );
      entry = await harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: _result(request, _emptyState()).receipt,
      );
      final newer = _snapshot(modelId: 99, version: 2);
      final restored = <AvatarSelectionSnapshot>[];
      var decideCalls = 0;
      final transport = _FakeTransport(
        currentHandler: (_, _) async => newer,
        commitHandler: (_) async =>
            throw StateError('stale applied recovery must not POST'),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: () =>
            throw StateError('recovery must not allocate a key'),
      );
      addTearDown(coordinator.deactivateAndDrain);

      final recovery = await coordinator.recover(
        decide: (_) {
          decideCalls += 1;
          return AvatarSelectionRecoveryResolution.rollForward;
        },
        local: AvatarSelectionLocalPhases(restore: restored.add),
      );

      expect(recovery.outcome, AvatarSelectionRecoveryOutcome.superseded);
      expect(recovery.current.hasSameSemanticValue(newer), isTrue);
      expect(restored, hasLength(1));
      expect(restored.single.hasSameSemanticValue(newer), isTrue);
      expect(decideCalls, 0);
      expect(transport.currentCalls, 1);
      expect(transport.commitRequests, isEmpty);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test('recovery compensates applied, needed, and in-flight stages', () async {
    for (final stage in <AvatarSelectionOutboxStage>[
      AvatarSelectionOutboxStage.applied,
      AvatarSelectionOutboxStage.compensateNeeded,
      AvatarSelectionOutboxStage.compensating,
    ]) {
      final harness = await _Harness.create(
        'coordinator-recover-${stage.name}.db',
      );
      final request = _request(
        key: 'avatar_set_recover_${stage.name}_1',
        modelId: 42,
      );
      var entry = await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_recover_${stage.name}_1',
      );
      entry = await harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: _result(request, _emptyState()).receipt,
      );
      if (stage != AvatarSelectionOutboxStage.applied) {
        entry = await harness.outbox.requestCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
      }
      if (stage == AvatarSelectionOutboxStage.compensating) {
        entry = await harness.outbox.beginCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
        );
      }
      final transport = _FakeTransport(
        currentHandler: (_, _) async {
          if (stage == AvatarSelectionOutboxStage.applied) {
            return _snapshot(modelId: 42, version: 1);
          }
          throw StateError('durable compensation recovery must not GET');
        },
        commitHandler: (compensation) async => _result(
          compensation,
          _state(modelId: 42, version: 1, selectionId: 10),
        ),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: () =>
            throw StateError('recovery must not allocate a key'),
      );

      final recovery = await coordinator.recover(
        decide: (_) => AvatarSelectionRecoveryResolution.compensate,
      );

      expect(recovery.outcome, AvatarSelectionRecoveryOutcome.compensated);
      expect(
        transport.currentCalls,
        stage == AvatarSelectionOutboxStage.applied ? 1 : 0,
      );
      expect(transport.commitRequests.single.modelId, isNull);
      expect(transport.commitRequests.single.expectedVersion, 1);
      expect(
        transport.commitRequests.single.idempotencyKey,
        'avatar_comp_recover_${stage.name}_1',
      );
      expect(await harness.outbox.read(), isNull);
      await coordinator.deactivateAndDrain();
      await harness.close();
    }
  });

  test(
    'same-account recovery explicitly adopts the historical generation',
    () async {
      final harness = await _Harness.create('coordinator-adoption.db');
      final request = _request(key: 'avatar_set_adopt_1', modelId: 42);
      await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_adopt_1',
      );
      await harness.outbox.deactivateAndDrain();
      harness.storageScopes.unmount(harness.mount);
      final nextMount = harness.storageScopes.mount(harness.scope);
      final events = <String>[];
      final nextOutbox = _RecordingOutbox(
        SembastAvatarSelectionOutbox(
          accountDatabase: harness.database,
          mount: nextMount,
          agentScope: harness.agentScope,
          storageScopes: harness.storageScopes,
        ),
        events,
      );
      final transport = _FakeTransport(
        currentHandler: (_, _) async => _snapshot(modelId: 42, version: 1),
        commitHandler: (replayed) async => _result(replayed, _emptyState()),
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: nextOutbox,
        idempotencyKeyFactory: () =>
            throw StateError('recovery must not allocate a key'),
      );

      final recovery = await coordinator.recover(
        decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
      );

      expect(recovery.outcome, AvatarSelectionRecoveryOutcome.rolledForward);
      expect(
        events,
        containsAllInOrder(<String>[
          'outbox.inspectForRecovery',
          'outbox.adoptForRecovery:start',
          'outbox.adoptForRecovery:done',
          'outbox.recordApplied:start',
        ]),
      );
      await coordinator.deactivateAndDrain();
      harness.storageScopes.unmount(nextMount);
      await harness.database.close();
    },
  );

  test(
    'bounded drain seals mutations and preserves a late prepared obligation',
    () async {
      final harness = await _Harness.create('coordinator-drain.db');
      final postStarted = Completer<void>();
      final releasePost = Completer<void>();
      final transport = _FakeTransport(
        currentHandler: (_, _) async => _snapshot(modelId: null, version: 0),
        commitHandler: (request) async {
          postStarted.complete();
          await releasePost.future;
          return _result(request, _emptyState());
        },
      );
      final coordinator = AvatarSelectionCoordinator(
        transport: transport,
        recoveryTransport: transport,
        outbox: harness.outbox,
        idempotencyKeyFactory: _keys(
          'avatar_set_drain_1',
          'avatar_comp_drain_1',
        ),
      );
      final pending = coordinator.commit(
        modelId: 42,
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );
      await postStarted.future;

      final drained = await coordinator.deactivateAndDrain(
        timeout: const Duration(milliseconds: 20),
      );
      expect(drained.fullyDrained, isFalse);
      expect(
        coordinator.observabilitySnapshot.lifecycle,
        AvatarSelectionObservabilityLifecycle.sealing,
      );
      expect(
        coordinator
            .observabilitySnapshot
            .outcomeCounts[AvatarSelectionObservedOutcome.timedOut],
        1,
      );
      await expectLater(
        coordinator.commit(
          modelId: 43,
          assetOptions: const AvatarSelectionAssetOptions.none(),
        ),
        throwsA(isA<AvatarSelectionCoordinatorUnavailableException>()),
      );

      releasePost.complete();
      await expectLater(
        pending,
        throwsA(isA<AvatarSelectionOutboxUnavailableException>()),
      );
      final retryDrain = await coordinator.deactivateAndDrain(
        timeout: const Duration(seconds: 1),
      );
      expect(retryDrain.fullyDrained, isTrue);
      expect(
        coordinator.observabilitySnapshot.lifecycle,
        AvatarSelectionObservabilityLifecycle.retired,
      );
      final inspector = SembastAvatarSelectionOutbox(
        accountDatabase: harness.database,
        mount: harness.mount,
        agentScope: harness.agentScope,
        storageScopes: harness.storageScopes,
      );
      expect(
        (await inspector.inspectForRecovery())?.stage,
        AvatarSelectionOutboxStage.prepared,
      );
      await inspector.deactivateAndDrain();
      harness.storageScopes.unmount(harness.mount);
      await harness.database.close();
    },
  );
}

final class _FakeTransport
    implements AvatarSelectionTransport, AvatarSelectionRecoveryTransport {
  _FakeTransport({
    required this.currentHandler,
    required this.commitHandler,
    List<String>? events,
  }) : events = events ?? <String>[];

  final Future<AvatarSelectionSnapshot> Function(
    String agentId,
    AvatarSelectionAssetOptions assetOptions,
  )
  currentHandler;
  final Future<AvatarSelectionCommitResult> Function(
    AvatarSelectionCommitRequest request,
  )
  commitHandler;
  final List<String> events;
  final List<AvatarSelectionCommitRequest> commitRequests =
      <AvatarSelectionCommitRequest>[];
  final List<AvatarSelectionRecoveryClaim> recoveryClaims =
      <AvatarSelectionRecoveryClaim>[];
  int currentCalls = 0;

  @override
  Future<AvatarSelectionSnapshot> current({
    required String agentId,
    required AvatarSelectionAssetOptions assetOptions,
  }) async {
    currentCalls += 1;
    events.add('transport.get');
    return currentHandler(agentId, assetOptions);
  }

  @override
  Future<AvatarSelectionCommitResult> commit(
    AvatarSelectionCommitRequest request,
  ) async {
    commitRequests.add(request);
    events.add('transport.post:${request.idempotencyKey}');
    return commitHandler(request);
  }

  @override
  Future<AvatarSelectionCommitResult> replay(
    AvatarSelectionRecoveryClaim claim,
  ) async {
    recoveryClaims.add(claim);
    commitRequests.add(claim.request);
    events.add('transport.post:${claim.request.idempotencyKey}');
    return commitHandler(claim.request);
  }
}

final class _RecordingOutbox implements AvatarSelectionOutbox {
  _RecordingOutbox(this.delegate, this.events);

  final AvatarSelectionOutbox delegate;
  final List<String> events;

  @override
  AgentStorageScope get agentScope => delegate.agentScope;

  @override
  int get ownerGeneration => delegate.ownerGeneration;

  Future<T> _record<T>(String name, Future<T> Function() operation) async {
    events.add('outbox.$name:start');
    final result = await operation();
    events.add('outbox.$name:done');
    return result;
  }

  @override
  Future<AvatarSelectionOutboxEntry?> read() => delegate.read();

  @override
  Future<AvatarSelectionOutboxEntry?> inspectForRecovery() async {
    events.add('outbox.inspectForRecovery');
    return delegate.inspectForRecovery();
  }

  @override
  Future<AvatarSelectionOutboxEntry> adoptForRecovery({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'adoptForRecovery',
    () => delegate.adoptForRecovery(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<AvatarSelectionOutboxEntry> prepare({
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionState previousSelection,
    required String compensationKey,
  }) => _record(
    'prepare',
    () => delegate.prepare(
      request: request,
      previousSelection: previousSelection,
      compensationKey: compensationKey,
    ),
  );

  @override
  Future<AvatarSelectionOutboxEntry> requestCompensation({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'requestCompensation',
    () => delegate.requestCompensation(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<AvatarSelectionOutboxEntry> recordApplied({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  }) => _record(
    'recordApplied',
    () => delegate.recordApplied(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
      receipt: receipt,
    ),
  );

  @override
  Future<AvatarSelectionOutboxEntry> beginCompensation({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'beginCompensation',
    () => delegate.beginCompensation(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<AvatarSelectionOutboxEntry> markSuperseded({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionSupersededReason reason,
  }) => _record(
    'markSuperseded',
    () => delegate.markSuperseded(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
      reason: reason,
    ),
  );

  @override
  Future<void> discardDefinitelyUncommitted({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'discardDefinitelyUncommitted',
    () => delegate.discardDefinitelyUncommitted(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<void> completeLocalCommit({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'completeLocalCommit',
    () => delegate.completeLocalCommit(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<void> completeCompensation({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  }) => _record(
    'completeCompensation',
    () => delegate.completeCompensation(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
      receipt: receipt,
    ),
  );

  @override
  Future<void> completeSuperseded({
    required String operationKey,
    required int expectedRevision,
  }) => _record(
    'completeSuperseded',
    () => delegate.completeSuperseded(
      operationKey: operationKey,
      expectedRevision: expectedRevision,
    ),
  );

  @override
  Future<void> deactivateAndDrain() => delegate.deactivateAndDrain();
}

final class _Harness {
  _Harness({
    required this.database,
    required this.storageScopes,
    required this.scope,
    required this.mount,
    required this.agentScope,
    required this.outbox,
  });

  static Future<_Harness> create(String path) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    final storageScopes = AccountStorageScopeService();
    final scope = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'avatar-selection-account',
    );
    final mount = storageScopes.mount(scope);
    final agentScope = scope.agent('self');
    final outbox = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: mount,
      agentScope: agentScope,
      storageScopes: storageScopes,
    );
    return _Harness(
      database: database,
      storageScopes: storageScopes,
      scope: scope,
      mount: mount,
      agentScope: agentScope,
      outbox: outbox,
    );
  }

  final DBService database;
  final AccountStorageScopeService storageScopes;
  final AccountStorageScope scope;
  final AccountStorageScopeMount mount;
  final AgentStorageScope agentScope;
  final SembastAvatarSelectionOutbox outbox;

  Future<void> close() async {
    await outbox.deactivateAndDrain();
    if (storageScopes.isCurrent(mount)) storageScopes.unmount(mount);
    await database.close();
  }
}

String Function() _keys(
  String first,
  String second, [
  String? third,
  String? fourth,
]) {
  final values = Queue<String>.of(<String>[first, second, ?third, ?fourth]);
  return () => values.removeFirst();
}

AvatarSelectionCommitRequest _request({
  required String key,
  required int? modelId,
  int expectedVersion = 0,
}) => AvatarSelectionCommitRequest(
  agentId: 'self',
  modelId: modelId,
  expectedVersion: expectedVersion,
  idempotencyKey: key,
  assetOptions: const AvatarSelectionAssetOptions.none(),
);

AvatarSelectionState _emptyState() => AvatarSelectionState(
  selectionId: null,
  agentId: 'self',
  modelId: null,
  version: 0,
  selectedAt: null,
);

AvatarSelectionState _state({
  required int? modelId,
  required int version,
  required int selectionId,
}) => AvatarSelectionState(
  selectionId: selectionId,
  agentId: 'self',
  modelId: modelId,
  version: version,
  selectedAt: DateTime.utc(2026, 9, 2, 8, version),
);

AvatarSelectionSnapshot _snapshot({
  required int? modelId,
  required int version,
  int? selectionId,
}) {
  final selection = version == 0
      ? _emptyState()
      : _state(
          modelId: modelId,
          version: version,
          selectionId: selectionId ?? 10,
        );
  return AvatarSelectionSnapshot(
    selection: selection,
    asset: _asset(modelId),
    selectionAvailable: true,
  );
}

AvatarSelectionSnapshot _snapshotFromReceipt(AvatarSelectionReceipt receipt) =>
    AvatarSelectionSnapshot(
      selection: receipt.selection,
      asset: receipt.asset,
      selectionAvailable: receipt.selectionAvailable,
    );

AvatarSelectionCommitResult _result(
  AvatarSelectionCommitRequest request,
  AvatarSelectionState previous,
) {
  final selection = _state(
    modelId: request.modelId,
    version: previous.version + 1,
    selectionId: previous.selectionId ?? 10,
  );
  return AvatarSelectionCommitResult(
    receipt: AvatarSelectionReceipt(
      idempotencyKey: request.idempotencyKey,
      previousSelection: previous,
      selection: selection,
      asset: _asset(request.modelId),
      selectionAvailable: true,
    ),
    replayed: false,
    request: request,
  );
}

AvatarSelectionAssetDescriptor _asset(int? modelId) {
  final id = modelId ?? 1;
  final bundled = modelId == null;
  return AvatarSelectionAssetDescriptor(
    id: id,
    modelKey: bundled ? 'masso.bundled.agent' : 'model-$id',
    displayName: bundled ? 'Maaso Agent' : 'Model $id',
    modelSource: bundled ? 'bundled' : 'reviewed',
    assetUrl: bundled
        ? 'unity://masso/avatar_agent'
        : 'https://cdn.example.com/model-$id.glb',
    assetSha256: bundled
        ? '82e306d47cd720b6ba121bfab08f07de5cb50e8046e34bd52d959b55012240cd'
        : List<String>.filled(64, 'a').join(),
    compatibility: const <String, Object?>{},
  );
}
