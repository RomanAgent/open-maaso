import 'creator_reward_evidence.dart';

const maxEconomyInteger = 9000000000000000;

String economyUsdLabel(int cashUsdCents) =>
    '\$${cashUsdCents ~/ 100}.${(cashUsdCents % 100).toString().padLeft(2, '0')}';

enum MembershipTier {
  plus(1990),
  pro(2990),
  max(10000),
  ultra(20000),
  basic(990),
  proV2(2990);

  const MembershipTier(this.cashUsdCents);
  final int cashUsdCents;

  /// Persisted v1 tier identities and prices remain readable for restores.
  /// Current offer prices; historical store prices are keyed by immutable SKU.
  /// Current Pro keeps its distinct wire identity and never becomes v1 Pro.
  static const currentTiers = [basic, plus, proV2];
  static const legacyTiers = [plus, pro, max, ultra];
  String get wireName => this == proV2 ? 'pro_v2' : name;
  bool get isCurrent => currentTiers.contains(this);
  String get title =>
      this == proV2 ? 'Pro' : name[0].toUpperCase() + name.substring(1);
  String get modelDisplayName => switch (this) {
    basic => 'GLM-5.3-Flash',
    plus => 'DeepSeek-V4.1-Flash',
    proV2 => 'DeepSeek-V4-Pro',
    pro || max || ultra => '',
  };
  String get usdLabel => economyUsdLabel(cashUsdCents);
  static MembershipTier parse(Object? value) => values.firstWhere(
    (tier) => tier.wireName == value,
    orElse: () => throw const FormatException('invalid_membership_tier'),
  );

  static bool isCompleteCatalog(Iterable<MembershipTier> entries) {
    final list = entries.toList(growable: false);
    final set = list.toSet();
    if (set.length != list.length) return false;
    return (set.length == currentTiers.length &&
            set.containsAll(currentTiers)) ||
        (set.length == legacyTiers.length && set.containsAll(legacyTiers));
  }
}

final class EconomyException implements Exception {
  const EconomyException(this.code, {this.statusCode});
  final String code;
  final int? statusCode;
  bool get definiteRefusal => const {
    'INSUFFICIENT_COINS',
    'QUOTE_EXPIRED',
    'QUOTE_UNAVAILABLE',
    'MEMBERSHIP_TIER_CONFLICT',
    'ECONOMY_CONFLICT',
    'WALLET_FROZEN',
    'IDENTITY_REQUIRED',
    'ECONOMY_LIMIT',
    'VALIDATION',
    'MEMBERSHIP_CAPABILITY_UNAVAILABLE',
    'ECONOMY_POLICY_UNAVAILABLE',
  }.contains(code);
  @override
  String toString() => 'Economy request failed ($code)';
}

Map<String, dynamic> economyObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_economy_object');
  }
  return value;
}

int economyInteger(
  Object? value, {
  bool signed = false,
  bool positive = false,
}) {
  if (value is! int ||
      value > maxEconomyInteger ||
      value <
          (signed
              ? -maxEconomyInteger
              : positive
              ? 1
              : 0)) {
    throw const FormatException('invalid_economy_integer');
  }
  return value;
}

String economyString(Object? value, {bool empty = false, int max = 160}) {
  if (value is! String || value.length > max || (!empty && value.isEmpty)) {
    throw const FormatException('invalid_economy_string');
  }
  return value;
}

DateTime economyTime(Object? value) {
  final parsed = DateTime.tryParse(economyString(value, max: 40));
  if (parsed == null) throw const FormatException('invalid_economy_time');
  return parsed.toUtc();
}

List<T> economyList<T>(
  Object? value,
  T Function(Object?) parse, {
  int max = 100,
}) {
  if (value is! List || value.length > max) {
    throw const FormatException('invalid_economy_list');
  }
  return List.unmodifiable(value.map(parse));
}

final class MembershipOffer {
  const MembershipOffer({
    required this.tier,
    required this.cashUsdCents,
    this.priceCoins,
  });
  final MembershipTier tier;
  final int cashUsdCents;
  final int? priceCoins;
  String get usdLabel => economyUsdLabel(cashUsdCents);
  factory MembershipOffer.fromJson(Object? value) {
    final map = economyObject(value);
    final tier = MembershipTier.parse(map['tier']);
    final cents = economyInteger(map['cashUsdCents'], positive: true);
    final baselinePro = tier == MembershipTier.proV2 && cents == 10000;
    if ((cents != tier.cashUsdCents && !baselinePro) ||
        map['durationDays'] != 30) {
      throw const FormatException('membership_contract_mismatch');
    }
    return MembershipOffer(
      tier: tier,
      cashUsdCents: cents,
      priceCoins: map['priceCoins'] == null
          ? null
          : economyInteger(map['priceCoins'], positive: true),
    );
  }
}

