import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/economy/application/economy_service.dart';
import 'package:maaso/src/features/economy/application/membership_review.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/data/membership_availability_reader.dart';
import 'package:maaso/src/features/economy/data/native_store_gateway.dart';
import 'package:maaso/src/features/economy/data/store_payment_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_market_info.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/membership_benefits.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';
import 'package:maaso/src/features/economy/presentation/membership_page.dart';
import 'economy_store_purchase_test.dart'
    show StoreGatewayFake, NativeStoreFake, storeNow;
import 'economy_test_support.dart';
import 'membership_benefits_test_support.dart';

const memberProduct = StoreProduct(
  provider: 'ios',
  id: 'test.plus',
  plan: '',
  kind: 'membership',
  usdCents: 1990,
  coins: 0,
  tier: MembershipTier.plus,
);

class MemberStoreGateway extends StoreGatewayFake
    implements MembershipAvailabilityReader {
  String version = 'test-policy-v1';
  String? checkoutVersion, expected;
  Completer<MembershipAvailability>? pendingAvailability;
  @override
  Future<MembershipAvailability> membershipAvailability(String context) async {
    if (pendingAvailability != null) return pendingAvailability!.future;
    return MembershipAvailability.fromJson(
      benefitsAvailabilityJson(version: version),
    );
  }

  @override
  Future<List<StoreOffer>> catalog(String context, String provider) async => [
    const StoreOffer(memberProduct, true, ''),
  ];
  @override
  Future<StoreCheckout> checkout(
    String context,
    StoreProduct p, {
    String? expectedPolicyVersion,
  }) async {
    calls.add('checkout');
    expected = expectedPolicyVersion;
    return StoreCheckout(
      id: 'member-intent',
      binding: '11111111-1111-4111-8111-111111111111',
      product: p,
      policyVersion: checkoutVersion ?? expectedPolicyVersion ?? '',
      expiresAt: storeNow.add(const Duration(minutes: 15)),
    );
  }
}

class MemberNative extends NativeStoreFake {
  @override
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed) async =>
      [
        const NativeStoreProduct(
          product: memberProduct,
          price: r'$19.90',
          handle: 'member',
        ),
      ];
}

Matcher economyError(String code) =>
    throwsA(isA<EconomyException>().having((e) => e.code, 'code', code));
