import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

typedef RealtimeAccessTokenProvider = Future<String?> Function();

const int maxRealtimeJsonInteger = 9007199254740991;
const Set<String> _realtimeBackendErrorCodes = <String>{
  'AUTHENTICATION_REQUIRED',
  'FORBIDDEN',
  'INTERNAL_ERROR',
  'REALTIME_SESSION_BUSY',
  'REALTIME_SESSION_PENDING',
  'REALTIME_SESSION_START_UNCERTAIN',
  'RUNTIME_EVENT_CURSOR_EXPIRED',
  'RUNTIME_LEASE_REQUEST_REUSED',
  'SERVICE_UNAVAILABLE',
  'STALE_REALTIME_SESSION',
  'STALE_RUNTIME_LEASE',
  'STALE_RUNTIME_PRESENCE',
  'UNAUTHORIZED',
  'VALIDATION_ERROR',
};

/// A sanitized backend failure. Response bodies and messages are deliberately
/// excluded so a hostile or broken response cannot reflect credentials into
/// logs through [toString].
final class RealtimeBackendException implements Exception {
  const RealtimeBackendException({
    required this.statusCode,
    required this.code,
    this.retryAfter,
  });

  final int statusCode;
  final String code;
  final Duration? retryAfter;

  bool get isAuthorityFailure => const <String>{
    'STALE_RUNTIME_LEASE',
    'STALE_RUNTIME_PRESENCE',
    'STALE_REALTIME_SESSION',
    'RUNTIME_EVENT_CURSOR_EXPIRED',
  }.contains(code);

  bool get isRetryableSessionCreation =>
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500 ||
      const <String>{
        'REALTIME_SESSION_PENDING',
        'REALTIME_SESSION_BUSY',
        'REALTIME_SESSION_START_UNCERTAIN',
        'SERVICE_UNAVAILABLE',
      }.contains(code);

  bool get isRetryableStream =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() =>
      'Realtime backend request failed (HTTP $statusCode, code: $code).';
}

class RealtimeSession {
  const RealtimeSession({
    required this.sessionId,
    required this.locale,
    required this.rtcAppId,
    required this.roomId,
    required this.userId,
    required this.agentUserId,
    required this.taskId,
    required this.rtcToken,
    required this.actionStreamUri,
    required this.createdAt,
    this.leaseEpoch = 0,
    this.rtcGeneration = 0,
  });

  final String sessionId;
  final String locale;
  final String rtcAppId;
  final String roomId;
  final String userId;
  final String agentUserId;
  final String taskId;
  final String rtcToken;
  final Uri actionStreamUri;
  final DateTime createdAt;
  final int leaseEpoch;
  final int rtcGeneration;

  bool get isFenced => leaseEpoch > 0 && rtcGeneration > 0;

  @override
  String toString() =>
      'RealtimeSession(sessionId: $sessionId, locale: $locale, '
      'leaseEpoch: $leaseEpoch, rtcGeneration: $rtcGeneration)';
}

class RealtimeSessionClient {
  RealtimeSessionClient({
    required Uri baseUri,
    http.Client? httpClient,
    RealtimeAccessTokenProvider? accessTokenProvider,
    Duration requestTimeout = const Duration(seconds: 20),
    int maximumResponseBytes = 64 * 1024,
  }) : _baseUri = requireRealtimeHttpsBaseUri(baseUri),
       _httpClient = httpClient ?? http.Client(),
       _accessTokenProvider = accessTokenProvider,
       _requestTimeout = requestTimeout,
       _maximumResponseBytes = maximumResponseBytes,
       _ownsClient = httpClient == null {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    if (maximumResponseBytes < 1024) {
      throw ArgumentError.value(maximumResponseBytes, 'maximumResponseBytes');
    }
  }

  final Uri _baseUri;
  final http.Client _httpClient;
  final RealtimeAccessTokenProvider? _accessTokenProvider;
  final Duration _requestTimeout;
  final int _maximumResponseBytes;
  final bool _ownsClient;
  bool _closed = false;

  Uri get baseUri => _baseUri;

