import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_runtime_producer_fence.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await SpUtils.init();
  });

  tearDown(appServices.reset);

  test(
    'late avatar POST cannot cross logout and cleanup resets before DB close',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final selectionOutcome = harness.startRemoteSelection();
      await harness.postStarted.future.timeout(const Duration(seconds: 1));

      expect(
        harness.outboxStageAtDispatch,
        AvatarSelectionOutboxStage.prepared,
      );
      expect(harness.posts, hasLength(1));
      expect(harness.posts.single.authorization, 'Bearer account-a-token');
      expect(harness.renderer.loadedAvatars, <String>[_remoteAvatar.modelUrl]);

      final signingOut = harness.lifecycle.signOutAndUnmount();
      await _waitUntil(() => harness.coordinator.isSealed);

      expect(harness.avatarConfigDrainStarted, isTrue);
      expect(harness.coordinator.isSealed, isTrue);
      await expectLater(
        signingOut.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'avatar_selection_drain_incomplete',
          ),
        ),
      );

      expect(
        harness.lifecycle.phase.value,
        AccountSessionLifecyclePhase.faulted,
      );
      expect(harness.lifecycle.isMounted, isFalse);
      expect(harness.auth.session.value, isNull);
      expect(harness.renderer.resetCount, 0);
      expect(harness.databaseCloseCount, 0);
      expect(() => harness.database.raw, returnsNormally);
      await expectLater(
        harness.avatarConfig.select(_remoteAvatar.id),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        harness.coordinator.commit(
          modelId: _remoteAvatar.remoteModelId,
          assetOptions: _selectionAssets,
        ),
        throwsA(isA<AvatarSelectionCoordinatorUnavailableException>()),
      );

      final parkedBeforeLateResponse = await harness.inspectParkedObligation();
      expect(parkedBeforeLateResponse, isNotNull);
      expect(
        parkedBeforeLateResponse!.stage,
        AvatarSelectionOutboxStage.prepared,
      );
      expect(
        parkedBeforeLateResponse.operationKey,
        harness.posts.single.body['idempotencyKey'],
      );

      var accountBAuthenticationStarted = false;
      await expectLater(
        harness.lifecycle.authenticateAndMount(() async {
          accountBAuthenticationStarted = true;
          harness.auth.stage(_session('account-b', 'account-b-token'));
        }),
        throwsA(isA<StateError>()),
      );
      expect(accountBAuthenticationStarted, isFalse);
      expect(harness.posts, hasLength(1));

      harness.completeLateSuccess();
      expect(
        await selectionOutcome.timeout(const Duration(seconds: 1)),
        isA<AvatarSelectionOutboxUnavailableException>(),
      );
      expect(harness.renderer.loadedAvatars, <String>[_remoteAvatar.modelUrl]);
      expect(harness.renderer.resetCount, 0);
      expect(harness.databaseCloseCount, 0);

      final parkedAfterLateResponse = await harness.inspectParkedObligation();
      expect(parkedAfterLateResponse, isNotNull);
      expect(
        parkedAfterLateResponse!.stage,
        AvatarSelectionOutboxStage.prepared,
      );
      expect(
        parkedAfterLateResponse.operationKey,
        parkedBeforeLateResponse.operationKey,
      );

      await harness.lifecycle.retryFaultedCleanup();

      expect(
        harness.lifecycle.phase.value,
        AccountSessionLifecyclePhase.signedOut,
      );
      expect(harness.renderer.resetCount, 1);
      expect(harness.renderer.lastResetUrl, _bundledAvatar.modelUrl);
      expect(harness.databaseCloseCount, 1);
      expect(
        harness.events.indexOf('renderer_reset'),
        lessThan(harness.events.indexOf('database_close')),
      );
      expect(() => harness.database.raw, throwsStateError);
      expect(harness.posts, hasLength(1));
    },
  );

  test(
    'never-return avatar POST ends logout fail-closed and retains old runtime',
    () async {
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      final selectionOutcome = harness.startRemoteSelection();
      await harness.postStarted.future.timeout(const Duration(seconds: 1));
      final stopwatch = Stopwatch()..start();

      await expectLater(
        harness.lifecycle.signOutAndUnmount().timeout(
          const Duration(seconds: 1),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'avatar_selection_drain_incomplete',
          ),
        ),
      );
      stopwatch.stop();

      // A transport with no terminal event does not make logout hang forever.
      // The bounded drain terminates by retaining the exact old-account lease,
      // its open DB, and its prepared obligation as a hard mount gate.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        harness.lifecycle.phase.value,
        AccountSessionLifecyclePhase.faulted,
      );
      expect(harness.lifecycle.storageScopes.isMounted, isFalse);
      expect(harness.coordinator.isSealed, isTrue);
      expect(harness.renderer.resetCount, 0);
      expect(harness.databaseCloseCount, 0);
      expect(() => harness.database.raw, returnsNormally);
      expect(
        (await harness.inspectParkedObligation())?.stage,
        AvatarSelectionOutboxStage.prepared,
      );

      var replacementAuthenticationStarted = false;
      await expectLater(
        harness.lifecycle.authenticateAndMount(() async {
          replacementAuthenticationStarted = true;
          harness.auth.stage(_session('account-b', 'account-b-token'));
        }),
        throwsA(isA<StateError>()),
      );
      expect(replacementAuthenticationStarted, isFalse);
      expect(harness.posts, hasLength(1));
      expect(harness.posts.single.authorization, 'Bearer account-a-token');

      // Release only the test fixture after the never-return contract has
      // been proven. Production deliberately has no forced-success escape:
      // it remains faulted until the old transport produces a terminal event.
      harness.completeLateSuccess();
      expect(
        await selectionOutcome.timeout(const Duration(seconds: 1)),
        isA<AvatarSelectionOutboxUnavailableException>(),
      );
      await harness.lifecycle.retryFaultedCleanup();
      expect(harness.renderer.resetCount, 1);
      expect(harness.databaseCloseCount, 1);
    },
  );
}

