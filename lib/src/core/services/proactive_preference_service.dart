import 'dart:async';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/agent_persona_memory_store.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int maxProactivePreferenceRevision = 0x1fffffffffffff;

bool _requiredStoredBool(Map<String, Object?> value, String field) {
  if (value[field] is! bool) {
    throw const FormatException('invalid contact consent');
  }
  return value[field]! as bool;
}

DateTime? _optionalPreferenceDate(Object? value) {
  if (value == null) return null;
  final date = value is String ? DateTime.tryParse(value) : null;
  if (date == null) throw const FormatException('invalid contact date');
  return date;
}

List<ProactiveConversationTopic> _decodeTopics(Object? value) {
  if (value is! List || value.length > 32) {
    throw const FormatException('invalid contact topics');
  }
  final topics = value.map(ProactiveConversationTopic.fromJson).toList();
  if (topics.map((topic) => topic.id).toSet().length != topics.length) {
    throw const FormatException('duplicate contact topic');
  }
  return List.unmodifiable(topics);
}

enum ProactiveContactObservation {
  none,
  scheduled,
  closed,
  cancelled,
  needsTime,
  unavailable;

  String? get replyGuidance => switch (this) {
    none => null,
    scheduled =>
      'A one-time check-in agreement was saved from this authenticated user message. Briefly confirm only that specific topic and time; do not imply ongoing proactive permission. Quiet hours, runtime ownership and unanswered-contact waiting still apply. Do not promise guaranteed delivery.',
    closed =>
      'The agreed one-time follow-up is now complete and closed. Do not promise a later check-in about it.',
    cancelled =>
      'The user cancelled this one-time follow-up and it is now closed. Briefly acknowledge; do not promise to contact them about it again.',
    needsTime =>
      'The user requested a one-time follow-up but no unambiguous clock time was provided. No check-in has been scheduled. Ask for one complete request containing the topic, date and local clock time, for example 明天15点问我面试结果 / Tomorrow at 15:00 ask me about the interview. A bare time in a later message is not sufficient in this version. Do not claim it is arranged.',
    unavailable =>
      'The requested check-in was not saved. Briefly say it could not be arranged and do not claim it is scheduled.',
  };
}

enum ProactiveContactFrequency {
  low,
  balanced,
  high;

  static ProactiveContactFrequency parse(Object? source) => switch (source) {
    'low' => ProactiveContactFrequency.low,
    'balanced' => ProactiveContactFrequency.balanced,
    'high' => ProactiveContactFrequency.high,
    _ => throw const FormatException('proactive frequency is invalid'),
  };
}

enum ProactiveContactSensitivity {
  low,
  balanced,
  high;

  static ProactiveContactSensitivity parse(Object? source) => switch (source) {
    'low' => ProactiveContactSensitivity.low,
    'balanced' => ProactiveContactSensitivity.balanced,
    'high' => ProactiveContactSensitivity.high,
    _ => throw const FormatException('proactive sensitivity is invalid'),
  };
}

/// Immutable account-owned hard preference consumed by foreground and OS
/// proactive paths. Device notification permission and OS categories remain
/// owned by [NotificationPreferencesService].
final class ProactivePreferenceSnapshot {
  const ProactivePreferenceSnapshot({
    required this.generation,
    required this.revision,
    required this.hardMuted,
    required this.foregroundEnabled,
    required this.osOutreachEnabled,
    required this.quietStartMinutes,
    required this.quietEndMinutes,
    required this.dailyBudget,
    required this.frequency,
    required this.sensitivity,
    this.consentRecorded = true,
    this.needsConsentReview = false,
    this.contactScope = ProactiveConversationScope.everyday,
    this.authorizedUntil,
    this.authorizationOwnerKey,
    this.agreementChangedAt,
    this.lastUserReturnAt,
    this.topics = const [],
  });

  const ProactivePreferenceSnapshot.defaults({
    required int generation,
    int revision = 1,
  }) : this(
         generation: generation,
         revision: revision,
         hardMuted: false,
         foregroundEnabled: false,
         osOutreachEnabled: false,
         quietStartMinutes: 22 * 60,
         quietEndMinutes: 7 * 60,
         dailyBudget: 1,
         frequency: ProactiveContactFrequency.balanced,
         sensitivity: ProactiveContactSensitivity.balanced,
         consentRecorded: false,
         contactScope: ProactiveConversationScope.openTopics,
       );

  const ProactivePreferenceSnapshot.disabled({required int generation})
    : this(
        generation: generation,
        revision: 0,
        hardMuted: true,
        foregroundEnabled: false,
        osOutreachEnabled: false,
        quietStartMinutes: 0,
        quietEndMinutes: 0,
        dailyBudget: 0,
        frequency: ProactiveContactFrequency.low,
        sensitivity: ProactiveContactSensitivity.low,
      );

  static const int schemaVersion = 2;

  final int generation;
  final int revision;
  final bool hardMuted;
  final bool foregroundEnabled;
  final bool osOutreachEnabled;
  final int quietStartMinutes;
  final int quietEndMinutes;
  final int dailyBudget;
  final ProactiveContactFrequency frequency;
  final ProactiveContactSensitivity sensitivity;
  final bool consentRecorded;
  final bool needsConsentReview;
  final ProactiveConversationScope contactScope;
  final DateTime? authorizedUntil;
  final String? authorizationOwnerKey;
  final DateTime? agreementChangedAt;
  final DateTime? lastUserReturnAt;
  final List<ProactiveConversationTopic> topics;

  bool get foregroundAllowed =>
      !hardMuted && consentRecorded && foregroundEnabled;

  bool get osOutreachAllowed =>
      !hardMuted && consentRecorded && osOutreachEnabled;

  bool authorizationCurrentAt(DateTime now) =>
      !hardMuted && (authorizedUntil == null || now.isBefore(authorizedUntil!));
  bool allowsTopic(String topicKey, DateTime now, {bool os = false}) {
    if (hardMuted) return false;
    final explicit = topics.any(
      (topic) =>
          topic.topicKey == topicKey &&
          (os ? topic.openAt(now) : topic.dueAtTime(now)),
    );
    if (topicKey.startsWith('conversation.followup.')) return explicit;
    if (!authorizationCurrentAt(now)) return false;
    return (os ? osOutreachAllowed : foregroundAllowed) &&
        contactScope == ProactiveConversationScope.everyday;
  }

