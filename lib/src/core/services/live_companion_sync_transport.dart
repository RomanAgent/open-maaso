import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/models/runtime_chat.dart';
import 'account_device_lease_transport.dart';
import 'app_environment_service.dart';

abstract interface class LiveCompanionSyncGateway {
  Future<Map<String, Object?>> request(
    String operation,
    Map<String, Object?> body,
  );
  void close();
}

final class LiveCompanionSyncException implements Exception {
  const LiveCompanionSyncException(this.code);
  final String code;
}

/// Independent, bounded authenticated requests. No media URLs or credentials
/// are accepted from the message body, and redirects are never followed.
final class LiveCompanionSyncTransport implements LiveCompanionSyncGateway {
  LiveCompanionSyncTransport({
    required this.environment,
    required this.accountUuid,
    required this.accessToken,
    required this.isCurrent,
    http.Client? client,
  }) : _client = client ?? http.Client();
  final MaasoEnvironment environment;
  final String accountUuid;
  final AccountDeviceLeaseAccessTokenProvider accessToken;
  final bool Function() isCurrent;
  final http.Client _client;
  bool _closed = false;
  void _check() {
    if (_closed || !isCurrent()) {
      throw const LiveCompanionSyncException('ACCOUNT_UNAVAILABLE');
    }
  }

  @override
  Future<Map<String, Object?>> request(
    String operation,
    Map<String, Object?> body,
  ) async {
    _check();
    if (!const {'poll', 'publish', 'close'}.contains(operation)) {
      throw const FormatException('invalid_live_operation');
    }
    final token = await accessToken(environment, accountUuid);
    _check();
    if (token == null || token.isEmpty) {
      throw const LiveCompanionSyncException('AUTHENTICATION_REQUIRED');
    }
    final encoded = utf8.encode(jsonEncode(body));
    if (encoded.length > 514 * 1024) {
      throw const FormatException('live_request_too_large');
    }
    final req =
        http.Request(
            'POST',
            Uri.parse(
              '${environment.baseUrl}/v1/companion/live-sync/$operation',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Cache-Control': 'no-store',
          })
          ..bodyBytes = encoded;
    final response = await _client
        .send(req)
        .timeout(const Duration(seconds: 18));
    _check();
    final output = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 18),
    )) {
      _check();
      if (output.length + chunk.length > 1152 * 1024) {
        throw const FormatException('live_response_too_large');
      }
      output.addAll(chunk);
    }
    _check();
    final raw = jsonDecode(utf8.decode(output));
    if (raw is! Map) throw const FormatException('invalid_live_response');
    if (response.statusCode != 200 || raw['code'] != 'OK') {
      throw LiveCompanionSyncException(
        raw['code'] is String ? raw['code'] as String : 'LIVE_SYNC_UNAVAILABLE',
      );
    }
    if (raw['data'] is! Map) {
      throw const FormatException('invalid_live_response');
    }
    return Map<String, Object?>.from(raw['data'] as Map);
  }

  @override
  void close() {
    _closed = true;
    _client.close();
  }
}

final class LiveCompanionPeer {
  const LiveCompanionPeer({
    required this.presenceSessionId,
    required this.installationId,
    required this.runtimeInstanceId,
    required this.canShareReviewedMemory,
  });
  final String presenceSessionId, installationId, runtimeInstanceId;
  final bool canShareReviewedMemory;
  factory LiveCompanionPeer.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 4 ||
        value['canShareReviewedMemory'] is! bool) {
      throw const FormatException('invalid_live_peer');
    }
    return LiveCompanionPeer(
      presenceSessionId: runtimeChatIdentifier(
        value['presenceSessionId'] as String,
      ),
      installationId: runtimeChatIdentifier(value['installationId'] as String),
      runtimeInstanceId: runtimeChatIdentifier(
        value['runtimeInstanceId'] as String,
      ),
      canShareReviewedMemory: value['canShareReviewedMemory'] as bool,
    );
  }
}

final class LiveCompanionEvent {
  const LiveCompanionEvent({
    required this.eventId,
    required this.sourcePresenceSessionId,
    required this.sourceInstallationId,
    required this.kind,
    required this.payload,
  });
  final String eventId, sourcePresenceSessionId, sourceInstallationId, kind;
  final Map<String, Object?> payload;
  factory LiveCompanionEvent.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 5 ||
        value['payload'] is! Map ||
        !const {
          'chat_message',
          'media_chunk',
          'memory_entry',
          'memory_delete',
        }.contains(value['kind'])) {
      throw const FormatException('invalid_live_event');
    }
    final payload = Map<String, Object?>.from(value['payload'] as Map);
    if (utf8.encode(jsonEncode(payload)).length > 512 * 1024) {
      throw const FormatException('live_event_too_large');
    }
    return LiveCompanionEvent(
      eventId: runtimeChatIdentifier(value['eventId'] as String),
      sourcePresenceSessionId: runtimeChatIdentifier(
        value['sourcePresenceSessionId'] as String,
      ),
      sourceInstallationId: runtimeChatIdentifier(
        value['sourceInstallationId'] as String,
      ),
      kind: value['kind'] as String,
      payload: payload,
    );
  }
}
