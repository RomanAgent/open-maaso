import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';

class CreatorTaskRequestException extends StateError {
  CreatorTaskRequestException(this.statusCode, this.code) : super(code);
  final int statusCode;
  final String code;
  bool get ambiguous =>
      statusCode == 0 || statusCode >= 500 || statusCode == 408;
}

final class CreatorTaskResult {
  const CreatorTaskResult({required this.artifact, required this.assetUrl});
  final CreatorTaskArtifact artifact;
  final Uri assetUrl;
}

abstract interface class CreatorTaskGateway {
  bool get isAvailable;
  String get requestContextKey;
  Future<CreatorTaskReceipt> create({
    required String requestId,
    required String agentId,
    required CreatorTaskImageInput input,
    required String expectedContextKey,
  });
  Future<CreatorTaskReceipt> command({
    required String taskId,
    required CreatorTaskCommand command,
    required String expectedContextKey,
  });
  Future<CreatorTaskSnapshot> snapshot({
    required String taskId,
    required String expectedContextKey,
  });
  Future<CreatorTaskEventPage> events({
    required String taskId,
    required String agentId,
    required int afterSequence,
    required String expectedContextKey,
  });
  Future<CreatorTaskResult> result({
    required String taskId,
    required String expectedContextKey,
  });
  Future<void> deactivateAndDrain();
}

class HttpCreatorTaskGateway extends AppService implements CreatorTaskGateway {
  HttpCreatorTaskGateway({
    required Uri Function() baseUri,
    required String Function() contextKey,
    required Future<String> Function() accessToken,
    required bool Function() isCurrent,
    required bool available,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _baseUri = baseUri,
       _contextKey = contextKey,
       _accessToken = accessToken,
       _isCurrent = isCurrent,
       _available = available,
       _http = client ?? http.Client(),
       _ownsClient = client == null;
  final Uri Function() _baseUri;
  final String Function() _contextKey;
  final Future<String> Function() _accessToken;
  final bool Function() _isCurrent;
  final bool _available;
  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;
  final Set<Future<Object?>> _pending = {};
  bool _sealed = false;
  int _generation = 0;
  @override
  bool get isAvailable => _available && !_sealed;
  @override
  String get requestContextKey => _contextKey();

  @override
  Future<CreatorTaskReceipt> create({
    required String requestId,
    required String agentId,
    required CreatorTaskImageInput input,
    required String expectedContextKey,
  }) async {
    // Recovery replays the same persisted nonce even if new admission is off.
    final data = await _request(
      'POST',
      'v1/tasks',
      expectedContextKey,
      body: {
        'requestId': requestId,
        'agentId': agentId,
        'kind': 'creator_image',
        'image': input.toJson(),
      },
    );
    return _decode(() => CreatorTaskReceipt.fromJson(data));
  }

  @override
  Future<CreatorTaskReceipt> command({
    required String taskId,
    required CreatorTaskCommand command,
    required String expectedContextKey,
  }) async {
    _taskId(taskId);
    if (command.operation == CreatorTaskOperation.create) {
      throw CreatorTaskRequestException(0, 'invalid_task_command');
    }
    final data = await _request(
      'POST',
      'v1/tasks/$taskId/${command.operation.name}',
      expectedContextKey,
      body: {
        'requestId': command.requestId,
        'expectedAttemptId': command.expectedAttemptId,
      },
    );
    return _decode(() => CreatorTaskReceipt.fromJson(data));
  }

  @override
  Future<CreatorTaskSnapshot> snapshot({
    required String taskId,
    required String expectedContextKey,
  }) async {
    _taskId(taskId);
    final data = await _request('GET', 'v1/tasks/$taskId', expectedContextKey);
    return _decode(() => CreatorTaskSnapshot.fromJson(data));
  }

  @override
  Future<CreatorTaskEventPage> events({
    required String taskId,
    required String agentId,
    required int afterSequence,
    required String expectedContextKey,
  }) async {
    _taskId(taskId);
    if (afterSequence < 0 || afterSequence > creatorTaskMaximumSequence) {
      throw CreatorTaskRequestException(0, 'invalid_task_cursor');
    }
    final data = await _request(
      'GET',
      'v1/tasks/$taskId/events',
      expectedContextKey,
      query: {'afterSequence': '$afterSequence', 'limit': '100'},
    );
    return _decode(
      () => CreatorTaskEventPage.fromJson(
        data,
        taskId: taskId,
        agentId: agentId,
        afterSequence: afterSequence,
      ),
    );
  }

  @override
  Future<CreatorTaskResult> result({
    required String taskId,
    required String expectedContextKey,
  }) async {
    _taskId(taskId);
    final data = await _request(
      'GET',
      'v1/tasks/$taskId/result',
      expectedContextKey,
    );
    return _decode(() {
      if (data.length != 2 ||
          data['artifact'] is! Map ||
          data['assetUrl'] is! String) {
        throw const FormatException('invalid_task_result');
      }
      final raw = data['assetUrl']! as String;
      final uri = Uri.parse(raw);
      if (raw.length > 4096 ||
          uri.scheme != 'https' ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.host.isEmpty) {
        throw const FormatException('invalid_task_result_url');
      }
      return CreatorTaskResult(
        artifact: CreatorTaskArtifact.fromJson(
          creatorTaskMap(data['artifact']),
        ),
        assetUrl: uri,
      );
    });
  }

  T _decode<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      throw CreatorTaskRequestException(502, 'invalid_task_response');
    }
  }

