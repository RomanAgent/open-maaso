import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/economy/application/cosmetic_service.dart';
import 'package:maaso/src/features/economy/data/cosmetic_gateway.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/domain/cosmetic_appearance.dart';
import 'package:maaso/src/features/economy/domain/cosmetic_shop_models.dart';
import 'package:maaso/src/features/economy/domain/economy_models.dart';

const cosmeticStyle = CosmeticStyle(
  kind: 'frame',
  renderId: 'aurora',
  nameEn: 'Aurora',
  nameZh: '极光',
);
const ownedItem = OwnedCosmetic(
  id: 'owned-one',
  productId: 'frame.aurora',
  style: cosmeticStyle,
  price: 300,
  transactionId: 'transaction-one',
);

class CosmeticFake implements CosmeticGateway {
  @override
  String requestContextKey = 'account-A';
  int writes = 0, quotes = 0, equips = 0, available = 1000;
  bool uncertain = false, block = false, ready = true, failCatalog = false;
  final requests = <String>[];
  final equipment = <String>[];
  Completer<CosmeticPurchaseReceipt>? response;
  DateTime now = DateTime.utc(2026, 9, 13);
  List<OwnedCosmetic> owned = [];
  @override
  Future<EconomyWallet> wallet(String context) async => EconomyWallet(
    available: available,
    pending: 500,
    frozen: 500,
    total: available + 1000,
    purchasedAvailable: available,
    earnedAvailable: 0,
    blocked: block,
    version: 1,
    playerName: 'Sky',
  );
  @override
  Future<CosmeticCatalog> cosmeticCatalog(String context) async {
    if (failCatalog) throw const EconomyException('ECONOMY_POLICY_UNAVAILABLE');
    return CosmeticCatalog(
      ready: ready,
      items: [
        CosmeticOffer('frame.aurora', cosmeticStyle, 300, owned.isNotEmpty),
      ],
    );
  }

