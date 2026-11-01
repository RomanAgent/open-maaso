import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_selection_outbox.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'older frozen request gets a terminal builtin compatibility rejection without retry upgrade',
    () async {
      final posts = <_ObservedPost>[];
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'GET') return _currentResponse(agentId: 'self');
          posts.add(_ObservedPost.fromRequest(request));
          return http.Response(
            jsonEncode({
              'code': 'AVATAR_BUILTIN_CATALOG_REQUIRED',
              'message': 'update app',
              'traceId': 'builtin-test',
              'data': null,
            }),
            409,
          );
        }),
      );
      addTearDown(harness.close);
      // Both set and possible compensation keys are reserved before any POST.
      final coordinator = harness.coordinator(
        keys: ['old_clear_blocked_01', 'unused_compensation_01'],
      );
      addTearDown(coordinator.deactivateAndDrain);
      await expectLater(
        coordinator.commit(
          modelId: null,
          assetOptions: const AvatarSelectionAssetOptions.none(),
        ),
        throwsA(
          isA<AvatarSelectionValidationException>().having(
            (e) => e.code,
            'code',
            'AVATAR_BUILTIN_CATALOG_REQUIRED',
          ),
        ),
      );
      expect(posts, hasLength(1));
      expect(
        posts.single.decodedBody.containsKey('builtinCatalogVersion'),
        isFalse,
      );
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'ambiguous normal commit replays exact request with captured token after unpublish',
    () async {
      final posts = <_ObservedPost>[];
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'GET') {
            expect(
              request.url.toString(),
              'https://api-test.futurpals.com.cn/'
              'v1/avatar-models/selections/current'
              '?agentId=self&platformAssets=false',
            );
            expect(request.headers['authorization'], 'Bearer captured-token');
            return _currentResponse(agentId: 'self');
          }
          posts.add(_ObservedPost.fromRequest(request));
          if (posts.length == 1) return _ambiguousResponse();
          return _commitResponse(posts.first.decodedBody, replayed: true);
        }),
      );
      addTearDown(harness.close);
      final coordinator = harness.coordinator(
        keys: const <String>[
          'avatar_set_unpublish_1',
          'avatar_comp_unpublish_1',
        ],
        retryDelay: (attempt) async {
          expect(attempt, 1);
          await harness.auth.unpublishSession();
        },
      );
      addTearDown(coordinator.deactivateAndDrain);

      final committed = await coordinator.commit(
        modelId: 24,
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );

      expect(committed.receipt.selection.modelId, 24);
      expect(harness.auth.session.value, isNull);
      expect(posts, hasLength(2));
      expect(
        posts.map((request) => request.url).toList(),
        everyElement(
          'https://api-test.futurpals.com.cn/'
          'v1/avatar-models/selections/commit',
        ),
      );
      expect(posts.map((request) => request.authorization).toList(), <String>[
        'Bearer captured-token',
        'Bearer captured-token',
      ]);
      expect(posts.last.rawBody, posts.first.rawBody);
      expect(posts.last.decodedBody, posts.first.decodedBody);
      expect(posts.first.decodedBody, <String, Object?>{
        'agentId': 'self',
        'modelId': 24,
        'expectedVersion': 0,
        'idempotencyKey': 'avatar_set_unpublish_1',
        'platformAssets': false,
      });
      expect(await harness.outbox.read(), isNull);
    },
  );

  test(
    'ambiguous commit recovery uses refreshed token from same published account',
    () async {
      final posts = <_ObservedPost>[];
      final harness = await _Harness.create(
        MockClient((request) async {
          if (request.method == 'GET') {
            return _currentResponse(agentId: 'self');
          }
          posts.add(_ObservedPost.fromRequest(request));
          if (posts.length == 1) return _ambiguousResponse();
          return _commitResponse(posts.first.decodedBody, replayed: true);
        }),
      );
      addTearDown(harness.close);
      final coordinator = harness.coordinator(
        keys: const <String>['avatar_set_refresh_1', 'avatar_comp_refresh_1'],
        retryDelay: (attempt) async {
          expect(attempt, 1);
          harness.auth.session.value = _session(
            accountUuid: _ownerAccount,
            accessToken: 'refreshed-token',
          );
          await Future<void>.value();
        },
      );
      addTearDown(coordinator.deactivateAndDrain);

      await coordinator.commit(
        modelId: 24,
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );

      expect(posts, hasLength(2));
      expect(posts.map((request) => request.authorization).toList(), <String>[
        'Bearer captured-token',
        'Bearer refreshed-token',
      ]);
      expect(posts.last.rawBody, posts.first.rawBody);
      expect(posts.last.decodedBody['idempotencyKey'], 'avatar_set_refresh_1');
      expect(await harness.outbox.read(), isNull);
    },
  );

  for (final fence in _RecoveryFence.values) {
    test(
      '${fence.label} rejects recovery before network and retains outbox',
      () {
        return _expectRecoveryFence(fence);
      },
    );
  }
}

