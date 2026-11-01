enum ContentReviewKind { comment, consumption, delivery }

enum ContentReviewState { pending, approved, rejected, processing }

enum ContentReviewAppealState { pending, upheld, reopened }

class ContentReview {
  const ContentReview({
    required this.id,
    required this.kind,
    required this.targetId,
    required this.state,
    required this.version,
    required this.createdAt,
    this.commentText,
    this.appealState,
    this.delivery,
    this.reasonCode,
  });
  final String id;
  final ContentReviewKind kind;
  final String targetId;
  final ContentReviewState state;
  final int version;
  final DateTime createdAt;
  final String? commentText;
  final ContentReviewAppealState? appealState;
  final DeliveryReviewInfo? delivery;
  final String? reasonCode;

  factory ContentReview.fromJson(Map<String, dynamic> data) {
    final version = data['version'];
    final text = data['commentText'];
    final rawAppeal = data['appealState'];
    final rawDelivery = data['delivery'];
    final rawReason = data['reasonCode'];
    final appeal = ContentReviewAppealState.values
        .where((v) => v.name == rawAppeal)
        .firstOrNull;
    final kind = ContentReviewKind.values
        .where((v) => v.name == data['kind'])
        .firstOrNull;
    final state = ContentReviewState.values
        .where((v) => v.name == data['state'])
        .firstOrNull;
    final created = data['createdAt'] is String
        ? DateTime.tryParse(data['createdAt'] as String)
        : null;
    if ((text != null &&
            (text is! String ||
                text.runes.length > 180 ||
                kind != ContentReviewKind.comment)) ||
        (rawAppeal != null && appeal == null) ||
        kind == null ||
        state == null ||
        (state == ContentReviewState.processing &&
            kind != ContentReviewKind.delivery) ||
        (kind == ContentReviewKind.delivery) != (rawDelivery != null) ||
        (rawReason != null && rawReason is! String) ||
        version is! int ||
        version < 1 ||
        version > 9007199254740991 ||
        created == null) {
      throw const FormatException('invalid_review');
    }
    return ContentReview(
      id: reviewKey(data['id'], 40),
      kind: kind,
      targetId: reviewKey(data['targetId'], 48),
      state: state,
      version: version,
      createdAt: created,
      commentText: text as String?,
      appealState: appeal,
      delivery: rawDelivery == null
          ? null
          : DeliveryReviewInfo.fromJson(rawDelivery),
      reasonCode: rawReason == null ? null : reviewKey(rawReason, 64),
    );
  }
}

class DeliveryReviewInfo {
  const DeliveryReviewInfo({
    required this.origin,
    required this.exceptionReason,
    required this.activityOccurredAt,
    required this.qualifiedAt,
  });

  final String origin;
  final String exceptionReason;
  final DateTime activityOccurredAt;
  final DateTime qualifiedAt;

  factory DeliveryReviewInfo.fromJson(Object raw) {
    const fields = {
      'origin',
      'exceptionReason',
      'activityOccurredAt',
      'qualifiedAt',
    };
    if (raw is! Map<String, dynamic> ||
        raw.keys.any((key) => !fields.contains(key)) ||
        raw['origin'] != 'content' ||
        !{
          'evidence_conflict',
          'pool_already_settled',
        }.contains(raw['exceptionReason'])) {
      throw const FormatException('invalid_delivery_review');
    }
    final activity = raw['activityOccurredAt'] is String
        ? DateTime.tryParse(raw['activityOccurredAt'] as String)
        : null;
    final qualified = raw['qualifiedAt'] is String
        ? DateTime.tryParse(raw['qualifiedAt'] as String)
        : null;
    if (activity == null || qualified == null || qualified.isBefore(activity)) {
      throw const FormatException('invalid_delivery_review_time');
    }
    return DeliveryReviewInfo(
      origin: raw['origin'] as String,
      exceptionReason: raw['exceptionReason'] as String,
      activityOccurredAt: activity.toUtc(),
      qualifiedAt: qualified.toUtc(),
    );
  }
}

String reviewKey(Object? raw, int max) {
  if (raw is! String ||
      raw.length > max ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(raw)) {
    throw const FormatException('invalid_review_id');
  }
  return raw;
}

abstract interface class ContentReviewGateway {
  String get contextKey;
  bool get reviewActive;
  Stream<void> get reviewChanges;
  Future<List<ContentReview>> reviews();
  Future<void> appealReview(ContentReview review, String reason);
}
