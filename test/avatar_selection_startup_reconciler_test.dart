import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/avatar_selection_startup_reconciler.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/bundled_matt_revision_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final version in [1, 2, 3, 4]) {
    for (final applied in [false, true]) {
      test(
        'retired Matt v$version clears selection and saved context after restart (applied=$applied)',
        () async {
          final events = <String>[];
          final descriptor = version == 4
              ? <String, dynamic>{
                  ...historicalMattDescriptor(),
                  'assetSha256': BundledAvatarContract.mattAssetSha256,
                  'runtimeConfig': BundledAvatarContract.mattRuntimeConfig,
                  'compatibility': {
                    'backends': ['unity'],
                    'builtinCatalogVersion': 5,
                  },
                }
              : historicalMattDescriptor(version: version);
          final asset = AvatarSelectionAssetDescriptor.fromJson(descriptor);
          var current = AvatarSelectionSnapshot(
            selection: _state(modelId: 44, version: 7),
            asset: asset,
            selectionAvailable: true,
          );
          final harness = await _Harness.create(
            databasePath: 'retired-matt-$version-$applied.db',
            events: events,
            savedSelectionId: 'reviewed-model-44',
            currentHandler: (_, _) async => current,
            idempotencyKeyFactory: _keys(
              'retire_model_clear_1',
              'retire_model_comp_1',
            ),
            commitHandler: (request) async {
              expect(
                request.modelId,
                isNull,
                reason: 'No retry may reselect retired content.',
              );
              expect(request.expectedVersion, 7);
              final result = _result(request, current.selection);
              current = AvatarSelectionSnapshot(
                selection: result.receipt.selection,
                asset: result.receipt.asset,
                selectionAvailable: true,
              );
              return result;
            },
          );
          addTearDown(harness.close);
          if (applied) {
            final request = AvatarSelectionCommitRequest(
              agentId: 'self',
              modelId: 44,
              expectedVersion: 6,
              idempotencyKey: 'old_matt_applied_receipt',
              assetOptions: const AvatarSelectionAssetOptions.none(
                builtinCatalogVersion: 2,
              ),
            );
            final prepared = await harness.outbox.prepare(
              request: request,
              previousSelection: _state(modelId: 44, version: 6),
              compensationKey: 'old_matt_compensate',
            );
            await harness.outbox.recordApplied(
              operationKey: prepared.operationKey,
              expectedRevision: prepared.recordRevision,
              receipt: AvatarSelectionReceipt(
                idempotencyKey: request.idempotencyKey,
                previousSelection: _state(modelId: 44, version: 6),
                selection: current.selection,
                asset: asset,
                selectionAvailable: true,
              ),
            );
          }
          final result = await harness
              .reconciler(
                loadReviewedCatalog: () async => [
                  ApprovedAvatarModel.fromJson(descriptor),
                ],
              )
              .reconcile();
          expect(result.state, AvatarSelectionStartupState.ready);
          expect(result.serverClearCommitted, isTrue);
          expect(harness.transport.commitRequests.map((r) => r.modelId), [
            null,
          ]);
          expect(
            harness.runtime.loadAttempts,
            everyElement(_bundledOption.modelUrl),
          );
          expect(harness.config.selectedId.value, 'agent');
          expect(SpUtils.getString('avatar.selected_id'), isEmpty);
          expect(current.selection.modelId, isNull);
          expect(current.selection.version, 8);
          expect(await harness.outbox.read(), isNull);
        },
      );
    }
  }

  test('retirement CAS conflict preserves a newer nonretired model', () async {
    final retired = AvatarSelectionSnapshot(
      selection: _state(modelId: 44, version: 7),
      asset: AvatarSelectionAssetDescriptor.fromJson(
        historicalMattDescriptor(),
      ),
      selectionAvailable: true,
    );
    final newer = _snapshot(modelId: 42, version: 8);
    final harness = await _Harness.create(
      databasePath: 'retired-conflict-preserves-newer.db',
      events: [],
      currentHandler: (_, _) async => retired,
      idempotencyKeyFactory: _keys(
        'retire_conflict_clear_1',
        'retire_conflict_comp_1',
      ),
      commitHandler: (_) async =>
          throw AvatarSelectionVersionChangedException(currentSelection: newer),
    );
    addTearDown(harness.close);
    final result = await harness
        .reconciler(loadReviewedCatalog: () async => [_reviewedModel])
        .reconcile();
    expect(result.serverClearCommitted, isFalse);
    expect(harness.transport.commitRequests, hasLength(1));
    expect(harness.config.selected.remoteModelId, 42);
    expect(
      harness.runtime.loadAttempts,
      isNot(contains(BundledAvatarContract.mattAssetUrl)),
    );
    expect(await harness.outbox.read(), isNull);
  });

  test('retirement retries CAS for a newer still-retired selection', () async {
    final asset = AvatarSelectionAssetDescriptor.fromJson(
      historicalMattDescriptor(),
    );
    var current = AvatarSelectionSnapshot(
      selection: _state(modelId: 44, version: 7),
      asset: asset,
      selectionAvailable: true,
    );
    var conflicts = 0;
    final harness = await _Harness.create(
      databasePath: 'retired-conflict-clears-newer.db',
      events: [],
      currentHandler: (_, _) async => current,
      idempotencyKeyFactory: _keys(
        'retire_conflict_clear_1',
        'retire_conflict_comp_1',
        'retire_conflict_clear_2',
        'retire_conflict_comp_2',
      ),
      commitHandler: (request) async {
        expect(request.modelId, isNull);
        if (conflicts++ == 0) {
          current = AvatarSelectionSnapshot(
            selection: _state(modelId: 44, version: 8),
            asset: asset,
            selectionAvailable: true,
          );
          throw AvatarSelectionVersionChangedException(
            currentSelection: current,
          );
        }
        expect(request.expectedVersion, 8);
        return _result(request, current.selection);
      },
    );
    addTearDown(harness.close);
    final result = await harness
        .reconciler(loadReviewedCatalog: () async => [])
        .reconcile();
    expect(result.serverClearCommitted, isTrue);
    expect(harness.transport.commitRequests, hasLength(2));
    expect(harness.config.selectedId.value, 'agent');
    expect(harness.runtime.loadAttempts, everyElement(_bundledOption.modelUrl));
    expect(await harness.outbox.read(), isNull);
  });

  test(
    'no outbox previews bundled before GET and commits only authoritative remote',
    () async {
      final events = <String>[];
      final authoritative = _snapshot(modelId: 42, version: 3);
      late _Harness harness;
      harness = await _Harness.create(
        databasePath: 'avatar-startup-current.db',
        events: events,
        savedSelectionId: _remoteOption.id,
        currentHandler: (_, _) async {
          // The account boundary must stay hidden even after the safe
          // bundled fallback has loaded and before the selected Matt arrives.
          expect(harness.config.selectionDisplayReady.value, isFalse);
          expect(harness.config.selectionDisplayGeneration.value, 0);
          return authoritative;
        },
        commitHandler: (_) async =>
            throw StateError('current-only startup must not POST'),
      );
      addTearDown(harness.close);

      expect(harness.config.selectedId.value, _bundledOption.id);
      expect(harness.runtime.loadAttempts, isEmpty);

      final result = await harness
          .reconciler(
            loadReviewedCatalog: () async {
              events.add('catalog');
              return const <ApprovedAvatarModel>[_reviewedModel];
            },
          )
          .reconcile();

      expect(result.state, AvatarSelectionStartupState.ready);
      expect(
        result.recoveryOutcome,
        AvatarSelectionRecoveryOutcome.reconciledCurrent,
      );
      expect(result.catalogSize, 1);
      expect(result.serverClearCommitted, isFalse);
      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.ready,
      );
      expect(harness.config.remoteModelSelectionAvailable, isTrue);
      expect(harness.config.selectedId.value, _remoteOption.id);
      expect(harness.config.selectionDisplayReady.value, isTrue);
      expect(harness.config.selectionDisplayGeneration.value, 1);
      expect(harness.transport.commitRequests, isEmpty);
      expect(await harness.outbox.read(), isNull);
      expect(events, <String>[
        'load:${_bundledOption.modelUrl}',
        'GET',
        'catalog',
        'load:${_remoteOption.modelUrl}',
        'persist:${_remoteOption.id}',
      ]);
      expect(
        events.take(events.indexOf('GET')),
        isNot(contains('load:${_remoteOption.modelUrl}')),
      );
    },
  );

  test(
    'v2 contract unavailable still loads catalog and stays bundled read-only',
    () async {
      final events = <String>[];
      final harness = await _Harness.create(
        databasePath: 'avatar-startup-v2-unavailable.db',
        events: events,
        savedSelectionId: _remoteOption.id,
        currentHandler: (_, _) async =>
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            ),
        commitHandler: (_) async =>
            throw StateError('read-only startup must not POST'),
      );
      addTearDown(harness.close);

      final result = await harness
          .reconciler(
            loadReviewedCatalog: () async {
              events.add('catalog');
              return const <ApprovedAvatarModel>[_reviewedModel];
            },
          )
          .reconcile();

      expect(result.state, AvatarSelectionStartupState.readOnlyBundled);
      expect(result.contractErrorCode, 'AVATAR_SELECTION_CONTRACT_UNAVAILABLE');
      expect(result.catalogSize, 1);
      expect(result.serverClearCommitted, isFalse);
      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );
      expect(harness.config.remoteModelSelectionAvailable, isFalse);
      expect(harness.config.selectedId.value, _bundledOption.id);
      expect(harness.config.selectionDisplayCurrent, isFalse);
      expect(harness.config.selectionDisplayGeneration.value, 0);
      expect(
        harness.config.catalog.map((option) => option.id),
        contains(_remoteOption.id),
      );
      expect(harness.transport.commitRequests, isEmpty);
      expect(await harness.outbox.read(), isNull);
      expect(events, <String>[
        'load:${_bundledOption.modelUrl}',
        'GET',
        'catalog',
        'load:${_bundledOption.modelUrl}',
      ]);
    },
  );

  test('durable applied survives reviewed catalog failure', () async {
    final events = <String>[];
    final harness = await _Harness.create(
      databasePath: 'avatar-startup-catalog-failure.db',
      events: events,
      currentHandler: (_, _) async => _snapshot(modelId: 42, version: 1),
      commitHandler: (_) async =>
          throw StateError('catalog failure must not replay'),
    );
    addTearDown(harness.close);
    await _seedDurableApplied(harness.outbox);

    await expectLater(
      harness
          .reconciler(
            loadReviewedCatalog: () async {
              events.add('catalog');
              throw StateError('catalog unavailable');
            },
          )
          .reconcile(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'catalog unavailable',
        ),
      ),
    );

    final retained = await harness.outbox.read();
    expect(retained, isNotNull);
    expect(retained?.stage, AvatarSelectionOutboxStage.applied);
    expect(retained?.appliedReceipt?.selection.modelId, 42);
    expect(harness.transport.currentCalls, 1);
    expect(harness.transport.commitRequests, isEmpty);
    expect(harness.config.selectedId.value, _bundledOption.id);
    expect(events, <String>[
      'load:${_bundledOption.modelUrl}',
      'GET',
      'catalog',
    ]);
  });

  test(
    'durable applied survives local load failure and ambiguous compensation',
    () async {
      final events = <String>[];
      final harness = await _Harness.create(
        databasePath: 'avatar-startup-local-failure.db',
        events: events,
        currentHandler: (_, _) async => _snapshot(modelId: 42, version: 1),
        commitHandler: (_) async =>
            throw const AvatarSelectionAmbiguousTransportException(),
      );
      addTearDown(harness.close);
      await _seedDurableApplied(harness.outbox);
      harness.runtime.failingModelUrl = _remoteOption.modelUrl;

      await expectLater(
        harness
            .reconciler(
              loadReviewedCatalog: () async {
                events.add('catalog');
                return const <ApprovedAvatarModel>[_reviewedModel];
              },
            )
            .reconcile(),
        throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
      );

      final retained = await harness.outbox.read();
      expect(retained, isNotNull);
      expect(retained?.stage, AvatarSelectionOutboxStage.compensating);
      expect(retained?.appliedReceipt?.selection.modelId, 42);
      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.commitRequests, hasLength(1));
      expect(
        harness.transport.recoveryClaims.single.operation,
        AvatarSelectionRecoveryOperation.compensation,
      );
      expect(harness.config.selectedId.value, _bundledOption.id);
      expect(
        events,
        containsAllInOrder(<String>[
          'load:${_bundledOption.modelUrl}',
          'GET',
          'catalog',
          'load:${_remoteOption.modelUrl}',
          'load:${_bundledOption.modelUrl}',
          'POST:avatar_comp_startup_1',
        ]),
      );
    },
  );

  test(
    'contract unavailable during required server clear becomes bundled read-only',
    () async {
      final events = <String>[];
      final harness = await _Harness.create(
        databasePath: 'avatar-startup-clear-unavailable.db',
        events: events,
        currentHandler: (_, _) async => _snapshot(modelId: 99, version: 1),
        commitHandler: (_) async =>
            throw const AvatarSelectionContractUnavailableException(
              statusCode: 404,
            ),
        idempotencyKeyFactory: _keys(
          'avatar_set_clear_unavailable_1',
          'avatar_comp_clear_unavailable_1',
        ),
      );
      addTearDown(harness.close);

      final result = await harness
          .reconciler(
            loadReviewedCatalog: () async {
              events.add('catalog');
              return const <ApprovedAvatarModel>[_reviewedModel];
            },
          )
          .reconcile();

      expect(result.state, AvatarSelectionStartupState.readOnlyBundled);
      expect(result.serverClearCommitted, isFalse);
      expect(result.contractErrorCode, 'AVATAR_SELECTION_CONTRACT_UNAVAILABLE');
      expect(harness.config.selectedId.value, _bundledOption.id);
      expect(
        harness.config.selectionAuthorityState.value,
        AvatarSelectionAuthorityState.readOnlyBundled,
      );
      expect(harness.config.remoteModelSelectionAvailable, isFalse);
      expect(harness.transport.currentCalls, 1);
      expect(harness.transport.commitRequests, hasLength(1));
      expect(harness.transport.commitRequests.single.modelId, isNull);
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'server clear retries once when conflicting current is still invalid',
    () async {
      final events = <String>[];
      var commitCalls = 0;
      final harness = await _Harness.create(
        databasePath: 'avatar-startup-clear-retry.db',
        events: events,
        currentHandler: (_, _) async => _snapshot(modelId: 99, version: 1),
        commitHandler: (request) async {
          commitCalls += 1;
          if (commitCalls == 1) {
            throw AvatarSelectionVersionChangedException(
              currentSelection: _snapshot(modelId: 100, version: 2),
            );
          }
          return _result(request, _state(modelId: 100, version: 2));
        },
        idempotencyKeyFactory: _keys(
          'avatar_set_clear_retry_1',
          'avatar_comp_clear_retry_1',
          'avatar_set_clear_retry_2',
          'avatar_comp_clear_retry_2',
        ),
      );
      addTearDown(harness.close);

      final result = await harness
          .reconciler(
            loadReviewedCatalog: () async => const <ApprovedAvatarModel>[
              _reviewedModel,
            ],
          )
          .reconcile();

      expect(result.state, AvatarSelectionStartupState.ready);
      expect(result.serverClearCommitted, isTrue);
      expect(harness.config.selectedId.value, _bundledOption.id);
      expect(harness.transport.commitRequests, hasLength(2));
      expect(
        harness.transport.commitRequests.map(
          (request) => request.expectedVersion,
        ),
        <int>[1, 2],
      );
      expect(
        harness.transport.commitRequests.map((request) => request.modelId),
        <int?>[null, null],
      );
    },
  );

  test('server clear does not overwrite a newer valid selection', () async {
    final events = <String>[];
    final harness = await _Harness.create(
      databasePath: 'avatar-startup-clear-valid-conflict.db',
      events: events,
      currentHandler: (_, _) async => _snapshot(modelId: 99, version: 1),
      commitHandler: (_) async => throw AvatarSelectionVersionChangedException(
        currentSelection: _snapshot(modelId: 42, version: 2),
      ),
      idempotencyKeyFactory: _keys(
        'avatar_set_clear_valid_1',
        'avatar_comp_clear_valid_1',
      ),
    );
    addTearDown(harness.close);

    final result = await harness
        .reconciler(
          loadReviewedCatalog: () async => const <ApprovedAvatarModel>[
            _reviewedModel,
          ],
        )
        .reconcile();

    expect(result.state, AvatarSelectionStartupState.ready);
    expect(result.serverClearCommitted, isFalse);
    expect(harness.config.selectedId.value, _remoteOption.id);
    expect(harness.transport.commitRequests, hasLength(1));
    expect(harness.transport.commitRequests.single.modelId, isNull);
  });
}

