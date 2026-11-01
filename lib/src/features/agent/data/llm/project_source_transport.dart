import 'dart:async';
import 'dart:convert';

import 'llm_response_integrity.dart';

const projectSourceDefaultIdleTimeout = Duration(minutes: 5);

/// A source request can be cancelled while awaiting headers or idle input.
/// Checks are synchronous and never initiate another model/privacy request.
class ProjectSourceCancellation {
  ProjectSourceCancellation(this.shouldCancel, {this.onCancelled}) {
    if (shouldCancel != null) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => check(),
      );
    }
    check();
  }

  final bool Function()? shouldCancel;
  final void Function()? onCancelled;
  final _cancelled = Completer<void>();
  Timer? _timer;

  void check() {
    if (_cancelled.isCompleted) return;
    var cancel = false;
    try {
      cancel = shouldCancel?.call() == true;
    } catch (_) {
      cancel = true;
    }
    if (!cancel) return;
    _cancelled.complete();
    onCancelled?.call();
  }

  void requireCurrent() {
    check();
    if (_cancelled.isCompleted) {
      throw const LLMResponseIntegrityException.publicFailure('interrupted');
    }
  }

  Future<T> wait<T>(Future<T> operation) {
    requireCurrent();
    return Future.any([
      operation,
      _cancelled.future.then<T>((_) {
        throw const LLMResponseIntegrityException.publicFailure('interrupted');
      }),
    ]);
  }

  Stream<T> bind<T>(Stream<T> source) {
    late StreamController<T> output;
    StreamSubscription<T>? subscription;
    output = StreamController<T>(
      onListen: () {
        subscription = source.listen(
          (event) {
            check();
            if (!output.isClosed && !_cancelled.isCompleted) output.add(event);
          },
          onError: (Object error, StackTrace stack) {
            if (!output.isClosed) output.addError(error, stack);
          },
          onDone: () {
            if (!output.isClosed) unawaited(output.close());
          },
        );
        _cancelled.future.then((_) {
          if (output.isClosed) return;
          output.addError(
            const LLMResponseIntegrityException.publicFailure('interrupted'),
          );
          unawaited(_cancelSubscription(subscription));
          unawaited(output.close());
        });
      },
      onCancel: () {
        final active = subscription;
        if (active != null) unawaited(_cancelSubscription(active));
      },
    );
    return output.stream;
  }

  void dispose() => _timer?.cancel();

  static Future<void> _cancelSubscription<T>(
    StreamSubscription<T>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {
      // Cancellation is already the owned request's terminal outcome. An
      // unfinished async generator must not leak a second unhandled failure.
    }
  }
}

/// Decodes complete SSE data frames without evaluating or logging payloads.
/// The transport framing bound is per frame, not a project/source length cap.
Stream<String> projectSourceSseData(Stream<List<int>> input) async* {
  var lineBytes = <int>[];
  var frameBytes = 0;
  var data = <String>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (++frameBytes > 4 * 1024 * 1024) {
        throw const LLMResponseIntegrityException.invalidResponse();
      }
      if (byte != 0x0a) {
        lineBytes.add(byte);
        continue;
      }
      if (lineBytes.isNotEmpty && lineBytes.last == 0x0d) {
        lineBytes.removeLast();
      }
      final line = utf8.decode(lineBytes);
      lineBytes = <int>[];
      if (line.isEmpty) {
        frameBytes = 0;
        if (data.isNotEmpty) {
          yield data.join('\n');
          data = <String>[];
        }
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
  }
  if (lineBytes.isNotEmpty || data.isNotEmpty) {
    throw const LLMResponseIntegrityException.publicFailure(
      'modelStreamInterrupted',
    );
  }
}
