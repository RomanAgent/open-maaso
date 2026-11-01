import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';

void main() {
  late _MemorySecureStorageService storage;
  late AppEnvironmentService environment;
  late _TestAuthSessionService auth;
  AccountSessionLifecycleService? lifecycle;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    storage = _MemorySecureStorageService();
    appServices.put<SecureStorageService>(storage);
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    auth = appServices.put(_TestAuthSessionService());
  });

  tearDown(() async {
    final current = lifecycle;
    if (current != null) {
      try {
        await current.unmount();
      } catch (_) {
        // Individual failure tests make the retry path succeed before teardown.
      }
      current.closeLifecycle();
    }
    await appServices.reset();
  });

  test('account boundary callbacks must be configured as a pair', () {
    AccountSessionLifecycleService build({
      AccountRuntimeBoundaryActivateCallback? activate,
      AccountRuntimeBoundaryRetireCallback? retire,
    }) => AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      activateRuntimeBoundary: activate,
      retireRuntimeBoundary: retire,
      mountRuntime: (_) async => _TestLease(),
    );

    expect(() => build(activate: (_) {}), throwsArgumentError);
    expect(() => build(retire: (_) {}), throwsArgumentError);
  });

  test(
    'captured deletion cannot sign out an account mounted earlier in the queue',
    () async {
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(),
      );
      await lifecycle!.authenticateAndMount(
        () async => auth.stage(_session('account-a')),
      );
      final oldScope = lifecycle!.activeScope!;
      final replacement = lifecycle!.authenticateAndMount(
        () async => auth.stage(_session('account-b')),
      );
      var erased = false;
      final cleanup = lifecycle!.signOutAndUnmount(
        expectedScope: oldScope,
        afterSignOut: () async {
          erased = true;
        },
      );
      await expectLater(cleanup, throwsStateError);
      expect(await replacement, isTrue);
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(lifecycle!.activeScope?.accountUuid, 'account-b');
      expect(erased, isFalse);
    },
  );

  test(
    'account erasure runs after teardown and keeps a queued login waiting',
    () async {
      var closed = false;
      final eraseStarted = Completer<void>(), eraseDone = Completer<void>();
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(
          onClose: () async {
            closed = true;
          },
        ),
      );
      await lifecycle!.authenticateAndMount(
        () async => auth.stage(_session('account-a')),
      );
      final scope = lifecycle!.activeScope!;
      final cleanup = lifecycle!.signOutAndUnmount(
        expectedScope: scope,
        afterSignOut: () async {
          expect(closed, isTrue);
          expect(auth.session.value, isNull);
          eraseStarted.complete();
          await eraseDone.future;
        },
      );
      await eraseStarted.future;
      var newLoginStarted = false;
      final next = lifecycle!.authenticateAndMount(() async {
        newLoginStarted = true;
        auth.stage(_session('account-b'));
      });
      await _flushEventQueue();
      expect(newLoginStarted, isFalse);
      eraseDone.complete();
      await cleanup;
      expect(await next, isTrue);
    },
  );

  test('authenticate publishes a runtime only after mount is ready', () async {
    final mountReady = Completer<AccountRuntimeLease>();
    AccountStorageScopeMount? observedMount;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (mount) {
        observedMount = mount;
        return mountReady.future;
      },
    );

    final result = lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });
    await _flushEventQueue();

    expect(observedMount?.scope.accountUuid, 'account-a');
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.mounting);
    expect(lifecycle!.isMounted, isFalse);
    expect(lifecycle!.activeScope, isNull);
    expect(auth.session.value, isNull);

    mountReady.complete(_TestLease());

    expect(await result, isTrue);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.mounted);
    expect(lifecycle!.activeScope?.accountUuid, 'account-a');
    expect(auth.session.value?.accountUuid, 'account-a');
  });

  test(
    'account boundary activates before runtime and retires before close',
    () async {
      final snapshots = AppCapabilitySnapshotService(
        resolver: AppPlatformCapabilitySnapshotResolver(
          routeIds: const <String>{},
        ),
        initialContext: AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
      );
      addTearDown(snapshots.closeLifecycle);
      AccountStorageScopeMount? runtimeMount;
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        activateRuntimeBoundary: (mount) {
          snapshots.activateAccount(
            accountScopeDigest: mount.scope.accountDigest,
            accountGeneration: mount.generation,
          );
        },
        retireRuntimeBoundary: (accountGeneration) =>
            snapshots.deactivateAccount(accountGeneration: accountGeneration),
        mountRuntime: (mount) async {
          runtimeMount = mount;
          expect(
            snapshots.context.accountScopeDigest,
            mount.scope.accountDigest,
          );
          expect(snapshots.context.accountGeneration, mount.generation);
          return _TestLease(
            onClose: () async {
              expect(snapshots.context.accountScopeDigest, isNull);
              expect(snapshots.context.accountGeneration, isNull);
            },
          );
        },
      );

      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });

      expect(runtimeMount, isNotNull);
      expect(snapshots.context.accountScopeDigest, isNot('account-a'));
      expect(snapshots.context.accountGeneration, runtimeMount!.generation);

      await lifecycle!.unmount();

      expect(snapshots.context.accountScopeDigest, isNull);
      expect(snapshots.context.accountGeneration, isNull);
    },
  );

  test('failed runtime mount retires the exact activated generation', () async {
    int? activatedGeneration;
    final retiredGenerations = <int>[];
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      activateRuntimeBoundary: (mount) {
        activatedGeneration = mount.generation;
      },
      retireRuntimeBoundary: retiredGenerations.add,
      mountRuntime: (_) async => throw StateError('mount failed'),
    );

    await expectLater(
      lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      }),
      throwsA(isA<StateError>()),
    );

    expect(activatedGeneration, isNotNull);
    expect(retiredGenerations, <int>[activatedGeneration!]);
    expect(lifecycle!.storageScopes.isMounted, isFalse);
  });

  test('closeLifecycle retires an active generation exactly once', () async {
    int? activatedGeneration;
    final retiredGenerations = <int>[];
    final runtime = _TestLease();
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      activateRuntimeBoundary: (mount) {
        activatedGeneration = mount.generation;
      },
      retireRuntimeBoundary: retiredGenerations.add,
      mountRuntime: (_) async => runtime,
    );
    await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });
    final current = lifecycle!;
    final mount = current.activeMount!;

    current.closeLifecycle();
    current.closeLifecycle();

    expect(activatedGeneration, mount.generation);
    expect(retiredGenerations, <int>[mount.generation]);

    lifecycle = null;
    if (current.storageScopes.isCurrent(mount)) {
      current.storageScopes.unmount(mount);
    }
    await runtime.close();
    await auth.unpublishSession();
  });

  test(
    'closeLifecycle fences an in-flight mount without reviving its phase',
    () async {
      final runtimeStarted = Completer<void>();
      final runtimeReady = Completer<AccountRuntimeLease>();
      final runtime = _TestLease();
      int? activatedGeneration;
      final retiredGenerations = <int>[];
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        activateRuntimeBoundary: (mount) {
          activatedGeneration = mount.generation;
        },
        retireRuntimeBoundary: retiredGenerations.add,
        mountRuntime: (_) {
          runtimeStarted.complete();
          return runtimeReady.future;
        },
      );
      final current = lifecycle!;
      final mounting = current.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });
      await runtimeStarted.future;

      current.closeLifecycle();
      current.closeLifecycle();

      expect(current.phase.value, AccountSessionLifecyclePhase.closed);
      expect(current.storageScopes.isMounted, isFalse);
      expect(retiredGenerations, <int>[activatedGeneration!]);

      runtimeReady.complete(runtime);
      await expectLater(mounting, throwsStateError);

      expect(current.phase.value, AccountSessionLifecyclePhase.closed);
      expect(current.isMounted, isFalse);
      expect(runtime.closeCalls, 1);
      expect(retiredGenerations, <int>[activatedGeneration!]);
      lifecycle = null;
    },
  );

  test(
    'closeLifecycle cannot activate while waiting for a privacy boundary',
    () async {
      final scopes = AccountStorageScopeService();
      final oldMount = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'old-account'),
      );
      final boundaryHold = scopes.acquireBoundaryHold(oldMount);
      scopes.unmount(oldMount);
      var activationCalls = 0;
      var retirementCalls = 0;
      var runtimeMountCalls = 0;
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        storageScopes: scopes,
        activateRuntimeBoundary: (_) => activationCalls++,
        retireRuntimeBoundary: (_) => retirementCalls++,
        mountRuntime: (_) async {
          runtimeMountCalls++;
          return _TestLease();
        },
      );
      final current = lifecycle!;
      final mounting = current.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });
      await _flushEventQueue();

      expect(current.phase.value, AccountSessionLifecyclePhase.mounting);
      expect(scopes.isMounted, isFalse);
      expect(activationCalls, 0);

      current.closeLifecycle();
      boundaryHold.release();
      await expectLater(mounting, throwsStateError);

      expect(current.phase.value, AccountSessionLifecyclePhase.closed);
      expect(scopes.isMounted, isFalse);
      expect(activationCalls, 0);
      expect(retirementCalls, 0);
      expect(runtimeMountCalls, 0);
      lifecycle = null;
    },
  );

  test('unmount fences the generation before awaiting lease close', () async {
    final closeStarted = Completer<void>();
    final closeAllowed = Completer<void>();
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async => _TestLease(
        onClose: () async {
          closeStarted.complete();
          await closeAllowed.future;
        },
      ),
    );
    await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });
    final mountedToken = lifecycle!.activeMount!;
    final mountedGeneration = lifecycle!.generation;

    final unmount = lifecycle!.unmount();
    await closeStarted.future;

    expect(lifecycle!.isMounted, isFalse);
    expect(lifecycle!.activeMount, isNull);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.retiring);
    expect(lifecycle!.storageScopes.isCurrent(mountedToken), isFalse);
    expect(lifecycle!.generation, greaterThan(mountedGeneration));
    expect(auth.session.value, isNull);

    closeAllowed.complete();
    await unmount;
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test(
    'unmount waits for sensitive root UI dismissal before runtime close',
    () async {
      final lease = _TestLease();
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => lease,
      );
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });
      final mount = lifecycle!.activeMount!;
      final hold = lifecycle!.storageScopes.acquireBoundaryHold(mount);
      var unmountCompleted = false;

      final unmount = lifecycle!.unmount().then((_) {
        unmountCompleted = true;
      });
      await mount.whenInvalidated;
      await _flushEventQueue();

      expect(lifecycle!.storageScopes.isCurrent(mount), isFalse);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.retiring);
      expect(lease.closeCalls, 0);
      expect(unmountCompleted, isFalse);

      hold.release();
      await unmount;

      expect(lease.closeCalls, 1);
      expect(unmountCompleted, isTrue);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );

  test(
    'failed close faults and blocks replacement until close retry',
    () async {
      var closeAttempts = 0;
      var accountBAuthenticationStarted = false;
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(
          onClose: () async {
            closeAttempts++;
            if (closeAttempts == 1) throw StateError('close failed');
          },
        ),
      );
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });

      await expectLater(
        lifecycle!.authenticateAndMount(() async {
          accountBAuthenticationStarted = true;
          auth.stage(_session('account-b'));
        }),
        throwsA(isA<StateError>()),
      );

      expect(accountBAuthenticationStarted, isFalse);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(lifecycle!.isFaulted, isTrue);
      expect(lifecycle!.isMounted, isFalse);
      expect(lifecycle!.storageScopes.isMounted, isFalse);
      expect(lifecycle!.error.value, isA<StateError>());

      await lifecycle!.unmount();
      expect(closeAttempts, 2);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);

      expect(
        await lifecycle!.authenticateAndMount(() async {
          accountBAuthenticationStarted = true;
          auth.stage(_session('account-b'));
        }),
        isTrue,
      );
      expect(accountBAuthenticationStarted, isTrue);
      expect(lifecycle!.activeScope?.accountUuid, 'account-b');
    },
  );

  test(
    'projection failure still closes runtime and retry only retries projection',
    () async {
      final runtimeLease = _TestLease();
      auth.unpublishFailuresRemaining = 1;
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => runtimeLease,
      );
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });

      await expectLater(
        lifecycle!.unmount(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'unpublish failed',
          ),
        ),
      );

      expect(auth.unpublishCount, 1);
      expect(runtimeLease.closeCalls, 1);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.faulted);

      await lifecycle!.unmount();

      expect(auth.unpublishCount, 2);
      expect(runtimeLease.closeCalls, 1);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );

  test('both teardown failures remain independently retryable', () async {
    var runtimeFailuresRemaining = 1;
    final runtimeLease = _TestLease(
      onClose: () async {
        if (runtimeFailuresRemaining > 0) {
          runtimeFailuresRemaining--;
          throw StateError('runtime close failed');
        }
      },
    );
    auth.unpublishFailuresRemaining = 1;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async => runtimeLease,
    );
    await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });

    await expectLater(
      lifecycle!.unmount(),
      throwsA(
        isA<AccountRuntimeTeardownFailure>()
            .having(
              (failure) => failure.projectionError.toString(),
              'projection error',
              contains('unpublish failed'),
            )
            .having(
              (failure) => failure.runtimeError.toString(),
              'runtime error',
              contains('runtime close failed'),
            ),
      ),
    );

    expect(auth.unpublishCount, 1);
    expect(runtimeLease.closeCalls, 1);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.faulted);

    await lifecycle!.unmount();

    expect(auth.unpublishCount, 2);
    expect(runtimeLease.closeCalls, 2);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test('mount callback failure releases its storage mount', () async {
    var failMount = true;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async {
        if (failMount) throw StateError('mount failed');
        return _TestLease();
      },
    );

    await expectLater(
      lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      }),
      throwsA(isA<StateError>()),
    );

    expect(lifecycle!.isMounted, isFalse);
    expect(lifecycle!.storageScopes.isMounted, isFalse);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);

    failMount = false;
    expect(
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-b'));
      }),
      isTrue,
    );
    expect(lifecycle!.activeScope?.accountUuid, 'account-b');
  });

  test(
    'unfinished mount rollback faults until its cleanup lease retries',
    () async {
      var closeAttempts = 1;
      final cleanupLease = _TestLease(
        onClose: () async {
          closeAttempts++;
        },
      );
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async {
          throw AccountRuntimeMountFailure(
            cause: StateError('mount failed'),
            causeStackTrace: StackTrace.current,
            cleanupLease: cleanupLease,
            cleanupError: StateError('first cleanup failed'),
            cleanupStackTrace: StackTrace.current,
          );
        },
      );

      await expectLater(
        lifecycle!.authenticateAndMount(() async {
          auth.stage(_session('account-a'));
        }),
        throwsA(isA<AccountRuntimeMountFailure>()),
      );

      expect(lifecycle!.isFaulted, isTrue);
      expect(lifecycle!.storageScopes.isMounted, isFalse);
      expect(closeAttempts, 1);

      await lifecycle!.unmount();
      expect(closeAttempts, 2);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );

  test('blank account identity fails closed without mounting', () async {
    var mountCalls = 0;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async {
        mountCalls++;
        return _TestLease();
      },
    );

    final mounted = await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('   '));
    });

    expect(mounted, isFalse);
    expect(mountCalls, 0);
    expect(auth.session.value, isNull);
    expect(lifecycle!.isMounted, isFalse);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test('a published session without a candidate cannot bypass mount', () async {
    var mountCalls = 0;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async {
        mountCalls++;
        return _TestLease();
      },
    );
    auth.session.value = _session('account-a');

    expect(await lifecycle!.mountCurrentSession(), isFalse);

    expect(mountCalls, 0);
    expect(auth.session.value, isNull);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test('environment switch closes first and never mounts implicitly', () async {
    final closeStarted = Completer<void>();
    final closeAllowed = Completer<void>();
    var mountCalls = 0;
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async {
        mountCalls++;
        return _TestLease(
          onClose: () async {
            closeStarted.complete();
            await closeAllowed.future;
          },
        );
      },
    );
    await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });

    final switching = lifecycle!.switchEnvironment(MaasoEnvironment.production);
    await closeStarted.future;

    expect(environment.environment.value, MaasoEnvironment.test);
    expect(auth.activationCount, 0);
    expect(lifecycle!.isMounted, isFalse);

    closeAllowed.complete();
    await switching;

    expect(environment.environment.value, MaasoEnvironment.production);
    expect(auth.activationCount, 1);
    expect(mountCalls, 1);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test('direct auth sign-out awaits the account runtime boundary', () async {
    final closeStarted = Completer<void>();
    final closeAllowed = Completer<void>();
    lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async => _TestLease(
        onClose: () async {
          closeStarted.complete();
          await closeAllowed.future;
        },
      ),
    );
    await lifecycle!.authenticateAndMount(() async {
      auth.stage(_session('account-a'));
    });

    final signingOut = auth.signOut();
    await closeStarted.future;

    expect(lifecycle!.isMounted, isFalse);
    expect(auth.session.value, isNull);

    closeAllowed.complete();
    await signingOut;
    expect(auth.session.value, isNull);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
  });

  test(
    'sign-out clears credentials but reports a runtime teardown failure',
    () async {
      var closeAttempts = 0;
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(
          onClose: () async {
            closeAttempts++;
            if (closeAttempts == 1) throw StateError('close failed');
          },
        ),
      );
      final accountSession = _session('account-a');
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(accountSession);
      });
      final credentialKeys = <String>{
        GlobalConstant.keyMaasoAccessToken,
        GlobalConstant.keyMaasoRefreshToken,
        GlobalConstant.keyMaasoAccountUuid,
        GlobalConstant.keyMaasoAccessTokenExpiresAt,
      };
      final environmentKey = environment.environment.value.key;
      _seedCommittedCredentialRecords(
        storage,
        accountSession,
        environmentKey: environmentKey,
      );

      await expectLater(
        lifecycle!.signOutAndUnmount(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'close failed',
          ),
        ),
      );

      expect(auth.session.value, isNull);
      for (final key in credentialKeys) {
        expect(storage.values, isNot(contains(key)));
        expect(storage.values, isNot(contains('${key}_$environmentKey')));
      }
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(lifecycle!.isMounted, isFalse);
      expect(lifecycle!.storageScopes.isMounted, isFalse);

      await lifecycle!.unmount();
      expect(closeAttempts, 2);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );

  test(
    'credential cleanup failure stays faulted until retry succeeds',
    () async {
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(),
      );
      final accountSession = _session('account-a');
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(accountSession);
      });
      _seedCommittedCredentialRecords(
        storage,
        accountSession,
        environmentKey: environment.environment.value.key,
      );
      storage.failDeletes = true;

      await expectLater(
        lifecycle!.signOutAndUnmount(),
        throwsA(isA<AuthCredentialCleanupFailure>()),
      );

      expect(auth.session.value, isNull);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.faulted);

      storage.failDeletes = false;
      await lifecycle!.unmount();
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );

  test(
    'non-credential sign-out boundary error does not retain cleanup fault',
    () async {
      auth.beforeCredentialsCleared = () async {
        throw StateError('external boundary failed');
      };
      lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestLease(),
      );
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(_session('account-a'));
      });

      await expectLater(
        lifecycle!.signOutAndUnmount(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'external boundary failed',
          ),
        ),
      );

      expect(auth.session.value, isNull);
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(lifecycle!.isMounted, isFalse);

      await lifecycle!.retryFaultedCleanup();
      expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.signedOut);
    },
  );
}

