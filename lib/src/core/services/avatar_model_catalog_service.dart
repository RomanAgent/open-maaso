import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_selection_coordinator.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';

/// A server-reviewed, Unity-compatible avatar descriptor.
///
/// The app deliberately accepts only HTTPS model URLs from this catalog. Raw
/// uploads never reach the renderer from Flutter; the Maaso service controls
/// approval and the object-storage descriptor.
class AvatarPlatformAsset {
  const AvatarPlatformAsset({
    required this.platform,
    required this.bundleVersion,
    required this.assetUrl,
    required this.assetSha256,
    required this.assetBytes,
    required this.runtimeConfig,
    this.capabilityProfile = AvatarCapabilityProfile.unknown,
  });

  final String platform;
  final String bundleVersion;
  final String assetUrl;
  final String assetSha256;
  final int assetBytes;
  final Map<String, dynamic> runtimeConfig;
  final AvatarCapabilityProfile capabilityProfile;

  factory AvatarPlatformAsset.fromJson(
    String mapKey,
    Map<String, dynamic> json,
  ) {
    final platform = _requiredString(json, 'platform').toLowerCase();
    if (platform != mapKey || !_supportedAvatarPlatforms.contains(platform)) {
      throw StateError('Avatar model response has an invalid platform');
    }
    final assetSha256 = _requiredString(json, 'assetSha256').toLowerCase();
    if (!_sha256Pattern.hasMatch(assetSha256)) {
      throw StateError('Avatar model response has an invalid assetSha256');
    }
    final assetBytes = _requiredInt(json, 'assetBytes');
    if (assetBytes <= 0) {
      throw StateError('Avatar model response has an invalid assetBytes');
    }
    final runtimeConfig = _objectMap(json['runtimeConfig']);
    return AvatarPlatformAsset(
      platform: platform,
      bundleVersion: _requiredString(json, 'bundleVersion'),
      assetUrl: _approvedHttpsUrl(_requiredString(json, 'assetUrl')),
      assetSha256: assetSha256,
      assetBytes: assetBytes,
      runtimeConfig: runtimeConfig,
      capabilityProfile: AvatarCapabilityProfile.fromJson(
        json['capabilityProfile'] ?? runtimeConfig['capabilityProfile'],
      ),
    );
  }
}

class ApprovedAvatarModel {
  const ApprovedAvatarModel({
    required this.id,
    required this.modelKey,
    required this.displayName,
    required this.modelSource,
    required this.assetUrl,
    required this.assetSha256,
    required this.runtimeConfig,
    required this.compatibility,
    this.previewImageUrl,
    this.platformAssets = const {},
    this.selectedPlatform,
    this.assetBytes,
    this.bundleVersion,
    this.voiceGender = AvatarVoiceGender.unspecified,
    this.preferredVoiceSid,
    this.capabilityProfile = AvatarCapabilityProfile.unknown,
  });

  final int id;
  final String modelKey;
  final String displayName;
  final String modelSource;
  final String assetUrl;
  final String assetSha256;
  final Map<String, dynamic> runtimeConfig;
  final Map<String, dynamic> compatibility;
  final String? previewImageUrl;
  final Map<String, AvatarPlatformAsset> platformAssets;
  final String? selectedPlatform;
  final int? assetBytes;
  final String? bundleVersion;
  final AvatarVoiceGender voiceGender;
  final int? preferredVoiceSid;
  final AvatarCapabilityProfile capabilityProfile;

  bool get isUnityCompatible {
    final backends = compatibility['backends'];
    if (backends is! Iterable) return false;
    return backends.any(
      (backend) => backend.toString().trim().toLowerCase() == 'unity',
    );
  }

  String get assetFormat =>
      runtimeConfig['assetFormat']?.toString().trim().toLowerCase() ?? '';

  bool get isVrm => assetFormat == 'vrm' || assetFormat == 'vrm_1_0';

  bool get isRetiredOfficial => BundledAvatarContract.isRetiredOfficial(
    modelKey: modelKey,
    modelSource: modelSource,
    assetUrl: assetUrl,
  );

  bool get isBundledMatt =>
      !isRetiredOfficial &&
      BundledAvatarContract.isMatt(
        modelId: id,
        modelKey: modelKey,
        modelSource: modelSource,
        assetUrl: assetUrl,
        assetSha256: assetSha256,
        runtimeConfig: runtimeConfig,
        compatibility: compatibility,
      );

  /// Whether the reviewed descriptor is structurally safe to offer in the
  /// store. Runtime capability blockers remain visible but cannot be selected.
  bool get hasExecutableDescriptor {
    if (isRetiredOfficial) return false;
    if (assetUrl.startsWith('unity://') ||
        modelKey == BundledAvatarContract.mattModelKey) {
      return isBundledMatt;
    }
    if (isVrm) return isUnityCompatible;
    final assetName = runtimeConfig['assetName']?.toString().trim() ?? '';
    return isUnityCompatible &&
        assetName.isNotEmpty &&
        !assetName.contains('..') &&
        RegExp(r'^[A-Za-z0-9_/-]+$').hasMatch(assetName);
  }

  /// The exact review contract consumed by the Unity bridge. Compatibility
  /// metadata alone is not enough to execute a remote asset.
  bool get isLoadableOnDevice =>
      hasExecutableDescriptor && !capabilityProfile.hasBlockers;

  AvatarOption toAvatarOption() => AvatarOption(
    id: 'reviewed-model-$id',
    name: displayName,
    backend: AvatarBackendKind.unity,
    modelUrl: assetUrl,
    config: {
      ...runtimeConfig,
      'approvedAssetSha256': assetSha256,
      'modelKey': modelKey,
      if (assetBytes != null) 'approvedAssetBytes': assetBytes,
      if (bundleVersion != null) 'bundleVersion': bundleVersion,
      if (selectedPlatform != null) 'platform': selectedPlatform,
      if (capabilityProfile.isDeclared)
        'capabilityProfile': capabilityProfile.toJson(),
    },
    previewImageUrl: previewImageUrl,
    previewAssetPath: isBundledMatt
        ? BundledAvatarContract.mattPreviewAsset
        : null,
    remoteModelId: id,
    modelSource: modelSource,
    voiceGender: voiceGender,
    preferredVoiceSid: preferredVoiceSid,
  );