Future<void> _expectRecoveryFence(_RecoveryFence fence) async {
  var requests = 0;
  final harness = await _Harness.create(
    MockClient((_) async {
      requests += 1;
      throw StateError('a rejected recovery claim must not reach HTTP');
    }),
    claimAccountMismatch: fence == _RecoveryFence.claimAccountScope,
    claimAgentMismatch: fence == _RecoveryFence.claimAgentScope,
    claimGenerationMismatch: fence == _RecoveryFence.claimGeneration,
  );
  addTearDown(harness.close);
  final request = AvatarSelectionCommitRequest(
    agentId: harness.outbox.agentScope.agentId,
    modelId: 24,
    expectedVersion: 0,
    idempotencyKey: 'avatar_set_fence_${fence.index + 1}',
    assetOptions: const AvatarSelectionAssetOptions.none(),
  );
  await harness.outbox.prepare(
    request: request,
    previousSelection: _emptySelection(request.agentId),
    compensationKey: 'avatar_comp_fence_${fence.index + 1}',
  );

  switch (fence) {
    case _RecoveryFence.publishedAccount:
      harness.auth.session.value = _session(
        accountUuid: 'another-account',
        accessToken: 'another-token',
      );
    case _RecoveryFence.environment:
      harness.environment.environment.value = MaasoEnvironment.production;
    case _RecoveryFence.claimAccountScope:
    case _RecoveryFence.claimAgentScope:
    case _RecoveryFence.claimGeneration:
      break;
  }

  final coordinator = harness.coordinator(keys: const <String>[]);
  addTearDown(coordinator.deactivateAndDrain);

  await expectLater(
    coordinator.recover(
      decide: (_) => AvatarSelectionRecoveryResolution.rollForward,
    ),
    throwsA(
      isA<AvatarSelectionAmbiguousTransportException>().having(
        (error) => error.cause,
        'cause',
        isA<AvatarSelectionAuthorizationException>().having(
          (error) => error.code,
          'code',
          'AVATAR_SELECTION_RECOVERY_FENCE_REJECTED',
        ),
      ),
    ),
  );

  expect(requests, 0);
  final retained = await harness.outbox.read();
  expect(retained, isNotNull);
  expect(retained!.stage, AvatarSelectionOutboxStage.prepared);
  expect(retained.request.hasSameSemanticValue(request), isTrue);
  expect(retained.operationKey, request.idempotencyKey);
}

enum _RecoveryFence {
  publishedAccount('different published account'),
  environment('different environment'),
  claimAccountScope('different account-scope claim'),
  claimAgentScope('different agent-scope claim'),
  claimGeneration('different generation claim');

  const _RecoveryFence(this.label);

  final String label;
}

final class _Harness {
  _Harness({
    required this.database,
    required this.transport,
    required this.auth,
    required this.environment,
    required this.outbox,
    required this.scopeOwners,
  });

  static int _databaseSerial = 0;

  static Future<_Harness> create(
    http.Client client, {
    bool claimAccountMismatch = false,
    bool claimAgentMismatch = false,
    bool claimGenerationMismatch = false,
  }) async {
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    environment.environment.value = MaasoEnvironment.test;
    final auth = appServices.put(
      AuthSessionService(
        httpClient: MockClient((_) async {
          throw StateError('transport recovery tests must not refresh auth');
        }),
      ),
    );
    await auth.init();
    final session = _session(
      accountUuid: _ownerAccount,
      accessToken: 'captured-token',
    );
    auth.session.value = session;

    final transportScope = AccountStorageScope(
      environmentKey: MaasoEnvironment.test.key,
      accountUuid: _ownerAccount,
    );
    final transportScopeOwner = AccountStorageScopeService();
    final transportMount = transportScopeOwner.mount(transportScope);
    final transportAgentScope = transportScope.agent('self');
    final transport = AvatarModelCatalogService(
      accountSession: session,
      accountMount: transportMount,
      agentScope: transportAgentScope,
      storageScopes: transportScopeOwner,
      httpClient: client,
      targetPlatform: TargetPlatform.macOS,
    );

    var outboxScopeOwner = transportScopeOwner;
    var outboxScope = transportScope;
    var outboxMount = transportMount;
    var outboxAgentScope = transportAgentScope;
    if (claimAccountMismatch) {
      outboxScopeOwner = AccountStorageScopeService();
      outboxScope = AccountStorageScope(
        environmentKey: MaasoEnvironment.test.key,
        accountUuid: 'claim-account',
      );
      outboxMount = outboxScopeOwner.mount(outboxScope);
      outboxAgentScope = outboxScope.agent('self');
    } else if (claimAgentMismatch) {
      outboxAgentScope = outboxScope.agent('another-agent');
    } else if (claimGenerationMismatch) {
      transportScopeOwner.unmount(transportMount);
      outboxMount = transportScopeOwner.mount(outboxScope);
    }

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'avatar-selection-transport-recovery-${_databaseSerial++}.db',
    );
    final outbox = SembastAvatarSelectionOutbox(
      accountDatabase: database,
      mount: outboxMount,
      agentScope: outboxAgentScope,
      storageScopes: outboxScopeOwner,
    );
    return _Harness(
      database: database,
      transport: transport,
      auth: auth,
      environment: environment,
      outbox: outbox,
      scopeOwners: <AccountStorageScopeService>{
        transportScopeOwner,
        outboxScopeOwner,
      },
    );
  }

  final DBService database;
  final AvatarModelCatalogService transport;
  final AuthSessionService auth;
  final AppEnvironmentService environment;
  final SembastAvatarSelectionOutbox outbox;
  final Set<AccountStorageScopeService> scopeOwners;

  AvatarSelectionCoordinator coordinator({
    required List<String> keys,
    AvatarSelectionRetryDelay? retryDelay,
  }) {
    var keyIndex = 0;
    return AvatarSelectionCoordinator(
      transport: transport,
      recoveryTransport: transport,
      outbox: outbox,
      idempotencyKeyFactory: () => keys[keyIndex++],
      retryDelay: retryDelay,
    );
  }

  Future<void> close() async {
    await outbox.deactivateAndDrain();
    transport.onClose();
    for (final owner in scopeOwners) {
      final activeMount = owner.activeMount;
      if (activeMount != null) owner.unmount(activeMount);
    }
    await database.close();
  }
}

