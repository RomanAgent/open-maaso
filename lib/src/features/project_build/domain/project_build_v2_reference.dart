import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'project_reference_selection.dart';

Map<String, Object?> _object(
  Object? raw,
  Set<String> keys, {
  Set<String> optional = const {},
}) {
  if (raw is! Map ||
      raw.keys.any(
        (key) =>
            key is! String || !keys.contains(key) && !optional.contains(key),
      ) ||
      keys.any((key) => !raw.containsKey(key)) ||
      optional.any((key) => raw.containsKey(key) && raw[key] == null)) {
    throw const FormatException('project_reference_fields');
  }
  return Map<String, Object?>.from(raw);
}

String _digest(Object? raw) {
  if (raw is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw)) {
    throw const FormatException('project_reference_digest');
  }
  return raw;
}

String _referenceId(Object? raw) {
  if (raw is! String ||
      !RegExp(
        r'^ref_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      ).hasMatch(raw)) {
    throw const FormatException('project_reference_id');
  }
  return raw;
}

ProjectReferencePurpose? _purpose(Object? raw, {bool optional = false}) {
  if (raw == null && optional) return null;
  for (final item in ProjectReferencePurpose.values) {
    if (item.name == raw) return item;
  }
  throw const FormatException('project_reference_purpose');
}

int _integer(Object? raw, int maximum) {
  if (raw is! int || raw < 1 || raw > maximum) {
    throw const FormatException('project_reference_limit');
  }
  return raw;
}

final class ProjectBuildReferenceInput {
  ProjectBuildReferenceInput({
    required this.referenceId,
    required this.sha256,
    this.purpose,
  }) {
    _referenceId(referenceId);
    _digest(sha256);
  }
  final String referenceId, sha256;

  /// Null preserves an old exact command body. It never grants asset use.
  final ProjectReferencePurpose? purpose;
  Map<String, Object?> toJson() => {
    'referenceId': referenceId,
    'sha256': sha256,
    if (purpose != null) 'purpose': purpose!.name,
  };
  factory ProjectBuildReferenceInput.fromJson(Object? raw) {
    final value = _object(
      raw,
      {'referenceId', 'sha256'},
      optional: {'purpose'},
    );
    return ProjectBuildReferenceInput(
      referenceId: _referenceId(value['referenceId']),
      sha256: _digest(value['sha256']),
      purpose: _purpose(value['purpose'], optional: true),
    );
  }
}

final class ProjectBuildReferenceUploadRequest {
  ProjectBuildReferenceUploadRequest({
    required this.requestId,
    required this.mediaType,
    required this.contentBase64,
    required this.purpose,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(requestId) ||
        !const {'image/jpeg', 'image/png'}.contains(mediaType) ||
        contentBase64.length > 2796204) {
      throw const FormatException('project_reference_upload');
    }
    final bytes = base64Decode(contentBase64);
    if (bytes.isEmpty ||
        bytes.length > ProjectReferenceSelection.maximumImageBytes ||
        base64Encode(bytes) != contentBase64) {
      throw const FormatException('project_reference_upload');
    }
    originalSha256 = sha256.convert(bytes).toString();
  }
  final String requestId, mediaType, contentBase64;
  final ProjectReferencePurpose purpose;
  late final String originalSha256;
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'mediaType': mediaType,
    'contentBase64': contentBase64,
    'purpose': purpose.name,
  };
}

final class ProjectBuildReferenceReceipt {
  ProjectBuildReferenceReceipt._(
    this.referenceId,
    this.originalSha256,
    this.sha256,
    this.byteLength,
    this.mediaType,
    this.width,
    this.height,
    this.expiresAt,
    this.purpose,
  );
  final String referenceId, originalSha256, sha256, mediaType;
  final int byteLength, width, height;
  final DateTime expiresAt;
  final ProjectReferencePurpose? purpose;
  factory ProjectBuildReferenceReceipt.fromJson(Object? raw) {
    final value = _object(
      raw,
      {
        'schemaVersion',
        'referenceId',
        'originalSha256',
        'sha256',
        'byteLength',
        'mediaType',
        'width',
        'height',
        'expiresAt',
      },
      optional: {'purpose'},
    );
    final expires = value['expiresAt'];
    if (value['schemaVersion'] is! int ||
        value['schemaVersion'] != 2 ||
        !const {'image/jpeg', 'image/png'}.contains(value['mediaType']) ||
        expires is! String ||
        !expires.endsWith('Z')) {
      throw const FormatException('project_reference_receipt');
    }
    final at = DateTime.tryParse(expires);
    if (at == null || !at.isUtc) {
      throw const FormatException('project_reference_receipt');
    }
    final width = _integer(value['width'], 4096),
        height = _integer(value['height'], 4096);
    if (width * height > 16 * 1024 * 1024) {
      throw const FormatException('project_reference_limit');
    }
    return ProjectBuildReferenceReceipt._(
      _referenceId(value['referenceId']),
      _digest(value['originalSha256']),
      _digest(value['sha256']),
      _integer(
        value['byteLength'],
        ProjectReferenceSelection.maximumImageBytes,
      ),
      value['mediaType']! as String,
      width,
      height,
      at,
      _purpose(value['purpose'], optional: true),
    );
  }
  bool matches(ProjectBuildReferenceUploadRequest request) =>
      originalSha256 == request.originalSha256 &&
      mediaType == request.mediaType &&
      purpose == request.purpose;
  ProjectBuildReferenceInput get input => ProjectBuildReferenceInput(
    referenceId: referenceId,
    sha256: sha256,
    purpose: purpose,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'referenceId': referenceId,
    'originalSha256': originalSha256,
    'sha256': sha256,
    'byteLength': byteLength,
    'mediaType': mediaType,
    'width': width,
    'height': height,
    'expiresAt': expiresAt.toIso8601String(),
    if (purpose != null) 'purpose': purpose!.name,
  };
}
