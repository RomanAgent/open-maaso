import 'package:maaso/src/features/economy/domain/economy_models.dart';

// Explicit test data only. App model choices always come from the server.
Map<String, Object?> benefitsModelJson(MembershipTier tier) => {
  'tier': tier.name,
  'displayName': 'Server ${tier.title}',
  'provider': 'test-provider',
  'modelId': 'server-${tier.name}-model',
  'capabilityClass': 'test-${tier.name}',
  'thinking': 'disabled',
  'contextTokens': 8192 * (tier.index + 1),
  'maxOutputTokens': 2048 * (tier.index + 1),
  'dailyTokens': 20000 * (tier.index + 1),
  'dailyRequests': 100 * (tier.index + 1),
  'grantTokens': 100000 * (tier.index + 1),
};
Map<String, Object?> benefitsAvailabilityJson({
  String version = 'test-policy-v1',
  bool ready = true,
}) => {
  'checkedAt': '2030-01-01T00:00:00Z',
  'policyVersion': version,
  'entitlementVersion': 'test-model-v1',
  'tiers': [
    for (final tier in MembershipTier.legacyTiers)
      {
        'tier': tier.name,
        'available': ready,
        if (!ready) 'reason': 'model_unavailable',
        'model': benefitsModelJson(tier),
      },
  ],
};
