import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

enum DesktopLocalAsrEngine { moonshineV1, senseVoice }

/// One immutable file in a user-importable desktop ASR model pack.
final class DesktopLocalAsrModelFileDescriptor {
  DesktopLocalAsrModelFileDescriptor({
    required String name,
    required this.byteLength,
    required String sha256Digest,
  }) : name = _checkedFileName(name),
       sha256Digest = _checkedSha256(sha256Digest) {
    if (byteLength < 1) {
      throw ArgumentError.value(byteLength, 'byteLength', 'must be positive');
    }
  }

  final String name;
  final int byteLength;
  final String sha256Digest;
}

/// Pure, immutable provenance and integrity metadata for a local ASR pack.
///
/// It deliberately contains no mutable download URL. Desktop local ASR only
/// accepts a directory explicitly selected by the user and never downloads or
/// redistributes model weights.
final class DesktopLocalAsrModelDescriptor {
  DesktopLocalAsrModelDescriptor({
    required String id,
    required String displayName,
    required this.engine,
    required String sourceRepository,
    required String sourceRevision,
    required String licenseId,
    required String licenseReference,
    required this.requiresLicenseAcknowledgement,
    required this.requiresLegalApproval,
    required Iterable<String> locales,
    required Iterable<DesktopLocalAsrModelFileDescriptor> files,
  }) : id = _checkedId(id),
       displayName = _checkedLabel(displayName, 'displayName'),
       sourceRepository = _checkedHttpsUri(
         sourceRepository,
         'sourceRepository',
       ),
       sourceRevision = _checkedRevision(sourceRevision),
       licenseId = _checkedLabel(licenseId, 'licenseId'),
       licenseReference = _checkedHttpsUri(
         licenseReference,
         'licenseReference',
       ),
       locales = _checkedLocales(locales),
       files = _checkedFiles(files);

  final String id;
  final String displayName;
  final DesktopLocalAsrEngine engine;
  final String sourceRepository;
  final String sourceRevision;
  final String licenseId;
  final String licenseReference;
  final bool requiresLicenseAcknowledgement;
  final bool requiresLegalApproval;
  final List<String> locales;
  final List<DesktopLocalAsrModelFileDescriptor> files;

  /// All production descriptors are user-import-only. This getter is
  /// intentionally constant so no caller can accidentally add acquisition.
  bool get userImportOnly => true;

  DesktopLocalAsrModelPack get coreModelPack =>
      DesktopLocalAsrModelPack(id: id);

  DesktopLocalAsrModelFileDescriptor fileNamed(String name) => files.firstWhere(
    (file) => file.name == name,
    orElse: () => throw StateError('desktop_local_asr_file_not_declared'),
  );