  @override
  Future<CosmeticInventory> cosmeticInventory(String context) async =>
      CosmeticInventory(items: owned, equipped: const EquippedCosmetics());
  @override
  Future<CosmeticQuote> quoteCosmetic(String context, String product) async {
    quotes++;
    return CosmeticQuote(
      id: 'quote-one',
      productId: product,
      style: cosmeticStyle,
      price: 300,
      version: 'fixture-v1',
      expiresAt: now.add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<CosmeticPurchaseReceipt> purchaseCosmetic(
    String context, {
    required String quoteId,
    required String requestId,
  }) async {
    writes++;
    requests.add(requestId);
    if (response != null) return response!.future;
    if (uncertain) throw const EconomyException('connection_unavailable');
    owned = [ownedItem];
    return CosmeticPurchaseReceipt(quoteId, ownedItem);
  }

  @override
  Future<EquippedCosmetics> equipCosmetic(
    String context, {
    required String actorKind,
    required String slot,
    required String ownershipId,
  }) async {
    equips++;
    equipment.add('$actorKind/$slot/$ownershipId');
    return const EquippedCosmetics();
  }
}

CosmeticService makeService(CosmeticFake g) => CosmeticService(
  gateway: g,
  ownerIsCurrent: () => true,
  now: () => g.now,
  requestId: () => 'same-original-key',
);
void main() {
  test(
    'preview cannot charge and uncertain receipt survives navigation and expiry',
    () async {
      final g = CosmeticFake();
      final service = makeService(g);
      await service.load();
      final q = await service.prepare('frame.aurora');
      expect(g.writes, 0);
      g.uncertain = true;
      await expectLater(
        service.confirm(q.id),
        throwsA(isA<EconomyException>()),
      );
      service.cancel();
      expect(service.pending!.uncertain, true);
      await expectLater(
        service.prepare('frame.aurora'),
        throwsA(isA<EconomyException>()),
      );
      g.uncertain = false;
      g.now = g.now.add(const Duration(days: 1));
      g.available = 0;
      await service.load();
      final r = await service.confirm(q.id);
      expect(r.ownership.id, 'owned-one');
      expect(g.requests, ['same-original-key', 'same-original-key']);
      expect(service.pending, isNull);
    },
  );
  test(
    'pending and frozen balances cannot cover purchase, duplicate confirms and late account callbacks are fenced',
    () async {
      final g = CosmeticFake();
      final s = makeService(g);
      g.available = 0;
      await s.load();
      final q = await s.prepare('frame.aurora');
      await expectLater(s.confirm(q.id), throwsA(isA<EconomyException>()));
      expect(g.writes, 0);
      g.available = 1000;
      g.block = true;
      await s.load();
      await expectLater(s.confirm(q.id), throwsA(isA<EconomyException>()));
      expect(g.writes, 0);
      g.block = false;
      await s.load();
      g.response = Completer();
      final first = s.confirm(q.id);
      await Future<void>.delayed(Duration.zero);
      await expectLater(s.confirm(q.id), throwsA(isA<EconomyException>()));
      g.requestContextKey = 'account-B';
      g.response!.complete(CosmeticPurchaseReceipt(q.id, ownedItem));
      await expectLater(first, throwsA(isA<EconomyException>()));
      expect(s.receipt.value, isNull);
      expect(s.pending, isNull);
    },
  );
  test(
    'owned cosmetics remain equipable during pricing outage; wrong slot/foreign ownership never leaves client',
    () async {
      final g = CosmeticFake()
        ..owned = [ownedItem]
        ..failCatalog = true;
      final s = makeService(g);
      await s.load();
      expect(s.inventory.value!.items.single.id, 'owned-one');
      await s.equip(
        actorKind: 'agent',
        slot: 'frame',
        ownershipId: 'owned-one',
      );
      expect(g.equipment, ['agent/frame/owned-one']);
      await expectLater(
        s.equip(actorKind: 'player', slot: 'title', ownershipId: 'owned-one'),
        throwsA(isA<EconomyException>()),
      );
      await expectLater(
        s.equip(actorKind: 'agent', slot: 'frame', ownershipId: 'foreign'),
        throwsA(isA<EconomyException>()),
      );
      expect(g.equips, 1);
      await s.equip(actorKind: 'player', slot: 'frame', ownershipId: '');
      expect(g.equips, 2);
    },
  );
  test('HTTP cosmetic operations carry server identifiers only', () async {
    final calls = <http.Request>[];
    final client = EconomyHttpClient(
      baseUri: () => Uri.parse('https://test.example/'),
      accountId: () => 'A',
      accessToken: () async => 'token',
      client: MockClient((r) async {
        calls.add(r);
        final data = r.url.path.endsWith('equip')
            ? {'player': {}, 'agent': {}}
            : {
                'quoteId': 'quote-one',
                'productId': 'frame.aurora',
                ...cosmeticStyle.toJson(),
                'priceCoins': 300,
                'policyVersion': 'fixture',
                'expiresAt': '2026-09-13T01:00:00Z',
              };
        return http.Response(
          jsonEncode({'code': 'OK', 'data': data}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await client.quoteCosmetic(client.requestContextKey, 'frame.aurora');
    await client.equipCosmetic(
      client.requestContextKey,
      actorKind: 'agent',
      slot: 'frame',
      ownershipId: 'owned-one',
    );
    expect(calls.map((r) => r.url.path), [
      '/v1/economy/cosmetics/quotes',
      '/v1/economy/cosmetics/equip',
    ]);
    expect(jsonDecode(calls[0].body), {'productId': 'frame.aurora'});
    expect(jsonDecode(calls[1].body), {
      'actorKind': 'agent',
      'slot': 'frame',
      'ownershipId': 'owned-one',
    });
    expect(
      calls.every((r) => r.headers['Authorization'] == 'Bearer token'),
      true,
    );
  });
}
