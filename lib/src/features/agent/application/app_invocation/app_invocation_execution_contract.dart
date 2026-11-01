import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'app_invocation_descriptor.dart';

const appInvocationMaximumImages = 4;
const appInvocationMaximumImageBytes = 12 * 1024 * 1024;
const appInvocationImageHandleAnnotation = 'maaso.input.image-handle.v1';
const appInvocationResultJson = ProjectJsonCanonicalizer(
  maxBytes: 64 * 1024,
  maxDepth: 16,
  maxNodes: 4096,
);

/// Native-owned input bytes; model-visible handles never contain image bytes.
final class AppInvocationInputImage {
  AppInvocationInputImage({
    required this.id,
    required this.mime,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       sha256Digest = sha256.convert(bytes).toString() {
    requireAppInvocationIdentifier(id);
    _requireImage(mime, bytes);
  }
  final String id, mime, sha256Digest;
  final Uint8List bytes;
  Map<String, Object?> toHandleJson() => {
    'id': id,
    'mime': mime,
    'byteLength': bytes.length,
    'sha256': sha256Digest,
  };
}

/// A real producer output. This is data, not a native execution capability.
/// The output receiver additionally verifies MIME signatures and decoded pixels.
final class AppInvocationProducedImage {
  AppInvocationProducedImage({
    required this.producerOutputKey,
    required this.mime,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       sha256Digest = sha256.convert(bytes).toString() {
    requireAppInvocationIdentifier(producerOutputKey);
    _requireImage(mime, bytes);
  }
  final String producerOutputKey, mime, sha256Digest;
  final Uint8List bytes;
  Map<String, Object?> toMetadataJson() => {
    'producerOutputKey': producerOutputKey,
    'mime': mime,
    'byteLength': bytes.length,
    'sha256': sha256Digest,
  };
}

enum AppInvocationActionStatus { completed, failed, outcomeUnknown, cancelled }

/// Durable action outcome, distinct from successful chat publication.
final class AppInvocationActionReceipt {
  AppInvocationActionReceipt({
    required this.invocationId,
    required this.requestId,
    required this.actionId,
    required this.identity,
    required this.contractDigest,
    required this.status,
    required this.stateVersion,
    Object? result,
    List<AppInvocationProducedImage> outputs = const [],
    this.errorCode,
  }) : result = appInvocationResultJson.parse(
         appInvocationResultJson.canonicalize(result),
       ),
       outputs = List.unmodifiable(outputs) {
    requireAppInvocationIdentifier(invocationId);
    requireAppInvocationIdentifier(requestId);
    if (actionId.isEmpty ||
        actionId.length > 256 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(contractDigest) ||
        stateVersion < 0 ||
        stateVersion >= 9007199254740991 ||
        outputs.length > appInvocationMaximumImages ||
        outputs.map((image) => image.producerOutputKey).toSet().length !=
            outputs.length ||
        (status != AppInvocationActionStatus.completed && outputs.isNotEmpty) ||
        (errorCode != null &&
            !RegExp(r'^[a-z][a-z0-9_]{0,95}$').hasMatch(errorCode!))) {
      throw const FormatException('invocation_receipt_invalid');
    }
  }
  final String invocationId, requestId, actionId, contractDigest;
  final AppInvocationIdentity identity;
  final AppInvocationActionStatus status;
  final int stateVersion;
  final Object? result;
  final List<AppInvocationProducedImage> outputs;
  final String? errorCode;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'invocationId': invocationId,
    'requestId': requestId,
    'actionId': actionId,
    'identity': identity.toJson(),
    'contractDigest': contractDigest,
    'status': status.name,
    'stateVersion': stateVersion,
    'result': result,
    'outputs': outputs.map((image) => image.toMetadataJson()).toList(),
    if (errorCode != null) 'errorCode': errorCode,
  };
  String get digest => sha256
      .convert(
        utf8.encode(const ProjectJsonCanonicalizer().canonicalize(toJson())),
      )
      .toString();
}

/// Only invocation-owned application data is exposed to a visible bundle.
/// The host supplies this port; authored code never picks a data namespace.
abstract interface class AppInvocationApplicationDataPort {
  String get invocationId;
  bool get isCurrent;
  Future<({int version, Map<String, Object?> values})> read();
  Future<({int version, Map<String, Object?> values})> save(
    Map<String, Object?> values, {
    required int expectedVersion,
    required bool Function() canContinue,
  });
}

void requireAppInvocationIdentifier(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw const FormatException('invocation_identifier_invalid');
  }
}

void _requireImage(String mime, Uint8List bytes) {
  if (!const {'image/png', 'image/jpeg'}.contains(mime) ||
      bytes.isEmpty ||
      bytes.length > appInvocationMaximumImageBytes) {
    throw const FormatException('invocation_image_invalid');
  }
}
