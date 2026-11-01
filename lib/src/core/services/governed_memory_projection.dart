import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/episode.dart';

/// Typed, bounded payload attached to a governed memory revision.
///
/// Episode rows remain suitable for review and audit, while the account-local
/// projection sidecar retains the structured value needed to rebuild a read
/// model after accept, delete, or restore.
final class GovernedMemoryProjectionDraft {
  GovernedMemoryProjectionDraft({
    required String kind,
    required Map<String, Object?> payload,
  }) : kind = _validateKind(kind),
       payload = Map<String, Object?>.unmodifiable(_normalizeMap(payload)) {
    canonicalPayload = jsonEncode(this.payload);
    if (canonicalPayload.runes.length > maxCanonicalPayloadLength) {
      throw ArgumentError.value(
        canonicalPayload.length,
        'payload',
        'canonical payload exceeds $maxCanonicalPayloadLength characters',
      );
    }
    digest = sha256.convert(utf8.encode(canonicalPayload)).toString();
  }

  static const int maxCanonicalPayloadLength = 32768;

  final String kind;
  final Map<String, Object?> payload;
  late final String canonicalPayload;
  late final String digest;

  bool matchesClaimValueFingerprint(Object? value) =>
      value is String &&
      value ==
          sha256
              .convert(utf8.encode('claim-value-v2:$canonicalPayload'))
              .toString();
}

final class GovernedMemoryProjectionRecord {
  GovernedMemoryProjectionRecord({
    required this.episodeId,
    required this.accountScopeDigest,
    required GovernedMemoryProjectionDraft draft,
  }) : kind = draft.kind,
       payload = draft.payload,
       canonicalPayload = draft.canonicalPayload,
       digest = draft.digest {
    if (episodeId < 1) {
      throw ArgumentError.value(episodeId, 'episodeId');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest)) {
      throw ArgumentError.value(accountScopeDigest, 'accountScopeDigest');
    }
  }

  final int episodeId;
  final String accountScopeDigest;
  final String kind;
  final Map<String, Object?> payload;
  final String canonicalPayload;
  final String digest;

  bool matchesClaimValueFingerprint(Object? value) =>
      value is String &&
      value ==
          sha256
              .convert(utf8.encode('claim-value-v2:$canonicalPayload'))
              .toString();

  Map<String, Object?> toStored() => <String, Object?>{
    'schemaVersion': 1,
    'accountScopeDigest': accountScopeDigest,
    'episodeId': episodeId,
    'kind': kind,
    'payload': payload,
    'digest': digest,
  };

  factory GovernedMemoryProjectionRecord.fromStored(
    Object? source, {
    required int expectedEpisodeId,
    required String expectedAccountScopeDigest,
    String? expectedKind,
  }) {
    try {
      if (source is! Map) throw const FormatException();
      final row = Map<String, Object?>.from(source);
      if (row['schemaVersion'] != 1 ||
          row['episodeId'] != expectedEpisodeId ||
          row['accountScopeDigest'] != expectedAccountScopeDigest ||
          row['kind'] is! String ||
          row['payload'] is! Map ||
          row['digest'] is! String) {
        throw const FormatException();
      }
      final draft = GovernedMemoryProjectionDraft(
        kind: row['kind']! as String,
        payload: Map<String, Object?>.from(row['payload']! as Map),
      );
      if ((expectedKind != null && draft.kind != expectedKind) ||
          draft.digest != row['digest']) {
        throw const FormatException();
      }
      return GovernedMemoryProjectionRecord(
        episodeId: expectedEpisodeId,
        accountScopeDigest: expectedAccountScopeDigest,
        draft: draft,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('governed projection row is invalid');
    }
  }
}

/// Durable compare-and-swap head for one account-owned projection kind.
///
/// The revision head and the accepted materialized revision are intentionally
/// separate: a pending or rejected proposal may be the newest audit revision
/// while an older accepted profile remains active.
final class GovernedMemoryProjectionHeadRecord {
  const GovernedMemoryProjectionHeadRecord({
    required this.kind,
    required this.headEpisodeId,
    required this.activeEpisodeId,
    required this.revision,
    required this.reviewState,
    required this.materializationComplete,
    required this.materializedActiveEpisodeId,
  });

  final String kind;
  final int headEpisodeId;
  final int? activeEpisodeId;
  final int revision;
  final EpisodeReviewState reviewState;
  final bool materializationComplete;
  final int? materializedActiveEpisodeId;

  Map<String, Object?> toStored({
    required String accountScopeDigest,
    required DateTime updatedAt,
  }) => <String, Object?>{
    'schemaVersion': 1,
    'accountScopeDigest': accountScopeDigest,
    'kind': kind,
    'headEpisodeId': headEpisodeId,
    'activeEpisodeId': activeEpisodeId,
    'revision': revision,
    'reviewState': reviewState.name,
    'materializationComplete': materializationComplete,
    'materializedActiveEpisodeId': materializedActiveEpisodeId,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
  };

