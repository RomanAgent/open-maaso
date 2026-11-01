import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/security/trusted_media_asset_policy.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/creator/data/image_generation_gateway.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'maaso-creator-image-',
    );
  });

  tearDown(() async {
    await appServices.reset();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'durable download uses account directory and validates again before apply',
    () async {
      final png = Uint8List.fromList(
        image.encodePng(image.Image(width: 2, height: 3)),
      );
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response.bytes(
            png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      );
      final artifact = CreatorTaskArtifact(
        assetId: 'durable_image',
        sha256: sha256.convert(png).toString(),
        contentType: 'image/png',
        bytes: png.length,
        width: 2,
        height: 3,
      );
      final scope = gateway.requestContextKey;
      final asset = await gateway.downloadTaskAsset(
        artifact: artifact,
        assetUrl: Uri.parse('https://cdn.example.com/image.png'),
        expectedContextKey: scope,
        canContinue: () => true,
      );
      expect(
        asset.localPath,
        contains(sha256.convert(utf8.encode(scope)).toString()),
      );
      expect(
        await gateway.validateTaskAsset(
          asset,
          artifact,
          expectedContextKey: scope,
          canContinue: () => true,
        ),
        isTrue,
      );
      await File(asset.localPath).writeAsBytes([1, 2, 3]);
      expect(
        await gateway.validateTaskAsset(
          asset,
          artifact,
          expectedContextKey: scope,
          canContinue: () => true,
        ),
        isFalse,
      );
      gateway.cancelPendingTaskDownloads();
      await expectLater(
        () => gateway.downloadTaskAsset(
          artifact: artifact,
          assetUrl: Uri.parse('https://cdn.example.com/image.png'),
          expectedContextKey: scope,
          canContinue: () => true,
        ),
        throwsA(anything),
      );
    },
  );

  test(
    'production gateway is disabled by default and sends no request',
    () async {
      var requestCount = 0;
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((_) async {
          requestCount++;
          return http.Response('{}', 500);
        }),
        available: null,
      );

      expect(gateway.isAvailable, isFalse);
      await expectLater(
        gateway.generate(
          prompt: 'A tiny warm city',
          aspectRatio: '1:1',
          style: 'cinematic',
          idempotencyKey: 'creator_backend_not_ready',
          expectedContextKey: gateway.requestContextKey,
        ),
        throwsA(
          isA<CreatorImageRequestException>()
              .having((error) => error.code, 'code', 'backend_not_ready')
              .having((error) => error.statusCode, 'statusCode', 0),
        ),
      );
      expect(requestCount, 0);
    },
  );

  test('downloads and verifies a bounded trusted generated image', () async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 2, height: 3)),
    );
    final gateway = await _gateway(
      temporaryDirectory,
      MockClient((request) async {
        if (request.method == 'POST') {
          return _generationResponse(png, width: 2, height: 3);
        }
        expect(request.url.host, 'cdn.example.com');
        return http.Response.bytes(
          png,
          200,
          headers: <String, String>{
            'content-type': 'image/png',
            'content-length': '${png.length}',
          },
        );
      }),
    );

    final asset = await gateway.generate(
      prompt: 'A tiny warm city',
      aspectRatio: '4:5',
      style: 'cinematic',
      idempotencyKey: 'creator_valid_asset',
      expectedContextKey: gateway.requestContextKey,
    );

    expect(asset.width, 2);
    expect(asset.height, 3);
    expect(await File(asset.localPath).readAsBytes(), png);
  });

  test('rejects an asset redirect before leaving the trusted host', () async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 2, height: 3)),
    );
    var assetRequestSeen = false;
    final gateway = await _gateway(
      temporaryDirectory,
      MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.maxRedirects, 0);
        if (request.method == 'POST') {
          return _generationResponse(png, width: 2, height: 3);
        }
        assetRequestSeen = true;
        expect(request.url.host, 'cdn.example.com');
        return http.Response(
          '',
          302,
          headers: const <String, String>{
            'location': 'https://untrusted.example/asset.png',
          },
        );
      }),
    );

    await expectLater(
      gateway.generate(
        prompt: 'A tiny warm city',
        aspectRatio: '1:1',
        style: 'cinematic',
        idempotencyKey: 'creator_redirect_asset',
        expectedContextKey: gateway.requestContextKey,
      ),
      throwsA(
        isA<CreatorImageRequestException>()
            .having((error) => error.code, 'code', 'asset_download_failed')
            .having((error) => error.statusCode, 'statusCode', 302),
      ),
    );
    expect(assetRequestSeen, isTrue);
  });

  test(
    'rejects WebP even when the declared bytes are otherwise valid',
    () async {
      final png = Uint8List.fromList(
        image.encodePng(image.Image(width: 2, height: 3)),
      );
      var assetRequestCount = 0;
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((request) async {
          if (request.method == 'POST') {
            return _generationResponse(
              png,
              width: 2,
              height: 3,
              contentType: 'image/webp',
            );
          }
          assetRequestCount++;
          return http.Response('', 500);
        }),
      );

      await _expectInvalidAssetContract(gateway, 'creator_webp_asset');
      expect(assetRequestCount, 0);
    },
  );

  test('rejects extra and missing generation data fields', () async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 2, height: 3)),
    );
    for (final response in <http.Response>[
      _generationResponse(
        png,
        width: 2,
        height: 3,
        extraData: const <String, Object?>{'unexpected': true},
      ),
      _generationResponse(
        png,
        width: 2,
        height: 3,
        omittedDataKeys: const <String>{'height'},
      ),
    ]) {
      await appServices.reset();
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((_) async => response),
      );
      await _expectInvalidEnvelope(gateway, 'creator_shape_contract');
    }
  });

  test('rejects fractional and string integer fields', () async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 2, height: 3)),
    );
    for (final width in <Object>[2.5, '2']) {
      await appServices.reset();
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient(
          (_) async => _generationResponse(png, width: width, height: 3),
        ),
      );
      await _expectInvalidEnvelope(gateway, 'creator_integer_contract');
    }
  });

  test('rejects a non-OK code on an HTTP 2xx response', () async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 2, height: 3)),
    );
    final gateway = await _gateway(
      temporaryDirectory,
      MockClient(
        (_) async =>
            _generationResponse(png, width: 2, height: 3, code: 'SUCCESS'),
      ),
    );

    await _expectInvalidEnvelope(gateway, 'creator_non_ok_code');
  });

  test('rejects an oversized streamed asset before buffering it', () async {
    final tiny = Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
    final gateway = await _gateway(
      temporaryDirectory,
      MockClient((request) async {
        if (request.method == 'POST') {
          return _generationResponse(tiny, width: 1, height: 1);
        }
        return http.Response.bytes(
          tiny,
          200,
          headers: <String, String>{
            'content-type': 'image/png',
            'content-length':
                '${HttpImageGenerationGateway.maximumAssetBytes + 1}',
          },
        );
      }),
    );

    await expectLater(
      gateway.generate(
        prompt: 'A tiny warm city',
        aspectRatio: '1:1',
        style: 'cinematic',
        idempotencyKey: 'creator_large_asset',
        expectedContextKey: gateway.requestContextKey,
      ),
      throwsA(
        isA<CreatorImageRequestException>().having(
          (error) => error.code,
          'code',
          'asset_too_large',
        ),
      ),
    );
  });

  test(
    'rejects image headers that exceed the decoded dimension budget',
    () async {
      final bombHeader = Uint8List.fromList(
        image.encodePng(image.Image(width: 5000, height: 1)),
      );
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((request) async {
          if (request.method == 'POST') {
            return _generationResponse(bombHeader, width: 2, height: 1);
          }
          return http.Response.bytes(
            bombHeader,
            200,
            headers: <String, String>{
              'content-type': 'image/png',
              'content-length': '${bombHeader.length}',
            },
          );
        }),
      );

      await expectLater(
        gateway.generate(
          prompt: 'A tiny warm city',
          aspectRatio: '1:1',
          style: 'cinematic',
          idempotencyKey: 'creator_header_bomb',
          expectedContextKey: gateway.requestContextKey,
        ),
        throwsA(
          isA<CreatorImageRequestException>().having(
            (error) => error.code,
            'code',
            'asset_dimensions_mismatch',
          ),
        ),
      );
    },
  );

  test('matches the backend 12,000,000 pixel budget exactly', () async {
    expect(HttpImageGenerationGateway.maximumPixels, 12_000_000);
    expect(HttpImageGenerationGateway.maximumPixels + 1, 12_000_001);

    final tiny = Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
    var assetRequestCount = 0;
    final gateway = await _gateway(
      temporaryDirectory,
      MockClient((request) async {
        if (request.method == 'POST') {
          // 3,001 x 4,000 is the smallest convenient integral-dimension
          // fixture above the exact 12,000,001-pixel rejection boundary.
          return _generationResponse(tiny, width: 3001, height: 4000);
        }
        assetRequestCount++;
        return http.Response.bytes(
          tiny,
          200,
          headers: <String, String>{
            'content-type': 'image/png',
            'content-length': '${tiny.length}',
          },
        );
      }),
    );

    await _expectInvalidAssetContract(gateway, 'creator_pixel_budget');
    expect(assetRequestCount, 0);
  });

  test(
    'times out image-generation requests and leaves no busy network wait',
    () async {
      final gateway = await _gateway(
        temporaryDirectory,
        _NeverCompletingClient(),
        requestTimeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.generate(
          prompt: 'A tiny warm city',
          aspectRatio: '1:1',
          style: 'cinematic',
          idempotencyKey: 'creator_timeout',
          expectedContextKey: gateway.requestContextKey,
        ),
        throwsA(
          isA<CreatorImageRequestException>().having(
            (error) => error.code,
            'code',
            'generation_timeout',
          ),
        ),
      );
    },
  );

  test(
    'never deletes an asset outside the managed creator directory',
    () async {
      final gateway = await _gateway(
        temporaryDirectory,
        MockClient((_) async => throw UnimplementedError()),
      );
      final outside = File('${temporaryDirectory.path}/outside.png');
      await outside.writeAsBytes(<int>[1, 2, 3]);
      final asset = CreatorAssetRef(
        id: 'outside',
        localPath: outside.path,
        contentType: 'image/png',
        sha256: List<String>.filled(64, 'a').join(),
        bytes: 3,
        width: 1,
        height: 1,
      );

      await expectLater(
        gateway.deleteLocalAsset(asset),
        throwsA(
          isA<CreatorImageRequestException>().having(
            (error) => error.code,
            'code',
            'invalid_asset_path',
          ),
        ),
      );
      expect(await outside.exists(), isTrue);
    },
  );
}

