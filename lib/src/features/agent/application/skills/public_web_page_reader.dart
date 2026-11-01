import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'public_web_page_client_stub.dart'
    if (dart.library.io) 'public_web_page_client_io.dart'
    as transport;
import 'public_web_page_url_policy.dart';

/// Reads a public document as untrusted plain text. It never executes scripts,
/// loads referenced resources, submits forms, or inherits user credentials.
class PublicWebPageReader {
  PublicWebPageReader({
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _client = client,
       _timeout = timeout,
       _now = now ?? DateTime.now;

  final http.Client? _client;
  final Duration _timeout;
  final DateTime Function() _now;

  static const maxResponseBytes = 2 * 1024 * 1024;
  static const _redirectCodes = {301, 302, 303, 307, 308};

  Future<Map<String, dynamic>> read(
    String rawUrl, {
    int maxChars = 12000,
  }) async {
    final timer = Stopwatch()..start();
    final abort = Completer<void>();
    http.Client? client;
    Uri? current;
    int? responseStatus;
    var stage = 'url';
    try {
      current = validatePublicWebPageUrl(rawUrl);
      client = _client ?? transport.createPublicWebPageClient();
      final activeClient = client;
      final result = await (() async {
        for (var redirects = 0; ; redirects++) {
          if (abort.isCompleted) {
            throw const PublicWebPageRequestException(
              'request_cancelled',
              failureStage: 'response_headers',
            );
          }
          stage = 'response_headers';
          final request =
              http.AbortableRequest('GET', current!, abortTrigger: abort.future)
                ..followRedirects = false
                ..persistentConnection = false
                ..headers['Accept'] =
                    'text/html,application/xhtml+xml,text/plain,application/json';
          final response = await activeClient.send(request);
          if (abort.isCompleted) {
            await response.stream.listen(null).cancel();
            throw const PublicWebPageRequestException(
              'request_cancelled',
              failureStage: 'response_headers',
            );
          }
          responseStatus = response.statusCode;
          if (_redirectCodes.contains(response.statusCode)) {
            await response.stream.listen(null).cancel();
            if (redirects >= 2) {
              throw const PublicWebPageRequestException(
                'too_many_redirects',
                failureStage: 'redirect',
              );
            }
            final location = response.headers['location'];
            if (location == null || location.trim().isEmpty) {
              throw const PublicWebPageRequestException(
                'invalid_redirect',
                failureStage: 'redirect',
              );
            }
            current = validatePublicWebPageUrl(
              current!.resolve(location).toString(),
            );
            continue;
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            await response.stream.listen(null).cancel();
            throw const PublicWebPageRequestException(
              'http_error',
              failureStage: 'response_headers',
            );
          }
          final contentType = response.headers['content-type'] ?? '';
          final mime = contentType.split(';').first.trim().toLowerCase();
          if (!_supportedMime(mime)) {
            await response.stream.listen(null).cancel();
            throw const PublicWebPageRequestException(
              'unsupported_content_type',
              failureStage: 'response_headers',
            );
          }
          if ((response.contentLength ?? 0) > maxResponseBytes) {
            await response.stream.listen(null).cancel();
            throw const PublicWebPageRequestException(
              'response_too_large',
              failureStage: 'response_body',
            );
          }
          stage = 'response_body';
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            if (bytes.length + chunk.length > maxResponseBytes) {
              throw const PublicWebPageRequestException(
                'response_too_large',
                failureStage: 'response_body',
              );
            }
            bytes.addAll(chunk);
          }
          stage = 'parse';
          final rawText = _decode(bytes, contentType);
          final (title, fullText) = _readDocument(rawText, mime);
          if (fullText.isEmpty) {
            throw const PublicWebPageRequestException(
              'empty_content',
              failureStage: 'parse',
            );
          }
          final limit = maxChars.clamp(256, 20000);
          final text = _boundedText(fullText, limit);
          return <String, dynamic>{
            'status': 'ok',
            'url': current.toString(),
            'sourceHost': current!.host,
            'httpStatus': response.statusCode,
            'contentType': mime,
            'title': title,
            'text': text,
            'fetchedAtUtc': _now().toUtc().toIso8601String(),
            'truncated': fullText.length > text.length,
          };
        }
      })().timeout(_timeout);
      return {...result, 'elapsedMs': timer.elapsedMilliseconds};
    } on PublicWebPageRequestException catch (error) {
      return _failure(
        current,
        responseStatus,
        error.code,
        error.failureStage,
        timer,
      );
    } on TimeoutException {
      return _failure(current, responseStatus, 'timeout', stage, timer);
    } on FormatException {
      return _failure(current, responseStatus, 'invalid_content', stage, timer);
    } catch (_) {
      return _failure(current, responseStatus, 'network_error', stage, timer);
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (_client == null) client?.close();
      timer.stop();
    }
  }

  Map<String, dynamic> _failure(
    Uri? uri,
    int? httpStatus,
    String error,
    String stage,
    Stopwatch timer,
  ) => {
    'status': 'failed',
    if (uri != null) 'url': uri.toString(),
    if (uri != null) 'sourceHost': uri.host,
    'httpStatus': ?httpStatus,
    'error': error,
    'failureStage': stage,
    'elapsedMs': timer.elapsedMilliseconds,
  };

  static bool _supportedMime(String mime) =>
      mime == 'text/html' ||
      mime == 'application/xhtml+xml' ||
      mime == 'text/plain' ||
      mime == 'application/json' ||
      (mime.startsWith('application/') && mime.endsWith('+json'));

  static String _decode(List<int> bytes, String contentType) {
    if (RegExp(
      r'charset\s*=\s*["\x27]?(?:iso-8859-1|latin1)\b',
      caseSensitive: false,
    ).hasMatch(contentType)) {
      return latin1.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static (String, String) _readDocument(String source, String mime) {
    if (mime == 'application/json' || mime.endsWith('+json')) {
      final decoded = jsonDecode(source);
      return ('', const JsonEncoder.withIndent('  ').convert(decoded).trim());
    }
    if (mime == 'text/plain') return ('', _normalizeText(source));
    final document = html.parse(source);
    final title = _boundedText(
      _normalizeText(document.querySelector('title')?.text ?? ''),
      300,
    );
    for (final element in document.querySelectorAll(
      'script,style,noscript,template,nav,footer,aside,iframe,form,svg,canvas,'
      'button,input,select,textarea,[hidden],[aria-hidden="true"],'
      '[role="navigation"],[role="banner"],[role="contentinfo"]',
    )) {
      element.remove();
    }
    final content =
        document.querySelector('main, [role="main"]') ??
        document.querySelector('article') ??
        document.body;
    final buffer = StringBuffer();
    if (content != null) _appendText(content, buffer);
    return (title, _normalizeText(buffer.toString()));
  }

  static const _blockTags = {
    'address',
    'article',
    'blockquote',
    'br',
    'dd',
    'div',
    'dl',
    'dt',
    'figcaption',
    'figure',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'hr',
    'li',
    'main',
    'ol',
    'p',
    'pre',
    'section',
    'table',
    'tr',
    'ul',
  };

  static void _appendText(dom.Node node, StringBuffer buffer) {
    // An explicit stack avoids call-stack exhaustion from deeply nested pages.
    final pending = <(dom.Node, bool)>[(node, false)];
    while (pending.isNotEmpty) {
      final (current, closing) = pending.removeLast();
      if (current is dom.Text) {
        buffer.write(current.text);
        continue;
      }
      final block =
          current is dom.Element && _blockTags.contains(current.localName);
      if (closing) {
        if (current is dom.Element &&
            (current.localName == 'td' || current.localName == 'th')) {
          buffer.write(' ');
        }
        if (block) buffer.writeln();
        continue;
      }
      if (block) buffer.writeln();
      pending.add((current, true));
      for (final child in current.nodes.reversed) {
        pending.add((child, false));
      }
    }
  }

  static String _normalizeText(String text) => text
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
      .split(RegExp(r'\r?\n'))
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n')
      .trim();

  static String _boundedText(String text, int limit) {
    if (text.length <= limit) return text;
    var end = limit;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return text.substring(0, end);
  }
}