  factory ApprovedAvatarModel.fromJson(
    Map<String, dynamic> json, {
    String? platform,
  }) {
    final id = _requiredInt(json, 'id');
    final modelKey = _requiredString(json, 'modelKey');
    final displayName = _requiredString(json, 'displayName');
    final modelSource = _requiredString(json, 'modelSource');
    final previewImageUrl = _optionalApprovedHttpsUrl(json['previewImageUrl']);
    final catalogCapabilityProfile = AvatarCapabilityProfile.fromJson(
      json['capabilityProfile'],
    );
    final platformAssets = _platformAssets(json['platformAssets']);
    if (modelKey == BundledAvatarContract.mattModelKey &&
        platformAssets.isNotEmpty) {
      throw StateError('Bundled Matt cannot use remote platform variants');
    }
    if (platformAssets.isNotEmpty) {
      if (!_requiredAvatarPlatforms.every(platformAssets.containsKey)) {
        throw StateError(
          'Avatar model response is missing a required platform asset',
        );
      }
      final normalizedPlatform = platform?.trim().toLowerCase() ?? '';
      final selectedAsset = platformAssets[normalizedPlatform];
      if (selectedAsset == null) {
        throw StateError(
          'Avatar model response is missing the current platform asset',
        );
      }
      return ApprovedAvatarModel(
        id: id,
        modelKey: modelKey,
        displayName: displayName,
        modelSource: modelSource,
        assetUrl: selectedAsset.assetUrl,
        assetSha256: selectedAsset.assetSha256,
        runtimeConfig: selectedAsset.runtimeConfig,
        compatibility: _objectMap(json['compatibility']),
        previewImageUrl: previewImageUrl,
        platformAssets: platformAssets,
        selectedPlatform: normalizedPlatform,
        assetBytes: selectedAsset.assetBytes,
        bundleVersion: selectedAsset.bundleVersion,
        voiceGender: _avatarVoiceGender(
          json,
          modelKey: modelKey,
          runtimeConfig: selectedAsset.runtimeConfig,
        ),
        preferredVoiceSid: _preferredAvatarVoiceSid(
          json,
          runtimeConfig: selectedAsset.runtimeConfig,
        ),
        capabilityProfile: selectedAsset.capabilityProfile.isDeclared
            ? selectedAsset.capabilityProfile
            : catalogCapabilityProfile,
      );
    }
    final rawAssetUrl = _requiredString(json, 'assetUrl');
    final assetUrl = rawAssetUrl == BundledAvatarContract.mattAssetUrl
        ? rawAssetUrl
        : _approvedHttpsUrl(rawAssetUrl);
    final assetSha256 = _requiredString(json, 'assetSha256').toLowerCase();
    if (!_sha256Pattern.hasMatch(assetSha256)) {
      throw StateError('Avatar model response has an invalid assetSha256');
    }
    final runtimeConfig = _objectMap(json['runtimeConfig']);
    final compatibility = _objectMap(json['compatibility']);
    if ((assetUrl == BundledAvatarContract.mattAssetUrl ||
            modelKey == BundledAvatarContract.mattModelKey) &&
        !BundledAvatarContract.isKnownMatt(
          modelId: id,
          modelKey: modelKey,
          modelSource: modelSource,
          assetUrl: assetUrl,
          assetSha256: assetSha256,
          runtimeConfig: runtimeConfig,
          compatibility: compatibility,
        )) {
      throw StateError(
        'Avatar model response has an invalid bundled Matt identity',
      );
    }
    if (modelKey == BundledAvatarContract.mattModelKey &&
        (_avatarVoiceGender(
                  json,
                  modelKey: modelKey,
                  runtimeConfig: runtimeConfig,
                ) !=
                AvatarVoiceGender.male ||
            _preferredAvatarVoiceSid(json, runtimeConfig: runtimeConfig) !=
                AvatarVoiceService.defaultMaleSid)) {
      throw StateError('Bundled Matt has an invalid voice assignment');
    }
    return ApprovedAvatarModel(
      id: id,
      modelKey: modelKey,
      displayName: displayName,
      modelSource: modelSource,
      assetUrl: assetUrl,
      assetSha256: assetSha256,
      runtimeConfig: runtimeConfig,
      compatibility: compatibility,
      previewImageUrl: previewImageUrl,
      voiceGender: _avatarVoiceGender(
        json,
        modelKey: modelKey,
        runtimeConfig: runtimeConfig,
      ),
      preferredVoiceSid: _preferredAvatarVoiceSid(
        json,
        runtimeConfig: runtimeConfig,
      ),
      capabilityProfile: AvatarCapabilityProfile.fromJson(
        json['capabilityProfile'] ?? runtimeConfig['capabilityProfile'],
      ),
    );
  }
}

AvatarVoiceGender _avatarVoiceGender(
  Map<String, dynamic> json, {
  required String modelKey,
  required Map<String, dynamic> runtimeConfig,
}) {
  final voiceProfile = _objectMap(json['voiceProfile']);
  final explicit = AvatarVoiceGender.fromValue(
    json['voiceGender'] ??
        voiceProfile['gender'] ??
        runtimeConfig['voiceGender'],
  );
  if (explicit != AvatarVoiceGender.unspecified) return explicit;

  // Compatibility for the two reviewed official models published before the
  // API gained voice metadata. Do not infer arbitrary uploads from names.
  return switch (modelKey.trim().toLowerCase()) {
    'modular-anime-female' ||
    'masso.official.modular-female' => AvatarVoiceGender.female,
    'modular-anime-male' ||
    'masso.official.modular-male' => AvatarVoiceGender.male,
    _ => AvatarVoiceGender.unspecified,
  };
}

int? _preferredAvatarVoiceSid(
  Map<String, dynamic> json, {
  required Map<String, dynamic> runtimeConfig,
}) {
  final voiceProfile = _objectMap(json['voiceProfile']);
  final value =
      json['preferredVoiceSid'] ??
      voiceProfile['localSid'] ??
      runtimeConfig['preferredVoiceSid'];
  final sid = value is int ? value : int.tryParse(value?.toString() ?? '');
  return sid != null && sid >= 0 && sid <= 9 ? sid : null;
}