Future<HttpImageGenerationGateway> _gateway(
  Directory directory,
  http.Client client, {
  bool? available = true,
  Duration requestTimeout = const Duration(seconds: 2),
}) async {
  appServices.testMode = true;
  appServices.put<SecureStorageService>(_MemorySecureStorage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(AuthSessionService(httpClient: client));
  await auth.init();
  auth.session.value = MaasoAuthSession(
    accountUuid: 'owner-1',
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
  return HttpImageGenerationGateway(
    httpClient: client,
    environment: environment,
    auth: auth,
    assetPolicy: const TrustedMediaAssetPolicy(
      allowedHosts: <String>{'cdn.example.com'},
    ),
    supportDirectory: () async => directory,
    available: available,
    requestTimeout: requestTimeout,
    downloadTimeout: requestTimeout,
  );
}

http.Response _generationResponse(
  Uint8List bytes, {
  required Object width,
  required Object height,
  String code = 'OK',
  String contentType = 'image/png',
  Map<String, Object?> extraData = const <String, Object?>{},
  Set<String> omittedDataKeys = const <String>{},
}) {
  final data = <String, Object?>{
    'assetId': 'asset-1',
    'assetUrl': 'https://cdn.example.com/generated/asset-1.png',
    'contentType': contentType,
    'sha256': sha256.convert(bytes).toString(),
    'bytes': bytes.length,
    'width': width,
    'height': height,
    ...extraData,
  }..removeWhere((key, _) => omittedDataKeys.contains(key));
  return http.Response(
    jsonEncode(<String, Object?>{
      'code': code,
      'message': 'ok',
      'traceId': 'trace-1',
      'data': data,
    }),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

Future<void> _expectInvalidEnvelope(
  HttpImageGenerationGateway gateway,
  String idempotencyKey,
) => expectLater(
  gateway.generate(
    prompt: 'A tiny warm city',
    aspectRatio: '1:1',
    style: 'cinematic',
    idempotencyKey: idempotencyKey,
    expectedContextKey: gateway.requestContextKey,
  ),
  throwsA(
    isA<CreatorImageRequestException>().having(
      (error) => error.code,
      'code',
      'invalid_envelope',
    ),
  ),
);

Future<void> _expectInvalidAssetContract(
  HttpImageGenerationGateway gateway,
  String idempotencyKey,
) => expectLater(
  gateway.generate(
    prompt: 'A tiny warm city',
    aspectRatio: '1:1',
    style: 'cinematic',
    idempotencyKey: idempotencyKey,
    expectedContextKey: gateway.requestContextKey,
  ),
  throwsA(
    isA<CreatorImageRequestException>().having(
      (error) => error.code,
      'code',
      'invalid_asset',
    ),
  ),
);

class _NeverCompletingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
