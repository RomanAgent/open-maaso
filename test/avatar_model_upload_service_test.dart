import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'helpers/avatar_upload_cover_fixture.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  setUp(() {
    appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test(
    'uploads a bound VRM and cover pair without storage bearer tokens',
    () async {
      final client = _AvatarUploadClient(
        mineUploads: <Map<String, dynamic>>[_pendingReviewUpload()],
      );
      final service = await _createCatalog(client);
      final directory = await Directory.systemTemp.createTemp(
        'maaso-avatar-upload',
      );
      final file = File('${directory.path}/lumen.vrm');
      final bytes = <int>[1, 2, 3, 4, 5];
      await file.writeAsBytes(bytes);
      addTearDown(() => directory.delete(recursive: true));

      final upload = await service.uploadBundle(
        file: file,
        displayName: ' Lumen Explorer ',
        cover: await avatarUploadCoverFixture(),
      );

      expect(upload.id, 42);
      expect(upload.status, AvatarUploadStatus.pendingReview);
      expect(service.myUploads.single.id, 42);
      expect(client.createRequest['displayName'], 'Lumen Explorer');
      expect(client.createRequest['fileName'], 'lumen.vrm');
      expect(client.createRequest['contentLength'], bytes.length);
      expect(client.createRequest['sha256'], hasLength(64));
      expect(
        client.maasoAuthorizationHeaders,
        everyElement('Bearer access-token'),
      );
      expect(client.signedPutAuthorization, isNull);
      expect(client.signedPutBytes, bytes);
      expect(client.completedUploadID, 42);
      expect(client.createRequest['coverFileName'], 'lumen-cover.png');
      expect(client.createRequest['coverContentType'], 'image/png');
      expect(
        client.createRequest['coverContentLength'],
        avatarCoverPngBytes().length,
      );
      expect(client.createRequest['coverSha256'], hasLength(64));
      expect(client.createRequest['coverWidth'], 96);
      expect(client.createRequest['coverHeight'], 144);
      expect(client.signedCoverAuthorization, isNull);
      expect(client.signedCoverBytes, avatarCoverPngBytes());
      expect(client.completeBody, isEmpty);
      expect(client.requests.map((r) => r.url.path), [
        '/v1/avatar-models/uploads',
        '/signed',
        '/cover',
        '/v1/avatar-models/uploads/42/complete',
        '/v1/avatar-models/mine',
      ]);
    },
  );

  test('lists owner upload statuses through authenticated Maaso API', () async {
    final client = _AvatarUploadClient();
    final service = await _createCatalog(client);

    final uploads = await service.listMyUploads();

    expect(uploads, hasLength(1));
    expect(uploads.single.status, AvatarUploadStatus.scanFailed);
    expect(
      uploads.single.statusMessage,
      'This model could not pass automatic checks.',
    );
    expect(
      client.maasoAuthorizationHeaders,
      everyElement('Bearer access-token'),
    );
  });

  test('rejects a non-VRM file before opening an upload session', () async {
    final client = _AvatarUploadClient();
    final service = await _createCatalog(client);
    final directory = await Directory.systemTemp.createTemp(
      'maaso-avatar-invalid',
    );
    final file = File('${directory.path}/lumen.bundle');
    await file.writeAsBytes(<int>[1]);
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      service.uploadBundle(
        file: file,
        displayName: 'Lumen',
        cover: await avatarUploadCoverFixture(),
      ),
      throwsA(isA<StateError>()),
    );
    expect(client.requests, isEmpty);
  });
  for (final failCover in [false, true]) {
    test(
      'does not complete when the ${failCover ? "cover" : "model"} PUT fails',
      () async {
        final client = _AvatarUploadClient(
          modelPutStatus: failCover ? 200 : 500,
          coverPutStatus: failCover ? 500 : 200,
        );
        final service = await _createCatalog(client);
        final directory = await Directory.systemTemp.createTemp(
          'maaso-pair-failure',
        );
        addTearDown(() => directory.delete(recursive: true));
        final model = await File(
          '${directory.path}/avatar.vrm',
        ).writeAsBytes([1, 2, 3]);
        await expectLater(
          service.uploadBundle(
            file: model,
            displayName: 'Avatar',
            cover: await avatarUploadCoverFixture(),
          ),
          throwsA(isA<StateError>()),
        );
        expect(client.completedUploadID, isNull);
        if (!failCover) expect(client.signedCoverBytes, isNull);
      },
    );
  }

  test('rejects unsafe cover storage response before completing', () async {
    for (final client in [
      _AvatarUploadClient(omitCoverMetadata: true),
      _AvatarUploadClient(coverUploadUrl: 'http://upload.example.com/cover'),
      _AvatarUploadClient(
        coverHeaders: {'content-type': 'image/png', 'Authorization': 'unsafe'},
      ),
      _AvatarUploadClient(coverHeaders: {'content-type': 'image/jpeg'}),
    ]) {
      final service = await _createCatalog(client);
      final directory = await Directory.systemTemp.createTemp(
        'maaso-pair-unsafe',
      );
      addTearDown(() => directory.delete(recursive: true));
      final model = await File(
        '${directory.path}/avatar.vrm',
      ).writeAsBytes([1]);
      await expectLater(
        service.uploadBundle(
          file: model,
          displayName: 'Avatar',
          cover: await avatarUploadCoverFixture(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(client.signedCoverBytes, isNull);
      expect(client.completedUploadID, isNull);
    }
  });

  test(
    'account switch after model PUT prevents cover PUT and completion',
    () async {
      final client = _AvatarUploadClient(
        afterModelPut: () {
          appServices
              .find<AuthSessionService>()
              .session
              .value = MaasoAuthSession(
            accountUuid: 'owner-2',
            accessToken: 'other-account',
            refreshToken: 'other-refresh',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          );
        },
      );
      final service = await _createCatalog(client);
      final directory = await Directory.systemTemp.createTemp(
        'maaso-pair-scope',
      );
      addTearDown(() => directory.delete(recursive: true));
      final model = await File(
        '${directory.path}/avatar.vrm',
      ).writeAsBytes([1]);
      await expectLater(
        service.uploadBundle(
          file: model,
          displayName: 'Avatar',
          cover: await avatarUploadCoverFixture(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(client.signedCoverBytes, isNull);
      expect(client.completedUploadID, isNull);
      expect(service.myUploads, isEmpty);
    },
  );

  test(
    'owner upload preview is optional for old records and requires HTTPS',
    () {
      final legacy = OwnAvatarUpload.fromJson(_pendingReviewUpload());
      expect(legacy.previewImageUrl, isNull);
      final ready = OwnAvatarUpload.fromJson({
        ..._pendingReviewUpload(),
        'previewImageUrl': 'https://cdn.example.com/full.png',
      });
      expect(ready.previewImageUrl, 'https://cdn.example.com/full.png');
      for (final url in [
        'http://cdn.example.com/full.png',
        'file:///cover.png',
        'javascript:alert(1)',
      ]) {
        expect(
          () => OwnAvatarUpload.fromJson({
            ..._pendingReviewUpload(),
            'previewImageUrl': url,
          }),
          throwsA(isA<StateError>()),
        );
      }
    },
  );
}

Future<AvatarModelCatalogService> _createCatalog(http.Client client) async {
  final storage = _MemorySecureStorageService();
  appServices.put<SecureStorageService>(storage);
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(httpClient: _AvatarUploadClient(failOnRequests: true)),
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
  );
}

class _AvatarUploadClient extends http.BaseClient {
  _AvatarUploadClient({
    this.failOnRequests = false,
    this.coverPutStatus = 200,
    this.modelPutStatus = 200,
    this.coverUploadUrl = 'https://upload.example.com/cover',
    this.coverHeaders = const {'content-type': 'image/png'},
    this.afterModelPut,
    this.omitCoverMetadata = false,
    List<Map<String, dynamic>>? mineUploads,
  }) : mineUploads = mineUploads ?? <Map<String, dynamic>>[_scanFailedUpload()];

  final bool failOnRequests;
  final bool omitCoverMetadata;
  final int coverPutStatus;
  final int modelPutStatus;
  final String coverUploadUrl;
  final Map<String, String> coverHeaders;
  final void Function()? afterModelPut;
  final List<Map<String, dynamic>> mineUploads;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<String?> maasoAuthorizationHeaders = <String?>[];
  final Map<String, dynamic> createRequest = <String, dynamic>{};
  String? signedPutAuthorization;
  List<int>? signedPutBytes;
  int? completedUploadID;
  String? signedCoverAuthorization;
  List<int>? signedCoverBytes;
  List<int>? completeBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (failOnRequests) {
      throw UnimplementedError('This client must not make auth refresh calls');
    }
    requests.add(request);
    final body = await request.finalize().toBytes();
    final isMaasoAPI = request.url.host == 'api-test.futurpals.com.cn';
    if (isMaasoAPI) {
      maasoAuthorizationHeaders.add(request.headers['authorization']);
    }
    if (request.url.host == 'upload.example.com') {
      if (request.url.path == '/cover') {
        signedCoverAuthorization = request.headers['authorization'];
        signedCoverBytes = body;
        return _jsonResponse(const <String, dynamic>{}, coverPutStatus);
      }
      signedPutAuthorization = request.headers['authorization'];
      signedPutBytes = body;
      afterModelPut?.call();
      return _jsonResponse(const <String, dynamic>{}, modelPutStatus);
    }
    if (request.method == 'POST' &&
        request.url.path == '/v1/avatar-models/uploads') {
      createRequest.addAll(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(body)) as Map),
      );
      return _jsonResponse({
        'code': 'OK',
        'data': {
          'uploadId': 42,
          'objectKey':
              'maaso/avatar-uploads/owner-1/00000000-0000-4000-8000-000000000001.bundle',
          'uploadUrl': 'https://upload.example.com/signed',
          'uploadHeaders': {'content-type': 'application/octet-stream'},
          'expiresAt': '2026-07-14T12:00:00Z',
          'maxBytes': 52428800,
          if (!omitCoverMetadata) ...{
            'coverUploadUrl': coverUploadUrl,
            'coverUploadHeaders': coverHeaders,
            'coverMaxBytes': AvatarModelUploadCover.maxBytes,
          },
        },
      }, 200);
    }
    if (request.method == 'POST' &&
        request.url.path == '/v1/avatar-models/uploads/42/complete') {
      completedUploadID = 42;
      completeBody = body;
      return _jsonResponse({'code': 'OK', 'data': _pendingReviewUpload()}, 200);
    }
    if (request.method == 'GET' &&
        request.url.path == '/v1/avatar-models/mine') {
      return _jsonResponse({'code': 'OK', 'data': mineUploads}, 200);
    }
    throw StateError('Unexpected request: ${request.method} ${request.url}');
  }
}

http.StreamedResponse _jsonResponse(Object body, int statusCode) =>
    http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _pendingReviewUpload() => <String, dynamic>{
  'id': 42,
  'displayName': 'Lumen Explorer',
  'fileName': 'lumen.bundle',
  'status': 'pending_review',
  'modelId': null,
  'createdAt': '2026-07-14T10:00:00Z',
  'updatedAt': '2026-07-14T10:01:00Z',
};

Map<String, dynamic> _scanFailedUpload() => <String, dynamic>{
  'id': 42,
  'displayName': 'Lumen Explorer',
  'fileName': 'lumen.bundle',
  'status': 'scan_failed',
  'statusMessage': 'This model could not pass automatic checks.',
  'modelId': null,
  'createdAt': '2026-07-14T10:00:00Z',
  'updatedAt': '2026-07-14T10:01:00Z',
};

class _MemorySecureStorageService extends SecureStorageService {
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
