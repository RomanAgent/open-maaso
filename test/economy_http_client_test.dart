import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'economy_test_support.dart';

void main() {
  test(
    'membership quote sends token and tier, never caller coins or account',
    () async {
      late http.Request captured;
      final client = EconomyHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'private-account',
        accessToken: () async => 'existing-token',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'code': 'OK', 'data': economyQuoteJson()}),
            200,
          );
        }),
      );
      final quote = await client.quoteMembership(
        client.requestContextKey,
        MembershipTier.plus,
      );
      expect(quote.price, 300);
      expect(captured.url.path, '/v1/economy/quotes');
      expect(captured.headers['Authorization'], 'Bearer existing-token');
      expect(jsonDecode(captured.body), {
        'kind': 'membership',
        'productId': 'plus',
      });
      expect(captured.body, isNot(contains('private-account')));
      client.close();
    },
  );
  test(
    'account switch while resolving a token prevents network dispatch',
    () async {
      var account = 'a';
      var calls = 0;
      final token = Completer<String>();
      final client = EconomyHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final request = client.wallet(client.requestContextKey);
      account = 'b';
      token.complete('old-token');
      await expectLater(
        request,
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'context_changed',
          ),
        ),
      );
      expect(calls, 0);
      client.close();
    },
  );
  test(
    'late response is rejected after an account or environment switch',
    () async {
      var uri = Uri.parse('https://first.test/');
      final response = Completer<http.Response>();
      final client = EconomyHttpClient(
        baseUri: () => uri,
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient((_) => response.future),
      );
      final request = client.wallet(client.requestContextKey);
      await Future<void>.delayed(Duration.zero);
      uri = Uri.parse('https://second.test/');
      response.complete(
        http.Response(
          jsonEncode({'code': 'OK', 'data': economyWalletJson()}),
          200,
        ),
      );
      await expectLater(
        request,
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'context_changed',
          ),
        ),
      );
      client.close();
    },
  );
  test(
    'server shortages and invalid balances are surfaced without success',
    () async {
      var invalid = false;
      final client = EconomyHttpClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient(
          (_) async => invalid
              ? http.Response(
                  jsonEncode({
                    'code': 'OK',
                    'data': {...economyWalletJson(), 'totalCoins': 1},
                  }),
                  200,
                )
              : http.Response('{"code":"INSUFFICIENT_COINS"}', 409),
        ),
      );
      await expectLater(
        client.redeem(client.requestContextKey, quoteId: 'q', requestId: 'r'),
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'INSUFFICIENT_COINS',
          ),
        ),
      );
      invalid = true;
      await expectLater(
        client.wallet(client.requestContextKey),
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      client.close();
    },
  );
}
