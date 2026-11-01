import '../domain/economy_market_info.dart';
import '../domain/economy_models.dart';
import '../domain/membership_benefits.dart';

ReviewedMembershipTerms reviewMembershipTerms(
  MembershipAvailability availability,
  MembershipTier tier,
) {
  final matches = availability.tiers.where((t) => t.tier == tier).toList();
  if (matches.length != 1) {
    throw const EconomyException('membership_details_unavailable');
  }
  final selected = matches.single;
  if (!selected.available) {
    throw EconomyException(
      selected.reason == 'capacity_unavailable'
          ? 'MEMBERSHIP_CAPACITY_UNAVAILABLE'
          : 'MEMBERSHIP_CAPABILITY_UNAVAILABLE',
    );
  }
  final model = selected.model;
  if (model == null ||
      model.tier != tier ||
      availability.policyVersion.isEmpty ||
      availability.entitlementVersion.isEmpty) {
    throw const EconomyException('membership_details_unavailable');
  }
  return ReviewedMembershipTerms(
    policyVersion: availability.policyVersion,
    entitlementVersion: availability.entitlementVersion,
    checkedAt: availability.checkedAt,
    model: model,
  );
}