Future<void> _flushEventQueue() => Future<void>.delayed(Duration.zero);

MaasoAuthSession _session(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(hours: 2)),
);

void _seedCommittedCredentialRecords(
  _MemorySecureStorageService storage,
  MaasoAuthSession session, {
  required String environmentKey,
}) {
  const ownerFingerprint =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final ownerBody = <String, Object>{
    'environment': environmentKey,
    'owner': ownerFingerprint,
    'schema': 1,
  };
  final encodedOwner = jsonEncode(<String, Object>{
    ...ownerBody,
    'checksum': sha256.convert(utf8.encode(jsonEncode(ownerBody))).toString(),
  });
  final credentialValues = <String, String>{
    GlobalConstant.keyMaasoAccessToken: session.accessToken,
    GlobalConstant.keyMaasoRefreshToken: session.refreshToken,
    GlobalConstant.keyMaasoAccountUuid: session.accountUuid,
    GlobalConstant.keyMaasoAccessTokenExpiresAt: session.expiresAt
        .toIso8601String(),
  };
  for (final entry in credentialValues.entries) {
    storage.values[entry.key] = entry.value;
    storage.values['${entry.key}_$environmentKey'] = entry.value;
  }
  storage.values['maaso_session_record_owner_v1'] = encodedOwner;
  storage.values['maaso_session_record_owner_v1_$environmentKey'] =
      encodedOwner;
  storage.values['maaso_session_record_commit_v2'] = _sessionCommit(
    'active',
    session,
    environmentKey: environmentKey,
    ownerFingerprint: ownerFingerprint,
  );
  storage.values['maaso_session_record_commit_v2_$environmentKey'] =
      _sessionCommit(
        'environment:$environmentKey',
        session,
        environmentKey: environmentKey,
        ownerFingerprint: ownerFingerprint,
      );
}

