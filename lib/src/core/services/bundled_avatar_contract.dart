/// Published identities retained only for strict historical receipt decoding.
/// Retired official models are never admitted to catalog selection or rendering.
abstract final class BundledAvatarContract {
  /// Exact product identities, never a gender or display-name filter. User
  /// uploads retain their normal model and voice capabilities.
  static bool isRetiredOfficial({
    required String modelKey,
    required String modelSource,
    String? assetUrl,
  }) =>
      assetUrl == mattAssetUrl ||
      (modelSource == 'official' &&
          const {
            mattModelKey,
            'modular-anime-male',
            'masso.official.modular-male',
          }.contains(modelKey));

  static const mattModelKey = 'masso.bundled.matt';
  static const mattAssetUrl = 'unity://masso/avatar_matt';
  static const mattAssetSha256 =
      '1e4e6f8b30ed5a9bfa690811f6ed37557408e5fb8d8626c209806fe0176f4036';
  static const mattAssetName = 'MaleCompanion';
  static const mattPreviewAsset = 'assets/model_store/matt.png';
  static const mattRuntimeConfig = <String, Object?>{
    'avatar': 'matt',
    'modelKey': mattModelKey,
    'assetName': mattAssetName,
    'assetVersion': 4,
    'bundleVersion': '4',
    'voiceGender': 'male',
    'preferredVoiceSid': 5,
  };

  // Frozen published revisions can appear in durable receipts or while the
  // server and app are being upgraded separately. Recognizing one does not
  // grant this build permission to execute it through isMatt.
  static const _historicalMattRevisions =
      <({int version, String sha256, int catalogVersion})>[
        (
          version: 1,
          sha256:
              'f2fb5402cb89e16f82dd464584f1e0be1d1affce784ee0f11fa911201775b5c7',
          catalogVersion: 2,
        ),
        (
          version: 2,
          sha256:
              '1546f3842d78d31a0c7e079eae63b68ee32aed3a2461025f7b6ba18ac210bc77',
          catalogVersion: 3,
        ),
        (
          version: 3,
          sha256:
              '73d78f0d1f1b165a5819f1fc34717272c761ee00f26a64a4efb45ebe741cd2e7',
          catalogVersion: 4,
        ),
      ];

  static bool isKnownMatt({
    required int? modelId,
    required String modelKey,
    required String modelSource,
    required String assetUrl,
    required String? assetSha256,
    required Map<String, Object?> runtimeConfig,
    required Map<String, Object?> compatibility,
  }) {
    if (isMatt(
      modelId: modelId,
      modelKey: modelKey,
      modelSource: modelSource,
      assetUrl: assetUrl,
      assetSha256: assetSha256,
      runtimeConfig: runtimeConfig,
      compatibility: compatibility,
    )) {
      return true;
    }
    if (modelId == null ||
        modelId <= 0 ||
        modelKey != mattModelKey ||
        modelSource != 'official' ||
        assetUrl != mattAssetUrl ||
        runtimeConfig['avatar'] != 'matt' ||
        runtimeConfig['modelKey'] != mattModelKey ||
        runtimeConfig['assetName'] != 'MaleCompanion' ||
        runtimeConfig['voiceGender'] != 'male' ||
        runtimeConfig['preferredVoiceSid'] is! int ||
        runtimeConfig['preferredVoiceSid'] != 5 ||
        runtimeConfig['assetVersion'] is! int) {
      return false;
    }
    final backends = compatibility['backends'];
    if (backends is! Iterable || !backends.contains('unity')) return false;
    final approved = runtimeConfig['approvedAssetSha256'];
    if (approved != null && approved != assetSha256) return false;
    return _historicalMattRevisions.any(
      (revision) =>
          assetSha256 == revision.sha256 &&
          runtimeConfig['assetVersion'] == revision.version &&
          runtimeConfig['bundleVersion'] == '${revision.version}' &&
          compatibility['builtinCatalogVersion'] is int &&
          compatibility['builtinCatalogVersion'] == revision.catalogVersion,
    );
  }

  /// Matches the final published revision for decoding old durable receipts.
  /// This identity match does not grant execution; retirement is checked first.
  static bool isMatt({
    required int? modelId,
    required String modelKey,
    required String modelSource,
    required String assetUrl,
    required String? assetSha256,
    required Map<String, Object?> runtimeConfig,
    Map<String, Object?>? compatibility,
  }) {
    if (modelId == null ||
        modelId <= 0 ||
        modelKey != mattModelKey ||
        modelSource != 'official' ||
        assetUrl != mattAssetUrl ||
        assetSha256 != mattAssetSha256) {
      return false;
    }
    for (final entry in mattRuntimeConfig.entries) {
      if (runtimeConfig[entry.key] != entry.value) return false;
    }
    final approved = runtimeConfig['approvedAssetSha256'];
    if (approved != null && approved != mattAssetSha256) return false;
    if (compatibility != null) {
      final backends = compatibility['backends'];
      if (backends is! Iterable || !backends.contains('unity')) return false;
    }
    return true;
  }
}
