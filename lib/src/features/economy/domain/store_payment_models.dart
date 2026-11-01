import 'economy_models.dart';

final class StoreProduct {
  const StoreProduct({
    required this.provider,
    required this.id,
    required this.plan,
    required this.kind,
    required this.usdCents,
    required this.coins,
    this.tier,
    this.retired = false,
  });
  final String provider, id, plan, kind;
  final int usdCents, coins;
  final MembershipTier? tier;
  final bool retired;
  String get key => '$provider:$id:$plan';
  factory StoreProduct.fromJson(Object? value) {
    final m = economyObject(value);
    final id = economyString(m['productId'], max: 128);
    final provider = economyString(m['provider']);
    final kind = economyString(m['kind']);
    final tier = m['tier'] == null ? null : MembershipTier.parse(m['tier']);
    final price = economyInteger(m['cashUsdCents'], positive: true);
    final coins = economyInteger(m['topUpCoins'] ?? 0);
    final plan = economyString(m['basePlanId'] ?? '', empty: true);
    final retired = m['retired'] ?? false;
    final historicalPro = id == 'maaso.membership.pro.monthly.v2';
    final expectedPrice = historicalPro ? 10000 : tier?.cashUsdCents;
    if (!{'ios', 'android'}.contains(provider) ||
        !{'membership', 'topup'}.contains(kind) ||
        retired is! bool ||
        (historicalPro &&
            (kind != 'membership' || tier != MembershipTier.proV2)) ||
        (id == 'maaso.membership.pro.monthly.v3' &&
            (kind != 'membership' || tier != MembershipTier.proV2)) ||
        (id == 'maaso.membership.pro.monthly.v1' &&
            (kind != 'membership' || tier != MembershipTier.pro)) ||
        (kind == 'membership' &&
            (tier == null || expectedPrice != price || coins != 0)) ||
        (kind == 'topup' && (tier != null || coins == 0 || plan.isNotEmpty))) {
      throw const FormatException('invalid_store_product');
    }
    return StoreProduct(
      provider: provider,
      id: id,
      plan: plan,
      kind: kind,
      usdCents: price,
      coins: coins,
      tier: tier,
      retired: retired,
    );
  }
}

final class StoreOffer {
  const StoreOffer(this.product, this.ready, this.reason);
  final StoreProduct product;
  final bool ready;
  final String reason;
  factory StoreOffer.fromJson(Object? value) {
    final m = economyObject(value);
    if (m['ready'] is! bool) throw const FormatException('invalid_store_offer');
    return StoreOffer(
      StoreProduct.fromJson(m['product']),
      m['ready'] as bool,
      economyString(m['unavailableReason'] ?? '', empty: true),
    );
  }
}

final class StoreCheckout {
  const StoreCheckout({
    required this.id,
    required this.binding,
    this.policyVersion = '',
    required this.product,
    required this.expiresAt,
  });
  final String id, binding, policyVersion;
  final StoreProduct product;
  final DateTime expiresAt;
  factory StoreCheckout.fromJson(Object? value) {
    final m = economyObject(value);
    final binding = economyString(m['accountBinding'], max: 36);
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(binding)) {
      throw const FormatException('invalid_store_binding');
    }
    return StoreCheckout(
      id: economyString(m['intentId'], max: 36),
      policyVersion: economyString(
        m['policyVersion'] ?? '',
        empty: true,
        max: 64,
      ),
      binding: binding,
      product: StoreProduct.fromJson(m['product']),
      expiresAt: economyTime(m['expiresAt']),
    );
  }
}

final class StoreReceipt {
  const StoreReceipt({
    required this.id,
    required this.productId,
    required this.kind,
    required this.state,
    required this.source,
    required this.renewalState,
    this.tier,
    this.paidStartsAt,
    this.paidExpiresAt,
    this.startsAt,
    this.expiresAt,
    this.storeExpiresAt,
  });
  final String id, productId, kind, state, source, renewalState;
  final MembershipTier? tier;
  final DateTime? paidStartsAt,
      paidExpiresAt,
      startsAt,
      expiresAt,
      storeExpiresAt;
  bool get persisted =>
      {'granted', 'awaiting_fulfillment', 'revoked'}.contains(state);
  factory StoreReceipt.fromJson(Object? value) {
    final m = economyObject(value);
    final state = economyString(m['state']);
    final kind = economyString(m['kind']);
    if (!{'granted', 'awaiting_fulfillment', 'revoked'}.contains(state) ||
        !{'membership', 'topup'}.contains(kind)) {
      throw const FormatException('invalid_store_receipt');
    }
    DateTime? date(String k) => m[k] == null ? null : economyTime(m[k]);
    final r = StoreReceipt(
      id: economyString(m['receiptId'], max: 64),
      productId: economyString(m['productId']),
      kind: kind,
      state: state,
      source: economyString(m['source'] ?? '', empty: true),
      renewalState: economyString(m['renewalState'] ?? '', empty: true),
      tier: m['tier'] == null ? null : MembershipTier.parse(m['tier']),
      paidStartsAt: date('paidStartsAt'),
      paidExpiresAt: date('paidExpiresAt'),
      startsAt: date('startsAt'),
      expiresAt: date('expiresAt'),
      storeExpiresAt: date('storeExpiresAt'),
    );
    if (kind == 'membership' &&
        (r.paidStartsAt == null ||
            r.paidExpiresAt == null ||
            !r.paidExpiresAt!.isAfter(r.paidStartsAt!))) {
      throw const FormatException('missing_paid_period');
    }
    if (kind == 'membership' &&
        state == 'granted' &&
        (r.startsAt == null ||
            r.expiresAt == null ||
            !r.expiresAt!.isAfter(r.startsAt!) ||
            !{'cash', 'cash_deferred'}.contains(r.source))) {
      throw const FormatException('missing_service_period');
    }
    return r;
  }
}

final class MembershipUsage {
  const MembershipUsage({
    required this.modelName,
    required this.dailyTokens,
    required this.periodTokens,
    required this.dailyRequests,
    required this.pendingTokens,
    required this.resetsAt,
    this.tier,
    this.expiresAt,
    this.quotaUnlimited = false,
  });
  final MembershipTier? tier;
  final bool quotaUnlimited;
  final String modelName;
  final int dailyTokens, periodTokens, dailyRequests, pendingTokens;
  final DateTime resetsAt;
  final DateTime? expiresAt;
  factory MembershipUsage.fromJson(Object? value) {
    final m = economyObject(value);
    final tier = m['activeTier'] == null
        ? null
        : MembershipTier.parse(m['activeTier']);
    final model = m['model'] == null ? null : economyObject(m['model']);
    if (tier != null && (model == null || model['tier'] != tier.wireName)) {
      throw const FormatException('usage_model_mismatch');
    }
    return MembershipUsage(
      quotaUnlimited: m['quotaUnlimited'] == true,
      tier: tier,
      modelName: model == null ? '' : economyString(model['displayName']),
      dailyTokens: economyInteger(m['dailyTokensRemaining']),
      periodTokens: economyInteger(m['periodTokensRemaining']),
      dailyRequests: economyInteger(m['dailyRequestsRemaining']),
      pendingTokens: economyInteger(m['pendingTokens']),
      resetsAt: economyTime(m['resetsAt']),
      expiresAt: m['expiresAt'] == null ? null : economyTime(m['expiresAt']),
    );
  }
}