  int get effectiveDailyBudget => hardMuted ? 0 : dailyBudget;

  bool isQuietAt(DateTime value) {
    if (quietStartMinutes == quietEndMinutes) return false;
    final local = value.toLocal();
    final minute = local.hour * 60 + local.minute;
    if (quietStartMinutes < quietEndMinutes) {
      return minute >= quietStartMinutes && minute < quietEndMinutes;
    }
    return minute >= quietStartMinutes || minute < quietEndMinutes;
  }

  ProactivePolicyConfig toForegroundPolicyConfig() => ProactivePolicyConfig(
    foregroundDailyLimit:
        !hardMuted &&
            (foregroundAllowed ||
                topics.any(
                  (topic) => topic.status == ProactiveTopicStatus.open,
                ))
        ? dailyBudget
        : 0,
    quietStartMinutes: quietStartMinutes,
    quietEndMinutes: quietEndMinutes,
    authorizationRevision: revision,
    authorizationGeneration: generation,
    authorizedUntil: authorizedUntil,
    lastUserReturnAt: lastUserReturnAt,
    agreementChangedAt: agreementChangedAt,
  );

  ProactivePreferenceSnapshot copyWith({
    int? generation,
    int? revision,
    bool? hardMuted,
    bool? foregroundEnabled,
    bool? osOutreachEnabled,
    int? quietStartMinutes,
    int? quietEndMinutes,
    int? dailyBudget,
    ProactiveContactFrequency? frequency,
    ProactiveContactSensitivity? sensitivity,
    bool? consentRecorded,
    bool? needsConsentReview,
    ProactiveConversationScope? contactScope,
    DateTime? authorizedUntil,
    String? authorizationOwnerKey,
    bool clearAuthorizedUntil = false,
    DateTime? agreementChangedAt,
    DateTime? lastUserReturnAt,
    List<ProactiveConversationTopic>? topics,
  }) => ProactivePreferenceSnapshot(
    generation: generation ?? this.generation,
    revision: revision ?? this.revision,
    hardMuted: hardMuted ?? this.hardMuted,
    foregroundEnabled: foregroundEnabled ?? this.foregroundEnabled,
    osOutreachEnabled: osOutreachEnabled ?? this.osOutreachEnabled,
    quietStartMinutes: quietStartMinutes ?? this.quietStartMinutes,
    quietEndMinutes: quietEndMinutes ?? this.quietEndMinutes,
    dailyBudget: dailyBudget ?? this.dailyBudget,
    frequency: frequency ?? this.frequency,
    sensitivity: sensitivity ?? this.sensitivity,
    consentRecorded: consentRecorded ?? this.consentRecorded,
    needsConsentReview: needsConsentReview ?? this.needsConsentReview,
    contactScope: contactScope ?? this.contactScope,
    authorizedUntil: clearAuthorizedUntil
        ? null
        : authorizedUntil ?? this.authorizedUntil,
    authorizationOwnerKey: authorizationOwnerKey ?? this.authorizationOwnerKey,
    agreementChangedAt: agreementChangedAt ?? this.agreementChangedAt,
    lastUserReturnAt: lastUserReturnAt ?? this.lastUserReturnAt,
    topics: List.unmodifiable(topics ?? this.topics),
  );

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'revision': revision,
    'hardMuted': hardMuted,
    'foregroundEnabled': foregroundEnabled,
    'osOutreachEnabled': osOutreachEnabled,
    'quietStartMinutes': quietStartMinutes,
    'quietEndMinutes': quietEndMinutes,
    'dailyBudget': dailyBudget,
    'frequency': frequency.name,
    'sensitivity': sensitivity.name,
    'consentRecorded': consentRecorded,
    'needsConsentReview': needsConsentReview,
    'contactScope': contactScope.name,
    'authorizedUntil': authorizedUntil?.toUtc().toIso8601String(),
    'authorizationOwnerKey': authorizationOwnerKey,
    'agreementChangedAt': agreementChangedAt?.toUtc().toIso8601String(),
    'lastUserReturnAt': lastUserReturnAt?.toUtc().toIso8601String(),
    'topics': topics.map((topic) => topic.toJson()).toList(),
  };

  factory ProactivePreferenceSnapshot.fromStorageJson(
    Object? source, {
    required int generation,
  }) {
    if (source is! Map) {
      throw const FormatException('proactive preference row is invalid');
    }
    final json = Map<String, Object?>.from(source);
    final legacy = json['schemaVersion'] == 1;
    final fields = <String>{
      'schemaVersion',
      'revision',
      'hardMuted',
      'foregroundEnabled',
      'osOutreachEnabled',
      'quietStartMinutes',
      'quietEndMinutes',
      'dailyBudget',
      'frequency',
      'sensitivity',
      if (!legacy) ...{
        'consentRecorded',
        'needsConsentReview',
        'contactScope',
        'authorizedUntil',
        'authorizationOwnerKey',
        'agreementChangedAt',
        'lastUserReturnAt',
        'topics',
      },
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        (!legacy && json['schemaVersion'] != schemaVersion)) {
      throw const FormatException('proactive preference schema is invalid');
    }
    final revision = json['revision'];
    final hardMuted = json['hardMuted'];
    final foregroundEnabled = json['foregroundEnabled'];
    final osOutreachEnabled = json['osOutreachEnabled'];
    final quietStart = json['quietStartMinutes'];
    final quietEnd = json['quietEndMinutes'];
    final dailyBudget = json['dailyBudget'];
    if (revision is! int ||
        revision < 1 ||
        revision > maxProactivePreferenceRevision ||
        hardMuted is! bool ||
        foregroundEnabled is! bool ||
        osOutreachEnabled is! bool ||
        quietStart is! int ||
        quietStart < 0 ||
        quietStart >= 24 * 60 ||
        quietEnd is! int ||
        quietEnd < 0 ||
        quietEnd >= 24 * 60 ||
        dailyBudget is! int ||
        dailyBudget < 1 ||
        dailyBudget > 3) {
      throw const FormatException('proactive preference values are invalid');
    }
    return ProactivePreferenceSnapshot(
      generation: generation,
      revision: revision,
      hardMuted: hardMuted,
      foregroundEnabled: legacy ? false : foregroundEnabled,
      osOutreachEnabled: legacy ? false : osOutreachEnabled,
      quietStartMinutes: quietStart,
      quietEndMinutes: quietEnd,
      dailyBudget: dailyBudget,
      frequency: ProactiveContactFrequency.parse(json['frequency']),
      sensitivity: ProactiveContactSensitivity.parse(json['sensitivity']),
      consentRecorded: !legacy && _requiredStoredBool(json, 'consentRecorded'),
      needsConsentReview:
          legacy || _requiredStoredBool(json, 'needsConsentReview'),
      contactScope: legacy
          ? ProactiveConversationScope.openTopics
          : ProactiveConversationScope.values.firstWhere(
              (scope) => scope.name == json['contactScope'],
              orElse: () =>
                  throw const FormatException('invalid contact scope'),
            ),
      authorizedUntil: _optionalPreferenceDate(json['authorizedUntil']),
      authorizationOwnerKey: json['authorizationOwnerKey'] == null
          ? null
          : _ownerKeyFromStorage(json['authorizationOwnerKey']),
      agreementChangedAt: _optionalPreferenceDate(json['agreementChangedAt']),
      lastUserReturnAt: _optionalPreferenceDate(json['lastUserReturnAt']),
      topics: legacy ? const [] : _decodeTopics(json['topics']),
    );
  }
}

