import 'dart:convert';
import 'dart:math';

import 'package:maaso/src/core/services/bundled_avatar_contract.dart';

const int avatarSelectionContractVersion = 2;
const int avatarBuiltinCatalogVersion = 5;
const int maxAvatarSelectionJsonSafeInteger = 9007199254740991;

final class AvatarSelectionAssetOptions {
  const AvatarSelectionAssetOptions._({
    required this.platformAssets,
    required this.platform,
    required this.builtinCatalogVersion,
  }) : assert(
         builtinCatalogVersion >= 0 &&
             builtinCatalogVersion <= avatarBuiltinCatalogVersion,
       );

  const AvatarSelectionAssetOptions.none({int builtinCatalogVersion = 0})
    : this._(
        platformAssets: false,
        platform: null,
        builtinCatalogVersion: builtinCatalogVersion,
      );

  factory AvatarSelectionAssetOptions.forPlatform(
    String platform, {
    int builtinCatalogVersion = 0,
  }) {
    final normalized = platform.trim().toLowerCase();
    if (normalized != 'ios' && normalized != 'android') {
      throw const FormatException('invalid_avatar_selection_platform');
    }
    return AvatarSelectionAssetOptions._(
      platformAssets: true,
      platform: normalized,
      builtinCatalogVersion: _builtinCatalogVersion(builtinCatalogVersion),
    );
  }

  factory AvatarSelectionAssetOptions.fromPersistenceJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{'platformAssets', 'platform'},
      optionalKeys: const {'builtinCatalogVersion'},
      context: 'avatar_selection_asset_options',
    );
    final platformAssets = _requiredBool(json, 'platformAssets');
    final platform = json['platform'];
    final builtinVersion = json.containsKey('builtinCatalogVersion')
        ? _builtinCatalogVersion(json['builtinCatalogVersion'])
        : 0;
    if (!platformAssets) {
      if (platform != null) {
        throw const FormatException('invalid_avatar_selection_platform');
      }
      return AvatarSelectionAssetOptions.none(
        builtinCatalogVersion: builtinVersion,
      );
    }
    if (platform is! String) {
      throw const FormatException('invalid_avatar_selection_platform');
    }
    return AvatarSelectionAssetOptions.forPlatform(
      platform,
      builtinCatalogVersion: builtinVersion,
    );
  }

  final bool platformAssets;
  final String? platform;
  final int builtinCatalogVersion;

  Map<String, String> toQueryParameters({required String agentId}) =>
      <String, String>{
        'agentId': validateAvatarSelectionAgentId(agentId),
        'platformAssets': platformAssets.toString(),
        'platform': ?platform,
        if (builtinCatalogVersion != 0)
          'builtinCatalogVersion': builtinCatalogVersion.toString(),
      };

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'platformAssets': platformAssets,
    'platform': platform,
    if (builtinCatalogVersion != 0)
      'builtinCatalogVersion': builtinCatalogVersion,
  };

  bool hasSameSemanticValue(AvatarSelectionAssetOptions other) =>
      platformAssets == other.platformAssets &&
      platform == other.platform &&
      builtinCatalogVersion == other.builtinCatalogVersion;
}

int _builtinCatalogVersion(Object? value) {
  if (value is! int || value < 0 || value > avatarBuiltinCatalogVersion) {
    throw const FormatException('invalid_avatar_builtin_catalog_version');
  }
  return value;
}

final class AvatarSelectionState {
  AvatarSelectionState({
    required int? selectionId,
    required String agentId,
    required int? modelId,
    required int version,
    required DateTime? selectedAt,
  }) : selectionId = _nullablePositiveJsonInteger(selectionId, 'selectionId'),
       agentId = validateAvatarSelectionAgentId(agentId),
       modelId = _nullablePositiveJsonInteger(modelId, 'modelId'),
       version = _nonNegativeJsonInteger(version, 'version'),
       selectedAt = _nullableUtcDateTime(selectedAt, 'selectedAt') {
    if (version == 0) {
      if (selectionId != null || modelId != null || selectedAt != null) {
        throw const FormatException('invalid_avatar_selection_virtual_state');
      }
    } else if (selectionId == null || selectedAt == null) {
      throw const FormatException('invalid_avatar_selection_persisted_state');
    }
  }

