import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AccountSessionLifecycleService? lifecycle;
  GoRouter? router;
  late _RouteAuthSessionService auth;
  var failFirstClose = false;
  var closeAttempts = 0;

  setUp(() async {
    await appServices.reset();
    failFirstClose = false;
    closeAttempts = 0;
    appServices.put<SecureStorageService>(SecureStorageService());
    final environment = appServices.put(AppEnvironmentService());
    auth = _RouteAuthSessionService();
    appServices.put<AuthSessionService>(auth);
    lifecycle = appServices.put(
      AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _TestAccountRuntimeLease(
          onClose: () async {
            closeAttempts++;
            if (failFirstClose && closeAttempts == 1) {
              throw StateError('account runtime close failed');
            }
          },
        ),
      ),
    );
  });

  tearDown(() async {
    final current = lifecycle;
    if (current?.isMounted == true || current?.isFaulted == true) {
      await current!.unmount();
    }
    router?.dispose();
    await appServices.reset();
  });

  test('unmounted account redirects protected paths to login', () {
    expect(accountSessionRedirectForPath(AppRoutes.home), AppRoutes.login);
    expect(accountSessionRedirectForPath(AppRoutes.login), isNull);
  });

  test('an in-flight login stays on its canvas during lease preparation', () {
    auth.stage(
      MaasoAuthSession(
        accountUuid: 'account-a',
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    lifecycle!.phase.value = AccountSessionLifecyclePhase.acquiringLease;
    expect(lifecycle!.hasAuthenticatedCandidate, isTrue);
    expect(
      accountSessionRedirectForPath(AppRoutes.login, loginPending: true),
      isNull,
    );
  });

  test(
    'mounted account is not forced away from an explicit login route',
    () async {
      await lifecycle!.authenticateAndMount(() async {
        auth.stage(
          MaasoAuthSession(
            accountUuid: 'account-a',
            accessToken: 'access-token',
            refreshToken: 'refresh-token',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
      });
      expect(accountSessionRedirectForPath(AppRoutes.home), isNull);
      expect(accountSessionRedirectForPath(AppRoutes.login), isNull);
    },
  );

  testWidgets('unmount refresh redirects an open protected route to login', (
    tester,
  ) async {
    await tester.runAsync(() => _mountAccount(lifecycle!, auth));
    router = _createTestRouter();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router!.routeInformationProvider.value.uri.path, AppRoutes.home);

    await tester.runAsync(() => lifecycle!.unmount());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(router!.routeInformationProvider.value.uri.path, AppRoutes.login);
  });

  testWidgets('faulted unmount also refreshes protected route to login', (
    tester,
  ) async {
    await tester.runAsync(() => _mountAccount(lifecycle!, auth));
    router = _createTestRouter();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router!));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    failFirstClose = true;

    Object? unmountError;
    await tester.runAsync(() async {
      try {
        await lifecycle!.unmount();
      } catch (error) {
        unmountError = error;
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(unmountError, isA<StateError>());
    expect(lifecycle!.isFaulted, isTrue);
    expect(router!.routeInformationProvider.value.uri.path, AppRoutes.login);
  });
}

class _TestAccountRuntimeLease implements AccountRuntimeLease {
  _TestAccountRuntimeLease({this.onClose});

  final Future<void> Function()? onClose;

  @override
  Future<void> close() async {
    await onClose?.call();
  }
}

Future<void> _mountAccount(
  AccountSessionLifecycleService lifecycle,
  _RouteAuthSessionService auth,
) async {
  await lifecycle.authenticateAndMount(() async {
    auth.stage(
      MaasoAuthSession(
        accountUuid: 'account-a',
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
  });
}

class _RouteAuthSessionService extends AuthSessionService {
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
}

GoRouter _createTestRouter() => createAppRouter(
  initialLocation: AppRoutes.home,
  routesOverride: <RouteBase>[
    GoRoute(path: AppRoutes.home, builder: (_, _) => const SizedBox.expand()),
    GoRoute(path: AppRoutes.login, builder: (_, _) => const SizedBox.expand()),
  ],
);