final class EconomyCatalog {
  const EconomyCatalog({
    required this.memberships,
    required this.membershipReady,
    required this.unavailableReason,
    required this.topUpsReady,
    required this.cashCheckoutReady,
  });
  final List<MembershipOffer> memberships;
  final bool membershipReady, topUpsReady, cashCheckoutReady;
  final String unavailableReason;
  factory EconomyCatalog.fromJson(Object? value) {
    final map = economyObject(value);
    final offers = economyList(
      map['memberships'],
      MembershipOffer.fromJson,
      max: MembershipTier.legacyTiers.length,
    );
    if (!MembershipTier.isCompleteCatalog(offers.map((offer) => offer.tier)) ||
        map['membershipReady'] is! bool ||
        map['topUpsReady'] is! bool ||
        map['cashCheckoutReady'] is! bool) {
      throw const FormatException('incomplete_economy_catalog');
    }
    if (map['membershipReady'] == true &&
        offers.any((offer) => offer.priceCoins == null)) {
      throw const FormatException('ready_without_price');
    }
    return EconomyCatalog(
      memberships: offers,
      membershipReady: map['membershipReady'] as bool,
      unavailableReason: economyString(
        map['membershipUnavailableReason'],
        empty: true,
        max: 80,
      ),
      topUpsReady: map['topUpsReady'] as bool,
      cashCheckoutReady: map['cashCheckoutReady'] as bool,
    );
  }
}

final class EconomyWallet {
  const EconomyWallet({
    required this.available,
    required this.pending,
    required this.frozen,
    required this.total,
    required this.purchasedAvailable,
    required this.earnedAvailable,
    required this.blocked,
    required this.version,
    required this.playerName,
  });
  final int available,
      pending,
      frozen,
      total,
      purchasedAvailable,
      earnedAvailable,
      version;
  final bool blocked;
  final String playerName;
  factory EconomyWallet.fromJson(Object? value) {
    final map = economyObject(value);
    final available = economyInteger(map['availableCoins']);
    final pending = economyInteger(map['pendingCoins']);
    final frozen = economyInteger(map['frozenCoins']);
    final total = economyInteger(map['totalCoins']);
    final pa = economyInteger(map['purchasedAvailable']);
    final ea = economyInteger(map['earnedAvailable']);
    final pf = economyInteger(map['purchasedFrozen']);
    final ef = economyInteger(map['earnedFrozen']);
    final pp = economyInteger(map['purchasedPending']);
    final ep = economyInteger(map['earnedPending']);
    if (available + pending + frozen != total ||
        pa + ea != available ||
        pf + ef != frozen ||
        pp + ep != pending ||
        map['spendingBlocked'] is! bool) {
      throw const FormatException('wallet_conservation_failed');
    }
    final actor = economyObject(map['actor']);
    if (actor['kind'] != 'player') {
      throw const FormatException('invalid_wallet_actor');
    }
    return EconomyWallet(
      available: available,
      pending: pending,
      frozen: frozen,
      total: total,
      purchasedAvailable: pa,
      earnedAvailable: ea,
      blocked: map['spendingBlocked'] as bool,
      version: economyInteger(map['version']),
      playerName: economyString(actor['name'], empty: true),
    );
  }
}

final class EconomyLedgerEntry {
  const EconomyLedgerEntry({
    required this.id,
    required this.transactionId,
    required this.bucket,
    required this.delta,
    required this.balanceAfter,
    required this.createdAt,
  });
  final int id, delta, balanceAfter;
  final String transactionId, bucket;
  final DateTime createdAt;
  factory EconomyLedgerEntry.fromJson(Object? value) {
    final map = economyObject(value);
    final bucket = economyString(map['bucket']);
    if (!const {
      'purchased_available',
      'earned_available',
      'purchased_frozen',
      'earned_frozen',
      'purchased_pending',
      'earned_pending',
    }.contains(bucket)) {
      throw const FormatException('invalid_ledger_bucket');
    }
    final delta = economyInteger(map['deltaCoins'], signed: true);
    if (delta == 0) throw const FormatException('empty_ledger_posting');
    return EconomyLedgerEntry(
      id: economyInteger(map['id'], positive: true),
      transactionId: economyString(map['transactionId'], max: 36),
      bucket: bucket,
      delta: delta,
      balanceAfter: economyInteger(map['balanceAfter']),
      createdAt: economyTime(map['createdAt']),
    );
  }
}

final class EconomyLedgerPage {
  const EconomyLedgerPage({required this.items, required this.nextBeforeId});
  final List<EconomyLedgerEntry> items;
  final int nextBeforeId;
  factory EconomyLedgerPage.fromJson(Object? value) {
    final map = economyObject(value);
    final rows = economyList(map['items'], EconomyLedgerEntry.fromJson);
    for (var i = 1; i < rows.length; i++) {
      if (rows[i].id >= rows[i - 1].id) {
        throw const FormatException('unordered_ledger');
      }
    }
    final cursor = economyInteger(map['nextBeforeId'] ?? 0);
    if (cursor > 0 && (rows.isEmpty || rows.last.id != cursor)) {
      throw const FormatException('invalid_ledger_cursor');
    }
    return EconomyLedgerPage(items: rows, nextBeforeId: cursor);
  }
}