final class _Harness {
  _Harness._({
    required this.lifecycle,
    required this.auth,
    required this.database,
    required this.outbox,
    required this.coordinator,
    required this.transport,
    required this.avatarConfig,
    required this.renderer,
    required this.lateResponse,
    required this.postStarted,
    required this.posts,
    required this.events,
    required this.databaseCloseCountReader,
    required this.avatarConfigDrainStartedReader,
    required this.outboxStageAtDispatchReader,
  });

  static int _databaseSerial = 0;

  static Future<_Harness> create() async {
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    environment.environment.value = MaasoEnvironment.test;
    final auth = _LifecycleAuthSessionService();
    appServices.put<AuthSessionService>(auth);
    final renderer = _RecordingAvatarRuntime();
    final activeAvatar = appServices.put(ActiveAvatarRuntime());
    activeAvatar.register(renderer);

    final storageScopes = AccountStorageScopeService();
    final producerFence = AccountRuntimeProducerFenceController();
    final lateResponse = Completer<http.Response>();
    final postStarted = Completer<void>();
    final posts = <_ObservedPost>[];
    final events = <String>[];
    var databaseCloseCount = 0;
    var avatarConfigDrainStarted = false;
    AvatarSelectionOutboxStage? outboxStageAtDispatch;

    late DBService database;
    late SembastAvatarSelectionOutbox outbox;
    late AvatarSelectionCoordinator coordinator;
    late AvatarModelCatalogService transport;
    late AvatarConfigService avatarConfig;

    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return _currentResponse(agentId: 'self');
      }
      final post = _ObservedPost.fromRequest(request);
      posts.add(post);
      events.add('post_dispatched');
      outboxStageAtDispatch = (await outbox.read())?.stage;
      if (!postStarted.isCompleted) postStarted.complete();
      return lateResponse.future;
    });

    final lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      storageScopes: storageScopes,
      fenceRuntime: producerFence.fenceAndDrain,
      mountRuntime: (mount) async {
        final session = auth.candidate?.session;
        if (session == null) throw StateError('missing mount candidate');
        database =
            await DBService(
              closeDatabase: (raw) async {
                events.add('database_close');
                databaseCloseCount++;
                await raw.close();
              },
            ).init(
              factory: databaseFactoryMemory,
              path:
                  'avatar-selection-account-lifecycle-${_databaseSerial++}.db',
            );
        final accountScope = mount.scope;
        final agentScope = accountScope.agent('self');
        outbox = SembastAvatarSelectionOutbox(
          accountDatabase: database,
          mount: mount,
          agentScope: agentScope,
          storageScopes: storageScopes,
        );
        transport = AvatarModelCatalogService(
          accountSession: session,
          accountMount: mount,
          agentScope: agentScope,
          storageScopes: storageScopes,
          httpClient: client,
          targetPlatform: TargetPlatform.macOS,
          selectionRequestTimeout: const Duration(seconds: 5),
        );
        var keyIndex = 0;
        const keys = <String>[
          'avatar_set_account_teardown_1',
          'avatar_comp_account_teardown_1',
        ];
        coordinator = AvatarSelectionCoordinator(
          transport: transport,
          recoveryTransport: transport,
          outbox: outbox,
          idempotencyKeyFactory: () => keys[keyIndex++],
        );
        avatarConfig = AvatarConfigService(
          initialCatalog: const <AvatarOption>[_bundledAvatar, _remoteAvatar],
          storageKeyPrefix: accountScope.storageNamespace,
          persistSelection: (_, _) async => true,
          selectionCoordinator: coordinator,
          selectionAssetOptions: _selectionAssets,
        ).init();
        avatarConfig.markAuthoritativeSelectionReady();

        final handle = producerFence.install(() async {
          events.add('avatar_producers_sealed');
          avatarConfigDrainStarted = true;
          final configDrain = avatarConfig.deactivateAndDrain(
            timeout: _drainTimeout,
          );
          final selectionDrain = coordinator.deactivateAndDrain(
            timeout: _drainTimeout,
          );
          final configFullyDrained = await configDrain;
          final selectionResult = await selectionDrain;
          if (!configFullyDrained) {
            throw StateError('avatar_config_drain_incomplete');
          }
          if (!selectionResult.fullyDrained) {
            throw StateError('avatar_selection_drain_incomplete');
          }
          final fallback = AvatarConfigService.builtInCatalog.first;
          activeAvatar.select(fallback.backend);
          await activeAvatar.current?.resetAvatarForAccountBoundary(
            fallback.modelUrl,
            fallback.config,
          );
          events.add('renderer_reset');
        });

        return _RetryableRuntimeLease(() async {
          await handle.fenceAndDrain();
          avatarConfig.closeLifecycle();
          transport.closeLifecycle();
          await database.close();
          await handle.complete();
        });
      },
    );

    final mounted = await lifecycle.authenticateAndMount(() async {
      auth.stage(_session(_accountA, 'account-a-token'));
    });
    if (!mounted) throw StateError('test account did not mount');

    return _Harness._(
      lifecycle: lifecycle,
      auth: auth,
      database: database,
      outbox: outbox,
      coordinator: coordinator,
      transport: transport,
      avatarConfig: avatarConfig,
      renderer: renderer,
      lateResponse: lateResponse,
      postStarted: postStarted,
      posts: posts,
      events: events,
      databaseCloseCountReader: () => databaseCloseCount,
      avatarConfigDrainStartedReader: () => avatarConfigDrainStarted,
      outboxStageAtDispatchReader: () => outboxStageAtDispatch,
    );
  }

  final AccountSessionLifecycleService lifecycle;
  final _LifecycleAuthSessionService auth;
  final DBService database;
  final SembastAvatarSelectionOutbox outbox;
  final AvatarSelectionCoordinator coordinator;
  final AvatarModelCatalogService transport;
  final AvatarConfigService avatarConfig;
  final _RecordingAvatarRuntime renderer;
  final Completer<http.Response> lateResponse;
  final Completer<void> postStarted;
  final List<_ObservedPost> posts;
  final List<String> events;
  final int Function() databaseCloseCountReader;
  final bool Function() avatarConfigDrainStartedReader;
  final AvatarSelectionOutboxStage? Function() outboxStageAtDispatchReader;

  int get databaseCloseCount => databaseCloseCountReader();

  bool get avatarConfigDrainStarted => avatarConfigDrainStartedReader();

  AvatarSelectionOutboxStage? get outboxStageAtDispatch =>
      outboxStageAtDispatchReader();

  Future<Object?> startRemoteSelection() =>
      _failureOf(avatarConfig.select(_remoteAvatar.id));

  void completeLateSuccess() {
    if (lateResponse.isCompleted) return;
    final post = posts.single;
    lateResponse.complete(_commitResponse(post.body));
  }

  Future<AvatarSelectionOutboxEntry?> inspectParkedObligation() async {
    final inspectorScopes = AccountStorageScopeService();
    final scope = AccountStorageScope(
      environmentKey: MaasoEnvironment.test.key,
      accountUuid: _accountA,
    );
    final mount = inspectorScopes.mount(scope);
    final inspector = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: mount,
      agentScope: scope.agent('self'),
      storageScopes: inspectorScopes,
    );
    try {
      return await inspector.inspectForRecovery();
    } finally {
      await inspector.deactivateAndDrain();
      inspectorScopes.unmount(mount);
    }
  }

  Future<void> dispose() async {
    completeLateSuccess();
    await Future<void>.delayed(Duration.zero);
    if (lifecycle.isFaulted) {
      try {
        await lifecycle.retryFaultedCleanup();
      } catch (_) {
        // Assertions report the lifecycle failure; fixture cleanup continues.
      }
    }
    avatarConfig.closeLifecycle();
    transport.closeLifecycle();
    try {
      await database.close();
    } catch (_) {
      // The behavior assertions own database-close failures.
    }
    lifecycle.closeLifecycle();
  }
}

