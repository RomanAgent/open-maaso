import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/economy/application/economy_service.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/creator_reward_evidence.dart';

import 'economy_test_support.dart';

Map<String, Object?> _evidence() => {
  'pending': [_row('pending-1', 'game', 'pending', 'qualified')],
  'reviewHold': [
    _row('funding-1', 'game', 'review_hold', 'funding_capacity'),
    _row('held-1', 'applet', 'review_hold', 'reward_capacity'),
  ],
  'submitted': [_row('submitted-1', 'game', 'submitted', 'qualified')],
};

Map<String, Object?> _row(
  String id,
  String kind,
  String state,
  String reason,
) => {
  'id': id,
  'kind': kind,
  'contentId': 'test-content-$kind',
  'state': state,
  'reason': reason,
  'occurredAt': '2030-01-01T00:00:00Z',
  'qualifiedAt': '2030-01-01T00:05:00Z',
};

class _Server {
  final requests = <http.Request>[];
  Object? evidence = _evidence();
  bool evidenceUnavailable = false;
  Completer<http.Response>? delayedEvidence;
  String account = 'account-a';

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    Object? data;
    switch (request.url.path) {
      case '/v1/economy/catalog':
        data = economyCatalogJson(ready: false);
      case '/v1/economy/wallet':
        data = economyWalletJson();
      case '/v1/economy/ledger':
        data = {'items': [], 'nextBeforeId': 0};
      case '/v1/economy/rewards/pending':
        data = [];
      case '/v1/economy/membership':
        data = {'activeTier': null, 'grants': []};
      case '/v1/content-engagement/rewards/evidence':
        if (delayedEvidence != null) return delayedEvidence!.future;
        if (evidenceUnavailable) return unavailable();
        data = evidence;
      default:
        return unavailable();
    }
    return ok(data);
  }

  static http.Response ok(Object? data) =>
      http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
  static http.Response unavailable() => http.Response(
    jsonEncode({'code': 'CONTENT_ENGAGEMENT_UNAVAILABLE'}),
    503,
  );

  EconomyService service() {
    final gateway = EconomyHttpClient(
      baseUri: () => Uri.parse('https://maaso.test/'),
      accountId: () => account,
      accessToken: () async => 'test-token-$account',
      client: MockClient(respond),
    );
    return EconomyService(gateway: gateway, closeGateway: gateway.close);
  }
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  _boundaryTests();
}

void _boundaryTests() {
  test('creator reads use the captured account and a bounded GET', () async {
    final server = _Server();
    final service = server.service();
    addTearDown(service.onClose);
    final result = await service.load();
    expect(result.creatorEvidence?.pending.single.id, 'pending-1');
    expect(result.creatorEvidence?.reviewHold, hasLength(2));
    final request = server.requests.singleWhere(
      (r) => r.url.path == '/v1/content-engagement/rewards/evidence',
    );
    expect(request.method, 'GET');
    expect(request.url.queryParameters, {'limit': '10'});
    expect(request.headers['Authorization'], 'Bearer test-token-account-a');
    expect(request.body, isEmpty);
  });

  test(
    'unknown evidence stays distinct from an empty activity history',
    () async {
      final server = _Server()..evidenceUnavailable = true;
      final service = server.service();
      addTearDown(service.onClose);
      final unavailable = await service.load();
      expect(unavailable.creatorEvidence, isNull);
      expect(unavailable.wallet.available, 1200);
      server.evidenceUnavailable = false;
      server.evidence = {'pending': [], 'reviewHold': [], 'submitted': []};
      final empty = await service.load();
      expect(empty.creatorEvidence?.isEmpty, isTrue);
      expect(empty.wallet.available, 1200);
    },
  );

  test(
    'late creator evidence cannot complete an old account overview',
    () async {
      final server = _Server()..delayedEvidence = Completer<http.Response>();
      final service = server.service();
      addTearDown(service.onClose);
      final result = service.load();
      final rejected = expectLater(
        result,
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'context_changed',
          ),
        ),
      );
      while (!server.requests.any(
        (r) => r.url.path == '/v1/content-engagement/rewards/evidence',
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      server.account = 'account-b';
      server.delayedEvidence!.complete(_Server.ok(_evidence()));
      await rejected;
    },
  );

  test(
    'malformed, duplicate, oversized and wrongly grouped evidence is rejected',
    () {
      final bad = <Object?>[
        null,
        {'pending': [], 'submitted': []},
        {
          ..._evidence(),
          'pending': [_row('id', 'game', 'submitted', 'qualified')],
        },
        {
          ..._evidence(),
          'pending': [
            _row('id', 'game', 'pending', 'qualified')..remove('qualifiedAt'),
          ],
        },
        {
          ..._evidence(),
          'pending': [_row('funding-1', 'game', 'pending', 'qualified')],
        },
        {
          ..._evidence(),
          'reviewHold': [
            _row('bad-kind', 'video', 'review_hold', 'risk_review'),
          ],
        },
        {
          ..._evidence(),
          'pending': [
            _row('retired-article', 'article', 'pending', 'qualified'),
          ],
        },
        {
          ..._evidence(),
          'pending': List.generate(
            11,
            (i) => _row('id-$i', 'game', 'pending', 'qualified'),
          ),
        },
      ];
      for (final value in bad) {
        expect(
          () => CreatorRewardEvidencePage.fromJson(value),
          throwsFormatException,
        );
      }
      final parsed = CreatorRewardEvidencePage.fromJson(_evidence());
      expect(() => parsed.pending.clear(), throwsUnsupportedError);
    },
  );
}
