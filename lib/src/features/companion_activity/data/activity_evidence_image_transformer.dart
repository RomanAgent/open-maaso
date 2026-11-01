import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/companion_activity/domain/activity_evidence_privacy.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast.dart';

abstract interface class ActivityEvidenceDerivedThumbnailStore {
  Future<void> put({
    required String objectId,
    required String derivedSha256,
    required Uint8List bytes,
  });
}

/// Account-scoped persistence for derived thumbnails only. There is no API
/// capable of accepting a source path or source-image metadata.
final class SembastActivityEvidenceDerivedThumbnailStore
    implements ActivityEvidenceDerivedThumbnailStore {
  SembastActivityEvidenceDerivedThumbnailStore({
    required Database database,
    required this.scope,
  }) : _database = database;

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>(
        'companion_activity_derived_thumbnails.v1',
      );

  final Database _database;
  final ActivityScope scope;

  @override
  Future<void> put({
    required String objectId,
    required String derivedSha256,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty ||
        bytes.length > ActivityEvidenceArtifact.maxThumbnailBytes) {
      return Future<void>.error(
        StateError('activity_evidence_thumbnail_size_invalid'),
      );
    }
    final actualDigest = sha256.convert(bytes).toString();
    if (actualDigest != derivedSha256) {
      return Future<void>.error(
        StateError('activity_evidence_thumbnail_digest_mismatch'),
      );
    }
    return _store.record(objectId).put(_database, <String, Object?>{
      'accountId': scope.accountId,
      'facadeGeneration': scope.facadeGeneration,
      'derivedSha256': derivedSha256,
      'bytes': Uint8List.fromList(bytes),
    });
  }
}

final class ActivityEvidencePrivacyTransformResult {
  const ActivityEvidencePrivacyTransformResult({
    required this.artifact,
    required this.receipt,
  });

  final ActivityEvidenceArtifact artifact;
  final ActivityEvidencePrivacyReceipt receipt;
}

/// Host-only pixel transform. Source bytes are method-local and are never
/// passed to the persistence interface.
final class ActivityEvidenceImageTransformer {
  ActivityEvidenceImageTransformer({
    required this.scope,
    required ActivityEvidencePrivacyReceiptIssuer receiptIssuer,
    required ActivityEvidenceDerivedThumbnailStore thumbnailStore,
    DateTime Function()? clock,
    String Function(String derivedDigest, DateTime transformedAt)?
    objectIdFactory,
  }) : _receiptIssuer = receiptIssuer,
       _thumbnailStore = thumbnailStore,
       _clock = clock ?? DateTime.now,
       _objectIdFactory = objectIdFactory ?? _defaultObjectId;

  static const int maxSourceBytes = 8 * 1024 * 1024;
  static const int maxSourceDimension = 8192;
  static const int maxSourcePixels = 24 * 1024 * 1024;

  final ActivityScope scope;
  final ActivityEvidencePrivacyReceiptIssuer _receiptIssuer;
  final ActivityEvidenceDerivedThumbnailStore _thumbnailStore;
  final DateTime Function() _clock;
  final String Function(String derivedDigest, DateTime transformedAt)
  _objectIdFactory;

  Future<ActivityEvidencePrivacyTransformResult> transform(
    Uint8List sourceBytes,
  ) async {
    if (sourceBytes.isEmpty || sourceBytes.length > maxSourceBytes) {
      throw StateError('activity_evidence_source_size_invalid');
    }
    final decoder = image.findDecoderForData(sourceBytes);
    final info = decoder?.startDecode(sourceBytes);
    if (decoder == null ||
        info == null ||
        info.numFrames != 1 ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > maxSourceDimension ||
        info.height > maxSourceDimension ||
        info.width * info.height > maxSourcePixels) {
      throw StateError('activity_evidence_image_invalid');
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      throw StateError('activity_evidence_image_invalid');
    }

    final scale = decoded.width > decoded.height
        ? ActivityEvidenceArtifact.maxThumbnailDimension / decoded.width
        : ActivityEvidenceArtifact.maxThumbnailDimension / decoded.height;
    final resized = scale < 1
        ? image.copyResize(
            decoded,
            width: (decoded.width * scale).round().clamp(1, 2048),
            height: (decoded.height * scale).round().clamp(1, 2048),
            interpolation: image.Interpolation.average,
          )
        : decoded;

    // Copy pixels into a new image container. This intentionally discards
    // EXIF/GPS, ICC, text chunks, animation frames, and decoder metadata.
    final pixelsOnly = image.Image(
      width: resized.width,
      height: resized.height,
      numChannels: 3,
    );
    image.compositeImage(pixelsOnly, resized);
    final derivedBytes = image.encodeJpg(pixelsOnly, quality: 82);
    if (derivedBytes.isEmpty ||
        derivedBytes.length > ActivityEvidenceArtifact.maxThumbnailBytes) {
      throw StateError('activity_evidence_thumbnail_size_invalid');
    }
    final verified = image.JpegDecoder().decode(derivedBytes);
    if (verified == null || verified.hasExif && !verified.exif.isEmpty) {
      throw StateError('activity_evidence_privacy_transform_failed');
    }

    final transformedAt = _clock().toUtc();
    final sourceDigest = sha256.convert(sourceBytes).toString();
    final derivedDigest = sha256.convert(derivedBytes).toString();
    final objectId = _objectIdFactory(derivedDigest, transformedAt);
    await _thumbnailStore.put(
      objectId: objectId,
      derivedSha256: derivedDigest,
      bytes: Uint8List.fromList(derivedBytes),
    );
    final artifact = ActivityEvidenceArtifact(
      localObjectId: objectId,
      derivedSha256: derivedDigest,
      mimeType: 'image/jpeg',
      byteLength: derivedBytes.length,
      pixelWidth: pixelsOnly.width,
      pixelHeight: pixelsOnly.height,
    );
    return ActivityEvidencePrivacyTransformResult(
      artifact: artifact,
      receipt: _receiptIssuer.issue(
        id: 'privacy-$objectId',
        accountId: scope.accountId,
        facadeGeneration: scope.facadeGeneration,
        sourceSha256: sourceDigest,
        derivedSha256: derivedDigest,
        transformedAt: transformedAt,
      ),
    );
  }

  static String _defaultObjectId(String digest, DateTime at) =>
      'thumb-${digest.substring(0, 24)}-${at.microsecondsSinceEpoch}';
}