final class _Harness {
  _Harness({
    required this.database,
    required this.storageScopes,
    required this.mount,
    required this.outbox,
    required this.coordinator,
    required this.transport,
    required this.runtime,
    required this.config,
  });

  static Future<_Harness> create({
    required String databasePath,
    required List<String> events,
    required Future<AvatarSelectionSnapshot> Function(
      String agentId,
      AvatarSelectionAssetOptions assetOptions,
    )
    currentHandler,
    required Future<AvatarSelectionCommitResult> Function(
      AvatarSelectionCommitRequest request,
    )
    commitHandler,
    String? savedSelectionId,
    String Function()? idempotencyKeyFactory,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'avatar.selected_id': ?savedSelectionId,
    });
    await SpUtils.init();

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: databasePath,
    );
    final storageScopes = AccountStorageScopeService();
    final scope = AccountStorageScope(
      environmentKey: 'test',
      accountUuid: 'avatar-startup-account',
    );
    final mount = storageScopes.mount(scope);
    final outbox = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: mount,
      agentScope: scope.agent('self'),
      storageScopes: storageScopes,
    );
    final transport = _FakeTransport(
      events: events,
      currentHandler: currentHandler,
      commitHandler: commitHandler,
    );
    final coordinator = AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: outbox,
      idempotencyKeyFactory:
          idempotencyKeyFactory ??
          () =>
              throw StateError('startup recovery must not allocate a new key'),
      maxAmbiguousAttempts: 1,
    );
    final active = appServices.put(ActiveAvatarRuntime());
    final runtime = _RecordingAvatarRuntime(events);
    active.register(runtime);
    final config = appServices.put(
      AvatarConfigService(
        initialCatalog: const <AvatarOption>[_bundledOption, _remoteOption],
        selectionCoordinator: coordinator,
        persistSelection: (key, selectedId) async {
          events.add('persist:${selectedId ?? 'bundled'}');
          return SpUtils.put(key, selectedId);
        },
      ).init(),
    );
    return _Harness(
      database: database,
      storageScopes: storageScopes,
      mount: mount,
      outbox: outbox,
      coordinator: coordinator,
      transport: transport,
      runtime: runtime,
      config: config,
    );
  }

  final DBService database;
  final AccountStorageScopeService storageScopes;
  final AccountStorageScopeMount mount;
  final SembastAvatarSelectionOutbox outbox;
  final AvatarSelectionCoordinator coordinator;
  final _FakeTransport transport;
  final _RecordingAvatarRuntime runtime;
  final AvatarConfigService config;

  AvatarSelectionStartupReconciler reconciler({
    required AvatarSelectionReviewedCatalogLoader loadReviewedCatalog,
  }) => AvatarSelectionStartupReconciler(
    coordinator: coordinator,
    config: config,
    loadReviewedCatalog: loadReviewedCatalog,
    assetOptions: const AvatarSelectionAssetOptions.none(),
    requireCurrentMount: () {},
  );

  Future<void> close() async {
    await coordinator.deactivateAndDrain();
    if (storageScopes.isCurrent(mount)) storageScopes.unmount(mount);
    await database.close();
    await appServices.reset();
  }
}

