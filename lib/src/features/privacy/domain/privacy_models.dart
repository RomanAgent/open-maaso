/// Public disclosures and consent state. Birth dates, account IDs and provider
/// credentials are deliberately absent from all response models.
abstract final class PrivacyScopes {
  static const cloudText = 'cloud_text';
  static const cloudVoice = 'cloud_voice';
  static const cloudImage = 'cloud_image';
  static const contentModeration = 'content_moderation';
  static const all = {cloudText, cloudVoice, cloudImage, contentModeration};
}

final class PrivacyException implements Exception {
  const PrivacyException(this.code);
  final String code;
  @override
  String toString() => 'PrivacyException($code)';
}

final class PrivacyRecipient {
  PrivacyRecipient._(
    this.id,
    this.name,
    this.policyUrl,
    this.apiOrigins,
    this.scopes,
    this.dataCategories,
  );
  final String id;
  final String name;
  final Uri policyUrl;
  final List<String> apiOrigins;
  final List<String> scopes;
  final List<String> dataCategories;

  factory PrivacyRecipient.fromJson(Object? raw) {
    final m = _map(raw);
    final origins = _strings(m['apiOrigins'], 16);
    for (final origin in origins) {
      final uri = _publicUrl(origin);
      if (uri.origin != origin || uri.path.isNotEmpty || uri.hasQuery) {
        _invalid();
      }
    }
    final scopes = _strings(m['scopes'], 4);
    if (!scopes.every(PrivacyScopes.all.contains)) _invalid();
    return PrivacyRecipient._(
      _key(m['id'], 64),
      _text(m['name'], 120),
      _publicUrl(m['policyUrl']),
      origins,
      scopes,
      _strings(m['dataCategories'], 16, limit: 300),
    );
  }
}

final class PrivacyPolicy {
  PrivacyPolicy._(
    this.version,
    this.effectiveAt,
    this.operatorName,
    this.supportEmail,
    this.privacyUrl,
    this.termsUrl,
    this.minimumAge,
    this.recipients,
  );
  final String version;
  final DateTime effectiveAt;
  final String operatorName;
  final String supportEmail;
  final Uri privacyUrl;
  final Uri termsUrl;
  final int minimumAge;
  final List<PrivacyRecipient> recipients;

  factory PrivacyPolicy.fromJson(Object? raw) {
    final m = _map(raw);
    final age = _integer(m['minimumAge']);
    if (age < 13 || age > 21) _invalid();
    final email = _text(m['supportEmail'], 320);
    if (!RegExp(r'^[^\s<>@]+@[^\s<>@]+$').hasMatch(email)) _invalid();
    final rawRecipients = m['recipients'];
    if (rawRecipients is! List ||
        rawRecipients.isEmpty ||
        rawRecipients.length > 16) {
      _invalid();
    }
    final recipients = rawRecipients.map(PrivacyRecipient.fromJson).toList();
    if (recipients.map((r) => r.id).toSet().length != recipients.length) {
      _invalid();
    }
    return PrivacyPolicy._(
      _key(m['version'], 96),
      _date(m['effectiveAt']),
      _text(m['operatorName'], 200),
      email,
      _publicUrl(m['privacyUrl']),
      _publicUrl(m['termsUrl']),
      age,
      List.unmodifiable(recipients),
    );
  }

  PrivacyRecipient? recipient(String id, String scope) {
    for (final value in recipients) {
      if (value.id == id && value.scopes.contains(scope)) return value;
    }
    return null;
  }
}

final class PrivacyPublicPolicy {
  const PrivacyPublicPolicy._(this.ready, this.policy, this.policyHash);
  final bool ready;
  final PrivacyPolicy? policy;
  final String? policyHash;

  factory PrivacyPublicPolicy.fromJson(Object? raw) {
    final m = _map(raw);
    final ready = _boolean(m['ready']);
    if (!ready) {
      if (m['policy'] != null || m['policyHash'] != null) _invalid();
      return const PrivacyPublicPolicy._(false, null, null);
    }
    final hash = _text(m['policyHash'], 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) _invalid();
    return PrivacyPublicPolicy._(
      true,
      PrivacyPolicy.fromJson(m['policy']),
      hash,
    );
  }
}

final class PrivacyConsent {
  PrivacyConsent._(
    this.recipientId,
    this.scope,
    this.allowed,
    this.current,
    this.updatedAt,
    this.explicitAllowed,
  );
  final String recipientId;
  final String scope;
  final bool allowed;
  final bool current;
  final DateTime updatedAt;

  /// Raw persisted human choice. Legacy `allowed:false,current:false` may
  /// describe an expired grant and must not be mistaken for a withdrawal.
  final bool? explicitAllowed;
  bool? get explicitChoice => explicitAllowed ?? (current ? allowed : null);

