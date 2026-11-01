enum ActivityEvidenceStorageClass { localDerivedThumbnail }

/// Opaque metadata for a locally persisted, derived image.
///
/// Raw image bytes and filesystem paths are deliberately absent from this
/// contract. Image decoding and re-encoding belong to a future host adapter.
final class ActivityEvidenceArtifact {
  ActivityEvidenceArtifact({
    required String localObjectId,
    required String derivedSha256,
    required String mimeType,
    required this.byteLength,
    required this.pixelWidth,
    required this.pixelHeight,
    this.storageClass = ActivityEvidenceStorageClass.localDerivedThumbnail,
  }) : localObjectId = _boundedId(localObjectId, 'localObjectId'),
       derivedSha256 = _sha256(derivedSha256, 'derivedSha256'),
       mimeType = mimeType.trim().toLowerCase() {
    if (byteLength < 1 || byteLength > maxThumbnailBytes) {
      throw ArgumentError.value(byteLength, 'byteLength');
    }
    if (pixelWidth < 1 ||
        pixelWidth > maxThumbnailDimension ||
        pixelHeight < 1 ||
        pixelHeight > maxThumbnailDimension) {
      throw ArgumentError('thumbnail dimensions are outside policy bounds');
    }
  }

  static const int maxThumbnailBytes = 2 * 1024 * 1024;
  static const int maxThumbnailDimension = 2048;

  final String localObjectId;
  final String derivedSha256;
  final String mimeType;
  final int byteLength;
  final int pixelWidth;
  final int pixelHeight;
  final ActivityEvidenceStorageClass storageClass;
}

/// Host-issued, one-shot proof that an image passed the privacy transform.
///
/// The private constructor deliberately prevents application and agent code
/// from manufacturing a receipt by setting metadata-removal booleans.
final class ActivityEvidencePrivacyReceipt {
  ActivityEvidencePrivacyReceipt._({
    required Object seal,
    required String id,
    required String accountId,
    required this.facadeGeneration,
    required String sourceSha256,
    required String derivedSha256,
    required this.transformedAt,
  }) : _seal = seal,
       id = _boundedId(id, 'id'),
       accountId = _boundedId(accountId, 'accountId'),
       sourceSha256 = _sha256(sourceSha256, 'sourceSha256'),
       derivedSha256 = _sha256(derivedSha256, 'derivedSha256') {
    if (facadeGeneration < 1) {
      throw ArgumentError.value(facadeGeneration, 'facadeGeneration');
    }
  }

  final Object _seal;
  final String id;
  final String accountId;
  final int facadeGeneration;
  final String sourceSha256;
  final String derivedSha256;
  final DateTime transformedAt;
  bool _consumed = false;
}

/// Paired authority. The transformer owns [issuer] and the activity service
/// owns [verifier]; a separately-created pair cannot mint accepted receipts.
final class ActivityEvidencePrivacyAuthority {
  ActivityEvidencePrivacyAuthority._({
    required this.issuer,
    required this.verifier,
  });

  factory ActivityEvidencePrivacyAuthority.create() {
    final seal = Object();
    return ActivityEvidencePrivacyAuthority._(
      issuer: ActivityEvidencePrivacyReceiptIssuer._(seal),
      verifier: ActivityEvidencePrivacyReceiptVerifier._(seal),
    );
  }

  final ActivityEvidencePrivacyReceiptIssuer issuer;
  final ActivityEvidencePrivacyReceiptVerifier verifier;
}

final class ActivityEvidencePrivacyReceiptIssuer {
  const ActivityEvidencePrivacyReceiptIssuer._(this._seal);

  final Object _seal;

  ActivityEvidencePrivacyReceipt issue({
    required String id,
    required String accountId,
    required int facadeGeneration,
    required String sourceSha256,
    required String derivedSha256,
    required DateTime transformedAt,
  }) => ActivityEvidencePrivacyReceipt._(
    seal: _seal,
    id: id,
    accountId: accountId,
    facadeGeneration: facadeGeneration,
    sourceSha256: sourceSha256,
    derivedSha256: derivedSha256,
    transformedAt: transformedAt.toUtc(),
  );
}

final class ActivityEvidencePrivacyReceiptVerifier {
  const ActivityEvidencePrivacyReceiptVerifier._(this._seal);

  static const Duration maxReceiptAge = Duration(minutes: 15);

  final Object _seal;

  /// Consumes before checking bindings so a mismatched attempt cannot turn a
  /// valid receipt into a reusable oracle.
  bool consume({
    required ActivityEvidencePrivacyReceipt receipt,
    required ActivityEvidenceArtifact artifact,
    required String accountId,
    required int facadeGeneration,
    required DateTime admittedAt,
  }) {
    if (!identical(receipt._seal, _seal) || receipt._consumed) return false;
    receipt._consumed = true;
    final admitted = admittedAt.toUtc();
    final age = admitted.difference(receipt.transformedAt.toUtc());
    return receipt.accountId == accountId &&
        receipt.facadeGeneration == facadeGeneration &&
        !age.isNegative &&
        age <= maxReceiptAge &&
        artifact.storageClass ==
            ActivityEvidenceStorageClass.localDerivedThumbnail &&
        ActivityEvidencePrivacyPolicy.allowedThumbnailMimeTypes.contains(
          artifact.mimeType,
        ) &&
        artifact.derivedSha256 == receipt.derivedSha256;
  }
}

final class ActivityEvidencePrivacyPolicy {
  const ActivityEvidencePrivacyPolicy();

  static const Set<String> allowedThumbnailMimeTypes = <String>{
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  String? diagnoseArtifact(ActivityEvidenceArtifact artifact) {
    if (artifact.storageClass !=
        ActivityEvidenceStorageClass.localDerivedThumbnail) {
      return 'evidence_storage_not_local_thumbnail';
    }
    if (!allowedThumbnailMimeTypes.contains(artifact.mimeType)) {
      return 'evidence_mime_not_allowed';
    }
    return null;
  }
}

String _boundedId(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 256) {
    throw ArgumentError.value(value, field);
  }
  return normalized;
}

String _sha256(String value, String field) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, field, 'must be a SHA-256 hex digest');
  }
  return normalized;
}