  factory AvatarSelectionState.fromJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{
        'selectionId',
        'agentId',
        'modelId',
        'version',
        'selectedAt',
      },
      context: 'avatar_selection_state',
    );
    return AvatarSelectionState(
      selectionId: _nullablePositiveIntField(json, 'selectionId'),
      agentId: _requiredString(json, 'agentId'),
      modelId: _nullablePositiveIntField(json, 'modelId'),
      version: _nonNegativeIntField(json, 'version'),
      selectedAt: _nullableUtcDateTimeField(json, 'selectedAt'),
    );
  }

  factory AvatarSelectionState.fromPersistenceJson(Object? value) =>
      AvatarSelectionState.fromJson(value);

  final int? selectionId;
  final String agentId;
  final int? modelId;
  final int version;
  final DateTime? selectedAt;

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'selectionId': selectionId,
    'agentId': agentId,
    'modelId': modelId,
    'version': version,
    'selectedAt': selectedAt?.toIso8601String(),
  };

  bool hasSameSemanticValue(AvatarSelectionState other) =>
      selectionId == other.selectionId &&
      agentId == other.agentId &&
      modelId == other.modelId &&
      version == other.version &&
      selectedAt == other.selectedAt;
}

final class AvatarSelectionPlatformAssetDescriptor {
  AvatarSelectionPlatformAssetDescriptor({
    required String platform,
    required String bundleVersion,
    required String assetUrl,
    required String assetSha256,
    required int assetBytes,
    required Map<String, Object?> runtimeConfig,
  }) : platform = _platform(platform),
       bundleVersion = _nonEmptyString(bundleVersion, 'bundleVersion'),
       assetUrl = _httpsUrl(assetUrl, 'assetUrl'),
       assetSha256 = _sha256(assetSha256),
       assetBytes = _positiveJsonInteger(assetBytes, 'assetBytes'),
       runtimeConfig = _immutableJsonMap(runtimeConfig, 'runtimeConfig');

  factory AvatarSelectionPlatformAssetDescriptor.fromJson(
    String mapKey,
    Object? value,
  ) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{
        'platform',
        'bundleVersion',
        'assetUrl',
        'assetSha256',
        'assetBytes',
        'runtimeConfig',
      },
      context: 'avatar_selection_platform_asset',
    );
    final descriptor = AvatarSelectionPlatformAssetDescriptor(
      platform: _requiredString(json, 'platform'),
      bundleVersion: _requiredString(json, 'bundleVersion'),
      assetUrl: _requiredString(json, 'assetUrl'),
      assetSha256: _requiredString(json, 'assetSha256'),
      assetBytes: _positiveIntField(json, 'assetBytes'),
      runtimeConfig: _requiredJsonMap(json, 'runtimeConfig'),
    );
    if (descriptor.platform != mapKey.trim().toLowerCase()) {
      throw const FormatException('avatar_selection_platform_key_mismatch');
    }
    return descriptor;
  }

  final String platform;
  final String bundleVersion;
  final String assetUrl;
  final String assetSha256;
  final int assetBytes;
  final Map<String, Object?> runtimeConfig;

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'platform': platform,
    'bundleVersion': bundleVersion,
    'assetUrl': assetUrl,
    'assetSha256': assetSha256,
    'assetBytes': assetBytes,
    'runtimeConfig': runtimeConfig,
  };
}

final class AvatarSelectionAssetDescriptor {
  AvatarSelectionAssetDescriptor({
    required int id,
    required String modelKey,
    required String displayName,
    required String modelSource,
    required Map<String, Object?> compatibility,
    String? previewImageUrl,
    String? assetUrl,
    String? assetSha256,
    Map<String, Object?> runtimeConfig = const <String, Object?>{},
    Map<String, AvatarSelectionPlatformAssetDescriptor> platformAssets =
        const <String, AvatarSelectionPlatformAssetDescriptor>{},
  }) : id = _positiveJsonInteger(id, 'id'),
       modelKey = _nonEmptyString(modelKey, 'modelKey'),
       displayName = _nonEmptyString(displayName, 'displayName'),
       modelSource = _nonEmptyString(modelSource, 'modelSource'),
       previewImageUrl = _nullableHttpsUrl(previewImageUrl, 'previewImageUrl'),
       assetUrl = _nullableTopLevelAssetUrl(assetUrl),
       assetSha256 = assetSha256 == null ? null : _sha256(assetSha256),
       runtimeConfig = _immutableJsonMap(runtimeConfig, 'runtimeConfig'),
       compatibility = _immutableJsonMap(compatibility, 'compatibility'),
       platformAssets =
           Map<String, AvatarSelectionPlatformAssetDescriptor>.unmodifiable(
             platformAssets,
           ) {
    if ((this.assetUrl == null) != (this.assetSha256 == null)) {
      throw const FormatException('partial_avatar_selection_asset');
    }
    if (this.assetUrl == _bundledAvatarAssetUrl &&
        (this.id != _bundledAvatarModelId ||
            this.modelKey != _bundledAvatarModelKey)) {
      throw const FormatException('invalid_bundled_avatar_selection_asset');
    }
    if ((this.assetUrl == BundledAvatarContract.mattAssetUrl ||
            this.modelKey == BundledAvatarContract.mattModelKey) &&
        !BundledAvatarContract.isKnownMatt(
          modelId: this.id,
          modelKey: this.modelKey,
          modelSource: this.modelSource,
          assetUrl: this.assetUrl ?? '',
          assetSha256: this.assetSha256,
          runtimeConfig: this.runtimeConfig,
          compatibility: this.compatibility,
        )) {
      throw const FormatException('invalid_bundled_matt_selection_asset');
    }
    for (final entry in this.platformAssets.entries) {
      if (entry.key != entry.value.platform) {
        throw const FormatException('avatar_selection_platform_key_mismatch');
      }
    }
  }

