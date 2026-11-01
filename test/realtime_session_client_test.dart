import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('client rejects a non-HTTPS base before creating an HTTP client', () {
    expect(
      () =>
          RealtimeSessionClient(baseUri: Uri.parse('http://api.example.test')),
      throwsA(isA<StateError>()),
    );
  });

  test('legacy create uses HTTPS without redirects or runtime proof', () async {
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    final locale = appServices.put(LocaleConfigService());
    locale.locale.value = AppLocale.zh;
    final client = RealtimeSessionClient(
      baseUri: Uri.parse('https://api.example.test'),
      httpClient: _SessionClientFake((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/realtime/sessions');
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        expect(
          request.headers,
          isNot(contains('x-maaso-runtime-holder-proof')),
        );
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, <String, dynamic>{'agentId': 'self', 'locale': 'zh'});
        expect(jsonEncode(body), isNot(contains('holderProof')));

        return http.Response(
          jsonEncode({
            'code': 'OK',
            'message': 'success',
            'traceId': 'trace-test',
            'data': {
              'sessionId': 'ms_session_1',
              'locale': 'zh',
              'rtcAppId': 'volc-app-id',
              'roomId': 'room_1',
              'userId': 'user_1',
              'agentUserId': 'ai_1',
              'taskId': 'task_1',
              'rtcToken': 'token_1',
              'actionStreamUrl': '/v1/realtime/sessions/ms_session_1/actions',
              'createdAt': '2026-07-02T00:00:00Z',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final session = await client.createSession(
      agentId: 'self',
      requestId: 'legacy-request-1',
      locale: AppLocale.system,
    );

    expect(session.sessionId, 'ms_session_1');
    expect(session.rtcAppId, 'volc-app-id');
    expect(session.roomId, 'room_1');
    expect(session.rtcToken, 'token_1');
    expect(session.isFenced, isFalse);
    expect(
      session.actionStreamUri.toString(),
      'https://api.example.test/v1/realtime/sessions/ms_session_1/actions',
    );
  });

  test(
    'fenced create sends the exact proof only in the Maaso JSON body',
    () async {
      final fixture = await _authorityFixture();
      late Map<String, dynamic> sentBody;
      final client = RealtimeSessionClient(
        baseUri: Uri.parse('${MaasoEnvironment.test.baseUrl}/'),
        accessTokenProvider: () async => 'access-token-secret',
        httpClient: _SessionClientFake((request) async {
          expect(request.url.origin, MaasoEnvironment.test.baseUrl);
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          expect(
            request.headers['authorization'],
            'Bearer access-token-secret',
          );
          expect(request.headers['cache-control'], 'no-store');
          expect(
            request.headers,
            isNot(contains('x-maaso-runtime-holder-proof')),
          );
          sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          expect(sentBody.keys.toSet(), <String>{
            'agentId',
            'locale',
            'requestId',
            'resumeAfterSequence',
            'leaseId',
            'epoch',
            'runtimeInstanceId',
            'presenceSessionId',
            'holderProof',
          });
          expect(sentBody['holderProof'], fixture.gateway.holderProof);
          expect(sentBody['leaseId'], fixture.authority.leaseId);
          expect(sentBody['epoch'], fixture.authority.leaseEpoch);
          expect(sentBody['requestId'], 'session-create-123');
          expect(sentBody['resumeAfterSequence'], 42);
          return _successResponse(
            leaseEpoch: fixture.authority.leaseEpoch,
            rtcGeneration: 3,
          );
        }),
      );

      final session = await client.createSession(
        agentId: 'self',
        requestId: 'session-create-123',
        authority: fixture.authority,
        locale: AppLocale.en,
        resumeAfterSequence: 42,
      );

      expect(sentBody['holderProof'], fixture.gateway.holderProof);
      expect(session.leaseEpoch, fixture.authority.leaseEpoch);
      expect(session.rtcGeneration, 3);
      expect(session.isFenced, isTrue);
      expect(session.toString(), isNot(contains(fixture.gateway.holderProof)));
      expect(session.toString(), isNot(contains('rtc-token-secret')));
    },
  );

  test(
    'authority refuses proof dispatch to a different HTTPS origin',
    () async {
      final fixture = await _authorityFixture();
      var sends = 0;
      final client = RealtimeSessionClient(
        baseUri: Uri.parse('https://other.example.test'),
        httpClient: _SessionClientFake((_) async {
          sends++;
          return _successResponse();
        }),
      );

      await expectLater(
        client.createSession(
          agentId: 'self',
          requestId: 'session-create-123',
          authority: fixture.authority,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('not authorized'),
          ),
        ),
      );

      expect(sends, 0);
    },
  );

  test(
    'cross-origin action stream URL is rejected after trusted create',
    () async {
      final fixture = await _authorityFixture();
      var sends = 0;
      final client = RealtimeSessionClient(
        baseUri: Uri.parse(MaasoEnvironment.test.baseUrl),
        httpClient: _SessionClientFake((_) async {
          sends++;
          return _successResponse(
            actionStreamUrl:
                'https://evil.example/v1/realtime/sessions/ms_session_1/actions',
            leaseEpoch: fixture.authority.leaseEpoch,
            rtcGeneration: 3,
          );
        }),
      );

      await expectLater(
        client.createSession(
          agentId: 'self',
          requestId: 'session-create-123',
          authority: fixture.authority,
        ),
        throwsA(isA<StateError>()),
      );

      expect(sends, 1);
    },
  );

  test('same-origin absolute action stream URL is accepted', () async {
    final fixture = await _authorityFixture();
    final client = RealtimeSessionClient(
      baseUri: Uri.parse(MaasoEnvironment.test.baseUrl),
      httpClient: _SessionClientFake(
        (_) async => _successResponse(
          actionStreamUrl:
              '${MaasoEnvironment.test.baseUrl}/v1/realtime/sessions/'
              'ms_session_1/actions',
          leaseEpoch: fixture.authority.leaseEpoch,
          rtcGeneration: 3,
        ),
      ),
    );

    final session = await client.createSession(
      agentId: 'self',
      requestId: 'session-create-123',
      authority: fixture.authority,
    );

    expect(
      session.actionStreamUri.toString(),
      '${MaasoEnvironment.test.baseUrl}/v1/realtime/sessions/'
      'ms_session_1/actions',
    );
  });

  test(
    'redirect response is not followed and reflected secrets are sanitized',
    () async {
      final fixture = await _authorityFixture();
      var sends = 0;
      final client = RealtimeSessionClient(
        baseUri: Uri.parse(MaasoEnvironment.test.baseUrl),
        accessTokenProvider: () async => 'access-token-secret',
        httpClient: _SessionClientFake((request) async {
          sends++;
          expect(request.followRedirects, isFalse);
          expect(request.maxRedirects, 0);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['holderProof'], fixture.gateway.holderProof);
          return http.Response(
            jsonEncode({
              'code': 'REDIRECT_REJECTED',
              'message': '${fixture.gateway.holderProof} access-token-secret',
            }),
            307,
            headers: {'location': 'https://evil.example/collect'},
          );
        }),
      );

      Object? failure;
      try {
        await client.createSession(
          agentId: 'self',
          requestId: 'session-create-123',
          authority: fixture.authority,
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<RealtimeBackendException>());
      final backendFailure = failure! as RealtimeBackendException;
      expect(backendFailure.statusCode, 307);
      expect(backendFailure.code, 'HTTP_307');
      expect(backendFailure.isRetryableSessionCreation, isFalse);
      expect(
        backendFailure.toString(),
        isNot(contains(fixture.gateway.holderProof)),
      );
      expect(backendFailure.toString(), isNot(contains('access-token-secret')));
      expect(backendFailure.toString(), isNot(contains('evil.example')));
      expect(sends, 1);
    },
  );
}

http.Response _successResponse({
  String actionStreamUrl = '/v1/realtime/sessions/ms_session_1/actions',
  int? leaseEpoch,
  int? rtcGeneration,
}) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'success',
    'traceId': 'trace-test',
    'data': {
      'sessionId': 'ms_session_1',
      'locale': 'en',
      'rtcAppId': 'volc-app-id',
      'roomId': 'room_1',
      'userId': 'user_1',
      'agentUserId': 'ai_1',
      'taskId': 'task_1',
      'rtcToken': 'rtc-token-secret',
      'actionStreamUrl': actionStreamUrl,
      'createdAt': '2026-07-02T00:00:00Z',
      'leaseEpoch': ?leaseEpoch,
      'rtcGeneration': ?rtcGeneration,
    },
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Future<_AuthorityFixture> _authorityFixture() async {
  final identity = await AppInstallationIdentityService(
    store: _MemoryInstallationIdentityStore(),
    randomBytes: (length) => List<int>.generate(length, (index) => index + 1),
  ).init();
  final gateway = _LeaseGateway();
  final coordinator = AccountDeviceLeaseCoordinator(
    identity: identity,
    gateway: gateway,
    randomBytes: (length) => List<int>.generate(length, (index) => index + 17),
    monotonicNow: () => Duration.zero,
    wallClock: () => _now,
  );
  await coordinator.acquire(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-1',
    deviceLabel: 'Test device',
    platform: 'macos',
    appVersion: '1.0.0',
  );
  return _AuthorityFixture(
    authority: coordinator.requireCurrentRequestAuthority(),
    gateway: gateway,
  );
}

final class _AuthorityFixture {
  const _AuthorityFixture({required this.authority, required this.gateway});

  final AccountDeviceLeaseRequestAuthority authority;
  final _LeaseGateway gateway;
}

final class _MemoryInstallationIdentityStore
    implements AppInstallationIdentityStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<bool> write(String key, String value) async {
    _values[key] = value;
    return true;
  }
}

final class _LeaseGateway implements AccountDeviceLeaseGateway {
  String holderProof = '';
  AccountDevicePresenceReceipt? _presence;
  AccountDeviceLeaseReceipt? _lease;

  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async {
    final presence = _presence ??= AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence_1',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: _now,
      lastSeenAt: _now,
      expiresAt: _now.add(const Duration(minutes: 1)),
      remainingTtl: const Duration(minutes: 1),
      renewAfter: const Duration(seconds: 20),
    );
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    this.holderProof = holderProof;
    final holder = _presence!.toHolder();
    final lease = _lease ??= AccountDeviceLeaseReceipt(
      agentId: agentId,
      leaseId: 'lease_1',
      epoch: 7,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: _now.add(const Duration(seconds: 45)),
      remainingTtl: const Duration(seconds: 45),
      renewAfter: const Duration(seconds: 15),
      holder: holder,
    );
    return AccountDeviceLeaseOperationResult(lease: lease, replayed: false);
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: _lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: _lease,
  );

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async =>
      AccountDevicePresenceOperationResult(presence: presence, replayed: false);

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async => AccountDeviceLeaseOperationResult(lease: lease, replayed: false);

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async => AccountDeviceLeaseReleaseResult(
    released: true,
    stale: false,
    epoch: lease.epoch + 1,
  );

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async => AccountDevicePresenceCloseResult(
    closed: true,
    stale: false,
    generation: presence.generation,
  );
}

final DateTime _now = DateTime.utc(2026, 8, 21, 12);

class _SessionClientFake extends http.BaseClient {
  _SessionClientFake(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    final response = await handler(req);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([response.bodyBytes]),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
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
