import 'dart:convert';

import 'package:http/http.dart' as http;

/// In-process authentication for the standalone edition's original login flow.
///
/// These markers identify a local test account. They are deliberately not
/// credentials accepted by any server. This client never opens a socket and
/// refuses every route outside the small local login/refresh contract.
class LocalTestAuthClient extends http.BaseClient {
  LocalTestAuthClient({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const username = 'test';
  static const password = 'test123456';
  static const accountUuid = 'open-maaso-local-test';
  static const accessMarker = 'local-test-account-session';
  static const refreshMarker = 'local-test-account-renewal';

  final DateTime Function() _clock;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Local auth client is closed.');
    final path = request.url.path;
    if (request.method != 'POST' ||
        !const {'/v1/login/email', '/v1/login/refresh'}.contains(path)) {
      return _response(request, 404, 'LOCAL_AUTH_ROUTE_UNAVAILABLE');
    }
    if (request.contentLength != null && request.contentLength! > 16384) {
      return _response(request, 413, 'LOCAL_AUTH_REQUEST_TOO_LARGE');
    }
    final bytes = <int>[];
    await for (final chunk in request.finalize()) {
      if (bytes.length + chunk.length > 16384) {
        return _response(request, 413, 'LOCAL_AUTH_REQUEST_TOO_LARGE');
      }
      bytes.addAll(chunk);
    }
    Object? payload;
    try {
      payload = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return _response(request, 400, 'LOCAL_AUTH_INVALID_REQUEST');
    }
    if (payload is! Map<String, dynamic>) {
      return _response(request, 400, 'LOCAL_AUTH_INVALID_REQUEST');
    }
    final valid = path == '/v1/login/email'
        ? payload['email'] == username && payload['password'] == password
        : payload['refresh_token'] == refreshMarker;
    if (!valid) return _response(request, 401, 'INVALID_CREDENTIALS');
    return _response(request, 200, 'OK', {
      'account_uuid': accountUuid,
      'access_token': accessMarker,
      'refresh_token': refreshMarker,
      'expires_at': _clock()
          .toUtc()
          .add(const Duration(days: 365))
          .toIso8601String(),
      'token_type': 'Local',
    });
  }

  http.StreamedResponse _response(
    http.BaseRequest request,
    int status,
    String code, [
    Map<String, Object?>? data,
  ]) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode({'code': code, 'data': data}))),
    status,
    request: request,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  @override
  void close() => _closed = true;
}
