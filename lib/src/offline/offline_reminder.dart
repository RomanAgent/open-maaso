enum OfflineReminderStatus {
  disabled,
  pending,
  scheduled,
  cancelPending,
  failed,
}

/// A user-authored local reminder. It carries no model execution instruction.
class OfflineReminder {
  const OfflineReminder({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledAt,
    required this.createdAt,
    required this.updatedAt,
    this.repeatsDaily = false,
    this.status = OfflineReminderStatus.disabled,
    this.errorCode = '',
  });
  static const maxCount = 64;
  static const errorCodes = {
    '',
    'permission_denied',
    'unsupported_platform',
    'schedule_failed',
    'cancellation_failed',
    'storage_failed',
    'interrupted',
    'cancelled',
  };
  final String id, title, body, errorCode;
  final DateTime scheduledAt, createdAt, updatedAt;
  final bool repeatsDaily;
  final OfflineReminderStatus status;
  bool get enabled => status == OfflineReminderStatus.scheduled;
  String get deliveryId => 'scheduled-task:open-maaso:$id';

  OfflineReminder copyWith({
    String? title,
    String? body,
    DateTime? scheduledAt,
    DateTime? updatedAt,
    bool? repeatsDaily,
    OfflineReminderStatus? status,
    String? errorCode,
  }) => OfflineReminder(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    scheduledAt: scheduledAt ?? this.scheduledAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    repeatsDaily: repeatsDaily ?? this.repeatsDaily,
    status: status ?? this.status,
    errorCode: errorCode ?? this.errorCode,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'scheduledAt': scheduledAt.toUtc().millisecondsSinceEpoch,
    'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
    'repeatsDaily': repeatsDaily,
    'status': status.name,
    'errorCode': errorCode,
  };
  factory OfflineReminder.fromJson(Map<String, Object?> json) {
    const allowed = {
      'id',
      'title',
      'body',
      'scheduledAt',
      'createdAt',
      'updatedAt',
      'repeatsDaily',
      'status',
      'errorCode',
    };
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unexpected reminder field.');
    }
    String text(String key, int maximum, {bool empty = false}) {
      final value = json[key];
      if (value is! String ||
          value.length > maximum ||
          (!empty && value.trim().isEmpty) ||
          RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Invalid reminder text.');
      }
      return value;
    }

    DateTime date(String key) {
      final value = json[key];
      if (value is! int || value < 0 || value > 253402300799999) {
        throw const FormatException('Invalid reminder timestamp.');
      }
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }

    final id = text('id', 160);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(id)) {
      throw const FormatException('Invalid reminder ID.');
    }
    final statusName = text('status', 32);
    final statuses = OfflineReminderStatus.values.where(
      (s) => s.name == statusName,
    );
    final errorCode = text('errorCode', 40, empty: true);
    final repeat = json['repeatsDaily'];
    if (statuses.isEmpty ||
        repeat is! bool ||
        !errorCodes.contains(errorCode)) {
      throw const FormatException('Invalid reminder state.');
    }
    final createdAt = date('createdAt'), updatedAt = date('updatedAt');
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('Reminder dates are inconsistent.');
    }
    return OfflineReminder(
      id: id,
      title: text('title', 120),
      body: text('body', 1000, empty: true),
      scheduledAt: date('scheduledAt'),
      createdAt: createdAt,
      updatedAt: updatedAt,
      repeatsDaily: repeat,
      status: statuses.single,
      errorCode: errorCode,
    );
  }
}
