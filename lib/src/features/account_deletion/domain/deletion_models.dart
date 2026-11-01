final class DeletionException implements Exception {
  const DeletionException(this.code);
  final String code;
  @override
  String toString() => 'Account deletion: $code';
}

Map<String, Object?> deletionObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Invalid deletion response');
  }
  return value;
}

String deletionString(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const FormatException('Invalid deletion field');
  }
  return value;
}

DateTime? deletionTime(Object? value) =>
    value == null ? null : DateTime.parse(deletionString(value)).toUtc();

final class DeletionPreview {
  const DeletionPreview({
    required this.id,
    required this.expiresAt,
    required this.slaDays,
    required this.maintenanceNotice,
    required this.retainsOtherProducts,
    required this.retention,
    required this.subscriptions,
  });
  final String id, maintenanceNotice;
  final DateTime expiresAt;
  final int slaDays;
  final bool retainsOtherProducts;
  final List<String> retention;
  final List<DeletionSubscription> subscriptions;
  factory DeletionPreview.fromJson(Object? value) {
    final j = deletionObject(value), days = j['slaDays'];
    if (days is! int ||
        days < 1 ||
        days > 30 ||
        j['retainsOtherProducts'] is! bool ||
        j['subscriptions'] is! List ||
        j['retention'] is! List) {
      throw const FormatException('Invalid deletion preview');
    }
    return DeletionPreview(
      id: deletionString(j['previewId']),
      expiresAt: deletionTime(j['expiresAt'])!,
      slaDays: days,
      maintenanceNotice: deletionString(j['maintenanceNotice']),
      retainsOtherProducts: j['retainsOtherProducts']! as bool,
      retention: (j['retention']! as List)
          .map(deletionString)
          .toList(growable: false),
      subscriptions: (j['subscriptions']! as List)
          .map(DeletionSubscription.fromJson)
          .toList(growable: false),
    );
  }
}

final class DeletionSubscription {
  const DeletionSubscription(
    this.provider,
    this.tier,
    this.autoRenew,
    this.expiresAt,
  );
  final String provider, tier;
  final bool autoRenew;
  final DateTime expiresAt;
  Uri get manageUri => Uri.parse(
    provider == 'ios'
        ? 'https://apps.apple.com/account/subscriptions'
        : 'https://play.google.com/store/account/subscriptions',
  );
  factory DeletionSubscription.fromJson(Object? value) {
    final j = deletionObject(value);
    if (!['ios', 'android'].contains(j['provider']) ||
        j['autoRenew'] is! bool) {
      throw const FormatException('Invalid subscription');
    }
    return DeletionSubscription(
      deletionString(j['provider']),
      deletionString(j['tier']),
      j['autoRenew']! as bool,
      deletionTime(j['expiresAt'])!,
    );
  }
}

final class DeletionStatus {
  const DeletionStatus({
    required this.requestId,
    required this.state,
    this.requestedAt,
    this.dueAt,
    this.completedAt,
    required this.retainsOtherProducts,
    required this.needsOperatorAttention,
  });
  final String requestId, state;
  final DateTime? requestedAt, dueAt, completedAt;
  final bool retainsOtherProducts, needsOperatorAttention;
  bool get completed => state == 'completed' && completedAt != null;
  factory DeletionStatus.fromJson(Object? value) {
    final j = deletionObject(value);
    if (![
          'queued',
          'auth_suspended',
          'sql_erased',
          'objects_erased',
          'auth_erased',
          'completed',
        ].contains(j['state']) ||
        j['retainsOtherProducts'] is! bool ||
        j['needsOperatorAttention'] is! bool) {
      throw const FormatException('Invalid deletion status');
    }
    return DeletionStatus(
      requestId: deletionString(j['requestId']),
      state: deletionString(j['state']),
      requestedAt: deletionTime(j['requestedAt']),
      dueAt: deletionTime(j['dueAt']),
      completedAt: deletionTime(j['completedAt']),
      retainsOtherProducts: j['retainsOtherProducts']! as bool,
      needsOperatorAttention: j['needsOperatorAttention']! as bool,
    );
  }
}