String _sessionCommit(
  String namespace,
  MaasoAuthSession session, {
  required String environmentKey,
  required String ownerFingerprint,
}) {
  final canonical = jsonEncode(<String>[
    namespace,
    session.accountUuid,
    session.accessToken,
    session.refreshToken,
    session.expiresAt.toIso8601String(),
    environmentKey,
    ownerFingerprint,
  ]);
  return 'v2:${sha256.convert(utf8.encode(canonical))}';
}

class _TestAuthSessionService extends AuthSessionService {
  int activationCount = 0;
  int publishCount = 0;
  int unpublishCount = 0;
  int unpublishFailuresRemaining = 0;
  bool restoreResult = false;
  MaasoAuthSession? restoredSession;
  MaasoAuthCandidate? _stagedCandidate;
  int _operationEpoch = 0;

  @override
  MaasoAuthCandidate? get candidate => _stagedCandidate;

  void stage(MaasoAuthSession next) {
    _stagedCandidate = MaasoAuthCandidate(
      environment: appServices.find<AppEnvironmentService>().environment.value,
      session: next,
      operationEpoch: ++_operationEpoch,
      logoutFence: const AuthLogoutPendingSnapshot(
        pending: false,
        revision: 1,
        token: 'test-cleared',
      ),
    );
    session.value = null;
  }

