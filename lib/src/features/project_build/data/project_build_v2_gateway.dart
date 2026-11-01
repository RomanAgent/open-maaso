import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../domain/project_build_v2_contract.dart';
import '../domain/project_json_canonicalizer.dart';
import '../domain/project_build_v2_inventory.dart';
import '../domain/project_build_v2_readiness.dart';
import '../domain/project_build_v2_delete.dart';
import '../domain/project_build_v2_head.dart';
import '../domain/project_build_v2_reference.dart';

class ProjectBuildV2RequestException extends StateError {
  ProjectBuildV2RequestException(this.statusCode, this.code) : super(code);
  final int statusCode;
  final String code;
  bool get ambiguous =>
      statusCode == 0 || statusCode >= 500 || statusCode == 408;
}

/// Account-owned control-plane client used by ProjectBuildV2Tasks. It cannot
/// invoke a generation provider or the legacy image API.
final class HttpProjectBuildV2Gateway {
  HttpProjectBuildV2Gateway({
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

  Future<ProjectBuildReferenceReceipt> uploadReference({
    required ProjectBuildReferenceUploadRequest request,
    required String expectedContextKey,
    bool Function()? canDispatch,
    required Future<void> Function() authorize,
  }) async {
    final data = await _request(
      'POST',
      'v1/project-builds/v2/references',
      expectedContextKey,
      body: request.toJson(),
      canDispatch: canDispatch,
      beforeDispatch: authorize,
    );
    return _decode(() {
      final receipt = ProjectBuildReferenceReceipt.fromJson(data);
      if (!receipt.matches(request)) {
        throw const FormatException('project_reference_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildV2Receipt> create({
    required ProjectBuildV2CreateRequest request,
    required String expectedContextKey,
    bool Function()? canDispatch,
    Future<void> Function()? authorize,
  }) async {
    final data = await _request(
      'POST',
      'v1/project-builds/v2',
      expectedContextKey,
      body: request.toJson(),
      canDispatch: canDispatch,
      beforeDispatch: authorize,
    );
    return _decode(() {
      final receipt = ProjectBuildV2Receipt.fromJson(data);
      if (receipt.requestId != request.requestId ||
          receipt.attempt != 1 ||
          receipt.savedRevision != null) {
        throw const FormatException('project_build_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildV2Receipt> command({
    required String taskId,
    required ProjectBuildV2Command command,
    required String expectedContextKey,
    bool Function()? canDispatch,
    Future<void> Function()? authorize,
  }) async {
    projectBuildV2Id(taskId, 'task');
    final data = await _request(
      'POST',
      'v1/project-builds/v2/$taskId/${command.operation.name}',
      expectedContextKey,
      body: command.toJson(),
      canDispatch: canDispatch,
      beforeDispatch: authorize,
    );
    return _decode(() {
      final receipt = ProjectBuildV2Receipt.fromJson(data);
      if (receipt.requestId != command.requestId ||
          receipt.taskId != taskId ||
          (command.operation == ProjectBuildV2Operation.cancel &&
              receipt.runId != command.expectedRunId) ||
          (command.operation == ProjectBuildV2Operation.retry &&
              receipt.runId == command.expectedRunId) ||
          (command.operation == ProjectBuildV2Operation.accept &&
              (receipt.runId != command.expectedRunId ||
                  receipt.savedRevision?.candidateDigest !=
                      command.candidateDigest ||
                  receipt.savedRevision?.headVersion !=
                      command.expectedHeadVersion! + 1)) ||
          (command.operation != ProjectBuildV2Operation.accept &&
              receipt.savedRevision != null)) {
        throw const FormatException('project_build_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildV2Snapshot> snapshot({
    required String taskId,
    required String expectedContextKey,
  }) async {
    projectBuildV2Id(taskId, 'task');
    final data = await _request(
      'GET',
      'v1/project-builds/v2/$taskId',
      expectedContextKey,
    );
    return _decode(() {
      final snapshot = ProjectBuildV2Snapshot.fromJson(data);
      if (snapshot.taskId != taskId) {
        throw const FormatException('project_build_snapshot_identity');
      }
      return snapshot;
    });
  }

  Future<ProjectBuildV2EventPage> events({
    required String taskId,
    required int afterTaskSequence,
    required String expectedContextKey,
    int limit = 100,
  }) async {
    projectBuildV2Id(taskId, 'task');
    if (afterTaskSequence < 0 ||
        afterTaskSequence > projectBuildV2MaximumSequence ||
        limit < 1 ||
        limit > projectBuildV2MaximumPageSize) {
      throw const FormatException('invalid_project_build_cursor');
    }
    final data = await _request(
      'GET',
      'v1/project-builds/v2/$taskId/events',
      expectedContextKey,
      query: {'afterTaskSequence': '$afterTaskSequence', 'limit': '$limit'},
      maximumBytes: 4 * 1024 * 1024,
    );
    return _decode(
      () => ProjectBuildV2EventPage.fromJson(
        data,
        taskId: taskId,
        afterTaskSequence: afterTaskSequence,
      ),
    );
  }

  Future<ProjectBuildV2Candidate> candidate({
    required String taskId,
    required String expectedContextKey,
  }) async {
    projectBuildV2Id(taskId, 'task');
    final data = await _request(
      'GET',
      'v1/project-builds/v2/$taskId/candidate',
      expectedContextKey,
      maximumBytes: 37 * 1024 * 1024,
    );
    return _decode(() {
      final candidate = ProjectBuildV2Candidate.fromJson(data);
      if (candidate.taskId != taskId) {
        throw const FormatException('project_build_candidate_identity');
      }
      return candidate;
    });
  }

  Future<ProjectBuildV2DeleteReceipt> deleteProject({
    required String projectId,
    required ProjectBuildV2DeleteRequest request,
    required String expectedContextKey,
    bool Function()? canDispatch,
  }) async {
    projectBuildV2Id(projectId, 'project');
    final data = await _request(
      'POST',
      'v1/project-builds/v2/projects/$projectId/delete',
      expectedContextKey,
      body: request.toJson(),
      canDispatch: canDispatch,
    );
    return _decode(() {
      final receipt = ProjectBuildV2DeleteReceipt.fromJson(data);
      if (receipt.requestId != request.requestId ||
          receipt.projectId != projectId ||
          receipt.deletedRevisionId != request.expectedRevision ||
          receipt.headVersion != request.expectedHeadVersion + 1) {
        throw const FormatException('project_delete_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildV2RollbackReceipt> rollbackProject({
    required String projectId,
    required ProjectBuildV2RollbackRequest request,
    required String expectedContextKey,
    bool Function()? canDispatch,
  }) async {
    projectBuildV2Id(projectId, 'project');
    final data = await _request(
      'POST',
      'v1/project-builds/v2/projects/$projectId/rollback',
      expectedContextKey,
      body: request.toJson(),
      canDispatch: canDispatch,
    );
    return _decode(() {
      final receipt = ProjectBuildV2RollbackReceipt.fromJson(data);
      if (receipt.requestId != request.requestId ||
          receipt.projectId != projectId ||
          receipt.revisionId != request.targetRevision ||
          receipt.headVersion != request.expectedHeadVersion + 1) {
        throw const FormatException('project_rollback_receipt_identity');
      }
      return receipt;
    });
  }

  Future<ProjectBuildV2Readiness> readiness({
    required String expectedContextKey,
  }) async {
    final data = await _request(
      'GET',
      'v1/project-builds/v2/readiness',
      expectedContextKey,
    );
    return _decode(() => ProjectBuildV2Readiness.fromJson(data));
  }

  Future<ProjectBuildV2OwnedProjects> projects({
    required String expectedContextKey,
  }) async {
    final data = await _request(
      'GET',
      'v1/project-builds/v2/projects',
      expectedContextKey,
    );
    return _decode(() => ProjectBuildV2OwnedProjects.fromJson(data));
  }

  Future<ProjectBuildV2OwnedRevisions> revisions({
    required String projectId,
    required String expectedContextKey,
  }) async {
    projectBuildV2Id(projectId, 'project');
    final data = await _request(
      'GET',
      'v1/project-builds/v2/projects/$projectId/revisions',
      expectedContextKey,
    );
    return _decode(() {
      final result = ProjectBuildV2OwnedRevisions.fromJson(data);
      if (result.projectId != projectId) {
        throw const FormatException('project_build_inventory_identity');
      }
      return result;
    });
  }

  Future<ProjectBuildV2Candidate> revision({
    required String projectId,
    required String revisionId,
    required String expectedContextKey,
  }) async {
    projectBuildV2Id(projectId, 'project');
    projectBuildV2Id(revisionId, 'revision');
    final data = await _request(
      'GET',
      'v1/project-builds/v2/projects/$projectId/revisions/$revisionId',
      expectedContextKey,
      maximumBytes: 37 * 1024 * 1024,
    );
    return _decode(() {
      final result = ProjectBuildV2Candidate.fromJson(data);
      if (result.projectId != projectId ||
          result.reference.revisionId != revisionId) {
        throw const FormatException('project_build_inventory_identity');
      }
      return result;
    });
  }

  T _decode<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      throw ProjectBuildV2RequestException(
        502,
        'invalid_project_build_response',
      );
    }
  }

  void _guard(String expected, int generation) {
    if (_sealed ||
        generation != _generation ||
        !_isCurrent() ||
        expected.isEmpty ||
        _contextKey() != expected) {
      throw ProjectBuildV2RequestException(0, 'project_build_scope_changed');
    }
  }

  Future<Map<String, Object?>> _request(
    String method,
    String route,
    String expected, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    int maximumBytes = 1024 * 1024,
    bool Function()? canDispatch,
    Future<void> Function()? beforeDispatch,
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
              throw ProjectBuildV2RequestException(
                0,
                'project_build_scope_changed',
              );
            }
            if (token.isEmpty) {
              throw ProjectBuildV2RequestException(401, 'unauthorized');
            }
            if (beforeDispatch != null) {
              await _awaitBounded(beforeDispatch, clock);
              _guard(expected, generation);
              if (origin != _baseUri()) {
                throw ProjectBuildV2RequestException(
                  0,
                  'project_build_scope_changed',
                );
              }
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
            if (canDispatch != null && !canDispatch()) {
              throw ProjectBuildV2RequestException(
                0,
                'project_build_dispatch_revoked',
              );
            }
            final response = await _awaitBounded(
              () => _http.send(request),
              clock,
            );
            _guard(expected, generation);
            final raw = await _read(response.stream, clock, maximumBytes);
            _guard(expected, generation);
            if (origin != _baseUri()) {
              throw ProjectBuildV2RequestException(
                0,
                'project_build_scope_changed',
              );
            }
            final envelope = projectBuildV2Object(
              ProjectJsonCanonicalizer(
                maxBytes: maximumBytes,
                maxNodes: 500000,
              ).parseBytes(raw),
            );
            if (response.statusCode < 200 || response.statusCode >= 300) {
              final code = envelope['code'];
              throw ProjectBuildV2RequestException(
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
            return projectBuildV2Object(envelope['data']);
          } on TimeoutException {
            throw ProjectBuildV2RequestException(
              0,
              'project_build_request_timeout',
            );
          } on http.ClientException {
            throw ProjectBuildV2RequestException(
              0,
              'project_build_network_error',
            );
          } on FormatException {
            throw ProjectBuildV2RequestException(
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
      throw ProjectBuildV2RequestException(0, 'project_build_scope_changed');
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
      (_) => fail(
        ProjectBuildV2RequestException(0, 'project_build_scope_changed'),
      ),
    );
    Future<T>.sync(work).then((value) {
      if (clock.elapsed >= timeout) {
        fail(TimeoutException('project_build_deadline'));
      } else if (!result.isCompleted) {
        result.complete(value);
      }
    }, onError: (Object error, StackTrace stack) => fail(error, stack));
    if (_sealed) {
      fail(ProjectBuildV2RequestException(0, 'project_build_scope_changed'));
    }
    try {
      return await result.future;
    } finally {
      timer.cancel();
      await cancellation.cancel();
    }
  }

  Future<Uint8List> _read(
    Stream<List<int>> stream,
    Stopwatch clock,
    int maximumBytes,
  ) async {
    final done = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    final subscription = stream.listen(
      (chunk) {
        if (done.isCompleted) return;
        length += chunk.length;
        if (length > maximumBytes) {
          done.completeError(
            ProjectBuildV2RequestException(
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
