const int maxAccountRuntimeAuthorityPolicyRevision = 0x1fffffffffffff;

enum AccountRuntimeAuthorityMode {
  off,
  shadow,
  enforce;

  static AccountRuntimeAuthorityMode parse(Object? source) => switch (source) {
    'off' => AccountRuntimeAuthorityMode.off,
    'shadow' => AccountRuntimeAuthorityMode.shadow,
    'enforce' => AccountRuntimeAuthorityMode.enforce,
    _ => throw const FormatException(
      'runtime authority policy mode is invalid',
    ),
  };

  static AccountRuntimeAuthorityMode parseCompileMaximum(String source) =>
      parse(source);

  AccountRuntimeAuthorityMode cappedBy(AccountRuntimeAuthorityMode maximum) =>
      index <= maximum.index ? this : maximum;
}

final class AccountRuntimeAuthorityPolicy {
  const AccountRuntimeAuthorityPolicy({
    required this.mode,
    required this.revision,
    required this.expiresAt,
    required this.remainingTtl,
    required this.pollAfter,
  });

  static const Duration maximumRemainingTtl = Duration(days: 1);
  static const Duration maximumPollAfter = Duration(days: 1);

  final AccountRuntimeAuthorityMode mode;
  final int revision;
  final DateTime expiresAt;
  final Duration remainingTtl;
  final Duration pollAfter;

  factory AccountRuntimeAuthorityPolicy.fromJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('runtime authority policy is invalid');
    }
    final json = Map<String, Object?>.from(source);
    const allowed = <String>{
      'mode',
      'revision',
      'expiresAt',
      'remainingTtlMs',
      'pollAfterMs',
    };
    if (json.length != allowed.length ||
        json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException(
        'runtime authority policy fields are invalid',
      );
    }
    final revision = json['revision'];
    if (revision is! int ||
        revision < 1 ||
        revision > maxAccountRuntimeAuthorityPolicyRevision) {
      throw const FormatException(
        'runtime authority policy revision is invalid',
      );
    }
    final remainingTtlMs = json['remainingTtlMs'];
    if (remainingTtlMs is! int ||
        remainingTtlMs < 1 ||
        remainingTtlMs > maximumRemainingTtl.inMilliseconds) {
      throw const FormatException(
        'runtime authority policy remainingTtlMs is invalid',
      );
    }
    final pollAfterMs = json['pollAfterMs'];
    if (pollAfterMs is! int ||
        pollAfterMs < 1 ||
        pollAfterMs > maximumPollAfter.inMilliseconds ||
        pollAfterMs > remainingTtlMs) {
      throw const FormatException(
        'runtime authority policy pollAfterMs is invalid',
      );
    }
    return AccountRuntimeAuthorityPolicy(
      mode: AccountRuntimeAuthorityMode.parse(json['mode']),
      revision: revision,
      expiresAt: _strictUtcTimestamp(json['expiresAt']),
      remainingTtl: Duration(milliseconds: remainingTtlMs),
      pollAfter: Duration(milliseconds: pollAfterMs),
    );
  }

  bool hasSameRevisionContents(AccountRuntimeAuthorityPolicy other) =>
      revision == other.revision &&
      mode == other.mode &&
      remainingTtl == other.remainingTtl &&
      pollAfter == other.pollAfter;

  static DateTime _strictUtcTimestamp(Object? source) {
    if (source is! String) {
      throw const FormatException(
        'runtime authority policy expiresAt is invalid',
      );
    }
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})'
      r'(?:\.\d{1,9})?Z$',
    ).firstMatch(source);
    if (match == null) {
      throw const FormatException(
        'runtime authority policy expiresAt must be RFC3339 UTC',
      );
    }
    late final DateTime parsed;
    try {
      parsed = DateTime.parse(source);
    } on FormatException {
      throw const FormatException(
        'runtime authority policy expiresAt is invalid',
      );
    }
    if (!parsed.isUtc ||
        parsed.year != int.parse(match.group(1)!) ||
        parsed.month != int.parse(match.group(2)!) ||
        parsed.day != int.parse(match.group(3)!) ||
        parsed.hour != int.parse(match.group(4)!) ||
        parsed.minute != int.parse(match.group(5)!) ||
        parsed.second != int.parse(match.group(6)!)) {
      throw const FormatException(
        'runtime authority policy expiresAt is invalid',
      );
    }
    return parsed;
  }
}