  factory AvatarSelectionAssetDescriptor.fromJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{
        'id',
        'modelKey',
        'displayName',
        'modelSource',
        'compatibility',
      },
      optionalKeys: const <String>{
        'previewImageUrl',
        'assetUrl',
        'assetSha256',
        'runtimeConfig',
        'platformAssets',
      },
      context: 'avatar_selection_asset',
    );
    final platformAssets = <String, AvatarSelectionPlatformAssetDescriptor>{};
    if (json.containsKey('platformAssets')) {
      final rawPlatformAssets = json['platformAssets'];
      final map = _jsonMap(rawPlatformAssets, 'platformAssets');
      for (final entry in map.entries) {
        final key = entry.key.trim().toLowerCase();
        if (key != 'ios' && key != 'android') {
          throw const FormatException('invalid_avatar_selection_platform');
        }
        if (platformAssets.containsKey(key)) {
          throw const FormatException('duplicate_avatar_selection_platform');
        }
        platformAssets[key] = AvatarSelectionPlatformAssetDescriptor.fromJson(
          key,
          entry.value,
        );
      }
    }
    return AvatarSelectionAssetDescriptor(
      id: _positiveIntField(json, 'id'),
      modelKey: _requiredString(json, 'modelKey'),
      displayName: _requiredString(json, 'displayName'),
      modelSource: _requiredString(json, 'modelSource'),
      previewImageUrl: _optionalString(json, 'previewImageUrl'),
      assetUrl: _optionalString(json, 'assetUrl'),
      assetSha256: _optionalString(json, 'assetSha256'),
      runtimeConfig: json.containsKey('runtimeConfig')
          ? _requiredJsonMap(json, 'runtimeConfig')
          : const <String, Object?>{},
      compatibility: _requiredJsonMap(json, 'compatibility'),
      platformAssets: platformAssets,
    );
  }

  factory AvatarSelectionAssetDescriptor.fromPersistenceJson(Object? value) =>
      AvatarSelectionAssetDescriptor.fromJson(value);

  final int id;
  final String modelKey;
  final String displayName;
  final String modelSource;
  final String? previewImageUrl;
  final String? assetUrl;
  final String? assetSha256;
  final Map<String, Object?> runtimeConfig;
  final Map<String, Object?> compatibility;
  final Map<String, AvatarSelectionPlatformAssetDescriptor> platformAssets;

  bool get isRetiredOfficial => BundledAvatarContract.isRetiredOfficial(
    modelKey: modelKey,
    modelSource: modelSource,
    assetUrl: assetUrl,
  );

  /// A published identity retained for recovery, not an alias for the bytes
  /// installed in this build. It must never be sent to Unity as a local load.
  bool get isKnownUninstalledBundledMatt =>
      platformAssets.isEmpty &&
      BundledAvatarContract.isKnownMatt(
        modelId: id,
        modelKey: modelKey,
        modelSource: modelSource,
        assetUrl: assetUrl ?? '',
        assetSha256: assetSha256,
        runtimeConfig: runtimeConfig,
        compatibility: compatibility,
      ) &&
      !BundledAvatarContract.isMatt(
        modelId: id,
        modelKey: modelKey,
        modelSource: modelSource,
        assetUrl: assetUrl ?? '',
        assetSha256: assetSha256,
        runtimeConfig: runtimeConfig,
        compatibility: compatibility,
      );

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'id': id,
    'modelKey': modelKey,
    'displayName': displayName,
    'modelSource': modelSource,
    'compatibility': compatibility,
    if (previewImageUrl != null) 'previewImageUrl': previewImageUrl,
    if (assetUrl != null) 'assetUrl': assetUrl,
    if (assetSha256 != null) 'assetSha256': assetSha256,
    if (runtimeConfig.isNotEmpty) 'runtimeConfig': runtimeConfig,
    if (platformAssets.isNotEmpty)
      'platformAssets': <String, Object?>{
        for (final entry in platformAssets.entries)
          entry.key: entry.value.toPersistenceJson(),
      },
  };

  bool hasSameSemanticValue(AvatarSelectionAssetDescriptor other) =>
      _sameJson(toPersistenceJson(), other.toPersistenceJson());
}

