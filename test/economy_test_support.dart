import 'package:maaso/src/features/economy/data/economy_market_gateway.dart';
import 'package:maaso/src/features/economy/domain/economy_market_info.dart';
import 'membership_benefits_test_support.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';

// Values in this fixture are test-only, never production price policy.
final class FakeEconomyGateway implements EconomyGateway, EconomyMarketGateway {
  @override
  String requestContextKey = 'test|account-a';
  String policyVersion = 'test-policy-v1';
  String? responsePolicyVersion;
  Future<MembershipAvailability> Function()? availabilityOverride;
  @override
  Future<MembershipAvailability> membershipAvailability(String context) async =>
      availabilityOverride != null
      ? availabilityOverride!()
      : MembershipAvailability.fromJson(
          benefitsAvailabilityJson(
            version: policyVersion,
            ready: ready && !unavailable,
          ),
        );
  DateTime now = DateTime.utc(2030, 1, 1);
  bool ready = true, unavailable = false, failAfterCommitOnce = false;
  List<MembershipTier> catalogTiers = MembershipTier.legacyTiers;
  int? currentProUsdCents;
  int available = 1200, quoteCalls = 0, redeemCalls = 0, debits = 0;
  final requestIds = <String>[];
  final receipts = <String, EconomyRedemption>{};
  final grants = <EconomyMembershipGrant>[];
  EconomyMembershipQuote? lastQuote;
  Future<EconomyWallet> Function()? walletOverride;
  Future<EconomyLedgerPage> Function(int)? ledgerOverride;
  Future<EconomyRedemption> Function(String, String)? redeemOverride;
  @override
  Future<EconomyCatalog> catalog(String context) async {
    if (unavailable) throw const EconomyException('ECONOMY_UNAVAILABLE');
    return EconomyCatalog(
      memberships: [
        for (final tier in catalogTiers)
          MembershipOffer(
            tier: tier,
            cashUsdCents: tier == MembershipTier.proV2
                ? currentProUsdCents ?? tier.cashUsdCents
                : tier.cashUsdCents,
            priceCoins: ready ? price(tier) : null,
          ),
      ],
      membershipReady: ready,
      unavailableReason: ready ? '' : 'MEMBERSHIP_CAPABILITY_UNAVAILABLE',
      topUpsReady: false,
      cashCheckoutReady: false,
    );
  }

  int price(MembershipTier tier) => switch (tier) {
    MembershipTier.plus => 300,
    MembershipTier.pro || MembershipTier.proV2 => 500,
    MembershipTier.max => 1800,
    MembershipTier.ultra => 4000,
    MembershipTier.basic => 100,
  };
  @override
  Future<EconomyWallet> wallet(String context) async => walletOverride != null
      ? walletOverride!()
      : EconomyWallet(
          available: available,
          pending: 70,
          frozen: 20,
          total: available + 90,
          purchasedAvailable: available - 200,
          earnedAvailable: 200,
          blocked: false,
          version: 1,
          playerName: 'Sky',
        );
  @override
  Future<EconomyLedgerPage> ledger(String context, {int beforeId = 0}) async =>
      ledgerOverride != null
      ? ledgerOverride!(beforeId)
      : EconomyLedgerPage(
          items: beforeId == 0
              ? [
                  EconomyLedgerEntry(
                    id: 1,
                    transactionId: 'test-transaction',
                    bucket: 'purchased_available',
                    delta: 1000,
                    balanceAfter: 1000,
                    createdAt: now,
                  ),
                ]
              : [],
          nextBeforeId: 0,
        );
  @override
  Future<List<EconomyRewardEstimate>> pendingRewards(String context) async => [
    EconomyRewardEstimate(poolKey: 'game', day: now, coins: 17),
  ];
  @override
  Future<EconomyMembership> membership(String context) async =>
      EconomyMembership(
        activeTier: grants.isEmpty ? null : grants.first.tier,
        grants: List.of(grants),
      );
  @override
  Future<EconomyMembershipQuote> quoteMembership(
    String context,
    MembershipTier tier, {
    String? expectedPolicyVersion,
  }) async {
    quoteCalls++;
    lastQuote = EconomyMembershipQuote(
      id: 'quote-$quoteCalls',
      policyVersion: responsePolicyVersion ?? expectedPolicyVersion ?? '',
      tier: tier,
      price: price(tier),
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    return lastQuote!;
  }

  @override
  Future<EconomyRedemption> redeem(
    String context, {
    required String quoteId,
    required String requestId,
  }) async {
    redeemCalls++;
    requestIds.add(requestId);
    if (redeemOverride != null) return redeemOverride!(quoteId, requestId);
    if (receipts.containsKey(requestId)) return receipts[requestId]!;
    final quote = lastQuote!;
    if (available < quote.price) {
      throw const EconomyException('INSUFFICIENT_COINS');
    }
    final grant = EconomyMembershipGrant(
      id: 'grant-1',
      tier: quote.tier,
      source: 'coins',
      transactionId: 'transaction-1',
      startsAt: now,
      expiresAt: now.add(const Duration(days: 30)),
    );
    final result = EconomyRedemption(
      transactionId: grant.transactionId,
      quoteId: quoteId,
      price: quote.price,
      grant: grant,
    );
    receipts[requestId] = result;
    grants.add(grant);
    available -= quote.price;
    debits++;
    if (failAfterCommitOnce) {
      failAfterCommitOnce = false;
      throw const EconomyException('connection_unavailable');
    }
    return result;
  }
}

Map<String, Object?> economyWalletJson() => {
  'actor': {'actorId': 'pa_public', 'name': 'Sky', 'kind': 'player'},
  'availableCoins': 1200,
  'pendingCoins': 70,
  'frozenCoins': 20,
  'totalCoins': 1290,
  'purchasedAvailable': 1000,
  'earnedAvailable': 200,
  'purchasedFrozen': 20,
  'earnedFrozen': 0,
  'purchasedPending': 0,
  'earnedPending': 70,
  'spendingBlocked': false,
  'version': 1,
};
Map<String, Object?> economyCatalogJson({bool ready = true}) => {
  'memberships': [
    for (final tier in MembershipTier.legacyTiers)
      {
        'tier': tier.name,
        'cashUsdCents': tier.cashUsdCents,
        'durationDays': 30,
        'priceCoins': ready ? 300 : null,
      },
  ],
  'membershipReady': ready,
  'membershipUnavailableReason': ready
      ? ''
      : 'MEMBERSHIP_CAPABILITY_UNAVAILABLE',
  'topUpsReady': false,
  'cashCheckoutReady': false,
};
Map<String, Object?> economyQuoteJson() => {
  'quoteId': 'quote-1',
  'kind': 'membership',
  'productId': 'plus',
  'priceCoins': 300,
  'cashUsdCents': 1990,
  'durationDays': 30,
  'expiresAt': '2030-01-01T00:05:00Z',
};
