import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/startup_route_service.dart';

void main() {
  late AppEnvironmentService environment;
  late _StartupAuthSessionService auth;
  AccountSessionLifecycleService? lifecycle;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    auth = _StartupAuthSessionService();
    appServices.put<AuthSessionService>(auth);
  });

  tearDown(() async {
    final current = lifecycle;
    if (current != null) {
      try {
        await current.unmount();
      } catch (_) {
        // The focused tests leave retryable leases clean on teardown.
      }
    }
    await appServices.reset();
  });

  test('home is selected only after the restored runtime is ready', () async {
    final runtimeReady = Completer<AccountRuntimeLease>();
    auth
      ..restoreResult = true
      ..restoredSession = _session('account-a');
    lifecycle = appServices.put(
      AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) => runtimeReady.future,
      ),
    );
    final service = StartupRouteService();
    var resolved = false;

    final route = service.resolveInitialRoute()..then((_) => resolved = true);
    await Future<void>.delayed(Duration.zero);

    expect(resolved, isFalse);
    expect(lifecycle!.phase.value, AccountSessionLifecyclePhase.mounting);

    runtimeReady.complete(_StartupLease());
    expect(await route, AppRouteCatalog.home);
    expect(lifecycle!.isMounted, isTrue);
  });

  test('failed restore stays on login without mounting a runtime', () async {
    var mountCalls = 0;
    auth.restoreResult = false;
    lifecycle = appServices.put(
      AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async {
          mountCalls++;
          return _StartupLease();
        },
      ),
    );

    final route = await StartupRouteService().resolveInitialRoute();

    expect(route, AppRouteCatalog.login);
    expect(mountCalls, 0);
    expect(lifecycle!.isMounted, isFalse);
  });

  test(
    'legacy auth fallback remains available without a coordinator',
    () async {
      auth
        ..restoreResult = true
        ..restoredSession = _session('account-a');

      final route = await StartupRouteService().resolveInitialRoute();

      expect(route, AppRouteCatalog.home);
      expect(auth.restoreCalls, 1);
    },
  );
}

MaasoAuthSession _session(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(hours: 2)),
);

class _StartupAuthSessionService extends AuthSessionService {
  bool restoreResult = false;
  int restoreCalls = 0;
  MaasoAuthSession? restoredSession;
  MaasoAuthCandidate? _stagedCandidate;

  @override
  MaasoAuthCandidate? get candidate => _stagedCandidate;

  @override
  Future<bool> restoreCandidate() async {
    final restored = restoredSession;
    _stagedCandidate = restoreResult && restored != null
        ? MaasoAuthCandidate(
            environment: appServices
                .find<AppEnvironmentService>()
                .environment
                .value,
            session: restored,
            operationEpoch: 1,
            logoutFence: const AuthLogoutPendingSnapshot(
              pending: false,
              revision: 1,
              token: 'test-cleared',
            ),
          )
        : null;
    return restoreResult;
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
  Future<bool> restoreOrRefresh() async {
    restoreCalls++;
    if (restoredSession != null) session.value = restoredSession;
    return restoreResult;
  }
}

class _StartupLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
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
