import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';

void main() {
  const installationId = '0123456789abcdef0123456789abcdef';
  const runtimeInstanceId = 'fedcba9876543210fedcba9876543210';
  const presenceSessionId = 'presence_1';
  const holderProof = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  test('openPresence scopes auth by environment and account', () async {
    MaasoEnvironment? tokenEnvironment;
    String? tokenAccount;
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (environment, accountUuid) async {
        tokenEnvironment = environment;
        tokenAccount = accountUuid;
        return 'access-secret';
      },
      httpClient: _RequestClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/companion/'
          'runtime-presences/open',
        );
        expect(request.headers['authorization'], 'Bearer access-secret');
        expect(request.headers['cache-control'], 'no-store');
        expect(request.followRedirects, isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, <String, Object>{
          'agentId': 'self',
          'installationId': installationId,
          'runtimeInstanceId': runtimeInstanceId,
          'deviceLabel': 'Kunhong Mac',
          'platform': 'macos',
          'appVersion': '1.2.3+4',
          'requestId': 'request_1',
        });
        expect(request.body, isNot(contains('account-1')));
        expect(request.body, isNot(contains('test')));
        expect(request.body, isNot(contains('access-secret')));
        return _jsonResponse(request, 200, <String, Object?>{
          'code': 'OK',
          'data': <String, Object?>{
            'presence': _presenceJson(
              installationId: installationId,
              runtimeInstanceId: runtimeInstanceId,
              presenceSessionId: presenceSessionId,
            ),
            'replayed': false,
          },
        });
      }),
    );

    final result = await transport.openPresence(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      agentId: 'self',
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      deviceLabel: 'Kunhong Mac',
      platform: 'macos',
      appVersion: '1.2.3+4',
      requestId: 'request_1',
    );

    expect(tokenEnvironment, MaasoEnvironment.test);
    expect(tokenAccount, 'account-1');
    expect(result.replayed, isFalse);
    expect(result.presence.presenceSessionId, presenceSessionId);
    expect(result.presence.generation, 3);
  });

  test('lists active presences without exposing authority secrets', () async {
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (_, _) async => 'discovery-token',
      httpClient: _RequestClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/companion/runtime-presences');
        expect(request.url.queryParameters, <String, String>{
          'agentId': 'self',
          'limit': '25',
        });
        expect(request.followRedirects, isFalse);
        return _jsonResponse(request, 200, <String, Object?>{
          'code': 'OK',
          'data': <String, Object?>{
            'presences': <Object?>[
              <String, Object?>{
                ..._presenceJson(
                    installationId: installationId,
                    runtimeInstanceId: runtimeInstanceId,
                    presenceSessionId: presenceSessionId,
                  )
                  ..remove('generation')
                  ..remove('remainingTtlMs')
                  ..remove('renewAfterMs'),
                'isCurrentHolder': true,
              },
            ],
            'snapshotAt': '2026-08-21T12:00:01.000Z',
            'eventSequence': 11,
            'truncated': false,
          },
        });
      }),
    );

    final result = await transport.listActivePresences(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      limit: 25,
    );

    expect(result.presences, hasLength(1));
    expect(result.presences.single.isCurrentHolder, isTrue);
    expect(result.presences.single.installationId, installationId);
    expect(result.eventSequence, 11);
    expect(result.truncated, isFalse);
  });

  test('rejects discovery command credentials and inconsistent holders', () {
    Map<String, Object?> snapshot(List<Object?> presences) => <String, Object?>{
      'presences': presences,
      'snapshotAt': '2026-08-21T12:00:01.000Z',
      'eventSequence': 11,
      'truncated': false,
    };

    final first = _presenceViewJson(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      isCurrentHolder: true,
    );
    final second = _presenceViewJson(
      installationId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      runtimeInstanceId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      presenceSessionId: 'presence_2',
      isCurrentHolder: true,
    );

    for (final invalid in <Map<String, Object?>>[
      snapshot(<Object?>[
        <String, Object?>{...first, 'generation': 3},
      ]),
      snapshot(<Object?>[
        <String, Object?>{...first, 'holderProof': holderProof},
      ]),
      snapshot(<Object?>[
        first,
        <String, Object?>{...first},
      ]),
      snapshot(<Object?>[first, second]),
    ]) {
      expect(
        () => AccountDevicePresenceListResult.fromJson(invalid),
        throwsFormatException,
      );
    }
  });

  test(
    'replays lifecycle events while advancing across filtered rows',
    () async {
      final transport = AccountDeviceLeaseTransport(
        accessTokenProvider: (_, _) async => 'event-token',
        httpClient: _RequestClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/companion/runtime-events');
          expect(request.url.queryParameters, <String, String>{
            'agentId': 'self',
            'afterSequence': '1',
            'limit': '50',
          });
          return _jsonResponse(request, 200, <String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'events': <Object?>[
                <String, Object?>{
                  'eventId': 'event_2',
                  'sequence': 2,
                  'type': 'lease.acquired',
                  'leaseEpoch': 7,
                  'createdAt': '2026-08-21T12:00:02.000Z',
                },
              ],
              // Sequence 3 and 4 may be internal rows. The client must commit
              // this server cursor rather than deriving it from visible events.
              'nextSequence': 4,
              'highWaterSequence': 5,
              'hasMore': true,
            },
          });
        }),
      );

      final page = await transport.replayRuntimeLifecycleEvents(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        afterSequence: 1,
      );

      expect(page.events.single.type, 'lease.acquired');
      expect(page.nextSequence, 4);
      expect(page.highWaterSequence, 5);
      expect(page.hasMore, isTrue);
    },
  );

  test('rejects a hasMore lifecycle page whose cursor does not advance', () {
    expect(
      () => AccountRuntimeLifecycleEventPage.fromJson(<String, Object?>{
        'events': const <Object?>[],
        'nextSequence': 7,
        'highWaterSequence': 8,
        'hasMore': true,
      }, afterSequence: 7),
      throwsFormatException,
    );
  });

  test('maps an expired lifecycle cursor to a typed resync signal', () async {
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (_, _) async => 'event-token',
      httpClient: _RequestClient(
        (request) async => _jsonResponse(request, 410, <String, Object?>{
          'code': 'RUNTIME_EVENT_CURSOR_EXPIRED',
          'details': null,
        }),
      ),
    );

    await expectLater(
      transport.replayRuntimeLifecycleEvents(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        afterSequence: 7,
      ),
      throwsA(
        isA<AccountDeviceLeaseRequestException>().having(
          (error) => error.isEventCursorExpired,
          'isEventCursorExpired',
          isTrue,
        ),
      ),
    );
  });

  test('rejects internal events and any extra event detail', () {
    Map<String, Object?> event({String type = 'realtime.action'}) =>
        <String, Object?>{
          'eventId': 'event_2',
          'sequence': 2,
          'type': type,
          'leaseEpoch': 7,
          'createdAt': '2026-08-21T12:00:02.000Z',
        };

    expect(
      () => AccountRuntimeLifecycleEvent.fromJson(event()),
      throwsFormatException,
    );
    expect(
      () => AccountRuntimeLifecycleEvent.fromJson(<String, Object?>{
        ...event(type: 'lease.acquired'),
        'payload': <String, Object?>{'holderProof': holderProof},
      }),
      throwsFormatException,
    );
  });

  test('acquire sends proof once and parses a proof-free receipt', () async {
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (_, _) async => 'token',
      httpClient: _RequestClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['holderProof'], holderProof);
        expect(body['presenceSessionId'], presenceSessionId);
        expect(body.containsKey('accountUuid'), isFalse);
        expect(body.containsKey('environment'), isFalse);
        return _jsonResponse(request, 200, <String, Object?>{
          'code': 'OK',
          'data': <String, Object?>{
            'lease': _leaseJson(
              installationId: installationId,
              runtimeInstanceId: runtimeInstanceId,
              presenceSessionId: presenceSessionId,
            ),
            'replayed': false,
          },
        });
      }),
    );

    final result = await transport.acquireLease(
      environment: MaasoEnvironment.production,
      accountUuid: 'account-1',
      agentId: 'self',
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      holderProof: holderProof,
      requestId: 'request_2',
    );

    expect(result.lease.epoch, 7);
    expect(result.lease.remainingTtl, const Duration(seconds: 45));
    expect(result.lease.toJson().toString(), isNot(contains('Proof')));
    expect(result.lease.toString(), isNot(contains(holderProof)));
  });

  test('maps lease conflict details to a non-secret typed exception', () async {
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (_, _) async => 'token',
      httpClient: _RequestClient((request) async {
        return _jsonResponse(request, 409, <String, Object?>{
          'code': 'RUNTIME_LEASE_CONFLICT',
          'details': <String, Object?>{
            'observedEpoch': 7,
            'holder': _holderJson(
              installationId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              runtimeInstanceId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              presenceSessionId: 'presence_other',
            ),
            'expiresAt': '2026-08-21T12:00:45.000Z',
            'remainingTtlMs': 31000,
          },
        });
      }),
    );

    await expectLater(
      transport.acquireLease(
        environment: MaasoEnvironment.test,
        accountUuid: 'account-1',
        agentId: 'self',
        installationId: installationId,
        runtimeInstanceId: runtimeInstanceId,
        presenceSessionId: presenceSessionId,
        holderProof: holderProof,
        requestId: 'request_3',
      ),
      throwsA(
        isA<AccountDeviceLeaseConflict>()
            .having((error) => error.observedEpoch, 'observedEpoch', 7)
            .having(
              (error) => error.toString(),
              'redacted representation',
              isNot(contains('aaaaaaaa')),
            ),
      ),
    );
  });

  test(
    'rejects a server response that contains holder proof material',
    () async {
      final transport = AccountDeviceLeaseTransport(
        accessTokenProvider: (_, _) async => 'token',
        httpClient: _RequestClient((request) async {
          final lease = _leaseJson(
            installationId: installationId,
            runtimeInstanceId: runtimeInstanceId,
            presenceSessionId: presenceSessionId,
          )..['proofHash'] = 'must-not-cross-the-wire';
          return _jsonResponse(request, 200, <String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{'lease': lease, 'replayed': false},
          });
        }),
      );

      await expectLater(
        transport.acquireLease(
          environment: MaasoEnvironment.test,
          accountUuid: 'account-1',
          agentId: 'self',
          installationId: installationId,
          runtimeInstanceId: runtimeInstanceId,
          presenceSessionId: presenceSessionId,
          holderProof: holderProof,
          requestId: 'request_4',
        ),
        throwsFormatException,
      );
    },
  );

  test('parses current lease and stale release contracts strictly', () async {
    var call = 0;
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (_, _) async => 'token',
      httpClient: _RequestClient((request) async {
        call++;
        if (call == 1) {
          expect(request.method, 'GET');
          expect(request.url.queryParameters, <String, String>{
            'agentId': 'self',
          });
          return _jsonResponse(request, 200, <String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'state': 'active',
              'lease': _leaseJson(
                installationId: installationId,
                runtimeInstanceId: runtimeInstanceId,
                presenceSessionId: presenceSessionId,
              ),
            },
          });
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['leaseId'], 'lease_1');
        expect(body['epoch'], 7);
        expect(body['holderProof'], holderProof);
        return _jsonResponse(request, 200, <String, Object?>{
          'code': 'OK',
          'data': <String, Object?>{
            'released': false,
            'stale': true,
            'epoch': 8,
          },
        });
      }),
    );

    final snapshot = await transport.currentLease(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      agentId: 'self',
    );
    final result = await transport.releaseLease(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
      lease: snapshot.lease!,
      holderProof: holderProof,
      requestId: 'request_5',
    );

    expect(snapshot.state, AccountDeviceLeaseRemoteState.active);
    expect(result.released, isFalse);
    expect(result.stale, isTrue);
    expect(result.epoch, 8);
  });

  test('rejects unknown keys in every nested authority receipt', () {
    final holder = _holderJson(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
    )..['unknown'] = true;
    final presence = _presenceJson(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
    )..['unknown'] = true;
    final lease = _leaseJson(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
    )..['unknown'] = true;
    final snapshot = <String, Object?>{
      'state': 'inactive',
      'lease': null,
      'unknown': true,
    };

    expect(
      () => AccountDeviceLeaseHolder.fromJson(holder),
      throwsFormatException,
    );
    expect(
      () => AccountDevicePresenceReceipt.fromJson(presence),
      throwsFormatException,
    );
    expect(
      () => AccountDeviceLeaseReceipt.fromJson(lease),
      throwsFormatException,
    );
    expect(
      () => AccountDeviceLeaseSnapshot.fromJson(snapshot),
      throwsFormatException,
    );
  });

  test(
    'rejects unknown response envelope and operation wrapper keys',
    () async {
      Future<void> expectRejected(Map<String, Object?> response) async {
        final transport = AccountDeviceLeaseTransport(
          accessTokenProvider: (_, _) async => 'token',
          httpClient: _RequestClient(
            (request) async => _jsonResponse(request, 200, response),
          ),
        );
        await expectLater(
          transport.acquireLease(
            environment: MaasoEnvironment.test,
            accountUuid: 'account-1',
            agentId: 'self',
            installationId: installationId,
            runtimeInstanceId: runtimeInstanceId,
            presenceSessionId: presenceSessionId,
            holderProof: holderProof,
            requestId: 'request_strict',
          ),
          throwsFormatException,
        );
      }

      final validData = <String, Object?>{
        'lease': _leaseJson(
          installationId: installationId,
          runtimeInstanceId: runtimeInstanceId,
          presenceSessionId: presenceSessionId,
        ),
        'replayed': false,
      };
      await expectRejected(<String, Object?>{
        'code': 'OK',
        'data': validData,
        'unknown': true,
      });
      await expectRejected(<String, Object?>{
        'code': 'OK',
        'data': <String, Object?>{...validData, 'unknown': true},
      });
    },
  );

  test('rejects zero and contradictory close results', () async {
    final presence = AccountDevicePresenceReceipt.fromJson(
      _presenceJson(
        installationId: installationId,
        runtimeInstanceId: runtimeInstanceId,
        presenceSessionId: presenceSessionId,
      ),
    );

    for (final data in <Map<String, Object?>>[
      <String, Object?>{'closed': true, 'stale': false, 'generation': 0},
      <String, Object?>{'closed': true, 'stale': true, 'generation': 3},
    ]) {
      final transport = AccountDeviceLeaseTransport(
        accessTokenProvider: (_, _) async => 'token',
        httpClient: _RequestClient(
          (request) async => _jsonResponse(request, 200, <String, Object?>{
            'code': 'OK',
            'data': data,
          }),
        ),
      );

      await expectLater(
        transport.closePresence(
          environment: MaasoEnvironment.test,
          accountUuid: 'account-1',
          presence: presence,
          requestId: 'request_close',
        ),
        throwsFormatException,
      );
    }
  });

  test('rejects zero and contradictory release results', () async {
    final lease = AccountDeviceLeaseReceipt.fromJson(
      _leaseJson(
        installationId: installationId,
        runtimeInstanceId: runtimeInstanceId,
        presenceSessionId: presenceSessionId,
      ),
    );

    for (final data in <Map<String, Object?>>[
      <String, Object?>{'released': true, 'stale': false, 'epoch': 0},
      <String, Object?>{'released': false, 'stale': false, 'epoch': 8},
    ]) {
      final transport = AccountDeviceLeaseTransport(
        accessTokenProvider: (_, _) async => 'token',
        httpClient: _RequestClient(
          (request) async => _jsonResponse(request, 200, <String, Object?>{
            'code': 'OK',
            'data': data,
          }),
        ),
      );

      await expectLater(
        transport.releaseLease(
          environment: MaasoEnvironment.test,
          accountUuid: 'account-1',
          lease: lease,
          holderProof: holderProof,
          requestId: 'request_release',
        ),
        throwsFormatException,
      );
    }
  });

  test('fetches authenticated no-store authority policy strictly', () async {
    final transport = AccountDeviceLeaseTransport(
      accessTokenProvider: (environment, accountUuid) async {
        expect(environment, MaasoEnvironment.test);
        expect(accountUuid, 'account-1');
        return 'policy-secret';
      },
      httpClient: _RequestClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/companion/'
          'runtime-authority-policy',
        );
        expect(request.headers['authorization'], 'Bearer policy-secret');
        expect(request.headers['cache-control'], 'no-store');
        expect(request.body, isEmpty);
        return _jsonResponse(request, 200, <String, Object?>{
          'code': 'OK',
          'data': <String, Object?>{
            'mode': 'enforce',
            'revision': 7,
            'expiresAt': '2026-08-21T12:05:00.000Z',
            'remainingTtlMs': 300000,
            'pollAfterMs': 15000,
          },
        });
      }),
    );

    final policy = await transport.fetchRuntimeAuthorityPolicy(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-1',
    );

    expect(policy.mode, AccountRuntimeAuthorityMode.enforce);
    expect(policy.revision, 7);
    expect(policy.remainingTtl, const Duration(minutes: 5));
    expect(policy.pollAfter, const Duration(seconds: 15));
  });
}