enum AvatarUploadStatus {
  pendingUpload('pending_upload'),
  pendingScan('pending_scan'),
  scanFailed('scan_failed'),
  pendingReview('pending_review'),
  approved('approved'),
  rejected('rejected');

  const AvatarUploadStatus(this.value);

  final String value;

  static AvatarUploadStatus fromJson(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final status in AvatarUploadStatus.values) {
      if (status.value == normalized) return status;
    }
    throw StateError('Avatar upload response has an invalid status');
  }
}

class AvatarUploadSession {
  const AvatarUploadSession({
    required this.uploadId,
    required this.objectKey,
    required this.uploadUrl,
    required this.uploadHeaders,
    required this.expiresAt,
    required this.maxBytes,
    required this.coverUploadUrl,
    required this.coverUploadHeaders,
    required this.coverMaxBytes,
  });

  final int uploadId;
  final String objectKey;
  final Uri uploadUrl;
  final Map<String, String> uploadHeaders;
  final DateTime expiresAt;
  final int maxBytes;
  final Uri coverUploadUrl;
  final Map<String, String> coverUploadHeaders;
  final int coverMaxBytes;

  factory AvatarUploadSession.fromJson(Map<String, dynamic> json) {
    final uploadId = _requiredInt(json, 'uploadId');
    final objectKey = _requiredString(json, 'objectKey');
    final uploadUrl = Uri.tryParse(_requiredString(json, 'uploadUrl'));
    if (uploadUrl == null ||
        uploadUrl.scheme != 'https' ||
        uploadUrl.host.isEmpty) {
      throw StateError('Avatar upload response has an invalid uploadUrl');
    }
    final expiresAt = DateTime.tryParse(_requiredString(json, 'expiresAt'));
    if (expiresAt == null) {
      throw StateError('Avatar upload response has an invalid expiresAt');
    }
    final maxBytes = _requiredInt(json, 'maxBytes');
    final headers = _stringMap(json['uploadHeaders']);
    if (headers.isEmpty) {
      throw StateError('Avatar upload response is missing uploadHeaders');
    }
    final coverUploadUrl = Uri.tryParse(
      _requiredString(json, 'coverUploadUrl'),
    );
    if (coverUploadUrl == null ||
        coverUploadUrl.scheme != 'https' ||
        coverUploadUrl.host.isEmpty ||
        coverUploadUrl.userInfo.isNotEmpty) {
      throw StateError('Avatar upload response has an invalid coverUploadUrl');
    }
    final coverUploadHeaders = _stringMap(json['coverUploadHeaders']);
    if (coverUploadHeaders.isEmpty) {
      throw StateError('Avatar upload response is missing coverUploadHeaders');
    }
    final coverMaxBytes = _requiredInt(json, 'coverMaxBytes');
    if (coverMaxBytes <= 0) {
      throw StateError('Avatar upload response has an invalid coverMaxBytes');
    }
    return AvatarUploadSession(
      uploadId: uploadId,
      objectKey: objectKey,
      uploadUrl: uploadUrl,
      uploadHeaders: headers,
      expiresAt: expiresAt.toUtc(),
      maxBytes: maxBytes,
      coverUploadUrl: coverUploadUrl,
      coverUploadHeaders: coverUploadHeaders,
      coverMaxBytes: coverMaxBytes,
    );
  }
}

class OwnAvatarUpload {
  const OwnAvatarUpload({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.status,
    required this.statusMessage,
    required this.modelId,
    required this.createdAt,
    required this.updatedAt,
    this.previewImageUrl,
  });

  final int id;
  final String displayName;
  final String fileName;
  final AvatarUploadStatus status;
  final String? statusMessage;
  final int? modelId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? previewImageUrl;

  factory OwnAvatarUpload.fromJson(Map<String, dynamic> json) {
    final statusMessage = json['statusMessage']?.toString().trim();
    final modelId = json['modelId'];
    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAt'));
    final updatedAt = DateTime.tryParse(_requiredString(json, 'updatedAt'));
    if (createdAt == null || updatedAt == null) {
      throw StateError('Avatar upload response has invalid timestamps');
    }
    final previewImageUrl = _optionalApprovedHttpsUrl(json['previewImageUrl']);
    if (previewImageUrl != null &&
        Uri.parse(previewImageUrl).userInfo.isNotEmpty) {
      throw StateError('Avatar upload response has an invalid previewImageUrl');
    }
    return OwnAvatarUpload(
      id: _requiredInt(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      fileName: _requiredString(json, 'fileName'),
      status: AvatarUploadStatus.fromJson(json['status']),
      statusMessage: statusMessage == null || statusMessage.isEmpty
          ? null
          : statusMessage,
      modelId: modelId == null ? null : _requiredInt(json, 'modelId'),
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      previewImageUrl: previewImageUrl,
    );
  }
}

/// Narrow catalog contract used by the model-store coordinator.
///
/// The concrete service keeps all authenticated API and streaming upload work;
/// this interface makes the page state testable without an HTTP client.
abstract interface class AvatarModelStoreGateway {
  Future<List<ApprovedAvatarModel>> listApprovedModels();

  Future<List<OwnAvatarUpload>> listMyUploads();

  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  });
}