String Function() _keys(
  String first,
  String second, [
  String? third,
  String? fourth,
]) {
  final values = <String>[first, second, ?third, ?fourth].iterator;
  return () {
    if (!values.moveNext()) throw StateError('No idempotency key remains');
    return values.current;
  };
}

final class _FakeTransport
    implements AvatarSelectionTransport, AvatarSelectionRecoveryTransport {
  _FakeTransport({
    required this.events,
    required this.currentHandler,
    required this.commitHandler,
  });

  final List<String> events;
  final Future<AvatarSelectionSnapshot> Function(
    String agentId,
    AvatarSelectionAssetOptions assetOptions,
  )
  currentHandler;
  final Future<AvatarSelectionCommitResult> Function(
    AvatarSelectionCommitRequest request,
  )
  commitHandler;
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
    events.add('GET');
    return currentHandler(agentId, assetOptions);
  }

  @override
  Future<AvatarSelectionCommitResult> commit(
    AvatarSelectionCommitRequest request,
  ) async {
    commitRequests.add(request);
    events.add('POST:${request.idempotencyKey}');
    return commitHandler(request);
  }

  @override
  Future<AvatarSelectionCommitResult> replay(
    AvatarSelectionRecoveryClaim claim,
  ) async {
    recoveryClaims.add(claim);
    commitRequests.add(claim.request);
    events.add('POST:${claim.request.idempotencyKey}');
    return commitHandler(claim.request);
  }
}

