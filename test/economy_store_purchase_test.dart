import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/data/native_store_gateway.dart';
import 'package:maaso/src/features/economy/data/store_payment_http_client.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';

const storeProduct = StoreProduct(
  provider: 'ios',
  id: 'test.coins',
  plan: '',
  kind: 'topup',
  usdCents: 999,
  coins: 1000,
);
final storeNow = DateTime.utc(2026, 9, 12);
StoreReceipt receipt(String state) => StoreReceipt(
  id: 'receipt-1',
  productId: 'test.coins',
  kind: 'topup',
  state: state,
  source: '',
  renewalState: '',
);

class StoreGatewayFake implements StorePaymentGateway {
  String contextKey = 'account-A';
  final calls = <String>[];
  Completer<StoreReceipt>? pending;
  int verifies = 0;
  bool fail = false;
  @override
  String get requestContextKey => contextKey;
  @override
  Future<List<StoreOffer>> catalog(String context, String provider) async => [
    const StoreOffer(storeProduct, true, ''),
  ];
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
      expiresAt: storeNow.add(const Duration(minutes: 15)),
    );
  }

  @override
  Future<void> cancel(String context, String id) async {
    calls.add('cancel');
  }

  @override
  Future<StoreReceipt> verify(
    String context,
    Map<String, Object?> proof,
  ) async {
    calls.add('verify');
    verifies++;
    expect(proof.containsKey('accountUuid'), false);
    expect(proof.containsKey('coins'), false);
    if (fail) throw StateError('network');
    return pending == null ? receipt('granted') : pending!.future;
  }

  @override
  Future<List<StoreReceipt>> receipts(String context) async => [];
  @override
  Future<MembershipUsage> usage(String context) async => MembershipUsage(
    modelName: '',
    dailyTokens: 0,
    periodTokens: 0,
    dailyRequests: 0,
    pendingTokens: 0,
    resetsAt: storeNow,
  );
  @override
  void close() {
    calls.add('close');
  }
}

class NativeStoreFake implements NativeStoreGateway {
  final updates = StreamController<List<NativeStoreEvent>>.broadcast(
    sync: true,
  );
  int buys = 0, acknowledgements = 0, restores = 0;
  String? binding;
  bool opens = true;
  @override
  String get provider => 'ios';
  @override
  Stream<List<NativeStoreEvent>> get events => updates.stream;
  @override
  Future<bool> available() async => true;
  @override
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed) async =>
      [
        const NativeStoreProduct(
          product: storeProduct,
          price: '\$9.99',
          handle: 'product',
        ),
      ];
  @override
  Future<bool> purchase(
    NativeStoreProduct product,
    String accountBinding,
  ) async {
    buys++;
    binding = accountBinding;
    return opens;
  }

  @override
  Future<void> restore() async {
    restores++;
  }

  @override
  Future<void> complete(NativeStoreEvent event, StoreProduct product) async {
    acknowledgements++;
  }

  void purchased() => updates.add([
    const NativeStoreEvent(
      productId: 'test.coins',
      transactionId: 'transaction-1',
      status: NativeStoreStatus.purchased,
      purchaseToken: '',
      handle: 'native',
    ),
  ]);
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'native completion waits for durable server receipt and duplicate callbacks do not repeat it',
    () async {
      final g = StoreGatewayFake()..pending = Completer<StoreReceipt>();
      final n = NativeStoreFake();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      await s.buy(s.products.single);
      n.purchased();
      await flush();
      expect(n.acknowledgements, 0);
      expect(g.verifies, 1);
      expect(n.binding, '11111111-1111-4111-8111-111111111111');
      g.pending!.complete(receipt('awaiting_fulfillment'));
      await flush();
      expect(n.acknowledgements, 1);
      expect(s.error.value, 'store_fulfillment_pending');
      n.purchased();
      await flush();
      expect(n.acknowledgements, 1);
      expect(g.verifies, 1);
      s.onClose();
      await n.updates.close();
    },
  );
  test(
    'account switch before verification returns prevents completion and receipt exposure',
    () async {
      final g = StoreGatewayFake()..pending = Completer<StoreReceipt>();
      final n = NativeStoreFake();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      n.purchased();
      await flush();
      g.contextKey = 'account-B';
      g.pending!.complete(receipt('granted'));
      await flush();
      expect(n.acknowledgements, 0);
      expect(s.receipts, isEmpty);
      expect(s.isCurrent, false);
      s.onClose();
      await n.updates.close();
    },
  );
  test(
    'uncertain verification retains transaction for retry and blocks a new purchase',
    () async {
      final g = StoreGatewayFake()..fail = true;
      final n = NativeStoreFake();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      n.purchased();
      await flush();
      expect(s.hasUnresolved, true);
      expect(n.acknowledgements, 0);
      await expectLater(s.buy(s.products.single), throwsA(anything));
      expect(n.buys, 0);
      g.fail = false;
      await s.retryVerification();
      expect(n.acknowledgements, 1);
      expect(g.verifies, 2);
      s.onClose();
      await n.updates.close();
    },
  );
  test(
    'rejected native opening cancels server checkout and never verifies',
    () async {
      final g = StoreGatewayFake();
      final n = NativeStoreFake()..opens = false;
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      await expectLater(s.buy(s.products.single), throwsA(anything));
      expect(g.calls, contains('cancel'));
      expect(g.verifies, 0);
      expect(s.hasUnresolved, false);
      s.onClose();
      await n.updates.close();
    },
  );
  test(
    'overlapping retry and callback share one in-flight verification',
    () async {
      final g = StoreGatewayFake()..pending = Completer<StoreReceipt>();
      final n = NativeStoreFake();
      final s = StorePurchaseService(
        gateway: g,
        native: n,
        now: () => storeNow,
      );
      await s.load();
      n.purchased();
      await flush();
      await s.retryVerification();
      expect(g.verifies, 1);
      g.pending!.complete(receipt('granted'));
      await flush();
      expect(n.acknowledgements, 1);
      s.onClose();
      await n.updates.close();
    },
  );
}
