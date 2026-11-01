import 'dart:convert';

import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Produces compact, token-safe logs for failed API calls.
///
/// Request headers, request bodies, URI queries, and upload URLs are
/// deliberately excluded so a device log can be shared for diagnosis.
class ServerRequestFailureLog {
  const ServerRequestFailureLog._();

  static void response({
    required String source,
    required String method,
    required Uri uri,
    required int statusCode,
    required String responseBody,
    Object? error,
    StackTrace? stackTrace,
  }) {
    Log.e(
      describeResponse(
        source: source,
        method: method,
        uri: uri,
        statusCode: statusCode,
        responseBody: responseBody,
      ),
      error: _redactedError(error),
      stackTrace: redactedStackTrace(stackTrace),
    );
  }

  static void transport({
    required String source,
    required String method,
    required Uri uri,
    required Object error,
    StackTrace? stackTrace,
  }) {
    Log.e(
      describeTransport(source: source, method: method, uri: uri, error: error),
      error: _redactedError(error),
      stackTrace: redactedStackTrace(stackTrace),
    );
  }

  /// Returns a bounded, single-line stack suitable for support diagnostics.
  ///
  /// Native/plugin exceptions can embed account identifiers, signed URLs, or
  /// device-local paths in stack frames. Apply the same allowlist-free
  /// redaction used for response text before handing a stack to the logger.
  static StackTrace? redactedStackTrace(StackTrace? stackTrace) {
    if (stackTrace == null) return null;
    return StackTrace.fromString(_singleLine(stackTrace.toString()));
  }

  static String describeTransport({
    required String source,
    required String method,
    required Uri uri,
    required Object error,
  }) {
    final safeError = _singleLine(error.toString());
    return '🌐 [$source] ${method.toUpperCase()} ${_path(uri, method)} '
        'failed before an HTTP response: $safeError';
  }

  static String describeResponse({
    required String source,
    required String method,
    required Uri uri,
    required int statusCode,
    required String responseBody,
  }) {
    final fields = <String>[
      '🌐 [$source] ${method.toUpperCase()} ${_path(uri, method)} failed',
      'HTTP $statusCode',
    ];
    final decoded = _jsonMap(responseBody);
    if (decoded != null) {
      _appendField(fields, 'code', decoded['code']);
      _appendField(fields, 'message', decoded['message']);
      _appendField(fields, 'traceId', decoded['traceId']);
    } else {
      final body = _singleLine(responseBody);
      if (body.isNotEmpty) fields.add('body=$body');
    }
    return fields.join(' | ');
  }

  static Map<String, dynamic>? _jsonMap(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static void _appendField(List<String> fields, String name, Object? value) {
    final text = _singleLine(value?.toString() ?? '');
    if (text.isNotEmpty) fields.add('$name=$text');
  }

  static String _path(Uri uri, String method) {
    if (method.toUpperCase() == 'PUT' || _hasPresignedQuery(uri)) {
      return '[REDACTED]';
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    return path
        .replaceAll(_uuidPattern, '[REDACTED]')
        .replaceAll(_localPathPattern, '[REDACTED]')
        .replaceAll(_windowsLocalPathPattern, '[REDACTED]');
  }

  static bool _hasPresignedQuery(Uri uri) {
    for (final key in uri.queryParametersAll.keys) {
      final normalized = key.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
      if (normalized.contains('signature') ||
          normalized.contains('credential') ||
          normalized.contains('accesskey') ||
          normalized.contains('securitytoken') ||
          normalized == 'policy' ||
          normalized.contains('keypairid')) {
        return true;
      }
    }
    return false;
  }

  static String _singleLine(String value) {
    final normalized = _redactSensitive(
      value.replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
    if (normalized.length <= 320) return normalized;
    return '${normalized.substring(0, 317)}...';
  }

  static Object? _redactedError(Object? error) {
    return error == null ? null : _singleLine(error.toString());
  }

  static String _redactSensitive(String value) {
    if (value.isEmpty) return value;
    var safe = value.replaceAll(_bearerPattern, 'Bearer [REDACTED]');
    safe = safe.replaceAll(_urlQueryPattern, '[REDACTED]');
    safe = safe.replaceAllMapped(
      _promptOrInstructionTailPattern,
      (match) => '${match.group(1)}=[REDACTED]',
    );
    safe = safe.replaceAllMapped(
      _sensitiveAssignmentPattern,
      (match) => '${match.group(1)}=[REDACTED]',
    );
    safe = safe.replaceAll(_uuidPattern, '[REDACTED]');
    safe = safe.replaceAll(
      _parenthesizedSensitiveLocationPattern,
      '([REDACTED])',
    );
    safe = safe.replaceAll(_quotedSensitiveLocationPattern, '[REDACTED]');
    safe = safe.replaceAll(_resourceUriPattern, '[REDACTED]');
    safe = safe.replaceAll(_localPathPattern, '[REDACTED]');
    safe = safe.replaceAllMapped(
      _absoluteUnixTextPathPattern,
      (match) => '${match.group(1)}[REDACTED]',
    );
    safe = safe.replaceAll(_windowsLocalPathPattern, '[REDACTED]');
    return safe;
  }

  static final RegExp _bearerPattern = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final RegExp _urlQueryPattern = RegExp(
    r'''https?://[^\s?)"']+\?[^\s)"']*''',
    caseSensitive: false,
  );
  static final RegExp _sensitiveAssignmentPattern = RegExp(
    r'\b(authorization|access[_-]?token|rtc[_-]?token|publish[_-]?ticket|'
    r'signature|ossaccesskeyid|account[_-]?uuid|prompt|'
    r'idempotency[_-]?key|operation[_-]?key|compensation[_-]?key|'
    r'instruction(?:[_-]?text)?|model[_-]?(?:path|url)|bundle[_-]?url|'
    r'local[_-]?path)\b\s*[:=]\s*[^;|}\r\n]+',
    caseSensitive: false,
  );
  static final RegExp _promptOrInstructionTailPattern = RegExp(
    r'\b(prompt|instruction(?:[_-]?text)?)\b\s*[:=].*$',
    caseSensitive: false,
  );
  static final RegExp _uuidPattern = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-'
    r'[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final RegExp _localPathPattern = RegExp(
    r'(?:/Users|/home|/tmp|/var/mobile|/var/folders|/var/tmp|/private/var|'
    r'/data/user|/storage/emulated|/Volumes|/workspace|/opt)/'
    r'[^\s;|,"]+',
    caseSensitive: false,
  );
  static final RegExp _windowsLocalPathPattern = RegExp(
    r'(?:[A-Za-z]:[\\/]|\\\\[^\\/\s]+[\\/][^\\/\s]+[\\/])'
    r'[^\s;|,"]+',
    caseSensitive: false,
  );
  static final RegExp _resourceUriPattern = RegExp(
    r'\b[A-Za-z][A-Za-z0-9+.-]*://[^\s;|,)"]+',
  );
  static final RegExp _parenthesizedSensitiveLocationPattern = RegExp(
    r'\((?:[A-Za-z][A-Za-z0-9+.-]*://|/|[A-Za-z]:[\\/]|\\\\)[^)]*\)',
    caseSensitive: false,
  );
  static final RegExp _quotedSensitiveLocationPattern = RegExp(
    r'''(["'])(?:[A-Za-z][A-Za-z0-9+.-]*://|/|[A-Za-z]:[\\/]|\\\\).*?\1''',
    caseSensitive: false,
  );
  static final RegExp _absoluteUnixTextPathPattern = RegExp(
    r'''(^|[\s(=:\[{},])(/[^\s)"']+)''',
  );
}