abstract interface class ProactivePreferenceStore {
  Future<Map<String, Object?>?> read();

  Future<void> write(ProactivePreferenceSnapshot snapshot);
}

final class SembastProactivePreferenceStore
    implements ProactivePreferenceStore {
  SembastProactivePreferenceStore(
    this.database, {
    required this.accountScopeDigest,
  });

  final DBService database;
  final String accountScopeDigest;

  AgentPersonaMemoryStore get _memory => AgentPersonaMemoryStore(
    database: database.raw,
    accountScopeDigest: accountScopeDigest,
    kind: AgentPersonaMemoryKind.proactiveContact,
    legacyStoreName: 'proactive_preferences.v1',
    legacyRecordKey: 'self',
    normalizePayload: (value) => ProactivePreferenceSnapshot.fromStorageJson(
      value,
      generation: 1,
    ).toStorageJson(),
  );

  @override
  Future<Map<String, Object?>?> read() => _memory.read();

  @override
  Future<void> write(ProactivePreferenceSnapshot snapshot) =>
      _memory.write(snapshot.toStorageJson());
}

final class ProactiveLegacyPreferenceSeed {
  const ProactiveLegacyPreferenceSeed({
    required this.quietStartMinutes,
    required this.quietEndMinutes,
    required this.dailyBudget,
    required this.sourceDigest,
  });

  final int quietStartMinutes;
  final int quietEndMinutes;
  final int dailyBudget;
  final String sourceDigest;
}

abstract interface class ProactivePreferenceLegacyMigration {
  Future<ProactiveLegacyPreferenceSeed?> claim({
    required String accountScopeDigest,
  });

  Future<void> complete({
    required String accountScopeDigest,
    required String sourceDigest,
  });

  Future<void> completeOwnedClaim({required String accountScopeDigest});
}

/// Two-phase ownership journal for the old device-global quiet/budget values.
/// Only the first exact account digest may import them; crashes remain pinned
/// to that owner and can never cause a later account to claim the same state.
final class SharedPreferencesProactivePreferenceLegacyMigration
    implements ProactivePreferenceLegacyMigration {
  SharedPreferencesProactivePreferenceLegacyMigration(this._preferences);

  static const String legacyStorageKey = 'notification_preferences.v1';
  static const String journalStorageKey =
      'proactive_preferences.legacy_migration.v1';

  final SharedPreferences _preferences;

  static Future<SharedPreferencesProactivePreferenceLegacyMigration>
  create() async => SharedPreferencesProactivePreferenceLegacyMigration(
    await SharedPreferences.getInstance(),
  );

  @override
  Future<ProactiveLegacyPreferenceSeed?> claim({
    required String accountScopeDigest,
  }) async {
    _validateScopeDigest(accountScopeDigest);
    final journal = _readJournal();
    if (journal != null) {
      if (journal.ownerScopeDigest != accountScopeDigest || journal.complete) {
        return null;
      }
      return journal.toSeed();
    }

    final legacyRaw = _preferences.getString(legacyStorageKey);
    if (legacyRaw == null || legacyRaw.isEmpty) return null;

    final seed = _decodeSeed(legacyRaw);
    if (seed == null) return null;
    final claimed = _MigrationJournal(
      ownerScopeDigest: accountScopeDigest,
      sourceDigest: seed.sourceDigest,
      quietStartMinutes: seed.quietStartMinutes,
      quietEndMinutes: seed.quietEndMinutes,
      dailyBudget: seed.dailyBudget,
      complete: false,
    );
    if (!await _preferences.setString(
      journalStorageKey,
      jsonEncode(claimed.toJson()),
    )) {
      throw StateError('proactive_preference_migration_claim_failed');
    }
    return seed;
  }

  @override
  Future<void> complete({
    required String accountScopeDigest,
    required String sourceDigest,
  }) async {
    _validateScopeDigest(accountScopeDigest);
    final journal = _readJournal();
    if (journal == null ||
        journal.ownerScopeDigest != accountScopeDigest ||
        journal.sourceDigest != sourceDigest) {
      throw StateError('proactive_preference_migration_claim_mismatch');
    }
    await _writeCompleted(journal);
  }

  @override
  Future<void> completeOwnedClaim({required String accountScopeDigest}) async {
    _validateScopeDigest(accountScopeDigest);
    final journal = _readJournal();
    if (journal == null ||
        journal.complete ||
        journal.ownerScopeDigest != accountScopeDigest) {
      return;
    }
    await _writeCompleted(journal);
  }

  Future<void> _writeCompleted(_MigrationJournal journal) async {
    if (!await _preferences.setString(
      journalStorageKey,
      jsonEncode(journal.copyWith(complete: true).toJson()),
    )) {
      throw StateError('proactive_preference_migration_complete_failed');
    }
  }

  _MigrationJournal? _readJournal() {
    final raw = _preferences.getString(journalStorageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return _MigrationJournal.fromJson(jsonDecode(raw));
    } on FormatException {
      throw StateError('proactive_preference_migration_journal_invalid');
    }
  }

  ProactiveLegacyPreferenceSeed? _decodeSeed(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final preferences = NotificationPreferences.fromJson(
        decoded.cast<String, Object?>(),
      );
      return ProactiveLegacyPreferenceSeed(
        quietStartMinutes: preferences.quietStartMinutes,
        quietEndMinutes: preferences.quietEndMinutes,
        dailyBudget: preferences.dailyProactiveBudget.clamp(1, 3),
        sourceDigest: _legacySeedDigest(
          preferences.quietStartMinutes,
          preferences.quietEndMinutes,
          preferences.dailyProactiveBudget.clamp(1, 3),
        ),
      );
    } on Object {
      return null;
    }
  }
}

