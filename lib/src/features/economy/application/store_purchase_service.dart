import 'dart:async';
import 'package:maaso/src/core/foundation/app_framework.dart';
import '../data/native_store_gateway.dart';
import '../data/store_payment_http_client.dart';
import '../domain/economy_models.dart';
import '../domain/store_payment_models.dart';
import '../domain/economy_market_info.dart';
import '../data/membership_availability_reader.dart';

/// One account-owned store listener. Switching account fences late responses
/// before acknowledging them; reopening/restore uses the provider transaction ID.
final class StorePurchaseService extends AppService {
  StorePurchaseService({
    required StorePaymentGateway gateway,
    NativeStoreGateway? native,
    DateTime Function()? now,
  }) : _gateway = gateway,
       _native = native,
       _now = now ?? DateTime.now,
       boundContextKey = gateway.requestContextKey;
  final StorePaymentGateway _gateway;
  final NativeStoreGateway? _native;
  final DateTime Function() _now;
  final String boundContextKey;
  final offers = <StoreOffer>[].obs;
  final products = <NativeStoreProduct>[].obs;
  final receipts = <StoreReceipt>[].obs;
  final usage = Rx<MembershipUsage?>(null);
  final error = Rx<String?>(null);
  final busy = false.obs;
  final loading = false.obs;
  final nativeReady = false.obs;
  final retired = false.obs;
  StreamSubscription<List<NativeStoreEvent>>? _subscription;
  Future<void> _queue = Future.value();
  final _unresolved = <String, NativeStoreEvent>{};
  final _completed = <String>{};
  final _inFlight = <String>{};
  StoreCheckout? _checkout;
  List<StoreProduct> _verificationProducts = const [];
  bool _started = false;
  bool get isCurrent =>
      !retired.value && boundContextKey == _gateway.requestContextKey;
  bool get hasUnresolved => _unresolved.isNotEmpty || _checkout != null;
  void _check() {
    if (!isCurrent) throw const EconomyException('context_changed');
  }

  /// Initialized on demand for membership purchases and restores.
  Future<void> load() async {
    _check();
    if (loading.value) return;
    loading.value = true;
    error.value = null;
    if (!_started) {
      _started = true;
      _subscription = _native?.events.listen(
        (batch) {
          for (final event in batch) {
            _queue = _queue.then((_) => _handle(event)).catchError((Object e) {
              if (isCurrent) {
                error.value = e is EconomyException
                    ? e.code
                    : 'store_verification_pending';
              }
            });
          }
        },
        onError: (Object _) {
          if (isCurrent) error.value = 'store_unavailable';
        },
      );
    }
    try {
      final loadedReceipts = await _gateway.receipts(boundContextKey);
      _check();
      receipts.assignAll(loadedReceipts);
      try {
        final value = await _gateway.usage(boundContextKey);
        _check();
        usage.value = value;
      } on EconomyException catch (e) {
        _check();
        error.value = e.code;
      }
      final native = _native;
      if (native != null) {
        final catalog = await _gateway.catalog(
          boundContextKey,
          native.provider,
        );
        _check();
        _verificationProducts = catalog.map((offer) => offer.product).toList();
        offers.assignAll(catalog.where((offer) => !offer.product.retired));
        nativeReady.value = await native.available();
        _check();
        if (nativeReady.value) {
          final list = await native.products(
            offers.where((o) => o.ready).map((o) => o.product).toList(),
          );
          _check();
          products.assignAll(list);
        }
      }
      await retryVerification();
    } on EconomyException catch (e) {
      if (isCurrent) error.value = e.code;
    } catch (_) {
      if (isCurrent) error.value = 'store_unavailable';
    } finally {
      if (isCurrent) loading.value = false;
    }
  }

  Future<MembershipAvailability> readMembershipAvailability() async {
    _check();
    final gateway = _gateway;
    if (gateway is! MembershipAvailabilityReader) {
      throw const EconomyException('membership_details_unavailable');
    }
    final result = await (gateway as MembershipAvailabilityReader)
        .membershipAvailability(boundContextKey);
    _check();
    return result;
  }

  /// Called exclusively by a human purchase button. AppControl has no access.
  Future<void> buy(
    NativeStoreProduct displayed, {
    String? expectedPolicyVersion,
  }) async {
    _check();
    if (busy.value || hasUnresolved || _native == null || !nativeReady.value) {
      throw const EconomyException('purchase_unresolved');
    }
    if (!products.any((p) => identical(p, displayed))) {
      throw const EconomyException('invalid_native_product');
    }
    if (displayed.product.kind == 'membership' &&
        (expectedPolicyVersion == null ||
            expectedPolicyVersion.trim().isEmpty)) {
      throw const EconomyException('membership_details_unavailable');
    }
    busy.value = true;
    error.value = null;
    try {
      final prepared = await _gateway.checkout(
        boundContextKey,
        displayed.product,
        expectedPolicyVersion: expectedPolicyVersion,
      );
      _check();
      if (displayed.product.kind == 'membership' &&
          prepared.policyVersion != expectedPolicyVersion) {
        try {
          await _gateway.cancel(boundContextKey, prepared.id);
        } catch (_) {
          /* No native payment started. */
        }
        _check();
        throw const EconomyException('membership_policy_changed');
      }
      if (prepared.product.kind != displayed.product.kind ||
          prepared.product.tier != displayed.product.tier ||
          prepared.product.key != displayed.product.key ||
          prepared.product.coins != displayed.product.coins ||
          prepared.product.usdCents != displayed.product.usdCents ||
          !prepared.expiresAt.isAfter(_now().toUtc())) {
        throw const EconomyException('invalid_response');
      }
      _checkout = prepared;
      final opened = await _native.purchase(displayed, prepared.binding);
      _check();
      if (!opened) {
        await _gateway.cancel(boundContextKey, prepared.id);
        _check();
        _checkout = null;
        busy.value = false;
        throw const EconomyException('store_cancelled');
      }
    } catch (e) {
      if (isCurrent) {
        error.value = e is EconomyException
            ? e.code
            : 'store_verification_pending';
        busy.value = false;
      }
      rethrow;
    }
  }

