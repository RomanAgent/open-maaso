import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

/// Account-local, bounded transport evidence. No queries, page text, URLs,
/// coordinates, request headers or model output are retained here.
class WebSearchDiagnosticsService extends AppService {
  WebSearchDiagnosticsService({
    required Database database,
    required bool Function() isCurrent,
    DateTime Function()? now,
  }) : _database = database,
       _isCurrent = isCurrent,
       _now = now ?? DateTime.now;

  static const maximumRecords = 20;
  static final _record = StoreRef<String, List<Object?>>(
    'web_search_diagnostics.v1',
  ).record('recent');
  final Database _database;
  final bool Function() _isCurrent;
  final DateTime Function() _now;
  bool _active = true;
  Future<void> _tail = Future<void>.value();

  bool get _current {
    if (!_active || isClosed) return false;
    try {
      return _isCurrent();
    } on Object {
      return false;
    }
  }

  /// An optional sidecar: persistence starts after the handler can return.
  void record(String operation, Map<String, dynamic> receipt) {
    if (!_current ||
        !const {'webSearch', 'imageSearch', 'readPage'}.contains(operation)) {
      return;
    }
    final attempts = receipt['attempts'];
    final results = receipt['results'];
    final entry = <String, Object?>{
      'atUtc': _now().toUtc().toIso8601String(),
      'operation': operation,
      'status': _token(receipt['status']),
      if (receipt['networkRegion'] != null)
        'networkRegion': _token(receipt['networkRegion']),
      if (receipt['regionSource'] != null)
        'regionSource': _token(receipt['regionSource']),
      if (receipt['sourceSelection'] != null)
        'sourceSelection': _token(receipt['sourceSelection']),
      if (results is List) 'resultCount': results.length.clamp(0, 10),
      'attempts': attempts is List
          ? attempts.whereType<Map>().take(3).map(_attempt).toList()
          : [_attempt(receipt)],
    };
    _tail = _tail
        .then((_) async {
          if (!_current) return;
          final previous = await _record.get(_database) ?? <Object?>[];
          if (!_current) return;
          final next = <Object?>[...previous, entry];
          if (next.length > maximumRecords) {
            next.removeRange(0, next.length - maximumRecords);
          }
          await _record.put(_database, next);
        })
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  static Map<String, Object?> _attempt(Map receipt) => {
    for (final key in ['source', 'status', 'error', 'failureStage'])
      if (receipt[key] != null) key: _token(receipt[key]),
    'sourceHost': ?_host(receipt['sourceHost']),
    for (final key in ['elapsedMs', 'timeoutMs'])
      if (receipt[key] case final int value) key: value.clamp(0, 600000),
    if (receipt['httpStatus'] case final int value)
      if (value >= 100 && value <= 599) 'httpStatus': value,
  };

  static String _token(Object? value) {
    const values = {
      'ok',
      'failed',
      'no_results',
      'partial',
      'blocked',
      'china_mainland',
      'overseas',
      'manual',
      'authorized_location',
      'device_locale',
      'default',
      'primary',
      'alternate',
      'bing_rss',
      'duckduckgo',
      'bing_images',
      'commons',
      'wikimedia_commons',
      'duckduckgo_images',
      'public_page',
      'timeout',
      'network_error',
      'http_error',
      'search_failed',
      'challenge',
      'rate_limited',
      'parse_error',
      'invalid_response',
      'response_too_large',
      'response_headers',
      'response_body',
      'parse',
      'invalid_url',
      'https_required',
      'blocked_target',
      'private_address',
      'non_public_address',
      'dns_failed',
      'redirect_blocked',
      'too_many_redirects',
      'unsupported_content_type',
      'unsupported_platform',
      'public_dns_validation_unavailable',
      'url',
      'redirect',
      'dns',
      'connect',
      'unsafe_url',
      'public_hostname_required',
      'connection_unavailable',
      'request_cancelled',
      'empty_content',
      'invalid_content',
      'invalid_redirect',
      'missing_url',
      'empty_url',
      'invalid_source',
      'missing_query',
      'empty_query',
      'cancelled',
      'request_aborted',
    };
    return value is String && values.contains(value) ? value : 'unknown';
  }

  static String? _host(Object? value) {
    if (value is! String || value.length > 253) return null;
    final host = value.toLowerCase();
    return RegExp(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$').hasMatch(host)
        ? host
        : null;
  }

  Future<void> get whenSettled => _tail;

  Future<List<Object?>> recent() async {
    await _tail;
    if (!_current) return const [];
    return List<Object?>.unmodifiable(
      await _record.get(_database) ?? <Object?>[],
    );
  }

  Future<void> deactivateAndDrain() async {
    _active = false;
    await _tail;
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