final class AvatarSelectionSnapshot {
  AvatarSelectionSnapshot({
    required this.selection,
    required this.asset,
    required this.selectionAvailable,
  }) {
    final modelId = selection.modelId;
    if (selectionAvailable) {
      if (modelId == null) {
        if (!_isBundledAsset(asset)) {
          throw const FormatException(
            'avatar_selection_snapshot_bundled_asset_mismatch',
          );
        }
      } else if (asset.id != modelId) {
        throw const FormatException(
          'avatar_selection_snapshot_remote_asset_mismatch',
        );
      }
    } else if (modelId == null || !_isBundledAsset(asset)) {
      throw const FormatException(
        'avatar_selection_snapshot_unavailable_state_mismatch',
      );
    }
  }

  factory AvatarSelectionSnapshot.fromJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{'selection', 'asset', 'selectionAvailable'},
      context: 'avatar_selection_snapshot',
    );
    return AvatarSelectionSnapshot(
      selection: AvatarSelectionState.fromJson(json['selection']),
      asset: AvatarSelectionAssetDescriptor.fromJson(json['asset']),
      selectionAvailable: _requiredBool(json, 'selectionAvailable'),
    );
  }

  factory AvatarSelectionSnapshot.fromPersistenceJson(Object? value) =>
      AvatarSelectionSnapshot.fromJson(value);

  final AvatarSelectionState selection;
  final AvatarSelectionAssetDescriptor asset;
  final bool selectionAvailable;

  /// Preserve the authoritative desired model/version during a resource
  /// upgrade. This build can display Joy until its exact Matt revision exists.
  bool get requiresUninstalledBundledMatt =>
      selectionAvailable &&
      selection.modelId == asset.id &&
      asset.isKnownUninstalledBundledMatt;

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'selection': selection.toPersistenceJson(),
    'asset': asset.toPersistenceJson(),
    'selectionAvailable': selectionAvailable,
  };

  bool hasSameSemanticValue(AvatarSelectionSnapshot other) =>
      selection.hasSameSemanticValue(other.selection) &&
      asset.hasSameSemanticValue(other.asset) &&
      selectionAvailable == other.selectionAvailable;
}

final class AvatarSelectionCommitRequest {
  AvatarSelectionCommitRequest({
    required String agentId,
    required int? modelId,
    required int expectedVersion,
    required String idempotencyKey,
    required this.assetOptions,
    String? expectedAssetVersionDigest,
  }) : expectedAssetVersionDigest = _validateExpectedAssetDigest(
         expectedAssetVersionDigest,
       ),
       agentId = validateAvatarSelectionAgentId(agentId),
       modelId = _nullablePositiveJsonInteger(modelId, 'modelId'),
       expectedVersion = _nonNegativeJsonInteger(
         expectedVersion,
         'expectedVersion',
       ),
       idempotencyKey = AvatarSelectionIdempotencyKey.validate(idempotencyKey);