void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  test('model metadata is exact, bounded, and tied to its tier', () {
    final availability = MembershipAvailability.fromJson(
      benefitsAvailabilityJson(),
    );
    final terms = reviewMembershipTerms(availability, MembershipTier.pro);
    expect(terms.model.modelId, 'server-pro-model');
    expect(terms.model.dailyTokens, 40000);
    expect(terms.model.grantTokens, 200000);
    expect(terms.policyVersion, 'test-policy-v1');
    expect(
      () => TierCapacity.fromJson({
        'tier': 'plus',
        'available': true,
        'model': benefitsModelJson(MembershipTier.pro),
      }),
      throwsFormatException,
    );
    expect(
      () => MembershipTierBenefits.fromJson({
        ...benefitsModelJson(MembershipTier.plus),
        'maxOutputTokens': 9000,
      }),
      throwsFormatException,
    );
    expect(
      () => MembershipTierBenefits.fromJson({
        ...benefitsModelJson(MembershipTier.plus),
        'dailyTokens': 0,
      }),
      throwsFormatException,
    );
    final legacy = MembershipAvailability(availability.checkedAt, [
      for (final tier in MembershipTier.legacyTiers)
        TierCapacity(tier, true, ''),
    ]);
    expect(
      () => reviewMembershipTerms(legacy, MembershipTier.plus),
      throwsA(isA<EconomyException>()),
    );
  });
  test(
    'coin quote version mismatch and missing details never create a purchase',
    () async {
      final g = FakeEconomyGateway()
        ..responsePolicyVersion = 'unexpected-version';
      final s = EconomyService(gateway: g, now: () => g.now);
      await expectLater(
        s.prepareQuote(MembershipTier.plus),
        economyError('membership_policy_changed'),
      );
      expect(s.pending, isNull);
      expect(g.debits, 0);
      g.availabilityOverride = () async => MembershipAvailability(g.now, [
        for (final tier in MembershipTier.legacyTiers)
          TierCapacity(tier, true, ''),
      ]);
      await expectLater(
        s.prepareQuote(MembershipTier.plus),
        economyError('membership_details_unavailable'),
      );
      expect(g.quoteCalls, 1);
      s.onClose();
    },
  );
  test(
    'uncertain coin retry keeps original model and version after configuration changes',
    () async {
      final g = FakeEconomyGateway()..failAfterCommitOnce = true;
      final s = EconomyService(
        gateway: g,
        now: () => g.now,
        requestId: () => 'same-purchase',
      );
      final q = await s.prepareQuote(MembershipTier.plus);
      await expectLater(
        s.confirm(q.id),
        economyError('connection_unavailable'),
      );
      final original = s.pending!.reviewedTerms;
      g.policyVersion = 'new-policy';
      g.ready = false;
      await expectLater(
        s.prepareQuote(MembershipTier.pro),
        economyError('purchase_unresolved'),
      );
      expect(identical(s.pending!.reviewedTerms, original), true);
      expect(original.policyVersion, 'test-policy-v1');
      await s.confirm(q.id);
      expect(g.debits, 1);
      expect(g.requestIds.toSet().length, 1);
      s.onClose();
    },
  );
  test(
    'both authenticated write clients send the reviewed policy version',
    () async {
      final captured = <http.Request>[];
      final transport = MockClient((r) async {
        captured.add(r);
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'data': r.url.path.endsWith('quotes')
                ? {...economyQuoteJson(), 'policyVersion': 'review-v1'}
                : {
                    'intentId': 'intent',
                    'accountBinding': '11111111-1111-4111-8111-111111111111',
                    'policyVersion': 'review-v1',
                    'expiresAt': '2030-01-01T00:15:00Z',
                    'product': {
                      'provider': 'ios',
                      'productId': 'test.plus',
                      'basePlanId': '',
                      'kind': 'membership',
                      'tier': 'plus',
                      'cashUsdCents': 1990,
                      'topUpCoins': 0,
                    },
                  },
          }),
          200,
        );
      });
      final econ = EconomyHttpClient(
        baseUri: () => Uri.parse('https://test.example/'),
        accountId: () => 'private',
        accessToken: () async => 'token',
        client: transport,
      );
      final store = StorePaymentHttpClient(
        baseUri: () => Uri.parse('https://test.example/'),
        accountId: () => 'private',
        accessToken: () async => 'token',
        client: transport,
      );
      expect(
        (await econ.quoteMembership(
          econ.requestContextKey,
          MembershipTier.plus,
          expectedPolicyVersion: 'review-v1',
        )).policyVersion,
        'review-v1',
      );
      expect(
        (await store.checkout(
          store.requestContextKey,
          memberProduct,
          expectedPolicyVersion: 'review-v1',
        )).policyVersion,
        'review-v1',
      );
      for (final request in captured) {
        expect(jsonDecode(request.body)['expectedPolicyVersion'], 'review-v1');
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.body, isNot(contains('private')));
      }
      econ.close();
      store.close();
      transport.close();
    },
  );
  test(
    'cash membership cannot open SDK without matching reviewed checkout',
    () async {
      final g = MemberStoreGateway(), n = MemberNative();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      await expectLater(
        s.buy(s.products.single),
        economyError('membership_details_unavailable'),
      );
      expect(g.calls, isNot(contains('checkout')));
      expect(n.buys, 0);
      g.checkoutVersion = 'other';
      await expectLater(
        s.buy(s.products.single, expectedPolicyVersion: 'reviewed'),
        economyError('membership_policy_changed'),
      );
      expect(n.buys, 0);
      expect(g.calls, contains('cancel'));
      g.checkoutVersion = 'reviewed';
      await s.buy(s.products.single, expectedPolicyVersion: 'reviewed');
      expect(g.expected, 'reviewed');
      expect(n.buys, 1);
      s.onClose();
      await n.updates.close();
    },
  );
  test(
    'cash availability is fenced when account switches during read',
    () async {
      final g = MemberStoreGateway()
        ..pendingAvailability = Completer<MembershipAvailability>();
      final s = StorePurchaseService(gateway: g, now: () => storeNow);
      final read = s.readMembershipAvailability();
      g.contextKey = 'new-account';
      g.pendingAvailability!.complete(
        MembershipAvailability.fromJson(benefitsAvailabilityJson()),
      );
      await expectLater(read, economyError('context_changed'));
      s.onClose();
    },
  );
  testWidgets(
    'cash review binds shown model version and remains usable at two-times text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = MemberStoreGateway(), n = MemberNative();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(
                ctx,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: MembershipPage(route: '/membership', service: s),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final plans = find.descendant(
        of: find.byKey(const ValueKey('membership-plans-scroll')),
        matching: find.byType(Scrollable),
      );
      final selection = find.byKey(const ValueKey('membership-select-plus'));
      await tester.scrollUntilVisible(selection, 250, scrollable: plans);
      await tester.tap(selection);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('membership-purchase')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('server-plus-model'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('Monthly auto-renewing'),
        ),
        findsOneWidget,
      );
      expect(n.buys, 0);
      expect(g.calls, isNot(contains('checkout')));
      g.version = 'after-review';
      await tester.tap(find.byKey(const ValueKey('membership-human-confirm')));
      // Native checkout remains pending until a store event arrives, so its
      // processing indicator intentionally keeps animating after confirmation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(g.expected, 'test-policy-v1');
      expect(n.buys, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('membership-purchase')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      s.onClose();
      await n.updates.close();
    },
  );
}
