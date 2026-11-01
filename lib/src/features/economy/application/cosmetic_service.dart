import 'dart:math';
import 'package:maaso/src/core/foundation/app_framework.dart';
import '../data/cosmetic_gateway.dart';
import '../domain/cosmetic_shop_models.dart';
import '../domain/economy_models.dart';

final class PendingCosmeticPurchase {
  PendingCosmeticPurchase(this.quote, this.requestId);
  final CosmeticQuote quote;
  final String requestId;
  bool uncertain = false;
}

/// Lazily owned by EconomyService. Navigation retains unresolved purchases;
/// owner teardown closes this state before closing the shared HTTP gateway.
final class CosmeticService extends AppService {
  CosmeticService({
    required CosmeticGateway gateway,
    required bool Function() ownerIsCurrent,
    DateTime Function()? now,
    String Function()? requestId,
  }) : _gateway = gateway,
       _ownerIsCurrent = ownerIsCurrent,
       _now = now ?? DateTime.now,
       _requestId = requestId ?? _newKey,
       boundContextKey = gateway.requestContextKey;
  final CosmeticGateway _gateway;
  final bool Function() _ownerIsCurrent;
  final DateTime Function() _now;
  final String Function() _requestId;
  final String boundContextKey;
  final retired = false.obs, loading = false.obs, busy = false.obs;
  final catalog = Rx<CosmeticCatalog?>(null),
      inventory = Rx<CosmeticInventory?>(null),
      wallet = Rx<EconomyWallet?>(null),
      error = Rx<String?>(null),
      receipt = Rx<CosmeticPurchaseReceipt?>(null);
  final _pending = Rx<PendingCosmeticPurchase?>(null);
  bool get isCurrent =>
      !retired.value &&
      _ownerIsCurrent() &&
      _gateway.requestContextKey == boundContextKey;
  PendingCosmeticPurchase? get pending => isCurrent ? _pending.value : null;
  static String _newKey() {
    final r = Random.secure();
    return 'cosmetic_${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  void _check() {
    if (!isCurrent) throw const EconomyException('context_changed');
  }

  Future<void> load() async {
    _check();
    if (loading.value) return;
    loading.value = true;
    error.value = null;
    // A pricing outage must not hide permanent ownership or prevent unequipping.
    await Future.wait([
      _read(
        () => _gateway.cosmeticCatalog(boundContextKey),
        (v) => catalog.value = v,
      ),
      _read(
        () => _gateway.cosmeticInventory(boundContextKey),
        (v) => inventory.value = v,
      ),
      _read(() => _gateway.wallet(boundContextKey), (v) => wallet.value = v),
    ]);
    if (isCurrent) loading.value = false;
  }

  Future<void> _read<T>(
    Future<T> Function() read,
    void Function(T) accept,
  ) async {
    try {
      final v = await read();
      _check();
      accept(v);
    } catch (e) {
      if (isCurrent) {
        error.value = e is EconomyException ? e.code : 'connection_unavailable';
      }
    }
  }

  Future<CosmeticQuote> prepare(String product) async {
    _check();
    if (busy.value || pending?.uncertain == true) {
      throw const EconomyException('purchase_unresolved');
    }
    if (catalog.value?.ready != true ||
        !catalog.value!.items.any((e) => e.productId == product && !e.owned)) {
      throw const EconomyException('quote_not_ready');
    }
    busy.value = true;
    error.value = null;
    try {
      final q = await _gateway.quoteCosmetic(boundContextKey, product);
      _check();
      if (q.productId != product || !q.expiresAt.isAfter(_now().toUtc())) {
        throw const EconomyException('invalid_response');
      }
      _pending.value = PendingCosmeticPurchase(q, _requestId());
      receipt.value = null;
      return q;
    } finally {
      if (isCurrent) busy.value = false;
    }
  }

  void cancel() {
    if (isCurrent && !busy.value && pending?.uncertain != true) {
      _pending.value = null;
    }
  }

  /// Only the separate human confirmation button calls this, never AppControl.
  Future<CosmeticPurchaseReceipt> confirm(String displayedQuoteId) async {
    _check();
    final p = pending;
    if (busy.value || p == null || p.quote.id != displayedQuoteId) {
      throw const EconomyException('quote_not_ready');
    }
    if (!p.uncertain) {
      if (!p.quote.expiresAt.isAfter(_now().toUtc())) {
        throw const EconomyException('QUOTE_EXPIRED');
      }
      if (wallet.value?.blocked == true) {
        throw const EconomyException('WALLET_FROZEN');
      }
      if ((wallet.value?.available ?? 0) < p.quote.price) {
        throw const EconomyException('INSUFFICIENT_COINS');
      }
    }
    busy.value = true;
    error.value = null;
    try {
      final r = await _gateway.purchaseCosmetic(
        boundContextKey,
        quoteId: p.quote.id,
        requestId: p.requestId,
      );
      _check();
      if (r.quoteId != p.quote.id ||
          r.ownership.productId != p.quote.productId ||
          r.ownership.price != p.quote.price ||
          r.ownership.style.toJson().toString() !=
              p.quote.style.toJson().toString()) {
        throw const EconomyException('invalid_response');
      }
      receipt.value = r;
      _pending.value = null;
      await load();
      return r;
    } catch (e) {
      final failure = e is EconomyException
          ? e
          : const EconomyException('connection_unavailable');
      if (isCurrent) {
        error.value = failure.code;
        if (!failure.definiteRefusal && failure.code != 'COSMETIC_OWNED') {
          p.uncertain = true;
          _pending.refresh();
        }
      }
      throw failure;
    } finally {
      if (isCurrent) busy.value = false;
    }
  }

  Future<void> equip({
    required String actorKind,
    required String slot,
    required String ownershipId,
  }) async {
    _check();
    if (busy.value) throw const EconomyException('purchase_unresolved');
    if (!{'player', 'agent'}.contains(actorKind) ||
        !{'frame', 'title'}.contains(slot) ||
        (ownershipId.isNotEmpty &&
            inventory.value?.items.any(
                  (e) => e.id == ownershipId && e.style.kind == slot,
                ) !=
                true)) {
      throw const EconomyException('invalid_response');
    }
    busy.value = true;
    error.value = null;
    try {
      await _gateway.equipCosmetic(
        boundContextKey,
        actorKind: actorKind,
        slot: slot,
        ownershipId: ownershipId,
      );
      _check();
      await load();
    } finally {
      if (isCurrent) busy.value = false;
    }
  }

  @override
  void onClose() {
    retired.value = true;
    _pending.value = null;
    catalog.value = null;
    inventory.value = null;
    wallet.value = null;
    receipt.value = null;
    error.value = null;
    super.onClose();
  }
}
