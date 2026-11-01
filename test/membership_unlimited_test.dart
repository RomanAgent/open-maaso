import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/membership_benefits.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';
import 'package:maaso/src/features/economy/presentation/membership_benefits_details.dart';
import 'package:maaso/src/features/economy/presentation/membership_page.dart';

import 'economy_store_purchase_test.dart'
    show StoreGatewayFake, NativeStoreFake, storeNow;

class _QuotaGateway extends StoreGatewayFake {
  _QuotaGateway(this.unlimited, this.tier);
  final bool unlimited;
  final MembershipTier? tier;
  @override
  Future<MembershipUsage> usage(String context) async => MembershipUsage(
    quotaUnlimited: unlimited,
    tier: tier,
    modelName: 'Test model',
    dailyTokens: 0,
    dailyRequests: 0,
    periodTokens: 0,
    pendingTokens: 12,
    resetsAt: storeNow,
  );
}

void main() {
  test('usage defaults to finite and decodes explicit unlimited', () {
    final payload = <String, Object?>{
      'dailyTokensRemaining': 0,
      'periodTokensRemaining': 0,
      'dailyRequestsRemaining': 0,
      'pendingTokens': 12,
      'resetsAt': storeNow.toIso8601String(),
    };
    expect(MembershipUsage.fromJson(payload).quotaUnlimited, isFalse);
    expect(
      MembershipUsage.fromJson({
        ...payload,
        'quotaUnlimited': true,
      }).quotaUnlimited,
      isTrue,
    );
  });

  for (final tier in [null, MembershipTier.plus]) {
    testWidgets('membership preserves unlimited quota state for $tier', (
      tester,
    ) async {
      final native = NativeStoreFake();
      final service = StorePurchaseService(
        gateway: _QuotaGateway(true, tier),
        native: native,
        now: () => storeNow,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: MembershipPage(route: '/membership', service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Current: ${tier?.title ?? 'Free'}'), findsOneWidget);
      expect(service.usage.value?.quotaUnlimited, isTrue);
      expect(service.usage.value?.pendingTokens, 12);
      expect(find.textContaining('allowance is exhausted'), findsNothing);
      expect(find.textContaining('Today:'), findsNothing);
      expect(find.textContaining('Daily reset:'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      service.onClose();
      await native.updates.close();
    });
  }

  testWidgets('membership preserves finite quota state', (tester) async {
    final native = NativeStoreFake();
    final service = StorePurchaseService(
      gateway: _QuotaGateway(false, MembershipTier.plus),
      native: native,
      now: () => storeNow,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MembershipPage(route: '/membership', service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current: Plus'), findsOneWidget);
    expect(service.usage.value?.quotaUnlimited, isFalse);
    expect(service.usage.value?.dailyTokens, 0);
    expect(service.usage.value?.dailyRequests, 0);
    expect(service.usage.value?.pendingTokens, 12);
    await tester.pumpWidget(const SizedBox());
    service.onClose();
    await native.updates.close();
  });

  testWidgets('benefits decode unlimited without hiding per-request bounds', (
    tester,
  ) async {
    final payload = <String, Object?>{
      'tier': 'plus',
      'displayName': 'Test model',
      'provider': 'test',
      'modelId': 'test-model',
      'capabilityClass': 'test',
      'thinking': 'disabled',
      'contextTokens': 8192,
      'maxOutputTokens': 2048,
      'dailyTokens': 20000,
      'dailyRequests': 100,
      'grantTokens': 100000,
    };
    expect(MembershipTierBenefits.fromJson(payload).quotaUnlimited, isFalse);
    final model = MembershipTierBenefits.fromJson({
      ...payload,
      'quotaUnlimited': true,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MembershipBenefitsDetails(
            model: model,
            zh: true,
            explainLimits: true,
          ),
        ),
      ),
    );
    expect(find.text('模型用量：不限额'), findsOneWidget);
    expect(find.textContaining('每日额度'), findsNothing);
    expect(find.textContaining('每个服务周期'), findsNothing);
    expect(find.textContaining('单次输出上限'), findsOneWidget);
  });
}
