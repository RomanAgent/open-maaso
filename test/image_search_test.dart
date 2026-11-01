import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/features/agent/application/skills/web_search_skill.dart';

void main() {
  test('image-like web queries are detected and normalized', () {
    expect(
      WebSearchSkill.isImageQuery('cute pig image, high resolution'),
      isTrue,
    );
    expect(WebSearchSkill.isImageQuery('帮我找一张小狗的图片'), isTrue);
    expect(WebSearchSkill.isImageQuery('latest projector price'), isFalse);

    expect(
      WebSearchSkill.normalizeImageQuery('cute pig image, high resolution'),
      'cute pig',
    );
    expect(
      WebSearchSkill.normalizeImageQuery('adorable dog picture'),
      'adorable dog',
    );
  });

  test('extractVqd pulls the token from DDG page HTML', () {
    expect(WebSearchSkill.extractVqd('x vqd="3-12345-67" y'), '3-12345-67');
    expect(WebSearchSkill.extractVqd('a&vqd=3-99&b'), '3-99');
    expect(WebSearchSkill.extractVqd('no token here'), isNull);
  });

  test('parseImageResults keeps only direct image urls', () {
    const body =
        '{"results":['
        '{"title":"Sunset","image":"https://images.example.org/a.jpg","thumbnail":"https://thumbs.example.org/a.jpg"},'
        '{"title":"No image"},'
        '{"title":"Beach","image":"https://images.example.org/b.png"}]}';
    final out = WebSearchSkill.parseImageResults(body, 5);
    expect(out.length, 2);
    expect(out[0]['url'], 'https://images.example.org/a.jpg');
    expect(out[0]['title'], 'Sunset');
    expect(out[0]['previewUrl'], 'https://thumbs.example.org/a.jpg');
    expect(out[1]['url'], 'https://images.example.org/b.png');
  });

  test('parseImageResults caps at maxResults', () {
    const body =
        '{"results":['
        '{"image":"https://images.example.org/1.jpg"},{"image":"https://images.example.org/2.jpg"},'
        '{"image":"https://images.example.org/3.jpg"}]}';
    expect(WebSearchSkill.parseImageResults(body, 2).length, 2);
  });

  test('parseImageResults returns empty on malformed body', () {
    expect(WebSearchSkill.parseImageResults('not json', 5), isEmpty);
    expect(WebSearchSkill.parseImageResults('{"results":[]}', 5), isEmpty);
  });

  test('parseCommonsImageResults extracts direct image URLs', () {
    const body =
        '{"query":{"pages":{'
        '"1":{"title":"File:Cute dog.jpg","imageinfo":[{"url":"https://upload.wikimedia.org/dog.jpg","mime":"image/jpeg"}]},'
        '"2":{"title":"File:Not image.pdf","imageinfo":[{"url":"https://upload.wikimedia.org/doc.pdf","mime":"application/pdf"}]},'
        '"3":{"title":"File:Pig.png","imageinfo":[{"url":"https://upload.wikimedia.org/pig.png","mime":"image/png"}]}'
        '}}}';

    final out = WebSearchSkill.parseCommonsImageResults(body, 5);

    expect(out, hasLength(2));
    expect(out[0]['url'], 'https://upload.wikimedia.org/dog.jpg');
    expect(out[0]['title'], 'Cute dog');
    expect(out[1]['url'], 'https://upload.wikimedia.org/pig.png');
  });

  test('image preview data URIs are built only from real image bytes', () {
    final png = WebSearchSkill.buildImagePreviewDataUri(const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ], contentType: 'application/octet-stream');
    final html = WebSearchSkill.buildImagePreviewDataUri(
      'not an image'.codeUnits,
      contentType: 'text/html',
    );

    expect(png, startsWith('data:image/png;base64,'));
    expect(html, isNull);
  });

  test('image preview fetch turns usable images into data URIs', () async {
    final skill = WebSearchSkill(
      httpClient: MockClient((request) async {
        if (request.url.toString().contains('good')) {
          return http.Response.bytes(
            const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
            200,
            headers: {'content-type': 'image/png'},
          );
        }
        return http.Response(
          '<html>blocked</html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      }),
    );

    final out = await skill.attachImagePreviewsForTest(const [
      {'url': 'https://images.example.org/good.png', 'title': 'good'},
      {'url': 'https://images.example.org/bad.jpg', 'title': 'bad'},
    ]);

    expect(out, hasLength(1));
    expect(out.first['url'], 'https://images.example.org/good.png');
    expect(out.first['previewDataUri'], startsWith('data:image/png;base64,'));
  });

  test('description steers image requests away from plain webSearch', () {
    final promptText = [
      WebSearchSkill().description,
      ...WebSearchSkill().nativeMethodDescriptions.values,
    ].join('\n');

    expect(promptText, contains('use imageSearch'));
    expect(promptText, contains('not webSearch'));
    expect(promptText, contains('results[0].url'));
    expect(promptText, isNot(contains('live search card')));
    expect(promptText, isNot(contains('live browsing card')));
  });

  test('Bing metadata is data-only, bounded, deduplicated and URL-safe', () {
    final body = _bingImages([
      {
        'murl': 'https://images.example.org/cat.jpg',
        'turl': '//thumbs.example.org/cat.jpg',
        't': '<b>Cat</b><script>bad()</script>',
      },
      {'murl': 'https://images.example.org/cat.jpg', 't': 'duplicate'},
      {'murl': 'javascript:alert(1)'},
      {'murl': 'http://127.0.0.1/private.jpg'},
      {'murl': 'https://user:secret@images.example.org/cat.jpg'},
      {'murl': 'http://printer.local/private.jpg'},
      {'murl': 'data:image/png;base64,abc'},
      {
        'murl': 'https://images.example.org/next.jpg',
        'turl': 'file:///tmp/x',
        't': 'x' * 900,
      },
    ]);
    final results = WebSearchSkill.parseBingImageResults(body, 10);
    expect(results, hasLength(2));
    expect(results.first['title'], 'Cat');
    expect(results.first['previewUrl'], 'https://thumbs.example.org/cat.jpg');
    expect(results.last['title']!.length, 300);
    expect(results.last.containsKey('previewUrl'), isFalse);
    expect(
      WebSearchSkill.parseBingImageResults(
        '<a class="iusc" m="broken"></a>',
        2,
      ),
      isEmpty,
    );
  });

  test('all image parsers reject nonpublic URLs and unsafe thumbnails', () {
    final payload = jsonEncode({
      'results': [
        {'image': 'http://localhost/x.png'},
        {
          'image': 'https://images.example.org/cat.png',
          'thumbnail': 'http://192.168.1.1/x.png',
          'title': '<b>cat</b>',
        },
      ],
    });
    final results = WebSearchSkill.parseImageResults(payload, 10);
    expect(results, [
      {'url': 'https://images.example.org/cat.png', 'title': 'cat'},
    ]);
    expect(
      WebSearchSkill.parseCommonsImageResults(
        jsonEncode({
          'query': {
            'pages': {
              '1': {
                'imageinfo': [
                  {'url': 'file:///tmp/x.png', 'mime': 'image/png'},
                ],
              },
            },
          },
        }),
        10,
      ),
      isEmpty,
    );
  });

  for (final region in NetworkRegion.values) {
    for (final query in ['猫的图片', 'cat images']) {
      test(
        'image source routes by region independently of query: $region/$query',
        () async {
          final hosts = <String>[];
          final resolution = NetworkRegionResolution(
            region: region,
            source: NetworkRegionSource.authorizedLocation,
          );
          final skill = WebSearchSkill(
            networkRegionProvider: () => resolution,
            httpClient: MockClient((request) async {
              hosts.add(request.url.host);
              if (request.url.host == 'cn.bing.com') {
                expect(request.url.path, '/images/search');
                return http.Response(
                  _bingImages([
                    {'murl': 'https://images.example.org/cat.jpg', 't': 'Cat'},
                  ]),
                  200,
                );
              }
              if (request.url.path == '/') {
                return http.Response('vqd="3-12345-67"', 200);
              }
              return http.Response(
                jsonEncode({
                  'results': [
                    {
                      'image': 'https://images.example.org/cat.jpg',
                      'title': 'Cat',
                    },
                  ],
                }),
                200,
              );
            }),
          );
          final result = jsonDecode(
            await skill.methods['imageSearch']!([query, 1]) as String,
          );
          expect(
            hosts,
            region == NetworkRegion.mainlandChina
                ? ['cn.bing.com']
                : ['duckduckgo.com', 'duckduckgo.com'],
          );
          expect(result['status'], 'ok');
          expect(result['networkRegion'], resolution.toJson()['region']);
          expect(result['regionSource'], 'authorized_location');
          expect((result['attempts'] as List), hasLength(1));
          expect(result.toString(), isNot(contains('base64')));
        },
      );
    }
  }

  test('mainland image challenge falls back once to public Commons', () async {
    final hosts = <String>[];
    final result = await _imageSearch(
      MockClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'cn.bing.com'
            ? http.Response('<form id="b_captchaform"></form>', 200)
            : http.Response(_commonsResult(), 200);
      }),
    );
    expect(hosts, ['cn.bing.com', 'commons.wikimedia.org']);
    expect(result['status'], 'ok');
    expect(result['source'], 'wikimedia_commons');
    expect((result['attempts'] as List).first['error'], 'challenge');
    expect((result['attempts'] as List).first['failureStage'], 'parse');
  });

  test(
    'image HTTP and parse failures are never mislabeled as a timeout',
    () async {
      final result = await _imageSearch(
        MockClient(
          (request) async => request.url.host == 'cn.bing.com'
              ? http.Response('blocked', 403)
              : http.Response('broken', 200),
        ),
      );
      expect(result['status'], 'failed');
      expect(result['reason'], 'providers_failed');
      expect((result['attempts'] as List).map((e) => e['error']), [
        'http_error',
        'parse_error',
      ]);
      expect((result['attempts'] as List).first['httpStatus'], 403);
      expect(
        (result['attempts'] as List).last['sourceHost'],
        'commons.wikimedia.org',
      );
      expect(
        (result['attempts'] as List).last['elapsedMs'],
        greaterThanOrEqualTo(0),
      );
    },
  );

  test(
    'oversized image source aborts its stream and allows fallback',
    () async {
      final aborts = <Future<void>>[];
      final result = await _imageSearch(
        MockClient.streaming((request, _) async {
          expect(request.followRedirects, isFalse);
          aborts.add((request as http.AbortableRequest).abortTrigger!);
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                request.url.host == 'cn.bing.com'
                    ? 'x' * (2 * 1024 * 1024 + 1)
                    : _commonsResult(),
              ),
            ),
            200,
          );
        }),
      );
      expect(result['status'], 'ok');
      expect((result['attempts'] as List).first['error'], 'response_too_large');
      expect(
        (result['attempts'] as List).first['failureStage'],
        'response_body',
      );
      await Future.wait(aborts);
    },
  );

  test(
    'image body timeouts abort without making a third provider attempt',
    () async {
      final aborts = <Future<void>>[];
      final hosts = <String>[];
      final result = await _imageSearch(
        MockClient.streaming((request, _) async {
          hosts.add(request.url.host);
          aborts.add((request as http.AbortableRequest).abortTrigger!);
          return http.StreamedResponse(
            (() async* {
              yield utf8.encode('partial');
              await Future<void>.delayed(const Duration(milliseconds: 40));
              yield utf8.encode('end');
            })(),
            200,
          );
        }),
        timeout: const Duration(milliseconds: 10),
      );
      expect(hosts, ['cn.bing.com', 'commons.wikimedia.org']);
      expect(result['status'], 'failed');
      expect(result['reason'], 'all_providers_timed_out');
      expect((result['attempts'] as List).map((e) => e['failureStage']), [
        'response_body',
        'response_body',
      ]);
      await Future.wait(aborts);
    },
  );

  test(
    'overseas token and image JSON share one provider time budget',
    () async {
      final hosts = <String>[];
      const budget = Duration(milliseconds: 500);
      final skill = WebSearchSkill(
        networkRegionProvider: () => NetworkRegionService.fallback,
        searchTimeout: budget,
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'commons.wikimedia.org') {
            return http.Response(_commonsResult(), 200);
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response(
            request.url.path == '/'
                ? 'vqd="3-12345-67"'
                : jsonEncode({
                    'results': [
                      {'image': 'https://images.example.org/cat.jpg'},
                    ],
                  }),
            200,
          );
        }),
      );
      final result = jsonDecode(
        await skill.methods['imageSearch']!(['cat images', 1]) as String,
      );
      expect(hosts, [
        'duckduckgo.com',
        'duckduckgo.com',
        'commons.wikimedia.org',
      ]);
      expect(result['status'], 'ok');
      expect(result['source'], 'wikimedia_commons');
      final attempts = result['attempts'] as List;
      expect(attempts.first['error'], 'timeout');
      expect(attempts.first['failureStage'], 'response_headers');
      expect(attempts.first['timeoutMs'], 500);
      expect(attempts.first['elapsedMs'], greaterThanOrEqualTo(500));
      expect(attempts.last['timeoutMs'], 500);
    },
  );

  test(
    'preview rejects private URLs and cancels oversized image streams',
    () async {
      var sends = 0;
      final aborts = <Future<void>>[];
      final skill = WebSearchSkill(
        httpClient: MockClient.streaming((request, _) async {
          sends++;
          aborts.add((request as http.AbortableRequest).abortTrigger!);
          expect(request.followRedirects, isFalse);
          return http.StreamedResponse(
            Stream.value(List.filled(700 * 1024 + 1, 1)),
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final results = await skill.attachImagePreviewsForTest([
        {'url': 'http://localhost/image.png'},
        {'url': 'https://images.example.org/oversized.png'},
      ]);
      expect(sends, 1);
      expect(results, isEmpty);
      await Future.wait(aborts);
    },
  );
}

String _bingImages(List<Map<String, String>> items) => items
    .map(
      (item) =>
          '<a class="iusc" m="${const HtmlEscape(HtmlEscapeMode.attribute).convert(jsonEncode(item))}"></a>',
    )
    .join();

String _commonsResult() => jsonEncode({
  'query': {
    'pages': {
      '1': {
        'title': 'File:Cat.jpg',
        'imageinfo': [
          {'url': 'https://upload.wikimedia.org/cat.jpg', 'mime': 'image/jpeg'},
        ],
      },
    },
  },
});

Future<Map<String, dynamic>> _imageSearch(
  http.Client client, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final skill = WebSearchSkill(
    httpClient: client,
    searchTimeout: timeout,
    networkRegionProvider: () => const NetworkRegionResolution(
      region: NetworkRegion.mainlandChina,
      source: NetworkRegionSource.authorizedLocation,
    ),
  );
  return jsonDecode(
        await skill.methods['imageSearch']!(['cat images', 1]) as String,
      )
      as Map<String, dynamic>;
}