final class _RecordingAvatarRuntime extends AvatarRuntime {
  _RecordingAvatarRuntime(this.events);

  final List<String> events;
  String? failingModelUrl;
  final List<String> loadAttempts = <String>[];

  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = true.obs;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async {
    loadAttempts.add(modelUrl);
    events.add('load:$modelUrl');
    if (modelUrl == failingModelUrl) {
      throw StateError('failed to load $modelUrl');
    }
  }

  @override
  Future<void> clearGaze() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {}

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setGaze(AvatarGaze gaze) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

Future<void> _seedDurableApplied(SembastAvatarSelectionOutbox outbox) async {
  final request = AvatarSelectionCommitRequest(
    agentId: 'self',
    modelId: 42,
    expectedVersion: 0,
    idempotencyKey: 'avatar_set_startup_1',
    assetOptions: const AvatarSelectionAssetOptions.none(),
  );
  var entry = await outbox.prepare(
    request: request,
    previousSelection: _emptyState(),
    compensationKey: 'avatar_comp_startup_1',
  );
  entry = await outbox.recordApplied(
    operationKey: entry.operationKey,
    expectedRevision: entry.recordRevision,
    receipt: _result(request, _emptyState()).receipt,
  );
  expect(entry.stage, AvatarSelectionOutboxStage.applied);
}

AvatarSelectionCommitResult _result(
  AvatarSelectionCommitRequest request,
  AvatarSelectionState previous,
) {
  final selection = _state(
    modelId: request.modelId,
    version: previous.version + 1,
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

AvatarSelectionSnapshot _snapshot({
  required int? modelId,
  required int version,
}) => AvatarSelectionSnapshot(
  selection: version == 0
      ? _emptyState()
      : _state(modelId: modelId, version: version),
  asset: _asset(modelId),
  selectionAvailable: true,
);

AvatarSelectionState _emptyState() => AvatarSelectionState(
  selectionId: null,
  agentId: 'self',
  modelId: null,
  version: 0,
  selectedAt: null,
);

AvatarSelectionState _state({required int? modelId, required int version}) =>
    AvatarSelectionState(
      selectionId: 10,
      agentId: 'self',
      modelId: modelId,
      version: version,
      selectedAt: DateTime.utc(2026, 9, 2, 8, version),
    );

AvatarSelectionAssetDescriptor _asset(int? modelId) {
  final bundled = modelId == null;
  return AvatarSelectionAssetDescriptor(
    id: modelId ?? 1,
    modelKey: bundled ? 'masso.bundled.agent' : 'model-$modelId',
    displayName: bundled ? 'Maaso Agent' : 'Model $modelId',
    modelSource: bundled ? 'bundled' : 'reviewed',
    assetUrl: bundled ? _bundledOption.modelUrl : _remoteOption.modelUrl,
    assetSha256: _avatarSha256,
    runtimeConfig: bundled
        ? const <String, Object?>{}
        : const <String, Object?>{'assetName': 'Avatar/Remote'},
    compatibility: bundled
        ? const <String, Object?>{}
        : const <String, Object?>{
            'backends': <Object?>['unity'],
          },
  );
}

const _avatarSha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

const _bundledOption = AvatarOption(
  id: 'agent',
  name: 'Agent',
  backend: AvatarBackendKind.unity,
  modelUrl: 'unity://masso/avatar_agent',
  isDefault: true,
);

const _remoteOption = AvatarOption(
  id: 'reviewed-model-42',
  name: 'Remote 42',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/model-42.glb',
  config: <String, dynamic>{'assetName': 'Avatar/Remote'},
  remoteModelId: 42,
  modelSource: 'reviewed',
);

const _reviewedModel = ApprovedAvatarModel(
  id: 42,
  modelKey: 'model-42',
  displayName: 'Remote 42',
  modelSource: 'reviewed',
  assetUrl: 'https://cdn.example.com/model-42.glb',
  assetSha256: _avatarSha256,
  runtimeConfig: <String, dynamic>{'assetName': 'Avatar/Remote'},
  compatibility: <String, dynamic>{
    'backends': <String>['unity'],
  },
);