  Future<RealtimeSession> createSession({
    required String agentId,
    required String requestId,
    AccountDeviceLeaseRequestAuthority? authority,
    String? userId,
    AppLocale? locale,
    int resumeAfterSequence = 0,
  }) async {
    _requireOpen();
    final normalizedAgentId = _opaqueId(agentId, 'agentId');
    final normalizedRequestId = _requestId(requestId);
    _cursor(resumeAfterSequence, 'resumeAfterSequence');
    if (authority != null) {
      authority.requireCurrent();
      if (authority.agentId != normalizedAgentId) {
        throw StateError(
          'Realtime authority does not match the requested agent',
        );
      }
    } else if (resumeAfterSequence != 0) {
      throw StateError(
        'Legacy realtime sessions cannot resume a durable cursor',
      );
    }

    final requestedLocale = locale ?? AgentPromptCatalog.currentLocale;
    final sessionLocale = AgentPromptCatalog.runWithLocale(
      requestedLocale,
      () => AgentPromptCatalog.currentLocale,
    );
    final destination = _baseUri.resolve('/v1/realtime/sessions');
    requireRealtimeSameOriginEndpoint(
      configuredBaseUri: _baseUri,
      destination: destination,
      expectedPath: '/v1/realtime/sessions',
    );

    final request = http.Request('POST', destination)
      ..followRedirects = false
      ..maxRedirects = 0;
    final token = (await _accessTokenProvider?.call())?.trim();
    _requireOpen();
    authority?.requireCurrent();
    request.headers['content-type'] = 'application/json; charset=utf-8';
    request.headers['accept'] = 'application/json';
    request.headers['cache-control'] = 'no-store';
    if (token != null && token.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $token';
    }
    final body = <String, Object?>{
      'agentId': normalizedAgentId,
      if (userId != null && userId.trim().isNotEmpty) 'userId': userId.trim(),
      'locale': _resolvedLocaleTag(sessionLocale),
    };
    if (authority != null) {
      body['requestId'] = normalizedRequestId;
      if (resumeAfterSequence > 0) {
        body['resumeAfterSequence'] = resumeAfterSequence;
      }
      // No await may be inserted between this destination-bound proof copy
      // and dispatch.
      authority.authorizeRealtimeSessionCreation(
        body,
        destination: destination,
      );
    }
    request.body = jsonEncode(body);

    final response = await _httpClient.send(request).timeout(_requestTimeout);
    _requireOpen();
    authority?.requireCurrent();
    final responseBytes = await readBoundedRealtimeResponse(
      response,
      maximumBytes: _maximumResponseBytes,
      timeout: _requestTimeout,
    );
    _requireOpen();
    authority?.requireCurrent();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw realtimeBackendException(response, responseBytes);
    }
    return _parseSession(
      responseBytes,
      authority: authority,
      configuredBaseUri: _baseUri,
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _httpClient.close();
  }

  void _requireOpen() {
    if (_closed) throw StateError('Realtime session client is closed');
  }
}

RealtimeSession _parseSession(
  Uint8List bytes, {
  required AccountDeviceLeaseRequestAuthority? authority,
  required Uri configuredBaseUri,
}) {
  final envelope = _jsonObject(bytes, 'realtime session envelope');
  _requireExactKeys(envelope, const <String>{
    'code',
    'message',
    'traceId',
    'data',
  }, 'realtime session envelope');
  if (envelope['code'] != 'OK') {
    throw const FormatException('realtime session response code is invalid');
  }
  final rawData = envelope['data'];
  if (rawData is! Map) {
    throw const FormatException('realtime session data is missing');
  }
  final data = Map<String, Object?>.from(rawData);
  final expectedKeys = <String>{
    'sessionId',
    'locale',
    'rtcAppId',
    'roomId',
    'userId',
    'agentUserId',
    'taskId',
    'rtcToken',
    'actionStreamUrl',
    'createdAt',
    if (authority != null) ...<String>{'leaseEpoch', 'rtcGeneration'},
  };
  _requireExactKeys(data, expectedKeys, 'realtime session data');

  final sessionId = _opaqueId(
    _requiredString(data, 'sessionId'),
    'sessionId',
    minimumLength: 8,
  );
  final leaseEpoch = data['leaseEpoch'] == null
      ? 0
      : _positiveJsonInteger(data['leaseEpoch'], 'leaseEpoch');
  final rtcGeneration = data['rtcGeneration'] == null
      ? 0
      : _positiveJsonInteger(data['rtcGeneration'], 'rtcGeneration');
  if (authority == null) {
    if (leaseEpoch != 0 || rtcGeneration != 0) {
      throw const FormatException(
        'legacy realtime response unexpectedly contains authority metadata',
      );
    }
  } else if (leaseEpoch != authority.leaseEpoch) {
    throw const FormatException('realtime response lease epoch mismatch');
  }

  final expectedPath =
      '/v1/realtime/sessions/${Uri.encodeComponent(sessionId)}/actions';
  final rawActionStream = _requiredString(data, 'actionStreamUrl');
  final suppliedActionStream = Uri.tryParse(rawActionStream);
  if (suppliedActionStream == null ||
      rawActionStream.startsWith('//') ||
      (!suppliedActionStream.isAbsolute && !rawActionStream.startsWith('/'))) {
    throw const FormatException('realtime action stream URL is invalid');
  }
  final actionStreamUri = suppliedActionStream.isAbsolute
      ? suppliedActionStream
      : configuredBaseUri.resolveUri(suppliedActionStream);
  requireRealtimeSameOriginEndpoint(
    configuredBaseUri: configuredBaseUri,
    destination: actionStreamUri,
    expectedPath: expectedPath,
  );
  final createdAtText = _requiredString(data, 'createdAt');
  final createdAt = DateTime.tryParse(createdAtText)?.toUtc();
  if (createdAt == null) {
    throw const FormatException('realtime session createdAt is invalid');
  }
  return RealtimeSession(
    sessionId: sessionId,
    locale: _requiredString(data, 'locale'),
    rtcAppId: _requiredString(data, 'rtcAppId'),
    roomId: _requiredString(data, 'roomId'),
    userId: _requiredString(data, 'userId'),
    agentUserId: _requiredString(data, 'agentUserId'),
    taskId: _requiredString(data, 'taskId'),
    rtcToken: _requiredString(data, 'rtcToken'),
    actionStreamUri: actionStreamUri,
    createdAt: createdAt,
    leaseEpoch: leaseEpoch,
    rtcGeneration: rtcGeneration,
  );
}