Map<String, Object?> _presenceJson({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
}) => <String, Object?>{
  'agentId': 'self',
  'installationId': installationId,
  'runtimeInstanceId': runtimeInstanceId,
  'presenceSessionId': presenceSessionId,
  'generation': 3,
  'deviceLabel': 'Kunhong Mac',
  'platform': 'macos',
  'appVersion': '1.2.3+4',
  'openedAt': '2026-08-21T12:00:00.000Z',
  'lastSeenAt': '2026-08-21T12:00:00.000Z',
  'expiresAt': '2026-08-21T12:01:00.000Z',
  'remainingTtlMs': 60000,
  'renewAfterMs': 20000,
};

Map<String, Object?> _presenceViewJson({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
  required bool isCurrentHolder,
}) => <String, Object?>{
  'agentId': 'self',
  'installationId': installationId,
  'runtimeInstanceId': runtimeInstanceId,
  'presenceSessionId': presenceSessionId,
  'deviceLabel': 'Kunhong Mac',
  'platform': 'macos',
  'appVersion': '1.2.3+4',
  'openedAt': '2026-08-21T12:00:00.000Z',
  'lastSeenAt': '2026-08-21T12:00:00.000Z',
  'expiresAt': '2026-08-21T12:01:00.000Z',
  'isCurrentHolder': isCurrentHolder,
};

Map<String, Object?> _leaseJson({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
}) => <String, Object?>{
  'agentId': 'self',
  'leaseId': 'lease_1',
  'epoch': 7,
  'installationId': installationId,
  'runtimeInstanceId': runtimeInstanceId,
  'presenceSessionId': presenceSessionId,
  'expiresAt': '2026-08-21T12:00:45.000Z',
  'remainingTtlMs': 45000,
  'renewAfterMs': 15000,
  'holder': _holderJson(
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
  ),
};

Map<String, Object?> _holderJson({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
}) => <String, Object?>{
  'installationId': installationId,
  'runtimeInstanceId': runtimeInstanceId,
  'presenceSessionId': presenceSessionId,
  'deviceLabel': 'Kunhong Mac',
  'platform': 'macos',
  'lastSeenAt': '2026-08-21T12:00:00.000Z',
};

http.StreamedResponse _jsonResponse(
  http.BaseRequest request,
  int statusCode,
  Map<String, Object?> body,
) {
  final bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    headers: <String, String>{'content-type': 'application/json'},
    request: request,
  );
}

class _RequestClient extends http.BaseClient {
  _RequestClient(this.handler);

  final Future<http.StreamedResponse> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request as http.Request);
}
