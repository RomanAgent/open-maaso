import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';

import 'helpers/avatar_upload_cover_fixture.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('loads free reviewed models and owner uploads independently', () async {
    final avatars = AvatarConfigService();
    final controller = AvatarModelStoreController(
      catalog: _FakeAvatarModelStoreGateway(),
      avatars: avatars,
    );

    await controller.load();

    expect(
      avatars.catalog.where((option) => option.remoteModelId != null),
      hasLength(1),
    );
    expect(controller.myUploads, hasLength(1));
    expect(controller.catalogError.value, isNull);
    expect(controller.uploadsError.value, isNull);
  });

  test('keeps free models available when owner upload refresh fails', () async {
    final avatars = AvatarConfigService();
    final controller = AvatarModelStoreController(
      catalog: _FakeAvatarModelStoreGateway(failMine: true),
      avatars: avatars,
    );

    await controller.load();

    expect(
      avatars.catalog.where((option) => option.remoteModelId != null),
      hasLength(1),
    );
    expect(controller.uploadsError.value, isNotNull);
  });

  test(
    'keeps blocker diagnostics out of the selectable and persisted catalog',
    () async {
      final avatars = AvatarConfigService()
        ..selectedId.value = 'reviewed-model-27';
      final controller = AvatarModelStoreController(
        catalog: _FakeAvatarModelStoreGateway(includeBlocked: true),
        avatars: avatars,
      );

      await controller.refreshFreeModels();

      expect(controller.reviewedModels, hasLength(2));
      expect(avatars.catalog.map((option) => option.id), [
        'agent',
        'reviewed-model-24',
      ]);
      expect(avatars.selectedId.value, 'agent');
    },
  );

  test(
    'delegates reviewed selection only to the authoritative avatar config',
    () async {
      final avatars = _RecordingAvatarConfigService();
      final catalog = _FakeAvatarModelStoreGateway();
      final controller = AvatarModelStoreController(
        catalog: catalog,
        avatars: avatars,
      );

      await controller.load();
      final model = avatars.catalog.singleWhere(
        (option) => option.remoteModelId == 24,
      );
      await controller.select(model);

      expect(avatars.selectedIds, [model.id]);
      expect(catalog.listApprovedCount, 1);
    },
  );

  test(
    'uploads the picked VRM with a trimmed display name and refreshes mine',
    () async {
      final catalog = _FakeAvatarModelStoreGateway();
      final controller = AvatarModelStoreController(
        catalog: catalog,
        avatars: AvatarConfigService(),
      );
      final file = File('${Directory.systemTemp.path}/lumen-upload.vrm');
      await file.writeAsString('vrm');
      addTearDown(file.delete);

      final upload = await controller.pickAndUpload(
        () async => PlatformFile(
          name: '  Lumen Explorer .vrm  ',
          size: 3,
          path: file.path,
        ),
        pickCover: _pickCover,
        confirm: (_, _) async => true,
      );

      expect(upload, isNotNull);
      expect(catalog.uploadDisplayNames, ['Lumen Explorer']);
      expect(catalog.listApprovedCount, 0);
      expect(catalog.listMineCount, 1);
    },
  );

  test('does not report an error when the file picker is cancelled', () async {
    final controller = AvatarModelStoreController(
      catalog: _FakeAvatarModelStoreGateway(),
      avatars: AvatarConfigService(),
    );

    final upload = await controller.pickAndUpload(
      () async => null,
      pickCover: () => throw StateError('No model picked'),
      confirm: (_, _) => throw StateError('No model picked'),
    );

    expect(upload, isNull);
    expect(controller.uploadsError.value, isNull);
  });

  test(
    'explains that a pathless browser selection needs the native app',
    () async {
      final controller = AvatarModelStoreController(
        catalog: _FakeAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );

      await expectLater(
        controller.pickAndUpload(
          () async => PlatformFile(name: 'lumen.vrm', size: 3),
          pickCover: () => throw StateError('Invalid VRM selection'),
          confirm: (_, _) => throw StateError('Invalid VRM selection'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(controller.uploadsError.value, contains('native app'));
    },
  );
  for (final cancelStep in ['cover', 'confirmation']) {
    test('cancelling $cancelStep creates no upload', () async {
      final gateway = _FakeAvatarModelStoreGateway();
      final controller = AvatarModelStoreController(
        catalog: gateway,
        avatars: AvatarConfigService(),
      );
      final result = await controller.pickAndUpload(
        () async =>
            PlatformFile(name: 'model.vrm', size: 1, path: '/tmp/model.vrm'),
        pickCover: () async =>
            cancelStep == 'cover' ? null : await _pickCover(),
        confirm: (_, cover) async {
          expect(gateway.uploadDisplayNames, isEmpty);
          expect(cover.width, 96);
          return false;
        },
      );
      expect(result, isNull);
      expect(gateway.uploadDisplayNames, isEmpty);
      expect(gateway.listMineCount, 0);
      expect(controller.isUploading.value, isFalse);
    });
  }

  test('rejects a bad cover before confirmation and upload', () async {
    final gateway = _FakeAvatarModelStoreGateway();
    final controller = AvatarModelStoreController(
      catalog: gateway,
      avatars: AvatarConfigService(),
    );
    await expectLater(
      controller.pickAndUpload(
        () async =>
            PlatformFile(name: 'model.vrm', size: 1, path: '/tmp/model.vrm'),
        pickCover: () async => PlatformFile(
          name: 'cover.jpg',
          size: 1,
          bytes: avatarCoverPngBytes(),
        ),
        confirm: (_, _) =>
            throw StateError('Invalid cover must never be confirmed'),
      ),
      throwsA(isA<AvatarUploadCoverException>()),
    );
    expect(gateway.uploadDisplayNames, isEmpty);
  });

  test(
    'does not duplicate uploads while waiting for a cover confirmation',
    () async {
      final gateway = _FakeAvatarModelStoreGateway();
      final controller = AvatarModelStoreController(
        catalog: gateway,
        avatars: AvatarConfigService(),
      );
      final ready = Completer<void>();
      final decision = Completer<bool>();
      final first = controller.pickAndUpload(
        () async =>
            PlatformFile(name: 'model.vrm', size: 1, path: '/tmp/model.vrm'),
        pickCover: _pickCover,
        confirm: (_, _) {
          ready.complete();
          return decision.future;
        },
      );
      await ready.future;
      final second = await controller.pickAndUpload(
        () => throw StateError('A second picker must not open'),
        pickCover: _pickCover,
        confirm: (_, _) async => true,
      );
      expect(second, isNull);
      expect(gateway.uploadDisplayNames, isEmpty);
      decision.complete(true);
      await first;
      expect(gateway.uploadDisplayNames, ['model']);
    },
  );

  test(
    'switching account or disposing during confirmation prevents upload',
    () async {
      for (final dispose in [false, true]) {
        final scopes = appServices.put(AccountStorageScopeService());
        if (scopes.activeMount case final active?) scopes.unmount(active);
        final mount = scopes.mount(
          AccountStorageScope(environmentKey: 'test', accountUuid: 'owner'),
        );
        final gateway = _FakeAvatarModelStoreGateway();
        final controller = AvatarModelStoreController(
          catalog: gateway,
          avatars: AvatarConfigService(),
        );
        final result = await controller.pickAndUpload(
          () async =>
              PlatformFile(name: 'model.vrm', size: 1, path: '/tmp/model.vrm'),
          pickCover: _pickCover,
          confirm: (_, _) async {
            if (dispose) {
              controller.closeLifecycle();
            } else {
              scopes.unmount(mount);
              scopes.mount(
                AccountStorageScope(
                  environmentKey: 'test',
                  accountUuid: 'next',
                ),
              );
            }
            return true;
          },
        );
        expect(result, isNull);
        expect(gateway.uploadDisplayNames, isEmpty);
      }
    },
  );
}

class _FakeAvatarModelStoreGateway implements AvatarModelStoreGateway {
  _FakeAvatarModelStoreGateway({
    this.failMine = false,
    this.includeBlocked = false,
  });

  final bool failMine;
  final bool includeBlocked;
  final uploadDisplayNames = <String>[];
  var listApprovedCount = 0;
  var listMineCount = 0;

  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async {
    listApprovedCount++;
    return <ApprovedAvatarModel>[
      ApprovedAvatarModel(
        id: 24,
        modelKey: 'community.lumen.v1',
        displayName: 'Lumen Explorer',
        modelSource: 'community',
        assetUrl: 'https://assets.example.com/lumen.bundle',
        assetSha256: 'a' * 64,
        runtimeConfig: const {'assetName': 'Avatar/Lumen'},
        compatibility: const {
          'backends': ['unity'],
        },
      ),
      if (includeBlocked)
        ApprovedAvatarModel(
          id: 27,
          modelKey: 'community.blocked.v1',
          displayName: 'Needs Rig Fix',
          modelSource: 'community',
          assetUrl: 'https://assets.example.com/blocked.bundle',
          assetSha256: 'b' * 64,
          runtimeConfig: const {'assetName': 'Avatar/Blocked'},
          compatibility: const {
            'backends': ['unity'],
          },
          capabilityProfile: AvatarCapabilityProfile.fromJson(const {
            'schemaVersion': 1,
            'source': 'catalog',
            'state': 'incompatible',
            'rig': {
              'humanoid': false,
              'head': true,
              'leftEye': true,
              'rightEye': true,
            },
            'behavior': {
              'lookAt': true,
              'lipSync': true,
              'blink': true,
              'expressions': true,
            },
            'render': {'renderable': true},
            'issues': [
              {'code': 'missing_humanoid', 'severity': 'blocker'},
            ],
          }),
        ),
    ];
  }

  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async {
    listMineCount++;
    if (failMine) throw StateError('Owner upload list unavailable');
    return <OwnAvatarUpload>[
      OwnAvatarUpload(
        id: 42,
        displayName: 'Lumen Explorer',
        fileName: 'lumen.vrm',
        status: AvatarUploadStatus.pendingReview,
        statusMessage: null,
        modelId: null,
        createdAt: DateTime.utc(2026, 7, 14, 10),
        updatedAt: DateTime.utc(2026, 7, 14, 10, 1),
      ),
    ];
  }

  @override
  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  }) async {
    uploadDisplayNames.add(displayName);
    return OwnAvatarUpload(
      id: 43,
      displayName: displayName,
      fileName: file.uri.pathSegments.last,
      status: AvatarUploadStatus.pendingReview,
      statusMessage: null,
      modelId: null,
      createdAt: DateTime.utc(2026, 7, 14, 10),
      updatedAt: DateTime.utc(2026, 7, 14, 10, 1),
    );
  }
}

class _RecordingAvatarConfigService extends AvatarConfigService {
  final selectedIds = <String>[];

  @override
  Future<void> select(String id, {String? expectedAssetVersionDigest}) async {
    selectedIds.add(id);
  }
}

Future<PlatformFile> _pickCover() async {
  final bytes = avatarCoverPngBytes();
  return PlatformFile(name: 'cover.png', size: bytes.length, bytes: bytes);
}
