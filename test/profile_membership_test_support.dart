import 'package:maaso/src/features/economy/data/membership_availability_reader.dart';
import 'package:maaso/src/features/economy/domain/economy_market_info.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/membership_benefits.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';
import 'package:maaso/src/features/economy/data/native_store_gateway.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/application/profile_controller.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'economy_store_purchase_test.dart';
import 'identity_test_support.dart';

class ProfileStoreFake implements CompanionProfileStore {
  CompanionProfile? value;
  @override
  Future<CompanionProfile?> read() async => value;
  @override
  Future<void> write(CompanionProfile profile) async {
    value = profile;
  }
}

class ProfileGatewayFake implements CompanionProfileGateway {
  @override
  String requestContextKey = 'test|account-a';
  CompanionProfile value = CompanionProfile(
    version: 1,
    avatarPreset: 'star',
    agentGender: 'female',
    interests: ['music'],
    onboardingVersion: 1,
  );
  int writes = 0;
  bool fail = false;
  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) async =>
      value;
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) async {
    writes++;
    if (fail) {
      throw const CompanionProfileException(
        CompanionProfileFailure.unavailable,
      );
    }
    if (profile.version != value.version) {
      throw const CompanionProfileException(CompanionProfileFailure.conflict);
    }
    return value = profile.copyWith(version: profile.version + 1);
  }
}

class ProfileFixture {
  ProfileFixture() {
    identity = IdentityService(gateway: identityGateway);
    companion = CompanionProfileService(
      gateway: companionGateway,
      store: ProfileStoreFake(),
      isCurrent: () => current,
    );
    controller = ProfileController(identity: identity, companion: companion);
  }
  final identityGateway = FakeIdentityGateway(initial: identityFixture());
  final companionGateway = ProfileGatewayFake();
  late final IdentityService identity;
  late final CompanionProfileService companion;
  late final ProfileController controller;
  bool current = true;
  void close() {
    controller.onClose();
    identity.onClose();
    companion.onClose();
  }
}

StoreProduct membershipProduct(MembershipTier tier) => StoreProduct(
  provider: 'ios',
  id: 'test.membership.${tier.wireName}',
  plan: '',
  kind: 'membership',
  usdCents: tier.cashUsdCents,
  coins: 0,
  tier: tier,
);

class MembershipGatewayFake extends StoreGatewayFake
    implements MembershipAvailabilityReader {
  MembershipGatewayFake() {
    contextKey = 'test|account-a';
  }
  MembershipTier? activeTier;
  bool unavailable = false;
  int membershipReads = 0;
  @override
  Future<List<StoreOffer>> catalog(String context, String provider) async => [
    for (final tier in MembershipTier.currentTiers)
      StoreOffer(membershipProduct(tier), true, ''),
  ];
  @override
  Future<MembershipAvailability> membershipAvailability(String context) async {
    membershipReads++;
    return MembershipAvailability(
      storeNow,
      [
        for (final tier in MembershipTier.currentTiers)
          TierCapacity(
            tier,
            !unavailable,
            unavailable ? 'model_unavailable' : '',
            model: MembershipTierBenefits(
              tier: tier,
              displayName: 'Verified ${tier.title}',
              provider: 'test',
              modelId: tier.wireName,
              capabilityClass: 'test',
              thinking: 'disabled',
              contextTokens: 8192,
              maxOutputTokens: 2048,
              dailyTokens: 20000,
              dailyRequests: 100,
              grantTokens: 100000,
            ),
          ),
      ],
      policyVersion: 'review-v2',
      entitlementVersion: 'models-v2',
    );
  }

  @override
  Future<MembershipUsage> usage(String context) async => MembershipUsage(
    tier: activeTier,
    modelName: activeTier?.modelDisplayName ?? 'Doubao-Seed-Evolving',
    dailyTokens: 1000,
    periodTokens: 2000,
    dailyRequests: 10,
    pendingTokens: 0,
    resetsAt: storeNow,
    expiresAt: activeTier == null ? null : DateTime.utc(2030),
  );
  @override
  Future<StoreCheckout> checkout(
    String context,
    StoreProduct product, {
    String? expectedPolicyVersion,
  }) async {
    calls.add('checkout');
    return StoreCheckout(
      id: 'intent',
      binding: '11111111-1111-4111-8111-111111111111',
      product: product,
      policyVersion: expectedPolicyVersion ?? '',
      expiresAt: storeNow.add(const Duration(minutes: 15)),
    );
  }
}

class MembershipNativeFake extends NativeStoreFake {
  bool missingPrice = false;
  @override
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed) async =>
      missingPrice
      ? []
      : [
          for (final product in allowed)
            NativeStoreProduct(
              product: product,
              price: 'LOCAL ${product.tier!.usdLabel}',
              handle: product.id,
            ),
        ];
}
