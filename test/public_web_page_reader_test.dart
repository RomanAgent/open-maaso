import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_client_stub.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_reader.dart';
import 'package:maaso/src/features/agent/application/skills/public_web_page_url_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 15, 12, 30);

  PublicWebPageReader reader(http.Client client, {Duration? timeout}) =>
      PublicWebPageReader(
        client: client,
        now: () => now,
        timeout: timeout ?? const Duration(seconds: 8),
      );

  test(
    'HTML becomes article text without loading or executing resources',
    () async {
      final requests = <http.Request>[];
      final result = await reader(
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            '<html><head><title>Forecast &amp; details</title>'
            '<script>evil()</script><style>secret-style</style></head><body>'
            '<nav>menu</nav><main><h1>Shenzhen weather</h1>'
            '<p>Temperature: 25 °C</p><p>Cloudy &amp; dry</p>'
            '<script src="https://example.org/remote.js">bad</script>'
            '<img src="https://example.org/image.png">'
            '<div hidden>hidden details</div><aside>advert</aside></main>'
            '<footer>footer</footer></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      ).read('https://example.com/article#section');
      expect(result['status'], 'ok');
      expect(result['url'], 'https://example.com/article');
      expect(result['sourceHost'], 'example.com');
      expect(result['httpStatus'], 200);
      expect(result['title'], 'Forecast & details');
      expect(
        result['text'],
        'Shenzhen weather\nTemperature: 25 °C\nCloudy & dry',
      );
      expect(result['fetchedAtUtc'], now.toIso8601String());
      expect(result['truncated'], false);
      expect(requests, hasLength(1));
      expect(requests.single.followRedirects, false);
      expect(requests.single.headers.keys, isNot(contains('authorization')));
      expect(requests.single.headers.keys, isNot(contains('cookie')));
      expect(requests.single.headers.keys, isNot(contains('referer')));
    },
  );

  test(
    'fallback body keeps text when a document has no article element',
    () async {
      final result = await reader(
        MockClient(
          (_) async => http.Response(
            '<p>A</p><p>B</p>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      ).read('https://example.com');
      expect(result['text'], 'A\nB');
    },
  );

  test(
    'plain text and JSON are readable without HTML interpretation',
    () async {
      final client = MockClient((request) async {
        if (request.url.path == '/json') {
          return http.Response(
            '{"city":"深圳","temperature":25}',
            200,
            headers: {
              'content-type': 'application/problem+json; charset=utf-8',
            },
          );
        }
        return http.Response(
          '<literal>\n  second line  ',
          200,
          headers: {'content-type': 'text/plain'},
        );
      });
      final plain = await reader(client).read('https://example.com/plain');
      final json = await reader(client).read('https://example.com/json');
      expect(plain['text'], '<literal>\nsecond line');
      expect(jsonDecode(json['text'] as String), {
        'city': '深圳',
        'temperature': 25,
      });
    },
  );

  test('invalid JSON returns a parse failure', () async {
    final result = await reader(
      MockClient(
        (_) async => http.Response(
          '{bad',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    ).read('https://example.com');
    expect(result['error'], 'invalid_content');
    expect(result['failureStage'], 'parse');
  });

  test('unsupported binary responses are not read as text', () async {
    final result = await reader(
      MockClient(
        (_) async => http.Response(
          'binary',
          200,
          headers: {'content-type': 'application/pdf'},
        ),
      ),
    ).read('https://example.com');
    expect(result['error'], 'unsupported_content_type');
    expect(result['failureStage'], 'response_headers');
  });

  test('missing content type fails closed', () async {
    final result = await reader(
      _StreamClient(
        (_) async => http.StreamedResponse(Stream.value([65]), 200),
      ),
    ).read('https://example.com');
    expect(result['error'], 'unsupported_content_type');
  });

  test('HTTP failures preserve actual status', () async {
    final result = await reader(
      MockClient((_) async => http.Response('unavailable', 503)),
    ).read('https://example.com');
    expect(result['status'], 'failed');
    expect(result['httpStatus'], 503);
    expect(result['error'], 'http_error');
  });

  test('follows at most two individually validated HTTPS redirects', () async {
    final urls = <String>[];
    final result = await reader(
      MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.path == '/start') {
          return http.Response('', 302, headers: {'location': '/middle'});
        }
        if (request.url.path == '/middle') {
          return http.Response(
            '',
            307,
            headers: {'location': 'https://example.org/end'},
          );
        }
        return http.Response(
          'final article',
          200,
          headers: {'content-type': 'text/plain'},
        );
      }),
    ).read('https://example.com/start');
    expect(result['status'], 'ok');
    expect(result['sourceHost'], 'example.org');
    expect(urls, [
      'https://example.com/start',
      'https://example.com/middle',
      'https://example.org/end',
    ]);
  });

  test(
    'redirect loops are bounded and cannot become third hop requests',
    () async {
      var requests = 0;
      final result = await reader(
        MockClient((_) async {
          requests++;
          return http.Response('', 302, headers: {'location': '/again'});
        }),
      ).read('https://example.com');
      expect(requests, 3);
      expect(result['error'], 'too_many_redirects');
    },
  );

  for (final target in [
    'http://example.org/',
    'https://127.0.0.1/',
    'https://admin:password@example.org/',
    'https://example.org:8443/',
    'https://router.local/',
  ]) {
    test('does not send unsafe redirect target $target', () async {
      var requests = 0;
      final result = await reader(
        MockClient((_) async {
          requests++;
          return http.Response('', 302, headers: {'location': target});
        }),
      ).read('https://example.com');
      expect(result['status'], 'failed');
      expect(requests, 1);
    });
  }

  test('empty redirects are rejected', () async {
    final result = await reader(
      MockClient((_) async => http.Response('', 302)),
    ).read('https://example.com');
    expect(result['error'], 'invalid_redirect');
  });

  test('streamed bytes cannot exceed 2 MiB without a content length', () async {
    final result = await reader(
      _StreamClient((_) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            List.filled(PublicWebPageReader.maxResponseBytes, 65),
            [66],
          ]),
          200,
          headers: {'content-type': 'text/plain'},
        );
      }),
    ).read('https://example.com');
    expect(result['error'], 'response_too_large');
    expect(result['failureStage'], 'response_body');
  });

  test('oversized declared body is cancelled before reading it', () async {
    var listened = false;
    final stream = StreamController<List<int>>(onListen: () => listened = true);
    final result = await reader(
      _StreamClient((_) async {
        return http.StreamedResponse(
          stream.stream,
          200,
          contentLength: PublicWebPageReader.maxResponseBytes + 1,
          headers: {'content-type': 'text/plain'},
        );
      }),
    ).read('https://example.com');
    expect(result['error'], 'response_too_large');
    expect(listened, true); // Attach only to cancel; consume no bytes.
    await stream.close();
  });

  test('text has a bounded output and never cuts a surrogate pair', () async {
    final result = await reader(
      MockClient((_) async {
        return http.Response(
          '${'A' * 255}😀${'B' * 1000}',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    ).read('https://example.com', maxChars: 256);
    expect(result['status'], 'ok');
    expect(result['text'], 'A' * 255);
    expect(result['truncated'], true);
  });

  test('output is clamped to a maximum of 20000 characters', () async {
    final result = await reader(
      MockClient((_) async {
        return http.Response(
          'A' * 30000,
          200,
          headers: {'content-type': 'text/plain'},
        );
      }),
    ).read('https://example.com', maxChars: 1000000);
    expect((result['text'] as String).length, 20000);
    expect(result['truncated'], true);
  });

  test('one total deadline bounds all redirect and header waits', () async {
    var requests = 0;
    final result = await reader(
      MockClient((_) async {
        requests++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response('', 302, headers: {'location': '/next'});
      }),
      timeout: const Duration(milliseconds: 45),
    ).read('https://example.com');
    expect(result['error'], 'timeout');
    expect(result['failureStage'], 'response_headers');
    expect(requests, 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 2); // Timed-out work cannot start another request.
  });

  test(
    'body timeout aborts the request and preserves response status',
    () async {
      final body = StreamController<List<int>>();
      final aborted = Completer<void>();
      final result = await reader(
        _StreamClient((request) async {
          (request as http.AbortableRequest).abortTrigger!.then((_) {
            aborted.complete();
            body.close();
          });
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/plain'},
          );
        }),
        timeout: const Duration(milliseconds: 20),
      ).read('https://example.com');
      expect(result['error'], 'timeout');
      expect(result['failureStage'], 'response_body');
      expect(result['httpStatus'], 200);
      await aborted.future;
    },
  );

  test('invalid source URL does not reach the injected transport', () async {
    var requests = 0;
    final result = await reader(
      MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
    ).read('https://localhost/');
    expect(result['status'], 'failed');
    expect(result.containsKey('url'), false);
    expect(requests, 0);
  });

  test(
    'browser and unsupported platforms fail closed before network access',
    () async {
      final result = await reader(
        PublicWebPageUnavailableClient(),
      ).read('https://example.com');
      expect(result['error'], 'public_dns_validation_unavailable');
      expect(result['failureStage'], 'dns');
    },
  );

  test(
    'injected transport structured DNS rejection is not mislabelled timeout',
    () async {
      final result = await reader(
        _StreamClient((_) async {
          throw const PublicWebPageRequestException(
            'non_public_address',
            failureStage: 'dns',
          );
        }),
      ).read('https://example.com');
      expect(result['error'], 'non_public_address');
      expect(result['failureStage'], 'dns');
    },
  );
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
