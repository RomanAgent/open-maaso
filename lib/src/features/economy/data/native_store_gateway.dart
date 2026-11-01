import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import '../domain/economy_models.dart';
import '../domain/store_payment_models.dart';

enum NativeStoreStatus { pending, purchased, restored, cancelled, error }

final class NativeStoreProduct {
  const NativeStoreProduct({
    required this.product,
    required this.price,
    required this.handle,
  });
  final StoreProduct product;
  final String price;
  final Object handle;
}

final class NativeStoreEvent {
  const NativeStoreEvent({
    required this.productId,
    required this.transactionId,
    required this.status,
    required this.purchaseToken,
    required this.handle,
  });
  final String productId, transactionId, purchaseToken;
  final NativeStoreStatus status;
  final Object handle;
  String get key => '$productId:$transactionId';
}

abstract interface class NativeStoreGateway {
  String get provider;
  Stream<List<NativeStoreEvent>> get events;
  Future<bool> available();
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed);
  Future<bool> purchase(NativeStoreProduct product, String binding);
  Future<void> restore();
  Future<void> complete(NativeStoreEvent event, StoreProduct product);
}

/// Uses the existing native billing plugin. No store result is acknowledged or
/// consumed until StorePurchaseService receives a durable server receipt.
final class PluginNativeStoreGateway implements NativeStoreGateway {
  PluginNativeStoreGateway({InAppPurchase? store, required this.provider})
    : _store = store ?? InAppPurchase.instance;
  final InAppPurchase _store;
  @override
  final String provider;
  static NativeStoreGateway? forCurrentPlatform() {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS => PluginNativeStoreGateway(provider: 'ios'),
      TargetPlatform.android => PluginNativeStoreGateway(provider: 'android'),
      _ => null,
    };
  }

  @override
  Stream<List<NativeStoreEvent>> get events => _store.purchaseStream.map(
    (purchases) => purchases
        .map(
          (p) => NativeStoreEvent(
            productId: p.productID,
            transactionId: p.purchaseID ?? '',
            status: switch (p.status) {
              PurchaseStatus.pending => NativeStoreStatus.pending,
              PurchaseStatus.purchased => NativeStoreStatus.purchased,
              PurchaseStatus.restored => NativeStoreStatus.restored,
              PurchaseStatus.canceled => NativeStoreStatus.cancelled,
              PurchaseStatus.error => NativeStoreStatus.error,
            },
            purchaseToken: provider == 'android'
                ? p.verificationData.serverVerificationData
                : '',
            handle: p,
          ),
        )
        .toList(growable: false),
  );
  @override
  Future<bool> available() => _store.isAvailable();
  @override
  Future<List<NativeStoreProduct>> products(List<StoreProduct> allowed) async {
    final result = await _store.queryProductDetails(
      allowed.map((p) => p.id).toSet(),
    );
    if (result.error != null) throw const EconomyException('store_unavailable');
    final products = <NativeStoreProduct>[];
    for (final p in allowed) {
      final matches = result.productDetails.where((detail) {
        if (detail.id != p.id) return false;
        if (provider == 'android') {
          if (detail is! GooglePlayProductDetails) return false;
          if (p.kind == 'membership') {
            final index = detail.subscriptionIndex;
            final offers = detail.productDetails.subscriptionOfferDetails;
            if (index == null || offers == null || index >= offers.length) {
              return false;
            }
            final offer = offers[index];
            return offer.basePlanId == p.plan &&
                offer.offerId == null &&
                offer.installmentPlanDetails == null &&
                offer.pricingPhases.length == 1 &&
                offer.pricingPhases.single.billingPeriod == 'P1M' &&
                offer.pricingPhases.single.priceAmountMicros > 0;
          }
          return detail.subscriptionIndex == null;
        }
        return detail.rawPrice > 0;
      }).toList();
      // Ambiguous native offers never choose an arbitrary billing plan.
      if (matches.length == 1) {
        products.add(
          NativeStoreProduct(
            product: p,
            price: matches.single.price,
            handle: matches.single,
          ),
        );
      }
    }
    return List.unmodifiable(products);
  }

  @override
  Future<bool> purchase(NativeStoreProduct product, String binding) {
    final detail = product.handle;
    if (detail is! ProductDetails) {
      throw const EconomyException('invalid_native_product');
    }
    final param = PurchaseParam(
      productDetails: detail,
      applicationUserName: binding,
    );
    return product.product.kind == 'topup'
        ? _store.buyConsumable(purchaseParam: param, autoConsume: false)
        : _store.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restore() => _store.restorePurchases();
  @override
  Future<void> complete(NativeStoreEvent event, StoreProduct product) async {
    final purchase = event.handle;
    if (purchase is! PurchaseDetails) {
      throw const EconomyException('invalid_native_receipt');
    }
    if (provider == 'android' && product.kind == 'topup') {
      final result = await _store
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>()
          .consumePurchase(purchase);
      if (result.responseCode != BillingResponse.ok &&
          result.responseCode != BillingResponse.itemNotOwned) {
        throw const EconomyException('store_completion_pending');
      }
      return;
    }
    if (purchase.pendingCompletePurchase) {
      await _store.completePurchase(purchase);
    }
  }
}
