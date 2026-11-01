import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_credential_transaction_lock.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store_codec.dart';
import 'package:maaso/src/core/services/auth_logout_pending_store_io.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';

const _commitKey = 'maaso_session_record_commit_v2';
const _ownerKey = 'maaso_session_record_owner_v1';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(appServices.reset);

  test('candidate login stays private until explicitly published', () async {
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, _successfulLoginClient());

    await auth.loginCandidate(email: 'person@example.com', password: 'secret');

    expect(auth.candidate?.environment, MaasoEnvironment.test);
    expect(auth.candidate?.session.accountUuid, 'account-1');
    expect(auth.session.value, isNull);
    expect(storage.values[GlobalConstant.keyMaasoAccessToken], isNull);
    expect(storage.values['${_commitKey}_test'], startsWith('v2:'));

    final expected = auth.candidate;
    await auth.publishCandidate(expected);

    expect(auth.session.value?.accountUuid, 'account-1');
    expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-token');
    expect(storage.values[_commitKey], startsWith('v2:'));
  });

  test('restoreOrRefresh never publishes without a mounted session', () async {
    final auth = await _createAuth(
      _FaultInjectingSecureStorage(),
      _unexpectedHttpClient(),
    );

    expect(await auth.restoreOrRefresh(), isFalse);
    expect(auth.candidate, isNull);
    expect(auth.session.value, isNull);
  });

  test('partial scoped write never creates a candidate', () async {
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, _successfulLoginClient());
    storage.failWrites.add('${GlobalConstant.keyMaasoAccountUuid}_test');

    await expectLater(
      auth.loginCandidate(email: 'person@example.com', password: 'secret'),
      throwsA(isA<StateError>()),
    );

    expect(auth.candidate, isNull);
    expect(auth.session.value, isNull);
    expect(storage.values['${_commitKey}_test'], 'v2:invalid');
    for (final key in _credentialSecretKeys(environmentKey: 'test')) {
      expect(storage.values, isNot(contains(key)));
    }
  });

  test('partial active write never publishes a session', () async {
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, _successfulLoginClient());
    storage.failWrites.add(GlobalConstant.keyMaasoAccountUuid);

    await expectLater(
      auth.login(email: 'person@example.com', password: 'secret'),
      throwsA(isA<StateError>()),
    );

    expect(auth.candidate?.session.accountUuid, 'account-1');
    expect(auth.session.value, isNull);
    expect(storage.values[_commitKey], 'v2:invalid');
    expect(storage.values['${_commitKey}_test'], startsWith('v2:'));
    for (final key in _credentialSecretKeys()) {
      expect(storage.values, isNot(contains(key)));
    }
  });

  test(
    'failed partial-write rollback leaves a retryable durable tombstone',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: logoutPending,
      );
      storage.failWrites.add('${GlobalConstant.keyMaasoAccountUuid}_test');
      storage.failDeletes.add('${GlobalConstant.keyMaasoAccessToken}_test');

      await expectLater(
        auth.loginCandidate(email: 'person@example.com', password: 'secret'),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(auth.candidate, isNull);
      expect(auth.session.value, isNull);
      expect(await logoutPending.isPending('test'), isTrue);
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-token',
      );

      storage.failWrites.clear();
      storage.failDeletes.clear();
      await auth.retryCredentialCleanup();

      expect(await logoutPending.isPending('test'), isFalse);
      for (final key in _credentialSecretKeys(environmentKey: 'test')) {
        expect(storage.values, isNot(contains(key)));
      }
    },
  );

  test('commit digest mismatch fails closed', () async {
    final storage = _FaultInjectingSecureStorage();
    _seedScopedRecord(storage, marker: 'v2:not-the-record-digest');

    final auth = await _createAuth(storage, _unexpectedHttpClient());

    expect(auth.candidate, isNull);
    expect(auth.session.value, isNull);
  });

  test('markerless legacy record is invalidated instead of migrated', () async {
    final storage = _FaultInjectingSecureStorage();
    _seedScopedRecord(storage);

    final auth = await _createAuth(storage, _unexpectedHttpClient());

    expect(auth.candidate, isNull);
    expect(auth.session.value, isNull);
    expect(storage.values['${_commitKey}_test'], 'v2:invalid');
    expect(
      storage.values,
      isNot(contains('${GlobalConstant.keyMaasoAccessToken}_test')),
    );
  });

  test(
    'legacy owner upgrade failure remains retryable through lifecycle fault',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final missing = await logoutPending.read('test');
      await logoutPending.clearPending('test', expected: missing);
      final legacySession = MaasoAuthSession(
        accountUuid: 'legacy-account',
        accessToken: 'legacy-access',
        refreshToken: 'legacy-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
      _seedLegacyCommittedScopedRecord(storage, legacySession);
      storage.failWrites.add('${_ownerKey}_test');
      final auth = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        initialize: false,
      );
      final lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await expectLater(
        lifecycle.restoreAndMount(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(await logoutPending.isPending('test'), isFalse);

      storage.failWrites.clear();
      await lifecycle.retryFaultedCleanup();

      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(await logoutPending.isPending('test'), isFalse);
      _expectCredentialRecordCleared(storage, environmentKey: 'test');
      lifecycle.closeLifecycle();
    },
  );

  test(
    'transient restore read failure retries activation instead of logout',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final first = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: logoutPending,
      );
      await first.loginCandidate(
        email: 'person@example.com',
        password: 'secret',
      );

      await appServices.reset();
      appServices.testMode = true;
      storage.failReads.add('${_commitKey}_test');
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        initialize: false,
      );
      final lifecycle = AccountSessionLifecycleService(
        auth: restarted,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await expectLater(
        lifecycle.restoreAndMount(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);

      storage.failReads.clear();
      expect(restarted.requiresCredentialReauthentication, isFalse);
      await lifecycle.retryFaultedCleanup();
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(restarted.candidate?.session.accountUuid, 'account-1');
      expect(await logoutPending.isPending('test'), isFalse);
      expect(await lifecycle.mountCurrentSession(), isTrue);
      await lifecycle.unmount();
      lifecycle.closeLifecycle();
    },
  );

  test('sign-out recaptures owner after a transient pre-mark read', () async {
    final storage = _FaultInjectingSecureStorage();
    final logoutPending = _MemoryLogoutPendingStore();
    final auth = await _createAuth(
      storage,
      _successfulLoginClient(),
      logoutPendingStore: logoutPending,
    );
    await auth.login(email: 'person@example.com', password: 'secret');
    storage.failReads.add('${_commitKey}_test');

    await expectLater(
      auth.signOut(),
      throwsA(isA<AuthCredentialCleanupFailure>()),
    );
    expect(await logoutPending.isPending('test'), isFalse);

    storage.failReads.clear();
    await auth.retryCredentialCleanup();

    expect(await logoutPending.isPending('test'), isFalse);
    _expectCredentialRecordCleared(storage);
    _expectCredentialRecordCleared(storage, environmentKey: 'test');
  });

  test('delete false leaves markers invalid and session unpublished', () async {
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, _successfulLoginClient());
    await auth.login(email: 'person@example.com', password: 'secret');
    storage.failDeletes.addAll(<String>{
      GlobalConstant.keyMaasoAccessToken,
      '${GlobalConstant.keyMaasoAccessToken}_test',
    });

    await expectLater(
      auth.signOut(),
      throwsA(isA<AuthCredentialCleanupFailure>()),
    );

    expect(auth.session.value, isNull);
    expect(auth.candidate, isNull);
    expect(storage.values[_commitKey], 'v2:invalid');
    expect(storage.values['${_commitKey}_test'], 'v2:invalid');
  });

  test(
    'marker write false still removes payload and reports failure',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final auth = await _createAuth(storage, _successfulLoginClient());
      await auth.login(email: 'person@example.com', password: 'secret');
      storage.failWrites.addAll(<String>{_commitKey, '${_commitKey}_test'});

      await expectLater(
        auth.signOut(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(auth.session.value, isNull);
      expect(auth.candidate, isNull);
      for (final key in <String>[
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
      ]) {
        expect(storage.values, isNot(contains(key)));
        expect(storage.values, isNot(contains('${key}_test')));
      }
    },
  );

  test(
    'logout tombstone prevents restart from restoring an undeletable record',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final supportDirectory = await Directory.systemTemp.createTemp(
        'maaso-auth-restart-',
      );
      addTearDown(() async {
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      FileAuthLogoutPendingStore newLogoutPendingStore() =>
          FileAuthLogoutPendingStore(
            supportDirectory: () async => supportDirectory,
          );
      final logoutPending = newLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'person@example.com', password: 'secret');
      storage.failWrites.addAll(<String>{_commitKey, '${_commitKey}_test'});
      storage.failDeletes.addAll(<String>{
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
        '${GlobalConstant.keyMaasoAccessToken}_test',
        '${GlobalConstant.keyMaasoRefreshToken}_test',
        '${GlobalConstant.keyMaasoAccountUuid}_test',
        '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test',
      });

      await expectLater(
        auth.signOut(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect((await logoutPending.read('test')).pending, isTrue);
      expect(storage.values[_commitKey], startsWith('v2:'));
      expect(storage.values['${_commitKey}_test'], startsWith('v2:'));

      await appServices.reset();
      appServices.testMode = true;
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: newLogoutPendingStore(),
        initialize: false,
      );
      final lifecycle = AccountSessionLifecycleService(
        auth: restarted,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await expectLater(
        lifecycle.restoreAndMount(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );
      expect(restarted.session.value, isNull);
      expect(restarted.candidate, isNull);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect((await newLogoutPendingStore().read('test')).pending, isTrue);

      storage.failWrites.clear();
      storage.failDeletes.clear();
      await lifecycle.retryFaultedCleanup();
      await restarted.activateCurrentEnvironment();

      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect((await newLogoutPendingStore().read('test')).pending, isFalse);
      expect(storage.values[_commitKey], 'v2:invalid');
      expect(storage.values['${_commitKey}_test'], 'v2:invalid');
      for (final key in <String>[
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
      ]) {
        expect(storage.values, isNot(contains(key)));
        expect(storage.values, isNot(contains('${key}_test')));
      }
      lifecycle.closeLifecycle();
    },
  );

  test('fresh login clears tombstone only after scoped commit', () async {
    final storage = _FaultInjectingSecureStorage();
    final logoutPending = _MemoryLogoutPendingStore();
    final auth = await _createAuth(
      storage,
      _successfulLoginClient(),
      logoutPendingStore: logoutPending,
    );
    await auth.login(email: 'person@example.com', password: 'secret');
    storage.failWrites.addAll(<String>{_commitKey, '${_commitKey}_test'});
    storage.failDeletes.addAll(<String>{
      GlobalConstant.keyMaasoAccessToken,
      GlobalConstant.keyMaasoRefreshToken,
      GlobalConstant.keyMaasoAccountUuid,
      GlobalConstant.keyMaasoAccessTokenExpiresAt,
      '${GlobalConstant.keyMaasoAccessToken}_test',
      '${GlobalConstant.keyMaasoRefreshToken}_test',
      '${GlobalConstant.keyMaasoAccountUuid}_test',
      '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test',
    });
    await expectLater(
      auth.signOut(),
      throwsA(isA<AuthCredentialCleanupFailure>()),
    );
    expect(await logoutPending.isPending('test'), isTrue);

    storage.failWrites.clear();
    storage.failDeletes.clear();
    storage.failWrites.add('${GlobalConstant.keyMaasoAccountUuid}_test');
    await expectLater(
      auth.loginCandidate(email: 'person@example.com', password: 'secret'),
      throwsA(isA<StateError>()),
    );
    expect(await logoutPending.isPending('test'), isTrue);

    storage.failWrites.clear();
    await auth.loginCandidate(email: 'person@example.com', password: 'secret');
    expect(auth.candidate?.session.accountUuid, 'account-1');
    expect(await logoutPending.isPending('test'), isFalse);
  });

  test(
    'durable mark survives immediate process restart before secure deletion',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final supportDirectory = await Directory.systemTemp.createTemp(
        'maaso-auth-crash-',
      );
      addTearDown(() async {
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      FileAuthLogoutPendingStore newLogoutPendingStore() =>
          FileAuthLogoutPendingStore(
            supportDirectory: () async => supportDirectory,
          );

      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: newLogoutPendingStore(),
      );
      await auth.login(email: 'person@example.com', password: 'secret');

      final marked = await newLogoutPendingStore().markPending(
        'test',
        ownerFingerprint: _storedOwnerFingerprint(
          storage,
          environmentKey: 'test',
        ),
      );
      expect(marked.pending, isTrue);
      storage.failWrites.addAll(<String>{_commitKey, '${_commitKey}_test'});
      storage.failDeletes.addAll(<String>{
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
        '${GlobalConstant.keyMaasoAccessToken}_test',
        '${GlobalConstant.keyMaasoRefreshToken}_test',
        '${GlobalConstant.keyMaasoAccountUuid}_test',
        '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test',
      });

      // Simulate process death immediately after markPending returned: no
      // credential-deletion call is made by the first AuthSessionService.
      await appServices.reset();
      appServices.testMode = true;
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: newLogoutPendingStore(),
        initialize: false,
      );
      final lifecycle = AccountSessionLifecycleService(
        auth: restarted,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await expectLater(
        lifecycle.restoreAndMount(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );
      expect(restarted.session.value, isNull);
      expect(restarted.candidate, isNull);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect((await newLogoutPendingStore().read('test')).pending, isTrue);

      storage.failWrites.clear();
      storage.failDeletes.clear();
      await lifecycle.retryFaultedCleanup();
      expect((await newLogoutPendingStore().read('test')).pending, isFalse);
      lifecycle.closeLifecycle();
    },
  );

  test(
    'restart finishes active-only cleanup after scoped cleanup committed',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final supportDirectory = await Directory.systemTemp.createTemp(
        'maaso-auth-active-restart-',
      );
      addTearDown(() async {
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      FileAuthLogoutPendingStore newLogoutPendingStore() =>
          FileAuthLogoutPendingStore(
            supportDirectory: () async => supportDirectory,
          );

      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: newLogoutPendingStore(),
      );
      await auth.login(email: 'person@example.com', password: 'secret');
      final owner = _storedOwnerFingerprint(storage, environmentKey: 'test');
      storage.failWrites.add(_commitKey);
      storage.failDeletes.addAll(_credentialSecretKeys());

      await expectLater(
        auth.signOut(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(storage.values, isNot(contains('${_ownerKey}_test')));
      expect(storage.values[_ownerKey], isNotNull);
      expect(
        storage.values[GlobalConstant.keyMaasoAccessToken],
        'access-token',
      );
      final pending = await newLogoutPendingStore().read('test');
      expect(pending.pending, isTrue);
      expect(pending.ownerFingerprint, owner);

      // Simulate process death: only the durable fence and active owner
      // metadata remain available to a fresh AuthSessionService.
      storage.failWrites.clear();
      storage.failDeletes.clear();
      await appServices.reset();
      appServices.testMode = true;
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: newLogoutPendingStore(),
      );

      expect(restarted.session.value, isNull);
      expect(restarted.candidate, isNull);
      expect((await newLogoutPendingStore().read('test')).pending, isFalse);
      _expectCredentialRecordCleared(storage);
      _expectCredentialRecordCleared(storage, environmentKey: 'test');
    },
  );

  test('restart salvages owner from a partial pending fence slot', () async {
    final storage = _FaultInjectingSecureStorage();
    final supportDirectory = await Directory.systemTemp.createTemp(
      'maaso-auth-partial-fence-',
    );
    addTearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });
    FileAuthLogoutPendingStore newLogoutPendingStore() =>
        FileAuthLogoutPendingStore(
          supportDirectory: () async => supportDirectory,
        );

    final logoutPending = newLogoutPendingStore();
    final auth = await _createAuth(
      storage,
      _successfulLoginClient(),
      logoutPendingStore: logoutPending,
    );
    await auth.login(email: 'person@example.com', password: 'secret');
    final baseline = await logoutPending.read('test');
    final owner = _storedOwnerFingerprint(storage, environmentKey: 'test');
    final partialMark = AuthLogoutPendingRecord(
      environmentKey: 'test',
      revision: baseline.revision + 1,
      pending: true,
      token: 'partial-slot-mark',
      ownerFingerprint: owner,
    );
    await (await _fenceSlotFile(
      supportDirectory,
      0,
    )).writeAsString(partialMark.encode(), flush: true);
    _removeCredentialRecord(storage, environmentKey: 'test');

    final crashedFence = await newLogoutPendingStore().read('test');
    expect(crashedFence.pending, isTrue);
    expect(crashedFence.ownerFingerprint, owner);

    await appServices.reset();
    appServices.testMode = true;
    final restarted = await _createAuth(
      storage,
      _unexpectedHttpClient(),
      logoutPendingStore: newLogoutPendingStore(),
    );

    expect(restarted.candidate, isNull);
    _expectCredentialRecordCleared(storage);
    expect((await newLogoutPendingStore().read('test')).pending, isFalse);
  });

  test(
    'unknown partial fence owner preserves active credentials and stays faulted',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final supportDirectory = await Directory.systemTemp.createTemp(
        'maaso-auth-unknown-fence-',
      );
      addTearDown(() async {
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      FileAuthLogoutPendingStore newLogoutPendingStore() =>
          FileAuthLogoutPendingStore(
            supportDirectory: () async => supportDirectory,
          );

      final logoutPending = newLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'person@example.com', password: 'secret');
      await (await _fenceSlotFile(
        supportDirectory,
        0,
      )).writeAsString('{corrupt', flush: true);
      _removeCredentialRecord(storage, environmentKey: 'test');

      await appServices.reset();
      appServices.testMode = true;
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: newLogoutPendingStore(),
        initialize: false,
      );

      await expectLater(
        restarted.init(),
        throwsA(
          isA<AuthCredentialCleanupFailure>().having(
            (failure) => failure.cause,
            'cause',
            isA<AuthCredentialReauthenticationRequired>(),
          ),
        ),
      );
      expect(
        storage.values[GlobalConstant.keyMaasoAccessToken],
        'access-token',
      );
      expect(storage.values[_ownerKey], isNotNull);
      expect((await newLogoutPendingStore().read('test')).pending, isTrue);
    },
  );

  test(
    'fresh login supersedes credential-only startup fault after validation',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final legacyExpiresAt = DateTime.now().add(const Duration(hours: 2));
      storage.values.addAll(<String, String>{
        GlobalConstant.keyMaasoAccessToken: 'legacy-access',
        GlobalConstant.keyMaasoRefreshToken: 'legacy-refresh',
        GlobalConstant.keyMaasoAccountUuid: 'legacy-account',
        GlobalConstant.keyMaasoAccessTokenExpiresAt: legacyExpiresAt
            .toIso8601String(),
      });
      final logoutPending = _MemoryLogoutPendingStore();
      var requestCount = 0;
      final auth = await _createAuth(
        storage,
        MockClient((_) async {
          requestCount++;
          if (requestCount == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{'code': 'INVALID_CREDENTIALS'}),
              401,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return _authResponse(
            accountUuid: 'account-1',
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }),
        logoutPendingStore: logoutPending,
        initialize: false,
      );
      final lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await expectLater(
        lifecycle.restoreAndMount(),
        throwsA(
          isA<AuthCredentialCleanupFailure>().having(
            (failure) => failure.cause,
            'cause',
            isA<AuthCredentialReauthenticationRequired>(),
          ),
        ),
      );
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(requestCount, 0);
      expect(auth.requiresCredentialReauthentication, isTrue);
      appServices.put(lifecycle);
      final controller = appServices.put(LoginController());
      await Future<void>.delayed(Duration.zero);
      expect(controller.canRetryCredentialCleanup.value, isFalse);

      await expectLater(
        lifecycle.authenticateAndMount(
          () => auth.loginCandidate(
            email: 'person@example.com',
            password: 'wrong-password',
          ),
        ),
        throwsA(isA<StateError>()),
      );

      expect(requestCount, 1);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(
        storage.values[GlobalConstant.keyMaasoAccessToken],
        'legacy-access',
      );
      expect((await logoutPending.read('test')).pending, isTrue);
      expect(auth.requiresCredentialReauthentication, isTrue);
      final passwordError = auth.error.value;
      expect(passwordError, isNotNull);
      expect(controller.error.value, passwordError);
      expect(controller.canRetryCredentialCleanup.value, isFalse);

      // Navigating away releases the route-scoped controller. A new instance
      // still reads recovery guidance from the same retained credential lease,
      // even though the 401 has replaced lifecycle.error with a plain error.
      await appServices.delete<LoginController>();
      final recreatedController = appServices.put(LoginController());
      await Future<void>.delayed(Duration.zero);
      expect(recreatedController.canRetryCredentialCleanup.value, isFalse);
      expect(recreatedController.error.value, passwordError);
      final environment = appServices.find<AppEnvironmentService>();
      environment.environment.value = MaasoEnvironment.production;
      expect(auth.requiresCredentialReauthentication, isFalse);
      environment.environment.value = MaasoEnvironment.test;
      expect(auth.requiresCredentialReauthentication, isTrue);

      expect(
        await lifecycle.authenticateAndMount(
          () => auth.loginCandidate(
            email: 'person@example.com',
            password: 'correct-password',
          ),
        ),
        isTrue,
      );

      expect(requestCount, 2);
      expect(auth.requiresCredentialReauthentication, isFalse);
      expect(recreatedController.canRetryCredentialCleanup.value, isFalse);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.mounted);
      expect(auth.session.value?.accountUuid, 'account-1');
      expect(
        storage.values[GlobalConstant.keyMaasoAccessToken],
        'access-token',
      );
      expect((await logoutPending.read('test')).pending, isFalse);

      await lifecycle.unmount();
      lifecycle.closeLifecycle();
    },
  );

  test(
    'pending owner clears active A but preserves same-account scoped B',
    () async {
      var requestCount = 0;
      final client = MockClient((_) async {
        requestCount++;
        return _authResponse(
          accountUuid: 'shared-account',
          accessToken: requestCount == 1 ? 'access-a' : 'access-b',
          refreshToken: requestCount == 1 ? 'refresh-a' : 'refresh-b',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      });
      final storage = _FaultInjectingSecureStorage();
      final supportDirectory = await Directory.systemTemp.createTemp(
        'maaso-auth-owner-boundary-',
      );
      addTearDown(() async {
        if (await supportDirectory.exists()) {
          await supportDirectory.delete(recursive: true);
        }
      });
      FileAuthLogoutPendingStore newLogoutPendingStore() =>
          FileAuthLogoutPendingStore(
            supportDirectory: () async => supportDirectory,
          );

      final logoutPending = newLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        client,
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'a@example.com', password: 'secret');
      final ownerA = _storedOwnerFingerprint(storage, environmentKey: 'test');
      await auth.loginCandidate(email: 'b@example.com', password: 'secret');
      final ownerB = _storedOwnerFingerprint(storage, environmentKey: 'test');
      expect(ownerB, isNot(ownerA));
      await logoutPending.markPending('test', ownerFingerprint: ownerA);

      await appServices.reset();
      appServices.testMode = true;
      final restarted = await _createAuth(
        storage,
        _unexpectedHttpClient(),
        logoutPendingStore: newLogoutPendingStore(),
      );

      expect(restarted.candidate, isNull);
      _expectCredentialRecordCleared(storage);
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-b',
      );
      expect(_storedOwnerFingerprint(storage, environmentKey: 'test'), ownerB);
      expect((await newLogoutPendingStore().read('test')).pending, isFalse);

      await restarted.activateCurrentEnvironment();
      expect(restarted.candidate?.session.accountUuid, 'shared-account');
      expect(restarted.candidate?.session.accessToken, 'access-b');
    },
  );

  test(
    'refresh active partial write cleans new scoped and partial active records',
    () async {
      var requestCount = 0;
      final client = MockClient((_) async {
        requestCount++;
        return _authResponse(
          accountUuid: 'account-a',
          accessToken: requestCount == 1 ? 'access-old' : 'access-new',
          refreshToken: requestCount == 1 ? 'refresh-old' : 'refresh-new',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      });
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        client,
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'a@example.com', password: 'secret');
      final owner = _storedOwnerFingerprint(storage, environmentKey: 'test');
      storage.failWrites.add(GlobalConstant.keyMaasoAccountUuid);

      expect(await auth.refresh(), isFalse);
      await auth.waitForPendingCredentialCleanup();

      expect(requestCount, 2);
      expect(auth.session.value, isNull);
      expect(auth.candidate, isNull);
      expect(await logoutPending.isPending('test'), isFalse);
      _expectCredentialRecordCleared(storage);
      _expectCredentialRecordCleared(storage, environmentKey: 'test');
      expect(storage.values.values, isNot(contains(owner)));
    },
  );

  test('refresh account mismatch signs out instead of republishing', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      if (request.url.path == '/v1/login/email') {
        return _authResponse(
          accountUuid: 'account-b',
          accessToken: 'access-b',
          refreshToken: 'refresh-b',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 2)),
        );
      }
      expect(request.url.path, '/v1/login/refresh');
      return _authResponse(
        accountUuid: 'account-a',
        accessToken: 'access-a',
        refreshToken: 'refresh-a',
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
    });
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, client);
    await auth.login(email: 'person@example.com', password: 'secret');

    expect(await auth.refresh(), isFalse);
    await auth.waitForPendingCredentialCleanup();

    expect(requestCount, 2);
    expect(auth.session.value, isNull);
    expect(auth.candidate, isNull);
    expect(storage.values['${_commitKey}_test'], 'v2:invalid');
  });

  test(
    'deferred refresh cleanup reports its error and notifies an observer',
    () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        return _authResponse(
          accountUuid: requestCount == 1 ? 'account-a' : 'account-b',
          accessToken: requestCount == 1 ? 'access-a' : 'access-b',
          refreshToken: requestCount == 1 ? 'refresh-a' : 'refresh-b',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      });
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        client,
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'person@example.com', password: 'secret');
      storage.failWrites.addAll(<String>{_commitKey, '${_commitKey}_test'});
      storage.failDeletes.addAll(<String>{
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
        '${GlobalConstant.keyMaasoAccessToken}_test',
        '${GlobalConstant.keyMaasoRefreshToken}_test',
        '${GlobalConstant.keyMaasoAccountUuid}_test',
        '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test',
      });
      Object? observedError;
      auth.credentialCleanupFailureObserver = (failure) async {
        observedError = failure;
      };

      expect(await auth.refresh(), isFalse);
      await expectLater(
        auth.waitForPendingCredentialCleanup(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(observedError, isA<AuthCredentialCleanupFailure>());
      expect(await logoutPending.isPending('test'), isTrue);
      expect(auth.session.value, isNull);
      expect(auth.candidate, isNull);
    },
  );

  test('late account A refresh cannot overwrite account B', () async {
    final refreshStarted = Completer<void>();
    final releaseRefresh = Completer<void>();
    var loginCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/login/refresh') {
        refreshStarted.complete();
        await releaseRefresh.future;
        return _authResponse(
          accountUuid: 'account-a',
          accessToken: 'access-a-refreshed',
          refreshToken: 'refresh-a-refreshed',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      }
      expect(request.url.path, '/v1/login/email');
      loginCount++;
      final account = loginCount == 1 ? 'account-a' : 'account-b';
      return _authResponse(
        accountUuid: account,
        accessToken: 'access-$account',
        refreshToken: 'refresh-$account',
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
    });
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, client);
    await auth.login(email: 'a@example.com', password: 'secret');

    final lateRefresh = auth.refresh();
    await refreshStarted.future;
    await auth.unpublishSession();
    final environment = appServices.find<AppEnvironmentService>();
    await environment.setEnvironment(MaasoEnvironment.production);
    await auth.activateCurrentEnvironment();
    await auth.loginCandidate(email: 'b@example.com', password: 'secret');
    await auth.publishCandidate(auth.candidate);

    releaseRefresh.complete();
    expect(await lateRefresh, isFalse);

    expect(auth.candidate?.session.accountUuid, 'account-b');
    expect(auth.session.value?.accountUuid, 'account-b');
    expect(auth.session.value?.accessToken, 'access-account-b');
    expect(
      storage.values[GlobalConstant.keyMaasoAccessToken],
      'access-account-b',
    );
    expect(
      storage.values['${GlobalConstant.keyMaasoAccessToken}_prod'],
      'access-account-b',
    );
    expect(auth.error.value, isNull);
  });

  test(
    'late account A cleanup failure cannot fault a mounted account B',
    () async {
      var loginCount = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/login/refresh') {
          return _authResponse(
            accountUuid: 'account-mismatch',
            accessToken: 'access-mismatch',
            refreshToken: 'refresh-mismatch',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }
        expect(request.url.path, '/v1/login/email');
        loginCount++;
        final account = loginCount == 1 ? 'account-a' : 'account-b';
        return _authResponse(
          accountUuid: account,
          accessToken: 'access-$account',
          refreshToken: 'refresh-$account',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      });
      final storage = _FaultInjectingSecureStorage();
      final auth = await _createAuth(storage, client);
      final oldBoundaryStarted = Completer<void>();
      final releaseOldBoundary = Completer<void>();
      auth.beforeCredentialsCleared = () async {
        oldBoundaryStarted.complete();
        await releaseOldBoundary.future;
        throw StateError('account A boundary failed late');
      };
      var observedCleanupFailures = 0;
      auth.credentialCleanupFailureObserver = (_) async {
        observedCleanupFailures++;
      };
      final lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: appServices.find<AppEnvironmentService>(),
        mountRuntime: (_) async => _NoopAccountRuntimeLease(),
      );

      await lifecycle.authenticateAndMount(
        () => auth.loginCandidate(email: 'a@example.com', password: 'secret'),
      );
      expect(auth.session.value?.accountUuid, 'account-a');

      expect(await auth.refresh(), isFalse);
      await oldBoundaryStarted.future;
      await lifecycle.authenticateAndMount(
        () => auth.loginCandidate(email: 'b@example.com', password: 'secret'),
      );
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.mounted);
      expect(auth.session.value?.accountUuid, 'account-b');

      releaseOldBoundary.complete();
      await auth.waitForPendingCredentialCleanup();

      expect(observedCleanupFailures, 0);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.mounted);
      expect(lifecycle.activeScope?.accountUuid, 'account-b');
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(storage.values['${_commitKey}_test'], startsWith('v2:'));

      await lifecycle.unmount();
      lifecycle.closeLifecycle();
    },
  );

  test(
    'in-flight account A marker write cannot overwrite account B on restart',
    () async {
      var loginCount = 0;
      final accountBRequestServed = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.path == '/v1/login/refresh') {
          return _authResponse(
            accountUuid: 'account-mismatch',
            accessToken: 'access-mismatch',
            refreshToken: 'refresh-mismatch',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }
        expect(request.url.path, '/v1/login/email');
        loginCount++;
        final account = loginCount == 1 ? 'account-a' : 'account-b';
        if (account == 'account-b') accountBRequestServed.complete();
        return _authResponse(
          accountUuid: account,
          accessToken: 'access-$account',
          refreshToken: 'refresh-$account',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        );
      });
      final storage = _LateScopedMarkerSecureStorage();
      final logoutPending = _MemoryLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        client,
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'a@example.com', password: 'secret');

      storage.gateNextScopedInvalidWrite();
      expect(await auth.refresh(), isFalse);
      await storage.scopedInvalidWriteStarted.future;

      var accountBLoginCompleted = false;
      final accountBLogin = auth
          .login(email: 'b@example.com', password: 'secret')
          .whenComplete(() => accountBLoginCompleted = true);
      try {
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // The complete credential transaction is queued, including its
        // initial durable-fence read, until A's dispatched write returns.
        expect(accountBRequestServed.isCompleted, isFalse);
        expect(accountBLoginCompleted, isFalse);
      } finally {
        if (!storage.releaseScopedInvalidWrite.isCompleted) {
          storage.releaseScopedInvalidWrite.complete();
        }
      }
      await accountBRequestServed.future;
      await accountBLogin;
      await auth.waitForPendingCredentialCleanup();

      expect(auth.session.value?.accountUuid, 'account-b');
      expect(storage.values['${_commitKey}_test'], startsWith('v2:'));
      expect(storage.values['${_commitKey}_test'], isNot('v2:invalid'));

      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
      );
      await restarted.init();

      expect(restarted.candidate?.session.accountUuid, 'account-b');
      expect(restarted.candidate?.session.accessToken, 'access-account-b');
    },
  );

  test(
    'new login in a second instance supersedes an older gated logout',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      final authA = AuthSessionService(
        httpClient: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final authB = AuthSessionService(
        httpClient: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');
      final boundaryStarted = Completer<void>();
      final releaseBoundary = Completer<void>();
      authA.beforeCredentialsCleared = () async {
        boundaryStarted.complete();
        await releaseBoundary.future;
      };

      final signingOutA = authA.signOut();
      await boundaryStarted.future;
      try {
        await authB.login(email: 'b@example.com', password: 'secret');
      } finally {
        if (!releaseBoundary.isCompleted) releaseBoundary.complete();
      }
      await signingOutA;

      expect(authB.session.value?.accountUuid, 'account-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-b',
      );
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(await logoutPending.isPending('test'), isFalse);

      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate?.session.accountUuid, 'account-b');
      expect(restarted.candidate?.session.accessToken, 'access-b');
    },
  );

  test(
    'fresh owner with identical session values supersedes old cleanup',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      final fixedExpiry = DateTime.utc(2035, 1, 1);
      MockClient identicalSessionClient() => MockClient(
        (_) async => _authResponse(
          accountUuid: 'shared-account',
          accessToken: 'identical-access',
          refreshToken: 'identical-refresh',
          expiresAt: fixedExpiry,
        ),
      );
      final authA = AuthSessionService(
        httpClient: identicalSessionClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final authB = AuthSessionService(
        httpClient: identicalSessionClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');
      final ownerA = _storedOwnerFingerprint(storage, environmentKey: 'test');
      final boundaryStarted = Completer<void>();
      final releaseBoundary = Completer<void>();
      authA.beforeCredentialsCleared = () async {
        boundaryStarted.complete();
        await releaseBoundary.future;
      };

      final signingOutA = authA.signOut();
      await boundaryStarted.future;
      try {
        await authB.login(email: 'b@example.com', password: 'secret');
      } finally {
        if (!releaseBoundary.isCompleted) releaseBoundary.complete();
      }
      await signingOutA;

      final ownerB = _storedOwnerFingerprint(storage, environmentKey: 'test');
      expect(ownerB, isNot(ownerA));
      expect(_storedOwnerFingerprint(storage), ownerB);
      expect(authB.session.value?.accountUuid, 'shared-account');
      expect(authB.session.value?.accessToken, 'identical-access');
      expect(await logoutPending.isPending('test'), isFalse);

      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate?.session.accountUuid, 'shared-account');
      expect(restarted.candidate?.session.accessToken, 'identical-access');
      expect(_storedOwnerFingerprint(storage, environmentKey: 'test'), ownerB);
    },
  );

  test(
    'published owner cleanup preserves identical scoped fresh owner',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      final fixedExpiry = DateTime.utc(2035, 2, 1);
      MockClient identicalSessionClient() => MockClient(
        (_) async => _authResponse(
          accountUuid: 'shared-account',
          accessToken: 'same-access',
          refreshToken: 'same-refresh',
          expiresAt: fixedExpiry,
        ),
      );
      final authA = AuthSessionService(
        httpClient: identicalSessionClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final authB = AuthSessionService(
        httpClient: identicalSessionClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');
      final ownerA = _storedOwnerFingerprint(storage, environmentKey: 'test');
      await authB.loginCandidate(email: 'b@example.com', password: 'secret');
      final ownerB = _storedOwnerFingerprint(storage, environmentKey: 'test');
      expect(ownerB, isNot(ownerA));

      await authA.signOut();

      _expectCredentialRecordCleared(storage);
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'same-access',
      );
      expect(_storedOwnerFingerprint(storage, environmentKey: 'test'), ownerB);
      expect(await logoutPending.isPending('test'), isFalse);

      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate?.session.accountUuid, 'shared-account');
      expect(restarted.candidate?.session.accessToken, 'same-access');
    },
  );

  test(
    'activating another environment preserves the published active record',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final logoutPending = _MemoryLogoutPendingStore();
      final accountA = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.test,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      await accountA.auth.login(email: 'a@example.com', password: 'secret');

      final accountB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
      );
      await accountB.auth.activateCurrentEnvironment();

      expect(accountA.auth.session.value?.accountUuid, 'account-a');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-a');
      expect(storage.values[GlobalConstant.keyMaasoAccountUuid], 'account-a');
      expect(storage.values[_commitKey], startsWith('v2:'));
      expect(storage.values[_commitKey], isNot('v2:invalid'));
    },
  );

  test(
    'test logout cannot clear a production login from another instance',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final logoutPending = _MemoryLogoutPendingStore();
      final accountA = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.test,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      final accountB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      await accountA.auth.login(email: 'a@example.com', password: 'secret');
      final boundaryStarted = Completer<void>();
      final releaseBoundary = Completer<void>();
      accountA.auth.beforeCredentialsCleared = () async {
        boundaryStarted.complete();
        await releaseBoundary.future;
      };

      final signingOutA = accountA.auth.signOut();
      await boundaryStarted.future;
      try {
        await accountB.auth.login(email: 'b@example.com', password: 'secret');
      } finally {
        if (!releaseBoundary.isCompleted) releaseBoundary.complete();
      }
      await signingOutA;

      expect(accountB.auth.session.value?.accountUuid, 'account-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccountUuid], 'account-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_prod'],
        'access-b',
      );
      expect(
        storage.values,
        isNot(contains('${GlobalConstant.keyMaasoAccessToken}_test')),
      );
      expect(await logoutPending.isPending('test'), isFalse);

      final restartedB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
      );
      expect(restartedB.auth.candidate?.session.accountUuid, 'account-b');
      expect(restartedB.auth.candidate?.session.accessToken, 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
    },
  );

  test(
    'test logout still removes its scoped record after production publishes',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final logoutPending = _MemoryLogoutPendingStore();
      final accountA = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.test,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      final accountB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      await accountA.auth.login(email: 'a@example.com', password: 'secret');
      await accountB.auth.login(email: 'b@example.com', password: 'secret');

      await accountA.auth.signOut();

      expect(accountB.auth.session.value?.accountUuid, 'account-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccountUuid], 'account-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_prod'],
        'access-b',
      );
      expect(
        storage.values,
        isNot(contains('${GlobalConstant.keyMaasoAccessToken}_test')),
      );
      expect(await logoutPending.isPending('test'), isFalse);
    },
  );

  test(
    'test cleanup retry cannot clear a production login from another instance',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final logoutPending = _MemoryLogoutPendingStore();
      final accountA = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.test,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      final accountB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
      );
      await accountA.auth.login(email: 'a@example.com', password: 'secret');
      storage.failDeletes.add('${GlobalConstant.keyMaasoAccessToken}_test');
      await expectLater(
        accountA.auth.signOut(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );
      expect(await logoutPending.isPending('test'), isTrue);

      storage.failDeletes.clear();
      await accountB.auth.login(email: 'b@example.com', password: 'secret');
      await accountA.auth.retryCredentialCleanup();

      expect(accountB.auth.session.value?.accountUuid, 'account-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccountUuid], 'account-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_prod'],
        'access-b',
      );
      expect(
        storage.values,
        isNot(contains('${GlobalConstant.keyMaasoAccessToken}_test')),
      );
      expect(await logoutPending.isPending('test'), isFalse);

      final restartedB = await _createEnvironmentBoundAuth(
        environment: MaasoEnvironment.production,
        client: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
      );
      expect(restartedB.auth.candidate?.session.accountUuid, 'account-b');
      expect(restartedB.auth.candidate?.session.accessToken, 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
    },
  );

  test(
    'two auth instances serialize an already-dispatched secure mutation',
    () async {
      final storage = _LateScopedMarkerSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      final authA = AuthSessionService(
        httpClient: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final accountBRequestStarted = Completer<void>();
      final authB = AuthSessionService(
        httpClient: MockClient((_) async {
          accountBRequestStarted.complete();
          return _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');

      storage.gateNextScopedInvalidWrite();
      final signingOutA = authA.signOut();
      await storage.scopedInvalidWriteStarted.future;
      final loggingInB = authB.login(
        email: 'b@example.com',
        password: 'secret',
      );
      try {
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(accountBRequestStarted.isCompleted, isFalse);
      } finally {
        if (!storage.releaseScopedInvalidWrite.isCompleted) {
          storage.releaseScopedInvalidWrite.complete();
        }
      }
      await signingOutA;
      await loggingInB;

      expect(accountBRequestStarted.isCompleted, isTrue);
      expect(authB.session.value?.accountUuid, 'account-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-b',
      );
      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate?.session.accountUuid, 'account-b');
      expect(restarted.candidate?.session.accessToken, 'access-b');
    },
  );

  test('unpublish cannot clear another instance active session', () async {
    final storage = _FaultInjectingSecureStorage();
    appServices.put<SecureStorageService>(storage);
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    final logoutPending = _MemoryLogoutPendingStore();
    final authA = AuthSessionService(
      httpClient: MockClient(
        (_) async => _authResponse(
          accountUuid: 'account-a',
          accessToken: 'access-a',
          refreshToken: 'refresh-a',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ),
      logoutPendingStore: logoutPending,
      credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
    );
    final authB = AuthSessionService(
      httpClient: MockClient(
        (_) async => _authResponse(
          accountUuid: 'account-b',
          accessToken: 'access-b',
          refreshToken: 'refresh-b',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ),
      logoutPendingStore: logoutPending,
      credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
    );
    await authA.init();
    await authB.init();
    await authA.login(email: 'a@example.com', password: 'secret');
    await authB.login(email: 'b@example.com', password: 'secret');

    await authA.unpublishSession();

    expect(authA.session.value, isNull);
    expect(authB.session.value?.accountUuid, 'account-b');
    expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
    expect(storage.values[GlobalConstant.keyMaasoAccountUuid], 'account-b');
    expect(storage.values[_commitKey], startsWith('v2:'));
    expect(storage.values[_commitKey], isNot('v2:invalid'));
  });

  test(
    'late cross-instance refresh is superseded without cleaning new login',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      final refreshStarted = Completer<void>();
      final releaseRefresh = Completer<void>();
      final authA = AuthSessionService(
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/login/refresh') {
            refreshStarted.complete();
            await releaseRefresh.future;
            return _authResponse(
              accountUuid: 'account-a',
              accessToken: 'access-a-refreshed',
              refreshToken: 'refresh-a-refreshed',
              expiresAt: DateTime.now().add(const Duration(hours: 2)),
            );
          }
          return _authResponse(
            accountUuid: 'account-a',
            accessToken: 'access-a',
            refreshToken: 'refresh-a',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final authB = AuthSessionService(
        httpClient: MockClient(
          (_) async => _authResponse(
            accountUuid: 'account-b',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');
      var teardownCalls = 0;
      var observerCalls = 0;
      authA.beforeCredentialsCleared = () async => teardownCalls++;
      authA.credentialCleanupFailureObserver = (_) async => observerCalls++;

      final refreshingA = authA.refresh();
      await refreshStarted.future;
      await authB.login(email: 'b@example.com', password: 'secret');
      releaseRefresh.complete();

      expect(await refreshingA, isFalse);
      await authA.waitForPendingCredentialCleanup();
      expect(teardownCalls, 0);
      expect(observerCalls, 0);
      expect(authB.session.value?.accountUuid, 'account-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-b',
      );
      expect(await logoutPending.isPending('test'), isFalse);
    },
  );

  test(
    'partial refresh cleanup skips a newer same-account owner identity',
    () async {
      final storage = _FaultInjectingSecureStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final logoutPending = _MemoryLogoutPendingStore();
      var authARequestCount = 0;
      final authA = AuthSessionService(
        httpClient: MockClient((_) async {
          authARequestCount++;
          return _authResponse(
            accountUuid: 'shared-account',
            accessToken: authARequestCount == 1
                ? 'access-a-old'
                : 'access-a-refreshed',
            refreshToken: authARequestCount == 1
                ? 'refresh-a-old'
                : 'refresh-a-refreshed',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          );
        }),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      final authB = AuthSessionService(
        httpClient: MockClient(
          (_) async => _authResponse(
            accountUuid: 'shared-account',
            accessToken: 'access-b',
            refreshToken: 'refresh-b',
            expiresAt: DateTime.now().add(const Duration(hours: 2)),
          ),
        ),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await authA.init();
      await authB.init();
      await authA.login(email: 'a@example.com', password: 'secret');
      final ownerA = _storedOwnerFingerprint(storage, environmentKey: 'test');
      final boundaryStarted = Completer<void>();
      final releaseBoundary = Completer<void>();
      authA.beforeCredentialsCleared = () async {
        boundaryStarted.complete();
        await releaseBoundary.future;
      };
      storage.failWrites.add(GlobalConstant.keyMaasoAccountUuid);

      expect(await authA.refresh(), isFalse);
      await boundaryStarted.future;
      storage.failWrites.clear();
      try {
        await authB.login(email: 'b@example.com', password: 'secret');
      } finally {
        if (!releaseBoundary.isCompleted) releaseBoundary.complete();
      }
      await authA.waitForPendingCredentialCleanup();

      final ownerB = _storedOwnerFingerprint(storage, environmentKey: 'test');
      expect(ownerB, isNot(ownerA));
      expect(authB.session.value?.accountUuid, 'shared-account');
      expect(authB.session.value?.accessToken, 'access-b');
      expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
      expect(
        storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
        'access-b',
      );
      expect(await logoutPending.isPending('test'), isFalse);

      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate?.session.accountUuid, 'shared-account');
      expect(restarted.candidate?.session.accessToken, 'access-b');
    },
  );

  test('old cleanup retry cannot delete a newer instance login', () async {
    final storage = _FaultInjectingSecureStorage();
    appServices.put<SecureStorageService>(storage);
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    final logoutPending = _MemoryLogoutPendingStore();
    final authA = AuthSessionService(
      httpClient: MockClient(
        (_) async => _authResponse(
          accountUuid: 'account-a',
          accessToken: 'access-a',
          refreshToken: 'refresh-a',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ),
      logoutPendingStore: logoutPending,
      credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
    );
    final authB = AuthSessionService(
      httpClient: MockClient(
        (_) async => _authResponse(
          accountUuid: 'account-b',
          accessToken: 'access-b',
          refreshToken: 'refresh-b',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ),
      logoutPendingStore: logoutPending,
      credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
    );
    await authA.init();
    await authB.init();
    await authA.login(email: 'a@example.com', password: 'secret');
    storage.failDeletes.addAll(<String>{
      GlobalConstant.keyMaasoAccessToken,
      '${GlobalConstant.keyMaasoAccessToken}_test',
    });
    await expectLater(
      authA.signOut(),
      throwsA(isA<AuthCredentialCleanupFailure>()),
    );
    expect(await logoutPending.isPending('test'), isTrue);

    storage.failDeletes.clear();
    await authB.login(email: 'b@example.com', password: 'secret');
    await authA.retryCredentialCleanup();

    expect(authB.session.value?.accountUuid, 'account-b');
    expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-b');
    expect(
      storage.values['${GlobalConstant.keyMaasoAccessToken}_test'],
      'access-b',
    );
    expect(await logoutPending.isPending('test'), isFalse);
  });

  test(
    'failed logout fence mark still invalidates restorable credentials',
    () async {
      final storage = _FaultInjectingSecureStorage();
      final logoutPending = _FailingMarkLogoutPendingStore();
      final auth = await _createAuth(
        storage,
        _successfulLoginClient(),
        logoutPendingStore: logoutPending,
      );
      await auth.login(email: 'a@example.com', password: 'secret');
      logoutPending.failMark = true;

      await expectLater(
        auth.signOut(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(storage.values[_commitKey], 'v2:invalid');
      expect(storage.values['${_commitKey}_test'], 'v2:invalid');
      final restarted = AuthSessionService(
        httpClient: _unexpectedHttpClient(),
        logoutPendingStore: logoutPending,
        credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
      );
      await restarted.init();
      expect(restarted.candidate, isNull);
      expect(restarted.session.value, isNull);
    },
  );

  test('stale sign-out cleanup cannot delete a newer environment', () async {
    final hookStarted = Completer<void>();
    final releaseHook = Completer<void>();
    var loginCount = 0;
    final client = MockClient((request) async {
      loginCount++;
      final account = loginCount == 1 ? 'account-a' : 'account-b';
      return _authResponse(
        accountUuid: account,
        accessToken: 'access-$account',
        refreshToken: 'refresh-$account',
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
    });
    final storage = _FaultInjectingSecureStorage();
    final auth = await _createAuth(storage, client);
    await auth.login(email: 'a@example.com', password: 'secret');
    auth.beforeCredentialsCleared = () async {
      hookStarted.complete();
      await releaseHook.future;
    };

    final staleSignOut = auth.signOut();
    await hookStarted.future;
    final environment = appServices.find<AppEnvironmentService>();
    await environment.setEnvironment(MaasoEnvironment.production);
    await auth.activateCurrentEnvironment();
    await auth.loginCandidate(email: 'b@example.com', password: 'secret');
    await auth.publishCandidate(auth.candidate);
    releaseHook.complete();

    await expectLater(staleSignOut, throwsA(isA<Exception>()));
    expect(auth.session.value?.accountUuid, 'account-b');
    expect(auth.candidate?.session.accountUuid, 'account-b');
    expect(
      storage.values['${GlobalConstant.keyMaasoAccessToken}_prod'],
      'access-account-b',
    );
  });

  test('refresh failure waits for teardown without self-deadlock', () async {
    final teardownStarted = Completer<void>();
    final releaseTeardown = Completer<void>();
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return _authResponse(
        accountUuid: requestCount == 1 ? 'account-a' : 'account-b',
        accessToken: requestCount == 1 ? 'access-a' : 'access-b',
        refreshToken: requestCount == 1 ? 'refresh-a' : 'refresh-b',
        expiresAt: DateTime.now().add(const Duration(hours: 2)),
      );
    });
    final auth = await _createAuth(_FaultInjectingSecureStorage(), client);
    await auth.login(email: 'a@example.com', password: 'secret');
    auth.beforeCredentialsCleared = () async {
      teardownStarted.complete();
      await releaseTeardown.future;
    };

    final refreshing = auth.refresh();
    expect(await refreshing, isFalse);
    final cleanup = auth.waitForPendingCredentialCleanup();
    var cleanupCompleted = false;
    cleanup.whenComplete(() => cleanupCompleted = true);
    await teardownStarted.future;

    expect(auth.session.value, isNull);
    expect(auth.candidate, isNull);
    expect(cleanupCompleted, isFalse);
    releaseTeardown.complete();
    await cleanup;
    expect(cleanupCompleted, isTrue);
  });

  test('environment write failure does not publish the new value', () async {
    final storage = _FaultInjectingSecureStorage();
    appServices.put<SecureStorageService>(storage);
    final environment = AppEnvironmentService();
    await environment.init();
    storage.failWrites.add(GlobalConstant.keyMaasoEnvironment);

    await expectLater(
      environment.setEnvironment(MaasoEnvironment.production),
      throwsA(isA<StateError>()),
    );

    expect(environment.environment.value, MaasoEnvironment.test);
    expect(
      storage.values[GlobalConstant.keyMaasoEnvironment],
      isNot(MaasoEnvironment.production.key),
    );
  });

  test(
    'latest environment operation wins durable and reactive state',
    () async {
      final storage = _GatedEnvironmentStorage();
      appServices.put<SecureStorageService>(storage);
      final environment = AppEnvironmentService();
      await environment.init();

      final first = environment.setEnvironment(MaasoEnvironment.production);
      await storage.productionWriteStarted.future;
      final second = environment.setEnvironment(MaasoEnvironment.test);
      storage.releaseProductionWrite.complete();

      await expectLater(first, throwsA(isA<StateError>()));
      await second;
      expect(environment.environment.value, MaasoEnvironment.test);
      expect(
        storage.values[GlobalConstant.keyMaasoEnvironment],
        MaasoEnvironment.test.key,
      );
    },
  );
}

Future<({AppEnvironmentService environment, AuthSessionService auth})>
_createEnvironmentBoundAuth({
  required MaasoEnvironment environment,
  required http.Client client,
  required AuthLogoutPendingStore logoutPendingStore,
}) async {
  final environmentService = appServices.put<AppEnvironmentService>(
    AppEnvironmentService(),
    overrideAbstract: true,
  );
  await environmentService.init();
  if (environmentService.environment.value != environment) {
    await environmentService.setEnvironment(environment);
  }
  final auth = AuthSessionService(
    httpClient: client,
    logoutPendingStore: logoutPendingStore,
    credentialTransactionLock: InProcessAuthCredentialTransactionLock(),
  );
  await auth.init();
  return (environment: environmentService, auth: auth);
}

Future<AuthSessionService> _createAuth(
  SecureStorageService storage,
  http.Client client, {
  AuthLogoutPendingStore? logoutPendingStore,
  bool initialize = true,
}) async {
  appServices.put<SecureStorageService>(storage);
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: client,
      logoutPendingStore: logoutPendingStore ?? _MemoryLogoutPendingStore(),
    ),
  );
  if (initialize) await auth.init();
  return auth;
}

MockClient _successfulLoginClient() => MockClient((request) async {
  return _authResponse(
    accountUuid: 'account-1',
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(hours: 2)),
  );
});

MockClient _unexpectedHttpClient() => MockClient((request) async {
  throw StateError('Unexpected request: ${request.url}');
});

http.Response _authResponse({
  required String accountUuid,
  required String accessToken,
  required String refreshToken,
  required DateTime expiresAt,
}) => http.Response(
  jsonEncode(<String, Object?>{
    'code': 'OK',
    'data': <String, Object?>{
      'account_uuid': accountUuid,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt.toIso8601String(),
    },
  }),
  200,
  headers: const <String, String>{'content-type': 'application/json'},
);

void _seedScopedRecord(_FaultInjectingSecureStorage storage, {String? marker}) {
  storage.values.addAll(<String, String>{
    '${GlobalConstant.keyMaasoAccessToken}_test': 'legacy-access',
    '${GlobalConstant.keyMaasoRefreshToken}_test': 'legacy-refresh',
    '${GlobalConstant.keyMaasoAccountUuid}_test': 'legacy-account',
    '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test': DateTime.now()
        .add(const Duration(hours: 2))
        .toIso8601String(),
  });
  if (marker != null) storage.values['${_commitKey}_test'] = marker;
}

void _seedLegacyCommittedScopedRecord(
  _FaultInjectingSecureStorage storage,
  MaasoAuthSession session,
) {
  storage.values.addAll(<String, String>{
    '${GlobalConstant.keyMaasoAccessToken}_test': session.accessToken,
    '${GlobalConstant.keyMaasoRefreshToken}_test': session.refreshToken,
    '${GlobalConstant.keyMaasoAccountUuid}_test': session.accountUuid,
    '${GlobalConstant.keyMaasoAccessTokenExpiresAt}_test': session.expiresAt
        .toIso8601String(),
  });
  final canonical = jsonEncode(<String>[
    'environment:test',
    session.accountUuid,
    session.accessToken,
    session.refreshToken,
    session.expiresAt.toIso8601String(),
  ]);
  storage.values['${_commitKey}_test'] =
      'v2:${sha256.convert(utf8.encode(canonical))}';
}

String _storedOwnerFingerprint(
  _FaultInjectingSecureStorage storage, {
  String? environmentKey,
}) {
  final key = environmentKey == null
      ? _ownerKey
      : '${_ownerKey}_$environmentKey';
  final decoded = jsonDecode(storage.values[key]!) as Map<String, dynamic>;
  return decoded['owner']! as String;
}

Set<String> _credentialSecretKeys({String? environmentKey}) {
  final suffix = environmentKey == null ? '' : '_$environmentKey';
  return <String>{
    '${GlobalConstant.keyMaasoAccessToken}$suffix',
    '${GlobalConstant.keyMaasoRefreshToken}$suffix',
    '${GlobalConstant.keyMaasoAccountUuid}$suffix',
    '${GlobalConstant.keyMaasoAccessTokenExpiresAt}$suffix',
  };
}

void _removeCredentialRecord(
  _FaultInjectingSecureStorage storage, {
  String? environmentKey,
}) {
  final suffix = environmentKey == null ? '' : '_$environmentKey';
  for (final key in <String>{
    ..._credentialSecretKeys(environmentKey: environmentKey),
    '$_ownerKey$suffix',
    '$_commitKey$suffix',
  }) {
    storage.values.remove(key);
  }
}

void _expectCredentialRecordCleared(
  _FaultInjectingSecureStorage storage, {
  String? environmentKey,
}) {
  final suffix = environmentKey == null ? '' : '_$environmentKey';
  for (final key in <String>{
    ..._credentialSecretKeys(environmentKey: environmentKey),
    '$_ownerKey$suffix',
  }) {
    expect(storage.values, isNot(contains(key)), reason: key);
  }
  expect(storage.values['$_commitKey$suffix'], 'v2:invalid');
}

Future<File> _fenceSlotFile(Directory supportDirectory, int slot) async {
  final fenceDirectory = Directory(
    '${supportDirectory.path}/auth_logout_fence_v1',
  );
  final files = await fenceDirectory
      .list()
      .where((entity) => entity is File && entity.path.endsWith('.$slot.fence'))
      .cast<File>()
      .toList();
  expect(files, hasLength(1));
  return files.single;
}

class _FaultInjectingSecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};
  final Set<String> failWrites = <String>{};
  final Set<String> failDeletes = <String>{};
  final Set<String> failReads = <String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (failWrites.contains(key)) return false;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> readPlatformValue(String key) async {
    if (failReads.contains(key)) {
      throw StateError('Secure credential read failed for $key.');
    }
    return values[key];
  }

  @override
  Future<bool> delete(String key) async {
    if (failDeletes.contains(key)) return false;
    values.remove(key);
    return true;
  }
}

class _MemoryLogoutPendingStore implements AuthLogoutPendingStore {
  final Map<String, AuthLogoutPendingSnapshot> states =
      <String, AuthLogoutPendingSnapshot>{};

  Future<bool> isPending(String environmentKey) async =>
      (await read(environmentKey)).pending;

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async =>
      states[environmentKey] ??
      const AuthLogoutPendingSnapshot(
        pending: true,
        revision: 0,
        token: 'test-missing',
      );

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async {
    final current = await read(environmentKey);
    final next = AuthLogoutPendingSnapshot(
      pending: true,
      revision: current.revision + 1,
      token: 'test-${current.revision + 1}-pending',
      ownerFingerprint: ownerFingerprint,
    );
    states[environmentKey] = next;
    return next;
  }

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) async {
    final current = await read(environmentKey);
    if (!current.sameVersion(expected)) return null;
    final next = AuthLogoutPendingSnapshot(
      pending: false,
      revision: current.revision + 1,
      token: 'test-${current.revision + 1}-cleared',
    );
    states[environmentKey] = next;
    return next;
  }
}

class _FailingMarkLogoutPendingStore extends _MemoryLogoutPendingStore {
  bool failMark = false;

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) {
    if (failMark) throw StateError('logout fence mark failed');
    return super.markPending(
      environmentKey,
      ownerFingerprint: ownerFingerprint,
    );
  }
}

class _NoopAccountRuntimeLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
}

class _GatedEnvironmentStorage extends _FaultInjectingSecureStorage {
  final productionWriteStarted = Completer<void>();
  final releaseProductionWrite = Completer<void>();

  @override
  Future<bool> write(String key, String? value) async {
    if (key == GlobalConstant.keyMaasoEnvironment &&
        value == MaasoEnvironment.production.key) {
      productionWriteStarted.complete();
      await releaseProductionWrite.future;
    }
    return super.write(key, value);
  }
}

class _LateScopedMarkerSecureStorage extends _FaultInjectingSecureStorage {
  final scopedInvalidWriteStarted = Completer<void>();
  final releaseScopedInvalidWrite = Completer<void>();
  bool _gateScopedInvalidWrite = false;

  void gateNextScopedInvalidWrite() {
    _gateScopedInvalidWrite = true;
  }

  @override
  Future<bool> write(String key, String? value) async {
    if (_gateScopedInvalidWrite &&
        key == '${_commitKey}_test' &&
        value == 'v2:invalid') {
      _gateScopedInvalidWrite = false;
      scopedInvalidWriteStarted.complete();
      await releaseScopedInvalidWrite.future;
    }
    return super.write(key, value);
  }
}
