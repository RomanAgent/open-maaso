/// Published historical descriptors, independent of this build's active
/// resource constants. These must not follow a new resource SHA automatically.
Map<String, dynamic> historicalMattDescriptor({int version = 1, int id = 44}) {
  final sha256 = switch (version) {
    1 => 'f2fb5402cb89e16f82dd464584f1e0be1d1affce784ee0f11fa911201775b5c7',
    2 => '1546f3842d78d31a0c7e079eae63b68ee32aed3a2461025f7b6ba18ac210bc77',
    3 => '73d78f0d1f1b165a5819f1fc34717272c761ee00f26a64a4efb45ebe741cd2e7',
    _ => throw ArgumentError.value(version, 'version'),
  };
  return <String, dynamic>{
    'id': id,
    'modelKey': 'masso.bundled.matt',
    'displayName': 'Matt',
    'modelSource': 'official',
    'assetUrl': 'unity://masso/avatar_matt',
    'assetSha256': sha256,
    'runtimeConfig': <String, Object?>{
      'avatar': 'matt',
      'modelKey': 'masso.bundled.matt',
      'assetName': 'MaleCompanion',
      'assetVersion': version,
      'bundleVersion': '$version',
      'voiceGender': 'male',
      'preferredVoiceSid': 5,
    },
    'compatibility': <String, Object?>{
      'backends': <String>['unity'],
      'builtinCatalogVersion': version + 1,
    },
  };
}