  factory AvatarSelectionCommitRequest.fromPersistenceJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{
        'contractVersion',
        'agentId',
        'modelId',
        'expectedVersion',
        'idempotencyKey',
        'assetOptions',
      },
      optionalKeys: const {'expectedAssetVersionDigest'},
      context: 'avatar_selection_commit_request',
    );
    if (json['contractVersion'] != avatarSelectionContractVersion) {
      throw const FormatException('unsupported_avatar_selection_contract');
    }
    return AvatarSelectionCommitRequest(
      agentId: _requiredString(json, 'agentId'),
      modelId: _nullablePositiveIntField(json, 'modelId'),
      expectedVersion: _nonNegativeIntField(json, 'expectedVersion'),
      idempotencyKey: _requiredString(json, 'idempotencyKey'),
      expectedAssetVersionDigest: json.containsKey('expectedAssetVersionDigest')
          ? _requiredString(json, 'expectedAssetVersionDigest')
          : null,
      assetOptions: AvatarSelectionAssetOptions.fromPersistenceJson(
        json['assetOptions'],
      ),
    );
  }

  final String agentId;
  final int? modelId;
  final int expectedVersion;
  final String idempotencyKey;
  final String? expectedAssetVersionDigest;
  final AvatarSelectionAssetOptions assetOptions;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'agentId': agentId,
    'modelId': modelId,
    'expectedVersion': expectedVersion,
    'idempotencyKey': idempotencyKey,
    if (expectedAssetVersionDigest != null)
      'expectedAssetVersionDigest': expectedAssetVersionDigest,
    'platformAssets': assetOptions.platformAssets,
    'platform': ?assetOptions.platform,
    if (assetOptions.builtinCatalogVersion != 0)
      'builtinCatalogVersion': assetOptions.builtinCatalogVersion,
  };

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'contractVersion': avatarSelectionContractVersion,
    'agentId': agentId,
    'modelId': modelId,
    'expectedVersion': expectedVersion,
    'idempotencyKey': idempotencyKey,
    if (expectedAssetVersionDigest != null)
      'expectedAssetVersionDigest': expectedAssetVersionDigest,
    'assetOptions': assetOptions.toPersistenceJson(),
  };

  bool hasSameSemanticValue(AvatarSelectionCommitRequest other) =>
      agentId == other.agentId &&
      modelId == other.modelId &&
      expectedVersion == other.expectedVersion &&
      idempotencyKey == other.idempotencyKey &&
      expectedAssetVersionDigest == other.expectedAssetVersionDigest &&
      assetOptions.hasSameSemanticValue(other.assetOptions);
}

String? _validateExpectedAssetDigest(String? value) {
  if (value != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('invalid_avatar_expected_asset_version_digest');
  }
  return value;
}

final class AvatarSelectionReceipt {
  AvatarSelectionReceipt({
    required String idempotencyKey,
    required this.previousSelection,
    required this.selection,
    required this.asset,
    required this.selectionAvailable,
  }) : idempotencyKey = AvatarSelectionIdempotencyKey.validate(idempotencyKey) {
    if (previousSelection.agentId != selection.agentId ||
        selection.version != previousSelection.version + 1) {
      throw const FormatException('invalid_avatar_selection_receipt');
    }
    if (previousSelection.version > 0 &&
        previousSelection.selectionId != selection.selectionId) {
      throw const FormatException(
        'avatar_selection_receipt_selection_id_mismatch',
      );
    }
    if (!selectionAvailable ||
        (selection.modelId == null
            ? !_isBundledAsset(asset)
            : asset.id != selection.modelId)) {
      throw const FormatException('avatar_selection_receipt_asset_mismatch');
    }
  }

  factory AvatarSelectionReceipt.fromJson(Object? value) {
    final json = _strictMap(
      value,
      requiredKeys: const <String>{
        'idempotencyKey',
        'previousSelection',
        'selection',
        'asset',
        'selectionAvailable',
      },
      context: 'avatar_selection_receipt',
    );
    return AvatarSelectionReceipt(
      idempotencyKey: _requiredString(json, 'idempotencyKey'),
      previousSelection: AvatarSelectionState.fromJson(
        json['previousSelection'],
      ),
      selection: AvatarSelectionState.fromJson(json['selection']),
      asset: AvatarSelectionAssetDescriptor.fromJson(json['asset']),
      selectionAvailable: _requiredBool(json, 'selectionAvailable'),
    );
  }

  factory AvatarSelectionReceipt.fromPersistenceJson(Object? value) =>
      AvatarSelectionReceipt.fromJson(value);

  final String idempotencyKey;
  final AvatarSelectionState previousSelection;
  final AvatarSelectionState selection;
  final AvatarSelectionAssetDescriptor asset;
  final bool selectionAvailable;

  void validateAgainst(AvatarSelectionCommitRequest request) {
    if (idempotencyKey != request.idempotencyKey ||
        previousSelection.agentId != request.agentId ||
        selection.agentId != request.agentId ||
        previousSelection.version != request.expectedVersion ||
        selection.version != request.expectedVersion + 1 ||
        selection.modelId != request.modelId) {
      throw const FormatException('avatar_selection_receipt_mismatch');
    }
  }

