import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/network/backend_client.dart';
import '../domain/economy_models.dart';
import 'economy_market_gateway.dart';
import '../domain/economy_market_info.dart';
import 'cosmetic_gateway.dart';
import '../domain/cosmetic_shop_models.dart';
import 'creator_reward_gateway.dart';
import '../domain/creator_reward_evidence.dart';

abstract interface class EconomyGateway {
  String get requestContextKey;
  Future<EconomyCatalog> catalog(String context);
  Future<EconomyWallet> wallet(String context);
  Future<EconomyLedgerPage> ledger(String context, {int beforeId = 0});
  Future<List<EconomyRewardEstimate>> pendingRewards(String context);
  Future<EconomyMembership> membership(String context);
  Future<EconomyMembershipQuote> quoteMembership(
    String context,
    MembershipTier tier, {
    String? expectedPolicyVersion,
  });
  Future<EconomyRedemption> redeem(
    String context, {
    required String quoteId,
    required String requestId,
  });
}

/// Host injects its existing account-bound endpoint/token refresh callbacks.
/// No account identifier, amount or recipient ownership is accepted in writes.
final class EconomyHttpClient
    implements
        EconomyGateway,
        EconomyMarketGateway,
        CosmeticGateway,
        CreatorRewardGateway {
  EconomyHttpClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _baseUri = baseUri,
       _accountId = accountId,
       _accessToken = accessToken,
       _client = client ?? createMaasoBackendClient(),
       _ownsClient = client == null;
  final Uri Function() _baseUri;
  final String Function() _accountId;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  bool _closed = false;
  @override
  Future<CreatorRewardEvidencePage> creatorRewardEvidence(String context) =>
      _request(
        context,
        '../content-engagement/rewards/evidence',
        CreatorRewardEvidencePage.fromJson,
        query: {'limit': '${CreatorRewardEvidencePage.perStateLimit}'},
      );
  @override
  Future<CosmeticCatalog> cosmeticCatalog(String context) =>
      _request(context, 'cosmetics/catalog', CosmeticCatalog.fromJson);
  @override
  Future<CosmeticInventory> cosmeticInventory(String context) =>
      _request(context, 'cosmetics/inventory', CosmeticInventory.fromJson);
  @override
  Future<CosmeticQuote> quoteCosmetic(String context, String productId) =>
      _request(
        context,
        'cosmetics/quotes',
        CosmeticQuote.fromJson,
        body: {'productId': productId},
      );
  @override
  Future<CosmeticPurchaseReceipt> purchaseCosmetic(
    String context, {
    required String quoteId,
    required String requestId,
  }) => _request(
    context,
    'cosmetics/purchase',
    CosmeticPurchaseReceipt.fromJson,
    body: {'quoteId': quoteId, 'requestId': requestId},
  );
  @override
  Future<EquippedCosmetics> equipCosmetic(
    String context, {
    required String actorKind,
    required String slot,
    required String ownershipId,
  }) => _request(
    context,
    'cosmetics/equip',
    EquippedCosmetics.fromJson,
    body: {'actorKind': actorKind, 'slot': slot, 'ownershipId': ownershipId},
  );
  @override
  String get requestContextKey => '${_baseUri()}|${_accountId().trim()}';
  void _check(String context) {
    if (_closed || context != requestContextKey) {
      throw const EconomyException('context_changed');
    }
    if (_accountId().trim().isEmpty) {
      throw const EconomyException('authentication_required');
    }
  }

  Future<T> _request<T>(
    String context,
    String path,
    T Function(Object?) parse, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    _check(context);
    var uri = _baseUri().resolve('v1/economy/$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final token = await _accessToken();
    _check(context);
    if (token.trim().isEmpty) {
      throw const EconomyException('authentication_required');
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    late final http.Response response;
    try {
      response =
          await (body == null
                  ? _client.get(uri, headers: headers)
                  : _client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(timeout);
    } catch (_) {
      _check(context);
      throw const EconomyException('connection_unavailable');
    }
    _check(context);
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const EconomyException('invalid_response');
    }
    Map<String, dynamic>? envelope;
    try {
      envelope = economyObject(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (_) {
      /* Classify without reflecting a raw server body. */
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        envelope?['code'] != 'OK') {
      throw EconomyException(
        response.statusCode == 401
            ? 'authentication_required'
            : envelope?['code'] is String
            ? envelope!['code'] as String
            : 'connection_unavailable',
        statusCode: response.statusCode,
      );
    }
    try {
      return parse(envelope!['data']);
    } on FormatException {
      throw const EconomyException('invalid_response');
    }
  }

  @override
  Future<EconomyCatalog> catalog(String context) =>
      _request(context, 'catalog', EconomyCatalog.fromJson);
  @override
  Future<EconomyWallet> wallet(String context) =>
      _request(context, 'wallet', EconomyWallet.fromJson);
  @override
  Future<EconomyLedgerPage> ledger(String context, {int beforeId = 0}) {
    economyInteger(beforeId);
    return _request(
      context,
      'ledger',
      EconomyLedgerPage.fromJson,
      query: {'limit': '30', if (beforeId > 0) 'beforeId': '$beforeId'},
    );
  }

  @override
  Future<List<EconomyRewardEstimate>> pendingRewards(String context) =>
      _request(
        context,
        'rewards/pending',
        (value) => economyList(value, EconomyRewardEstimate.fromJson),
        query: {'limit': '30'},
      );
  @override
  Future<EconomyMembership> membership(String context) =>
      _request(context, 'membership', EconomyMembership.fromJson);
  @override
  Future<EconomyMembershipQuote> quoteMembership(
    String context,
    MembershipTier tier, {
    String? expectedPolicyVersion,
  }) => _request(
    context,
    'quotes',
    EconomyMembershipQuote.fromJson,
    body: {
      'kind': 'membership',
      'productId': tier.wireName,
      'expectedPolicyVersion': ?expectedPolicyVersion,
    },
  );
  @override
  Future<EconomyRedemption> redeem(
    String context, {
    required String quoteId,
    required String requestId,
  }) => _request(
    context,
    'membership/redeem',
    EconomyRedemption.fromJson,
    body: {'quoteId': quoteId, 'requestId': requestId},
  );
  void close() {
    _closed = true;
    if (_ownsClient) _client.close();
  }

  @override
  Future<MembershipAvailability> membershipAvailability(String context) =>
      _request(
        context,
        '../membership/availability',
        MembershipAvailability.fromJson,
      );
}
