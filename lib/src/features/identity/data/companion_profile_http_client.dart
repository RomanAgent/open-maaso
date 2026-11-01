import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/companion_profile.dart';

final class CompanionProfileHttpClient implements CompanionProfileGateway {
  CompanionProfileHttpClient({
    required Uri Function() baseUri,
    required String Function() accountId,
    required Future<String> Function() accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 18),
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
  CompanionProfile? _cached;
  String? _cachedContext;
  @override
  String get requestContextKey => '${_baseUri()}|${_accountId().trim()}';
  void _check(String expected) {
    if (_closed || expected != requestContextKey) {
      throw const CompanionProfileException(
        CompanionProfileFailure.contextChanged,
      );
    }
    if (_accountId().trim().isEmpty) {
      throw const CompanionProfileException(
        CompanionProfileFailure.authenticationRequired,
      );
    }
  }

  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) =>
      _request(expectedContextKey, null);
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) => _request(expectedContextKey, {
    'expectedVersion': profile.version,
    'avatarPreset': profile.avatarPreset,
    'avatarJpeg': profile.avatarJpeg,
    'agentGender': profile.agentGender,
    'interests': profile.interests,
    'onboardingVersion': profile.onboardingVersion,
  });
  Future<CompanionProfile> _request(
    String expected,
    Map<String, Object?>? body,
  ) async {
    _check(expected);
    final uri = _baseUri().resolve(
      body == null
          ? 'v1/identity/companion-profile'
          : 'v1/identity/companion-profile/update',
    );
    final token = await _accessToken();
    _check(expected);
    if (token.trim().isEmpty) {
      throw const CompanionProfileException(
        CompanionProfileFailure.authenticationRequired,
      );
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
      if (body == null && _cachedContext == expected && _cached != null)
        'If-None-Match': '"maaso-profile-v${_cached!.version}"',
      if (body != null) 'Content-Type': 'application/json',
    };
    late http.Response response;
    try {
      final request = http.Request(body == null ? 'GET' : 'POST', uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(timeout);
      _check(expected);
      final bytes = <int>[];
      await for (final chunk in streamed.stream.timeout(timeout)) {
        _check(expected);
        if (bytes.length + chunk.length > 192 * 1024) {
          throw const CompanionProfileException(
            CompanionProfileFailure.invalidResponse,
          );
        }
        bytes.addAll(chunk);
      }
      response = http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
      );
    } on CompanionProfileException {
      rethrow;
    } catch (_) {
      _check(expected);
      throw const CompanionProfileException(
        CompanionProfileFailure.unavailable,
      );
    }
    _check(expected);
    if (response.statusCode == 304 &&
        body == null &&
        _cachedContext == expected &&
        _cached != null &&
        response.headers['etag'] == '"maaso-profile-v${_cached!.version}"') {
      return _cached!;
    }
    if (response.statusCode == 401) {
      throw const CompanionProfileException(
        CompanionProfileFailure.authenticationRequired,
      );
    }
    if (response.statusCode == 409) {
      throw const CompanionProfileException(CompanionProfileFailure.conflict);
    }
    if (response.statusCode == 404 ||
        response.statusCode == 429 ||
        response.statusCode >= 500) {
      throw const CompanionProfileException(
        CompanionProfileFailure.unavailable,
      );
    }
    if (response.statusCode != 200) {
      throw const CompanionProfileException(CompanionProfileFailure.rejected);
    }
    try {
      if (response.bodyBytes.length > 192 * 1024) throw const FormatException();
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['code'] != 'OK') {
        throw const FormatException();
      }
      final profile = CompanionProfile.fromJson(decoded['data']);
      if (_cachedContext != expected ||
          _cached == null ||
          profile.version >= _cached!.version) {
        _cachedContext = expected;
        _cached = profile;
      }
      return profile;
    } catch (_) {
      throw const CompanionProfileException(
        CompanionProfileFailure.invalidResponse,
      );
    }
  }

  void close() {
    _closed = true;
    _cached = null;
    _cachedContext = null;
    if (_ownsClient) _client.close();
  }
}