final class EconomyRewardEstimate {
  const EconomyRewardEstimate({
    required this.poolKey,
    required this.day,
    required this.coins,
  });
  final String poolKey;
  final DateTime day;
  final int coins;
  factory EconomyRewardEstimate.fromJson(Object? value) {
    final map = economyObject(value);
    if (map['isEstimate'] != true) {
      throw const FormatException('settled_reward_in_pending_list');
    }
    economyInteger(map['units'], positive: true);
    return EconomyRewardEstimate(
      poolKey: economyString(map['poolKey'], max: 64),
      day: economyTime(map['rewardDay']),
      coins: economyInteger(map['estimatedCoins']),
    );
  }
}

final class EconomyMembershipGrant {
  const EconomyMembershipGrant({
    required this.id,
    required this.tier,
    required this.source,
    required this.transactionId,
    required this.startsAt,
    required this.expiresAt,
  });
  final String id, source, transactionId;
  final MembershipTier tier;
  final DateTime startsAt, expiresAt;
  factory EconomyMembershipGrant.fromJson(Object? value) {
    final map = economyObject(value);
    final starts = economyTime(map['startsAt']);
    final expires = economyTime(map['expiresAt']);
    final source = economyString(map['source']);
    if (!expires.isAfter(starts) ||
        !const {'coins', 'cash', 'cash_deferred'}.contains(source)) {
      throw const FormatException('invalid_membership_grant');
    }
    return EconomyMembershipGrant(
      id: economyString(map['grantId'], max: 36),
      tier: MembershipTier.parse(map['tier']),
      source: source,
      transactionId: economyString(map['transactionId'], max: 36),
      startsAt: starts,
      expiresAt: expires,
    );
  }
}

final class EconomyMembership {
  const EconomyMembership({required this.activeTier, required this.grants});
  final MembershipTier? activeTier;
  final List<EconomyMembershipGrant> grants;
  factory EconomyMembership.fromJson(Object? value) {
    final map = economyObject(value);
    final tier = map['activeTier'];
    return EconomyMembership(
      activeTier: tier == '' || tier == null
          ? null
          : MembershipTier.parse(tier),
      grants: economyList(map['grants'], EconomyMembershipGrant.fromJson),
    );
  }
}

final class EconomyMembershipQuote {
  const EconomyMembershipQuote({
    required this.id,
    required this.tier,
    required this.price,
    required this.expiresAt,
    this.policyVersion = '',
  });
  final String id, policyVersion;
  final MembershipTier tier;
  final int price;
  final DateTime expiresAt;
  factory EconomyMembershipQuote.fromJson(Object? value) {
    final map = economyObject(value);
    final tier = MembershipTier.parse(map['productId']);
    final historicalPro =
        tier == MembershipTier.proV2 &&
        map['cashUsdCents'] == 10000 &&
        map['policyVersion'] is String &&
        (map['policyVersion'] as String).isNotEmpty;
    if (map['kind'] != 'membership' ||
        map['durationDays'] != 30 ||
        (map['cashUsdCents'] != tier.cashUsdCents && !historicalPro)) {
      throw const FormatException('quote_contract_mismatch');
    }
    return EconomyMembershipQuote(
      id: economyString(map['quoteId'], max: 36),
      policyVersion: economyString(
        map['policyVersion'] ?? '',
        empty: true,
        max: 64,
      ),
      tier: tier,
      price: economyInteger(map['priceCoins'], positive: true),
      expiresAt: economyTime(map['expiresAt']),
    );
  }
}

final class EconomyRedemption {
  const EconomyRedemption({
    required this.transactionId,
    required this.quoteId,
    required this.price,
    required this.grant,
  });
  final String transactionId, quoteId;
  final int price;
  final EconomyMembershipGrant grant;
  factory EconomyRedemption.fromJson(Object? value) {
    final map = economyObject(value);
    final tx = economyObject(map['transaction']);
    final grant = EconomyMembershipGrant.fromJson(map['grant']);
    final transactionId = economyString(tx['transactionId'], max: 36);
    final price = economyInteger(tx['coins'], positive: true);
    if (tx['kind'] != 'membership' ||
        tx['burnedCoins'] != price ||
        grant.transactionId != transactionId ||
        grant.source != 'coins' ||
        grant.expiresAt.difference(grant.startsAt) !=
            const Duration(days: 30)) {
      throw const FormatException('redemption_contract_mismatch');
    }
    return EconomyRedemption(
      transactionId: transactionId,
      quoteId: economyString(tx['quoteId'], max: 36),
      price: price,
      grant: grant,
    );
  }
}

final class EconomyOverview {
  const EconomyOverview({
    required this.catalog,
    required this.wallet,
    required this.ledger,
    required this.rewards,
    required this.membership,
    this.creatorEvidence,
  });
  final EconomyCatalog catalog;
  final EconomyWallet wallet;
  final EconomyLedgerPage ledger;
  final List<EconomyRewardEstimate> rewards;
  final EconomyMembership membership;

  /// Null means unavailable, never zero activity. It does not hide the wallet.
  final CreatorRewardEvidencePage? creatorEvidence;
}
