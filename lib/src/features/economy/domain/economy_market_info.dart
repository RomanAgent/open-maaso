import 'economy_models.dart';
import 'membership_benefits.dart';

final class TierCapacity {
  const TierCapacity(this.tier, this.available, this.reason, {this.model});
  final MembershipTierBenefits? model;
  final MembershipTier tier;
  final bool available;
  final String reason;
  factory TierCapacity.fromJson(Object? value) {
    final m = economyObject(value);
    final reason = economyString(m['reason'] ?? '', empty: true, max: 80);
    if (m['available'] is! bool ||
        (m['available'] == true && reason.isNotEmpty) ||
        (m['available'] == false &&
            !const {
              'model_unavailable',
              'capacity_unavailable',
            }.contains(reason))) {
      throw const FormatException('invalid_tier_capacity');
    }
    final tier = MembershipTier.parse(m['tier']);
    final model = m['model'] == null
        ? null
        : MembershipTierBenefits.fromJson(m['model']);
    if (model != null && model.tier != tier) {
      throw const FormatException('model_tier_mismatch');
    }
    return TierCapacity(tier, m['available'] as bool, reason, model: model);
  }
}

final class MembershipAvailability {
  const MembershipAvailability(
    this.checkedAt,
    this.tiers, {
    this.policyVersion = '',
    this.entitlementVersion = '',
  });
  final String policyVersion, entitlementVersion;
  final DateTime checkedAt;
  final List<TierCapacity> tiers;
  factory MembershipAvailability.fromJson(Object? value) {
    final m = economyObject(value);
    final tiers = economyList(m['tiers'], TierCapacity.fromJson, max: 4);
    if (!MembershipTier.isCompleteCatalog(tiers.map((t) => t.tier))) {
      throw const FormatException('incomplete_capacity');
    }
    return MembershipAvailability(
      economyTime(m['checkedAt']),
      tiers,
      policyVersion: economyString(
        m['policyVersion'] ?? '',
        empty: true,
        max: 64,
      ),
      entitlementVersion: economyString(
        m['entitlementVersion'] ?? '',
        empty: true,
        max: 64,
      ),
    );
  }
}