  factory PrivacyConsent.fromJson(Object? raw) {
    final m = _map(raw);
    final scope = _text(m['scope'], 32);
    if (!PrivacyScopes.all.contains(scope)) _invalid();
    final allowed = _boolean(m['allowed']);
    final current = _boolean(m['current']);
    final explicit = m.containsKey('explicitAllowed')
        ? _boolean(m['explicitAllowed'])
        : null;
    if (allowed && !current) _invalid();
    if (explicit != null && allowed != (explicit && current)) _invalid();
    return PrivacyConsent._(
      _key(m['recipientId'], 64),
      scope,
      allowed,
      current,
      _date(m['updatedAt']),
      explicit,
    );
  }
}

final class PrivacySnapshot {
  PrivacySnapshot._(
    this.publicPolicy,
    this.revision,
    this.ageStatus,
    this.declaredAt,
    this.consents,
  );
  final PrivacyPublicPolicy publicPolicy;
  final int revision;
  final String ageStatus;
  final DateTime? declaredAt;
  final List<PrivacyConsent> consents;
  bool get ready => publicPolicy.ready;
  PrivacyPolicy? get policy => publicPolicy.policy;
  String? get policyHash => publicPolicy.policyHash;
  bool get ageEligible => ageStatus == 'eligible';

  factory PrivacySnapshot.fromJson(Object? raw) {
    final m = _map(raw);
    if (m.containsKey('birthDate') ||
        m.containsKey('accountUUID') ||
        m.containsKey('accountId')) {
      _invalid();
    }
    final policy = PrivacyPublicPolicy.fromJson(m);
    final age = _text(m['ageStatus'], 16);
    if (!{'unconfirmed', 'eligible', 'ineligible'}.contains(age)) _invalid();
    final declaredAt = m['declaredAt'] == null ? null : _date(m['declaredAt']);
    if ((age == 'unconfirmed') != (declaredAt == null)) _invalid();
    final rawConsents = m['consents'];
    if (rawConsents is! List || rawConsents.length > 1024) _invalid();
    final consents = rawConsents.map(PrivacyConsent.fromJson).toList();
    final keys = <String>{};
    for (final value in consents) {
      if (!keys.add('${value.recipientId}|${value.scope}')) _invalid();
      if (value.current &&
          policy.policy?.recipient(value.recipientId, value.scope) == null) {
        _invalid();
      }
    }
    return PrivacySnapshot._(
      policy,
      _integer(m['revision']),
      age,
      declaredAt,
      List.unmodifiable(consents),
    );
  }

  bool? explicitChoice(String recipientId, String scope) {
    for (final value in consents) {
      if (value.recipientId == recipientId && value.scope == scope) {
        return value.explicitChoice;
      }
    }
    return null;
  }

  /// Availability defaults to enabled. This does not create a consent record
  /// or imply that an age declaration or disclosure was supplied.
  bool allows(String recipientId, String scope) =>
      PrivacyScopes.all.contains(scope) &&
      RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(recipientId) &&
      ageStatus != 'ineligible' &&
      explicitChoice(recipientId, scope) != false;
}

abstract interface class PrivacyGateway {
  String get requestContextKey;
  bool get hasAccount;
  Future<PrivacyPublicPolicy> policy({required String expectedContextKey});
  Future<PrivacySnapshot> read({required String expectedContextKey});
  Future<PrivacySnapshot> declareAge({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String birthDate,
  });
  Future<PrivacySnapshot> setConsent({
    required String expectedContextKey,
    required String requestKey,
    required int expectedRevision,
    required String expectedPolicyVersion,
    required String expectedPolicyHash,
    required String recipientId,
    required String scope,
    required bool allow,
  });
}

Never _invalid() => throw const FormatException('invalid_privacy_response');
Map<Object?, Object?> _map(Object? value) {
  if (value is! Map) _invalid();
  return Map<Object?, Object?>.from(value);
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > max ||
      value.runes.any((r) => r < 32 || (r >= 127 && r <= 159))) {
    _invalid();
  }
  return value;
}

String _key(Object? value, int max) {
  final key = _text(value, max);
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(key)) _invalid();
  return key;
}

int _integer(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) _invalid();
  return value;
}

bool _boolean(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

DateTime _date(Object? value) {
  if (value is! String || !value.endsWith('Z')) _invalid();
  final date = DateTime.tryParse(value);
  if (date == null || !date.isUtc) _invalid();
  return date;
}

Uri _publicUrl(Object? value) {
  final raw = _text(value, 2048);
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !uri.host.contains('.') ||
      uri.host == 'localhost' ||
      uri.host.endsWith('.example') ||
      uri.host.endsWith('.invalid')) {
    _invalid();
  }
  return uri;
}

List<String> _strings(Object? raw, int max, {int limit = 2048}) {
  if (raw is! List || raw.isEmpty || raw.length > max) _invalid();
  final values = raw.map((v) => _text(v, limit)).toList();
  if (values.toSet().length != values.length) _invalid();
  return List.unmodifiable(values);
}