  Map<String, Object?> toPersistenceJson() => <String, Object?>{
    'idempotencyKey': idempotencyKey,
    'previousSelection': previousSelection.toPersistenceJson(),
    'selection': selection.toPersistenceJson(),
    'asset': asset.toPersistenceJson(),
    'selectionAvailable': selectionAvailable,
  };

  bool hasSameSemanticValue(AvatarSelectionReceipt other) =>
      _sameJson(toPersistenceJson(), other.toPersistenceJson());
}

final class AvatarSelectionCommitResult {
  AvatarSelectionCommitResult({
    required this.receipt,
    required this.replayed,
    AvatarSelectionCommitRequest? request,
  }) {
    if (request != null) receipt.validateAgainst(request);
  }

  final AvatarSelectionReceipt receipt;
  final bool replayed;
}

abstract final class AvatarSelectionContractCodec {
  static Map<String, String> currentQueryParameters({
    required String agentId,
    required AvatarSelectionAssetOptions assetOptions,
  }) => assetOptions.toQueryParameters(agentId: agentId);

  static Map<String, Object?> encodeCommitRequest(
    AvatarSelectionCommitRequest request,
  ) => request.toWireJson();

  static AvatarSelectionSnapshot decodeCurrentResponse(
    Object? value, {
    required String agentId,
  }) {
    final data = _successData(value, 'avatar_selection_current');
    final json = _strictMap(
      data,
      requiredKeys: const <String>{
        'contractVersion',
        'selection',
        'asset',
        'selectionAvailable',
      },
      context: 'avatar_selection_current_data',
    );
    _requireContractVersion(json);
    final snapshot = AvatarSelectionSnapshot.fromJson(<String, Object?>{
      'selection': json['selection'],
      'asset': json['asset'],
      'selectionAvailable': json['selectionAvailable'],
    });
    if (snapshot.selection.agentId != validateAvatarSelectionAgentId(agentId)) {
      throw const FormatException('avatar_selection_agent_mismatch');
    }
    return snapshot;
  }

  static AvatarSelectionCommitResult decodeCommitResponse(
    Object? value, {
    required AvatarSelectionCommitRequest request,
  }) {
    final data = _successData(value, 'avatar_selection_commit');
    final json = _strictMap(
      data,
      requiredKeys: const <String>{'contractVersion', 'receipt', 'replayed'},
      context: 'avatar_selection_commit_data',
    );
    _requireContractVersion(json);
    final receipt = AvatarSelectionReceipt.fromJson(json['receipt']);
    receipt.validateAgainst(request);
    return AvatarSelectionCommitResult(
      receipt: receipt,
      replayed: _requiredBool(json, 'replayed'),
    );
  }

  static AvatarSelectionSnapshot decodeConflictCurrentSelection(
    Object? value, {
    required String agentId,
  }) {
    final envelope = _envelope(value, 'avatar_selection_conflict');
    if (envelope['code'] != 'AVATAR_SELECTION_VERSION_CHANGED') {
      throw const FormatException('avatar_selection_conflict_code_mismatch');
    }
    final data = _strictMap(
      envelope['data'],
      requiredKeys: const <String>{'currentSelection'},
      context: 'avatar_selection_conflict_data',
    );
    final snapshot = AvatarSelectionSnapshot.fromJson(data['currentSelection']);
    if (snapshot.selection.agentId != validateAvatarSelectionAgentId(agentId)) {
      throw const FormatException('avatar_selection_agent_mismatch');
    }
    return snapshot;
  }

  static Map<String, Object?> _successData(Object? value, String context) {
    final envelope = _envelope(value, context);
    if (envelope['code'] != 'OK') {
      throw const FormatException('avatar_selection_envelope_not_ok');
    }
    return _strictMap(
      envelope['data'],
      requiredKeys: const <String>{},
      allowAdditionalKeys: true,
      context: '${context}_data',
    );
  }

  static Map<String, Object?> _envelope(Object? value, String context) {
    final envelope = _strictMap(
      value,
      requiredKeys: const <String>{'code', 'message', 'traceId', 'data'},
      context: '${context}_envelope',
    );
    _requiredString(envelope, 'code');
    _requiredString(envelope, 'message');
    _requiredString(envelope, 'traceId');
    return envelope;
  }

