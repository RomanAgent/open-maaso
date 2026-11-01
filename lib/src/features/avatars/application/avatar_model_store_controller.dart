import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:path/path.dart' as path;

import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

/// Coordinates the Model Store while keeping API and file streaming in the
/// catalog service.
class AvatarModelStoreController extends AppController {
  AvatarModelStoreController({
    AvatarModelStoreGateway? catalog,
    AvatarConfigService? avatars,
  }) : _catalog = catalog ?? appServices.find<AvatarModelCatalogService>(),
       _avatars = avatars ?? appServices.find<AvatarConfigService>(),
       _accountScopes = appServices.maybeFind<AccountStorageScopeService>() {
    _mount = _accountScopes?.activeMount;
  }

  final AvatarModelStoreGateway _catalog;
  final AvatarConfigService _avatars;
  final AccountStorageScopeService? _accountScopes;
  AccountStorageScopeMount? _mount;

  bool get _accountCurrent =>
      !isClosed &&
      identical(
        _accountScopes,
        appServices.maybeFind<AccountStorageScopeService>(),
      ) &&
      identical(_mount, _accountScopes?.activeMount) &&
      (_accountScopes == null || _mount != null);

  AvatarConfigService get avatars => _avatars;

  final reviewedModels = <ApprovedAvatarModel>[].obs;
  final myUploads = <OwnAvatarUpload>[].obs;
  final isCatalogLoading = false.obs;
  final isUploadsLoading = false.obs;
  final isUploading = false.obs;
  final catalogError = RxnString();
  final uploadsError = RxnString();

  Future<void> load() async {
    await Future.wait<void>([refreshFreeModels(), refreshMyUploads()]);
  }

  Future<void> refreshFreeModels() async {
    isCatalogLoading.value = true;
    catalogError.value = null;
    try {
      final models = await _catalog.listApprovedModels();
      if (!_accountCurrent) return;
      // Gate stale/cached gateways as well as the HTTP catalog. Retired
      // products must not reappear as diagnostic-only cards in the picker.
      reviewedModels.assignAll(
        models.where((model) => !model.isRetiredOfficial),
      );
      _avatars.replaceReviewedOptions(
        models
            .where((model) => model.isLoadableOnDevice)
            .map((model) => model.toAvatarOption()),
      );
    } catch (exception) {
      catalogError.value = _messageFor(exception);
    } finally {
      isCatalogLoading.value = false;
    }
  }

  Future<void> refreshMyUploads() async {
    isUploadsLoading.value = true;
    uploadsError.value = null;
    try {
      final uploads = await _catalog.listMyUploads();
      if (_accountCurrent) myUploads.assignAll(uploads);
    } catch (exception) {
      uploadsError.value = _messageFor(exception);
    } finally {
      isUploadsLoading.value = false;
    }
  }

  Future<void> select(
    AvatarOption option, {
    String? expectedAssetVersionDigest,
  }) => _avatars.select(
    option.id,
    expectedAssetVersionDigest: expectedAssetVersionDigest,
  );

  /// No session or storage object is created until both local files have been
  /// selected and their complete cover preview explicitly confirmed.
  Future<OwnAvatarUpload?> pickAndUpload(
    Future<PlatformFile?> Function() pickFile, {
    required Future<PlatformFile?> Function() pickCover,
    required Future<bool> Function(String, AvatarModelUploadCover) confirm,
  }) async {
    if (!_accountCurrent || isUploading.value) return null;
    isUploading.value = true;
    uploadsError.value = null;
    try {
      final picked = await pickFile();
      if (picked == null || !_accountCurrent) return null;

      final name = picked.name.trim();
      if (!name.toLowerCase().endsWith('.vrm')) {
        throw StateError('Only VRM 1.0 .vrm model files can be uploaded');
      }
      final selectedPath = picked.path?.trim() ?? '';
      if (selectedPath.isEmpty) {
        throw StateError(
          'This upload requires a local file path and is available in the native app.',
        );
      }
      final displayName = path.basenameWithoutExtension(name).trim();
      if (displayName.isEmpty) {
        throw StateError('Give the VRM model a name before uploading it');
      }

      final selectedCover = await pickCover();
      if (selectedCover == null || !_accountCurrent) return null;
      final coverPath = selectedCover.path?.trim() ?? '';
      final AvatarModelUploadCover cover;
      if (selectedCover.size > AvatarModelUploadCover.maxBytes) {
        throw const AvatarUploadCoverException('size');
      }
      if (coverPath.isNotEmpty) {
        cover = await AvatarModelUploadCover.fromFile(
          File(coverPath),
          fileName: selectedCover.name,
        );
      } else {
        cover = await AvatarModelUploadCover.fromBytes(
          fileName: selectedCover.name,
          bytes: await selectedCover.readAsBytes(),
        );
      }
      if (!_accountCurrent ||
          !await confirm(displayName, cover) ||
          !_accountCurrent) {
        return null;
      }
      final uploaded = await _catalog.uploadBundle(
        file: File(selectedPath),
        displayName: displayName,
        cover: cover,
      );
      if (!_accountCurrent) return null;
      await refreshMyUploads();
      return _accountCurrent ? uploaded : null;
    } catch (exception) {
      if (_accountCurrent) uploadsError.value = _messageFor(exception);
      rethrow;
    } finally {
      if (_accountCurrent) isUploading.value = false;
    }
  }

  String _messageFor(Object exception) =>
      exception.toString().replaceFirst('Bad state: ', '');
}
