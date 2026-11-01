import 'economy_models.dart';

/// Public, server-supplied model benefits. No credentials or cost assumptions.
final class MembershipTierBenefits {
  const MembershipTierBenefits({
    required this.tier,
    required this.displayName,
    required this.provider,
    required this.modelId,
    required this.capabilityClass,
    required this.thinking,
    required this.contextTokens,
    required this.maxOutputTokens,
    required this.dailyTokens,
    required this.dailyRequests,
    required this.grantTokens,
    this.quotaUnlimited = false,
  });
  final bool quotaUnlimited;
  final MembershipTier tier;
  final String displayName, provider, modelId, capabilityClass, thinking;
  final int contextTokens,
      maxOutputTokens,
      dailyTokens,
      dailyRequests,
      grantTokens;
  factory MembershipTierBenefits.fromJson(Object? value) {
    final m = economyObject(value);
    final context = economyInteger(m['contextTokens'], positive: true);
    final output = economyInteger(m['maxOutputTokens'], positive: true);
    if (output > context) throw const FormatException('invalid_model_limits');
    return MembershipTierBenefits(
      quotaUnlimited: m['quotaUnlimited'] == true,
      tier: MembershipTier.parse(m['tier']),
      displayName: economyString(m['displayName'], max: 160),
      provider: economyString(m['provider'], max: 64),
      modelId: economyString(m['modelId'], max: 160),
      capabilityClass: economyString(m['capabilityClass'], max: 80),
      thinking: economyString(m['thinking'], max: 32),
      contextTokens: context,
      maxOutputTokens: output,
      dailyTokens: economyInteger(m['dailyTokens'], positive: true),
      dailyRequests: economyInteger(m['dailyRequests'], positive: true),
      grantTokens: economyInteger(m['grantTokens'], positive: true),
    );
  }
}

/// The exact benefits shown for a quote. Pending retries keep this snapshot.
final class ReviewedMembershipTerms {
  const ReviewedMembershipTerms({
    required this.policyVersion,
    required this.entitlementVersion,
    required this.checkedAt,
    required this.model,
  });
  final String policyVersion, entitlementVersion;
  final DateTime checkedAt;
  final MembershipTierBenefits model;
}
