import 'cosmetic_appearance.dart';
import 'economy_models.dart';

final class CosmeticOffer {
  const CosmeticOffer(this.productId, this.style, this.price, this.owned);
  final String productId;
  final CosmeticStyle style;
  final int price;
  final bool owned;
  factory CosmeticOffer.fromJson(Object? value) {
    final m = economyObject(value);
    if (m['owned'] is! bool) throw const FormatException('invalid_owned');
    return CosmeticOffer(
      economyString(m['productId'], max: 128),
      CosmeticStyle.fromJson(m),
      economyInteger(m['priceCoins'], positive: true),
      m['owned'] as bool,
    );
  }
}

final class CosmeticCatalog {
  const CosmeticCatalog({
    required this.ready,
    required this.items,
    this.reason,
  });
  final bool ready;
  final String? reason;
  final List<CosmeticOffer> items;
  factory CosmeticCatalog.fromJson(Object? value) {
    final m = economyObject(value);
    if (m['ready'] is! bool) throw const FormatException('invalid_ready');
    final items = economyList(m['items'], CosmeticOffer.fromJson, max: 100);
    if (items.map((e) => e.productId).toSet().length != items.length) {
      throw const FormatException('duplicate_cosmetic');
    }
    return CosmeticCatalog(
      ready: m['ready'] as bool,
      items: items,
      reason: m['unavailableReason'] is String
          ? m['unavailableReason'] as String
          : null,
    );
  }
}

final class OwnedCosmetic {
  const OwnedCosmetic({
    required this.id,
    required this.productId,
    required this.style,
    required this.price,
    required this.transactionId,
  });
  final String id, productId, transactionId;
  final CosmeticStyle style;
  final int price;
  factory OwnedCosmetic.fromJson(Object? value) {
    final m = economyObject(value);
    return OwnedCosmetic(
      id: economyString(m['ownershipId']),
      productId: economyString(m['productId'], max: 128),
      style: CosmeticStyle.fromJson(m),
      price: economyInteger(m['priceCoins'], positive: true),
      transactionId: economyString(m['transactionId']),
    );
  }
}

final class EquippedCosmetics {
  const EquippedCosmetics({
    this.player = const CosmeticAppearance(),
    this.agent = const CosmeticAppearance(),
  });
  final CosmeticAppearance player, agent;
  factory EquippedCosmetics.fromJson(Object? value) {
    final m = economyObject(value);
    return EquippedCosmetics(
      player: CosmeticAppearance.fromJson(m['player']),
      agent: CosmeticAppearance.fromJson(m['agent']),
    );
  }
}

final class CosmeticInventory {
  const CosmeticInventory({required this.items, required this.equipped});
  final List<OwnedCosmetic> items;
  final EquippedCosmetics equipped;
  factory CosmeticInventory.fromJson(Object? value) {
    final m = economyObject(value);
    return CosmeticInventory(
      items: economyList(m['items'], OwnedCosmetic.fromJson, max: 100),
      equipped: EquippedCosmetics.fromJson(m['equipped']),
    );
  }
}

final class CosmeticQuote {
  const CosmeticQuote({
    required this.id,
    required this.productId,
    required this.style,
    required this.price,
    required this.version,
    required this.expiresAt,
  });
  final String id, productId, version;
  final CosmeticStyle style;
  final int price;
  final DateTime expiresAt;
  factory CosmeticQuote.fromJson(Object? value) {
    final m = economyObject(value);
    return CosmeticQuote(
      id: economyString(m['quoteId']),
      productId: economyString(m['productId'], max: 128),
      style: CosmeticStyle.fromJson(m),
      price: economyInteger(m['priceCoins'], positive: true),
      version: economyString(m['policyVersion']),
      expiresAt: economyTime(m['expiresAt']),
    );
  }
}

final class CosmeticPurchaseReceipt {
  const CosmeticPurchaseReceipt(this.quoteId, this.ownership);
  final String quoteId;
  final OwnedCosmetic ownership;
  factory CosmeticPurchaseReceipt.fromJson(Object? value) {
    final m = economyObject(value), tx = economyObject(m['transaction']);
    final item = OwnedCosmetic.fromJson(m['ownership']);
    if (tx['kind'] != 'cosmetic' ||
        economyInteger(tx['coins'], positive: true) != item.price ||
        economyInteger(tx['burnedCoins']) != item.price ||
        economyInteger(tx['issuedCoins']) != 0 ||
        economyInteger(tx['payoutCoins']) != 0 ||
        tx['transactionId'] != item.transactionId) {
      throw const FormatException('invalid_cosmetic_receipt');
    }
    return CosmeticPurchaseReceipt(economyString(tx['quoteId']), item);
  }
}