final class _RetryableRuntimeLease implements AccountRuntimeLease {
  _RetryableRuntimeLease(this._dispose);

  final Future<void> Function() _dispose;
  Future<void>? _inFlight;
  bool _closed = false;

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    return _inFlight ??= _closeOnce();
  }

  Future<void> _closeOnce() async {
    try {
      await _dispose();
      _closed = true;
    } finally {
      _inFlight = null;
    }
  }
}

final class _LifecycleAuthSessionService extends AuthSessionService {
  MaasoAuthCandidate? _stagedCandidate;
  int _operationEpoch = 0;

  @override
  MaasoAuthCandidate? get candidate => _stagedCandidate;

  void stage(MaasoAuthSession session) {
    _stagedCandidate = MaasoAuthCandidate(
      environment: appServices.find<AppEnvironmentService>().environment.value,
      session: session,
      operationEpoch: ++_operationEpoch,
      logoutFence: const AuthLogoutPendingSnapshot(
        pending: false,
        revision: 1,
        token: 'test-cleared',
      ),
    );
    this.session.value = null;
  }

  @override
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    final current = _stagedCandidate;
    if (current == null ||
        (expected != null && !identical(current, expected))) {
      throw StateError('candidate changed');
    }
    session.value = current.session;
  }

  @override
  Future<void> unpublishSession() async {
    session.value = null;
  }

  @override
  Future<void> signOut() async {
    session.value = null;
    _stagedCandidate = null;
  }
}