  /// Address of the exact provenance + byte contract, not of a source path.
  String get contentDigest {
    final canonical = <String>[
      'maaso.desktop_local_asr.pack.v1',
      id,
      engine.name,
      sourceRepository,
      sourceRevision,
      licenseId,
      licenseReference,
      requiresLicenseAcknowledgement ? 'ack' : 'no-ack',
      requiresLegalApproval ? 'legal-gate' : 'no-legal-gate',
      ...locales,
      for (final file in files)
        '${file.name}:${file.byteLength}:${file.sha256Digest}',
    ].join('\n');
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

final class DesktopLocalAsrModelCatalog {
  DesktopLocalAsrModelCatalog._();

  static final moonshineTinyEnInt8 = DesktopLocalAsrModelDescriptor(
    id: 'moonshine-tiny-en-int8-bf2b762c',
    displayName: 'Moonshine v1 Tiny EN (int8)',
    engine: DesktopLocalAsrEngine.moonshineV1,
    sourceRepository:
        'https://huggingface.co/csukuangfj/'
        'sherpa-onnx-moonshine-tiny-en-int8',
    sourceRevision: 'bf2b762c076d8ea61e2af0b3851c9564fb77552e',
    licenseId: 'MIT',
    licenseReference:
        'https://huggingface.co/csukuangfj/'
        'sherpa-onnx-moonshine-tiny-en-int8/tree/'
        'bf2b762c076d8ea61e2af0b3851c9564fb77552e',
    requiresLicenseAcknowledgement: false,
    requiresLegalApproval: false,
    locales: const <String>['en'],
    files: <DesktopLocalAsrModelFileDescriptor>[
      DesktopLocalAsrModelFileDescriptor(
        name: 'cached_decode.int8.onnx',
        byteLength: 45264830,
        sha256Digest:
            '2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6',
      ),
      DesktopLocalAsrModelFileDescriptor(
        name: 'encode.int8.onnx',
        byteLength: 18249187,
        sha256Digest:
            '8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb',
      ),
      DesktopLocalAsrModelFileDescriptor(
        name: 'preprocess.onnx',
        byteLength: 6800738,
        sha256Digest:
            'f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e',
      ),
      DesktopLocalAsrModelFileDescriptor(
        name: 'tokens.txt',
        byteLength: 436688,
        sha256Digest:
            '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea',
      ),
      DesktopLocalAsrModelFileDescriptor(
        name: 'uncached_decode.int8.onnx',
        byteLength: 53216096,
        sha256Digest:
            '216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41',
      ),
    ],
  );

  /// SenseVoice remains legally gated even after byte-level verification.
  /// It is visible as a locked catalog entry, but is not importable or
  /// selectable until a future trusted approval authority is designed.
  static final senseVoiceInt8 = DesktopLocalAsrModelDescriptor(
    id: 'sense-voice-int8-2365baea',
    displayName: 'SenseVoice zh/yue/en/ja/ko (int8)',
    engine: DesktopLocalAsrEngine.senseVoice,
    sourceRepository:
        'https://huggingface.co/csukuangfj/'
        'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    sourceRevision: '2365baeacb507f821a0c8120fcee3d484dba7a07',
    licenseId: 'FunASR model license',
    licenseReference:
        'https://github.com/modelscope/FunASR/blob/'
        '58830eca4012644aac0c3218c3ccc7d98f003fda/MODEL_LICENSE',
    requiresLicenseAcknowledgement: true,
    requiresLegalApproval: true,
    locales: const <String>['zh', 'yue', 'en', 'ja', 'ko'],
    files: <DesktopLocalAsrModelFileDescriptor>[
      DesktopLocalAsrModelFileDescriptor(
        name: 'model.int8.onnx',
        byteLength: 239233841,
        sha256Digest:
            'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
      ),
      DesktopLocalAsrModelFileDescriptor(
        name: 'tokens.txt',
        byteLength: 315894,
        sha256Digest:
            'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
      ),
    ],
  );

  static final List<DesktopLocalAsrModelDescriptor> all =
      List<DesktopLocalAsrModelDescriptor>.unmodifiable(
        <DesktopLocalAsrModelDescriptor>[moonshineTinyEnInt8, senseVoiceInt8],
      );

  static final List<DesktopLocalAsrModelPack> coreModelPacks =
      List<DesktopLocalAsrModelPack>.unmodifiable(
        all.map((descriptor) => descriptor.coreModelPack),
      );

  /// Model packs admitted to the production recognition service. Entries
  /// requiring legal approval stay out of persisted selection and decode even
  /// if a future availability implementation is accidentally permissive.
  static final List<DesktopLocalAsrModelPack> productionSelectableModelPacks =
      List<DesktopLocalAsrModelPack>.unmodifiable(
        all
            .where((descriptor) => !descriptor.requiresLegalApproval)
            .map((descriptor) => descriptor.coreModelPack),
      );
}

final RegExp _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,95}$');
final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _revisionPattern = RegExp(r'^[a-f0-9]{40}$');
final RegExp _localePattern = RegExp(r'^[a-z]{2,3}$');

String _checkedId(String value) {
  final normalized = value.trim();
  if (!_idPattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'id', 'is invalid');
  }
  return normalized;
}

String _checkedFileName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized == '.' ||
      normalized == '..' ||
      normalized.contains('/') ||
      normalized.contains('\\') ||
      normalized.contains('\u0000')) {
    throw ArgumentError.value(value, 'name', 'is not a safe basename');
  }
  return normalized;
}

String _checkedSha256(String value) {
  final normalized = value.trim().toLowerCase();
  if (!_sha256Pattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'sha256Digest', 'is invalid');
  }
  return normalized;
}

String _checkedRevision(String value) {
  final normalized = value.trim().toLowerCase();
  if (!_revisionPattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'sourceRevision', 'is invalid');
  }
  return normalized;
}

String _checkedLabel(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 160) {
    throw ArgumentError.value(value, name, 'is invalid');
  }
  return normalized;
}

String _checkedHttpsUri(String value, String name) {
  final normalized = value.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw ArgumentError.value(value, name, 'must be a safe HTTPS URI');
  }
  return normalized;
}

List<String> _checkedLocales(Iterable<String> values) {
  final locales = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = value.trim().toLowerCase();
    if (!_localePattern.hasMatch(normalized) || !seen.add(normalized)) {
      throw ArgumentError.value(value, 'locales', 'is invalid or duplicated');
    }
    locales.add(normalized);
  }
  if (locales.isEmpty) {
    throw ArgumentError.value(values, 'locales', 'must not be empty');
  }
  return List<String>.unmodifiable(locales);
}

List<DesktopLocalAsrModelFileDescriptor> _checkedFiles(
  Iterable<DesktopLocalAsrModelFileDescriptor> values,
) {
  final files = <DesktopLocalAsrModelFileDescriptor>[];
  final seen = <String>{};
  for (final file in values) {
    if (!seen.add(file.name)) {
      throw ArgumentError.value(file.name, 'files', 'is duplicated');
    }
    files.add(file);
  }
  if (files.isEmpty) {
    throw ArgumentError.value(values, 'files', 'must not be empty');
  }
  files.sort((left, right) => left.name.compareTo(right.name));
  return List<DesktopLocalAsrModelFileDescriptor>.unmodifiable(files);
}
