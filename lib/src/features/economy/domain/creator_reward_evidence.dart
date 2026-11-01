/// Recent activity evidence is separate from coin estimates and wallet entries.
/// An accepted record proves pool admission, not that coins have settled.
final class CreatorRewardEvidence {
  const CreatorRewardEvidence._({
    required this.id,
    required this.contentId,
    required this.kind,
    required this.state,
    required this.reason,
    required this.occurredAt,
    required this.qualifiedAt,
  });

  final String id, contentId, kind, state, reason;
  final DateTime occurredAt;
  final DateTime? qualifiedAt;

  factory CreatorRewardEvidence.fromJson(Object? value) {
    final row = _object(value);
    final kind = _key(row['kind'], 16);
    final state = _key(row['state'], 20);
    if (!const {'game', 'applet'}.contains(kind) ||
        !const {'pending', 'review_hold', 'submitted'}.contains(state)) {
      throw const FormatException('invalid_creator_evidence_state');
    }
    final qualified = row['qualifiedAt'] == null
        ? null
        : _time(row['qualifiedAt']);
    if (state != 'review_hold' && qualified == null) {
      throw const FormatException('missing_creator_qualification');
    }
    return CreatorRewardEvidence._(
      id: _key(row['id'], 64),
      contentId: _key(row['contentId'], 48),
      kind: kind,
      state: state,
      reason: _key(row['reason'], 32),
      occurredAt: _time(row['occurredAt']),
      qualifiedAt: qualified,
    );
  }
}

final class CreatorRewardEvidencePage {
  CreatorRewardEvidencePage._(this.pending, this.reviewHold, this.submitted);
  static const perStateLimit = 10;
  final List<CreatorRewardEvidence> pending, reviewHold, submitted;
  bool get isEmpty =>
      pending.isEmpty && reviewHold.isEmpty && submitted.isEmpty;

  factory CreatorRewardEvidencePage.fromJson(Object? value) {
    final page = _object(value);
    final seen = <String>{};
    List<CreatorRewardEvidence> group(String key, String expectedState) {
      final values = page[key];
      if (values is! List || values.length > perStateLimit) {
        throw const FormatException('invalid_creator_evidence_page');
      }
      return List.unmodifiable(
        values.map((value) {
          final row = CreatorRewardEvidence.fromJson(value);
          if (row.state != expectedState || !seen.add(row.id)) {
            throw const FormatException('inconsistent_creator_evidence_page');
          }
          return row;
        }),
      );
    }

    return CreatorRewardEvidencePage._(
      group('pending', 'pending'),
      group('reviewHold', 'review_hold'),
      group('submitted', 'submitted'),
    );
  }
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('invalid_creator_evidence_object');
  }
  return value;
}

String _key(Object? value, int maximum) {
  if (value is! String ||
      value.length > maximum ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value)) {
    throw const FormatException('invalid_creator_evidence_key');
  }
  return value;
}

DateTime _time(Object? value) {
  final time = value is String && value.length <= 40
      ? DateTime.tryParse(value)
      : null;
  if (time == null || !time.isUtc) {
    throw const FormatException('invalid_creator_evidence_time');
  }
  return time;
}