  Future<void> restore() async {
    _check();
    if (busy.value || _native == null) {
      throw const EconomyException('purchase_unresolved');
    }
    error.value = null;
    try {
      await _native.restore();
      _check();
      await retryVerification();
      final list = await _gateway.receipts(boundContextKey);
      _check();
      receipts.assignAll(list);
    } catch (e) {
      if (isCurrent) {
        error.value = e is EconomyException
            ? e.code
            : 'store_verification_pending';
      }
    }
  }

  Future<void> retryVerification() async {
    _check();
    for (final event in _unresolved.values.toList()) {
      await _handle(event);
    }
  }

  Future<void> _handle(NativeStoreEvent event) async {
    if (!isCurrent || _native == null) return;
    final allowed = _verificationProducts
        .where(
          (product) =>
              product.id == event.productId &&
              product.provider == _native.provider,
        )
        .toList();
    if (allowed.length != 1) {
      if (_unresolved.length < 100 && event.transactionId.isNotEmpty) {
        _unresolved[event.key] = event;
      }
      return;
    }
    if (event.status == NativeStoreStatus.pending) return;
    if (event.status == NativeStoreStatus.error ||
        event.status == NativeStoreStatus.cancelled) {
      if (_checkout?.product.id == event.productId) {
        final intent = _checkout!;
        try {
          await _gateway.cancel(boundContextKey, intent.id);
          _check();
        } catch (_) {
          if (!isCurrent) return;
        }
        _checkout = null;
        busy.value = false;
      }
      _unresolved.remove(event.key);
      error.value = event.status == NativeStoreStatus.cancelled
          ? 'store_cancelled'
          : 'store_rejected';
      return;
    }
    if (event.transactionId.isEmpty) {
      error.value = 'store_verification_pending';
      return;
    }
    if ((_completed.contains(event.key) &&
            event.status != NativeStoreStatus.restored) ||
        _inFlight.contains(event.key)) {
      return;
    }
    if (_unresolved.length >= 100 && !_unresolved.containsKey(event.key)) {
      error.value = 'store_restore_limit';
      return;
    }
    _unresolved[event.key] = event;
    final product = allowed.single;
    _inFlight.add(event.key);
    try {
      final receipt = await _gateway.verify(boundContextKey, {
        'provider': product.provider,
        'productId': product.id,
        if (product.plan.isNotEmpty) 'basePlanId': product.plan,
        'transactionId': event.transactionId,
        if (event.status == NativeStoreStatus.restored) 'refreshRenewal': true,
        if (event.purchaseToken.isNotEmpty)
          'purchaseToken': event.purchaseToken,
        if (_checkout?.product.key == product.key) 'intentId': _checkout!.id,
      });
      _check();
      if (!receipt.persisted ||
          receipt.productId != product.id ||
          receipt.kind != product.kind) {
        throw const EconomyException('invalid_response');
      }
      await _native.complete(event, product);
      _check();
      _completed.add(event.key);
      if (_completed.length > 100) _completed.remove(_completed.first);
      _unresolved.remove(event.key);
      if (_checkout?.product.key == product.key) _checkout = null;
      busy.value = false;
      receipts.removeWhere((r) => r.id == receipt.id);
      receipts.insert(0, receipt);
      if (receipts.length > 30) receipts.removeRange(30, receipts.length);
      error.value = receipt.state == 'awaiting_fulfillment'
          ? 'store_fulfillment_pending'
          : receipt.state == 'revoked'
          ? 'STORE_REVOKED'
          : null;
      final snapshot = await _gateway.usage(boundContextKey);
      _check();
      usage.value = snapshot;
    } catch (e) {
      if (isCurrent) {
        error.value = e is EconomyException
            ? e.code
            : 'store_verification_pending';
        busy.value = false;
      }
    } finally {
      _inFlight.remove(event.key);
    }
  }

  @override
  void onClose() {
    retired.value = true;
    unawaited(_subscription?.cancel());
    _unresolved.clear();
    _completed.clear();
    _verificationProducts = const [];
    offers.clear();
    products.clear();
    receipts.clear();
    usage.value = null;
    _checkout = null;
    _gateway.close();
    super.onClose();
  }
}
