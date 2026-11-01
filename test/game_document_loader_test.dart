import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/widgets_hub/data/game_document_loader.dart';

const _policy =
    "default-src 'none'; script-src 'unsafe-inline'; worker-src blob:; sandbox allow-scripts";
const _headers = {
  'content-type': 'text/html; charset=utf-8',
  'content-security-policy': _policy,
};
final _origin = Uri.parse('https://games.example/');
final _share = Uri.parse('https://games.example/g/snake');

void main() {
  test(
    'fetches only a trusted embed and carries CSP plus a real sandbox into HTML',
    () async {
      http.Request? sent;
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            '<!doctype html><html><head><title>Snake</title></head><body><script>start()</script></body></html>',
            200,
            headers: _headers,
          );
        }),
      );
      addTearDown(loader.close);
      final document = await loader.fetch(_share);
      expect(sent!.url.toString(), 'https://games.example/g/snake/embed');
      expect(sent!.followRedirects, isFalse);
      expect(document.sandboxedHtml, contains('sandbox="allow-scripts"'));
      expect(document.sandboxedHtml, isNot(contains('allow-same-origin')));
      expect(document.sandboxedHtml, contains('Content-Security-Policy'));
      expect(document.sandboxedHtml, contains('worker-src blob:'));
      expect(
        document.sandboxedHtml,
        contains('&lt;script&gt;start()&lt;/script&gt;'),
      );
      expect(document.sandboxedHtml, isNot(contains('<script>start()')));
    },
  );

  for (final url in [
    'https://evil.example/g/snake',
    'http://games.example/g/snake',
    'https://user:secret@games.example/g/snake',
    'https://games.example/g/snake?redirect=evil',
    'https://games.example/g/snake#fragment',
    'https://games.example/g/snake/embed',
  ]) {
    test('rejects untrusted source without sending $url', () async {
      var requests = 0;
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient((request) async {
          requests++;
          return http.Response('', 200);
        }),
      );
      addTearDown(loader.close);
      await expectLater(loader.fetch(Uri.parse(url)), throwsFormatException);
      expect(requests, 0);
    });
  }

  for (final response in [
    http.Response(
      'redirect',
      302,
      headers: {..._headers, 'location': 'https://evil.example/'},
    ),
    http.Response('offline', 503, headers: _headers),
    http.Response('<html></html>', 200, headers: {'content-type': 'text/html'}),
    http.Response(
      '{}',
      200,
      headers: {..._headers, 'content-type': 'application/json'},
    ),
    http.Response('', 200, headers: _headers),
  ]) {
    test(
      'rejects invalid status, MIME, missing policy, or empty body ${response.statusCode}/${response.headers}',
      () async {
        final loader = GameDocumentLoader(
          trustedOrigin: _origin,
          client: MockClient((_) async => response),
        );
        addTearDown(loader.close);
        await expectLater(loader.fetch(_share), throwsFormatException);
      },
    );
  }

  test(
    'cancellation while downloading never produces a usable document',
    () async {
      final response = Completer<http.Response>();
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient((_) => response.future),
      );
      final pending = loader.fetch(_share);
      final assertion = expectLater(pending, throwsFormatException);
      loader.close();
      response.complete(http.Response('<html></html>', 200, headers: _headers));
      await assertion;
    },
  );

  test(
    'rejects an oversized body before creating any player document',
    () async {
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            contentLength: GameDocumentLoader.maxDocumentBytes + 1,
            headers: _headers,
          ),
        ),
      );
      addTearDown(loader.close);
      await expectLater(loader.fetch(_share), throwsFormatException);
    },
  );
  test(
    'accepts rendered packaging beyond the old raw-source 8MiB limit',
    () async {
      final content = '<html>${'x' * (8 * 1024 * 1024)}</html>';
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient(
          (_) async => http.Response(content, 200, headers: _headers),
        ),
      );
      addTearDown(loader.close);
      final result = await loader.fetch(_share);
      expect(result.html, content);
    },
  );

  test(
    'streaming response cannot exceed envelope limit without a length header',
    () async {
      final chunk = Uint8List(1024 * 1024);
      final loader = GameDocumentLoader(
        trustedOrigin: _origin,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(
              List.filled(
                GameDocumentLoader.maxDocumentBytes ~/ chunk.length + 1,
                chunk,
              ),
            ),
            200,
            headers: _headers,
          ),
        ),
      );
      addTearDown(loader.close);
      await expectLater(loader.fetch(_share), throwsFormatException);
    },
  );
}