enum _ProactivePreferenceLifecycle {
  created,
  initializing,
  active,
  degraded,
  retired,
}

final Object _proactiveStablePolicyZoneKey = Object();

final class _ProactiveStablePolicyContext {
  const _ProactiveStablePolicyContext(this.owner, this.snapshot);

  final ProactivePreferenceService owner;
  final ProactivePreferenceSnapshot snapshot;
}

/// Account-owned proactive-contact preference with write-before-publish
/// persistence and synchronous retirement fencing.
final class ProactivePreferenceService extends AppService {
  ProactivePreferenceService({
    required ProactivePreferenceStore store,
    required this.accountScopeDigest,
    required this.generation,
    ProactivePreferenceLegacyMigration? legacyMigration,
    DateTime Function()? clock,
  }) : _store = store,
       _legacyMigration = legacyMigration,
       _clock = clock ?? DateTime.now,
       state = ProactivePreferenceSnapshot.disabled(
         generation: generation,
       ).obs {
    _validateScopeDigest(accountScopeDigest);
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  final ProactivePreferenceStore _store;
  final ProactivePreferenceLegacyMigration? _legacyMigration;
  final DateTime Function() _clock;
  final Map<String, StreamSubscription<Object?>> _topicWatches = {};
  Timer? _expiryTimer;
  bool _awaitingTimedRequest = false;
  final String accountScopeDigest;
  final int generation;
  final Rx<ProactivePreferenceSnapshot> state;
  Future<void>? _initialization;
  Future<void> _mutationTail = Future<void>.value();
  ProactivePreferenceSnapshot? _persisted;
  _ProactivePreferenceLifecycle _lifecycle =
      _ProactivePreferenceLifecycle.created;
  bool _pendingHardMute = false;
  bool _stablePolicyOperationActive = false;
  int _hardMuteIntentEpoch = 0;
  bool _latestHardMuteIntent = false;

  bool get isAvailable =>
      _lifecycle == _ProactivePreferenceLifecycle.active && !isClosed;

  ProactivePreferenceSnapshot get effectiveSnapshot => isAvailable
      ? state.value
      : ProactivePreferenceSnapshot.disabled(generation: generation);

  Future<ProactivePreferenceService> init() async {
    if (isClosed || _lifecycle != _ProactivePreferenceLifecycle.created) {
      throw StateError('proactive_preferences_already_initialized');
    }
    _lifecycle = _ProactivePreferenceLifecycle.initializing;
    final initialization = _initialize();
    _initialization = initialization;
    await initialization;
    return this;
  }

  Future<void> _initialize() async {
    try {
      final stored = await _store.read();
      if (!_isInitializing) return;
      if (stored != null) {
        final restored = ProactivePreferenceSnapshot.fromStorageJson(
          stored,
          generation: generation,
        );
        if (stored['schemaVersion'] !=
            ProactivePreferenceSnapshot.schemaVersion) {
          await _store.write(restored);
        }
        _persisted = restored;
        try {
          await _legacyMigration?.completeOwnedClaim(
            accountScopeDigest: accountScopeDigest,
          );
        } on Object {
          Log.w('[ProactivePreference] migration completion retry failed');
        }
        _activate(restored);
        return;
      }

      final seed = await _legacyMigration?.claim(
        accountScopeDigest: accountScopeDigest,
      );
      if (!_isInitializing) return;
      final initial =
          ProactivePreferenceSnapshot.defaults(generation: generation).copyWith(
            quietStartMinutes: seed?.quietStartMinutes,
            quietEndMinutes: seed?.quietEndMinutes,
            dailyBudget: seed?.dailyBudget,
            needsConsentReview: seed != null,
          );
      // Application defaults are usable state, not an explicit owner choice.
      // Only remembered legacy values or a later user mutation become memory.
      if (seed != null) await _store.write(initial);
      _persisted = initial;
      if (seed != null) {
        try {
          await _legacyMigration?.complete(
            accountScopeDigest: accountScopeDigest,
            sourceDigest: seed.sourceDigest,
          );
        } on Object {
          Log.w('[ProactivePreference] migration completion deferred');
        }
      }
      if (_isInitializing) _activate(initial);
    } on Object {
      if (_isInitializing) {
        _lifecycle = _ProactivePreferenceLifecycle.degraded;
        state.value = ProactivePreferenceSnapshot.disabled(
          generation: generation,
        );
        Log.w('[ProactivePreference] state unavailable; outreach is muted');
      }
    }
  }

  Future<void> setHardMuted(bool muted) {
    _requireActive();
    final intentEpoch = ++_hardMuteIntentEpoch;
    _latestHardMuteIntent = muted;
    if (muted) {
      _pendingHardMute = true;
    }
    // Admit the mutation before publishing the synchronous fail-closed view.
    // An Rx listener may re-enter this method, and that later intent must be
    // serialized after (rather than accidentally before) the mute that caused
    // the notification.
    final mutation = _serializeMutation(() async {
      if (muted && !state.value.hardMuted) {
        state.value = state.value.copyWith(hardMuted: true);
      }
      final next = _nextPersisted(
        (current) =>
            current.copyWith(hardMuted: muted, agreementChangedAt: _clock()),
      );
      final durable =
          intentEpoch != _hardMuteIntentEpoch &&
              _latestHardMuteIntent &&
              !next.hardMuted
          ? next.copyWith(hardMuted: true)
          : next;
      await _store.write(durable);
      _persisted = durable;
      if (intentEpoch == _hardMuteIntentEpoch || durable.hardMuted) {
        _pendingHardMute = false;
      }
      _publishIfActive(durable);
    });
    if (muted && !_stablePolicyOperationActive) {
      state.value = state.value.copyWith(hardMuted: true);
    }
    return mutation;
  }

  Future<void> setForegroundEnabled(bool enabled) => _update(
    (current) => current.copyWith(
      foregroundEnabled: enabled,
      consentRecorded: enabled ? true : null,
      needsConsentReview: false,
      authorizationOwnerKey: enabled ? _currentOwnerKey() : null,
      agreementChangedAt: _clock(),
    ),
  );

  Future<void> setOsOutreachEnabled(bool enabled) => _update(
    (current) => current.copyWith(
      osOutreachEnabled: enabled,
      consentRecorded: enabled ? true : null,
      needsConsentReview: false,
      authorizationOwnerKey: enabled ? _currentOwnerKey() : null,
      agreementChangedAt: _clock(),
    ),
  );

  String? _currentOwnerKey() {
    final coordinator = appServices.maybeFind<AccountDeviceLeaseCoordinator>();
    if (coordinator == null) return null;
    final receipt = coordinator.currentReceipt;
    return receipt == null ? 'unbound' : '${receipt.leaseId}:${receipt.epoch}';
  }

  Future<void> setContactAgreement({
    required bool enabled,
    required ProactiveConversationScope scope,
    DateTime? expiresAt,
  }) async {
    if (expiresAt != null && !expiresAt.isAfter(_clock())) {
      throw ArgumentError('contact authorization must expire in the future');
    }
    if (!enabled) await setHardMuted(true);
    await _update(
      (current) => current.copyWith(
        foregroundEnabled: enabled,
        osOutreachEnabled: enabled,
        hardMuted: enabled ? false : current.hardMuted,
        consentRecorded: true,
        needsConsentReview: false,
        authorizationOwnerKey: _currentOwnerKey(),
        contactScope: scope,
        authorizedUntil: expiresAt,
        clearAuthorizedUntil: expiresAt == null,
        agreementChangedAt: _clock(),
        topics: enabled
            ? current.topics
            : [
                for (final topic in current.topics)
                  topic.close(ProactiveTopicStatus.revoked),
              ],
      ),
    );
  }

  Future<void> setContactScope(ProactiveConversationScope scope) => _update(
    (current) =>
        current.copyWith(contactScope: scope, agreementChangedAt: _clock()),
  );

  Future<void> setAuthorizationExpiry(DateTime? expiry) {
    if (expiry != null && !expiry.isAfter(_clock())) {
      return Future.error(
        ArgumentError('contact authorization must expire in the future'),
      );
    }
    return _update(
      (current) => current.copyWith(
        authorizedUntil: expiry,
        clearAuthorizedUntil: expiry == null,
        agreementChangedAt: _clock(),
      ),
    );
  }

  Future<void> closeConversationTopic(String id) => _update(
    (current) => current.copyWith(
      topics: [
        for (final topic in current.topics)
          topic.id == id ? topic.close(ProactiveTopicStatus.completed) : topic,
      ],
    ),
  );

  /// Authenticated human return and narrowly timed one-time contact agreement.
  /// A notification, model tool call or synthetic Presence turn cannot grant it.
  Future<ProactiveContactObservation> observeCurrentTurn() async {
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    final current = await writer?.currentPersistedUserSource();
    if (current == null || _lifecycle != _ProactivePreferenceLifecycle.active) {
      return ProactiveContactObservation.none;
    }
    final proposedTopic = parseDirectFollowup(
      current.text,
      current.reference,
      current.timestamp.toLocal(),
      agentId: current.agentId,
      ownerKey: _currentOwnerKey(),
    );
    final owner = appServices.maybeFind<AccountDeviceLeaseCoordinator>();
    final topic = owner != null && !owner.canAdmitMutations
        ? null
        : proposedTopic;
    var closedTopic = false;
    final text = current.text.trim().replaceFirst(RegExp(r'[。.!！]$'), '');
    try {
      await _update((snapshot) {
        closedTopic = snapshot.topics.any(
          (existing) => _closesAgreedTopic(text, existing.label),
        );
        final topics = [
          for (final existing in snapshot.topics)
            (snapshot.hardMuted && topic != null)
                ? existing.close(ProactiveTopicStatus.revoked)
                : existing.status == ProactiveTopicStatus.open &&
                      _closesAgreedTopic(text, existing.label)
                ? existing.close(ProactiveTopicStatus.completed)
                : existing,
        ];
        if (topic != null && !topics.any((entry) => entry.id == topic.id)) {
          topics.removeWhere(
            (entry) =>
                entry.status != ProactiveTopicStatus.open ||
                !entry.openAt(_clock()),
          );
          if (topics.length < 32) topics.add(topic);
        }
        return snapshot.copyWith(
          lastUserReturnAt: current.timestamp,
          hardMuted: topic != null ? false : null,
          foregroundEnabled: topic != null && snapshot.hardMuted ? false : null,
          osOutreachEnabled: topic != null && snapshot.hardMuted ? false : null,
          topics: topics,
        );
      });
    } on Object {
      Log.w('[ProactivePreference] current contact agreement was not saved');
      return proposedTopic != null || _requestsUntimedFollowup(current.text)
          ? ProactiveContactObservation.unavailable
          : ProactiveContactObservation.none;
    }
    if (proposedTopic != null && topic == null) {
      return ProactiveContactObservation.unavailable;
    }
    if (topic != null) {
      _awaitingTimedRequest = false;
      try {
        if (!await writer!.conversationSourcesAreLive([
          topic.source,
        ], agentId: topic.agentId)) {
          await refreshContactSources();
          return ProactiveContactObservation.unavailable;
        }
      } on Object {
        unawaited(setHardMuted(true).catchError((Object _) {}));
        return ProactiveContactObservation.unavailable;
      }
      if (owner != null &&
          (!owner.canAdmitMutations || topic.ownerKey != _currentOwnerKey())) {
        return ProactiveContactObservation.unavailable;
      }
      return effectiveSnapshot.topics.any(
            (entry) =>
                entry.id == topic.id &&
                entry.status == ProactiveTopicStatus.open,
          )
          ? ProactiveContactObservation.scheduled
          : ProactiveContactObservation.unavailable;
    }
    if (closedTopic) {
      _awaitingTimedRequest = false;
      return RegExp(
            r'^(不用|别再|do not|stop)',
            caseSensitive: false,
          ).hasMatch(text)
          ? ProactiveContactObservation.cancelled
          : ProactiveContactObservation.closed;
    }
    if (_requestsUntimedFollowup(current.text) ||
        (_awaitingTimedRequest && _isBareContactTime(current.text))) {
      _awaitingTimedRequest = true;
      return ProactiveContactObservation.needsTime;
    }
    return ProactiveContactObservation.none;
  }

  /// Rechecked before generation and submission, including after an app restart.
  Future<void> refreshContactSources() async {
    var snapshot = effectiveSnapshot;
    if (snapshot.revision == 0) return;
    final deviceOwner = appServices.maybeFind<AccountDeviceLeaseCoordinator>();
    final ownerKey = _currentOwnerKey();
    if (deviceOwner?.canAdmitMutations == true &&
        ((snapshot.consentRecorded &&
                (snapshot.foregroundEnabled || snapshot.osOutreachEnabled) &&
                snapshot.authorizationOwnerKey != ownerKey) ||
            snapshot.topics.any(
              (topic) =>
                  topic.status == ProactiveTopicStatus.open &&
                  topic.ownerKey != ownerKey,
            ))) {
      await _update(
        (current) => current.copyWith(
          foregroundEnabled: false,
          osOutreachEnabled: false,
          consentRecorded: false,
          needsConsentReview: true,
          topics: [
            for (final topic in current.topics)
              topic.ownerKey == ownerKey
                  ? topic
                  : topic.close(ProactiveTopicStatus.revoked),
          ],
        ),
      );
      snapshot = effectiveSnapshot;
    }
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    if (writer == null &&
        snapshot.topics.any(
          (topic) => topic.status == ProactiveTopicStatus.open,
        )) {
      throw StateError('contact_source_validator_unavailable');
    }
    final revoked = <String>{};
    for (final topic in snapshot.topics.where(
      (topic) => topic.status == ProactiveTopicStatus.open,
    )) {
      if (!topic.openAt(_clock()) ||
          writer == null ||
          !await writer.conversationSourcesAreLive([
            topic.source,
          ], agentId: topic.agentId)) {
        revoked.add(topic.id);
      }
    }
    if (revoked.isNotEmpty) {
      await _update(
        (current) => current.copyWith(
          topics: [
            for (final topic in current.topics)
              revoked.contains(topic.id)
                  ? topic.close(ProactiveTopicStatus.revoked)
                  : topic,
          ],
        ),
      );
    }
  }

  Future<bool> topicSourceIsLiveWithinTransaction(
    DatabaseClient transaction,
    String topicKey,
  ) async {
    if (!topicKey.startsWith('conversation.followup.')) return true;
    final topic = effectiveSnapshot.topics
        .where((topic) => topic.topicKey == topicKey && topic.openAt(_clock()))
        .firstOrNull;
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    if (topic == null || writer == null) return false;
    return writer.conversationSourcesAreLiveWithinTransaction(transaction, [
      topic.source,
    ], agentId: topic.agentId);
  }

  void _watchTopicSources() {
    _expiryTimer?.cancel();
    final now = _clock();
    final dates = <DateTime>[
      ?state.value.authorizedUntil,
      for (final topic in state.value.topics.where(
        (topic) => topic.status == ProactiveTopicStatus.open,
      ))
        topic.expiresAt,
    ].where((date) => date.isAfter(now)).toList()..sort();
    if (dates.isNotEmpty) {
      _expiryTimer = Timer(dates.first.difference(now), () {
        if (_lifecycle != _ProactivePreferenceLifecycle.active) return;
        unawaited(
          _update(
            (current) => current.copyWith(
              topics: [
                for (final topic in current.topics)
                  topic.openAt(_clock())
                      ? topic
                      : topic.close(ProactiveTopicStatus.revoked),
              ],
            ),
          ).catchError((Object _) {}),
        );
      });
    }
    final store = _store;
    if (store is! SembastProactivePreferenceStore) return;
    final wanted = state.value.topics
        .where((topic) => topic.status == ProactiveTopicStatus.open)
        .toList();
    final ids = wanted.map((topic) => topic.id).toSet();
    for (final id in _topicWatches.keys.toList()) {
      if (!ids.contains(id)) unawaited(_topicWatches.remove(id)!.cancel());
    }
    for (final topic in wanted) {
      if (_topicWatches.containsKey(topic.id)) continue;
      final match = RegExp(
        r'^chat_message:([1-9][0-9]*)$',
      ).firstMatch(topic.source.sourceId);
      if (match == null) continue;
      _topicWatches[topic.id] = MemoryGovernanceStores.chatMessages
          .record(int.parse(match.group(1)!))
          .onSnapshot(store.database.raw)
          .listen((_) {
            if (_lifecycle == _ProactivePreferenceLifecycle.active) {
              unawaited(
                refreshContactSources().catchError((Object _) {
                  // Already scheduled OS work must be cancelled even when the
                  // source store becomes unreadable; hard mute publishes first.
                  if (_lifecycle == _ProactivePreferenceLifecycle.active) {
                    unawaited(setHardMuted(true).catchError((Object _) {}));
                  }
                }),
              );
            }
          });
    }
  }

  Future<void> setQuietHours({required int start, required int end}) {
    if (start < 0 || start >= 24 * 60 || end < 0 || end >= 24 * 60) {
      return Future<void>.error(
        ArgumentError('quiet-hour minutes must be within a day'),
      );
    }
    return _update(
      (current) => current.copyWith(
        quietStartMinutes: start,
        quietEndMinutes: end,
        agreementChangedAt: _clock(),
      ),
    );
  }

  Future<void> setDailyBudget(int budget) {
    if (budget < 1 || budget > 3) {
      return Future<void>.error(
        ArgumentError.value(budget, 'budget', 'must be between 1 and 3'),
      );
    }
    return _update(
      (current) =>
          current.copyWith(dailyBudget: budget, agreementChangedAt: _clock()),
    );
  }

  Future<void> setFrequency(ProactiveContactFrequency frequency) => _update(
    (current) =>
        current.copyWith(frequency: frequency, agreementChangedAt: _clock()),
  );

  Future<void> setSensitivity(ProactiveContactSensitivity sensitivity) =>
      _update(
        (current) => current.copyWith(
          sensitivity: sensitivity,
          agreementChangedAt: _clock(),
        ),
      );

  /// Serializes a foreground commit with preference writes.
  ///
  /// A hard mute admitted before this operation begins remains immediately
  /// fail-closed. A hard mute admitted while the operation owns the boundary
  /// linearizes immediately after it and is published before its durable write.
  Future<T> runWithStableSnapshot<T>(
    Future<T> Function(ProactivePreferenceSnapshot snapshot) operation,
  ) {
    final inherited = Zone.current[_proactiveStablePolicyZoneKey];
    if (inherited is _ProactiveStablePolicyContext &&
        identical(inherited.owner, this)) {
      return operation(inherited.snapshot);
    }
    _requireActive();
    return _serialize<T>(() async {
      _requireActive();
      _stablePolicyOperationActive = true;
      final snapshot = effectiveSnapshot;
      try {
        return await runZoned<Future<T>>(
          () => operation(snapshot),
          zoneValues: <Object?, Object?>{
            _proactiveStablePolicyZoneKey: _ProactiveStablePolicyContext(
              this,
              snapshot,
            ),
          },
        );
      } finally {
        _stablePolicyOperationActive = false;
      }
    });
  }

  Future<void> deactivateAndDrain() {
    _expiryTimer?.cancel();
    _lifecycle = _ProactivePreferenceLifecycle.retired;
    state.value = ProactivePreferenceSnapshot.disabled(generation: generation);
    final watches = _topicWatches.values.toList();
    _topicWatches.clear();
    return Future.wait<void>(<Future<void>>[
      ...watches.map((subscription) => subscription.cancel()),
      ?_initialization,
      _mutationTail,
    ], eagerError: false);
  }

  Future<void> _update(
    ProactivePreferenceSnapshot Function(ProactivePreferenceSnapshot current)
    transform,
  ) {
    _requireActive();
    return _serializeMutation(() async {
      var next = _nextPersisted(transform);
      if (_pendingHardMute && !next.hardMuted) {
        next = next.copyWith(hardMuted: true);
      }
      await _store.write(next);
      _persisted = next;
      if (_pendingHardMute && next.hardMuted) _pendingHardMute = false;
      _publishIfActive(next);
    });
  }

  ProactivePreferenceSnapshot _nextPersisted(
    ProactivePreferenceSnapshot Function(ProactivePreferenceSnapshot current)
    transform,
  ) {
    final current =
        _persisted ??
        (throw StateError('proactive_preferences_not_initialized'));
    if (current.revision >= maxProactivePreferenceRevision) {
      throw StateError('proactive_preference_revision_exhausted');
    }
    return transform(current).copyWith(revision: current.revision + 1);
  }

  Future<void> _serializeMutation(Future<void> Function() operation) {
    return _serialize<void>(operation);
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final previous = _mutationTail;
    final next = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  void _activate(ProactivePreferenceSnapshot snapshot) {
    if (!_isInitializing) return;
    _lifecycle = _ProactivePreferenceLifecycle.active;
    state.value = snapshot;
    _watchTopicSources();
  }

  void _publishIfActive(ProactivePreferenceSnapshot snapshot) {
    if (_lifecycle == _ProactivePreferenceLifecycle.active && !isClosed) {
      state.value = _pendingHardMute
          ? snapshot.copyWith(hardMuted: true)
          : snapshot;
      _watchTopicSources();
    }
  }

  bool get _isInitializing =>
      !isClosed && _lifecycle == _ProactivePreferenceLifecycle.initializing;

  void _requireActive() {
    if (isClosed || _lifecycle != _ProactivePreferenceLifecycle.active) {
      throw StateError('proactive_preferences_retired');
    }
  }

  @override
  void onClose() {
    _expiryTimer?.cancel();
    for (final subscription in _topicWatches.values) {
      unawaited(subscription.cancel());
    }
    _topicWatches.clear();
    _lifecycle = _ProactivePreferenceLifecycle.retired;
    state.value = ProactivePreferenceSnapshot.disabled(generation: generation);
    super.onClose();
  }
}

/// Keeps the proven policy/coordinator implementation while sourcing its hard
/// quiet/budget gate from the current account snapshot on every evaluation.
final class ProactivePreferencePolicyAdapter extends ProactiveCompanionPolicy {
  ProactivePreferencePolicyAdapter(this.preferences) : super();

  final ProactivePreferenceService preferences;

  @override
  ProactivePolicyConfig get config =>
      preferences.effectiveSnapshot.toForegroundPolicyConfig();

  @override
  Future<T> runWithStableConfig<T>(
    Future<T> Function(ProactivePolicyConfig config) operation,
  ) => preferences.runWithStableSnapshot(
    (snapshot) => operation(snapshot.toForegroundPolicyConfig()),
  );

  @override
  ProactiveNoveltyDecision evaluateDraft({
    required DateTime now,
    required ProactiveTopicCandidate candidate,
    required String draft,
    Iterable<ProactiveOutreachHistoryEntry> history = const [],
  }) {
    final snapshot = preferences.effectiveSnapshot;
    if (!snapshot.allowsTopic(candidate.topicKey, now)) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.dailyBudgetExhausted,
        candidate: candidate,
      );
    }
    if (snapshot.isQuietAt(now)) {
      return ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.quietHours,
        candidate: candidate,
      );
    }
    return super.evaluateDraft(
      now: now,
      candidate: candidate,
      draft: draft,
      history: history,
    );
  }
}

