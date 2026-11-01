import 'dart:async';
import 'dart:io';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:package_info_plus/package_info_plus.dart';

class NativeSkillPurchaseReceipt {
  const NativeSkillPurchaseReceipt({
    required this.provider,
    required this.productId,
    required this.completionKey,
    this.appleReceipt,
    this.transactionId,
    this.googlePackageName,
    this.googlePurchaseToken,
  });

  final String provider;
  final String productId;
  final String completionKey;
  final String? appleReceipt;
  final String? transactionId;
  final String? googlePackageName;
  final String? googlePurchaseToken;
}

/// Starts a store purchase and returns provider proof only. The caller must
/// submit that proof to Maaso's server and call [complete] only after the
/// server returns an active entitlement.
class SkillPurchaseService extends AppService {
  SkillPurchaseService({InAppPurchase? inAppPurchase})
    : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance;

  final InAppPurchase _inAppPurchase;
  final _pendingPurchases = <String, PurchaseDetails>{};
  final isPurchaseInProgress = false.obs;

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  Completer<NativeSkillPurchaseReceipt>? _pendingReceipt;
  String? _pendingProductId;

  @override
  void onInit() {
    super.onInit();
    _purchaseSubscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error, StackTrace stackTrace) {
        _pendingReceipt?.completeError(error, stackTrace);
        _clearPendingRequest();
      },
    );
  }

  Future<NativeSkillPurchaseReceipt> purchase(MarketplaceSkill skill) {
    // Kept as a binary-compatible legacy service only. New marketplace paths
    // are free and never invoke native billing or server purchase endpoints.
    throw StateError('Skill purchases are no longer supported');
  }

  Future<void> complete(NativeSkillPurchaseReceipt receipt) async {
    final purchase = _pendingPurchases.remove(receipt.completionKey);
    if (purchase != null && purchase.pendingCompletePurchase) {
      await _inAppPurchase.completePurchase(purchase);
    }
  }

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != _pendingProductId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          continue;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          final completer = _pendingReceipt;
          if (completer == null || completer.isCompleted) continue;
          try {
            final receipt = await _receiptFor(purchase);
            _pendingPurchases[receipt.completionKey] = purchase;
            completer.complete(receipt);
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          } finally {
            _clearPendingRequest();
          }
          break;
        case PurchaseStatus.error:
          _pendingReceipt?.completeError(
            StateError(
              purchase.error?.message ?? 'The app store rejected the purchase',
            ),
          );
          _clearPendingRequest();
          break;
        case PurchaseStatus.canceled:
          _pendingReceipt?.completeError(
            StateError('The purchase was cancelled'),
          );
          _clearPendingRequest();
          break;
      }
    }
  }

  Future<NativeSkillPurchaseReceipt> _receiptFor(
    PurchaseDetails purchase,
  ) async {
    final proof = purchase.verificationData.serverVerificationData.trim();
    if (proof.isEmpty) {
      throw StateError(
        'The app store did not return purchase verification data',
      );
    }
    final purchaseID = purchase.purchaseID?.trim() ?? '';
    final completionKey = '${purchase.productID}|$purchaseID|$proof';
    if (Platform.isIOS || Platform.isMacOS) {
      return NativeSkillPurchaseReceipt(
        provider: 'ios',
        productId: purchase.productID,
        completionKey: completionKey,
        appleReceipt: proof,
        transactionId: purchaseID.isEmpty ? null : purchaseID,
      );
    }
    if (Platform.isAndroid) {
      final packageInfo = await PackageInfo.fromPlatform();
      return NativeSkillPurchaseReceipt(
        provider: 'android',
        productId: purchase.productID,
        completionKey: completionKey,
        googlePackageName: packageInfo.packageName,
        googlePurchaseToken: proof,
      );
    }
    throw StateError('Skill purchases are available on iOS and Android only');
  }

  void _clearPendingRequest() {
    _pendingReceipt = null;
    _pendingProductId = null;
    isPurchaseInProgress.value = false;
  }

  @override
  void onClose() {
    _purchaseSubscription?.cancel();
    super.onClose();
  }
}
