import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

/// Fetches a published game only after its detail route has painted loading.
/// Catalog pagination and thumbnail rendering never own this loader.
class GameDocumentLoader {
  GameDocumentLoader({required this.trustedOrigin, http.Client? client})
    : _client = client ?? debugClientFactory?.call() ?? http.Client();

  @visibleForTesting
  static http.Client Function()? debugClientFactory;

  // The decoded source limit is separate from its rendered envelope. Base64
  // resources and nested srcdoc/attribute escaping expand valid source bytes.
  // Keep a finite download bound without rejecting an admitted 8MiB work just
  // because of packaging; this is not a model-output allowance.
  static const maxDocumentBytes =
      12 * SurfaceProjectValidator.maximumPublicSourceBytes + 1024 * 1024;
  static const timeout = Duration(seconds: 20);
  final Uri trustedOrigin;
  final http.Client _client;
  bool _closed = false;

  Future<OpenedGameDocument> fetch(Uri shareUrl) async {
    if (_closed ||
        !isTrustedAppletShareUrl(shareUrl, trustedOrigin: trustedOrigin)) {
      throw const FormatException('untrusted_game_document');
    }
    final embedUrl = shareUrl.replace(
      pathSegments: [...shareUrl.pathSegments, 'embed'],
    );
    return _fetch(embedUrl).timeout(
      timeout,
      onTimeout: () {
        close();
        throw TimeoutException('game_document_timeout');
      },
    );
  }

  Future<OpenedGameDocument> _fetch(Uri embedUrl) async {
    final request = http.Request('GET', embedUrl)
      ..followRedirects = false
      ..headers['Accept'] = 'text/html';
    final response = await _client.send(request);
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim();
    final policy = response.headers['content-security-policy']?.trim();
    if (_closed ||
        response.statusCode != 200 ||
        contentType != 'text/html' ||
        policy == null ||
        policy.isEmpty ||
        (response.contentLength ?? 0) > maxDocumentBytes) {
      throw const FormatException('invalid_game_document_response');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (_closed || bytes.length + chunk.length > maxDocumentBytes) {
        throw const FormatException('game_document_cancelled_or_too_large');
      }
      bytes.add(chunk);
    }
    if (_closed || bytes.isEmpty) {
      throw const FormatException('empty_game_document');
    }
    final html = utf8.decode(bytes.takeBytes());
    return OpenedGameDocument(embedUrl: embedUrl, html: html, policy: policy);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class OpenedGameDocument {
  const OpenedGameDocument({
    required this.embedUrl,
    required this.html,
    required this.policy,
  });

  final Uri embedUrl;
  final String html;
  final String policy;

  /// Identity of the fetched rendered document, not the author's source hash.
  String get renderedDocumentDigest =>
      sha256.convert(utf8.encode(html)).toString();

  /// loadHtmlString does not carry response headers. Preserve the response
  /// policy in the child head and its sandbox as a real iframe attribute;
  /// CSP's sandbox directive is not enforceable from a meta element alone.
  String get sandboxedHtml {
    const escape = HtmlEscape(HtmlEscapeMode.attribute);
    final meta =
        '<meta http-equiv="Content-Security-Policy" '
        'content="${escape.convert(policy)}">';
    final head = RegExp(
      r'<head\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    final protected = head == null
        ? '<!doctype html><html><head>$meta</head><body>$html</body></html>'
        : html.replaceRange(head.end, head.end, meta);
    return '<!doctype html><html><head><meta name="viewport" '
        'content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<style>html,body,iframe{margin:0;width:100%;height:100%;border:0;'
        'overflow:hidden;background:#0d0d0d}iframe{display:block}</style>'
        '</head><body><iframe data-maaso-game-observation-frame sandbox="allow-scripts" referrerpolicy="no-referrer" '
        'allow="" srcdoc="${escape.convert(protected)}"></iframe></body></html>';
  }
}
