import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/features/agent/application/skills/web_search_skill.dart';

const _ddgResult = '''<div class="result web-result">
<a href="https://example.org/current?x=1&amp;y=2" class="external result__a">Current &amp; relevant</a>
<div class="result__snippet">A <b>fresh</b> result.</div></div>''';
const _emptyDdg = '<div class="no-results"><h1>No results found</h1></div>';

String _rss(String items) => '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title>Search</title>
<link>https://www.bing.com/search</link><description>Web results</description>
$items</channel></rss>''';

String _item({
  String title = 'Fresh result',
  String url = 'https://example.org/current',
  String description = 'Current source summary',
}) =>
    '<item><title>$title</title><link>$url</link>'
    '<description>$description</description></item>';

Future<Map<String, dynamic>> _search(
  http.Client client, {
  String query = 'Shanghai weather today',
  Duration timeout = const Duration(seconds: 8),
  List<dynamic>? args,
  AppLocale locale = AppLocale.en,
  NetworkRegionResolution region = NetworkRegionService.fallback,
}) async {
  final skill = WebSearchSkill(
    httpClient: client,
    searchTimeout: timeout,
    now: () => DateTime.utc(2026, 10, 14, 9),
    networkRegionProvider: () => region,
  );
  final raw = await AgentPromptCatalog.runWithLocale(
    locale,
    () => skill.methods['webSearch']!(args ?? [query]),
  );
  return jsonDecode(raw as String) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'text search parses attribute order and class lists with source metadata',
    () async {
      var requests = 0;
      final result = await _search(
        MockClient((request) async {
          requests++;
          expect(request.url.host, 'html.duckduckgo.com');
          expect(request.url.queryParameters['q'], 'Shanghai weather today');
          return http.Response(_ddgResult, 200);
        }),
      );
      expect(requests, 1);
      expect(result['status'], 'ok');
      expect(result['source'], 'duckduckgo');
      expect(result['query'], 'Shanghai weather today');
      expect(result['searchedAtUtc'], '2026-10-14T09:00:00.000Z');
      expect(result['results'], [
        {
          'title': 'Current & relevant',
          'url': 'https://example.org/current?x=1&y=2',
          'snippet': 'A fresh result.',
        },
      ]);
    },
  );

  test(
    'missing snippets remain usable and target escapes are not decoded twice',
    () async {
      const target = 'https://example.org/a%2Fb?q=x%26y';
      final html =
          '<div class="result"><a class="result__a" href="'
          '//duckduckgo.com/l/?uddg=${Uri.encodeQueryComponent(target)}&amp;rut=abc'
          '">Target</a></div>';
      final result = await _search(
        MockClient((_) async => http.Response(html, 200)),
      );
      expect((result['results'] as List).single, {
        'title': 'Target',
        'url': target,
        'snippet': '',
      });
    },
  );

  for (final status in [200, 202]) {
    test(
      'HTTP $status challenge falls back once to public RSS search',
      () async {
        final hosts = <String>[];
        final result = await _search(
          MockClient((request) async {
            hosts.add(request.url.host);
            if (request.url.host == 'html.duckduckgo.com') {
              return http.Response('<form id="challenge-form"></form>', status);
            }
            expect(request.url.queryParameters['format'], 'rss');
            expect(request.url.queryParameters['q'], 'Shanghai weather today');
            return http.Response(_rss(_item()), 200);
          }),
        );
        expect(hosts, ['html.duckduckgo.com', 'www.bing.com']);
        expect(result['status'], 'ok');
        expect(result['source'], 'bing_rss');
        expect(
          (result['attempts'] as List).first,
          containsPair('error', 'challenge'),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair('httpStatus', status),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair(
            'failureStage',
            status == 202 ? 'response_headers' : 'parse',
          ),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair('timeoutMs', 8000),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair('sourceHost', 'html.duckduckgo.com'),
        );
        expect(
          (result['attempts'] as List).first['elapsedMs'],
          greaterThanOrEqualTo(0),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair('source', 'duckduckgo'),
        );
        expect(
          (result['attempts'] as List).first,
          containsPair('status', 'failed'),
        );
      },
    );
  }

  test(
    'known empty results try fallback, and successful empty feeds are honest',
    () async {
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com' ? _emptyDdg : _rss(''),
            200,
          ),
        ),
      );
      expect(result['status'], 'no_results');
      expect(result['note'], 'no_results');
      expect(result['results'], isEmpty);
      expect((result['attempts'] as List).map((e) => e['status']), [
        'no_results',
        'no_results',
      ]);
      expect(result.containsKey('error'), isFalse);
    },
  );

  test(
    'HTML layout changes and malformed XML are parse failures, not empty results',
    () async {
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com'
                ? '<html><p>Unexpected response</p></html>'
                : '<rss><channel><item>',
            200,
          ),
        ),
      );
      expect(result['status'], 'failed');
      expect(result['error'], 'search_failed');
      expect((result['attempts'] as List).map((e) => e['error']), [
        'parse_error',
        'parse_error',
      ]);
      expect(result.containsKey('note'), isFalse);
    },
  );

  test('HTTP and rate limit causes survive failed providers', () async {
    final result = await _search(
      MockClient(
        (request) async => http.Response(
          'Temporarily unavailable',
          request.url.host == 'html.duckduckgo.com' ? 503 : 429,
        ),
      ),
    );
    expect(result['status'], 'failed');
    expect((result['attempts'] as List).map((e) => e['error']), [
      'http_error',
      'rate_limited',
    ]);
    expect((result['attempts'] as List).map((e) => e['httpStatus']), [
      503,
      429,
    ]);
  });

  test('timeout falls back and network failure remains diagnosable', () async {
    final result = await _search(
      MockClient((request) async {
        if (request.url.host == 'html.duckduckgo.com') {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response(_ddgResult, 200);
        }
        throw http.ClientException('offline');
      }),
      timeout: const Duration(milliseconds: 2),
    );
    expect(result['status'], 'failed');
    expect((result['attempts'] as List).map((e) => e['error']), [
      'timeout',
      'network_error',
    ]);
    expect((result['attempts'] as List).map((e) => e['failureStage']), [
      'response_headers',
      'response_headers',
    ]);
    expect(result['reason'], 'providers_failed');
  });

  test(
    'first timeout leaves the fallback its own full request budget',
    () async {
      const budget = Duration(milliseconds: 80);
      final result = await _search(
        MockClient((request) async {
          if (request.url.host == 'html.duckduckgo.com') {
            await Completer<void>().future;
          }
          // More than half of the complete budget remains usable by source two.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(_rss(_item()), 200);
        }),
        timeout: budget,
      );
      expect(result['status'], 'ok');
      expect(result['sourceHost'], 'www.bing.com');
      final attempts = result['attempts'] as List;
      expect(attempts.first['error'], 'timeout');
      expect(attempts.first['failureStage'], 'response_headers');
      expect(attempts.last['status'], 'ok');
      expect(attempts.map((e) => e['timeoutMs']), [80, 80]);
      expect(attempts.first['elapsedMs'], greaterThanOrEqualTo(80));
      expect(attempts.last['elapsedMs'], greaterThanOrEqualTo(50));
    },
  );

  test(
    'both header timeouts retain two independent diagnostic records',
    () async {
      final result = await _search(
        MockClient((_) async {
          await Completer<void>().future;
          return http.Response('', 200);
        }),
        timeout: const Duration(milliseconds: 15),
      );
      expect(result['status'], 'failed');
      expect(result['error'], 'search_failed');
      expect(result['reason'], 'all_providers_timed_out');
      final attempts = result['attempts'] as List;
      expect(attempts, hasLength(2));
      for (final attempt in attempts) {
        expect(attempt['error'], 'timeout');
        expect(attempt['failureStage'], 'response_headers');
        expect(attempt['timeoutMs'], 15);
        expect(attempt['elapsedMs'], greaterThanOrEqualTo(15));
        expect(attempt.containsKey('httpStatus'), isFalse);
      }
    },
  );

  test(
    'body timeout preserves received status and differs from header timeout',
    () async {
      final aborts = <Future<void>>[];
      final result = await _search(
        MockClient.streaming((request, _) async {
          expect(request.followRedirects, isFalse);
          aborts.add((request as http.AbortableRequest).abortTrigger!);
          if (request.url.host == 'html.duckduckgo.com') {
            return http.StreamedResponse(
              (() async* {
                yield utf8.encode('<html>');
                await Future<void>.delayed(const Duration(milliseconds: 40));
                yield utf8.encode('</html>');
              })(),
              200,
            );
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(_rss(_item()))),
            200,
          );
        }),
        timeout: const Duration(milliseconds: 10),
      );
      expect(result['status'], 'ok');
      final attempt = (result['attempts'] as List).first;
      expect(attempt['error'], 'timeout');
      expect(attempt['failureStage'], 'response_body');
      expect(attempt['httpStatus'], 200);
      await Future.wait(aborts);
    },
  );

  for (final locale in AppLocale.values) {
    for (final query in ['深圳 今日天气', 'Shenzhen weather today']) {
      for (final region in NetworkRegion.values) {
        test(
          'provider order depends on region, not language: $region/$locale/$query',
          () async {
            final mainland = region == NetworkRegion.mainlandChina;
            final hosts = <String>[];
            final result = await _search(
              MockClient((request) async {
                hosts.add(request.url.host);
                // First provider has no results, second returns a usable source.
                if (hosts.length == 1) {
                  return http.Response(mainland ? _rss('') : _emptyDdg, 200);
                }
                return http.Response(
                  mainland ? _ddgResult : _rss(_item()),
                  200,
                );
              }),
              query: query,
              locale: locale,
              region: NetworkRegionResolution(
                region: region,
                source: NetworkRegionSource.authorizedLocation,
              ),
            );
            expect(
              hosts,
              mainland
                  ? ['cn.bing.com', 'html.duckduckgo.com']
                  : ['html.duckduckgo.com', 'www.bing.com'],
            );
            expect(
              result['networkRegion'],
              mainland ? 'china_mainland' : 'overseas',
            );
            expect(result['regionSource'], 'authorized_location');
            for (final attempt in result['attempts'] as List) {
              expect(attempt['networkRegion'], result['networkRegion']);
              expect(attempt['regionSource'], 'authorized_location');
            }
            expect(result['status'], 'ok');
          },
        );
      }
    }
  }

  test('mainland usable RSS never sends an overseas-first request', () async {
    final hosts = <String>[];
    final result = await _search(
      MockClient((request) async {
        hosts.add(request.url.host);
        expect(request.url.queryParameters['format'], 'rss');
        return http.Response(_rss(_item()), 200);
      }),
      region: const NetworkRegionResolution(
        region: NetworkRegion.mainlandChina,
        source: NetworkRegionSource.authorizedLocation,
      ),
    );
    expect(hosts, ['cn.bing.com']);
    expect(result['source'], 'bing_rss');
    expect(result['regionSource'], 'authorized_location');
  });

  test(
    'one request pins region even when automatic country changes during fallback',
    () async {
      var region = const NetworkRegionResolution(
        region: NetworkRegion.mainlandChina,
        source: NetworkRegionSource.authorizedLocation,
      );
      var resolves = 0;
      final hosts = <String>[];
      final skill = WebSearchSkill(
        networkRegionProvider: () {
          resolves++;
          return region;
        },
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          if (hosts.length == 1) {
            region = NetworkRegionService.fallback;
            return http.Response('blocked', 403);
          }
          return http.Response(_ddgResult, 200);
        }),
      );
      final result = jsonDecode(
        await skill.methods['webSearch']!(['news today']) as String,
      );
      expect(resolves, 1);
      expect(hosts, ['cn.bing.com', 'html.duckduckgo.com']);
      expect(result['networkRegion'], 'china_mainland');
      expect(
        (result['attempts'] as List).last['regionSource'],
        'authorized_location',
      );
    },
  );

  test('missing region service uses a synchronous safe fallback', () async {
    expect(appServices.isRegistered<NetworkRegionService>(), isFalse);
    final skill = WebSearchSkill(
      httpClient: MockClient((request) async {
        expect(request.url.host, 'html.duckduckgo.com');
        return http.Response(_ddgResult, 200);
      }),
    );
    final result = jsonDecode(
      await skill.methods['webSearch']!(['news today']) as String,
    );
    expect(result['networkRegion'], 'overseas');
    expect(result['regionSource'], 'default');
  });

  test(
    'default skill reevaluates automatic country for each next request',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var country = 'CN';
      final service =
          await NetworkRegionService(
            deviceCountryCodeSupplier: () => country,
          ).init(
            scope: AccountStorageScope(
              environmentKey: 'test',
              accountUuid: 'regional-search',
            ),
          );
      appServices.put<NetworkRegionService>(service);
      addTearDown(() => appServices.delete<NetworkRegionService>(force: true));
      final hosts = <String>[];
      final skill = WebSearchSkill(
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response(
            request.url.host == 'cn.bing.com' ? _rss(_item()) : _ddgResult,
            200,
          );
        }),
      );
      Future<Map<String, dynamic>> run() async =>
          jsonDecode(
                await skill.methods['webSearch']!(['news today']) as String,
              )
              as Map<String, dynamic>;
      expect((await run())['regionSource'], 'device_locale');
      country = 'US';
      expect((await run())['regionSource'], 'device_locale');
      await service.deactivateAndDrain();
      expect((await run())['regionSource'], 'default');
      final nextOwner =
          await NetworkRegionService(
            deviceCountryCodeSupplier: () => 'CN',
          ).init(
            scope: AccountStorageScope(
              environmentKey: 'test',
              accountUuid: 'next-owner',
            ),
          );
      appServices.put<NetworkRegionService>(nextOwner, overrideAbstract: true);
      expect(
        (await run())['regionSource'],
        'default',
        reason: 'retired Skill must not borrow a new account region service',
      );
      final nextSkill = WebSearchSkill(
        httpClient: MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response(_rss(_item()), 200);
        }),
      );
      final nextResult = jsonDecode(
        await nextSkill.methods['webSearch']!(['news today']) as String,
      );
      expect(nextResult['regionSource'], 'device_locale');
      expect(hosts, [
        'cn.bing.com',
        'html.duckduckgo.com',
        'html.duckduckgo.com',
        'html.duckduckgo.com',
        'cn.bing.com',
      ]);
    },
  );

  for (final region in NetworkRegion.values) {
    test('alternate selects only fixed second source for $region', () async {
      final hosts = <String>[];
      final mainland = region == NetworkRegion.mainlandChina;
      final result = await _search(
        MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response(mainland ? _ddgResult : _rss(_item()), 200);
        }),
        region: NetworkRegionResolution(
          region: region,
          source: NetworkRegionSource.authorizedLocation,
        ),
        args: [
          {'query': 'current news', 'maxResults': 1, 'source': 'alternate'},
        ],
      );
      expect(hosts, mainland ? ['html.duckduckgo.com'] : ['www.bing.com']);
      expect(result['sourceSelection'], 'alternate');
      expect(result['source'], mainland ? 'duckduckgo' : 'bing_rss');
      expect(result['status'], 'ok');
      expect(result['results'], hasLength(1));
      expect(
        (result['attempts'] as List).single['sourceSelection'],
        'alternate',
      );
    });
  }

  for (final args in [
    [
      jsonEncode({
        'query': 'current news',
        'source': 'alternate',
        'maxResults': 1,
      }),
    ],
    ['current news', 1, 'alternate'],
  ]) {
    test(
      'alternate supports native JSON and positional compatibility: $args',
      () async {
        final result = await _search(
          MockClient((request) async {
            expect(request.url.host, 'www.bing.com');
            return http.Response(_rss(_item()), 200);
          }),
          args: args,
        );
        expect(result['sourceSelection'], 'alternate');
        expect(result['source'], 'bing_rss');
        expect(result['results'], hasLength(1));
      },
    );
  }

  test('alternate failure does not loop back to the primary source', () async {
    var requests = 0;
    final result = await _search(
      MockClient((request) async {
        requests++;
        expect(request.url.host, 'www.bing.com');
        return http.Response('unavailable', 503);
      }),
      args: [
        {'query': 'current news', 'source': 'alternate'},
      ],
    );
    expect(requests, 1);
    expect(result['status'], 'failed');
    expect(result['sourceSelection'], 'alternate');
    expect((result['attempts'] as List).single['error'], 'http_error');
  });

  for (final source in [
    'https://arbitrary.example',
    'localhost',
    '',
    'unknown',
  ]) {
    test(
      'source selector cannot become an arbitrary network host: $source',
      () async {
        final result = await _search(
          MockClient((_) async => fail('invalid source must not send')),
          args: [
            {'query': 'current news', 'source': source},
          ],
        );
        expect(result['status'], 'failed');
        expect(result['error'], 'invalid_source');
        expect(result['results'], isEmpty);
      },
    );
  }

  test(
    'explicit primary retains the existing fallback order and metadata',
    () async {
      final hosts = <String>[];
      final result = await _search(
        MockClient((request) async {
          hosts.add(request.url.host);
          return http.Response(
            request.url.host == 'html.duckduckgo.com'
                ? _emptyDdg
                : _rss(_item()),
            200,
          );
        }),
        args: [
          {'query': 'current news', 'source': 'primary'},
        ],
      );
      expect(hosts, ['html.duckduckgo.com', 'www.bing.com']);
      expect(result['sourceSelection'], 'primary');
      expect((result['attempts'] as List).map((e) => e['sourceSelection']), [
        'primary',
        'primary',
      ]);
    },
  );

  test(
    'public tool schemas expose bounded page reading and regional alternate only',
    () {
      final skill = WebSearchSkill();
      expect(
        skill.methods.keys,
        containsAll(['webSearch', 'imageSearch', 'readPage']),
      );
      final search = skill.nativeToolSchemas!['webSearch']!;
      expect(search['required'], ['query']);
      expect(search['properties']['source']['enum'], ['primary', 'alternate']);
      final page = skill.nativeToolSchemas!['readPage']!;
      expect(page['required'], ['url']);
      expect(page['properties']['maxChars']['maximum'], 20000);
      expect(page['properties']['url']['maxLength'], 2048);
      expect(
        skill.nativeMethodDescriptions['readPage'],
        contains('untrusted data'),
      );
    },
  );

  test(
    'RSS is data only: entities, HTML, unsafe URLs and duplicates are handled',
    () async {
      final items = [
        _item(
          title: 'Fresh &amp; useful',
          description: '<![CDATA[<b>Now</b><script>bad()</script>]]>',
        ),
        _item(),
        _item(url: 'javascript:alert(1)'),
        _item(url: 'file:///private/secret'),
        _item(url: 'https://user:password@example.org/'),
        _item(url: 'http://127.0.0.1/'),
        _item(url: 'http://localhost/'),
        _item(url: 'http://printer.local/'),
        _item(url: 'https://another.example/current', title: 'Other'),
      ].join();
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com' ? _emptyDdg : _rss(items),
            200,
          ),
        ),
      );
      expect(result['status'], 'ok');
      expect(result['results'], [
        {
          'title': 'Fresh & useful',
          'url': 'https://example.org/current',
          'snippet': 'Now',
        },
        {
          'title': 'Other',
          'url': 'https://another.example/current',
          'snippet': 'Current source summary',
        },
      ]);
    },
  );

  test(
    'RSS DTD or entity declarations are rejected without external resolution',
    () async {
      final hosts = <String>[];
      final result = await _search(
        MockClient((request) async {
          hosts.add(request.url.host);
          if (request.url.host == 'html.duckduckgo.com') {
            return http.Response('blocked', 403);
          }
          return http.Response(
            '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///private/secret">]>'
            '${_rss(_item(title: '&x;'))}',
            200,
          );
        }),
      );
      expect(hosts, ['html.duckduckgo.com', 'www.bing.com']);
      expect(result['status'], 'failed');
      expect((result['attempts'] as List).last['error'], 'invalid_response');
    },
  );

  test(
    'only invalid RSS links are a parser failure, never usable results',
    () async {
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com'
                ? '<html>Changed</html>'
                : _rss(_item(url: 'javascript:alert(1)')),
            200,
          ),
        ),
      );
      expect(result['status'], 'failed');
      expect((result['attempts'] as List).last['error'], 'parse_error');
    },
  );

  test('oversized provider responses are bounded and fall back', () async {
    final result = await _search(
      MockClient(
        (request) async => http.Response(
          request.url.host == 'html.duckduckgo.com'
              ? 'x' * (2 * 1024 * 1024 + 1)
              : _rss(_item()),
          200,
        ),
      ),
    );
    expect(result['status'], 'ok');
    expect(result['source'], 'bing_rss');
    expect((result['attempts'] as List).first['error'], 'response_too_large');
  });

  test(
    'query objects and maxResults preserve the native tool argument contract',
    () async {
      final items = List.generate(
        5,
        (i) => _item(url: 'https://example.org/$i'),
      ).join();
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com' ? _emptyDdg : _rss(items),
            200,
          ),
        ),
        args: [
          {'query': ' current news ', 'maxResults': 2},
        ],
      );
      expect(result['query'], 'current news');
      expect(result['results'], hasLength(2));
    },
  );

  test(
    'result title, snippet and URL lengths are bounded independently',
    () async {
      final items =
          _item(title: 't' * 1000, description: 's' * 3000) +
          _item(url: 'https://example.org/${'a' * 3000}');
      final result = await _search(
        MockClient(
          (request) async => http.Response(
            request.url.host == 'html.duckduckgo.com' ? _emptyDdg : _rss(items),
            200,
          ),
        ),
      );
      final results = result['results'] as List;
      expect(results, hasLength(1));
      expect(results.single['title'].length, 300);
      expect(results.single['snippet'].length, 1500);
      expect(results.single['url'].length, lessThanOrEqualTo(2048));
    },
  );

  test('empty queries do not send network requests', () async {
    final client = MockClient((_) async => fail('must not send'));
    expect((await _search(client, args: []))['error'], 'missing_query');
    expect((await _search(client, args: [' ']))['error'], 'empty_query');
  });

  test(
    'English image intent uses complete words and retains Chinese image queries',
    () {
      for (final query in [
        'Olympic latest news',
        'current topic',
        'epic game price',
        'imageology definition',
      ]) {
        expect(WebSearchSkill.isImageQuery(query), isFalse, reason: query);
      }
      for (final query in [
        'cute dog pics',
        'a photo of clouds',
        'find IMAGES',
        '上海图片',
      ]) {
        expect(WebSearchSkill.isImageQuery(query), isTrue, reason: query);
      }
    },
  );
}
