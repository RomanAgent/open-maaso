import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/network/backend_client.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';
import 'package:uuid/uuid.dart';

final class GamePerceptionResult {
  const GamePerceptionResult({
    required this.description,
    required this.modelId,
    required this.sourceMediaId,
  });
  final String description;
  final String modelId;
  final String sourceMediaId;
}

final class GamePerceptionException implements Exception {
  const GamePerceptionException(this.code, {this.retryAfter, this.statusCode});
  final String code;
  final Duration? retryAfter;
  final int? statusCode;
  @override
  String toString() => 'GamePerceptionException($code)';
}

/// One bounded ephemeral frame per request. Membership is decided by the
/// server. Local spacing is a performance safeguard, not a usage allowance.
/// No retries, attachment writes, arbitrary URLs or other media endpoints.
class GamePerceptionGateway extends AppService {
  GamePerceptionGateway({
    required Uri baseUri,
    required Future<String> Function() accessToken,
    required Future<void> Function() authorize,
    required bool Function() isCurrent,
    http.Client? client,
    DateTime Function()? now,
    this.minimumDispatchInterval = const Duration(seconds: 3),
  }) : _baseUri = baseUri,
       _accessToken = accessToken,
       _authorize = authorize,
       _isCurrent = isCurrent,
       _client = client ?? createMaasoBackendClient(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now {
    if (minimumDispatchInterval < Duration.zero) {
      throw ArgumentError('game_perception_schedule');
    }
    if (baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        (baseUri.scheme != 'https' &&
            !(baseUri.scheme == 'http' &&
                const ['127.0.0.1', 'localhost'].contains(baseUri.host)))) {
      throw ArgumentError('game_perception_base_uri');
    }
  }

  final Uri _baseUri;
  final Future<String> Function() _accessToken;
  final Future<void> Function() _authorize;
  final bool Function() _isCurrent;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Duration minimumDispatchInterval;
  DateTime? _lastDispatchAt;
  final Set<_GamePerceptionRequest> _requests = {};
  bool _retired = false;
  Future<void>? _shutdown;

  Future<GamePerceptionResult> analyze({
    required ProcessedGameFrame frame,
    required String question,
    required String locale,
    required Future<void> cancelled,
    required bool Function() requestIsCurrent,
    Duration deadline = const Duration(seconds: 8),
  }) {
    if (deadline <= Duration.zero || deadline > const Duration(minutes: 2)) {
      return Future.error(ArgumentError('game_perception_deadline'));
    }
    final request = _GamePerceptionRequest();
    if (_retired) {
      return Future.error(
        const GamePerceptionException('GAME_PERCEPTION_CANCELLED'),
      );
    }
    if (_requests.isNotEmpty) {
      return Future.error(
        const GamePerceptionException(
          'GAME_PERCEPTION_BUSY',
          retryAfter: Duration(seconds: 1),
        ),
      );
    }
    _requests.add(request);
    request.timer = Timer(deadline, () {
      request.abort('GAME_PERCEPTION_TIMEOUT');
    });
    cancelled.then<void>(
      (_) => request.abort('GAME_PERCEPTION_CANCELLED'),
      onError: (Object _, StackTrace _) =>
          request.abort('GAME_PERCEPTION_CANCELLED'),
    );
    final operation =
        _analyze(
          request,
          frame,
          question,
          locale,
          requestIsCurrent,
        ).whenComplete(() {
          request.timer?.cancel();
          request.finished = true;
          _requests.remove(request);
        });
    request.done = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _requireCurrent(
    _GamePerceptionRequest request,
    bool Function() current,
  ) {
    if (_retired || !_isCurrent() || !current()) {
      request.abort('GAME_PERCEPTION_CANCELLED');
    }
    final reason = request.reason;
    if (reason != null) throw GamePerceptionException(reason);
  }

  Future<T> _admit<T>(Future<T> value, _GamePerceptionRequest request) =>
      Future.any<T>([
        value,
        request.abortSignal.future.then<T>(
          (_) => throw GamePerceptionException(request.reason!),
        ),
      ]);

  Future<GamePerceptionResult> _analyze(
    _GamePerceptionRequest request,
    ProcessedGameFrame frame,
    String question,
    String locale,
    bool Function() current,
  ) async {
    try {
      // Let an already-completed revocation close admission before permission or
      // token callbacks start. Both are rechecked before the actual HTTP send.
      await Future<void>.value();
      _requireCurrent(request, current);
      if (frame.jpegBytes.isEmpty ||
          frame.jpegBytes.length > gameFrameMaximumBytes ||
          frame.width < 1 ||
          frame.height < 1 ||
          frame.width > gameFrameMaximumEdge ||
          frame.height > gameFrameMaximumEdge ||
          sha256.convert(frame.jpegBytes).toString() != frame.contentHash ||
          question.runes.length > 4000 ||
          utf8.encode(locale).length > 64) {
        throw const GamePerceptionException('GAME_PERCEPTION_INVALID');
      }
      await _admit(_authorize(), request);
      _requireCurrent(request, current);
      final token = await _admit(_accessToken(), request);
      _requireCurrent(request, current);
      if (token.trim().isEmpty) {
        throw const GamePerceptionException('AUTHENTICATION_REQUIRED');
      }
      final transport = http.AbortableRequest(
        'POST',
        _baseUri.resolve('v1/proxy/game-perception/analyze'),
        abortTrigger: request.abortSignal.future,
      )..followRedirects = false;
      transport.headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      });
      transport.body = jsonEncode({
        'requestId': const Uuid().v4(),
        'question': question,
        'locale': locale,
        'media': [
          {
            'id': frame.contentHash,
            'mime': 'image/jpeg',
            'durationMs': 0,
            'data': base64Encode(frame.jpegBytes),
          },
        ],
      });
      _requireCurrent(request, current);
      // Await physical send/stream termination after abort. A logical race must
      // not let the next frame hide a still-active transport behind a timeout.
      _reserveDispatch();
      final response = await _client.send(transport);
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        _requireCurrent(request, current);
        if (bytes.length + chunk.length > 32768) {
          request.abort('GAME_PERCEPTION_INVALID_RESPONSE');
          throw const GamePerceptionException(
            'GAME_PERCEPTION_INVALID_RESPONSE',
          );
        }
        bytes.addAll(chunk);
      }
      _requireCurrent(request, current);
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const GamePerceptionException('GAME_PERCEPTION_INVALID_RESPONSE');
      }
      if (response.statusCode != 200 ||
          decoded is! Map ||
          decoded['code'] != 'OK') {
        final rawCode = decoded is Map ? decoded['code'] : null;
        final code =
            rawCode is String &&
                RegExp(r'^[A-Z][A-Z0-9_]{1,63}$').hasMatch(rawCode)
            ? rawCode
            : 'GAME_PERCEPTION_UNAVAILABLE';
        final retry = int.tryParse(response.headers['retry-after'] ?? '');
        throw GamePerceptionException(
          code,
          statusCode: response.statusCode,
          retryAfter: retry != null && retry > 0
              ? Duration(seconds: retry.clamp(1, 86400))
              : null,
        );
      }
      final data = decoded['data'];
      if (data is! Map ||
          data['description'] is! String ||
          (data['description'] as String).trim().isEmpty ||
          (data['description'] as String).runes.length > 4000 ||
          data['modelId'] is! String ||
          (data['modelId'] as String).isEmpty ||
          (data['modelId'] as String).length > 128 ||
          data['sourceMediaIds'] is! List ||
          (data['sourceMediaIds'] as List).length != 1 ||
          (data['sourceMediaIds'] as List).single != frame.contentHash) {
        throw const GamePerceptionException('GAME_PERCEPTION_INVALID_RESPONSE');
      }
      return GamePerceptionResult(
        description: (data['description'] as String).trim(),
        modelId: data['modelId'] as String,
        sourceMediaId: frame.contentHash,
      );
    } on GamePerceptionException {
      rethrow;
    } on PrivacyException catch (error) {
      throw GamePerceptionException(error.code);
    } on Object {
      throw GamePerceptionException(
        request.reason ?? 'GAME_PERCEPTION_UNAVAILABLE',
      );
    }
  }

  void _reserveDispatch() {
    final now = _now();
    final last = _lastDispatchAt;
    final remaining = last?.add(minimumDispatchInterval).difference(now);
    if (remaining != null && remaining > Duration.zero) {
      throw GamePerceptionException(
        'GAME_PERCEPTION_BUSY',
        retryAfter: remaining,
      );
    }
    // Retain only the most recent dispatch timestamp, including refusals and
    // uncertain transports. There is no count/byte window, credit or refund.
    _lastDispatchAt = now;
  }

  Future<void> shutdown() => _shutdown ??= _shutdownRequests();

  Future<void> _shutdownRequests() async {
    _retired = true;
    final pending = _requests.toList(growable: false);
    for (final request in pending) {
      request.abort('GAME_PERCEPTION_CANCELLED');
    }
    if (_ownsClient) _client.close();
    await Future.wait(pending.map((request) => request.done));
  }

  @override
  void onClose() {
    unawaited(shutdown());
    super.onClose();
  }
}

final class _GamePerceptionRequest {
  final Completer<void> abortSignal = Completer<void>();
  String? reason;
  Timer? timer;
  bool finished = false;
  Future<void> done = Future<void>.value();
  void abort(String code) {
    if (finished || abortSignal.isCompleted) return;
    reason = code;
    abortSignal.complete();
  }
}
