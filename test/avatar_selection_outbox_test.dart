import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'prepared record reconstructs the exact platform request tuple',
    () async {
      final harness = await _Harness.create('outbox-reconstruct.db');
      addTearDown(harness.close);
      final request = _request(
        key: 'avatar_set_reconstruct_1',
        modelId: 42,
        assetOptions: AvatarSelectionAssetOptions.forPlatform('ios'),
      );

      final prepared = await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_reconstruct_1',
      );
      final reconstructed = SembastAvatarSelectionOutbox(
        accountDatabase: harness.database,
        mount: harness.mount,
        agentScope: harness.agentScope,
        storageScopes: harness.storageScopes,
      );
      final restored = await reconstructed.read();

      expect(restored?.stage, AvatarSelectionOutboxStage.prepared);
      expect(restored?.recordRevision, 1);
      expect(restored?.operationKey, request.idempotencyKey);
      expect(restored?.request.hasSameSemanticValue(request), isTrue);
      expect(restored?.request.assetOptions.platformAssets, isTrue);
      expect(restored?.request.assetOptions.platform, 'ios');
      expect(restored?.previousSelection.modelId, isNull);
      expect(prepared.toStorageJson()['request'], request.toPersistenceJson());
      await reconstructed.deactivateAndDrain();
    },
  );

  test(
    'explicit-null target survives persistence without becoming missing',
    () async {
      final harness = await _Harness.create('outbox-null.db');
      addTearDown(harness.close);
      final previous = _state(modelId: 42, version: 4, selectionId: 9);
      final request = _request(
        key: 'avatar_set_clear_1',
        modelId: null,
        expectedVersion: 4,
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );

      await harness.outbox.prepare(
        request: request,
        previousSelection: previous,
        compensationKey: 'avatar_comp_clear_1',
      );
      final restored = await harness.outbox.read();

      expect(restored?.request.modelId, isNull);
      expect(
        (restored?.request.toPersistenceJson() ?? const <String, Object?>{}),
        containsPair('modelId', null),
      );
      expect(restored?.request.assetOptions.platformAssets, isFalse);
      expect(restored?.request.assetOptions.platform, isNull);
    },
  );

  test('concurrent different prepares admit exactly one operation', () async {
    final harness = await _Harness.create('outbox-prepare-race.db');
    addTearDown(harness.close);

    Future<bool> attempt(String suffix) async {
      try {
        await harness.outbox.prepare(
          request: _request(
            key: 'avatar_set_race_$suffix',
            modelId: suffix == 'one' ? 41 : 42,
          ),
          previousSelection: _emptyState(),
          compensationKey: 'avatar_comp_race_$suffix',
        );
        return true;
      } on AvatarSelectionOutboxConflictException {
        return false;
      }
    }

    final results = await Future.wait<bool>(<Future<bool>>[
      attempt('one'),
      attempt('two'),
    ]);
    expect(results.where((value) => value), hasLength(1));
    expect(
      (await harness.outbox.read())?.stage,
      AvatarSelectionOutboxStage.prepared,
    );
  });

  test('same prepared request is locally idempotent', () async {
    final harness = await _Harness.create('outbox-prepare-idempotent.db');
    addTearDown(harness.close);
    final request = _request(key: 'avatar_set_idempotent_1', modelId: 42);
    final previous = _emptyState();

    final first = await harness.outbox.prepare(
      request: request,
      previousSelection: previous,
      compensationKey: 'avatar_comp_idempotent_1',
    );
    final second = await harness.outbox.prepare(
      request: request,
      previousSelection: previous,
      compensationKey: 'avatar_comp_idempotent_1',
    );

    expect(second.recordRevision, first.recordRevision);
    expect(second.createdAt, first.createdAt);
  });

  test(
    'compensation requested before receipt converges through fixed key',
    () async {
      final harness = await _Harness.create('outbox-compensation.db');
      addTearDown(harness.close);
      final request = _request(key: 'avatar_set_compensate_1', modelId: 42);
      final previous = _emptyState();
      var entry = await harness.outbox.prepare(
        request: request,
        previousSelection: previous,
        compensationKey: 'avatar_comp_compensate_1',
      );

      entry = await harness.outbox.requestCompensation(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      expect(entry.stage, AvatarSelectionOutboxStage.prepared);
      expect(entry.resolution, AvatarSelectionOutboxResolution.compensate);

      final appliedReceipt = _receipt(
        key: request.idempotencyKey,
        previous: previous,
        selection: _state(modelId: 42, version: 1, selectionId: 11),
        assetModelId: 42,
      );
      entry = await harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: appliedReceipt,
      );
      expect(entry.stage, AvatarSelectionOutboxStage.compensateNeeded);
      expect(
        entry.compensationRequest.idempotencyKey,
        'avatar_comp_compensate_1',
      );
      expect(entry.compensationRequest.modelId, isNull);
      expect(entry.compensationRequest.expectedVersion, 1);
      expect(
        entry.compensationRequest.assetOptions.hasSameSemanticValue(
          request.assetOptions,
        ),
        isTrue,
      );

      entry = await harness.outbox.beginCompensation(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      final compensationReceipt = _receipt(
        key: entry.compensationRequest.idempotencyKey,
        previous: appliedReceipt.selection,
        selection: _state(modelId: null, version: 2, selectionId: 11),
        assetModelId: 1,
      );
      await harness.outbox.completeCompensation(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: compensationReceipt,
      );

      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'applied receipt is durable before local completion removes it',
    () async {
      final harness = await _Harness.create('outbox-local-completion.db');
      addTearDown(harness.close);
      final request = _request(key: 'avatar_set_local_commit_1', modelId: 42);
      final previous = _emptyState();
      var entry = await harness.outbox.prepare(
        request: request,
        previousSelection: previous,
        compensationKey: 'avatar_comp_local_commit_1',
      );
      final receipt = _receipt(
        key: request.idempotencyKey,
        previous: previous,
        selection: _state(modelId: 42, version: 1, selectionId: 20),
        assetModelId: 42,
      );

      entry = await harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: receipt,
      );
      final reconstructed = SembastAvatarSelectionOutbox(
        accountDatabase: harness.database,
        mount: harness.mount,
        agentScope: harness.agentScope,
        storageScopes: harness.storageScopes,
      );
      final durable = await reconstructed.read();
      expect(durable?.stage, AvatarSelectionOutboxStage.applied);
      expect(durable?.appliedReceipt?.hasSameSemanticValue(receipt), isTrue);

      await reconstructed.completeLocalCommit(
        operationKey: durable!.operationKey,
        expectedRevision: durable.recordRevision,
      );
      expect(await reconstructed.read(), isNull);
      await reconstructed.deactivateAndDrain();
    },
  );

  test(
    'compensation completion rejects a receipt for the wrong prior selection',
    () async {
      final harness = await _Harness.create(
        'outbox-compensation-prior-selection.db',
      );
      addTearDown(harness.close);
      final request = _request(key: 'avatar_set_wrong_prior_1', modelId: 42);
      final previous = _emptyState();
      var entry = await harness.outbox.prepare(
        request: request,
        previousSelection: previous,
        compensationKey: 'avatar_comp_wrong_prior_1',
      );
      entry = await harness.outbox.requestCompensation(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      entry = await harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
        receipt: _receipt(
          key: request.idempotencyKey,
          previous: previous,
          selection: _state(modelId: 42, version: 1, selectionId: 21),
          assetModelId: 42,
        ),
      );
      entry = await harness.outbox.beginCompensation(
        operationKey: entry.operationKey,
        expectedRevision: entry.recordRevision,
      );
      final wrongPriorReceipt = _receipt(
        key: entry.compensationRequest.idempotencyKey,
        previous: _state(modelId: 99, version: 1, selectionId: 999),
        selection: _state(modelId: null, version: 2, selectionId: 999),
        assetModelId: 1,
      );

      await expectLater(
        harness.outbox.completeCompensation(
          operationKey: entry.operationKey,
          expectedRevision: entry.recordRevision,
          receipt: wrongPriorReceipt,
        ),
        throwsA(isA<AvatarSelectionOutboxConflictException>()),
      );

      final durable = await harness.outbox.read();
      expect(durable?.stage, AvatarSelectionOutboxStage.compensating);
      expect(durable?.recordRevision, entry.recordRevision);
    },
  );

  test('operation key and revision fence every late callback', () async {
    final harness = await _Harness.create('outbox-operation-fence.db');
    addTearDown(harness.close);
    final request = _request(key: 'avatar_set_fence_1', modelId: 42);
    final previous = _emptyState();
    var entry = await harness.outbox.prepare(
      request: request,
      previousSelection: previous,
      compensationKey: 'avatar_comp_fence_1',
    );
    final staleRevision = entry.recordRevision;
    entry = await harness.outbox.requestCompensation(
      operationKey: entry.operationKey,
      expectedRevision: entry.recordRevision,
    );
    final receipt = _receipt(
      key: request.idempotencyKey,
      previous: previous,
      selection: _state(modelId: 42, version: 1, selectionId: 30),
      assetModelId: 42,
    );

    await expectLater(
      harness.outbox.recordApplied(
        operationKey: entry.operationKey,
        expectedRevision: staleRevision,
        receipt: receipt,
      ),
      throwsA(isA<AvatarSelectionOutboxConflictException>()),
    );
    await expectLater(
      harness.outbox.discardDefinitelyUncommitted(
        operationKey: 'avatar_wrong_operation_1',
        expectedRevision: entry.recordRevision,
      ),
      throwsA(isA<AvatarSelectionOutboxConflictException>()),
    );
    expect((await harness.outbox.read())?.recordRevision, entry.recordRevision);
  });

  test(
    'mismatched receipt cannot advance or erase prepared evidence',
    () async {
      final harness = await _Harness.create('outbox-receipt-mismatch.db');
      addTearDown(harness.close);
      final request = _request(
        key: 'avatar_set_receipt_mismatch_1',
        modelId: 42,
      );
      final previous = _emptyState();
      final prepared = await harness.outbox.prepare(
        request: request,
        previousSelection: previous,
        compensationKey: 'avatar_comp_receipt_mismatch_1',
      );
      final wrongReceipt = _receipt(
        key: request.idempotencyKey,
        previous: previous,
        selection: _state(modelId: 43, version: 1, selectionId: 31),
        assetModelId: 43,
      );

      await expectLater(
        harness.outbox.recordApplied(
          operationKey: prepared.operationKey,
          expectedRevision: prepared.recordRevision,
          receipt: wrongReceipt,
        ),
        throwsFormatException,
      );
      final retained = await harness.outbox.read();
      expect(retained?.stage, AvatarSelectionOutboxStage.prepared);
      expect(retained?.recordRevision, prepared.recordRevision);
    },
  );

  test('superseded proof is durable before exact guarded removal', () async {
    final harness = await _Harness.create('outbox-superseded.db');
    addTearDown(harness.close);
    var entry = await harness.outbox.prepare(
      request: _request(key: 'avatar_set_superseded_1', modelId: 42),
      previousSelection: _emptyState(),
      compensationKey: 'avatar_comp_superseded_1',
    );

    entry = await harness.outbox.markSuperseded(
      operationKey: entry.operationKey,
      expectedRevision: entry.recordRevision,
      reason: AvatarSelectionSupersededReason.setVersionConflict,
    );
    expect(entry.stage, AvatarSelectionOutboxStage.superseded);
    expect(
      entry.supersededReason,
      AvatarSelectionSupersededReason.setVersionConflict,
    );

    await harness.outbox.completeSuperseded(
      operationKey: entry.operationKey,
      expectedRevision: entry.recordRevision,
    );
    expect(await harness.outbox.read(), isNull);
  });

  test(
    'same-account remount explicitly adopts historical generation',
    () async {
      final harness = await _Harness.create('outbox-adoption.db');
      final request = _request(key: 'avatar_set_adoption_1', modelId: 42);
      final prepared = await harness.outbox.prepare(
        request: request,
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_adoption_1',
      );
      final oldGeneration = harness.mount.generation;
      await harness.outbox.deactivateAndDrain();
      harness.storageScopes.unmount(harness.mount);
      final nextMount = harness.storageScopes.mount(harness.scope);
      final next = SembastAvatarSelectionOutbox(
        accountDatabase: harness.database,
        mount: nextMount,
        agentScope: harness.agentScope,
        storageScopes: harness.storageScopes,
      );

      final historical = await next.inspectForRecovery();
      expect(historical?.ownerGeneration, oldGeneration);
      await expectLater(
        next.read(),
        throwsA(isA<AvatarSelectionOutboxConflictException>()),
      );
      final adopted = await next.adoptForRecovery(
        operationKey: prepared.operationKey,
        expectedRevision: prepared.recordRevision,
      );
      expect(adopted.ownerGeneration, nextMount.generation);
      expect(adopted.recordRevision, prepared.recordRevision + 1);
      expect((await next.read())?.ownerGeneration, nextMount.generation);
      await expectLater(
        harness.outbox.read(),
        throwsA(isA<AvatarSelectionOutboxUnavailableException>()),
      );

      await next.deactivateAndDrain();
      harness.storageScopes.unmount(nextMount);
      await harness.database.close();
    },
  );

  test('corrupt record is retained and blocks replacement', () async {
    final harness = await _Harness.create('outbox-corrupt.db');
    addTearDown(harness.close);
    final prepared = await harness.outbox.prepare(
      request: _request(key: 'avatar_set_corrupt_1', modelId: 42),
      previousSelection: _emptyState(),
      compensationKey: 'avatar_comp_corrupt_1',
    );
    final rawStore = StoreRef<String, Map<String, Object?>>(
      'avatar_selection_outbox.v1',
    );
    final rawRecord = rawStore.record(harness.agentScope.agentDigest);
    final corrupt = <String, Object?>{
      ...prepared.toStorageJson(),
      'stage': 'applied',
      'appliedReceipt': null,
    };
    await rawRecord.put(harness.database.raw, corrupt);

    await expectLater(
      harness.outbox.inspectForRecovery(),
      throwsA(isA<AvatarSelectionOutboxCorruptException>()),
    );
    await expectLater(
      harness.outbox.prepare(
        request: _request(key: 'avatar_set_replacement_1', modelId: 43),
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_replacement_1',
      ),
      throwsA(isA<AvatarSelectionOutboxCorruptException>()),
    );
    expect((await rawRecord.get(harness.database.raw))?['stage'], 'applied');
  });

  test(
    'foreign account digest fails closed without deleting evidence',
    () async {
      final harness = await _Harness.create('outbox-foreign-account.db');
      addTearDown(harness.close);
      final prepared = await harness.outbox.prepare(
        request: _request(key: 'avatar_set_foreign_1', modelId: 42),
        previousSelection: _emptyState(),
        compensationKey: 'avatar_comp_foreign_1',
      );
      final rawStore = StoreRef<String, Map<String, Object?>>(
        'avatar_selection_outbox.v1',
      );
      final rawRecord = rawStore.record(harness.agentScope.agentDigest);
      final foreign = <String, Object?>{
        ...prepared.toStorageJson(),
        'accountScopeDigest': List<String>.filled(64, 'f').join(),
      };
      await rawRecord.put(harness.database.raw, foreign);

      await expectLater(
        harness.outbox.inspectForRecovery(),
        throwsA(isA<AvatarSelectionOutboxCorruptException>()),
      );
      expect(
        (await rawRecord.get(harness.database.raw))?['accountScopeDigest'],
        foreign['accountScopeDigest'],
      );
    },
  );

  test('final mount fence rejects an admitted queued write', () async {
    final harness = await _Harness.create('outbox-final-fence.db');
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocker = harness.database.raw.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final prepared = harness.outbox.prepare(
      request: _request(key: 'avatar_set_final_fence_1', modelId: 42),
      previousSelection: _emptyState(),
      compensationKey: 'avatar_comp_final_fence_1',
    );

    harness.storageScopes.unmount(harness.mount);
    release.complete();
    await blocker;
    await expectLater(
      prepared,
      throwsA(isA<AvatarSelectionOutboxUnavailableException>()),
    );
    final rawStore = StoreRef<String, Map<String, Object?>>(
      'avatar_selection_outbox.v1',
    );
    expect(
      await rawStore
          .record(harness.agentScope.agentDigest)
          .get(harness.database.raw),
      isNull,
    );
    await harness.outbox.deactivateAndDrain();
    await harness.database.close();
  });

  test('drain waits for admitted persistence and rejects new work', () async {
    final harness = await _Harness.create('outbox-drain.db');
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocker = harness.database.raw.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final prepared = harness.outbox.prepare(
      request: _request(key: 'avatar_set_drain_1', modelId: 42),
      previousSelection: _emptyState(),
      compensationKey: 'avatar_comp_drain_1',
    );
    var drained = false;
    final draining = harness.outbox.deactivateAndDrain().then((_) {
      drained = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    release.complete();
    await blocker;
    await prepared;
    await draining;
    expect(drained, isTrue);
    await expectLater(
      harness.outbox.read(),
      throwsA(isA<AvatarSelectionOutboxUnavailableException>()),
    );
    harness.storageScopes.unmount(harness.mount);
    await harness.database.close();
  });
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

AvatarSelectionCommitRequest _request({
  required String key,
  required int? modelId,
  int expectedVersion = 0,
  AvatarSelectionAssetOptions assetOptions =
      const AvatarSelectionAssetOptions.none(),
}) => AvatarSelectionCommitRequest(
  agentId: 'self',
  modelId: modelId,
  expectedVersion: expectedVersion,
  idempotencyKey: key,
  assetOptions: assetOptions,
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
  selectedAt: DateTime.utc(2026, 9, 1, 8, version),
);

AvatarSelectionReceipt _receipt({
  required String key,
  required AvatarSelectionState previous,
  required AvatarSelectionState selection,
  required int assetModelId,
}) {
  final isBundled = assetModelId == 1;
  return AvatarSelectionReceipt(
    idempotencyKey: key,
    previousSelection: previous,
    selection: selection,
    asset: AvatarSelectionAssetDescriptor(
      id: assetModelId,
      modelKey: isBundled ? 'masso.bundled.agent' : 'model-$assetModelId',
      displayName: isBundled ? 'Maaso Agent' : 'Model $assetModelId',
      modelSource: isBundled ? 'bundled' : 'reviewed',
      assetUrl: isBundled
          ? 'unity://masso/avatar_agent'
          : 'https://cdn.example.com/model-$assetModelId.glb',
      assetSha256: isBundled
          ? '82e306d47cd720b6ba121bfab08f07de5cb50e8046e34bd52d959b55012240cd'
          : List<String>.filled(64, 'a').join(),
      compatibility: const <String, Object?>{},
    ),
    selectionAvailable: true,
  );
}