final class _MigrationJournal {
  const _MigrationJournal({
    required this.ownerScopeDigest,
    required this.sourceDigest,
    required this.quietStartMinutes,
    required this.quietEndMinutes,
    required this.dailyBudget,
    required this.complete,
  });

  final String ownerScopeDigest;
  final String sourceDigest;
  final int quietStartMinutes;
  final int quietEndMinutes;
  final int dailyBudget;
  final bool complete;

  ProactiveLegacyPreferenceSeed toSeed() => ProactiveLegacyPreferenceSeed(
    quietStartMinutes: quietStartMinutes,
    quietEndMinutes: quietEndMinutes,
    dailyBudget: dailyBudget,
    sourceDigest: sourceDigest,
  );

  _MigrationJournal copyWith({bool? complete}) => _MigrationJournal(
    ownerScopeDigest: ownerScopeDigest,
    sourceDigest: sourceDigest,
    quietStartMinutes: quietStartMinutes,
    quietEndMinutes: quietEndMinutes,
    dailyBudget: dailyBudget,
    complete: complete ?? this.complete,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'ownerScopeDigest': ownerScopeDigest,
    'sourceDigest': sourceDigest,
    'quietStartMinutes': quietStartMinutes,
    'quietEndMinutes': quietEndMinutes,
    'dailyBudget': dailyBudget,
    'complete': complete,
  };