  factory GovernedMemoryProjectionHeadRecord.fromStored(
    Object? source, {
    required String expectedKind,
    required String expectedAccountScopeDigest,
  }) {
    if (source is! Map) {
      throw const FormatException('governed projection head is invalid');
    }
    final row = Map<String, Object?>.from(source);
    final headEpisodeId = (row['headEpisodeId'] as num?)?.toInt();
    final activeEpisodeId = (row['activeEpisodeId'] as num?)?.toInt();
    final revision = (row['revision'] as num?)?.toInt();
    final materializedActiveEpisodeId =
        (row['materializedActiveEpisodeId'] as num?)?.toInt();
    EpisodeReviewState? reviewState;
    for (final candidate in EpisodeReviewState.values) {
      if (candidate.name == row['reviewState']) {
        reviewState = candidate;
        break;
      }
    }
    if (row['schemaVersion'] != 1 ||
        row['accountScopeDigest'] != expectedAccountScopeDigest ||
        row['kind'] != expectedKind ||
        headEpisodeId == null ||
        headEpisodeId < 1 ||
        (activeEpisodeId != null && activeEpisodeId < 1) ||
        revision == null ||
        revision < 1 ||
        reviewState == null ||
        row['materializationComplete'] is! bool ||
        (materializedActiveEpisodeId != null &&
            materializedActiveEpisodeId < 1) ||
        (row['materializationComplete'] == true &&
            materializedActiveEpisodeId != activeEpisodeId)) {
      throw const FormatException('governed projection head is invalid');
    }
    return GovernedMemoryProjectionHeadRecord(
      kind: expectedKind,
      headEpisodeId: headEpisodeId,
      activeEpisodeId: activeEpisodeId,
      revision: revision,
      reviewState: reviewState,
      materializationComplete: row['materializationComplete']! as bool,
      materializedActiveEpisodeId: materializedActiveEpisodeId,
    );
  }
}

/// Account-owned materialized view updated only from accepted-current memory.
abstract interface class GovernedMemoryProjectionSink {
  String get projectionKind;

  /// Rejects a self-consistent JSON payload that does not satisfy this
  /// projection kind's schema. This runs before canonical governance state is
  /// admitted and must not mutate the sink.
  void validateProjection(GovernedMemoryProjectionDraft projection);

  Future<void> apply(GovernedMemoryProjectionRecord record);

  Future<void> clear();
}

/// A bounded, typed family of independently reviewed conversation facts.
///
/// Every kind still owns its own revision/active head. The family must validate
/// both its kind suffix and its payload; it cannot claim unrelated exact kinds.
abstract interface class GovernedMemoryProjectionFamilySink {
  String get projectionKindPrefix;

  bool acceptsProjectionKind(String kind);

  void validateProjection(GovernedMemoryProjectionDraft projection);

  /// Dependencies in addition to the current authenticated human source.
  /// The coordinator verifies these against actual published chat records.
  List<EpisodeSourceRef> supportingSources(
    GovernedMemoryProjectionDraft projection,
  );

  Future<void> apply(GovernedMemoryProjectionRecord record);

  Future<void> clear(String kind);
}

String _validateKind(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'kind', 'invalid projection kind');
  }
  return normalized;
}

Map<String, Object?> _normalizeMap(Map source) {
  if (source.length > 64 || source.keys.any((key) => key is! String)) {
    throw ArgumentError.value(source, 'payload', 'invalid projection map');
  }
  final keys = source.keys.cast<String>().toList(growable: false)..sort();
  return <String, Object?>{
    for (final key in keys)
      key: _normalizeValue(source[key], path: 'payload.$key'),
  };
}

Object? _normalizeValue(Object? value, {required String path}) {
  if (value == null || value is bool || value is int) return value;
  if (value is double) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, path, 'must be finite');
    }
    return value;
  }
  if (value is String) {
    if (value.runes.length >
        GovernedMemoryProjectionDraft.maxCanonicalPayloadLength) {
      throw ArgumentError.value(value.length, path, 'string is too long');
    }
    return value;
  }
  if (value is List) {
    if (value.length > 64) {
      throw ArgumentError.value(value.length, path, 'list is too long');
    }
    return List<Object?>.unmodifiable(
      value.indexed.map(
        (entry) => _normalizeValue(entry.$2, path: '$path[${entry.$1}]'),
      ),
    );
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(_normalizeMap(value));
  }
  throw ArgumentError.value(value.runtimeType, path, 'unsupported value');
}