  static void _requireContractVersion(Map<String, Object?> json) {
    if (json['contractVersion'] != avatarSelectionContractVersion) {
      throw const FormatException('unsupported_avatar_selection_contract');
    }
  }
}

abstract final class AvatarSelectionIdempotencyKey {
  static final RegExp _pattern = RegExp(r'^[A-Za-z0-9_-]{8,96}$');

  static bool isValid(String value) =>
      value == value.trim() && _pattern.hasMatch(value);

  static String validate(String value) {
    if (!isValid(value)) {
      throw const FormatException('invalid_avatar_selection_idempotency_key');
    }
    return value;
  }

  static String generate({Random? random}) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(24, (_) => source.nextInt(256));
    return validate('avatar_${base64Url.encode(bytes).replaceAll('=', '')}');
  }
}

abstract interface class AvatarSelectionTransport {
  Future<AvatarSelectionSnapshot> current({
    required String agentId,
    required AvatarSelectionAssetOptions assetOptions,
  });

  Future<AvatarSelectionCommitResult> commit(
    AvatarSelectionCommitRequest request,
  );
}

sealed class AvatarSelectionException implements Exception {
  const AvatarSelectionException({
    required this.code,
    this.message,
    this.traceId,
    this.statusCode,
  });

  final String code;
  final String? message;
  final String? traceId;
  final int? statusCode;

  @override
  String toString() => code;
}

final class AvatarSelectionValidationException
    extends AvatarSelectionException {
  const AvatarSelectionValidationException({
    super.code = 'VALIDATION_ERROR',
    super.message,
    super.traceId,
    super.statusCode,
  });
}

final class AvatarSelectionNotFoundException extends AvatarSelectionException {
  const AvatarSelectionNotFoundException({
    super.code = 'NOT_FOUND',
    super.message,
    super.traceId,
    super.statusCode,
  });
}

final class AvatarSelectionAuthorizationException
    extends AvatarSelectionException {
  const AvatarSelectionAuthorizationException({
    required super.code,
    super.message,
    super.traceId,
    super.statusCode,
  });
}

final class AvatarSelectionVersionChangedException
    extends AvatarSelectionException {
  const AvatarSelectionVersionChangedException({
    required this.currentSelection,
    super.message,
    super.traceId,
    super.statusCode = 409,
  }) : super(code: 'AVATAR_SELECTION_VERSION_CHANGED');

  final AvatarSelectionSnapshot currentSelection;
}

final class AvatarSelectionIdempotencyConflictException
    extends AvatarSelectionException {
  const AvatarSelectionIdempotencyConflictException({
    super.message,
    super.traceId,
    super.statusCode = 409,
  }) : super(code: 'AVATAR_SELECTION_IDEMPOTENCY_CONFLICT');
}

final class AvatarSelectionVersionExhaustedException
    extends AvatarSelectionException {
  const AvatarSelectionVersionExhaustedException({
    super.message,
    super.traceId,
    super.statusCode = 409,
  }) : super(code: 'AVATAR_SELECTION_VERSION_EXHAUSTED');
}

final class AvatarSelectionContractUnavailableException
    extends AvatarSelectionException {
  const AvatarSelectionContractUnavailableException({
    super.code = 'AVATAR_SELECTION_CONTRACT_UNAVAILABLE',
    super.message,
    super.traceId,
    super.statusCode,
  });
}

final class AvatarSelectionAmbiguousTransportException
    extends AvatarSelectionException {
  const AvatarSelectionAmbiguousTransportException({
    super.code = 'AVATAR_SELECTION_TRANSPORT_AMBIGUOUS',
    super.message,
    super.traceId,
    super.statusCode,
    this.cause,
  });

  final Object? cause;
}

String validateAvatarSelectionAgentId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.runes.length > 96) {
    throw const FormatException('invalid_avatar_selection_agent_id');
  }
  return normalized;
}

Map<String, Object?> _strictMap(
  Object? value, {
  required Set<String> requiredKeys,
  Set<String> optionalKeys = const <String>{},
  bool allowAdditionalKeys = false,
  required String context,
}) {
  if (value is! Map) throw FormatException('${context}_not_object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String || result.containsKey(entry.key)) {
      throw FormatException('${context}_invalid_key');
    }
    result[entry.key as String] = entry.value;
  }
  if (!result.keys.toSet().containsAll(requiredKeys)) {
    throw FormatException('${context}_missing_field');
  }
  if (!allowAdditionalKeys) {
    final allowed = <String>{...requiredKeys, ...optionalKeys};
    if (result.keys.any((key) => !allowed.contains(key))) {
      throw FormatException('${context}_unknown_field');
    }
  }
  return result;
}