  factory _MigrationJournal.fromJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('migration journal is invalid');
    }
    final json = Map<String, Object?>.from(source);
    const fields = <String>{
      'schemaVersion',
      'ownerScopeDigest',
      'sourceDigest',
      'quietStartMinutes',
      'quietEndMinutes',
      'dailyBudget',
      'complete',
    };
    final owner = json['ownerScopeDigest'];
    final digest = json['sourceDigest'];
    final quietStart = json['quietStartMinutes'];
    final quietEnd = json['quietEndMinutes'];
    final dailyBudget = json['dailyBudget'];
    final complete = json['complete'];
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != 1 ||
        owner is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(owner) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        quietStart is! int ||
        quietStart < 0 ||
        quietStart >= 24 * 60 ||
        quietEnd is! int ||
        quietEnd < 0 ||
        quietEnd >= 24 * 60 ||
        dailyBudget is! int ||
        dailyBudget < 1 ||
        dailyBudget > 3 ||
        digest != _legacySeedDigest(quietStart, quietEnd, dailyBudget) ||
        complete is! bool) {
      throw const FormatException('migration journal values are invalid');
    }
    return _MigrationJournal(
      ownerScopeDigest: owner,
      sourceDigest: digest,
      quietStartMinutes: quietStart,
      quietEndMinutes: quietEnd,
      dailyBudget: dailyBudget,
      complete: complete,
    );
  }
}