Uri requireRealtimeHttpsBaseUri(Uri uri) {
  if (!uri.isAbsolute ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw StateError('Maaso realtime base URL must be a root HTTPS origin');
  }
  return uri.replace(
    scheme: 'https',
    host: uri.host.toLowerCase(),
    path: '/',
    query: null,
    fragment: null,
  );
}

Uri requireRealtimeSameOriginEndpoint({
  required Uri configuredBaseUri,
  required Uri destination,
  required String expectedPath,
}) {
  final base = requireRealtimeHttpsBaseUri(configuredBaseUri);
  if (!destination.isAbsolute ||
      destination.scheme.toLowerCase() != 'https' ||
      destination.host.isEmpty ||
      destination.userInfo.isNotEmpty ||
      destination.hasQuery ||
      destination.hasFragment ||
      destination.path != expectedPath ||
      destination.host.toLowerCase() != base.host.toLowerCase() ||
      _effectiveHttpsPort(destination) != _effectiveHttpsPort(base)) {
    throw StateError(
      'Realtime endpoint is outside the configured HTTPS origin',
    );
  }
  return destination;
}

Future<Uint8List> readBoundedRealtimeResponse(
  http.StreamedResponse response, {
  required int maximumBytes,
  required Duration timeout,
}) async {
  final output = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response.stream.timeout(timeout)) {
    length += chunk.length;
    if (length > maximumBytes) {
      throw const FormatException('realtime backend response is too large');
    }
    output.add(chunk);
  }
  return output.takeBytes();
}

RealtimeBackendException realtimeBackendException(
  http.StreamedResponse response,
  Uint8List responseBytes,
) {
  var code = 'HTTP_${response.statusCode}';
  try {
    final envelope = _jsonObject(responseBytes, 'realtime error envelope');
    final rawCode = envelope['code'];
    if (rawCode is String && _realtimeBackendErrorCodes.contains(rawCode)) {
      code = rawCode;
    }
  } catch (_) {
    // Keep the stable status-derived code. Never retain or reflect the body.
  }
  Duration? retryAfter;
  final rawRetry = response.headers['retry-after']?.trim();
  final seconds = rawRetry == null ? null : int.tryParse(rawRetry);
  if (seconds != null && seconds >= 0 && seconds <= 300) {
    retryAfter = Duration(seconds: seconds);
  }
  return RealtimeBackendException(
    statusCode: response.statusCode,
    code: code,
    retryAfter: retryAfter,
  );
}

Map<String, Object?> _jsonObject(Uint8List bytes, String label) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
  } catch (_) {
    throw FormatException('$label is invalid JSON');
  }
  if (decoded is! Map) throw FormatException('$label is not an object');
  return Map<String, Object?>.from(decoded);
}

void _requireExactKeys(
  Map<String, Object?> value,
  Set<String> expected,
  String label,
) {
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw FormatException('$label fields are invalid');
  }
}

String _requiredString(Map<String, Object?> value, String field) {
  final raw = value[field];
  if (raw is! String || raw.isEmpty || raw != raw.trim() || raw.length > 4096) {
    throw FormatException('realtime session $field is invalid');
  }
  return raw;
}

String _opaqueId(String value, String field, {int minimumLength = 1}) {
  final normalized = value.trim();
  if (normalized != value ||
      normalized.length < minimumLength ||
      normalized.length > 64 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(normalized)) {
    throw FormatException('realtime $field is invalid');
  }
  return normalized;
}

String _requestId(String value) {
  final normalized = value.trim();
  if (normalized != value ||
      normalized.length < 8 ||
      normalized.length > 96 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(normalized)) {
    throw const FormatException('realtime requestId is invalid');
  }
  return normalized;
}

int _positiveJsonInteger(Object? value, String field) {
  if (value is! int || value <= 0 || value > maxRealtimeJsonInteger) {
    throw FormatException('realtime session $field is invalid');
  }
  return value;
}

int _cursor(int value, String field) {
  if (value < 0 || value > maxRealtimeJsonInteger) {
    throw ArgumentError.value(value, field, 'must be a JSON-safe cursor');
  }
  return value;
}

int _effectiveHttpsPort(Uri uri) => uri.hasPort ? uri.port : 443;

String _resolvedLocaleTag([AppLocale? locale]) =>
    (locale ??
            appServices.maybeFind<LocaleConfigService>()?.resolvedAppLocale ??
            AppLocale.en)
        .code;
