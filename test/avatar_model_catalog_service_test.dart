import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';

void main() {
  setUp(() {
    appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('lists approved Unity models with Maaso bearer authentication', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/avatar-models'
          '?platformAssets=true&platform=android&builtinCatalogVersion=$avatarBuiltinCatalogVersion',
        );
        expect(request.headers['authorization'], 'Bearer access-token');
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'message': 'success',
            'traceId': 'trace-avatar-catalog',
            'data': [
              {
                'id': 24,
                'modelKey': 'community.creator.v1',
                'displayName': 'Creator',
                'modelSource': 'community',
                'previewImageUrl':
                    'https://cdn.example.com/creator-preview.png',
                'assetUrl': 'https://cdn.example.com/creator.bundle',
                'assetSha256': 'a' * 64,
                'runtimeConfig': {
                  'scene': 'Community/Creator',
                  'avatar': 'creator',
                  'assetName': 'Creator',
                },
                'compatibility': {
                  'backends': ['unity'],
                },
                'capabilityProfile': _supportedCapabilityProfile,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final models = await service.listApprovedModels();

    expect(models, hasLength(1));
    expect(models.single.id, 24);
    expect(models.single.displayName, 'Creator');
    expect(models.single.isUnityCompatible, isTrue);
    expect(models.single.isLoadableOnDevice, isTrue);
    expect(
      models.single.capabilityProfile.state,
      AvatarCapabilityState.supported,
    );
    expect(models.single.toAvatarOption().remoteModelId, 24);
    expect(
      models.single.toAvatarOption().modelUrl,
      'https://cdn.example.com/creator.bundle',
    );
    expect(
      models.single.toAvatarOption().previewImageUrl,
      'https://cdn.example.com/creator-preview.png',
    );
    expect(service.models.single.modelKey, 'community.creator.v1');
    expect(
      models.single.toAvatarOption().capabilityProfile.state,
      AvatarCapabilityState.supported,
    );
  });

  test('keeps an incompatible descriptor explainable but not loadable', () {
    final model = ApprovedAvatarModel.fromJson({
      'id': 32,
      'modelKey': 'community.invalid.rig',
      'displayName': 'Needs Rig Fix',
      'modelSource': 'community',
      'assetUrl': 'https://cdn.example.com/needs-fix.vrm',
      'assetSha256': 'e' * 64,
      'runtimeConfig': {'assetFormat': 'vrm'},
      'compatibility': {
        'backends': ['unity'],
      },
      'capabilityProfile': {
        ..._supportedCapabilityProfile,
        'state': 'incompatible',
        'rig': {
          ...(_supportedCapabilityProfile['rig']! as Map<String, Object>),
          'humanoid': false,
        },
        'issues': const [
          {'code': 'missing_humanoid', 'severity': 'blocker'},
        ],
      },
    });

    expect(model.hasExecutableDescriptor, isTrue);
    expect(model.isLoadableOnDevice, isFalse);
    expect(model.capabilityProfile.hasBlockers, isTrue);
    expect(
      model.toAvatarOption().capabilityProfile.primaryIssue?.code,
      AvatarCapabilityIssueCode.missingHumanoid,
    );
  });

  test(
    'mobile catalog keeps incompatible diagnostics out of app logic',
    () async {
      final service = await _createCatalog(
        MockClient(
          (_) async =>
              _catalogResponseWithProfile(_incompatibleCapabilityProfile),
        ),
      );

      expect(await service.listApprovedModels(), isEmpty);
    },
  );

  test('desktop catalog retains incompatible models for diagnostics', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/avatar-models'
          '?platformAssets=false&builtinCatalogVersion=$avatarBuiltinCatalogVersion',
        );
        return _catalogResponseWithProfile(_incompatibleCapabilityProfile);
      }),
      targetPlatform: TargetPlatform.macOS,
    );

    final models = await service.listApprovedModels();
    expect(models, hasLength(1));
    expect(models.single.isLoadableOnDevice, isFalse);
    expect(models.single.capabilityProfile.hasBlockers, isTrue);
  });

  test('rejects a non-HTTPS catalog preview without exposing it to UI', () {
    expect(
      () => ApprovedAvatarModel.fromJson({
        'id': 24,
        'modelKey': 'community.creator.v1',
        'displayName': 'Creator',
        'modelSource': 'community',
        'previewImageUrl': 'http://cdn.example.com/creator-preview.png',
        'assetUrl': 'https://cdn.example.com/creator.bundle',
        'assetSha256': 'a' * 64,
        'runtimeConfig': {'assetName': 'Creator'},
        'compatibility': {
          'backends': ['unity'],
        },
      }),
      throwsA(isA<StateError>()),
    );
  });

  test('accepts one cross-platform VRM descriptor without an asset name', () {
    final model = ApprovedAvatarModel.fromJson({
      'id': 31,
      'modelKey': 'community.vrm.creator',
      'displayName': 'VRM Creator',
      'modelSource': 'community',
      'assetUrl': 'https://cdn.example.com/creator.vrm',
      'assetSha256': 'f' * 64,
      'runtimeConfig': {'assetFormat': 'vrm'},
      'compatibility': {
        'backends': ['unity'],
        'formats': ['vrm_1_0'],
      },
    });

    expect(model.isVrm, isTrue);
    expect(model.isLoadableOnDevice, isTrue);
    expect(model.platformAssets, isEmpty);
    expect(model.toAvatarOption().config, containsPair('assetFormat', 'vrm'));
  });

  test('selects the current platform from a complete variant map', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/v1/avatar-models'
          '?platformAssets=true&platform=android&builtinCatalogVersion=$avatarBuiltinCatalogVersion',
        );
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'message': 'success',
            'data': [
              {
                'id': 25,
                'modelKey': 'masso.official.modular-female',
                'displayName': 'Female',
                'modelSource': 'official',
                'compatibility': {
                  'backends': ['unity'],
                },
                'platformAssets': {
                  'ios': {
                    'platform': 'ios',
                    'bundleVersion': 'v1',
                    'assetUrl': 'https://cdn.example.com/female-ios.bundle',
                    'assetSha256': 'b' * 64,
                    'assetBytes': 1234,
                    'runtimeConfig': {'assetName': 'Female'},
                  },
                  'android': {
                    'platform': 'android',
                    'bundleVersion': 'v1',
                    'assetUrl': 'https://cdn.example.com/female-android.bundle',
                    'assetSha256': 'c' * 64,
                    'assetBytes': 2345,
                    'runtimeConfig': {'assetName': 'Female'},
                  },
                },
              },
              {
                'id': 26,
                'modelKey': 'masso.official.incomplete',
                'displayName': 'Incomplete',
                'modelSource': 'official',
                'compatibility': {
                  'backends': ['unity'],
                },
                'platformAssets': {
                  'ios': {
                    'platform': 'ios',
                    'bundleVersion': 'v1',
                    'assetUrl': 'https://cdn.example.com/incomplete.bundle',
                    'assetSha256': 'd' * 64,
                    'assetBytes': 100,
                    'runtimeConfig': {'assetName': 'Incomplete'},
                  },
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final models = await service.listApprovedModels();

    expect(models, hasLength(1));
    final female = models.single;
    expect(female.selectedPlatform, 'android');
    expect(female.assetUrl, 'https://cdn.example.com/female-android.bundle');
    expect(female.assetBytes, 2345);
    expect(female.platformAssets.keys, containsAll(['ios', 'android']));
    expect(
      female.toAvatarOption().config,
      containsPair('approvedAssetBytes', 2345),
    );
    expect(female.toAvatarOption().config, containsPair('bundleVersion', 'v1'));
  });

  test('keeps a plain-text catalog failure as an HTTP error', () async {
    final service = await _createCatalog(
      MockClient((_) async => http.Response('404 page not found', 404)),
    );

    await expectLater(
      service.listApprovedModels(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Avatar model request failed: HTTP 404',
        ),
      ),
    );
    expect(service.error.value, 'Avatar model request failed: HTTP 404');
  });

  test('reads v2 current selection with bound auth and mobile query', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/'
          'v1/avatar-models/selections/current'
          '?agentId=self&platformAssets=true&platform=ios',
        );
        expect(request.headers['authorization'], 'Bearer access-token');
        return _avatarSelectionCurrentResponse();
      }),
      targetPlatform: TargetPlatform.iOS,
    );

    final current = await service.current(
      agentId: 'self',
      assetOptions: AvatarSelectionAssetOptions.forPlatform('ios'),
    );

    expect(current.selection.version, 0);
    expect(current.selection.modelId, isNull);
    expect(current.asset.modelKey, 'masso.bundled.agent');
  });

  test(
    'only the internal test origin retries legacy current-selection GET',
    () async {
      final queries = <Map<String, String>>[];
      final service = await _createCatalog(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.headers['authorization'], 'Bearer access-token');
          queries.add(request.url.queryParameters);
          return request.url.queryParameters.containsKey(
                'builtinCatalogVersion',
              )
              ? _avatarSelectionErrorResponse(400, 'VALIDATION_ERROR')
              : _avatarSelectionCurrentResponse();
        }),
        targetPlatform: TargetPlatform.iOS,
      );
      final pending = service.current(
        agentId: 'self',
        assetOptions: AvatarSelectionAssetOptions.forPlatform(
          'ios',
          builtinCatalogVersion: 2,
        ),
      );
      const internal =
          bool.fromEnvironment('MAASO_STORE_INTERNAL_BUILD') &&
          bool.fromEnvironment('MAASO_INTERNAL_PRIVACY_TEST');
      if (internal) {
        final snapshot = await pending;
        expect(snapshot.selection.version, 0);
        expect(snapshot.asset.modelKey, 'masso.bundled.agent');
        expect(queries, hasLength(2));
        expect(queries.first['builtinCatalogVersion'], '2');
        expect(queries.last.containsKey('builtinCatalogVersion'), isFalse);
        expect(queries.last['platform'], 'ios');
      } else {
        await expectLater(
          pending,
          throwsA(isA<AvatarSelectionValidationException>()),
        );
        expect(queries, hasLength(1));
      }
    },
  );

  test('desktop v2 current omits platform and uses top-level asset', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://api-test.futurpals.com.cn/'
          'v1/avatar-models/selections/current'
          '?agentId=self&platformAssets=false',
        );
        return _avatarSelectionCurrentResponse(
          selection: _avatarSelectionState(
            selectionId: 9,
            modelId: 24,
            version: 7,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
          asset: _remoteAvatarSelectionAsset(),
        );
      }),
      targetPlatform: TargetPlatform.macOS,
    );

    final current = await service.current(
      agentId: 'self',
      assetOptions: const AvatarSelectionAssetOptions.none(),
    );

    expect(current.selection.modelId, 24);
    expect(current.asset.assetUrl, 'https://cdn.example.com/creator.vrm');
    expect(current.asset.platformAssets, isEmpty);
  });

  test(
    'unsupported desktop exposes mount-safe selection options but no catalog',
    () async {
      var requests = 0;
      final service = await _createCatalog(
        MockClient((_) async {
          requests++;
          return http.Response('[]', 200);
        }),
        targetPlatform: TargetPlatform.linux,
      );

      expect(service.selectionAssetOptions.platformAssets, isFalse);
      expect(service.selectionAssetOptions.platform, isNull);
      await expectLater(
        service.listApprovedModels(),
        throwsA(isA<UnsupportedError>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'rejects target-platform asset option mismatches before network',
    () async {
      var mobileRequests = 0;
      final mobile = await _createCatalog(
        MockClient((_) async {
          mobileRequests++;
          return _avatarSelectionCurrentResponse();
        }),
        targetPlatform: TargetPlatform.android,
      );

      await expectLater(
        mobile.current(
          agentId: 'self',
          assetOptions: const AvatarSelectionAssetOptions.none(),
        ),
        throwsA(
          isA<AvatarSelectionValidationException>().having(
            (error) => error.code,
            'code',
            'AVATAR_SELECTION_PLATFORM_MISMATCH',
          ),
        ),
      );
      expect(mobileRequests, 0);

      appServices.reset();
      appServices.testMode = true;
      var desktopRequests = 0;
      final desktop = await _createCatalog(
        MockClient((_) async {
          desktopRequests++;
          return _avatarSelectionCommitResponse(
            _avatarSelectionRequest(
              assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
            ),
          );
        }),
        targetPlatform: TargetPlatform.macOS,
      );
      await expectLater(
        desktop.commit(
          _avatarSelectionRequest(
            assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
          ),
        ),
        throwsA(isA<AvatarSelectionValidationException>()),
      );
      expect(desktopRequests, 0);
    },
  );

  test('commit sends exact body and reuses it for the same request', () async {
    final bodies = <String>[];
    final request = AvatarSelectionCommitRequest(
      agentId: 'self',
      modelId: 24,
      expectedVersion: 0,
      idempotencyKey: 'avatar_commit_01',
      assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
    );
    final service = await _createCatalog(
      MockClient((httpRequest) async {
        expect(httpRequest.method, 'POST');
        expect(
          httpRequest.url.toString(),
          'https://api-test.futurpals.com.cn/'
          'v1/avatar-models/selections/commit',
        );
        expect(httpRequest.headers['authorization'], 'Bearer access-token');
        bodies.add(httpRequest.body);
        return _avatarSelectionCommitResponse(request);
      }),
    );

    final first = await service.commit(request);
    final replay = await service.commit(request);

    expect(first.receipt.selection.version, 1);
    expect(replay.receipt.idempotencyKey, request.idempotencyKey);
    expect(bodies, hasLength(2));
    expect(bodies[1], bodies[0]);
    expect(jsonDecode(bodies.first), <String, Object?>{
      'agentId': 'self',
      'modelId': 24,
      'expectedVersion': 0,
      'idempotencyKey': 'avatar_commit_01',
      'platformAssets': true,
      'platform': 'android',
    });
  });

  test('current and commit use the active catalog capability', () async {
    late AvatarSelectionCommitRequest commitRequest;
    final service = await _createCatalog(
      MockClient((request) async {
        if (request.method == 'GET') {
          expect(
            request.url.queryParameters['builtinCatalogVersion'],
            '$avatarBuiltinCatalogVersion',
          );
          return _avatarSelectionCurrentResponse();
        }
        expect(request.url.path, '/v1/avatar-models/selections/commit');
        expect(
          (jsonDecode(request.body) as Map)['builtinCatalogVersion'],
          avatarBuiltinCatalogVersion,
        );
        return _avatarSelectionCommitResponse(commitRequest);
      }),
    );
    expect(
      service.selectionAssetOptions.builtinCatalogVersion,
      avatarBuiltinCatalogVersion,
    );
    await service.current(
      agentId: 'self',
      assetOptions: service.selectionAssetOptions,
    );
    commitRequest = _avatarSelectionRequest(
      assetOptions: service.selectionAssetOptions,
    );
    await service.commit(commitRequest);
  });

  test('bound production environment owns the request base URI', () async {
    final service = await _createCatalog(
      MockClient((request) async {
        expect(request.url.host, 'api.futurpals.com');
        return _avatarSelectionCurrentResponse();
      }),
      boundEnvironment: MaasoEnvironment.production,
    );

    await service.current(
      agentId: 'self',
      assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
    );
  });

  test(
    'account and environment fence reject a newly published identity',
    () async {
      var requests = 0;
      final service = await _createCatalog(
        MockClient((_) async {
          requests++;
          return _avatarSelectionCurrentResponse();
        }),
      );
      final auth = appServices.find<AuthSessionService>();
      auth.session.value = MaasoAuthSession(
        accountUuid: 'owner-2',
        accessToken: 'other-access-token',
        refreshToken: 'other-refresh-token',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );

      await expectLater(
        service.current(
          agentId: 'self',
          assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
        ),
        throwsA(isA<AvatarSelectionAuthorizationException>()),
      );
      await expectLater(
        service.listApprovedModels(),
        throwsA(isA<StateError>()),
      );
      expect(requests, 0);

      auth.session.value = MaasoAuthSession(
        accountUuid: 'owner-1',
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
      appServices.find<AppEnvironmentService>().environment.value =
          MaasoEnvironment.production;
      await expectLater(
        service.current(
          agentId: 'self',
          assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
        ),
        throwsA(isA<AvatarSelectionAuthorizationException>()),
      );
      expect(requests, 0);
    },
  );

  for (final statusCode in <int>[404, 410]) {
    test(
      'GET $statusCode makes v2 unavailable without legacy fallback',
      () async {
        final paths = <String>[];
        final service = await _createCatalog(
          MockClient((request) async {
            paths.add(request.url.path);
            return _avatarSelectionErrorResponse(statusCode, 'NOT_FOUND');
          }),
        );

        await expectLater(
          service.current(
            agentId: 'self',
            assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
          ),
          throwsA(isA<AvatarSelectionContractUnavailableException>()),
        );
        expect(paths, <String>['/v1/avatar-models/selections/current']);
      },
    );
  }

  test(
    'network and malformed GET failures make the contract unavailable',
    () async {
      final networkService = await _createCatalog(
        MockClient((_) async => throw const SocketException('offline')),
      );
      await expectLater(
        networkService.current(
          agentId: 'self',
          assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
        ),
        throwsA(isA<AvatarSelectionContractUnavailableException>()),
      );

      appServices.reset();
      appServices.testMode = true;
      final malformedService = await _createCatalog(
        MockClient((_) async => http.Response('{"code":"OK"}', 200)),
      );
      await expectLater(
        malformedService.current(
          agentId: 'self',
          assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
        ),
        throwsA(isA<AvatarSelectionContractUnavailableException>()),
      );
    },
  );

  final definiteCommitFailures = <(String, int, String, Matcher)>[
    (
      'asset version changed',
      409,
      'AVATAR_ASSET_VERSION_CHANGED',
      isA<AvatarSelectionValidationException>().having(
        (error) => error.code,
        'code',
        'AVATAR_ASSET_VERSION_CHANGED',
      ),
    ),
    (
      'validation',
      400,
      'VALIDATION_ERROR',
      isA<AvatarSelectionValidationException>(),
    ),
    (
      'unauthorized',
      401,
      'UNAUTHORIZED',
      isA<AvatarSelectionAuthorizationException>(),
    ),
    (
      'forbidden',
      403,
      'FORBIDDEN',
      isA<AvatarSelectionAuthorizationException>(),
    ),
    (
      'model not found',
      404,
      'NOT_FOUND',
      isA<AvatarSelectionNotFoundException>(),
    ),
    (
      'idempotency conflict',
      409,
      'AVATAR_SELECTION_IDEMPOTENCY_CONFLICT',
      isA<AvatarSelectionIdempotencyConflictException>(),
    ),
    (
      'version exhausted',
      409,
      'AVATAR_SELECTION_VERSION_EXHAUSTED',
      isA<AvatarSelectionVersionExhaustedException>(),
    ),
  ];
  for (final scenario in definiteCommitFailures) {
    test('maps POST ${scenario.$1} to its typed failure', () async {
      final request = _avatarSelectionRequest();
      final service = await _createCatalog(
        MockClient(
          (_) async => _avatarSelectionErrorResponse(scenario.$2, scenario.$3),
        ),
      );

      await expectLater(service.commit(request), throwsA(scenario.$4));
    });
  }

  test('maps version conflict with the requested agent snapshot', () async {
    final request = _avatarSelectionRequest();
    final service = await _createCatalog(
      MockClient(
        (_) async => _avatarSelectionErrorResponse(
          409,
          'AVATAR_SELECTION_VERSION_CHANGED',
          data: <String, Object?>{
            'currentSelection': _avatarSelectionCurrentData(
              selection: _avatarSelectionState(
                selectionId: 9,
                modelId: 18,
                version: 2,
                selectedAt: '2026-09-01T08:00:00Z',
              ),
              asset: _remoteAvatarSelectionAsset(id: 18),
            )..remove('contractVersion'),
          },
        ),
      ),
    );

    await expectLater(
      service.commit(request),
      throwsA(
        isA<AvatarSelectionVersionChangedException>().having(
          (error) => error.currentSelection.selection.version,
          'current version',
          2,
        ),
      ),
    );
  });

  test('rejects a version conflict snapshot for another agent', () async {
    final request = _avatarSelectionRequest();
    final service = await _createCatalog(
      MockClient(
        (_) async => _avatarSelectionErrorResponse(
          409,
          'AVATAR_SELECTION_VERSION_CHANGED',
          data: <String, Object?>{
            'currentSelection': _avatarSelectionCurrentData(
              selection: _avatarSelectionState(
                agentId: 'another-agent',
                selectionId: 9,
                modelId: 18,
                version: 2,
                selectedAt: '2026-09-01T08:00:00Z',
              ),
              asset: _remoteAvatarSelectionAsset(id: 18),
            )..remove('contractVersion'),
          },
        ),
      ),
    );

    await expectLater(
      service.commit(request),
      throwsA(isA<AvatarSelectionContractUnavailableException>()),
    );
  });

  for (final statusCode in <int>[408, 429, 500, 503]) {
    test('treats POST HTTP $statusCode as ambiguous', () async {
      final service = await _createCatalog(
        MockClient(
          (_) async =>
              _avatarSelectionErrorResponse(statusCode, 'INTERNAL_ERROR'),
        ),
      );

      await expectLater(
        service.commit(_avatarSelectionRequest()),
        throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
      );
    });
  }

  test('treats POST network and malformed success as ambiguous', () async {
    final networkService = await _createCatalog(
      MockClient((_) async => throw const SocketException('offline')),
    );
    await expectLater(
      networkService.commit(_avatarSelectionRequest()),
      throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
    );

    appServices.reset();
    appServices.testMode = true;
    final malformedService = await _createCatalog(
      MockClient(
        (_) async => http.Response(
          jsonEncode(_avatarSelectionEnvelope(<String, Object?>{})),
          200,
        ),
      ),
    );
    await expectLater(
      malformedService.commit(_avatarSelectionRequest()),
      throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
    );
  });

  test('selection request timeout is bounded and typed by method', () async {
    final pendingGet = Completer<http.Response>();
    final getService = await _createCatalog(
      MockClient((_) => pendingGet.future),
      selectionRequestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      getService.current(
        agentId: 'self',
        assetOptions: AvatarSelectionAssetOptions.forPlatform('android'),
      ),
      throwsA(isA<AvatarSelectionContractUnavailableException>()),
    );

    appServices.reset();
    appServices.testMode = true;
    final pendingPost = Completer<http.Response>();
    final postService = await _createCatalog(
      MockClient((_) => pendingPost.future),
      selectionRequestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      postService.commit(_avatarSelectionRequest()),
      throwsA(isA<AvatarSelectionAmbiguousTransportException>()),
    );
  });
}

const _supportedCapabilityProfile = <String, Object>{
  'schemaVersion': 1,
  'source': 'catalog',
  'state': 'supported',
  'rig': <String, Object>{
    'humanoid': true,
    'head': true,
    'leftEye': true,
    'rightEye': true,
  },
  'behavior': <String, Object>{
    'lookAt': true,
    'lipSync': true,
    'blink': true,
    'expressions': true,
  },
  'render': <String, Object>{
    'renderable': true,
    'rendererCount': 2,
    'skinnedMeshCount': 1,
    'vertexCount': 64000,
    'triangleCount': 96000,
    'materialCount': 6,
    'textureCount': 8,
    'maxTextureSize': 2048,
    'estimatedTextureBytes': 25165824,
  },
  'issues': <Object>[],
};

final _incompatibleCapabilityProfile = <String, Object>{
  ..._supportedCapabilityProfile,
  'state': 'incompatible',
  'rig': <String, Object>{
    ...(_supportedCapabilityProfile['rig']! as Map<String, Object>),
    'humanoid': false,
  },
  'issues': const <Object>[
    {'code': 'missing_humanoid', 'severity': 'blocker'},
  ],
};

Future<AvatarModelCatalogService> _createCatalog(
  http.Client client, {
  TargetPlatform targetPlatform = TargetPlatform.android,
  MaasoEnvironment boundEnvironment = MaasoEnvironment.test,
  Duration selectionRequestTimeout = const Duration(seconds: 15),
}) async {
  final storage = _MemorySecureStorageService();
  appServices.put<SecureStorageService>(storage);
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  environment.environment.value = boundEnvironment;
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async {
        throw UnimplementedError('Avatar catalog tests must not refresh auth');
      }),
    ),
  );
  await auth.init();
  final accountSession = MaasoAuthSession(
    accountUuid: 'owner-1',
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
  );
  auth.session.value = accountSession;
  final accountScope = AccountStorageScope(
    environmentKey: environment.environment.value.key,
    accountUuid: accountSession.accountUuid,
  );
  final storageScopes = AccountStorageScopeService();
  final accountMount = storageScopes.mount(accountScope);
  return AvatarModelCatalogService(
    accountSession: accountSession,
    accountMount: accountMount,
    agentScope: accountScope.agent('self'),
    storageScopes: storageScopes,
    httpClient: client,
    targetPlatform: targetPlatform,
    selectionRequestTimeout: selectionRequestTimeout,
  );
}

