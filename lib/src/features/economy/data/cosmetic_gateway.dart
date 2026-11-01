import '../domain/cosmetic_shop_models.dart';
import '../domain/economy_models.dart';

abstract interface class CosmeticGateway {
  String get requestContextKey;
  Future<EconomyWallet> wallet(String context);
  Future<CosmeticCatalog> cosmeticCatalog(String context);
  Future<CosmeticInventory> cosmeticInventory(String context);
  Future<CosmeticQuote> quoteCosmetic(String context, String productId);
  Future<CosmeticPurchaseReceipt> purchaseCosmetic(
    String context, {
    required String quoteId,
    required String requestId,
  });
  Future<EquippedCosmetics> equipCosmetic(
    String context, {
    required String actorKind,
    required String slot,
    required String ownershipId,
  });
}
