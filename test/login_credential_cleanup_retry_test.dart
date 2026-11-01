import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(appServices.reset);

  testWidgets(
    'late lifecycle cleanup fault is visible and retries without login',
    (tester) async {
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final auth = _RetryAuthSessionService();
      appServices.put<AuthSessionService>(auth);
      final lifecycle = appServices.put(
        AccountSessionLifecycleService(
          auth: auth,
          environment: environment,
          mountRuntime: (_) async => _NoopAccountRuntimeLease(),
        ),
      );
      final controller = appServices.put(LoginController());

      expect(controller.canRetryCredentialCleanup.value, isFalse);

      await auth.emitDeferredCleanupFailure();
      await tester.pump();

      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(controller.canRetryCredentialCleanup.value, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LoginCredentialCleanupRetry(controller: controller),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('login-credential-cleanup-retry')),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(auth.cleanupRetryCalls, 1);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(controller.canRetryCredentialCleanup.value, isFalse);
      expect(
        find.byKey(const ValueKey<String>('login-credential-cleanup-retry')),
        findsNothing,
      );
    },
  );

  test(
    'pre-existing lifecycle fault is replayed after controller initialization',
    () async {
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final auth = _RetryAuthSessionService();
      appServices.put<AuthSessionService>(auth);
      final lifecycle = appServices.put(
        AccountSessionLifecycleService(
          auth: auth,
          environment: environment,
          mountRuntime: (_) async => _NoopAccountRuntimeLease(),
        ),
      );

      await auth.emitDeferredCleanupFailure();
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);

      final controller = appServices.put(LoginController());

      expect(controller.canRetryCredentialCleanup.value, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(controller.canRetryCredentialCleanup.value, isTrue);
      expect(controller.error.value, 'common.request_failed'.tr);
    },
  );
}

class _RetryAuthSessionService extends AuthSessionService {
  _RetryAuthSessionService()
    : super(logoutPendingStore: _MemoryLogoutPendingStore());

  int cleanupRetryCalls = 0;

  Future<void> emitDeferredCleanupFailure() async {
    await credentialCleanupFailureObserver?.call(
      AuthCredentialCleanupFailure(
        cause: StateError('credential cleanup failed'),
        causeStackTrace: StackTrace.current,
        environment: MaasoEnvironment.test,
        operationEpoch: 0,
      ),
    );
  }

  @override
  bool isCredentialCleanupFailureCurrent(
    AuthCredentialCleanupFailure failure,
  ) => true;

  @override
  Future<void> retryCredentialCleanup() async {
    cleanupRetryCalls++;
  }
}

class _NoopAccountRuntimeLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
}

class _MemoryLogoutPendingStore implements AuthLogoutPendingStore {
  AuthLogoutPendingSnapshot state = const AuthLogoutPendingSnapshot(
    pending: false,
    revision: 1,
    token: 'test-cleared',
  );

  @override
  Future<AuthLogoutPendingSnapshot> read(String environmentKey) async => state;

  @override
  Future<AuthLogoutPendingSnapshot> markPending(
    String environmentKey, {
    required String ownerFingerprint,
  }) async {
    state = AuthLogoutPendingSnapshot(
      pending: true,
      revision: state.revision + 1,
      token: 'test-${state.revision + 1}-pending',
      ownerFingerprint: ownerFingerprint,
    );
    return state;
  }

  @override
  Future<AuthLogoutPendingSnapshot?> clearPending(
    String environmentKey, {
    required AuthLogoutPendingSnapshot expected,
  }) async {
    if (!state.sameVersion(expected)) return null;
    state = AuthLogoutPendingSnapshot(
      pending: false,
      revision: state.revision + 1,
      token: 'test-${state.revision + 1}-cleared',
    );
    return state;
  }
}

class _MemorySecureStorageService extends SecureStorageService {
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