  @override
  Future<void> activateCurrentEnvironment() async {
    activationCount++;
    session.value = null;
    final restored = restoredSession;
    _stagedCandidate = null;
    if (restored != null) stage(restored);
  }

  @override
  Future<bool> restoreCandidate() async {
    await activateCurrentEnvironment();
    return restoreResult;
  }

  @override
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    final current = _stagedCandidate;
    if (current == null ||
        (expected != null && !identical(current, expected))) {
      throw StateError('candidate changed');
    }
    publishCount++;
    session.value = current.session;
  }

  @override
  Future<void> unpublishSession() async {
    unpublishCount++;
    session.value = null;
    if (unpublishFailuresRemaining > 0) {
      unpublishFailuresRemaining--;
      throw StateError('unpublish failed');
    }
  }

  @override
  Future<void> signOut() async {
    // Production unpublish retains AuthSessionService's private candidate as
    // the durable cleanup owner. This fake stages its candidate separately, so
    // restore that owner through the public session before delegating.
    session.value ??= _stagedCandidate?.session;
    try {
      await super.signOut();
    } finally {
      _stagedCandidate = null;
    }
  }
}

class _TestLease implements AccountRuntimeLease {
  _TestLease({Future<void> Function()? onClose}) : _onClose = onClose ?? _noop;

  final Future<void> Function() _onClose;
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
    await _onClose();
  }

  static Future<void> _noop() async {}
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = <String, String>{};
  bool failDeletes = false;

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
    if (failDeletes) return false;
    values.remove(key);
    return true;
  }
}