final class _ObservedPost {
  const _ObservedPost({
    required this.url,
    required this.authorization,
    required this.rawBody,
    required this.decodedBody,
  });

  factory _ObservedPost.fromRequest(http.Request request) {
    expect(request.method, 'POST');
    final decoded = jsonDecode(request.body);
    expect(decoded, isA<Map>());
    return _ObservedPost(
      url: request.url.toString(),
      authorization: request.headers['authorization'] ?? '',
      rawBody: request.body,
      decodedBody: Map<String, Object?>.from(decoded as Map),
    );
  }

  final String url;
  final String authorization;
  final String rawBody;
  final Map<String, Object?> decodedBody;
}

MaasoAuthSession _session({
  required String accountUuid,
  required String accessToken,
}) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: accessToken,
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

AvatarSelectionState _emptySelection(String agentId) => AvatarSelectionState(
  selectionId: null,
  agentId: agentId,
  modelId: null,
  version: 0,
  selectedAt: null,
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

http.Response _ambiguousResponse() => http.Response(
  jsonEncode(
    _envelope(null, code: 'SERVICE_UNAVAILABLE', message: 'retry later'),
  ),
  503,
  headers: const <String, String>{'content-type': 'application/json'},
);

http.Response _commitResponse(
  Map<String, Object?> request, {
  required bool replayed,
}) {
  final agentId = request['agentId']! as String;
  final modelId = request['modelId'] as int?;
  final expectedVersion = request['expectedVersion']! as int;
  final selectionId = expectedVersion == 0 ? 9 : 10;
  return http.Response(
    jsonEncode(
      _envelope(<String, Object?>{
        'contractVersion': avatarSelectionContractVersion,
        'receipt': <String, Object?>{
          'idempotencyKey': request['idempotencyKey'],
          'previousSelection': _selectionState(
            agentId: agentId,
            version: expectedVersion,
            selectionId: expectedVersion == 0 ? null : selectionId,
            modelId: expectedVersion == 0 ? null : modelId,
            selectedAt: expectedVersion == 0 ? null : '2026-09-01T07:00:00Z',
          ),
          'selection': _selectionState(
            agentId: agentId,
            version: expectedVersion + 1,
            selectionId: selectionId,
            modelId: modelId,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
          'asset': modelId == null ? _bundledAsset() : _remoteAsset(modelId),
          'selectionAvailable': true,
        },
        'replayed': replayed,
      }),
    ),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

Map<String, Object?> _envelope(
  Object? data, {
  String code = 'OK',
  String message = 'success',
}) => <String, Object?>{
  'code': code,
  'message': message,
  'traceId': 'trace-avatar-selection-recovery',
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
  'assetUrl': 'unity://masso/avatar_agent',
  'assetSha256':
      '82e306d47cd720b6ba121bfab08f07de5cb50e8046e34bd52d959b55012240cd',
  'runtimeConfig': <String, Object?>{'avatar': 'agent', 'assetName': 'Agent'},
  'compatibility': <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

Map<String, Object?> _remoteAsset(int modelId) => <String, Object?>{
  'id': modelId,
  'modelKey': 'community.creator.v1',
  'displayName': 'Creator',
  'modelSource': 'community',
  'assetUrl': 'https://cdn.example.com/creator.vrm',
  'assetSha256': 'a' * 64,
  'runtimeConfig': <String, Object?>{'assetFormat': 'vrm'},
  'compatibility': <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

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

const String _ownerAccount = 'owner-account';
