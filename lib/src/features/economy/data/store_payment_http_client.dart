import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/economy_models.dart';
import '../domain/store_payment_models.dart';
import '../domain/economy_market_info.dart';
import 'membership_availability_reader.dart';

abstract interface class StorePaymentGateway {
  String get requestContextKey;
  Future<List<StoreOffer>> catalog(String context, String provider);
  Future<StoreCheckout> checkout(
    String context,
    StoreProduct product, {
    String? expectedPolicyVersion,
  });
  Future<void> cancel(String context, String intentId);
  Future<StoreReceipt> verify(String context, Map<String, Object?> proof);
  Future<List<StoreReceipt>> receipts(String context);
  Future<MembershipUsage> usage(String context);
  void close();
}

/// Shares the existing mounted account's token resolver and fixed environment.
/// It does not accept private account identifiers in any server request body.
final class StorePaymentHttpClient
    implements StorePaymentGateway, MembershipAvailabilityReader {
  StorePaymentHttpClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
  }) : _base = baseUri,
       _account = accountId,
       _token = accessToken,
       _client = client ?? http.Client(),
       _owns = client == null;
  final Uri Function() _base;
  final String Function() _account;
  final Future<String> Function() _token;
  final http.Client _client;
  final bool _owns;
  bool _closed = false;
  @override
  String get requestContextKey => '${_base()}|${_account().trim()}';
  void _check(String context) {
    if (_closed || context != requestContextKey) {
      throw const EconomyException('context_changed');
    }
    if (_account().trim().isEmpty) {
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
    var uri = _base().resolve(path);
    if (query != null) uri = uri.replace(queryParameters: query);
    final token = await _token();
    _check(context);
    if (token.trim().isEmpty) {
      throw const EconomyException('authentication_required');
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
    };
    late http.Response response;
    try {
      response =
          await (body == null
                  ? _client.get(uri, headers: headers)
                  : _client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(const Duration(seconds: 15));
    } catch (_) {
      _check(context);
      throw const EconomyException('connection_unavailable');
    }
    _check(context);
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const EconomyException('invalid_response');
    }
    try {
      final m = economyObject(jsonDecode(utf8.decode(response.bodyBytes)));
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          m['code'] != 'OK') {
        throw EconomyException(
          m['code'] is String ? m['code'] as String : 'connection_unavailable',
          statusCode: response.statusCode,
        );
      }
      return parse(m['data']);
    } on FormatException {
      throw const EconomyException('invalid_response');
    }
  }

  @override
  Future<List<StoreOffer>> catalog(String context, String provider) => _request(
    context,
    'v1/store/payments/catalog',
    (v) {
      final data = economyObject(v);
      final active = economyList(data['offers'], StoreOffer.fromJson);
      final restored = economyList(
        data['restoreProducts'] ?? const <Object?>[],
        StoreProduct.fromJson,
      );
      if (active.any((offer) => offer.product.retired) ||
          restored.any((product) => !product.retired)) {
        throw const FormatException('invalid_store_catalog_partition');
      }
      final activeProVersions = active
          .where((offer) => offer.product.tier == MembershipTier.proV2)
          .map((offer) => offer.product.id)
          .toSet();
      if (activeProVersions.contains('maaso.membership.pro.monthly.v2') &&
          activeProVersions.contains('maaso.membership.pro.monthly.v3')) {
        throw const FormatException('conflicting_active_pro_products');
      }
      final all = <StoreOffer>[
        ...active,
        for (final product in restored)
          StoreOffer(product, false, 'retired_product'),
      ];
      if (all.map((offer) => offer.product.key).toSet().length != all.length) {
        throw const FormatException('duplicate_store_product');
      }
      return all;
    },
    query: {'provider': provider},
  );
  @override
  Future<StoreCheckout> checkout(
    String context,
    StoreProduct p, {
    String? expectedPolicyVersion,
  }) => _request(
    context,
    'v1/store/payments/checkout',
    StoreCheckout.fromJson,
    body: {
      'provider': p.provider,
      'productId': p.id,
      'expectedPolicyVersion': ?expectedPolicyVersion,
      if (p.plan.isNotEmpty) 'basePlanId': p.plan,
    },
  );
  @override
  Future<void> cancel(String context, String intentId) => _request(
    context,
    'v1/store/payments/checkout/cancel',
    (_) {},
    body: {'intentId': intentId},
  );
  @override
  Future<StoreReceipt> verify(String context, Map<String, Object?> proof) =>
      _request(
        context,
        'v1/store/payments/verify',
        StoreReceipt.fromJson,
        body: proof,
      );
  @override
  Future<List<StoreReceipt>> receipts(String context) => _request(
    context,
    'v1/store/payments/receipts',
    (v) => economyList(v, StoreReceipt.fromJson),
    query: {'limit': '30'},
  );
  @override
  Future<MembershipAvailability> membershipAvailability(String context) =>
      _request(
        context,
        'v1/membership/availability',
        MembershipAvailability.fromJson,
      );
  @override
  Future<MembershipUsage> usage(String context) =>
      _request(context, 'v1/membership/usage', MembershipUsage.fromJson);
  @override
  void close() {
    _closed = true;
    if (_owns) _client.close();
  }
}
