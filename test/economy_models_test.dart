import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'economy_test_support.dart';

void main() {
  test(
    'wallet keeps estimates outside minted balance and checks conservation',
    () {
      final wallet = EconomyWallet.fromJson(economyWalletJson());
      expect(wallet.total, 1290);
      expect(wallet.available, 1200);
      expect(wallet.pending, 70);
      expect(
        () => EconomyWallet.fromJson({
          ...economyWalletJson(),
          'totalCoins': 1307,
        }),
        throwsFormatException,
      );
      expect(
        () => EconomyWallet.fromJson({
          ...economyWalletJson(),
          'earnedAvailable': 201,
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'four exact USD tiers are required and readiness cannot invent prices',
    () {
      final catalog = EconomyCatalog.fromJson(economyCatalogJson(ready: false));
      expect(catalog.memberships.map((v) => v.tier.usdLabel), [
        r'$19.90',
        r'$29.90',
        r'$100.00',
        r'$200.00',
      ]);
      expect(catalog.memberships.every((v) => v.priceCoins == null), isTrue);
      expect(
        () => EconomyCatalog.fromJson({
          ...economyCatalogJson(ready: false),
          'membershipReady': true,
        }),
        throwsFormatException,
      );
      expect(
        () => MembershipOffer.fromJson({
          'tier': 'plus',
          'cashUsdCents': 1900,
          'priceCoins': 300,
          'durationDays': 30,
        }),
        throwsFormatException,
      );
    },
  );
  test('coins are bounded integers and quotes explicitly buy thirty days', () {
    for (final value in [1.2, -1, 9000000000000001, '100']) {
      expect(() => economyInteger(value), throwsFormatException);
    }
    expect(economyInteger(maxEconomyInteger), maxEconomyInteger);
    expect(EconomyMembershipQuote.fromJson(economyQuoteJson()).price, 300);
    expect(
      () => EconomyMembershipQuote.fromJson({
        ...economyQuoteJson(),
        'durationDays': 365,
      }),
      throwsFormatException,
    );
  });
}
