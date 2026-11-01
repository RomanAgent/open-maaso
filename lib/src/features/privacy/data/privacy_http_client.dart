import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/privacy_models.dart';

/// Every request stays bound to the environment/account that admitted it. The
/// public policy endpoint deliberately receives neither token nor account ID.
final class PrivacyHttpClient implements PrivacyGateway {
  PrivacyHttpClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _baseUri = baseUri,
       _accountId = accountId,
       _accessToken = accessToken,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri Function() _baseUri;
  final String Function() _accountId;
  final Future<String> Function() _accessToken;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  bool _closed = false;

  @override
  String get requestContextKey => '${_baseUri()}|${_accountId().trim()}';

  @override
  bool get hasAccount => _accountId().trim().isNotEmpty;

  @override
  Future<PrivacyPublicPolicy> policy({
    required String expectedContextKey,
  }) async => _decode(
    await _request('policy', expectedContextKey, public: true),
    PrivacyPublicPolicy.fromJson,
  );

  @override
  Future<PrivacySnapshot> read({required String expectedContextKey}) async =>
      _decode(
        await _request('me', expectedContextKey),
        PrivacySnapshot.fromJson,
      );

  @override
  Future<PrivacySnapshot> declareAge({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String birthDate,
  }) async {
    final body = _mutation(
      requestKey,
      expectedRevision,
      expectedPolicyVersion,
      expectedPolicyHash,
    )..['birthDate'] = birthDate;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(birthDate)) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
    return _decode(
      await _request('age', expectedContextKey, body: body),
      PrivacySnapshot.fromJson,
    );
  }

  @override
  Future<PrivacySnapshot> setConsent({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String recipientId,
    required String scope,
    required bool allow,
  }) async {
    final body = _mutation(
      requestKey,
      expectedRevision,
      expectedPolicyVersion,
      expectedPolicyHash,
    );
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(recipientId) ||
        !PrivacyScopes.all.contains(scope)) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
    body.addAll({'recipientId': recipientId, 'scope': scope, 'allow': allow});
    return _decode(
      await _request('consent', expectedContextKey, body: body),
      PrivacySnapshot.fromJson,
    );
  }

  Map<String, Object?> _mutation(
    String key,
    int revision,
    String version,
    String hash,
  ) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(key) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,96}$').hasMatch(version) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        revision < 0 ||
        revision >= 9007199254740991) {
      throw const PrivacyException('PRIVACY_INVALID_INPUT');
    }
    return {
      'requestKey': key,
      'expectedRevision': revision,
      'expectedPolicyVersion': version,
      'expectedPolicyHash': hash,
    };
  }

  void _check(String expected, {bool public = false}) {
    if (_closed || expected != requestContextKey) {
      throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
    }
    if (!public && _accountId().trim().isEmpty) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
  }

  Future<Object?> _request(
    String path,
    String expected, {
    bool public = false,
    Map<String, Object?>? body,
  }) async {
    _check(expected, public: public);
    final uri = _baseUri().resolve('v1/privacy/$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
      if (body != null) 'Content-Type': 'application/json',
    };
    if (!public) {
      late final String token;
      try {
        token = await _accessToken().timeout(timeout);
      } catch (_) {
        _check(expected);
        throw const PrivacyException('PRIVACY_UNAVAILABLE');
      }
      _check(expected);
      if (token.trim().isEmpty) {
        throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
      }
      headers['Authorization'] = 'Bearer $token';
    }
    late final http.Response response;
    try {
      response =
          await (body == null
                  ? _client.get(uri, headers: headers)
                  : _client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(timeout);
    } catch (_) {
      _check(expected, public: public);
      throw const PrivacyException('PRIVACY_UNAVAILABLE');
    }
    _check(expected, public: public);
    if (response.bodyBytes.length > 256 * 1024) {
      throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      /* Below. */
    }
    final code = decoded is Map ? decoded['code'] : null;
    if (response.statusCode == 401) {
      throw const PrivacyException('PRIVACY_AUTHENTICATION_REQUIRED');
    }
    const known = {
      'PRIVACY_UNAVAILABLE',
      'PRIVACY_INVALID_INPUT',
      'PRIVACY_POLICY_CHANGED',
      'PRIVACY_REVISION_CONFLICT',
      'PRIVACY_AGE_REQUIRED',
      'PRIVACY_AGE_INELIGIBLE',
      'PRIVACY_CONSENT_REQUIRED',
    };
    if (known.contains(code)) throw PrivacyException(code as String);
    if (response.statusCode == 404 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      throw const PrivacyException('PRIVACY_UNAVAILABLE');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        code != 'OK' ||
        decoded is! Map) {
      throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
    }
    return decoded['data'];
  }

  T _decode<T>(Object? value, T Function(Object?) decode) {
    try {
      return decode(value);
    } on FormatException {
      throw const PrivacyException('PRIVACY_INVALID_RESPONSE');
    }
  }

  void close() {
    _closed = true;
    if (_ownsClient) _client.close();
  }
}
