import 'dart:async';

import 'package:http/http.dart' as http;

/// An optional, turn-owned observer at the final HTTP dispatch boundary.
/// Request data is inspected only by a scoped consumer; none is persisted here.
abstract final class LlmRequestDispatchScope {
  static final Object _key = Object();

  static T run<T>(
    T Function() operation, {
    required void Function(http.BaseRequest) onDispatch,
  }) => runZoned(operation, zoneValues: {_key: onDispatch});

  static void notify(http.BaseRequest request) {
    final observer = Zone.current[_key];
    if (observer is! void Function(http.BaseRequest)) return;
    try {
      observer(request);
    } on Object {
      // Local statistics must not fail or repeat a billed model request.
    }
  }
}