/// Authenticated client for the Maaso reviewed-avatar catalog.
class AvatarModelCatalogService extends AppService
    implements
        AvatarModelStoreGateway,
        AvatarSelectionTransport,
        AvatarSelectionRecoveryTransport {
  AvatarModelCatalogService({
    required MaasoAuthSession accountSession,
    required AccountStorageScopeMount accountMount,
    required AgentStorageScope agentScope,
    required AccountStorageScopeService storageScopes,
    http.Client? httpClient,
    TargetPlatform? targetPlatform,
    Duration selectionRequestTimeout = const Duration(seconds: 15),
  }) : _accountUuid = accountSession.accountUuid,
       _accountMount = accountMount,
       _storageScopes = storageScopes,
       _accountScopeDigest = accountMount.scope.accountDigest,
       _agentScopeDigest = agentScope.agentDigest,
       _agentId = agentScope.agentId,
       _ownerGeneration = accountMount.generation,
       _targetPlatform = targetPlatform ?? defaultTargetPlatform,
       _selectionRequestTimeout = selectionRequestTimeout,
       _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null {
    final environment = _requiredAvatarEnvironment(
      accountMount.scope.environmentKey,
    );
    if (accountSession.accountUuid.trim().isEmpty ||
        accountSession.accountUuid != accountSession.accountUuid.trim() ||
        !accountSession.isValid) {
      throw ArgumentError.value(
        accountSession.accountUuid,
        'accountSession.accountUuid',
        'must identify the valid mounted account',
      );
    }
    if (accountMount.scope.accountUuid != accountSession.accountUuid ||
        agentScope.accountScope != accountMount.scope ||
        !storageScopes.isCurrent(accountMount)) {
      throw ArgumentError(
        'Avatar selection account, mount, and agent scopes must match',
      );
    }
    if (selectionRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        selectionRequestTimeout,
        'selectionRequestTimeout',
        'must be positive',
      );
    }
    _environmentKey = environment.key;
    _baseUri = Uri.parse('${environment.baseUrl}/');
    if (_environment.environment.value.key != _environmentKey) {
      throw StateError(
        'The reviewed avatar environment does not match the account mount',
      );
    }
    _recoveryAccessToken = accountSession.accessToken;
    _sessionWorker = _auth.session.listen(_handlePublishedAvatarSession);
    _handlePublishedAvatarSession(_auth.session.value);
  }

  final AppEnvironmentService _environment = appServices
      .find<AppEnvironmentService>();
  final AuthSessionService _auth = appServices.find<AuthSessionService>();
  final String _accountUuid;
  final AccountStorageScopeMount _accountMount;
  final AccountStorageScopeService _storageScopes;
  final String _accountScopeDigest;
  final String _agentScopeDigest;
  final String _agentId;
  final int _ownerGeneration;
  late final String _environmentKey;
  late final Uri _baseUri;
  final http.Client _httpClient;
  final bool _ownsClient;
  final TargetPlatform _targetPlatform;
  final Duration _selectionRequestTimeout;
  Worker? _sessionWorker;
  late String _recoveryAccessToken;
  bool _closed = false;

  final models = <ApprovedAvatarModel>[].obs;
  final myUploads = <OwnAvatarUpload>[].obs;
  final isLoading = false.obs;
  final error = RxnString();
  final isUploading = false.obs;
  final uploadError = RxnString();

  AvatarSelectionAssetOptions get selectionAssetOptions =>
      _targetPlatform == TargetPlatform.fuchsia ||
          _targetPlatform == TargetPlatform.linux
      ? const AvatarSelectionAssetOptions.none()
      : _avatarAssetOptions(_targetPlatform);

  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async {
    final assetOptions = _avatarAssetOptions(_targetPlatform);
    final platform = assetOptions.platform;
    final exposesDesktopDiagnostics =
        _targetPlatform == TargetPlatform.macOS ||
        _targetPlatform == TargetPlatform.windows;
    final data = await _request(
      _baseUri
          .resolve('v1/avatar-models')
          .replace(
            queryParameters: <String, String>{
              'platformAssets': assetOptions.platformAssets.toString(),
              'platform': ?platform,
              'builtinCatalogVersion': assetOptions.builtinCatalogVersion
                  .toString(),
            },
          ),
      method: 'GET',
    );
    if (data is! List) {
      throw StateError('Avatar model catalog response is invalid');
    }
    final result = <ApprovedAvatarModel>[];
    for (final item in data) {
      if (item is! Map) continue;
      try {
        final model = ApprovedAvatarModel.fromJson(
          Map<String, dynamic>.from(item),
          platform: platform,
        );
        if (model.hasExecutableDescriptor &&
            (exposesDesktopDiagnostics || model.isLoadableOnDevice)) {
          result.add(model);
        }
      } on StateError {
        // A malformed or incomplete descriptor is never passed to Unity. Keep
        // the rest of the reviewed catalog usable while the server is repaired.
      }
    }
    models.assignAll(result);
    return result;
  }

  @override
  Future<AvatarSelectionSnapshot> current({
    required String agentId,
    required AvatarSelectionAssetOptions assetOptions,
  }) async {
    final normalizedAgentId = validateAvatarSelectionAgentId(agentId);
    _requireSelectionAgent(normalizedAgentId);
    _requireTargetAssetOptions(assetOptions);
    final uri = _baseUri
        .resolve('v1/avatar-models/selections/current')
        .replace(
          queryParameters: AvatarSelectionContractCodec.currentQueryParameters(
            agentId: normalizedAgentId,
            assetOptions: assetOptions,
          ),
        );
    var response = await _selectionRequest(
      uri,
      method: 'GET',
      accessToken: await _selectionAccessToken(),
    );
    // The existing staging server predates built-in catalog negotiation.
    // Retry only this definite, read-only validation rejection in the
    // test-origin internal build. Commit/replay keep their exact saved packet.
    if (kMaasoStoreInternalBuild &&
        const bool.fromEnvironment('MAASO_INTERNAL_PRIVACY_TEST') &&
        _environmentKey == MaasoEnvironment.test.key &&
        _baseUri.origin == MaasoEnvironment.test.baseUrl &&
        assetOptions.builtinCatalogVersion >= 2 &&
        response.statusCode == 400 &&
        response.code == 'VALIDATION_ERROR') {
      final legacyQuery = Map<String, String>.of(uri.queryParameters)
        ..remove('builtinCatalogVersion');
      response = await _selectionRequest(
        uri.replace(queryParameters: legacyQuery),
        method: 'GET',
        accessToken: await _selectionAccessToken(),
      );
    }
    if (response.statusCode != 200) {
      _throwAvatarSelectionFailure(
        response,
        isCommit: false,
        expectedAgentId: normalizedAgentId,
      );
    }
    try {
      final snapshot = AvatarSelectionContractCodec.decodeCurrentResponse(
        response.envelope,
        agentId: normalizedAgentId,
      );
      if (snapshot.selection.agentId != normalizedAgentId) {
        throw const FormatException('avatar_selection_agent_mismatch');
      }
      return snapshot;
    } on AvatarSelectionException {
      rethrow;
    } catch (error, stackTrace) {
      _logAvatarSelectionResponse(response, error, stackTrace);
      throw AvatarSelectionContractUnavailableException(
        code: 'AVATAR_SELECTION_PROTOCOL_INVALID',
        traceId: response.traceId,
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<AvatarSelectionCommitResult> commit(
    AvatarSelectionCommitRequest request,
  ) async {
    _requireSelectionAgent(request.agentId);
    _requireTargetAssetOptions(request.assetOptions);
    return _commitSelection(request, accessToken: _selectionAccessToken());
  }

  @override
  Future<AvatarSelectionCommitResult> replay(
    AvatarSelectionRecoveryClaim claim,
  ) async {
    final request = claim.request;
    _requireRecoveryClaim(claim);
    _requireTargetAssetOptions(request.assetOptions);
    return _commitSelection(
      request,
      accessToken: Future<String>.value(_recoveryAccessTokenFor(claim)),
    );
  }

  Future<AvatarSelectionCommitResult> _commitSelection(
    AvatarSelectionCommitRequest request, {
    required Future<String> accessToken,
  }) async {
    final uri = _baseUri.resolve('v1/avatar-models/selections/commit');
    final response = await _selectionRequest(
      uri,
      method: 'POST',
      body: AvatarSelectionContractCodec.encodeCommitRequest(request),
      isCommit: true,
      accessToken: await accessToken,
    );
    if (response.statusCode != 200) {
      _throwAvatarSelectionFailure(
        response,
        isCommit: true,
        expectedAgentId: request.agentId,
      );
    }
    try {
      return AvatarSelectionContractCodec.decodeCommitResponse(
        response.envelope,
        request: request,
      );
    } on AvatarSelectionException {
      rethrow;
    } catch (error, stackTrace) {
      _logAvatarSelectionResponse(response, error, stackTrace);
      throw AvatarSelectionAmbiguousTransportException(
        code: 'AVATAR_SELECTION_COMMIT_RESPONSE_INVALID',
        traceId: response.traceId,
        statusCode: response.statusCode,
        cause: error,
      );
    }
  }

  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async {
    final data = await _request(
      _baseUri.resolve('v1/avatar-models/mine'),
      method: 'GET',
      trackCatalogRequest: false,
    );
    if (data is! List) {
      throw StateError('Avatar upload list response is invalid');
    }
    final uploads = <OwnAvatarUpload>[
      for (final item in data)
        if (item is Map)
          OwnAvatarUpload.fromJson(Map<String, dynamic>.from(item)),
    ];
    _requirePublishedAvatarAccount();
    myUploads.assignAll(uploads);
    return uploads;
  }

  @override
  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  }) async {
    final normalizedDisplayName = displayName.trim();
    final fileName = path.basename(file.path).trim();
    if (normalizedDisplayName.isEmpty) {
      throw StateError('A model name is required');
    }
    if (!fileName.toLowerCase().endsWith('.vrm')) {
      throw StateError('Only VRM 1.0 .vrm model files can be uploaded');
    }
    if (!await file.exists()) {
      throw StateError('The selected model file is no longer available');
    }
    final contentLength = await file.length();
    if (contentLength <= 0 || contentLength > _maxAvatarBundleBytes) {
      throw StateError('The VRM model must be between 1 byte and 50 MB');
    }

    isUploading.value = true;
    uploadError.value = null;
    AvatarUploadSession? session;
    try {
      final sha256 = await _sha256ForFile(file);
      session = await _createUploadSession(
        displayName: normalizedDisplayName,
        fileName: fileName,
        contentLength: contentLength,
        sha256: sha256,
        cover: cover,
      );
      if (contentLength > session.maxBytes) {
        throw StateError('This VRM model exceeds the server upload limit');
      }
      if (cover.contentLength > session.coverMaxBytes) {
        throw StateError('This model cover exceeds the server upload limit');
      }
      _requirePublishedAvatarAccount();
      await _putBundle(session, file, contentLength);
      _requirePublishedAvatarAccount();
      await _putCover(session, cover);
      _requirePublishedAvatarAccount();
      final data = await _request(
        _baseUri.resolve(
          'v1/avatar-models/uploads/${session.uploadId}/complete',
        ),
        method: 'POST',
        trackCatalogRequest: false,
      );
      if (data is! Map) {
        throw StateError('Avatar upload completion response is invalid');
      }
      final completed = OwnAvatarUpload.fromJson(
        Map<String, dynamic>.from(data),
      );
      if (completed.id != session.uploadId) {
        throw StateError(
          'Avatar upload completion returned a different upload',
        );
      }
      _replaceOwnUpload(completed);
      try {
        await listMyUploads();
      } catch (_) {
        // Completion already succeeded. Keep its returned state visible even
        // if the background owner-list refresh has a transient error.
      }
      return completed;
    } catch (exception) {
      uploadError.value = exception.toString().replaceFirst('Bad state: ', '');
      if (session != null) {
        try {
          await listMyUploads();
        } catch (_) {
          // The server-created pending_upload record remains retryable when
          // the owner list cannot be refreshed immediately.
        }
      }
      rethrow;
    } finally {
      isUploading.value = false;
    }
  }

  Future<AvatarUploadSession> _createUploadSession({
    required String displayName,
    required String fileName,
    required int contentLength,
    required String sha256,
    required AvatarModelUploadCover cover,
  }) async {
    final data = await _request(
      _baseUri.resolve('v1/avatar-models/uploads'),
      method: 'POST',
      body: {
        'displayName': displayName,
        'fileName': fileName,
        'contentLength': contentLength,
        'sha256': sha256,
        'coverFileName': cover.fileName,
        'coverContentType': cover.contentType,
        'coverContentLength': cover.contentLength,
        'coverSha256': cover.sha256Hex,
        'coverWidth': cover.width,
        'coverHeight': cover.height,
      },
      trackCatalogRequest: false,
    );
    if (data is! Map) {
      throw StateError('Avatar upload session response is invalid');
    }
    return AvatarUploadSession.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> _putCover(
    AvatarUploadSession session,
    AvatarModelUploadCover cover,
  ) async {
    final request = http.Request('PUT', session.coverUploadUrl);
    for (final header in session.coverUploadHeaders.entries) {
      final key = header.key.trim();
      final value = header.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      if (const {
        'authorization',
        'cookie',
        'proxy-authorization',
      }.contains(key.toLowerCase())) {
        throw StateError('The signed cover upload included an unsafe header');
      }
      request.headers[key] = value;
    }
    if (request.headers['content-type'] != cover.contentType) {
      throw StateError('The signed cover upload has a different content type');
    }
    request.bodyBytes = cover.bytes;
    final response = await _httpClient.send(request);
    await response.stream.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Cover upload failed: HTTP ${response.statusCode}');
    }
  }

  Future<void> _putBundle(
    AvatarUploadSession session,
    File file,
    int contentLength,
  ) async {
    final request = http.StreamedRequest('PUT', session.uploadUrl);
    for (final header in session.uploadHeaders.entries) {
      final key = header.key.trim();
      final value = header.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      if (key.toLowerCase() == 'authorization') {
        throw StateError(
          'The signed upload response included an unsafe header',
        );
      }
      request.headers[key] = value;
    }
    request.contentLength = contentLength;
    late final http.StreamedResponse response;
    try {
      final responseFuture = _httpClient.send(request);
      await request.sink.addStream(file.openRead());
      unawaited(request.sink.close());
      response = await responseFuture;
    } catch (exception, stackTrace) {
      ServerRequestFailureLog.transport(
        source: 'AvatarCatalog',
        method: request.method,
        uri: request.url,
        error: exception,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    final responseBody = response.statusCode < 200 || response.statusCode >= 300
        ? await response.stream.bytesToString()
        : await response.stream.drain<void>().then((_) => '');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      ServerRequestFailureLog.response(
        source: 'AvatarCatalog',
        method: request.method,
        uri: request.url,
        statusCode: response.statusCode,
        responseBody: responseBody,
      );
      throw StateError('Bundle upload failed: HTTP ${response.statusCode}');
    }
  }

  Future<String> _sha256ForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).single;
    return digest.toString();
  }

  void _replaceOwnUpload(OwnAvatarUpload upload) {
    _requirePublishedAvatarAccount();
    final index = myUploads.indexWhere((item) => item.id == upload.id);
    if (index < 0) {
      myUploads.insert(0, upload);
    } else {
      myUploads[index] = upload;
    }
  }

  Future<_AvatarSelectionHttpResponse> _selectionRequest(
    Uri uri, {
    required String method,
    required String accessToken,
    Map<String, Object?>? body,
    bool isCommit = false,
  }) async {
    final headers = <String, String>{
      'Authorization': 'Bearer $accessToken',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
    };
    late final http.Response response;
    try {
      final pending = switch (method) {
        'GET' => _httpClient.get(uri, headers: headers),
        'POST' => _httpClient.post(
          uri,
          headers: headers,
          body: jsonEncode(body),
        ),
        _ => throw UnsupportedError(
          'Unsupported avatar selection method: $method',
        ),
      };
      response = await pending.timeout(_selectionRequestTimeout);
    } catch (error, stackTrace) {
      ServerRequestFailureLog.transport(
        source: 'AvatarSelection',
        method: method,
        uri: uri,
        error: error,
        stackTrace: stackTrace,
      );
      if (isCommit) {
        throw AvatarSelectionAmbiguousTransportException(cause: error);
      }
      throw const AvatarSelectionContractUnavailableException(
        code: 'AVATAR_SELECTION_TRANSPORT_UNAVAILABLE',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      final envelope = _strictAvatarSelectionEnvelope(decoded);
      return _AvatarSelectionHttpResponse(
        uri: uri,
        method: method,
        statusCode: response.statusCode,
        envelope: envelope,
      );
    } catch (error, stackTrace) {
      final metadata = _AvatarSelectionHttpResponse(
        uri: uri,
        method: method,
        statusCode: response.statusCode,
        envelope: const <String, Object?>{},
      );
      _logAvatarSelectionResponse(metadata, error, stackTrace);
      if (isCommit && _isAmbiguousAvatarSelectionStatus(response.statusCode)) {
        throw AvatarSelectionAmbiguousTransportException(
          code: 'AVATAR_SELECTION_COMMIT_RESPONSE_INVALID',
          statusCode: response.statusCode,
          cause: error,
        );
      }
      throw AvatarSelectionContractUnavailableException(
        code: 'AVATAR_SELECTION_PROTOCOL_INVALID',
        statusCode: response.statusCode,
      );
    }
  }

  Never _throwAvatarSelectionFailure(
    _AvatarSelectionHttpResponse response, {
    required bool isCommit,
    required String expectedAgentId,
  }) {
    final code = response.code;
    final message = response.message;
    final traceId = response.traceId;
    final statusCode = response.statusCode;

    Never fail(AvatarSelectionException exception) {
      _logAvatarSelectionResponse(response, exception, StackTrace.current);
      throw exception;
    }

    Never unavailable() => fail(
      AvatarSelectionContractUnavailableException(
        code: 'AVATAR_SELECTION_CONTRACT_UNAVAILABLE',
        message: message,
        traceId: traceId,
        statusCode: statusCode,
      ),
    );

    if (isCommit && _isAmbiguousAvatarSelectionStatus(statusCode)) {
      fail(
        AvatarSelectionAmbiguousTransportException(
          code: code.isEmpty ? 'AVATAR_SELECTION_TRANSPORT_AMBIGUOUS' : code,
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (!isCommit && (statusCode == 404 || statusCode == 410)) {
      unavailable();
    }
    if (statusCode == 400 && code == 'VALIDATION_ERROR') {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionValidationException(
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (statusCode == 401 && code == 'UNAUTHORIZED' ||
        statusCode == 403 && code == 'FORBIDDEN') {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionAuthorizationException(
          code: code,
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (isCommit && statusCode == 404 && code == 'NOT_FOUND') {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionNotFoundException(
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (isCommit &&
        statusCode == 409 &&
        (code == 'AVATAR_ASSET_VERSION_CHANGED' ||
            code == 'AVATAR_BUILTIN_CATALOG_REQUIRED')) {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionValidationException(
          code: code,
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (statusCode == 409 && code == 'AVATAR_SELECTION_VERSION_CHANGED') {
      try {
        final current =
            AvatarSelectionContractCodec.decodeConflictCurrentSelection(
              response.envelope,
              agentId: expectedAgentId,
            );
        if (current.selection.agentId != expectedAgentId) unavailable();
        fail(
          AvatarSelectionVersionChangedException(
            currentSelection: current,
            message: message,
            traceId: traceId,
            statusCode: statusCode,
          ),
        );
      } on AvatarSelectionException {
        rethrow;
      } catch (_) {
        unavailable();
      }
    }
    if (statusCode == 409 && code == 'AVATAR_SELECTION_IDEMPOTENCY_CONFLICT') {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionIdempotencyConflictException(
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    if (statusCode == 409 && code == 'AVATAR_SELECTION_VERSION_EXHAUSTED') {
      if (response.data != null) unavailable();
      fail(
        AvatarSelectionVersionExhaustedException(
          message: message,
          traceId: traceId,
          statusCode: statusCode,
        ),
      );
    }
    unavailable();
  }

  void _logAvatarSelectionResponse(
    _AvatarSelectionHttpResponse response,
    Object error,
    StackTrace stackTrace,
  ) {
    ServerRequestFailureLog.response(
      source: 'AvatarSelection',
      method: response.method,
      uri: response.uri,
      statusCode: response.statusCode,
      responseBody: jsonEncode(<String, Object?>{
        if (response.code.isNotEmpty) 'code': response.code,
        'traceId': ?response.traceId,
      }),
      error: error,
      stackTrace: stackTrace,
    );
  }

  Future<Object?> _request(
    Uri uri, {
    required String method,
    Map<String, dynamic>? body,
    bool trackCatalogRequest = true,
  }) async {
    if (trackCatalogRequest) {
      isLoading.value = true;
      error.value = null;
    }
    try {
      final token = await _accessToken();
      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      };
      late final http.Response response;
      try {
        response = switch (method) {
          'GET' => await _httpClient.get(uri, headers: headers),
          'POST' => await _httpClient.post(
            uri,
            headers: headers,
            body: body == null ? null : jsonEncode(body),
          ),
          _ => throw UnsupportedError(
            'Unsupported avatar catalog method: $method',
          ),
        };
      } catch (exception, stackTrace) {
        ServerRequestFailureLog.transport(
          source: 'AvatarCatalog',
          method: method,
          uri: uri,
          error: exception,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      try {
        Object? decoded;
        try {
          decoded = response.body.trim().isEmpty
              ? const <String, dynamic>{}
              : jsonDecode(response.body);
        } on FormatException {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw StateError(
              'Avatar model request failed: HTTP ${response.statusCode}',
            );
          }
          rethrow;
        }
        if (decoded is! Map) {
          throw StateError('Avatar model response is invalid');
        }
        final envelope = Map<String, dynamic>.from(decoded);
        final code = envelope['code']?.toString().trim();
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            (code != null && code.isNotEmpty && code != 'OK')) {
          final message = envelope['message']?.toString().trim();
          throw StateError(
            message == null || message.isEmpty
                ? 'Avatar model request failed: HTTP ${response.statusCode}'
                : message,
          );
        }
        _requirePublishedAvatarAccount();
        return envelope['data'];
      } catch (exception, stackTrace) {
        ServerRequestFailureLog.response(
          source: 'AvatarCatalog',
          method: method,
          uri: uri,
          statusCode: response.statusCode,
          responseBody: response.body,
          error: exception,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    } catch (exception) {
      if (trackCatalogRequest) {
        error.value = exception.toString().replaceFirst('Bad state: ', '');
      }
      rethrow;
    } finally {
      if (trackCatalogRequest) {
        isLoading.value = false;
      }
    }
  }

  Future<String> _accessToken() async {
    _requirePublishedAvatarAccount();
    final current = _auth.session.value;
    if (current != null && current.isValid) return current.accessToken;
    final restored = await _auth.restoreOrRefresh();
    _requirePublishedAvatarAccount();
    final refreshed = _auth.session.value;
    if (!restored || refreshed == null || !refreshed.isValid) {
      throw StateError('Sign in is required to use reviewed avatar models');
    }
    return refreshed.accessToken;
  }

  Future<String> _selectionAccessToken() async {
    try {
      return await _accessToken();
    } on StateError catch (error) {
      throw AvatarSelectionAuthorizationException(
        code: 'AUTHENTICATION_REQUIRED',
        message: error.message,
      );
    }
  }

  void _requireSelectionAgent(String agentId) {
    if (agentId != _agentId) {
      throw const AvatarSelectionValidationException(
        code: 'AVATAR_SELECTION_AGENT_SCOPE_MISMATCH',
      );
    }
  }

  void _requireTargetAssetOptions(AvatarSelectionAssetOptions assetOptions) {
    final supported = _avatarAssetOptions(_targetPlatform);
    // An outbox request retains the exact capabilities and request hash from
    // when it was created. A new client can recover an older catalog version
    // on the same platform, but cannot silently upgrade that frozen request.
    if (supported.platformAssets != assetOptions.platformAssets ||
        supported.platform != assetOptions.platform ||
        assetOptions.builtinCatalogVersion > supported.builtinCatalogVersion) {
      throw const AvatarSelectionValidationException(
        code: 'AVATAR_SELECTION_PLATFORM_MISMATCH',
      );
    }
  }

  void _requireRecoveryClaim(AvatarSelectionRecoveryClaim claim) {
    final request = claim.request;
    if (_closed ||
        !_storageScopes.isCurrent(_accountMount) ||
        claim.accountScopeDigest != _accountScopeDigest ||
        claim.agentScopeDigest != _agentScopeDigest ||
        claim.ownerGeneration != _ownerGeneration ||
        claim.recordRevision <= 0 ||
        request.agentId != _agentId) {
      throw const AvatarSelectionAuthorizationException(
        code: 'AVATAR_SELECTION_RECOVERY_FENCE_REJECTED',
      );
    }
  }

  String _recoveryAccessTokenFor(AvatarSelectionRecoveryClaim claim) {
    _requireRecoveryClaim(claim);
    final published = _auth.session.value;
    if (_environment.environment.value.key != _environmentKey ||
        published != null && published.accountUuid != _accountUuid ||
        _recoveryAccessToken.trim().isEmpty) {
      throw const AvatarSelectionAuthorizationException(
        code: 'AVATAR_SELECTION_RECOVERY_FENCE_REJECTED',
      );
    }
    return _recoveryAccessToken;
  }

  void _handlePublishedAvatarSession(MaasoAuthSession? session) {
    if (_closed ||
        !_storageScopes.isCurrent(_accountMount) ||
        session == null ||
        !session.isValid ||
        session.accountUuid != _accountUuid ||
        _environment.environment.value.key != _environmentKey) {
      return;
    }
    _recoveryAccessToken = session.accessToken;
  }

  void _requirePublishedAvatarAccount() {
    final current = _auth.session.value;
    if (_closed ||
        !_storageScopes.isCurrent(_accountMount) ||
        _environment.environment.value.key != _environmentKey ||
        current == null ||
        current.accountUuid != _accountUuid) {
      throw StateError(
        'The reviewed avatar account or environment context changed',
      );
    }
  }

  @override
  void onClose() {
    _closed = true;
    _sessionWorker?.dispose();
    _sessionWorker = null;
    _recoveryAccessToken = '';
    if (_ownsClient) _httpClient.close();
    super.onClose();
  }
}

const _supportedAvatarPlatforms = {'ios', 'android', 'macos', 'windows'};
const _requiredAvatarPlatforms = {'ios', 'android'};
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

Map<String, AvatarPlatformAsset> _platformAssets(Object? value) {
  if (value == null) return const {};
  if (value is! Map) {
    throw StateError('Avatar model response has invalid platformAssets');
  }
  final result = <String, AvatarPlatformAsset>{};
  for (final entry in value.entries) {
    final key = entry.key.toString().trim().toLowerCase();
    final rawAsset = entry.value;
    if (rawAsset is! Map) {
      throw StateError('Avatar model response has invalid platformAssets');
    }
    result[key] = AvatarPlatformAsset.fromJson(
      key,
      Map<String, dynamic>.from(rawAsset),
    );
  }
  return Map.unmodifiable(result);
}

AvatarSelectionAssetOptions _avatarAssetOptions(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS => AvatarSelectionAssetOptions.forPlatform(
        'ios',
        builtinCatalogVersion: avatarBuiltinCatalogVersion,
      ),
      TargetPlatform.android => AvatarSelectionAssetOptions.forPlatform(
        'android',
        builtinCatalogVersion: avatarBuiltinCatalogVersion,
      ),
      TargetPlatform.macOS ||
      TargetPlatform.windows => const AvatarSelectionAssetOptions.none(
        builtinCatalogVersion: avatarBuiltinCatalogVersion,
      ),
      TargetPlatform.fuchsia || TargetPlatform.linux => throw UnsupportedError(
        'Remote Unity avatars are unavailable on this platform',
      ),
    };

MaasoEnvironment _requiredAvatarEnvironment(String environmentKey) {
  final normalized = environmentKey.trim();
  for (final environment in MaasoEnvironment.values) {
    if (environment.key == normalized && normalized == environmentKey) {
      return environment;
    }
  }
  throw ArgumentError.value(
    environmentKey,
    'environmentKey',
    'must identify a normalized Maaso environment',
  );
}

Map<String, Object?> _strictAvatarSelectionEnvelope(Object? value) {
  if (value is! Map) {
    throw const FormatException('avatar_selection_envelope_not_object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String || result.containsKey(entry.key)) {
      throw const FormatException('avatar_selection_envelope_invalid_key');
    }
    result[entry.key as String] = entry.value;
  }
  const fields = <String>{'code', 'message', 'traceId', 'data'};
  if (result.keys.toSet().length != fields.length ||
      !result.keys.toSet().containsAll(fields)) {
    throw const FormatException('avatar_selection_envelope_invalid_shape');
  }
  for (final field in const <String>['code', 'message', 'traceId']) {
    final fieldValue = result[field];
    if (fieldValue is! String ||
        fieldValue.trim().isEmpty ||
        fieldValue != fieldValue.trim()) {
      throw FormatException('avatar_selection_envelope_invalid_$field');
    }
  }
  return Map<String, Object?>.unmodifiable(result);
}

bool _isAmbiguousAvatarSelectionStatus(int statusCode) =>
    statusCode >= 200 && statusCode < 300 ||
    statusCode == 408 ||
    statusCode == 429 ||
    statusCode >= 500;

final class _AvatarSelectionHttpResponse {
  const _AvatarSelectionHttpResponse({
    required this.uri,
    required this.method,
    required this.statusCode,
    required this.envelope,
  });

  final Uri uri;
  final String method;
  final int statusCode;
  final Map<String, Object?> envelope;

  String get code =>
      envelope['code'] is String ? (envelope['code']! as String) : '';

  String? get message => envelope['message'] as String?;

  String? get traceId => envelope['traceId'] as String?;

  Object? get data => envelope['data'];
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num && value.toInt() > 0) return value.toInt();
  final parsed = int.tryParse(value?.toString() ?? '');
  if (parsed != null && parsed > 0) return parsed;
  throw StateError('Avatar model response missing $key');
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is Map || value is Iterable) {
    throw StateError('Avatar model response missing $key');
  }
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw StateError('Avatar model response missing $key');
  return text;
}

Map<String, dynamic> _objectMap(Object? value) {
  if (value is! Map) return const <String, dynamic>{};
  return {
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty)
        entry.key.toString(): entry.value,
  };
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return {
    for (final entry in value.entries)
      if (entry.key.toString().trim().isNotEmpty &&
          entry.value is! Map &&
          entry.value is! Iterable &&
          entry.value?.toString().trim().isNotEmpty == true)
        entry.key.toString(): entry.value.toString().trim(),
  };
}

String _approvedHttpsUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.trim().isEmpty) {
    throw StateError('Avatar model response has an invalid assetUrl');
  }
  return uri.toString();
}

String? _optionalApprovedHttpsUrl(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.scheme != 'https' || uri.host.trim().isEmpty) {
    throw StateError('Avatar model response has an invalid previewImageUrl');
  }
  return uri.toString();
}

const _maxAvatarBundleBytes = 50 * 1024 * 1024;
