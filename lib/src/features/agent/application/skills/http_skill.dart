import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Generic HTTP fetch skill — gives the agent access to arbitrary REST
/// APIs the user explicitly asks about.
///
/// Hard guardrails (the agent can't unbind these):
///   * HTTPS only (no http://, no localhost, no 127./10./192.168./[::1])
///   * Hostname can't be a bare IP literal
///   * Body size capped at 64 KB outbound
///   * Response truncated to 16 KB so a runaway dump doesn't poison the
///     LLM context window
///   * 10s connect / 15s receive timeout
///
/// These rules are deliberately conservative — when an agent skill can
/// call any URL, you become responsible for what it reaches.
class HttpSkill extends AgentSkill {
  HttpSkill({this.agentId});

  final String? agentId;

  static const _maxBodyBytes = 64 * 1024;
  static const _maxResponseBytes = 16 * 1024;
  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 10),
      // Don't follow redirects beyond 3 — keeps "follow forever" attacks bounded.
      maxRedirects: 3,
      responseType: ResponseType.plain,
    ),
  );

  @override
  String get skillName => 'Http';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Make a raw HTTPS request to a public API the user mentioned. '
      'Use for arbitrary REST endpoints — webhooks, public data feeds, '
      'JSON APIs. HTTPS-only, no private network access.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'get': _get,
    'post': _post,
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    'get': {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description':
              'Full HTTPS URL.  Must start with https:// and resolve to a public host (no localhost / private IPs).',
        },
        'headers': {
          'type': 'object',
          'description':
              'Optional request headers as a flat string→string map.',
          'additionalProperties': {'type': 'string'},
        },
      },
      'required': ['url'],
    },
    'post': {
      'type': 'object',
      'properties': {
        'url': {'type': 'string', 'description': 'Full HTTPS URL.'},
        'headers': {
          'type': 'object',
          'description': 'Optional request headers.',
          'additionalProperties': {'type': 'string'},
        },
        'body': {
          'type': 'string',
          'description':
              'Request body as a string.  Set Content-Type via headers if needed.  Max 64KB.',
        },
      },
      'required': ['url'],
    },
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'get': 'Perform an HTTPS GET on a public URL and return the response.',
    'post': 'Perform an HTTPS POST on a public URL with an optional body.',
  };

  // ─────────────────────────── implementation ───────────────────────────

  dynamic _get(List<dynamic> args) => _send('GET', args);
  dynamic _post(List<dynamic> args) => _send('POST', args);

  Future<String> _send(String method, List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      final raw = args[0];
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is! Map) return '{"error":"expected_object"}';
      final urlStr = decoded['url']?.toString().trim() ?? '';
      final headers = (decoded['headers'] is Map)
          ? Map<String, dynamic>.from(
              decoded['headers'],
            ).map((k, v) => MapEntry(k, v.toString()))
          : <String, String>{};
      final body = decoded['body']?.toString() ?? '';
      final reject = _validateUrl(urlStr);
      if (reject != null) return jsonEncode({'error': reject});
      if (body.length > _maxBodyBytes) {
        return jsonEncode({
          'error': 'body_too_large',
          'bodyBytes': body.length,
          'maxBodyBytes': _maxBodyBytes,
        });
      }
      Log.i('🌐 [Http] $method $urlStr (body=${body.length}B)');
      final res = await _dio.request<String>(
        urlStr,
        data: method == 'POST' ? body : null,
        options: Options(
          method: method,
          headers: headers,
          // Don't throw on non-2xx; let the agent see the status code.
          validateStatus: (_) => true,
        ),
      );
      final fullBody = res.data ?? '';
      final truncated = fullBody.length > _maxResponseBytes;
      final outBody = truncated
          ? fullBody.substring(0, _maxResponseBytes)
          : fullBody;
      return jsonEncode({
        'status': res.statusCode,
        'body': outBody,
        if (truncated) 'truncated': true,
      });
    } on DioException catch (e) {
      Log.w('🌐 [Http] $method failed: ${e.message}');
      return jsonEncode({'error': 'network_error'});
    } catch (e) {
      Log.w('🌐 [Http] $method threw: $e');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  /// Returns an error string when the url is unsafe, null when it's fine.
  static String? _validateUrl(String urlStr) {
    if (urlStr.isEmpty) return 'empty_url';
    final uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasAuthority) return 'malformed_url';
    if (uri.scheme.toLowerCase() != 'https') {
      return 'https_required';
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return 'missing_host';
    if (host == 'localhost' || host.endsWith('.localhost')) {
      return 'localhost_blocked';
    }
    // Reject bare IP literals — easiest way to block private-range targets
    // without a full RFC1918 / link-local table.  Public APIs always go
    // through a DNS name.
    final ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
    final ipv6 = host.startsWith('[') && host.endsWith(']');
    if (ipv4.hasMatch(host) || ipv6) return 'bare_ip_blocked';
    return null;
  }
}
