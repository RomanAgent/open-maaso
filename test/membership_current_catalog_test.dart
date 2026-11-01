import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/economy_market_info.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';

void main() {
  Map<String, Object?> catalog(List<MembershipTier> tiers) => {
    'memberships': [
      for (final tier in tiers)
        {
          'tier': tier.wireName,
          'cashUsdCents': tier.cashUsdCents,
          'durationDays': 30,
        },
    ],
    'membershipReady': false,
    'membershipUnavailableReason': 'MEMBERSHIP_CAPABILITY_UNAVAILABLE',
    'topUpsReady': false,
    'cashCheckoutReady': false,
  };

  test('new monthly plans and legacy receipts retain separate identities', () {
    expect(MembershipTier.currentTiers.map((t) => t.wireName), [
      'basic',
      'plus',
      'pro_v2',
    ]);
    expect(MembershipTier.currentTiers.map((t) => t.cashUsdCents), [
      990,
      1990,
      2990,
    ]);
    expect(MembershipTier.proV2.title, 'Pro');
    expect(MembershipTier.parse('pro'), MembershipTier.pro);
    expect(MembershipTier.parse('pro').cashUsdCents, 2990);
    expect(MembershipTier.parse('pro_v2'), MembershipTier.proV2);
    expect(() => MembershipTier.parse('proV2'), throwsFormatException);
    expect(() => MembershipTier.parse('free'), throwsFormatException);
  });

  test(
    'catalog accepts complete new or legacy policy but rejects mixtures',
    () {
      expect(
        EconomyCatalog.fromJson(
          catalog(MembershipTier.currentTiers),
        ).memberships.length,
        3,
      );
      expect(
        EconomyCatalog.fromJson(
          catalog(MembershipTier.legacyTiers),
        ).memberships.length,
        4,
      );
      for (final tiers in [
        [MembershipTier.basic, MembershipTier.plus],
        [MembershipTier.basic, MembershipTier.plus, MembershipTier.pro],
        [MembershipTier.basic, MembershipTier.plus, MembershipTier.plus],
        MembershipTier.values,
      ]) {
        expect(
          () => EconomyCatalog.fromJson(catalog(tiers)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'new availability and store contracts use pro_v2 without repricing pro',
    () {
      final availability = MembershipAvailability.fromJson({
        'checkedAt': '2026-09-15T00:00:00Z',
        'tiers': [
          for (final tier in MembershipTier.currentTiers)
            {
              'tier': tier.wireName,
              'available': false,
              'reason': 'model_unavailable',
            },
        ],
      });
      expect(
        availability.tiers.map((t) => t.tier),
        MembershipTier.currentTiers,
      );
      Map<String, Object?> product(String tier, int cents) => {
        'provider': 'ios',
        'productId': tier == 'pro_v2'
            ? 'maaso.membership.pro.monthly.v3'
            : 'maaso.membership.$tier.monthly.v1',
        'kind': 'membership',
        'tier': tier,
        'cashUsdCents': cents,
      };
      expect(
        StoreProduct.fromJson(product('pro_v2', 2990)).tier,
        MembershipTier.proV2,
      );
      expect(
        StoreProduct.fromJson(product('pro', 2990)).tier,
        MembershipTier.pro,
      );
      expect(
        () => StoreProduct.fromJson(product('pro', 10000)),
        throwsFormatException,
      );
      expect(
        () => StoreProduct.fromJson(product('pro_v2', 10000)),
        throwsFormatException,
      );
    },
  );
}
