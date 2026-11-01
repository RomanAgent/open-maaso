import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../domain/project_build_contract.dart';

class ProjectBuildRequestException extends StateError {
  ProjectBuildRequestException(this.statusCode, this.code) : super(code);
  final int statusCode;
  final String code;
  bool get ambiguous =>
      statusCode == 0 || statusCode >= 500 || statusCode == 408;
}

/// Account-owned control-plane client used by ProjectBuildTasks. It cannot
/// invoke a generation provider or the legacy image API.
final class HttpProjectBuildGateway {
  HttpProjectBuildGateway({
    required Uri Function() baseUri,
    required String Function() contextKey,
    required Future<String> Function() accessToken,
    required bool Function() isCurrent,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _baseUri = baseUri,
       _contextKey = contextKey,
       _accessToken = accessToken,
       _isCurrent = isCurrent,
       _http = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri Function() _baseUri;
  final String Function() _contextKey;
  final Future<String> Function() _accessToken;
  final bool Function() _isCurrent;
  final http.Client _http;
  final bool _ownsClient;
  final Duration timeout;
  final Set<Future<Object?>> _pending = {};
  final _cancellations = StreamController<void>.broadcast(sync: true);
  bool _sealed = false;
  int _generation = 0;

  Future<ProjectBuildReceipt> create({
    required ProjectBuildCreateRequest request,
    required String expectedContextKey,
  }) async {
    final data = await _request(
      'POST',
      'v1/project-builds',
      expectedContextKey,
      body: request.toJson(),
    );
    return _decode(() {
      final receipt = ProjectBuildReceipt.fromJson(data);
      if (receipt.requestId != request.requestId || receipt.attempt != 1) {
        throw const FormatException('project_build_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildReceipt> command({
    required String taskId,
    required ProjectBuildCommand command,
    required String expectedContextKey,
  }) async {
    projectBuildId(taskId, 'task');
    final data = await _request(
      'POST',
      'v1/project-builds/$taskId/${command.operation.name}',
      expectedContextKey,
      body: command.toJson(),
    );
    return _decode(() {
      final receipt = ProjectBuildReceipt.fromJson(data);
      if (receipt.requestId != command.requestId ||
          receipt.taskId != taskId ||
          (command.operation == ProjectBuildOperation.cancel &&
              receipt.runId != command.expectedRunId) ||
          (command.operation == ProjectBuildOperation.retry &&
              receipt.runId == command.expectedRunId)) {
        throw const FormatException('project_build_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildSnapshot> snapshot({
    required String taskId,
    required String expectedContextKey,
  }) async {
    projectBuildId(taskId, 'task');
    final data = await _request(
      'GET',
      'v1/project-builds/$taskId',
      expectedContextKey,
    );
    return _decode(() {
      final snapshot = ProjectBuildSnapshot.fromJson(data);
      if (snapshot.taskId != taskId) {
        throw const FormatException('project_build_snapshot_identity');
      }
      return snapshot;
    });
  }

  Future<ProjectBuildEventPage> events({
    required String taskId,
    required int afterTaskSequence,
    required String expectedContextKey,
    int limit = 100,
  }) async {
    projectBuildId(taskId, 'task');
    if (afterTaskSequence < 0 ||
        afterTaskSequence > projectBuildMaximumSequence ||
        limit < 1 ||
        limit > projectBuildMaximumPageSize) {
      throw const FormatException('invalid_project_build_cursor');
    }
    final data = await _request(
      'GET',
      'v1/project-builds/$taskId/events',
      expectedContextKey,
      query: {'afterTaskSequence': '$afterTaskSequence', 'limit': '$limit'},
    );
    return _decode(
      () => ProjectBuildEventPage.fromJson(
        data,
        taskId: taskId,
        afterTaskSequence: afterTaskSequence,
      ),
    );
  }

  T _decode<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      throw ProjectBuildRequestException(502, 'invalid_project_build_response');
    }
  }

  void _guard(String expected, int generation) {
    if (_sealed ||
        generation != _generation ||
        !_isCurrent() ||
        expected.isEmpty ||
        _contextKey() != expected) {
      throw ProjectBuildRequestException(0, 'project_build_scope_changed');
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
    final origin = _baseUri();
    final clock = Stopwatch()..start();
    late Future<Map<String, Object?>> operation;
    operation =
        () async {
          try {
            _guard(expected, generation);
            final token = await _awaitBounded(_accessToken, clock);
            _guard(expected, generation);
            if (origin != _baseUri()) {
              throw ProjectBuildRequestException(
                0,
                'project_build_scope_changed',
              );
            }
            if (token.isEmpty) {
              throw ProjectBuildRequestException(401, 'unauthorized');
            }
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
            final response = await _awaitBounded(
              () => _http.send(request),
              clock,
            );
            _guard(expected, generation);
            final raw = await _read(response.stream, clock);
            _guard(expected, generation);
            if (origin != _baseUri()) {
              throw ProjectBuildRequestException(
                0,
                'project_build_scope_changed',
              );
            }
            final envelope = projectBuildObject(jsonDecode(utf8.decode(raw)));
            if (response.statusCode < 200 || response.statusCode >= 300) {
              final code = envelope['code'];
              throw ProjectBuildRequestException(
                response.statusCode,
                code is String && code.length <= 64
                    ? code
                    : 'project_build_request_failed',
              );
            }
            if (envelope.length != 4 ||
                envelope['code'] != 'OK' ||
                envelope['message'] is! String ||
                envelope['traceId'] is! String ||
                (envelope['traceId']! as String).isEmpty ||
                envelope['data'] is! Map) {
              throw const FormatException('invalid_project_build_envelope');
            }
            return projectBuildObject(envelope['data']);
          } on TimeoutException {
            throw ProjectBuildRequestException(
              0,
              'project_build_request_timeout',
            );
          } on http.ClientException {
            throw ProjectBuildRequestException(
              0,
              'project_build_network_error',
            );
          } on FormatException {
            throw ProjectBuildRequestException(
              502,
              'invalid_project_build_response',
            );
          }
        }().whenComplete(() {
          clock.stop();
          _pending.remove(operation);
        });
    _pending.add(operation);
    return operation;
  }

  /// One monotonic deadline covers token, response headers and body. Local
  /// retirement cancels the wait even if the token provider never completes.
  Future<T> _awaitBounded<T>(Future<T> Function() work, Stopwatch clock) async {
    if (_sealed) {
      throw ProjectBuildRequestException(0, 'project_build_scope_changed');
    }
    if (clock.elapsed >= timeout) {
      throw TimeoutException('project_build_deadline');
    }
    final result = Completer<T>();
    void fail(Object error, [StackTrace? stack]) {
      if (!result.isCompleted) result.completeError(error, stack);
    }

    final remaining = timeout - clock.elapsed;
    final timer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () => fail(TimeoutException('project_build_deadline')),
    );
    final cancellation = _cancellations.stream.listen(
      (_) =>
          fail(ProjectBuildRequestException(0, 'project_build_scope_changed')),
    );
    Future<T>.sync(work).then((value) {
      if (clock.elapsed >= timeout) {
        fail(TimeoutException('project_build_deadline'));
      } else if (!result.isCompleted) {
        result.complete(value);
      }
    }, onError: (Object error, StackTrace stack) => fail(error, stack));
    if (_sealed) {
      fail(ProjectBuildRequestException(0, 'project_build_scope_changed'));
    }
    try {
      return await result.future;
    } finally {
      timer.cancel();
      await cancellation.cancel();
    }
  }

  Future<Uint8List> _read(Stream<List<int>> stream, Stopwatch clock) async {
    final done = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    final subscription = stream.listen(
      (chunk) {
        if (done.isCompleted) return;
        length += chunk.length;
        if (length > 1024 * 1024) {
          done.completeError(
            ProjectBuildRequestException(
              502,
              'project_build_response_too_large',
            ),
          );
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
    );
    try {
      return await _awaitBounded(() => done.future, clock);
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> deactivateAndDrain() async {
    if (!_sealed) {
      _sealed = true;
      _generation++;
      _cancellations.add(null);
      if (_ownsClient) _http.close();
    }
    await Future.wait(
      _pending.toList().map(
        (work) => work.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    await _cancellations.close();
  }
}