Map<String, Object?> _jsonMap(Object? value, String field) => _strictMap(
  value,
  requiredKeys: const <String>{},
  allowAdditionalKeys: true,
  context: 'avatar_selection_$field',
);

Map<String, Object?> _requiredJsonMap(Map<String, Object?> json, String key) =>
    _immutableJsonMap(_jsonMap(json[key], key), key);

Map<String, Object?> _immutableJsonMap(
  Map<String, Object?> value,
  String field,
) {
  final validated = _validatedJsonValue(value, field);
  return Map<String, Object?>.unmodifiable(
    Map<String, Object?>.from(validated as Map),
  );
}

Object? _validatedJsonValue(Object? value, String field) {
  if (value == null || value is String || value is bool) return value;
  if (value is int) {
    if (value.abs() > maxAvatarSelectionJsonSafeInteger) {
      throw FormatException('avatar_selection_${field}_unsafe_integer');
    }
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      throw FormatException('avatar_selection_${field}_invalid_number');
    }
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _validatedJsonValue(item, field)),
    );
  }
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String || result.containsKey(entry.key)) {
        throw FormatException('avatar_selection_${field}_invalid_key');
      }
      result[entry.key as String] = _validatedJsonValue(entry.value, field);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw FormatException('avatar_selection_${field}_invalid_json');
}

bool _sameJson(Object? left, Object? right) =>
    jsonEncode(_canonicalJson(left)) == jsonEncode(_canonicalJson(right));

Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  if (value is Iterable) return value.map(_canonicalJson).toList();
  return value;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return _nonEmptyString(value, key);
}

String? _optionalString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! String) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return _nonEmptyString(value, key);
}

String _nonEmptyString(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized != value) {
    throw FormatException('avatar_selection_${field}_invalid');
  }
  return normalized;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return value;
}

int _positiveIntField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return _positiveJsonInteger(value, key);
}

int _nonNegativeIntField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return _nonNegativeJsonInteger(value, key);
}

int? _nullablePositiveIntField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return _positiveJsonInteger(value, key);
}

int _positiveJsonInteger(int value, String field) {
  if (value <= 0 || value > maxAvatarSelectionJsonSafeInteger) {
    throw FormatException('avatar_selection_${field}_invalid');
  }
  return value;
}

int _nonNegativeJsonInteger(int value, String field) {
  if (value < 0 || value > maxAvatarSelectionJsonSafeInteger) {
    throw FormatException('avatar_selection_${field}_invalid');
  }
  return value;
}

int? _nullablePositiveJsonInteger(int? value, String field) =>
    value == null ? null : _positiveJsonInteger(value, field);

DateTime? _nullableUtcDateTimeField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim() != value) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw FormatException('avatar_selection_${key}_invalid');
  }
  return parsed;
}

DateTime? _nullableUtcDateTime(DateTime? value, String field) {
  if (value != null && !value.isUtc) {
    throw FormatException('avatar_selection_${field}_invalid');
  }
  return value;
}

String _platform(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized != 'ios' && normalized != 'android') {
    throw const FormatException('invalid_avatar_selection_platform');
  }
  return normalized;
}

String _httpsUrl(String value, String field) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.trim().isEmpty) {
    throw FormatException('avatar_selection_${field}_invalid');
  }
  return uri.toString();
}

String? _nullableHttpsUrl(String? value, String field) =>
    value == null ? null : _httpsUrl(value, field);

String? _nullableTopLevelAssetUrl(String? value) {
  if (value == null) return null;
  if (value == _bundledAvatarAssetUrl) return value;
  if (value == BundledAvatarContract.mattAssetUrl) return value;
  return _httpsUrl(value, 'assetUrl');
}

String _sha256(String value) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw const FormatException('invalid_avatar_selection_asset_sha256');
  }
  return normalized;
}

const int _bundledAvatarModelId = 1;
const String _bundledAvatarModelKey = 'masso.bundled.agent';
const String _bundledAvatarAssetUrl = 'unity://masso/avatar_agent';

bool _isBundledAsset(AvatarSelectionAssetDescriptor asset) =>
    asset.id == _bundledAvatarModelId &&
    asset.modelKey == _bundledAvatarModelKey &&
    asset.assetUrl == _bundledAvatarAssetUrl;
