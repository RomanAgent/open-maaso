import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'daily_token_usage_service.dart';
import 'llm_request_dispatch_scope.dart';

typedef RecordTokenUsage =
    Future<void> Function({
      required String requestId,
      required DateTime dispatchedAt,
      required ReportedTokenUsage? usage,
    });

/// Records one actual HTTP dispatch, independent of user turns and retries.
/// SSE usage snapshots replace each other; they are never added to each other.
final class MeteredLlmHttpClient extends http.BaseClient {
  MeteredLlmHttpClient({
    required http.Client inner,
    required RecordTokenUsage record,
    bool Function()? canDispatch,
    DateTime Function()? now,
    void Function()? onClosed,
  }) : _inner = inner,
       _record = record,
       _canDispatch = canDispatch ?? (() => true),
       _now = now ?? DateTime.now,
       _onClosed = onClosed;
  final http.Client _inner;
  final RecordTokenUsage _record;
  final bool Function() _canDispatch;
  final DateTime Function() _now;
  final void Function()? _onClosed;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || !_canDispatch()) {
      throw StateError('token_usage_account_changed');
    }
    final id = const Uuid().v4();
    final at = _now();
    Future<void> finish(ReportedTokenUsage? usage) async {
      try {
        await _record(requestId: id, dispatchedAt: at, usage: usage);
      } catch (_) {
        /* Telemetry cannot trigger a model retry. */
      }
    }

    http.StreamedResponse response;
    try {
      LlmRequestDispatchScope.notify(request);
      response = await _inner.send(request);
    } catch (_) {
      unawaited(finish(null));
      rethrow;
    }
    // Rejected admission has no successful model response. Do not fabricate a
    // billed token count for permission errors or unsupported request options.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return response;
    }
    final observer = _UsageResponseObserver(
      sse: (response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      ),
    );
    StreamSubscription<List<int>>? subscription;
    Future<void>? finalized;
    var endedNormally = false;
    Future<void> finalize() => finalized ??= Future<void>.sync(() async {
      observer.finish();
      final usage = observer.usage;
      final complete =
          !observer.failed &&
          (observer.sse ? observer.terminalMarker : endedNormally);
      // The account service owns its write queue. A slow telemetry disk must
      // not delay valid response completion, cancellation, or a model error.
      unawaited(finish(complete ? usage : usage?.asIncomplete()));
    });
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = response.stream.listen(
          (bytes) {
            observer.add(bytes);
            controller.add(bytes);
          },
          onError: (Object error, StackTrace stack) {
            observer.failed = true;
            controller.addError(error, stack);
          },
          onDone: () {
            endedNormally = true;
            unawaited(finalize().whenComplete(controller.close));
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        await subscription?.cancel();
        await finalize();
      },
    );

    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
    _onClosed?.call();
  }
}

final class _UsageResponseObserver {
  _UsageResponseObserver({required this.sse});
  final bool sse;
  final List<int> _pending = [];
  bool _overflow = false;
  ReportedTokenUsage? usage;
  bool failed = false;
  bool terminalMarker = false;
  static const _maxLineBytes = 256 * 1024;
  static const _maxBodyBytes = 2 * 1024 * 1024;

  void add(List<int> bytes) {
    if (!sse) {
      if (_overflow) return;
      if (_pending.length + bytes.length > _maxBodyBytes) {
        _pending.clear();
        _overflow = true;
        return;
      }
      _pending.addAll(bytes);
      return;
    }
    for (final byte in bytes) {
      if (byte == 10) {
        if (!_overflow) _parseLine();
        _pending.clear();
        _overflow = false;
      } else if (!_overflow) {
        if (_pending.length >= _maxLineBytes) {
          _pending.clear();
          _overflow = true;
        } else {
          _pending.add(byte);
        }
      }
    }
  }

  void _parseLine() {
    final line = utf8.decode(_pending, allowMalformed: true).trim();
    if (line.startsWith('event:') && line.substring(6).trim() == 'error') {
      failed = true;
    }
    if (!line.startsWith('data:')) return;
    _accept(line.substring(5).trim());
  }

  void _accept(String data) {
    if (data == '[DONE]') {
      terminalMarker = true;
      return;
    }
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map && decoded['error'] != null) failed = true;
      final parsed = ReportedTokenUsage.fromPayload(decoded);
      if (parsed != null) usage = parsed;
    } catch (_) {
      /* Preserve response bytes and let the provider validate. */
    }
  }

  void finish() {
    if (!_overflow && _pending.isNotEmpty) {
      if (sse) {
        _parseLine();
      } else {
        _accept(utf8.decode(_pending, allowMalformed: true));
      }
    }
    _pending.clear();
  }
}
