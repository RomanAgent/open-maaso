import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/offline/local_test_auth_client.dart';
import 'package:maaso/src/offline/local_mount_credentials.dart';
import 'package:maaso/src/offline/local_original_backend.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/identity/data/identity_http_client.dart';
import 'package:maaso/src/features/identity/data/companion_profile_http_client.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(() async => appServices.reset());

  test('local login refuses wrong credentials and unrelated routes', () async {
    final client = LocalTestAuthClient();
    addTearDown(client.close);
    final wrong = await client.post(
      Uri.parse('https://never-contacted.invalid/v1/login/email'),
      body: jsonEncode({'email': 'test', 'password': 'wrong'}),
    );
    expect(wrong.statusCode, 401);
    final unrelated = await client.get(
      Uri.parse('https://never-contacted.invalid/v1/anything'),
    );
    expect(unrelated.statusCode, 404);
    final signup = await client.post(
      Uri.parse('https://never-contacted.invalid/v1/login/email/signup'),
      body: '{}',
    );
    expect(signup.statusCode, 404);
  });

  test(
    'original auth and lifecycle mount the test account without a backend',
    () async {
      final storage = appServices.put<SecureStorageService>(_MemoryStorage());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final client = LocalTestAuthClient();
      addTearDown(client.close);
      final auth = appServices.put(
        AuthSessionService(
          httpClient: client,
          logoutPendingStore: _LogoutStore(),
        ),
      );
      await auth.init();
      var mounts = 0;
      var closed = false;
      final scopes = AccountStorageScopeService();
      final db = await databaseFactoryMemory.openDatabase(
        'local-mount-account',
      );
      addTearDown(db.close);
      late AccountStorageScopeMount capturedMount;
      late MaasoAuthCandidate capturedCandidate;
      final lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        storageScopes: scopes,
        mountRuntime: (mount) async {
          capturedMount = mount;
          capturedCandidate = auth.candidate!;
          mounts++;
          expect(mount.scope.accountUuid, LocalTestAuthClient.accountUuid);
          expect(auth.session.value, isNull);
          expect(
            auth.candidate?.session.accountUuid,
            LocalTestAuthClient.accountUuid,
          );
          Future<String> mountToken() async => localMountAccessToken(
            auth: auth,
            candidate: capturedCandidate,
            mount: mount,
            scopes: scopes,
          );
          final local = LocalOriginalBackend(
            database: () => db,
            isCurrent: () => scopes.isCurrent(mount),
            origins: {environment.baseUri.origin},
          );
          addTearDown(local.close);
          final identity = IdentityHttpClient(
            baseUri: () => environment.baseUri,
            accountId: () => mount.scope.accountUuid,
            accessToken: mountToken,
            client: local,
          );
          expect(
            (await identity.fetch(
              expectedContextKey: identity.requestContextKey,
            )).completed,
            isTrue,
          );
          final profile = CompanionProfileHttpClient(
            baseUri: () => environment.baseUri,
            accountId: () => mount.scope.accountUuid,
            accessToken: mountToken,
            client: local,
          );
          expect(
            (await profile.fetch(
              expectedContextKey: profile.requestContextKey,
            )).completed,
            isTrue,
          );
          expect(auth.session.value, isNull);
          return _Lease(() => closed = true);
        },
      );
      appServices.put(lifecycle);
      expect(
        await lifecycle.authenticateAndMount(
          () => auth.loginCandidate(email: 'test', password: 'test123456'),
        ),
        isTrue,
      );
      expect(mounts, 1);
      expect(lifecycle.isMounted, isTrue);
      expect(lifecycle.canExecuteAgent, isTrue);
      expect(auth.session.value?.accountUuid, LocalTestAuthClient.accountUuid);
      expect(
        auth.hasCommittedSessionForEnvironment(environment.environment.value),
        isTrue,
      );
      expect(await auth.refresh(), isTrue);
      await lifecycle.signOutAndUnmount();
      expect(closed, isTrue);
      expect(lifecycle.isMounted, isFalse);
      expect(auth.session.value, isNull);
      expect(
        () => localMountAccessToken(
          auth: auth,
          candidate: capturedCandidate,
          mount: capturedMount,
          scopes: scopes,
        ),
        throwsStateError,
      );
      expect(await auth.restoreCandidate(), isFalse);
      expect(
        (storage as _MemoryStorage).values.values,
        isNot(contains(LocalTestAuthClient.accessMarker)),
      );
    },
  );

  test('local refresh rejects an unrelated account marker', () async {
    final client = LocalTestAuthClient();
    addTearDown(client.close);
    final response = await client.post(
      Uri.parse('https://never-contacted.invalid/v1/login/refresh'),
      body: jsonEncode({'refresh_token': 'different-session'}),
    );
    expect(response.statusCode, 401);
  });
}

class _Lease implements AccountRuntimeLease {
  _Lease(this.onClose);
  final void Function() onClose;
  @override
  Future<void> close() async => onClose();
}

class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    value == null ? values.remove(key) : values[key] = value;
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

class _LogoutStore implements AuthLogoutPendingStore {
  AuthLogoutPendingSnapshot state = const AuthLogoutPendingSnapshot(
    pending: false,
    revision: 1,
    token: 'local-test-cleared',
  );
  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async => state;
  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async => state = AuthLogoutPendingSnapshot(
    pending: true,
    revision: state.revision + 1,
    token: 'local-test-${state.revision + 1}',
    ownerFingerprint: ownerFingerprint,
  );
  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) async {
    if (!state.sameVersion(expected)) return null;
    return state = AuthLogoutPendingSnapshot(
      pending: false,
      revision: state.revision + 1,
      token: 'local-test-${state.revision + 1}',
    );
  }
}