String _legacySeedDigest(int quietStart, int quietEnd, int dailyBudget) =>
    sha256
        .convert(utf8.encode('$quietStart:$quietEnd:$dailyBudget'))
        .toString();

void _validateScopeDigest(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw ArgumentError.value(
      value,
      'accountScopeDigest',
      'must be a SHA-256 digest',
    );
  }
}

// Exact direct completion/cancellation only; quoted, negative, hypothetical and
// third-party statements do not close an agreement.
bool _closesAgreedTopic(String text, String label) {
  final subjects = <String>{label};
  final subject = label.replaceFirst(RegExp(r'(结果|情况|进展)$'), '');
  if (subject.length >= 2) subjects.add(subject);
  return subjects.any(
    (value) =>
        <String>{
          '$value已经完成了',
          '$value完成了',
          '不用问$value了',
          '别再问$value了',
          '$value通过了',
          '$value已经通过了',
          '$value结束了',
          '$value已经结束了',
          '我$value通过了',
          '我$value完成了',
          '我$value结束了',
        }.contains(text) ||
        <String>{
          '$value is finished',
          '$value is complete',
          'I finished $value',
          'I completed $value',
          'Do not ask me about $value again',
          'Stop asking me about $value',
        }.map((phrase) => phrase.toLowerCase()).contains(text.toLowerCase()),
  );
}

String _ownerKeyFromStorage(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 180 ||
      RegExp(r'[\r\n]').hasMatch(value)) {
    throw const FormatException('invalid contact owner');
  }
  return value;
}

bool _requestsUntimedFollowup(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'[。.!！]$'), '');
  return RegExp(
        r'^(今天|明天|后天)[^“”"「」<>`\n]{0,24}(结束后|之后|过后)(问问我|问我|跟我聊聊)[^“”"「」<>`\n]{0,24}$',
      ).hasMatch(text) ||
      RegExp(
        r'^(today|tomorrow) after [a-zA-Z0-9 -]{2,40} (ask me|check in with me)( about [a-zA-Z0-9 -]{2,40})?$',
        caseSensitive: false,
      ).hasMatch(text);
}

bool _isBareContactTime(String raw) => RegExp(
  r'^(?:今天|明天|后天)?(?:上午|中午|下午|晚上)?(?:[一二三四五六七八九十两0-9]{1,3})(?:点(?:半|[0-9]{1,2}分)?|:[0-9]{2})[。.!！]?$|^(?:at )?[0-9]{1,2}(?::[0-9]{2})? ?(?:am|pm)?[.!]?$',
  caseSensitive: false,
).hasMatch(raw.trim());