final class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

final class _RecordingAvatarRuntime extends AvatarRuntime {
  final List<String> loadedAvatars = <String>[];
  int resetCount = 0;
  String? lastResetUrl;

  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = true.obs;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async {
    loadedAvatars.add(modelUrl);
  }

  @override
  Future<void> resetAvatarForAccountBoundary(
    String modelUrl, [
    Map<String, dynamic> config = const <String, dynamic>{},
  ]) async {
    resetCount++;
    lastResetUrl = modelUrl;
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
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

final class _ObservedPost {
  const _ObservedPost({required this.authorization, required this.body});

  factory _ObservedPost.fromRequest(http.Request request) {
    final decoded = jsonDecode(request.body);
    if (decoded is! Map) throw StateError('POST body must be an object');
    return _ObservedPost(
      authorization: request.headers['authorization'] ?? '',
      body: Map<String, Object?>.from(decoded),
    );
  }

  final String authorization;
  final Map<String, Object?> body;
}

Future<Object?> _failureOf(Future<void> operation) async {
  try {
    await operation;
    return null;
  } catch (error) {
    return error;
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

MaasoAuthSession _session(String accountUuid, String accessToken) =>
    MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: accessToken,
      refreshToken: 'refresh-$accountUuid',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );

http.Response _currentResponse({required String agentId}) => http.Response(
  jsonEncode(
    _envelope(<String, Object?>{
      'contractVersion': avatarSelectionContractVersion,
      'selection': _selectionState(agentId: agentId, version: 0),
      'asset': _bundledAsset(),
      'selectionAvailable': true,
    }),
  ),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

http.Response _commitResponse(Map<String, Object?> request) {
  final agentId = request['agentId']! as String;
  final modelId = request['modelId'] as int?;
  final expectedVersion = request['expectedVersion']! as int;
  return http.Response(
    jsonEncode(
      _envelope(<String, Object?>{
        'contractVersion': avatarSelectionContractVersion,
        'receipt': <String, Object?>{
          'idempotencyKey': request['idempotencyKey'],
          'previousSelection': _selectionState(
            agentId: agentId,
            version: expectedVersion,
          ),
          'selection': _selectionState(
            agentId: agentId,
            version: expectedVersion + 1,
            selectionId: 9,
            modelId: modelId,
            selectedAt: '2026-09-02T08:00:00Z',
          ),
          'asset': modelId == null ? _bundledAsset() : _remoteAsset(modelId),
          'selectionAvailable': true,
        },
        'replayed': false,
      }),
    ),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

Map<String, Object?> _envelope(Object? data) => <String, Object?>{
  'code': 'OK',
  'message': 'success',
  'traceId': 'trace-avatar-account-lifecycle',
  'data': data,
};

Map<String, Object?> _selectionState({
  required String agentId,
  required int version,
  int? selectionId,
  int? modelId,
  String? selectedAt,
}) => <String, Object?>{
  'selectionId': selectionId,
  'agentId': agentId,
  'modelId': modelId,
  'version': version,
  'selectedAt': selectedAt,
};

Map<String, Object?> _bundledAsset() => <String, Object?>{
  'id': 1,
  'modelKey': 'masso.bundled.agent',
  'displayName': 'Agent',
  'modelSource': 'official',
  'assetUrl': _bundledAvatar.modelUrl,
  'assetSha256': 'b' * 64,
  'runtimeConfig': const <String, Object?>{
    'avatar': 'agent',
    'assetName': 'Agent',
  },
  'compatibility': const <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

Map<String, Object?> _remoteAsset(int modelId) => <String, Object?>{
  'id': modelId,
  'modelKey': 'community.lifecycle.v1',
  'displayName': 'Lifecycle avatar',
  'modelSource': 'community',
  'assetUrl': _remoteAvatar.modelUrl,
  'assetSha256': 'a' * 64,
  'runtimeConfig': const <String, Object?>{'assetFormat': 'vrm'},
  'compatibility': const <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

const Duration _drainTimeout = Duration(milliseconds: 30);
const String _accountA = 'account-a';
const AvatarSelectionAssetOptions _selectionAssets =
    AvatarSelectionAssetOptions.none();
const AvatarOption _bundledAvatar = AvatarOption(
  id: 'agent',
  name: 'Agent',
  backend: AvatarBackendKind.unity,
  modelUrl: 'unity://masso/avatar_agent',
  isDefault: true,
);
const AvatarOption _remoteAvatar = AvatarOption(
  id: 'reviewed-model-42',
  name: 'Lifecycle avatar',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/lifecycle-avatar.vrm',
  remoteModelId: 42,
  modelSource: 'community',
);
