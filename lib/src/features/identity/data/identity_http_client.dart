import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/network/backend_client.dart';

import '../domain/identity_profile.dart';

/// Host injects the active environment/account and its existing token refresh.
/// This client never caches credentials or accepts a caller-supplied actor ID.
final class IdentityHttpClient implements IdentityGateway {
  IdentityHttpClient({
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
  String get requestContextKey => '${_baseUri()}|${_accountId().trim()}';

  @override
  Future<IdentityProfile> fetch({required String expectedContextKey}) =>
      _request('v1/identity/profile', expectedContextKey: expectedContextKey);

  @override
  Future<IdentityProfile> update({
    required String expectedContextKey,
    required int expectedVersion,
    required String playerName,
    required String agentName,
  }) {
    if (expectedVersion < 0 || expectedVersion > 9007199254740991) {
      throw const FormatException('invalid_identity_version');
    }
    return _request(
      'v1/identity/profile/update',
      expectedContextKey: expectedContextKey,
      body: {
        'expectedVersion': expectedVersion,
        'playerName': IdentityNames.require(playerName),
        'agentName': IdentityNames.require(agentName),
      },
    );
  }

  void _check(String expected) {
    if (_closed || expected != requestContextKey) {
      throw const IdentityException(IdentityFailure.contextChanged);
    }
    if (_accountId().trim().isEmpty) {
      throw const IdentityException(IdentityFailure.authenticationRequired);
    }
  }

  Future<IdentityProfile> _request(
    String path, {
    required String expectedContextKey,
    Map<String, Object?>? body,
  }) async {
    _check(expectedContextKey);
    final uri = _baseUri().resolve(path);
    final token = await _accessToken();
    _check(expectedContextKey);
    if (token.trim().isEmpty) {
      throw const IdentityException(IdentityFailure.authenticationRequired);
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
      _check(expectedContextKey);
      throw const IdentityException(IdentityFailure.unavailable);
    }
    _check(expectedContextKey);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      /* Classified below. */
    }
    final code = decoded is Map ? decoded['code'] : null;
    if (response.statusCode == 409 && code == 'IDENTITY_VERSION_CONFLICT') {
      throw const IdentityException(IdentityFailure.conflict);
    }
    if (response.statusCode == 401) {
      throw const IdentityException(IdentityFailure.authenticationRequired);
    }
    if (response.statusCode == 404 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      throw const IdentityException(IdentityFailure.unavailable);
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        code != 'OK') {
      throw const IdentityException(IdentityFailure.rejected);
    }
    try {
      return IdentityProfile.fromJson((decoded as Map)['data']);
    } on FormatException {
      throw const IdentityException(IdentityFailure.invalidResponse);
    }
  }

  void close() {
    _closed = true;
    if (_ownsClient) _client.close();
  }
}
