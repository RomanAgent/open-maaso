import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/economy/application/economy_service.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_market_info.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';

Map<String, Object?> availabilityJSON() => {
  'checkedAt': '2026-09-13T00:00:00Z',
  'tiers': [
    for (final tier in MembershipTier.legacyTiers)
      {
        'tier': tier.name,
        'available': tier == MembershipTier.plus,
        if (tier != MembershipTier.plus) 'reason': 'capacity_unavailable',
      },
  ],
};
void main() {
  test(
    'membership capacity reads use the authenticated public endpoint',
    () async {
      final paths = <String>[];
      final client = EconomyHttpClient(
        baseUri: () => Uri.parse('https://test.example/'),
        accountId: () => 'account-A',
        accessToken: () async => 'token',
        client: MockClient((r) async {
          paths.add(r.url.path);
          expect(r.method, 'GET');
          expect(r.headers['Authorization'], 'Bearer token');
          expect(r.url.query, '');
          return http.Response(
            jsonEncode({'code': 'OK', 'data': availabilityJSON()}),
            200,
          );
        }),
      );
      final service = EconomyService(gateway: client);
      expect(
        (await service.readMembershipAvailability()).tiers.first.available,
        true,
      );
      expect(paths, ['/v1/membership/availability']);
      service.onClose();
      client.close();
    },
  );
  test(
    'incomplete tiers and inconsistent availability never imply capacity',
    () {
      expect(
        () => MembershipAvailability.fromJson({
          ...availabilityJSON(),
          'tiers': [],
        }),
        throwsFormatException,
      );
      expect(
        () => TierCapacity.fromJson({
          'tier': 'plus',
          'available': true,
          'reason': 'capacity_unavailable',
        }),
        throwsFormatException,
      );
    },
  );
  test('account change fences late availability', () async {
    var account = 'A';
    final pending = Completer<http.Response>();
    final client = EconomyHttpClient(
      baseUri: () => Uri.parse('https://test.example/'),
      accountId: () => account,
      accessToken: () async => 'token',
      client: MockClient((_) => pending.future),
    );
    final service = EconomyService(gateway: client);
    final read = service.readMembershipAvailability();
    await Future<void>.delayed(Duration.zero);
    account = 'B';
    pending.complete(
      http.Response(
        jsonEncode({'code': 'OK', 'data': availabilityJSON()}),
        200,
      ),
    );
    await expectLater(
      read,
      throwsA(
        isA<EconomyException>().having(
          (e) => e.code,
          'code',
          'context_changed',
        ),
      ),
    );
    service.onClose();
    client.close();
  });
}