  void _taskId(String id) {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ).hasMatch(id)) {
      throw CreatorTaskRequestException(0, 'invalid_task_id');
    }
  }

  void _guard(String expected, int generation) {
    if (_sealed ||
        generation != _generation ||
        !_isCurrent() ||
        expected.isEmpty ||
        _contextKey() != expected) {
      throw CreatorTaskRequestException(0, 'task_scope_changed');
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    String route,
    String expected, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) {
    final generation = _generation;
    late Future<Map<String, Object?>> operation;
    operation = () async {
      _guard(expected, generation);
      final token = await _accessToken();
      _guard(expected, generation);
      if (token.isEmpty) throw CreatorTaskRequestException(401, 'unauthorized');
      final origin = _baseUri();
      var uri = origin.resolve(route);
      if (query != null) uri = uri.replace(queryParameters: query);
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll({
          'authorization': 'Bearer $token',
          'accept': 'application/json',
        });
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      try {
        final response = await _http.send(request).timeout(timeout);
        _guard(expected, generation);
        final raw = await _read(response.stream);
        _guard(expected, generation);
        if (origin != _baseUri()) {
          throw CreatorTaskRequestException(0, 'task_scope_changed');
        }
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(raw));
        } catch (_) {
          throw CreatorTaskRequestException(502, 'invalid_task_response');
        }
        final envelope = creatorTaskMap(decoded);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final code = envelope['code'];
          throw CreatorTaskRequestException(
            response.statusCode,
            code is String && code.length <= 64 ? code : 'task_request_failed',
          );
        }
        if (envelope.length != 4 ||
            envelope['code'] != 'OK' ||
            envelope['message'] is! String ||
            envelope['traceId'] is! String ||
            (envelope['traceId']! as String).isEmpty ||
            envelope['data'] is! Map) {
          throw CreatorTaskRequestException(502, 'invalid_task_response');
        }
        return creatorTaskMap(envelope['data']);
      } on TimeoutException {
        throw CreatorTaskRequestException(0, 'task_request_timeout');
      } on http.ClientException {
        throw CreatorTaskRequestException(0, 'task_network_error');
      } on FormatException {
        throw CreatorTaskRequestException(502, 'invalid_task_response');
      }
    }().whenComplete(() => _pending.remove(operation));
    _pending.add(operation);
    return operation;
  }

  Future<Uint8List> _read(Stream<List<int>> stream) async {
    final done = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    StreamSubscription<List<int>>? subscription;
    void fail(Object error) {
      if (done.isCompleted) return;
      done.completeError(error);
      unawaited(subscription?.cancel());
    }

    final timer = Timer(
      timeout,
      () => fail(TimeoutException('task_response_timeout')),
    );
    subscription = stream.listen(
      (chunk) {
        length += chunk.length;
        if (length > 512 * 1024) {
          fail(CreatorTaskRequestException(502, 'task_response_too_large'));
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object error) => fail(error),
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
    );
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  @override
  Future<void> deactivateAndDrain() async {
    if (!_sealed) {
      _sealed = true;
      _generation++;
      if (_ownsClient) _http.close();
    }
    await Future.wait(
      _pending.toList().map(
        (work) => work.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  @override
  void onClose() {
    _sealed = true;
    _generation++;
    if (_ownsClient) _http.close();
    super.onClose();
  }
}
