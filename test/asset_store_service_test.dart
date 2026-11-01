import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/features/store/presentation/store_asset_detail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_preview.dart';

Map<String, Object?> assetJson({
  String id = 'wave',
  String version = '1',
  String type = 'skill',
}) => {
  'id': id,
  'type': type,
  'versionId': version,
  'title': 'Wave',
  'summary': 'A friendly wave',
  'coverUrl': '',
  'listed': true,
  'examples': <String>[],
  'preview': {'state': 'unavailable'},
  'popularity': {
    'metric': type == 'skill' ? 'active_installations' : 'current_selections',
    'value': 0,
  },
  'ownership': {'created': false, 'bundled': true},
  'sourceRef': type == 'skill'
      ? {'skillVersionId': int.parse(version)}
      : {'modelId': int.parse(id), 'expectedAssetVersionDigest': version},
};
http.Response ok(Object value) =>
    http.Response(jsonEncode({'code': 'OK', 'data': value}), 200);
void main() {
  test('catalog accepts models and skills and rejects action products', () {
    expect(StoreAsset.fromJson(assetJson()).type, 'skill');
    expect(
      StoreAsset.fromJson(
        assetJson(id: '7', version: 'a' * 64, type: 'model'),
      ).type,
      'model',
    );
    expect(
      () => StoreAsset.fromJson({...assetJson(), 'type': 'motion'}),
      throwsFormatException,
    );
    expect(
      () => StoreAsset.fromJson({
        ...assetJson(),
        'preview': {
          'state': 'available',
          'source': 'builtin',
          'assetPath': 'assets/motion_previews/v1/wave.mp4',
          'packVersion': 1,
        },
      }),
      throwsFormatException,
    );
  });
  test(
    'stale directory drops only retired action rows and keeps pagination',
    () {
      final page = StoreAssetPage.fromJson({
        'schemaVersion': 1,
        'items': [
          {'type': 'motion'},
          assetJson(),
          assetJson(id: '7', version: 'a' * 64, type: 'model'),
        ],
        'nextCursor': 'next',
      });
      expect(page.items.map((item) => item.type), ['skill', 'model']);
      expect(page.nextCursor, 'next');
      expect(() => page.items.clear(), throwsUnsupportedError);
      for (final invalid in [
        {'type': 'unrecognized'},
        {'type': 'skill'},
        null,
      ]) {
        expect(
          () => StoreAssetPage.fromJson({
            'schemaVersion': 1,
            'items': [invalid],
          }),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'retired action requests never acquire credentials or call the API',
    () async {
      var requests = 0;
      var tokens = 0;
      final service = AssetStoreService(
        client: MockClient((_) async {
          requests++;
          return http.Response('', 404);
        }),
        baseUri: () => Uri.parse('https://api.example/'),
        token: () async {
          tokens++;
          return 'access';
        },
        scope: () => 'a',
      );
      for (final workshop in [false, true]) {
        await expectLater(
          service.list(type: 'motion', workshop: workshop),
          throwsA(
            isA<AssetStoreException>()
                .having(
                  (error) => error.code,
                  'code',
                  'asset_store_invalid_type',
                )
                .having(
                  (error) => error.isUnsupported,
                  'legacy fallback',
                  false,
                ),
          ),
        );
      }
      expect(requests, 0);
      expect(tokens, 0);
    },
  );
  test('strict immutable projection rejects wrong units, source versions', () {
    final raw = assetJson();
    final item = StoreAsset.fromJson(raw);
    (raw['popularity'] as Map)['value'] = 8;
    expect(item.popularity['value'], 0);
    expect(() => item.popularity['value'] = 1, throwsUnsupportedError);
    for (final invalid in [
      {
        ...assetJson(),
        'popularity': {'metric': 'current_selections', 'value': 1},
      },
      {
        ...assetJson(),
        'sourceRef': {'skillVersionId': 2},
      },
      {
        ...assetJson(),
        'preview': {
          'state': 'available',
          'kind': 'gif',
          'url': 'http://cdn.example/p.gif',
          'sha256': 'a' * 64,
        },
      },
    ]) {
      expect(() => StoreAsset.fromJson(invalid), throwsFormatException);
    }
  });
  test(
    'list pins type locale sort and cursor without account query overrides',
    () async {
      final service = AssetStoreService(
        client: MockClient((request) async {
          expect(request.url.path, '/v1/asset-store/assets');
          expect(request.headers['Authorization'], 'Bearer access');
          expect(request.url.queryParameters, {
            'type': 'skill',
            'query': 'wave',
            'sort': 'popular',
            'locale': 'zh',
            'limit': '30',
            'cursor': 'next',
            'platform': 'ios',
            'builtinCatalogVersion': '$avatarBuiltinCatalogVersion',
          });
          return ok({
            'schemaVersion': 1,
            'items': [assetJson()],
            'nextCursor': 'after',
          });
        }),
        baseUri: () => Uri.parse('https://api.example/'),
        token: () async => 'access',
        scope: () => 'a',
      );
      final page = await service.list(
        type: 'skill',
        query: 'wave',
        locale: 'zh',
        cursor: 'next',
        platform: 'ios',
      );
      expect(page.items.single.id, 'wave');
      expect(page.nextCursor, 'after');
    },
  );
  test('response after account switch is discarded', () async {
    final response = Completer<http.Response>();
    var scope = 'a';
    final service = AssetStoreService(
      client: MockClient((_) => response.future),
      baseUri: () => Uri.parse('https://api.example/'),
      token: () async => 'access',
      scope: () => scope,
    );
    final future = service.list(type: 'skill');
    final assertion = expectLater(
      future,
      throwsA(
        isA<AssetStoreException>().having(
          (e) => e.code,
          'code',
          'asset_store_scope_changed',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    scope = 'b';
    response.complete(
      ok({
        'schemaVersion': 1,
        'items': [assetJson()],
      }),
    );
    await assertion;
  });
  test(
    'detail never silently resolves a newer version; 409 is actionable',
    () async {
      final service = AssetStoreService(
        client: MockClient((request) async {
          expect(request.url.queryParameters['versionId'], '1');
          expect(
            request.url.queryParameters['builtinCatalogVersion'],
            '$avatarBuiltinCatalogVersion',
          );
          return ok(assetJson(version: '2'));
        }),
        baseUri: () => Uri.parse('https://api.example/'),
        token: () async => 'access',
        scope: () => 'a',
      );
      await expectLater(
        service.detail(StoreAsset.fromJson(assetJson())),
        throwsA(
          isA<AssetStoreException>().having(
            (e) => e.isConflict,
            'conflict',
            true,
          ),
        ),
      );
    },
  );
  test(
    'retired action detail is rejected without triggering legacy fallback',
    () async {
      final service = AssetStoreService(
        client: MockClient((_) async => ok({'type': 'motion'})),
        baseUri: () => Uri.parse('https://api.example/'),
        token: () async => 'access',
        scope: () => 'a',
      );
      await expectLater(
        service.detail(StoreAsset.fromJson(assetJson())),
        throwsFormatException,
      );
    },
  );
  test('model and skill preview receipts remain version-bound', () async {
    var requests = 0;
    final service = AssetStoreService(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(request.method, 'POST');
        expect(request.headers['Authorization'], 'Bearer access');
        expect(body['eventId'], 'event');
        expect(body['completed'], true);
        expect(body.containsKey('previewSha256'), false);
        expect(request.url.path.contains('/motion/'), false);
        requests++;
        return ok({'recorded': true});
      }),
      baseUri: () => Uri.parse('https://api.example/'),
      token: () async => 'access',
      scope: () => 'a',
    );
    await service.recordPreview(StoreAsset.fromJson(assetJson()), 'event');
    await service.recordPreview(
      StoreAsset.fromJson(assetJson(id: '7', version: 'a' * 64, type: 'model')),
      'event',
    );
    expect(requests, 2);
  });
  test(
    'media has no credentials, refuses redirects and checks exact sha',
    () async {
      final bytes = [71, 73, 70, 56, 57, 97];
      final item = StoreAsset.fromJson({
        ...assetJson(),
        'preview': {
          'state': 'available',
          'kind': 'gif',
          'url': 'https://cdn.example/wave.gif',
          'sha256': sha256.convert(bytes).toString(),
        },
      });
      expect(
        await fetchStorePreview(
          item,
          client: MockClient((request) async {
            expect(request.headers.containsKey('Authorization'), false);
            expect(request.followRedirects, false);
            return http.Response.bytes(bytes, 200);
          }),
        ),
        bytes,
      );
      await expectLater(
        fetchStorePreview(
          item,
          client: MockClient((_) async => http.Response('bad', 200)),
        ),
        throwsFormatException,
      );
      await expectLater(
        fetchStorePreview(
          item,
          client: MockClient(
            (_) async => http.Response(
              '',
              302,
              headers: {'location': 'https://elsewhere.example'},
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'bundled artwork uses strict registry identity, never a lookalike name',
    () {
      final model = <String, Object?>{
        'id': 7,
        'modelKey': BundledAvatarContract.mattModelKey,
        'modelSource': 'official',
        'displayName': 'Matt',
        'assetUrl': BundledAvatarContract.mattAssetUrl,
        'assetSha256': BundledAvatarContract.mattAssetSha256,
        'runtimeConfig': BundledAvatarContract.mattRuntimeConfig,
        'compatibility': {
          'backends': ['unity'],
        },
      };
      StoreAsset item(Map<String, Object?> descriptor) => StoreAsset.fromJson({
        ...assetJson(id: '7', version: 'a' * 64, type: 'model'),
        'sourceRef': {
          'modelId': 7,
          'expectedAssetVersionDigest': 'a' * 64,
          'model': descriptor,
        },
      });
      expect(
        storeAssetLocalArtwork(item(model)),
        BundledAvatarContract.mattPreviewAsset,
      );
      expect(
        storeAssetLocalArtwork(item({...model, 'assetSha256': 'b' * 64})),
        isNull,
      );
      expect(
        storeAssetLocalArtwork(item({...model, 'modelKey': 'masso.other'})),
        isNull,
      );
    },
  );
}
