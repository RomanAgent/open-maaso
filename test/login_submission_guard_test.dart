import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rapid submit remains one authentication while account mounting is pending',
    () async {
      await appServices.reset();
      appServices.testMode = true;
      addTearDown(appServices.reset);
      appServices.put<SecureStorageService>(_Storage());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final auth = appServices.put(AuthSessionService());
      appServices.put(
        AccountSessionLifecycleService(
          auth: auth,
          environment: environment,
          mountRuntime: (_) async => throw StateError('not used'),
        ),
      );
      final controller = appServices.put<_GuardedLogin>(_GuardedLogin());
      final first = controller.submit();
      await controller.submit();
      expect(controller.calls, 1);
      expect(controller.busy, isTrue);
      // AuthSessionService may have finished its network request while mounting
      // the account is still pending: the form must remain busy throughout.
      auth.isLoading.value = false;
      expect(controller.busy, isTrue);
      controller.completion.complete();
      await first;
      expect(controller.busy, isFalse);
      controller.completion = Completer<void>();
      final second = controller.submit();
      expect(controller.calls, 2);
      final failed = expectLater(second, throwsStateError);
      controller.completion.completeError(StateError('mount failed'));
      await failed;
      expect(controller.busy, isFalse);
    },
  );
}

class _GuardedLogin extends LoginController {
  var calls = 0;
  var completion = Completer<void>();
  @override
  Future<void> login() async {
    calls++;
    await completion.future;
  }
}

class _Storage extends SecureStorageService {
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