AvatarSelectionCommitRequest _avatarSelectionRequest({
  AvatarSelectionAssetOptions? assetOptions,
}) => AvatarSelectionCommitRequest(
  agentId: 'self',
  modelId: 24,
  expectedVersion: 0,
  idempotencyKey: 'avatar_request_01',
  assetOptions:
      assetOptions ?? AvatarSelectionAssetOptions.forPlatform('android'),
);

Map<String, Object?> _avatarSelectionEnvelope(
  Object? data, {
  String code = 'OK',
}) => <String, Object?>{
  'code': code,
  'message': code == 'OK' ? 'success' : 'request failed',
  'traceId': 'trace-avatar-selection',
  'data': data,
};

Map<String, Object?> _avatarSelectionState({
  int? selectionId,
  int? modelId,
  required int version,
  String? selectedAt,
  String agentId = 'self',
}) => <String, Object?>{
  'selectionId': selectionId,
  'agentId': agentId,
  'modelId': modelId,
  'version': version,
  'selectedAt': selectedAt,
};

Map<String, Object?> _bundledAvatarSelectionAsset() => <String, Object?>{
  'id': 1,
  'modelKey': 'masso.bundled.agent',
  'displayName': 'Agent',
  'modelSource': 'official',
  'assetUrl': 'unity://masso/avatar_agent',
  'assetSha256':
      '82e306d47cd720b6ba121bfab08f07de5cb50e8046e34bd52d959b55012240cd',
  'runtimeConfig': <String, Object?>{'avatar': 'agent', 'assetName': 'Agent'},
  'compatibility': <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

Map<String, Object?> _remoteAvatarSelectionAsset({int id = 24}) =>
    <String, Object?>{
      'id': id,
      'modelKey': 'community.creator.v1',
      'displayName': 'Creator',
      'modelSource': 'community',
      'assetUrl': 'https://cdn.example.com/creator.vrm',
      'assetSha256': 'a' * 64,
      'runtimeConfig': <String, Object?>{'assetFormat': 'vrm'},
      'compatibility': <String, Object?>{
        'backends': <Object?>['unity'],
      },
    };

Map<String, Object?> _avatarSelectionCurrentData({
  Map<String, Object?>? selection,
  Map<String, Object?>? asset,
  bool selectionAvailable = true,
}) => <String, Object?>{
  'contractVersion': avatarSelectionContractVersion,
  'selection': selection ?? _avatarSelectionState(version: 0),
  'asset': asset ?? _bundledAvatarSelectionAsset(),
  'selectionAvailable': selectionAvailable,
};

http.Response _avatarSelectionCurrentResponse({
  Map<String, Object?>? selection,
  Map<String, Object?>? asset,
  bool selectionAvailable = true,
}) => http.Response(
  jsonEncode(
    _avatarSelectionEnvelope(
      _avatarSelectionCurrentData(
        selection: selection,
        asset: asset,
        selectionAvailable: selectionAvailable,
      ),
    ),
  ),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _avatarSelectionCommitResponse(
  AvatarSelectionCommitRequest request,
) => http.Response(
  jsonEncode(
    _avatarSelectionEnvelope(<String, Object?>{
      'contractVersion': avatarSelectionContractVersion,
      'receipt': <String, Object?>{
        'idempotencyKey': request.idempotencyKey,
        'previousSelection': _avatarSelectionState(version: 0),
        'selection': _avatarSelectionState(
          selectionId: 9,
          modelId: request.modelId,
          version: 1,
          selectedAt: '2026-09-01T08:00:00Z',
        ),
        'asset': request.modelId == null
            ? _bundledAvatarSelectionAsset()
            : _remoteAvatarSelectionAsset(id: request.modelId!),
        'selectionAvailable': true,
      },
      'replayed': false,
    }),
  ),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _avatarSelectionErrorResponse(
  int statusCode,
  String code, {
  Object? data,
}) => http.Response(
  jsonEncode(_avatarSelectionEnvelope(data, code: code)),
  statusCode,
  headers: <String, String>{'content-type': 'application/json'},
);

http.Response _catalogResponseWithProfile(Map<String, Object> profile) {
  return http.Response(
    jsonEncode({
      'code': 'OK',
      'message': 'success',
      'traceId': 'trace-avatar-capability-filter',
      'data': [
        {
          'id': 32,
          'modelKey': 'community.invalid.rig',
          'displayName': 'Needs Rig Fix',
          'modelSource': 'community',
          'assetUrl': 'https://cdn.example.com/needs-fix.bundle',
          'assetSha256': 'e' * 64,
          'runtimeConfig': {'assetName': 'NeedsRigFix'},
          'compatibility': {
            'backends': ['unity'],
          },
          'capabilityProfile': profile,
        },
      ],
    }),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = {};

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
