import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/application/economy_service.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'economy_test_support.dart';

void main() {
  test('preparing a quote never spends coins', () async {
    final gateway = FakeEconomyGateway();
    final service = EconomyService(
      gateway: gateway,
      now: () => gateway.now,
      requestId: () => 'request-1',
    );
    expect(gateway.quoteCalls, 0);
    expect(gateway.debits, 0);
    final quote = await service.prepareQuote(MembershipTier.pro);
    expect(quote.tier, MembershipTier.pro);
    expect(gateway.quoteCalls, 1);
    expect(gateway.debits, 0);
    service.cancelQuote();
    expect(service.pending, isNull);
  });
  test(
    'unknown payment result keeps one retry identity across cancellation and expiry',
    () async {
      final gateway = FakeEconomyGateway()..failAfterCommitOnce = true;
      final service = EconomyService(
        gateway: gateway,
        now: () => gateway.now,
        requestId: () => 'original-request',
      );
      final quote = await service.prepareQuote(MembershipTier.plus);
      await expectLater(
        service.confirm(quote.id),
        throwsA(isA<EconomyException>()),
      );
      expect(service.pending?.uncertain, isTrue);
      expect(gateway.debits, 1);
      service.cancelQuote();
      gateway.now = gateway.now.add(const Duration(minutes: 6));
      await expectLater(
        service.prepareQuote(MembershipTier.plus),
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'purchase_unresolved',
          ),
        ),
      );
      final result = await service.confirm(quote.id);
      expect(result.quoteId, quote.id);
      expect(gateway.requestIds, ['original-request', 'original-request']);
      expect(gateway.debits, 1);
      expect(service.pending, isNull);
    },
  );
  test(
    'expired first confirmation and substituted quote cannot charge',
    () async {
      final gateway = FakeEconomyGateway();
      final service = EconomyService(gateway: gateway, now: () => gateway.now);
      final quote = await service.prepareQuote(MembershipTier.plus);
      await expectLater(
        service.confirm('different-quote'),
        throwsA(isA<EconomyException>()),
      );
      gateway.now = gateway.now.add(const Duration(minutes: 6));
      await expectLater(
        service.confirm(quote.id),
        throwsA(
          isA<EconomyException>().having(
            (e) => e.code,
            'code',
            'QUOTE_EXPIRED',
          ),
        ),
      );
      expect(gateway.redeemCalls, 0);
    },
  );
  test('new account cannot receive late wallet or purchase state', () async {
    final gateway = FakeEconomyGateway();
    final wallet = Completer<EconomyWallet>();
    gateway.walletOverride = () => wallet.future;
    final service = EconomyService(gateway: gateway, now: () => gateway.now);
    final pending = service.load();
    gateway.requestContextKey = 'test|account-b';
    wallet.complete(
      const EconomyWallet(
        available: 0,
        pending: 0,
        frozen: 0,
        total: 0,
        purchasedAvailable: 0,
        earnedAvailable: 0,
        blocked: false,
        version: 1,
        playerName: 'Old player',
      ),
    );
    await expectLater(
      pending,
      throwsA(
        isA<EconomyException>().having(
          (e) => e.code,
          'code',
          'context_changed',
        ),
      ),
    );
    expect(service.pending, isNull);
    expect(service.isCurrent, isFalse);
  });
  test('unavailable membership prevents quote creation', () async {
    final gateway = FakeEconomyGateway()..ready = false;
    final service = EconomyService(gateway: gateway, now: () => gateway.now);
    await expectLater(
      service.prepareQuote(MembershipTier.plus),
      throwsA(isA<EconomyException>()),
    );
    expect(gateway.quoteCalls, 0);
    expect(gateway.debits, 0);
    expect(service.pending, isNull);
  });
}
