import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(appServices.reset);

  test('login parses hosted auth token envelope', () async {
    final storage = _MemorySecureStorageService();
    final auth = await _createAuth(
      storage,
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/login/email',
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['app_id'], 'maaso');
        expect(body['aud'], 'maaso-agent');
        expect(body['scope'], ['maaso:user']);
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'message': 'success',
            'traceId': 'trace-test',
            'data': {
              'account_uuid': 'account-1',
              'access_token': 'access-token',
              'refresh_token': 'refresh-token',
              'expires_at': '2026-08-03T08:49:49.242056139Z',
              'token_type': 'Bearer',
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await auth.login(email: 'person@example.com', password: 'secret');

    expect(auth.session.value?.accountUuid, 'account-1');
    expect(auth.session.value?.accessToken, 'access-token');
    expect(storage.values[GlobalConstant.keyMaasoAccessToken], 'access-token');
  });

  test('login hides non-ok server copy behind a localized error', () async {
    final auth = await _createAuth(
      _MemorySecureStorageService(),
      MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': 'VALIDATION_ERROR',
            'message': 'account already exists',
            'traceId': 'trace-error',
            'data': null,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    await expectLater(
      auth.login(email: 'person@example.com', password: 'secret'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'That request did not go through. Please try again.',
        ),
      ),
    );
    expect(
      auth.error.value,
      'That request did not go through. Please try again.',
    );
    expect(auth.error.value, isNot(contains('account already exists')));
  });

  test(
    'login preserves HTTP failure semantics for a non-JSON response',
    () async {
      final auth = await _createAuth(
        _MemorySecureStorageService(),
        MockClient((request) async {
          return http.Response(
            '404 page not found',
            404,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }),
      );

      await expectLater(
        auth.login(email: 'person@example.com', password: 'secret'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Login failed. Please try again.',
          ),
        ),
      );
      expect(auth.error.value, 'Login failed. Please try again.');
    },
  );
}

Future<AuthSessionService> _createAuth(
  SecureStorageService storage,
  http.Client client,
) async {
  appServices.put<SecureStorageService>(storage);
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: client,
      logoutPendingStore: _TestLogoutPendingStore(),
    ),
  );
  await auth.init();
  return auth;
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = {};

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

class _TestLogoutPendingStore implements AuthLogoutPendingStore {
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
