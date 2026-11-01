import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messages = <String>[];
  late DebugPrintCallback originalDebugPrint;
  late _FaultingAuth auth;
  late AccountSessionLifecycleService lifecycle;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) messages.add(message);
    };
    messages.clear();
    appServices.put<SecureStorageService>(_MemoryStorage());
    final environment = appServices.put(AppEnvironmentService());
    await environment.init();
    auth = _FaultingAuth();
    appServices.put<AuthSessionService>(auth);
    lifecycle = appServices.put(
      AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (_) async => _NoopLease(),
      ),
    );
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    await appServices.reset();
  });

  test(
    'existing fault logs only its types and known integer OSStatus',
    () async {
      await auth.emitFailure(
        PlatformException(
          code: 'Unexpected security result code',
          message: 'secret message user@example.com',
          details: -25308,
          stacktrace: 'secret platform stack',
        ),
      );
      final controller = appServices.put(LoginController());
      await Future<void>.delayed(Duration.zero);

      final diagnostic = messages.singleWhere(
        (message) => message.startsWith('[AuthRecovery]'),
      );
      expect(diagnostic, contains('stage=fault_observed phase=faulted'));
      expect(diagnostic, contains('error.type=AuthCredentialCleanupFailure'));
      expect(diagnostic, contains('error.cause.type=PlatformException'));
      expect(diagnostic, contains('error.cause.osStatus=-25308'));
      expect(diagnostic, isNot(contains('secret')));
      expect(diagnostic, isNot(contains('user@example.com')));
      expect(controller.canRetryCredentialCleanup.value, isTrue);
      expect(auth.retryCalls, 0);
    },
  );

  test('failed retry stays fenced and omits arbitrary platform data', () async {
    final controller = appServices.put(LoginController());
    await Future<void>.delayed(Duration.zero);
    final failure = PlatformException(
      code: 'secret-code',
      message: 'secret message',
      details: <String, Object>{'token': 'secret-token', 'status': -25308},
      stacktrace: 'secret platform stack',
    );
    await auth.emitFailure(failure);
    auth.retryFailure = failure;
    messages.clear();

    await controller.retryCredentialCleanup();

    final diagnostic = messages.singleWhere(
      (message) => message.startsWith('[AuthRecovery] stage=retry_failed'),
    );
    expect(diagnostic, contains('phase=faulted error.type=PlatformException'));
    expect(diagnostic, isNot(contains('secret')));
    expect(diagnostic, isNot(contains('osStatus')));
    expect(diagnostic, isNot(contains('-25308')));
    expect(auth.retryCalls, 1);
    expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
    expect(controller.canRetryCredentialCleanup.value, isTrue);
    expect(controller.isRetryingCredentialCleanup.value, isFalse);
  });

  for (final cause in <StateError>[
    AuthCredentialReauthenticationRequired(),
    AuthCredentialReauthenticationRequired.activeRecord(),
  ]) {
    test('unknown owner requires sign-in: ${cause.message}', () async {
      await auth.emitFailure(cause);
      final controller = appServices.put(LoginController());
      await Future<void>.delayed(Duration.zero);

      expect(
        controller.error.value,
        'auth.session_reauthentication_required'.tr,
      );
      expect(controller.canRetryCredentialCleanup.value, isFalse);
      await controller.retryCredentialCleanup();
      expect(auth.retryCalls, 0);
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
    });
  }

  test(
    'rejected sign-in preserves its error and does not restore retry',
    () async {
      await auth.emitFailure(AuthCredentialReauthenticationRequired());
      final controller = appServices.put(LoginController());
      await Future<void>.delayed(Duration.zero);
      controller.clearTransientMessages();

      await expectLater(
        lifecycle.authenticateAndMount(() async {
          expect(
            lifecycle.phase.value,
            AccountSessionLifecyclePhase.authenticating,
          );
          expect(controller.canRetryCredentialCleanup.value, isFalse);
          auth.error.value = 'Incorrect password';
          throw StateError('Invalid credentials');
        }),
        throwsA(isA<StateError>()),
      );

      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(controller.error.value, 'Incorrect password');
      expect(controller.canRetryCredentialCleanup.value, isFalse);
      await controller.retryCredentialCleanup();
      expect(auth.retryCalls, 0);

      // A resolved lifecycle boundary retires the sticky UI recovery choice.
      await lifecycle.retryFaultedCleanup();
      expect(lifecycle.phase.value, AccountSessionLifecyclePhase.signedOut);
      await auth.emitFailure(StateError('temporary cleanup failure'));
      expect(controller.canRetryCredentialCleanup.value, isTrue);
    },
  );
}

class _FaultingAuth extends AuthSessionService {
  int retryCalls = 0;
  Object? retryFailure;

  Future<void> emitFailure(Object cause) async {
    await credentialCleanupFailureObserver?.call(
      AuthCredentialCleanupFailure(
        cause: cause,
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
    retryCalls++;
    final failure = retryFailure;
    if (failure != null) throw failure;
  }
}

class _NoopLease implements AccountRuntimeLease {
  @override
  Future<void> close() async {}
}

class _MemoryStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }
}
