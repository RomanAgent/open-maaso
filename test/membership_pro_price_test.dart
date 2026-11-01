import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/data/native_store_gateway.dart';
import 'package:maaso/src/features/economy/data/store_payment_http_client.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';

import 'economy_store_purchase_test.dart' as fixture;

const _oldSKU = 'maaso.membership.pro.monthly.v2';
const _newSKU = 'maaso.membership.pro.monthly.v3';

Map<String, Object?> _product({
  String id = _newSKU,
  String tier = 'pro_v2',
  int cents = 2990,
  bool retired = false,
}) => {
  'provider': 'ios',
  'productId': id,
  'kind': 'membership',
  'tier': tier,
  'cashUsdCents': cents,
  if (retired) 'retired': true,
};

StorePaymentHttpClient _client(Map<String, Object?> data) =>
    StorePaymentHttpClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => 'account-a',
      accessToken: () async => 'token',
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'code': 'OK', 'data': data}), 200),
      ),
    );

void main() {
  test(
    'current Pro is 2990 while legacy Pro retains its separate identity',
    () {
      expect(MembershipTier.proV2.cashUsdCents, 2990);
      expect(MembershipTier.proV2.usdLabel, r'$29.90');
      expect(MembershipTier.proV2.wireName, 'pro_v2');
      expect(MembershipTier.pro.cashUsdCents, 2990);
      expect(MembershipTier.pro, isNot(MembershipTier.proV2));
      expect(StoreProduct.fromJson(_product()).usdCents, 2990);
      final historical = StoreProduct.fromJson(
        _product(id: _oldSKU, cents: 10000, retired: true),
      );
      expect(historical.usdCents, 10000);
      expect(historical.tier, MembershipTier.proV2);
      expect(historical.retired, isTrue);
    },
  );

  test('baseline Pro price exception rejects malformed products', () {
    for (final input in [
      _product(cents: 10000),
      _product(cents: 1),
      _product(id: _oldSKU, retired: true),
      _product(id: 'unknown.pro', cents: 10000, retired: true),
      _product(id: _oldSKU, tier: 'pro', cents: 10000, retired: true),
      _product(id: _newSKU, tier: 'pro'),
      _product(id: 'maaso.membership.pro.monthly.v1'),
      {..._product(), 'retired': 'true'},
    ]) {
      expect(
        () => StoreProduct.fromJson(input),
        throwsFormatException,
        reason: '$input',
      );
    }
  });

  test('baseline active Pro v2 is accepted only at its exact old price', () {
    final baseline = StoreProduct.fromJson(_product(id: _oldSKU, cents: 10000));
    expect(baseline.usdCents, 10000);
    expect(baseline.retired, isFalse);
    final offer = MembershipOffer.fromJson({
      'tier': 'pro_v2',
      'cashUsdCents': 10000,
      'durationDays': 30,
      'priceCoins': 300,
    });
    expect(offer.usdLabel, r'$100.00');
    expect(offer.priceCoins, 300);
    for (final cents in [9999, 10001, 1]) {
      expect(
        () => MembershipOffer.fromJson({
          'tier': 'pro_v2',
          'cashUsdCents': cents,
          'durationDays': 30,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => MembershipOffer.fromJson({
        'tier': 'pro_v2',
        'cashUsdCents': 10000.0,
        'durationDays': 30,
      }),
      throwsFormatException,
    );
  });

  test(
    'catalog rejects simultaneous active old and new Pro products',
    () async {
      final old = {
        'product': _product(id: _oldSKU, cents: 10000),
        'ready': true,
      };
      final newOffer = {'product': _product(), 'ready': true};
      final baselineClient = _client({
        'offers': [old],
      });
      addTearDown(baselineClient.close);
      final baseline = await baselineClient.catalog(
        baselineClient.requestContextKey,
        'ios',
      );
      expect(baseline.single.product.id, _oldSKU);
      final mixedClient = _client({
        'offers': [old, newOffer],
      });
      addTearDown(mixedClient.close);
      await expectLater(
        mixedClient.catalog(mixedClient.requestContextKey, 'ios'),
        throwsA(isA<EconomyException>()),
      );
    },
  );

  test(
    'new clients accept catalogs without optional restoreProducts',
    () async {
      final client = _client({
        'offers': [
          {'product': _product(), 'ready': true},
        ],
      });
      addTearDown(client.close);
      final products = await client.catalog(client.requestContextKey, 'ios');
      expect(products, hasLength(1));
      expect(products.single.product.id, _newSKU);
    },
  );

  test('restore catalog mappings never become purchasable offers', () async {
    final client = _client({
      'offers': [
        {'product': _product(), 'ready': true},
      ],
      'restoreProducts': [_product(id: _oldSKU, cents: 10000, retired: true)],
    });
    addTearDown(client.close);
    final products = await client.catalog(client.requestContextKey, 'ios');
    expect(products.map((e) => e.product.id), [_newSKU, _oldSKU]);
    expect(products.last.ready, isFalse);
    expect(products.last.product.retired, isTrue);
  });

  test('malformed catalog partitions fail closed', () async {
    final old = _product(id: _oldSKU, cents: 10000, retired: true);
    for (final data in [
      {
        'offers': [
          {'product': old, 'ready': true},
        ],
      },
      {
        'offers': <Object>[],
        'restoreProducts': [_product()],
      },
      {
        'offers': <Object>[],
        'restoreProducts': [old, old],
      },
    ]) {
      final client = _client(data);
      addTearDown(client.close);
      await expectLater(
        client.catalog(client.requestContextKey, 'ios'),
        throwsA(isA<EconomyException>()),
      );
    }
  });

  test(
    'persisted Pro quote reads the explicit historical price only with policy',
    () {
      Map<String, Object?> quote(
        int cents, {
        String? policy = 'historical-v2',
      }) => {
        'kind': 'membership',
        'productId': 'pro_v2',
        'durationDays': 30,
        'cashUsdCents': cents,
        'priceCoins': 300,
        'quoteId': 'quote',
        'expiresAt': '2026-09-22T12:00:00Z',
        'policyVersion': ?policy,
      };
      expect(EconomyMembershipQuote.fromJson(quote(10000)).price, 300);
      expect(
        EconomyMembershipQuote.fromJson(quote(2990)).tier,
        MembershipTier.proV2,
      );
      for (final value in [quote(10000, policy: null), quote(1), quote(9999)]) {
        expect(
          () => EconomyMembershipQuote.fromJson(value),
          throwsFormatException,
        );
      }
    },
  );

  for (final status in [
    NativeStoreStatus.restored,
    NativeStoreStatus.purchased,
  ]) {
    test(
      'old Pro $status verifies only after durable receipt and stays out of store UI',
      () async {
        final gateway = _RestoreGateway()..pending = Completer<StoreReceipt>();
        final native = _NativeGateway();
        final service = StorePurchaseService(gateway: gateway, native: native);
        addTearDown(() async {
          service.onClose();
          await native.updates.close();
        });
        await service.load();
        expect(service.offers.map((e) => e.product.id), [_newSKU]);
        expect(native.queried.map((e) => e.id), [_newSKU]);
        expect(service.products.single.price, '¥218.00 / 月');
        native.updates.add([
          NativeStoreEvent(
            productId: _oldSKU,
            transactionId: 'old-transaction',
            status: status,
            purchaseToken: '',
            handle: 'old-native',
          ),
        ]);
        await fixture.flush();
        expect(gateway.proofs.single['productId'], _oldSKU);
        expect(gateway.proofs.single.containsKey('cashUsdCents'), isFalse);
        expect(
          gateway.proofs.single['refreshRenewal'],
          status == NativeStoreStatus.restored ? true : null,
        );
        expect(native.acknowledgements, 0);
        gateway.pending!.complete(_oldReceipt());
        await fixture.flush();
        expect(native.acknowledgements, 1);
        expect(native.buys, 0);
        expect(service.receipts.single.productId, _oldSKU);
        expect(service.hasUnresolved, isFalse);
      },
    );
  }

  test('account change fences a late retired-SKU receipt', () async {
    final gateway = _RestoreGateway()..pending = Completer<StoreReceipt>();
    final native = _NativeGateway();
    final service = StorePurchaseService(gateway: gateway, native: native);
    addTearDown(() async {
      service.onClose();
      await native.updates.close();
    });
    await service.load();
    native.updates.add([
      const NativeStoreEvent(
        productId: _oldSKU,
        transactionId: 'old-transaction',
        status: NativeStoreStatus.restored,
        purchaseToken: '',
        handle: 'old-native',
      ),
    ]);
    await fixture.flush();
    gateway.contextKey = 'account-b';
    gateway.pending!.complete(_oldReceipt());
    await fixture.flush();
    expect(service.receipts, isEmpty);
    expect(native.acknowledgements, 0);
  });
}

StoreReceipt _oldReceipt() => StoreReceipt(
  id: 'old-receipt',
  productId: _oldSKU,
  kind: 'membership',
  state: 'granted',
  source: 'cash',
  renewalState: 'disabled',
  tier: MembershipTier.proV2,
  paidStartsAt: DateTime.utc(2026, 9, 1),
  paidExpiresAt: DateTime.utc(2026, 10, 1),
  startsAt: DateTime.utc(2026, 9, 1),
  expiresAt: DateTime.utc(2026, 10, 1),
);

class _RestoreGateway extends fixture.StoreGatewayFake {
  final proofs = <Map<String, Object?>>[];
  @override
  Future<List<StoreOffer>> catalog(String context, String provider) async => [
    StoreOffer(StoreProduct.fromJson(_product()), true, ''),
    StoreOffer(
      StoreProduct.fromJson(_product(id: _oldSKU, cents: 10000, retired: true)),
      false,
      'retired_product',
    ),
  ];
  @override
  Future<StoreReceipt> verify(String context, Map<String, Object?> proof) {
    proofs.add(Map.of(proof));
    return pending?.future ?? Future.value(_oldReceipt());
  }
}

class _NativeGateway extends fixture.NativeStoreFake {
  List<StoreProduct> queried = [];
  @override
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed) async {
    queried = allowed;
    return [
      for (final product in allowed)
        NativeStoreProduct(
          product: product,
          price: '¥218.00 / 月',
          handle: product.id,
        ),
    ];
  }
}
