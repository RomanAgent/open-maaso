import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/entangled_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/governed_memory_projection.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:sembast/sembast.dart';

enum MemoryWriteDisposition {
  legacy,
  shadow,
  accepted,
  quarantined,
  rejected,
  duplicate,
}

enum MemoryWriteAuthority {
  /// A model-proposed summary of the current conversation. The Host may only
  /// promote it when the durable user message explicitly asks to remember it.
  automaticConversation,

  /// A deterministic structured extraction whose values still require user
  /// consent or owner review before they may update a materialized profile.
  governedProposal,

  /// A trusted product flow whose source material has already been verified.
  verifiedHost,

  /// Untrusted material imported from a legacy-checksummed AgentGene carrier.
  inherited,
}

enum MemoryWriteFaultPoint {
  shadowEvaluation,
  shadowAudit,
  beforeCommit,
  afterCommit,
  beforeProjection,
}

typedef MemoryWriteFaultInjector =
    FutureOr<void> Function(MemoryWriteFaultPoint point, String fingerprint);

sealed class MemoryWriteSource {
  const MemoryWriteSource();

  const factory MemoryWriteSource.currentTurn() = CurrentTurnMemorySource;

  factory MemoryWriteSource.imported({
    required String sourceKind,
    required String sourceKey,
    required String canonicalMaterial,
  }) = ImportedMemorySource;
}

final class CurrentTurnMemorySource extends MemoryWriteSource {
  const CurrentTurnMemorySource();
}

final class ImportedMemorySource extends MemoryWriteSource {
  ImportedMemorySource({
    required this.sourceKind,
    required this.sourceKey,
    required this.canonicalMaterial,
  }) {
    _requireBounded(sourceKind, 'sourceKind', maxLength: 64);
    _requireBounded(sourceKey, 'sourceKey', maxLength: 4096);
    _requireBounded(canonicalMaterial, 'canonicalMaterial', maxLength: 65536);
  }

  final String sourceKind;
  final String sourceKey;
  final String canonicalMaterial;
}

final class MemoryWriteDraft {
  MemoryWriteDraft.event({
    required String what,
    required DateTime when,
    List<String> entities = const <String>[],
    String? emotion,
    double salience = 0.5,
    EpisodeRetentionClass retentionClass = EpisodeRetentionClass.durable,
  }) : this._(
         kind: EpisodeKind.episode,
         what: what,
         when: when,
         entities: entities,
         emotion: emotion,
         salience: salience,
         retentionClass: retentionClass,
       );

  MemoryWriteDraft.claim({
    required String slot,
    required String value,
    required DateTime when,
    String? summary,
    List<String> entities = const <String>[],
    double salience = 0.7,
    EpisodeRetentionClass retentionClass = EpisodeRetentionClass.durable,
    GovernedMemoryProjectionDraft? projection,
  }) : this._(
         kind: EpisodeKind.fact,
         what: summary ?? '$slot: $value',
         when: when,
         entities: entities,
         emotion: null,
         salience: salience,
         retentionClass: retentionClass,
         claimSlot: slot,
         claimValue: value,
         projection: projection,
       );

  MemoryWriteDraft._acceptedSourceAssertion({
    required String what,
    required DateTime when,
    double salience = 0.7,
    EpisodeRetentionClass retentionClass = EpisodeRetentionClass.durable,
  }) : this._(
         kind: EpisodeKind.episode,
         what: what,
         when: when,
         entities: const <String>[],
         emotion: null,
         salience: salience,
         retentionClass: retentionClass,
         preserveWhatWhitespace: true,
       );

  MemoryWriteDraft._({
    required this.kind,
    required String what,
    required this.when,
    required List<String> entities,
    required String? emotion,
    required double salience,
    required this.retentionClass,
    this.claimSlot,
    this.claimValue,
    this.projection,
    bool preserveWhatWhitespace = false,
  }) : what = preserveWhatWhitespace ? what.trim() : _normalizeSummary(what),
       entities = List<String>.unmodifiable(_normalizeEntities(entities)),
       emotion = _optionalNormalized(emotion),
       salience = salience.clamp(0.0, 1.0) {
    if (this.what.isEmpty) {
      throw ArgumentError.value(what, 'what', 'must not be empty');
    }
    if (!salience.isFinite) {
      throw ArgumentError.value(salience, 'salience', 'must be finite');
    }
    if (claimSlot != null || claimValue != null) {
      _requireBounded(claimSlot!, 'claimSlot', maxLength: 256);
      _requireBounded(
        claimValue!,
        'claimValue',
        maxLength: projection == null
            ? 4096
            : GovernedMemoryProjectionDraft.maxCanonicalPayloadLength,
      );
    }
    if (projection != null &&
        (claimSlot == null ||
            claimValue == null ||
            claimValue != projection!.canonicalPayload)) {
      throw ArgumentError(
        'a governed projection requires a matching structured claim value',
      );
    }
  }

  final EpisodeKind kind;
  final String what;
  final DateTime when;
  final List<String> entities;
  final String? emotion;
  final double salience;
  final EpisodeRetentionClass retentionClass;
  final String? claimSlot;
  final String? claimValue;
  final GovernedMemoryProjectionDraft? projection;

  factory MemoryWriteDraft.fromEpisode(Episode episode) => MemoryWriteDraft._(
    kind: episode.kind,
    what: episode.what,
    when: episode.when,
    entities: episode.entities,
    emotion: episode.emotion,
    salience: episode.salience,
    retentionClass: episode.retentionClass,
  );

  Episode toLegacyEpisode() => Episode(
    when: when,
    what: what,
    entities: entities,
    emotion: emotion,
    salience: salience,
    retentionClass: retentionClass,
  );
}

final class MemoryWriteResult {
  const MemoryWriteResult({
    required this.disposition,
    required this.episode,
    required this.created,
    required this.projected,
    this.reason,
  });

  final MemoryWriteDisposition disposition;
  final Episode? episode;
  final bool created;
  final bool projected;
  final String? reason;

  int? get episodeId => episode?.id;
}

/// A copy of one verified persisted chat source, never a write capability.
final class PersistedConversationSource {
  const PersistedConversationSource({
    required this.reference,
    required this.agentId,
    required this.text,
    required this.timestamp,
    this.turnId,
  });

  final EpisodeSourceRef reference;
  final String agentId;
  final String text;
  final DateTime timestamp;
  final String? turnId;
}

/// Account-scoped, single-writer boundary for all new long-term memories.
///
/// In `enforce`, provenance validation, exact/semantic deduplication, claim
/// revision selection, Episode append, and governance indexes commit in one
/// Sembast transaction. Only an accepted current revision is projected into
/// entanglement and relationship side effects after that commit succeeds.
final class MemoryWriteCoordinator extends AppService {
  MemoryWriteCoordinator({
    Database? database,
    EpisodeStore? episodeStore,
    required String accountScopeDigest,
    FeatureRolloutMode Function()? memoryV2Mode,
    int Function()? memoryV2AuthorityGeneration,
    DateTime Function()? clock,
    Future<void> Function(Episode episode)? linkEpisode,
    Future<void> Function(int episodeId)? removeEpisodeLinks,
    Future<void> Function(Episode episode)? projectMilestone,
    List<GovernedMemoryProjectionSink> governedProjectionSinks =
        const <GovernedMemoryProjectionSink>[],
    List<GovernedMemoryProjectionFamilySink> governedProjectionFamilies =
        const <GovernedMemoryProjectionFamilySink>[],
    MemoryWriteFaultInjector? faultInjector,
  }) : _database = database,
       _episodeStoreOverride = episodeStore,
       _accountScopeDigest = accountScopeDigest,
       _memoryV2ModeOverride = memoryV2Mode,
       _memoryV2AuthorityGenerationOverride = memoryV2AuthorityGeneration,
       _clock = clock ?? DateTime.now,
       _linkEpisodeOverride = linkEpisode,
       _removeEpisodeLinksOverride = removeEpisodeLinks,
       _projectMilestoneOverride = projectMilestone,
       _governedProjectionSinks = _indexProjectionSinks(
         governedProjectionSinks,
       ),
       _governedProjectionFamilies = _validatedProjectionFamilies(
         governedProjectionFamilies,
       ),
       _faultInjector = faultInjector {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest)) {
      throw ArgumentError.value(
        accountScopeDigest,
        'accountScopeDigest',
        'must be a lowercase SHA-256 digest',
      );
    }
  }

  static final Object _sourceZoneKey = Object();

  final Database? _database;
  final EpisodeStore? _episodeStoreOverride;
  final String _accountScopeDigest;
  final FeatureRolloutMode Function()? _memoryV2ModeOverride;
  final int Function()? _memoryV2AuthorityGenerationOverride;
  final DateTime Function() _clock;
  final Future<void> Function(Episode episode)? _linkEpisodeOverride;
  final Future<void> Function(int episodeId)? _removeEpisodeLinksOverride;
  final Future<void> Function(Episode episode)? _projectMilestoneOverride;
  final Map<String, GovernedMemoryProjectionSink> _governedProjectionSinks;
  final List<GovernedMemoryProjectionFamilySink> _governedProjectionFamilies;
  final MemoryWriteFaultInjector? _faultInjector;
  Future<void> _mutationTail = Future<void>.value();
  bool _retiring = false;

  Database get _db => _database ?? appServices.find<DBService>().raw;

  EpisodeStore get _episodeStore =>
      _episodeStoreOverride ?? appServices.find<EpisodeStore>();

  FeatureRolloutMode get rolloutMode => _effectiveMode();

  int get rolloutAuthorityGeneration =>
      _memoryV2AuthorityGenerationOverride?.call() ?? 0;

  bool get hasInheritedPersistedChatSourceCapability =>
      Zone.current[_sourceZoneKey] != null;

  bool get governanceEnforced => rolloutMode == FeatureRolloutMode.enforce;

  bool get acceptsWrites => !_retiring && !isClosed;

  /// Reads the actual user record bound to this operation. A caller cannot
  /// manufacture provenance by passing a transcript or copying this result.
  Future<PersistedConversationSource?> currentPersistedUserSource() {
    final scope = _currentSourceScope;
    return _enqueue(() async {
      final resolved = await _resolveSource(
        _db,
        const MemoryWriteSource.currentTurn(),
        scope: scope,
        persistImported: false,
      );
      final message = resolved?.chatMessage;
      if (resolved == null || message == null) return null;
      if (await _verifiedConversationSource(
            _db,
            resolved.ref,
            agentId: resolved.agentId,
          ) ==
          null) {
        return null;
      }
      return PersistedConversationSource(
        reference: resolved.ref,
        agentId: resolved.agentId,
        text: message.content,
        timestamp: message.timestamp,
        turnId: message.turnId,
      );
    });
  }

  Future<bool> conversationSourcesAreLive(
    Iterable<EpisodeSourceRef> sources, {
    required String agentId,
  }) {
    final copy = List<EpisodeSourceRef>.unmodifiable(sources);
    return _enqueue(() async {
      if (copy.isEmpty || copy.length > 8) return false;
      for (final source in copy) {
        if (await _verifiedConversationSource(_db, source, agentId: agentId) ==
            null) {
          return false;
        }
      }
      return true;
    });
  }

  /// Read-only provenance check inside an existing account transaction. This
  /// does not enqueue a second transaction or grant memory-write authority.
  Future<bool> conversationSourcesAreLiveWithinTransaction(
    DatabaseClient transaction,
    Iterable<EpisodeSourceRef> sources, {
    required String agentId,
  }) async {
    if (!acceptsWrites) return false;
    final copy = List<EpisodeSourceRef>.unmodifiable(sources);
    if (copy.isEmpty || copy.length > 8) return false;
    for (final source in copy) {
      if (await _verifiedConversationSource(
            transaction,
            source,
            agentId: agentId,
          ) ==
          null) {
        return false;
      }
    }
    return true;
  }

  /// Bounded evidence window in the same private conversation. Each returned
  /// record is published and hash-bound; system/notification/live rows fail
  /// the same role checks as later source-liveness verification.
  Future<List<PersistedConversationSource>> recentConversationSources({
    required String sessionId,
    required String agentId,
    required DateTime before,
    int limit = 32,
  }) => _enqueue(() async {
    final rows = await MemoryGovernanceStores.chatMessages.find(
      _db,
      finder: Finder(
        filter: Filter.equals('sessionId', sessionId),
        sortOrders: [SortOrder(Field.key, false)],
        limit: limit.clamp(1, 64) * 2,
      ),
    );
    final result = <PersistedConversationSource>[];
    for (final row in rows) {
      final raw = row.value;
      final stamp = DateTime.tryParse(raw['timestamp']?.toString() ?? '');
      final content = raw['content'];
      if (stamp == null || !stamp.isBefore(before) || content is! String) {
        continue;
      }
      final ref = EpisodeSourceRef(
        sourceId: 'chat_message:${row.key}',
        sessionId: sessionId,
        origin: raw['isUserMessage'] == true
            ? EpisodeSourceOrigin.user
            : EpisodeSourceOrigin.agent,
        contentHash: _digest(content),
      );
      final verified = await _verifiedConversationSource(
        _db,
        ref,
        agentId: agentId,
      );
      if (verified != null) result.add(verified);
      if (result.length == limit.clamp(1, 64)) break;
    }
    return List<PersistedConversationSource>.unmodifiable(result.reversed);
  });

  GovernedMemoryProjectionFamilySink? _projectionFamily(String kind) {
    for (final family in _governedProjectionFamilies) {
      if (kind.startsWith(family.projectionKindPrefix) &&
          family.acceptsProjectionKind(kind)) {
        return family;
      }
    }
    return null;
  }

  GovernedMemoryProjectionSink? _projectionSink(String kind) {
    final exact = _governedProjectionSinks[kind];
    if (exact != null) return exact;
    final family = _projectionFamily(kind);
    return family == null ? null : _FamilyProjectionSink(family, kind);
  }

  Future<PersistedConversationSource?> _verifiedConversationSource(
    DatabaseClient client,
    EpisodeSourceRef source, {
    required String agentId,
  }) async {
    final match = RegExp(
      r'^chat_message:([1-9][0-9]*)$',
    ).firstMatch(source.sourceId);
    if (match == null ||
        (source.origin != EpisodeSourceOrigin.user &&
            source.origin != EpisodeSourceOrigin.agent)) {
      return null;
    }
    final id = int.tryParse(match.group(1)!);
    if (id == null) return null;
    final raw = await MemoryGovernanceStores.chatMessages
        .record(id)
        .get(client);
    final text = raw?['content'];
    final timestamp = DateTime.tryParse(raw?['timestamp']?.toString() ?? '');
    if (raw == null ||
        raw['sessionId'] != source.sessionId ||
        text is! String ||
        text.isEmpty ||
        text.runes.length > 65536 ||
        timestamp == null ||
        _digest(text) != source.contentHash ||
        (raw['deliveryStatus'] != null &&
            raw['deliveryStatus'] != 'published')) {
      return null;
    }
    final origin = raw['turnOrigin'];
    if (source.origin == EpisodeSourceOrigin.user) {
      if (raw['senderId'] != 'user' ||
          raw['receiverId'] != agentId ||
          raw['isUserMessage'] != true ||
          !ChatMessageTurnOrigins.humanAuthored.contains(origin)) {
        return null;
      }
    } else if (raw['senderId'] != agentId ||
        raw['receiverId'] != 'user' ||
        raw['isUserMessage'] != false ||
        !ChatMessageTurnOrigins.humanAuthored.contains(origin)) {
      return null;
    }
    return PersistedConversationSource(
      reference: source,
      agentId: agentId,
      text: text,
      timestamp: timestamp,
      turnId: raw['turnId'] is String ? raw['turnId']! as String : null,
    );
  }

  Future<bool> _familyProjectionSourcesLive(
    DatabaseClient client,
    GovernedMemoryProjectionRecord projection,
  ) async {
    final family = _projectionFamily(projection.kind);
    if (family == null) return true;
    final raw = await MemoryGovernanceStores.episodes
        .record(projection.episodeId)
        .get(client);
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(projection.episodeId)
        .get(client);
    if (raw == null || governance?['projectionSourceInvalidated'] == true) {
      return false;
    }
    final episode = Episode.fromJson(raw)..id = projection.episodeId;
    final sources = episode.sourceRefs;
    if (sources.isEmpty ||
        sources.length > 8 ||
        sources.first.origin != EpisodeSourceOrigin.user) {
      return false;
    }
    final declared = family.supportingSources(
      GovernedMemoryProjectionDraft(
        kind: projection.kind,
        payload: projection.payload,
      ),
    );
    if (sources.length != declared.length + 1) return false;
    for (var index = 0; index < declared.length; index++) {
      if (jsonEncode(sources[index + 1].toJson()) !=
          jsonEncode(declared[index].toJson())) {
        return false;
      }
    }
    final primary = await _verifiedConversationSource(
      client,
      sources.first,
      agentId: episode.agentId,
    );
    if (primary == null) return false;
    for (final source in sources) {
      final verified = await _verifiedConversationSource(
        client,
        source,
        agentId: episode.agentId,
      );
      if (source.sessionId != sources.first.sessionId ||
          verified == null ||
          verified.timestamp.isAfter(primary.timestamp)) {
        return false;
      }
    }
    return true;
  }

  /// Binds exactly one already-persisted human ChatMessage to [operation].
  ///
  /// The capability is private to this coordinator instance and becomes
  /// unusable as soon as the awaited operation returns, including from late
  /// unawaited children that inherited the Zone.
  Future<T> runWithPersistedChatSource<T>({
    required int messageRecordId,
    required String sessionId,
    required String agentId,
    required Future<T> Function() operation,
  }) async {
    if (_retiring || isClosed) {
      throw StateError('memory_write_coordinator_retired');
    }
    if (messageRecordId < 1) {
      throw ArgumentError.value(messageRecordId, 'messageRecordId');
    }
    _requireBounded(sessionId, 'sessionId', maxLength: 256);
    _requireBounded(agentId, 'agentId', maxLength: 256);
    final scope = _PersistedChatSourceScope(
      owner: this,
      messageRecordId: messageRecordId,
      sessionId: sessionId,
      agentId: agentId,
    );
    return runZoned<Future<T>>(() async {
      try {
        return await operation();
      } finally {
        scope.active = false;
      }
    }, zoneValues: <Object, Object>{_sourceZoneKey: scope});
  }

  Future<MemoryWriteResult> writeEpisode(
    Episode proposal, {
    MemoryWriteSource source = const MemoryWriteSource.currentTurn(),
    MemoryWriteAuthority authority = MemoryWriteAuthority.automaticConversation,
  }) => write(
    MemoryWriteDraft.fromEpisode(proposal),
    source: source,
    authority: authority,
  );

  /// Returns the source rejection that must also apply while Memory v2 is
  /// rolled back. No inherited Zone is a legitimate trusted-host write, but an
  /// inherited expired or foreign capability fails closed so a late child from
  /// another turn/account cannot fall through to a compatibility mirror.
  Future<String?> currentSourceStructuredPersistenceRejection() {
    final inheritedScope = Zone.current[_sourceZoneKey];
    return _enqueue(() async {
      if (inheritedScope == null) return null;
      if (inheritedScope is! _PersistedChatSourceScope ||
          !inheritedScope.isCurrentFor(this)) {
        return 'trusted_source_missing_or_invalid';
      }
      final resolved = await _db.transaction(
        (transaction) => _resolveSource(
          transaction,
          const MemoryWriteSource.currentTurn(),
          scope: inheritedScope,
          persistImported: false,
        ),
      );
      final content = resolved?.chatMessage?.content;
      if (content == null) return 'trusted_source_missing_or_invalid';
      return _isExplicitNoSaveRequest(content, structuredProposal: true)
          ? 'explicit_no_save_request'
          : null;
    });
  }

  Future<MemoryWriteResult> write(
    MemoryWriteDraft draft, {
    MemoryWriteSource source = const MemoryWriteSource.currentTurn(),
    MemoryWriteAuthority authority = MemoryWriteAuthority.automaticConversation,
  }) {
    final admittedMode = _effectiveMode();
    final admittedScope = _currentSourceScope;
    return _enqueue(
      () => _write(
        draft,
        source: source,
        authority: authority,
        mode: admittedMode,
        sourceScope: admittedScope,
      ),
    );
  }

  /// Applies one owner-reviewed lifecycle mutation as an append-only revision.
  ///
  /// Review commands share the account writer queue with ordinary memory
  /// writes. The expected head and revision are checked again inside the
  /// transaction so stale UI snapshots cannot fork a lineage.
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) {
    final admittedMode = _effectiveMode();
    return _enqueue(() => _review(command, mode: admittedMode));
  }

  /// Replays accepted-current structured projections into freshly mounted
  /// account read models. Durable receipts prevent ordinary duplicate work,
  /// but a new in-memory sink must still be hydrated on every mount.
  Future<int> rehydrateGovernedProjections({String? familyPrefix}) {
    return _enqueue(() async {
      if (!governanceEnforced) return 0;
      if (familyPrefix != null && familyPrefix != 'conversation.fact.') {
        throw ArgumentError.value(familyPrefix, 'familyPrefix');
      }
      var restored = 0;
      final kinds = <String>{
        if (familyPrefix == null) ..._governedProjectionSinks.keys,
      };
      if (_governedProjectionFamilies.isNotEmpty) {
        final heads = await MemoryGovernanceStores.governedProjectionHeads.find(
          _db,
        );
        for (final head in heads) {
          if (_projectionFamily(head.key) != null) kinds.add(head.key);
        }
      }
      for (final kind in kinds) {
        final rawHead = await MemoryGovernanceStores.governedProjectionHeads
            .record(kind)
            .get(_db);
        if (rawHead == null) continue;
        try {
          final head = GovernedMemoryProjectionHeadRecord.fromStored(
            rawHead,
            expectedKind: kind,
            expectedAccountScopeDigest: _accountScopeDigest,
          );
          if (await _materializeGovernedProjectionKind(kind, force: true) &&
              head.activeEpisodeId != null) {
            restored++;
          }
        } on Object {
          // A malformed head fails closed and is never replaced by a legacy
          // mirror during this account mount.
        }
      }
      return restored;
    });
  }

  Future<bool> hasGovernedProjectionHistory(String kind) =>
      _enqueue(() => _hasGovernedProjectionHistory(kind));

  Future<bool> _hasGovernedProjectionHistory(String kind) async {
    GovernedMemoryProjectionDraft(
      kind: kind,
      payload: const <String, Object?>{},
    );
    return await MemoryGovernanceStores.governedProjectionHeads
            .record(kind)
            .get(_db) !=
        null;
  }

  Future<String?> activeGovernedProjectionDigest(String kind) =>
      _enqueue(() async {
        final rawHead = await MemoryGovernanceStores.governedProjectionHeads
            .record(kind)
            .get(_db);
        if (rawHead == null) return null;
        try {
          final head = GovernedMemoryProjectionHeadRecord.fromStored(
            rawHead,
            expectedKind: kind,
            expectedAccountScopeDigest: _accountScopeDigest,
          );
          final activeEpisodeId = head.activeEpisodeId;
          if (activeEpisodeId == null) return null;
          return (await _boundGovernedProjectionRecord(
            _db,
            episodeId: activeEpisodeId,
            kind: kind,
            expectedReviewState: EpisodeReviewState.accepted,
            requireCurrent: true,
          )).digest;
        } on Object {
          return null;
        }
      });

  /// Persists only the commit digest produced while Memory v2 is rolled back.
  /// The marker distinguishes an intentional rollback write from an arbitrary
  /// stale compatibility file without copying profile PII into a v2 sidecar.
  Future<void> recordLegacyProjectionOverride(
    GovernedMemoryProjectionDraft projection, {
    required FeatureRolloutMode admittedMode,
  }) {
    if (admittedMode == FeatureRolloutMode.enforce) {
      return Future<void>.error(
        StateError('legacy_projection_override_requires_rollback'),
      );
    }
    return _enqueue(
      () => MemoryGovernanceStores.governedProjectionRollbackOverrides
          .record(projection.kind)
          .put(_db, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'kind': projection.kind,
            'digest': projection.digest,
            'rolloutMode': admittedMode.name,
            'writtenAt': _clock().toUtc().millisecondsSinceEpoch,
          }),
    );
  }

  Future<void> clearLegacyProjectionOverride(String kind) => _enqueue(() async {
    GovernedMemoryProjectionDraft(
      kind: kind,
      payload: const <String, Object?>{},
    );
    await MemoryGovernanceStores.governedProjectionRollbackOverrides
        .record(kind)
        .delete(_db);
  });

  /// Replaces a rollback commit marker with a payload-free fail-closed tombstone.
  ///
  /// This is used when the compatibility mirror was written but restoring the
  /// accepted governed mirror may still fail. A revoked marker can authorize
  /// neither rollback adoption nor ordinary legacy import after restart.
  Future<void> revokeLegacyProjectionOverride(
    GovernedMemoryProjectionDraft projection,
  ) => _enqueue(
    () => MemoryGovernanceStores.governedProjectionRollbackOverrides
        .record(projection.kind)
        .put(_db, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountScopeDigest,
          'kind': projection.kind,
          'digest': projection.digest,
          'rolloutMode': 'revoked',
          'writtenAt': _clock().toUtc().millisecondsSinceEpoch,
        }),
  );

  Future<bool> isLegacyProjectionImportBlocked(String kind) => _enqueue(
    () async => _isRevokedLegacyProjectionOverride(
      await MemoryGovernanceStores.governedProjectionRollbackOverrides
          .record(kind)
          .get(_db),
      expectedKind: kind,
      expectedAccountScopeDigest: _accountScopeDigest,
    ),
  );

  Future<String?> legacyProjectionOverrideDigest(String kind) =>
      _enqueue(() async {
        if (!governanceEnforced) return null;
        final raw = await MemoryGovernanceStores
            .governedProjectionRollbackOverrides
            .record(kind)
            .get(_db);
        if (raw == null) return null;
        try {
          return _decodeLegacyProjectionOverrideDigest(
            raw,
            expectedKind: kind,
            expectedAccountScopeDigest: _accountScopeDigest,
          );
        } on Object {
          return null;
        }
      });

  Future<bool> reconcileGovernedProjection(String kind, {bool force = false}) =>
      _enqueue(() => _materializeGovernedProjectionKind(kind, force: force));

  Future<GovernedMemoryProjectionRecord?> latestGovernedProjectionBase(
    String kind,
  ) => _enqueue(() async {
    final rawHead = await MemoryGovernanceStores.governedProjectionHeads
        .record(kind)
        .get(_db);
    if (rawHead == null) return null;
    final head = GovernedMemoryProjectionHeadRecord.fromStored(
      rawHead,
      expectedKind: kind,
      expectedAccountScopeDigest: _accountScopeDigest,
    );
    await _validateGovernedProjectionHeadBinding(_db, head);
    final candidateEpisodeId = head.reviewState == EpisodeReviewState.pending
        ? head.headEpisodeId
        : head.activeEpisodeId;
    if (candidateEpisodeId == null) return null;
    return _boundGovernedProjectionRecord(
      _db,
      episodeId: candidateEpisodeId,
      kind: kind,
      expectedReviewState: candidateEpisodeId == head.headEpisodeId
          ? head.reviewState
          : EpisodeReviewState.accepted,
      requireCurrent: candidateEpisodeId == head.activeEpisodeId,
    );
  });

  Future<MemoryGovernanceResult> _review(
    MemoryGovernanceCommand command, {
    required FeatureRolloutMode mode,
  }) async {
    if (mode != FeatureRolloutMode.enforce) {
      return MemoryGovernanceResult.failure(
        status: MemoryGovernanceStatus.invalid,
        action: command.action,
        previousEpisodeId: command.targetEpisodeId,
        reason: 'memory_v2_not_enforced',
      );
    }

    MemoryGovernanceResult? failure;
    _CommittedGovernanceMutation? committed;
    await _db.transaction((transaction) async {
      final targetRaw = await MemoryGovernanceStores.episodes
          .record(command.targetEpisodeId)
          .get(transaction);
      if (targetRaw == null) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.notFound,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_episode_not_found',
        );
        return;
      }

      late final Episode target;
      try {
        target = Episode.fromJson(targetRaw)..id = command.targetEpisodeId;
      } on Object {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_episode_invalid',
        );
        return;
      }
      final targetGovernance = await MemoryGovernanceStores.episodeGovernance
          .record(command.targetEpisodeId)
          .get(transaction);
      if (!_validReviewGovernance(target, targetGovernance)) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_governance_invalid',
        );
        return;
      }
      final governedProjectionKind =
          targetGovernance?['governedProjectionKind'] as String?;
      final governedProjectionRaw = await MemoryGovernanceStores
          .governedProjections
          .record(command.targetEpisodeId)
          .get(transaction);
      GovernedMemoryProjectionRecord? governedProjection;
      if (governedProjectionKind == null) {
        if (governedProjectionRaw != null) {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_projection_metadata_invalid',
          );
          return;
        }
      } else {
        try {
          governedProjection = GovernedMemoryProjectionRecord.fromStored(
            governedProjectionRaw,
            expectedEpisodeId: command.targetEpisodeId,
            expectedAccountScopeDigest: _accountScopeDigest,
            expectedKind: governedProjectionKind,
          );
          if (!governedProjection.matchesClaimValueFingerprint(
            targetGovernance?['claimValueFingerprint'],
          )) {
            throw const FormatException();
          }
        } on FormatException {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_projection_metadata_invalid',
          );
          return;
        }
      }

      final lineageId = await _reviewLineageId(
        transaction,
        target,
        targetGovernance,
      );
      if (lineageId == null) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_revision_chain_invalid',
        );
        return;
      }
      final head = await MemoryGovernanceStores.revisionHeads
          .record(lineageId)
          .get(transaction);
      final bootstrapsHead =
          head == null &&
          await _isReviewBootstrapHead(transaction, target, targetGovernance);
      final storedHeadId = (head?['headEpisodeId'] as num?)?.toInt();
      final storedRevision = (head?['revision'] as num?)?.toInt();
      final validHead = head == null
          ? bootstrapsHead
          : head['schemaVersion'] == 1 &&
                head['accountScopeDigest'] == _accountScopeDigest &&
                head['lineageId'] == lineageId &&
                storedHeadId != null &&
                storedRevision != null;
      if (!validHead) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_revision_head_invalid',
        );
        return;
      }
      final effectiveHeadId = storedHeadId ?? target.id!;
      final effectiveRevision = storedRevision ?? target.revision;
      GovernedMemoryProjectionHeadRecord? projectionHead;
      if (governedProjectionKind != null) {
        try {
          projectionHead = GovernedMemoryProjectionHeadRecord.fromStored(
            await MemoryGovernanceStores.governedProjectionHeads
                .record(governedProjectionKind)
                .get(transaction),
            expectedKind: governedProjectionKind,
            expectedAccountScopeDigest: _accountScopeDigest,
          );
          await _validateGovernedProjectionHeadBinding(
            transaction,
            projectionHead,
          );
          if (projectionHead.headEpisodeId != effectiveHeadId ||
              projectionHead.revision != effectiveRevision ||
              head?['reviewState'] != projectionHead.reviewState.name) {
            throw const FormatException();
          }
        } on Object {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'governed_projection_head_invalid',
          );
          return;
        }
      }
      final targetsReviewHead =
          command.targetEpisodeId == command.expectedHeadEpisodeId &&
          command.expectedHeadEpisodeId == effectiveHeadId &&
          command.expectedRevision == effectiveRevision &&
          target.revision == effectiveRevision;
      final targetsDetachedActiveProjection =
          !targetsReviewHead &&
          governedProjectionKind != null &&
          projectionHead?.activeEpisodeId == target.id &&
          targetGovernance?['current'] == true &&
          target.reviewState == EpisodeReviewState.accepted &&
          command.action == MemoryGovernanceAction.delete &&
          command.expectedHeadEpisodeId == effectiveHeadId &&
          command.expectedRevision == effectiveRevision;
      if (!targetsReviewHead && !targetsDetachedActiveProjection) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.conflict,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'stale_memory_revision',
        );
        return;
      }

      if (governedProjectionKind != null &&
          command.action == MemoryGovernanceAction.edit) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'governed_projection_edit_requires_typed_update',
        );
        return;
      }

      final invalidTransition = _invalidReviewTransition(command, target);
      if (invalidTransition != null) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: invalidTransition,
        );
        return;
      }
      if (governedProjection != null &&
          (command.action == MemoryGovernanceAction.accept ||
              command.action == MemoryGovernanceAction.restore) &&
          !await _familyProjectionSourcesLive(
            transaction,
            governedProjection,
          )) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'conversation_projection_source_invalid',
        );
        return;
      }
      var reviewPredecessor = target;
      Map<String, Object?>? reviewPredecessorGovernance = targetGovernance;
      if (targetsDetachedActiveProjection) {
        final predecessorRaw = await MemoryGovernanceStores.episodes
            .record(effectiveHeadId)
            .get(transaction);
        final predecessorGovernance = await MemoryGovernanceStores
            .episodeGovernance
            .record(effectiveHeadId)
            .get(transaction);
        try {
          reviewPredecessor = Episode.fromJson(predecessorRaw!)
            ..id = effectiveHeadId;
          if (reviewPredecessor.revision != effectiveRevision ||
              predecessorGovernance?['accountScopeDigest'] !=
                  _accountScopeDigest ||
              predecessorGovernance?['lineageId'] != lineageId ||
              predecessorGovernance?['governedProjectionKind'] !=
                  governedProjectionKind) {
            throw const FormatException();
          }
          reviewPredecessorGovernance = predecessorGovernance;
        } on Object {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_revision_head_invalid',
          );
          return;
        }
      }
      final claimSlotFingerprint =
          targetGovernance?['claimSlotFingerprint'] as String?;
      if (command.action == MemoryGovernanceAction.edit &&
          claimSlotFingerprint != null) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'claim_semantic_edit_requires_structured_claim',
        );
        return;
      }

      final editedWhat = command.edit?.what.trim();
      if (command.action == MemoryGovernanceAction.edit &&
          (editedWhat == null ||
              editedWhat.isEmpty ||
              editedWhat.runes.length > 4096)) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_edit_text_invalid',
        );
        return;
      }
      if (command.action == MemoryGovernanceAction.edit &&
          editedWhat == target.what) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'memory_edit_has_no_changes',
        );
        return;
      }

      final now = _clock().toUtc();
      DateTime? lineageExpiresAt = target.expiresAt;
      final storedLineageExpiresAt = targetGovernance?['lineageExpiresAt'];
      if (storedLineageExpiresAt != null) {
        if (storedLineageExpiresAt is! int) {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_retention_metadata_invalid',
          );
          return;
        }
        try {
          lineageExpiresAt = DateTime.fromMillisecondsSinceEpoch(
            storedLineageExpiresAt,
            isUtc: true,
          );
        } on RangeError {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_retention_metadata_invalid',
          );
          return;
        }
        final payloadExpiry = target.expiresAt;
        if (payloadExpiry != null &&
            payloadExpiry.toUtc().millisecondsSinceEpoch !=
                storedLineageExpiresAt) {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'memory_retention_metadata_invalid',
          );
          return;
        }
      }
      if ((command.action == MemoryGovernanceAction.accept ||
              command.action == MemoryGovernanceAction.edit ||
              command.action == MemoryGovernanceAction.restore) &&
          lineageExpiresAt != null &&
          !lineageExpiresAt.isAfter(now)) {
        failure = MemoryGovernanceResult.failure(
          status: MemoryGovernanceStatus.invalid,
          action: command.action,
          previousEpisodeId: command.targetEpisodeId,
          reason: 'expired_memory_cannot_activate',
        );
        return;
      }
      final reviewState = _reviewStateAfter(command.action, target.reviewState);
      final sourceType = target.sourceType == EpisodeSourceType.legacyUnknown
          ? EpisodeSourceType.runtimeUnknown
          : target.sourceType;
      String? claimValueFingerprint =
          targetGovernance?['claimValueFingerprint'] as String?;
      Map<String, Object?>? claimHead;
      if (claimSlotFingerprint != null) {
        claimHead = await MemoryGovernanceStores.claimHeads
            .record(claimSlotFingerprint)
            .get(transaction);
        if (claimValueFingerprint == null &&
            claimHead?['accountScopeDigest'] == _accountScopeDigest &&
            claimHead?['episodeId'] == target.id) {
          claimValueFingerprint = claimHead?['valueFingerprint'] as String?;
        }
        if (projectionHead != null) {
          final activeClaimEpisodeId =
              claimHead?['accountScopeDigest'] == _accountScopeDigest &&
                  claimHead?['slotFingerprint'] == claimSlotFingerprint
              ? (claimHead?['episodeId'] as num?)?.toInt()
              : null;
          if (activeClaimEpisodeId != projectionHead.activeEpisodeId) {
            failure = MemoryGovernanceResult.failure(
              status: MemoryGovernanceStatus.invalid,
              action: command.action,
              previousEpisodeId: command.targetEpisodeId,
              reason: 'governed_projection_head_invalid',
            );
            return;
          }
          if (activeClaimEpisodeId != null) {
            final activeGovernance = await MemoryGovernanceStores
                .episodeGovernance
                .record(activeClaimEpisodeId)
                .get(transaction);
            if (activeGovernance?['accountScopeDigest'] !=
                    _accountScopeDigest ||
                activeGovernance?['episodeId'] != activeClaimEpisodeId ||
                activeGovernance?['current'] != true ||
                activeGovernance?['reviewState'] !=
                    EpisodeReviewState.accepted.name ||
                activeGovernance?['governedProjectionKind'] !=
                    governedProjectionKind) {
              failure = MemoryGovernanceResult.failure(
                status: MemoryGovernanceStatus.invalid,
                action: command.action,
                previousEpisodeId: command.targetEpisodeId,
                reason: 'governed_projection_head_invalid',
              );
              return;
            }
          }
        }
        if (reviewState == EpisodeReviewState.accepted &&
            claimValueFingerprint == null) {
          failure = MemoryGovernanceResult.failure(
            status: MemoryGovernanceStatus.invalid,
            action: command.action,
            previousEpisodeId: command.targetEpisodeId,
            reason: 'claim_accept_requires_structured_claim',
          );
          return;
        }
      }
      final episode = Episode(
        when: target.when,
        what: editedWhat ?? target.what,
        entities: target.entities,
        emotion: target.emotion,
        salience: target.salience,
        agentId: target.agentId,
        kind: target.kind,
        sourceRefs: target.sourceRefs,
        sourceType: sourceType,
        confidence: target.confidence,
        reviewState: reviewState,
        revision: reviewPredecessor.revision + 1,
        supersedesId: reviewPredecessor.id,
        contradictionIds: target.contradictionIds,
        createdAt: now,
        updatedAt: now,
        expiresAt: lineageExpiresAt?.isAfter(now) == true
            ? lineageExpiresAt
            : null,
        retentionClass: target.retentionClass,
      );
      final newId = await MemoryGovernanceStores.episodes.add(
        transaction,
        episode.toJson(),
      );
      episode.id = newId;
      if (governedProjection != null) {
        await MemoryGovernanceStores.governedProjections
            .record(newId)
            .put(
              transaction,
              GovernedMemoryProjectionRecord(
                episodeId: newId,
                accountScopeDigest: _accountScopeDigest,
                draft: GovernedMemoryProjectionDraft(
                  kind: governedProjection.kind,
                  payload: governedProjection.payload,
                ),
              ).toStored(),
            );
      }

      final originalExactFingerprint =
          targetGovernance?['exactFingerprint'] as String?;
      final originalSemanticFingerprint =
          targetGovernance?['semanticFingerprint'] as String?;
      final fingerprintDraft = MemoryWriteDraft.fromEpisode(episode);
      final sourceRef = episode.sourceRefs.isEmpty
          ? null
          : episode.sourceRefs.first;
      final exactFingerprint =
          command.action == MemoryGovernanceAction.edit ||
              originalExactFingerprint == null
          ? sourceRef == null
                ? _digest(
                    jsonEncode(<String, Object?>{
                      'domain': 'memory-governance-exact-v1',
                      'accountScopeDigest': _accountScopeDigest,
                      'lineageId': lineageId,
                      'what': episode.what,
                    }),
                  )
                : _exactFingerprint(fingerprintDraft, sourceRef, episode.when)
          : originalExactFingerprint;
      final semanticFingerprint =
          command.action == MemoryGovernanceAction.edit ||
              originalSemanticFingerprint == null
          ? _semanticFingerprint(fingerprintDraft, episode.when)
          : originalSemanticFingerprint;
      if (command.action == MemoryGovernanceAction.edit) {
        for (final entry in <(StoreRef<String, Map<String, Object?>>, String?)>[
          (MemoryGovernanceStores.exactDedup, originalExactFingerprint),
          (MemoryGovernanceStores.semanticDedup, originalSemanticFingerprint),
        ]) {
          final oldFingerprint = entry.$2;
          if (oldFingerprint == null) continue;
          final oldIndex = await entry.$1
              .record(oldFingerprint)
              .get(transaction);
          if (oldIndex?['accountScopeDigest'] == _accountScopeDigest &&
              oldIndex?['episodeId'] == target.id) {
            await entry.$1.record(oldFingerprint).delete(transaction);
          }
        }
      }
      final priorGovernance =
          reviewPredecessorGovernance ??
          <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'episodeId': reviewPredecessor.id,
            'reviewState': reviewPredecessor.reviewState.name,
            'exactFingerprint': originalExactFingerprint,
            'semanticFingerprint': originalSemanticFingerprint,
            'claimSlotFingerprint': claimSlotFingerprint,
            'governedProjectionKind': governedProjectionKind,
            'lineageExpiresAt': lineageExpiresAt?.millisecondsSinceEpoch,
            'projectionLinkComplete': false,
            'projectionMilestoneComplete': false,
            'projectionGovernedComplete': false,
            'writtenAt': reviewPredecessor.createdAt.millisecondsSinceEpoch,
          };
      await MemoryGovernanceStores.episodeGovernance
          .record(reviewPredecessor.id!)
          .put(transaction, <String, Object?>{
            ...priorGovernance,
            'current': false,
            'lineageId': lineageId,
            'supersededByEpisodeId': newId,
            'projectionUnlinkComplete': false,
            'updatedAt': now.millisecondsSinceEpoch,
          });
      if (targetsDetachedActiveProjection) {
        await MemoryGovernanceStores.episodeGovernance
            .record(target.id!)
            .put(transaction, <String, Object?>{
              ...targetGovernance!,
              'current': false,
              'projectionGovernedUnlinkComplete': false,
              'updatedAt': now.millisecondsSinceEpoch,
            });
      }
      await MemoryGovernanceStores.episodeGovernance
          .record(newId)
          .put(transaction, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'episodeId': newId,
            'current': reviewState == EpisodeReviewState.accepted,
            'reviewState': reviewState.name,
            'lineageId': lineageId,
            'supersededByEpisodeId': null,
            'reviewAction': command.action.name,
            'exactFingerprint': exactFingerprint,
            'semanticFingerprint': semanticFingerprint,
            'claimSlotFingerprint': claimSlotFingerprint,
            'claimValueFingerprint': claimValueFingerprint,
            'governedProjectionKind': governedProjectionKind,
            'lineageExpiresAt': lineageExpiresAt?.millisecondsSinceEpoch,
            'projectionLinkComplete': false,
            'projectionMilestoneComplete': false,
            'projectionGovernedComplete': false,
            'projectionUnlinkComplete': false,
            'writtenAt': now.millisecondsSinceEpoch,
            'updatedAt': now.millisecondsSinceEpoch,
          });
      await MemoryGovernanceStores.revisionHeads
          .record(lineageId)
          .put(transaction, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'lineageId': lineageId,
            'headEpisodeId': newId,
            'revision': episode.revision,
            'reviewState': reviewState.name,
            'updatedAt': now.millisecondsSinceEpoch,
          });
      if (projectionHead != null) {
        var activeEpisodeId = projectionHead.activeEpisodeId;
        if (reviewState == EpisodeReviewState.accepted) {
          activeEpisodeId = newId;
        } else if (activeEpisodeId == target.id) {
          activeEpisodeId = null;
        }
        final materializationComplete =
            projectionHead.materializationComplete &&
            projectionHead.activeEpisodeId == activeEpisodeId;
        await MemoryGovernanceStores.governedProjectionHeads
            .record(projectionHead.kind)
            .put(
              transaction,
              GovernedMemoryProjectionHeadRecord(
                kind: projectionHead.kind,
                headEpisodeId: newId,
                activeEpisodeId: activeEpisodeId,
                revision: episode.revision,
                reviewState: reviewState,
                materializationComplete: materializationComplete,
                materializedActiveEpisodeId: materializationComplete
                    ? activeEpisodeId
                    : null,
              ).toStored(
                accountScopeDigest: _accountScopeDigest,
                updatedAt: now,
              ),
            );
      }
      if (governedProjection == null) {
        await _episodeStore.updateRecallIndexInTransaction(
          transaction,
          episode,
          removeEpisodeId: target.id,
          now: now,
        );
      } else {
        await MemoryGovernanceStores.episodeRecallIndex
            .record(target.id!)
            .delete(transaction);
        await MemoryGovernanceStores.episodeRecallIndex
            .record(newId)
            .delete(transaction);
      }

      if (claimSlotFingerprint != null) {
        final claimRecord = MemoryGovernanceStores.claimHeads.record(
          claimSlotFingerprint,
        );
        if (reviewState == EpisodeReviewState.accepted) {
          final displacedEpisodeId = (claimHead?['episodeId'] as num?)?.toInt();
          if (governedProjection != null &&
              displacedEpisodeId != null &&
              displacedEpisodeId != target.id) {
            final displacedRecord = MemoryGovernanceStores.episodeGovernance
                .record(displacedEpisodeId);
            final displacedGovernance = await displacedRecord.get(transaction);
            if (displacedGovernance?['accountScopeDigest'] ==
                    _accountScopeDigest &&
                displacedGovernance?['current'] == true &&
                displacedGovernance?['governedProjectionKind'] ==
                    governedProjectionKind) {
              await displacedRecord.put(transaction, <String, Object?>{
                ...displacedGovernance!,
                'current': false,
                'supersededByEpisodeId': newId,
                'projectionUnlinkComplete': false,
                'updatedAt': now.millisecondsSinceEpoch,
              });
              await MemoryGovernanceStores.episodeRecallIndex
                  .record(displacedEpisodeId)
                  .delete(transaction);
            }
          }
          await claimRecord.put(transaction, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'episodeId': newId,
            'revision': episode.revision,
            'slotFingerprint': claimSlotFingerprint,
            'valueFingerprint': claimValueFingerprint,
            'updatedAt': now.millisecondsSinceEpoch,
          });
        } else if (claimHead?['accountScopeDigest'] == _accountScopeDigest &&
            claimHead?['episodeId'] == target.id) {
          await claimRecord.delete(transaction);
        }
      }
      final exactRow = _dedupRow(
        fingerprint: exactFingerprint,
        episode: episode,
        now: now,
      );
      await MemoryGovernanceStores.exactDedup
          .record(exactFingerprint)
          .put(transaction, exactRow);
      await MemoryGovernanceStores.semanticDedup
          .record(semanticFingerprint)
          .put(
            transaction,
            _dedupRow(
              fingerprint: semanticFingerprint,
              episode: episode,
              now: now,
            ),
          );
      await MemoryGovernanceStores.audit.add(transaction, <String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': _accountScopeDigest,
        'mode': mode.name,
        'eventType': 'governance_review',
        'action': command.action.name,
        'disposition': MemoryGovernanceStatus.applied.name,
        'targetEpisodeId': target.id,
        'episodeId': newId,
        'lineageId': lineageId,
        'expectedHeadEpisodeId': command.expectedHeadEpisodeId,
        'expectedRevision': command.expectedRevision,
        'fromReviewState': target.reviewState.name,
        'reviewState': reviewState.name,
        'changedFields': command.action == MemoryGovernanceAction.edit
            ? <String>['what']
            : <String>['reviewState'],
        'exactFingerprint': exactFingerprint,
        'semanticFingerprint': semanticFingerprint,
        'created': true,
        'writtenAt': now.millisecondsSinceEpoch,
      });
      await Future<void>.sync(
        () => _faultInjector?.call(
          MemoryWriteFaultPoint.beforeCommit,
          exactFingerprint,
        ),
      );
      committed = _CommittedGovernanceMutation(
        action: command.action,
        previousEpisodeId: target.id!,
        episode: episode,
        exactFingerprint: exactFingerprint,
        governedProjectionKind: governedProjectionKind,
      );
    });

    if (failure != null) return failure!;
    final mutation = committed!;
    _episodeStore.invalidateRecallCache();
    final unlinked = await _unlinkSupersededProjection(
      mutation.previousEpisodeId,
    );
    final governedProjectionKind = mutation.governedProjectionKind;
    if (governedProjectionKind != null) {
      var materialized = await _materializeGovernedProjectionKind(
        governedProjectionKind,
      );
      if (!materialized) {
        materialized = await _materializeGovernedProjectionKind(
          governedProjectionKind,
        );
      }
      return MemoryGovernanceResult(
        status: MemoryGovernanceStatus.applied,
        action: mutation.action,
        previousEpisodeId: mutation.previousEpisodeId,
        episode: mutation.episode,
        projected: unlinked && materialized,
      );
    }
    var acceptedProjectionComplete = false;
    if (mutation.episode.reviewState == EpisodeReviewState.accepted) {
      acceptedProjectionComplete = await _projectIfNeeded(
        mutation.episode,
        mutation.exactFingerprint,
      );
    }
    return MemoryGovernanceResult(
      status: MemoryGovernanceStatus.applied,
      action: mutation.action,
      previousEpisodeId: mutation.previousEpisodeId,
      episode: mutation.episode,
      projected:
          unlinked &&
          (mutation.episode.reviewState != EpisodeReviewState.accepted ||
              acceptedProjectionComplete),
    );
  }

  bool _validReviewGovernance(
    Episode episode,
    Map<String, Object?>? governance,
  ) {
    if (governance == null) {
      return episode.sourceType == EpisodeSourceType.legacyUnknown;
    }
    return governance['schemaVersion'] == 1 &&
        governance['accountScopeDigest'] == _accountScopeDigest &&
        governance['episodeId'] == episode.id &&
        governance['reviewState'] == episode.reviewState.name;
  }

  Future<int?> _reviewLineageId(
    DatabaseClient transaction,
    Episode episode,
    Map<String, Object?>? governance,
  ) async {
    final stored = (governance?['lineageId'] as num?)?.toInt();
    if (stored != null) return stored > 0 ? stored : null;
    var current = episode;
    final visited = <int>{episode.id!};
    for (var depth = 0; depth < 64; depth++) {
      final priorId = current.supersedesId;
      if (priorId == null) return current.id;
      if (!visited.add(priorId)) return null;
      final raw = await MemoryGovernanceStores.episodes
          .record(priorId)
          .get(transaction);
      if (raw == null) return null;
      try {
        current = Episode.fromJson(raw)..id = priorId;
      } on Object {
        return null;
      }
    }
    return null;
  }

  Future<bool> _isReviewBootstrapHead(
    DatabaseClient transaction,
    Episode episode,
    Map<String, Object?>? governance,
  ) async {
    if (governance == null) {
      return episode.sourceType == EpisodeSourceType.legacyUnknown &&
          episode.supersedesId == null;
    }
    if (episode.reviewState == EpisodeReviewState.accepted) {
      return governance['current'] == true;
    }
    if (episode.reviewState != EpisodeReviewState.pending) return false;
    for (final entry in <(StoreRef<String, Map<String, Object?>>, String)>[
      (MemoryGovernanceStores.exactDedup, 'exactFingerprint'),
      (MemoryGovernanceStores.semanticDedup, 'semanticFingerprint'),
    ]) {
      final fingerprint = governance[entry.$2];
      if (fingerprint is! String) continue;
      final index = await entry.$1.record(fingerprint).get(transaction);
      if (index?['accountScopeDigest'] == _accountScopeDigest &&
          index?['episodeId'] == episode.id) {
        return true;
      }
    }
    return false;
  }

  String? _invalidReviewTransition(
    MemoryGovernanceCommand command,
    Episode target,
  ) => switch (command.action) {
    MemoryGovernanceAction.accept =>
      target.reviewState == EpisodeReviewState.pending ||
              (target.reviewState == EpisodeReviewState.accepted &&
                  target.sourceType == EpisodeSourceType.legacyUnknown)
          ? null
          : 'memory_accept_requires_pending',
    MemoryGovernanceAction.edit =>
      target.reviewState == EpisodeReviewState.pending ||
              target.reviewState == EpisodeReviewState.accepted
          ? null
          : 'memory_edit_state_invalid',
    MemoryGovernanceAction.reject =>
      target.reviewState == EpisodeReviewState.pending
          ? null
          : 'memory_reject_requires_pending',
    MemoryGovernanceAction.delete =>
      target.reviewState != EpisodeReviewState.tombstoned
          ? null
          : 'memory_already_deleted',
    MemoryGovernanceAction.restore =>
      target.reviewState == EpisodeReviewState.tombstoned ||
              target.reviewState == EpisodeReviewState.rejected
          ? null
          : 'memory_restore_state_invalid',
  };

  EpisodeReviewState _reviewStateAfter(
    MemoryGovernanceAction action,
    EpisodeReviewState current,
  ) => switch (action) {
    MemoryGovernanceAction.accept ||
    MemoryGovernanceAction.restore => EpisodeReviewState.accepted,
    MemoryGovernanceAction.edit => current,
    MemoryGovernanceAction.reject => EpisodeReviewState.rejected,
    MemoryGovernanceAction.delete => EpisodeReviewState.tombstoned,
  };

  Future<void> _markGovernanceProjection(int episodeId, String field) async {
    final record = MemoryGovernanceStores.episodeGovernance.record(episodeId);
    final current = await record.get(_db);
    if (current == null ||
        current['accountScopeDigest'] != _accountScopeDigest) {
      return;
    }
    await record.put(_db, <String, Object?>{
      ...current,
      field: true,
      'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
    });
  }

  Future<bool> _unlinkSupersededProjection(int episodeId) async {
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(episodeId)
        .get(_db);
    if (governance == null ||
        governance['accountScopeDigest'] != _accountScopeDigest) {
      return false;
    }
    if (governance['projectionUnlinkComplete'] == true) return true;
    if (governance['governedProjectionKind'] is String) {
      await _markGovernanceProjection(episodeId, 'projectionUnlinkComplete');
      return true;
    }
    try {
      await _removeEpisodeLinks(episodeId);
      await _markGovernanceProjection(episodeId, 'projectionUnlinkComplete');
      return true;
    } catch (_) {
      // Recall eligibility is authoritative. Exact source replay retries this
      // idempotent cleanup while the durable receipt remains false.
      return false;
    }
  }

  Future<void> waitForIdle() => _mutationTail;

  Future<void> deactivateAndDrain() async {
    _retiring = true;
    await _mutationTail;
  }

  Future<MemoryWriteResult> _write(
    MemoryWriteDraft draft, {
    required MemoryWriteSource source,
    required MemoryWriteAuthority authority,
    required FeatureRolloutMode mode,
    required _PersistedChatSourceScope? sourceScope,
  }) async {
    final projection = draft.projection;
    if (projection != null) {
      final sink = _projectionSink(projection.kind);
      if (sink == null) {
        return const MemoryWriteResult(
          disposition: MemoryWriteDisposition.rejected,
          episode: null,
          created: false,
          projected: false,
          reason: 'governed_projection_sink_missing',
        );
      }
      try {
        sink.validateProjection(projection);
      } on Object {
        return const MemoryWriteResult(
          disposition: MemoryWriteDisposition.rejected,
          episode: null,
          created: false,
          projected: false,
          reason: 'governed_projection_schema_invalid',
        );
      }
    }
    final invalidAuthority = switch ((draft.projection, authority)) {
      (null, MemoryWriteAuthority.governedProposal) =>
        'governed_proposal_requires_projection',
      (
        != null,
        MemoryWriteAuthority.automaticConversation ||
            MemoryWriteAuthority.inherited,
      ) =>
        'governed_projection_authority_invalid',
      _ => null,
    };
    if (invalidAuthority != null) {
      return MemoryWriteResult(
        disposition: MemoryWriteDisposition.rejected,
        episode: null,
        created: false,
        projected: false,
        reason: invalidAuthority,
      );
    }
    if (projection != null &&
        _projectionFamily(projection.kind) != null &&
        authority != MemoryWriteAuthority.governedProposal) {
      return const MemoryWriteResult(
        disposition: MemoryWriteDisposition.rejected,
        episode: null,
        created: false,
        projected: false,
        reason: 'conversation_projection_requires_governed_proposal',
      );
    }
    if (draft.projection != null && mode == FeatureRolloutMode.off) {
      return const MemoryWriteResult(
        disposition: MemoryWriteDisposition.rejected,
        episode: null,
        created: false,
        projected: false,
        reason: 'governed_projection_requires_memory_v2',
      );
    }
    if (mode == FeatureRolloutMode.off) {
      return _writeLegacy(draft, MemoryWriteDisposition.legacy);
    }

    if (mode == FeatureRolloutMode.shadow) {
      _ShadowEvaluation? evaluation;
      try {
        await Future<void>.sync(
          () => _faultInjector?.call(
            MemoryWriteFaultPoint.shadowEvaluation,
            _digest('memory-shadow-evaluation-v1'),
          ),
        );
        evaluation = await _evaluateShadow(
          draft,
          source,
          authority,
          sourceScope: sourceScope,
        );
      } catch (error) {
        Log.w(
          '[MemoryWriteCoordinator] shadow evaluation skipped: '
          '${error.runtimeType}',
        );
      }
      MemoryWriteResult? projectionResult;
      if (draft.projection != null) {
        projectionResult = MemoryWriteResult(
          disposition:
              evaluation?.disposition == MemoryWriteDisposition.rejected
              ? MemoryWriteDisposition.rejected
              : MemoryWriteDisposition.shadow,
          episode: null,
          created: false,
          projected: false,
          reason: evaluation?.reason ?? 'shadow_evaluation_unavailable',
        );
      }
      final legacy =
          projectionResult ??
          await _writeLegacy(draft, MemoryWriteDisposition.shadow);
      if (evaluation != null) {
        try {
          await Future<void>.sync(
            () => _faultInjector?.call(
              MemoryWriteFaultPoint.shadowAudit,
              evaluation!.exactFingerprint ?? _digest('memory-shadow-audit-v1'),
            ),
          );
          await _appendAudit(
            mode: mode,
            disposition: evaluation.disposition,
            reason: evaluation.reason,
            exactFingerprint: evaluation.exactFingerprint,
            semanticFingerprint: evaluation.semanticFingerprint,
            episodeId: legacy.episodeId,
            created: draft.projection == null,
            sourceRef: evaluation.sourceRef,
          );
        } catch (error) {
          Log.w(
            '[MemoryWriteCoordinator] shadow audit skipped: '
            '${error.runtimeType}',
          );
        }
      }
      return legacy;
    }

    late _CommittedMemory committed;
    await _db.transaction((transaction) async {
      final resolved = await _resolveSource(
        transaction,
        source,
        scope: sourceScope,
      );
      if (resolved == null) {
        final now = _clock().toUtc();
        await MemoryGovernanceStores.audit.add(transaction, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountScopeDigest,
          'mode': mode.name,
          'disposition': MemoryWriteDisposition.rejected.name,
          'reason': 'trusted_source_missing_or_invalid',
          'created': false,
          'writtenAt': now.millisecondsSinceEpoch,
        });
        committed = const _CommittedMemory.rejected(
          'trusted_source_missing_or_invalid',
        );
        return;
      }

      final decision = _decideReview(draft, authority, resolved);
      if (decision.disposition == MemoryWriteDisposition.rejected) {
        await _writeAuditInTransaction(
          transaction,
          mode: mode,
          disposition: decision.disposition,
          reason: decision.reason,
          exactFingerprint: null,
          semanticFingerprint: null,
          episodeId: null,
          created: false,
          sourceRef: resolved.ref,
        );
        committed = _CommittedMemory.rejected(decision.reason);
        return;
      }
      final family = projection == null
          ? null
          : _projectionFamily(projection.kind);
      final supporting = family == null
          ? const <EpisodeSourceRef>[]
          : family.supportingSources(projection!);
      if (family != null) {
        var valid = resolved.chatMessage != null && supporting.length <= 7;
        for (final ref in supporting) {
          final dependency = await _verifiedConversationSource(
            transaction,
            ref,
            agentId: resolved.agentId,
          );
          if (ref.sessionId != resolved.ref.sessionId ||
              ref.sourceId == resolved.ref.sourceId ||
              dependency == null ||
              resolved.chatMessage == null ||
              dependency.timestamp.isAfter(resolved.chatMessage!.timestamp)) {
            valid = false;
          }
        }
        if (!valid) {
          committed = const _CommittedMemory.rejected(
            'conversation_projection_source_invalid',
          );
          return;
        }
      }
      final governedDraft = _governedDraftForWrite(
        draft,
        authority: authority,
        decision: decision,
        sourceText: resolved.chatMessage?.content,
      );
      final effectiveWhen =
          resolved.chatMessage?.timestamp.toUtc() ?? governedDraft.when.toUtc();
      final exactFingerprint = _exactFingerprint(
        governedDraft,
        resolved.ref,
        effectiveWhen,
      );
      final semanticFingerprint = _semanticFingerprint(
        governedDraft,
        effectiveWhen,
      );
      final governedProjection = governedDraft.projection;
      GovernedMemoryProjectionHeadRecord? projectionHead;
      Episode? projectionHeadEpisode;
      if (governedProjection != null) {
        final projectionHeadRaw = await MemoryGovernanceStores
            .governedProjectionHeads
            .record(governedProjection.kind)
            .get(transaction);
        if (projectionHeadRaw != null) {
          try {
            projectionHead = GovernedMemoryProjectionHeadRecord.fromStored(
              projectionHeadRaw,
              expectedKind: governedProjection.kind,
              expectedAccountScopeDigest: _accountScopeDigest,
            );
            projectionHeadEpisode =
                await _validateGovernedProjectionHeadBinding(
                  transaction,
                  projectionHead,
                );
          } on Object {
            await _writeAuditInTransaction(
              transaction,
              mode: mode,
              disposition: MemoryWriteDisposition.rejected,
              reason: 'governed_projection_head_invalid',
              exactFingerprint: exactFingerprint,
              semanticFingerprint: semanticFingerprint,
              episodeId: null,
              created: false,
              sourceRef: resolved.ref,
            );
            committed = const _CommittedMemory.rejected(
              'governed_projection_head_invalid',
            );
            return;
          }
        }
      }
      bool projectionReplayEligible(Episode episode) {
        if (governedProjection == null) return true;
        final head = projectionHead;
        if (head == null) return false;
        if (episode.id == head.activeEpisodeId &&
            episode.reviewState == EpisodeReviewState.accepted) {
          return true;
        }
        return episode.id == head.headEpisodeId &&
            head.reviewState == EpisodeReviewState.pending &&
            episode.reviewState == EpisodeReviewState.pending;
      }

      final exact = await MemoryGovernanceStores.exactDedup
          .record(exactFingerprint)
          .get(transaction);
      final exactEpisode = await _validIndexedEpisode(
        transaction,
        exact,
        expectedFingerprint: exactFingerprint,
        requireAcceptedCurrent: false,
      );
      Episode? reviewPriorEpisode;
      if (exactEpisode != null && projectionReplayEligible(exactEpisode)) {
        final promotesReview =
            decision.reviewState == EpisodeReviewState.accepted &&
            exactEpisode.reviewState == EpisodeReviewState.pending;
        if (!promotesReview) {
          committed = _CommittedMemory.duplicate(
            exactEpisode,
            exactFingerprint: exactFingerprint,
            semanticFingerprint: semanticFingerprint,
          );
          await _writeAuditInTransaction(
            transaction,
            mode: mode,
            disposition: MemoryWriteDisposition.duplicate,
            reason: 'exact_replay',
            exactFingerprint: exactFingerprint,
            semanticFingerprint: semanticFingerprint,
            episodeId: exactEpisode.id,
            created: false,
            sourceRef: resolved.ref,
          );
          return;
        }
        reviewPriorEpisode = exactEpisode;
      }

      final semantic = await MemoryGovernanceStores.semanticDedup
          .record(semanticFingerprint)
          .get(transaction);
      final semanticEpisode = await _validIndexedEpisode(
        transaction,
        semantic,
        expectedFingerprint: semanticFingerprint,
        governanceFingerprintField: 'semanticFingerprint',
      );
      if (semanticEpisode != null &&
          projectionReplayEligible(semanticEpisode) &&
          (semanticEpisode.reviewState == decision.reviewState ||
              semanticEpisode.reviewState == EpisodeReviewState.accepted ||
              semanticEpisode.reviewState == EpisodeReviewState.rejected ||
              semanticEpisode.reviewState == EpisodeReviewState.tombstoned)) {
        await MemoryGovernanceStores.exactDedup
            .record(exactFingerprint)
            .put(
              transaction,
              _dedupRow(
                fingerprint: exactFingerprint,
                episode: semanticEpisode,
                now: _clock().toUtc(),
              ),
            );
        committed = _CommittedMemory.duplicate(
          semanticEpisode,
          exactFingerprint: exactFingerprint,
          semanticFingerprint: semanticFingerprint,
        );
        await _writeAuditInTransaction(
          transaction,
          mode: mode,
          disposition: MemoryWriteDisposition.duplicate,
          reason: 'semantic_duplicate',
          exactFingerprint: exactFingerprint,
          semanticFingerprint: semanticFingerprint,
          episodeId: semanticEpisode.id,
          created: false,
          sourceRef: resolved.ref,
        );
        return;
      }
      if (semanticEpisode != null &&
          projectionReplayEligible(semanticEpisode) &&
          decision.reviewState == EpisodeReviewState.accepted &&
          semanticEpisode.reviewState == EpisodeReviewState.pending) {
        reviewPriorEpisode ??= semanticEpisode;
      }

      final now = _clock().toUtc();
      final claimSlotFingerprint = governedDraft.claimSlot == null
          ? null
          : _digest(
              'claim-slot-v1:${_normalizeForFingerprint(governedDraft.claimSlot!)}',
            );
      final claimValueFingerprint = governedDraft.claimValue == null
          ? null
          : _digest('claim-value-v2:${governedDraft.claimValue!}');
      Map<String, Object?>? priorHead;
      Episode? priorEpisode;
      if (claimSlotFingerprint != null) {
        priorHead = await MemoryGovernanceStores.claimHeads
            .record(claimSlotFingerprint)
            .get(transaction);
        priorEpisode = await _validIndexedEpisode(
          transaction,
          priorHead,
          expectedFingerprint: claimSlotFingerprint,
          fingerprintField: 'slotFingerprint',
          governanceFingerprintField: 'claimSlotFingerprint',
        );
      }
      final priorEpisodeId = priorEpisode?.id;
      var supersededEpisodeId = priorEpisodeId ?? reviewPriorEpisode?.id;
      var supersededEpisode = priorEpisode ?? reviewPriorEpisode;
      if (governedProjection != null) {
        if (projectionHead != null) {
          if (projectionHead.activeEpisodeId != priorEpisodeId) {
            await _writeAuditInTransaction(
              transaction,
              mode: mode,
              disposition: MemoryWriteDisposition.rejected,
              reason: 'governed_projection_head_invalid',
              exactFingerprint: exactFingerprint,
              semanticFingerprint: semanticFingerprint,
              episodeId: null,
              created: false,
              sourceRef: resolved.ref,
            );
            committed = const _CommittedMemory.rejected(
              'governed_projection_head_invalid',
            );
            return;
          }
          supersededEpisode = projectionHeadEpisode;
          supersededEpisodeId = projectionHeadEpisode!.id;
        }
      }
      final previousActiveEpisodeId = governedProjection == null
          ? null
          : projectionHead?.activeEpisodeId ?? priorEpisodeId;
      final conflicts =
          priorEpisodeId != null &&
          priorHead?['valueFingerprint'] != claimValueFingerprint;
      final accepted = decision.reviewState == EpisodeReviewState.accepted;
      int? lineageId;
      if ((accepted || governedProjection != null) &&
          supersededEpisode != null) {
        final predecessorGovernance = await MemoryGovernanceStores
            .episodeGovernance
            .record(supersededEpisode.id!)
            .get(transaction);
        lineageId = await _reviewLineageId(
          transaction,
          supersededEpisode,
          predecessorGovernance,
        );
        if (lineageId == null) {
          await _writeAuditInTransaction(
            transaction,
            mode: mode,
            disposition: MemoryWriteDisposition.rejected,
            reason: 'memory_revision_chain_invalid',
            exactFingerprint: exactFingerprint,
            semanticFingerprint: semanticFingerprint,
            episodeId: null,
            created: false,
            sourceRef: resolved.ref,
          );
          committed = const _CommittedMemory.rejected(
            'memory_revision_chain_invalid',
          );
          return;
        }
        final lineageHead = await MemoryGovernanceStores.revisionHeads
            .record(lineageId)
            .get(transaction);
        final lineageHeadId = (lineageHead?['headEpisodeId'] as num?)?.toInt();
        final lineageHeadRevision = (lineageHead?['revision'] as num?)?.toInt();
        final lineageHeadValid =
            lineageHead == null ||
            (lineageHead['schemaVersion'] == 1 &&
                lineageHead['accountScopeDigest'] == _accountScopeDigest &&
                lineageHead['lineageId'] == lineageId &&
                lineageHeadId != null &&
                lineageHeadRevision != null);
        if (lineageHeadValid &&
            governedProjection != null &&
            lineageHeadId != null &&
            lineageHeadId != supersededEpisode.id) {
          final headRaw = await MemoryGovernanceStores.episodes
              .record(lineageHeadId)
              .get(transaction);
          final headGovernance = await MemoryGovernanceStores.episodeGovernance
              .record(lineageHeadId)
              .get(transaction);
          try {
            final candidate = Episode.fromJson(headRaw!)..id = lineageHeadId;
            if (candidate.revision != lineageHeadRevision ||
                headGovernance?['accountScopeDigest'] != _accountScopeDigest ||
                headGovernance?['lineageId'] != lineageId ||
                headGovernance?['governedProjectionKind'] !=
                    governedProjection.kind) {
              throw const FormatException();
            }
            supersededEpisode = candidate;
            supersededEpisodeId = lineageHeadId;
          } on Object {
            await _writeAuditInTransaction(
              transaction,
              mode: mode,
              disposition: MemoryWriteDisposition.rejected,
              reason: 'memory_revision_chain_invalid',
              exactFingerprint: exactFingerprint,
              semanticFingerprint: semanticFingerprint,
              episodeId: null,
              created: false,
              sourceRef: resolved.ref,
            );
            committed = const _CommittedMemory.rejected(
              'memory_revision_chain_invalid',
            );
            return;
          }
        }
        if (!lineageHeadValid ||
            (lineageHead != null &&
                (lineageHeadId != supersededEpisode.id ||
                    lineageHeadRevision != supersededEpisode.revision))) {
          await _writeAuditInTransaction(
            transaction,
            mode: mode,
            disposition: MemoryWriteDisposition.rejected,
            reason: 'memory_revision_head_conflict',
            exactFingerprint: exactFingerprint,
            semanticFingerprint: semanticFingerprint,
            episodeId: null,
            created: false,
            sourceRef: resolved.ref,
          );
          committed = const _CommittedMemory.rejected(
            'memory_revision_head_conflict',
          );
          return;
        }
      }
      final headRevision = supersededEpisode?.revision ?? 0;
      final priorRevision = headRevision > (reviewPriorEpisode?.revision ?? 0)
          ? headRevision
          : (reviewPriorEpisode?.revision ?? 0);
      final revision = priorRevision == 0 ? 1 : priorRevision + 1;
      final episode = Episode(
        when: effectiveWhen,
        what: governedDraft.what,
        entities: governedDraft.entities,
        emotion: governedDraft.emotion,
        salience: governedDraft.salience,
        agentId: resolved.agentId,
        kind: governedDraft.kind,
        sourceRefs: <EpisodeSourceRef>[resolved.ref, ...supporting],
        sourceType: decision.sourceType,
        confidence: decision.confidence,
        reviewState: decision.reviewState,
        revision: revision,
        supersedesId: accepted || governedProjection != null
            ? supersededEpisodeId
            : null,
        contradictionIds: conflicts ? <int>[priorEpisodeId] : const <int>[],
        createdAt: now,
        updatedAt: now,
        retentionClass: governedDraft.retentionClass,
      );
      final id = await MemoryGovernanceStores.episodes.add(
        transaction,
        episode.toJson(),
      );
      episode.id = id;
      lineageId ??= id;
      if (governedProjection != null) {
        await MemoryGovernanceStores.governedProjections
            .record(id)
            .put(
              transaction,
              GovernedMemoryProjectionRecord(
                episodeId: id,
                accountScopeDigest: _accountScopeDigest,
                draft: governedProjection,
              ).toStored(),
            );
      }
      final current = accepted;
      await MemoryGovernanceStores.episodeGovernance
          .record(id)
          .put(transaction, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'episodeId': id,
            'current': current,
            'reviewState': decision.reviewState.name,
            'lineageId': lineageId,
            'supersededByEpisodeId': null,
            'exactFingerprint': exactFingerprint,
            'semanticFingerprint': semanticFingerprint,
            'claimSlotFingerprint': claimSlotFingerprint,
            'claimValueFingerprint': claimValueFingerprint,
            'governedProjectionKind': governedProjection?.kind,
            'lineageExpiresAt': episode.expiresAt?.millisecondsSinceEpoch,
            'projectionLinkComplete': false,
            'projectionMilestoneComplete': false,
            'projectionGovernedComplete': false,
            'writtenAt': now.millisecondsSinceEpoch,
            'updatedAt': now.millisecondsSinceEpoch,
          });
      if ((accepted || governedProjection != null) &&
          supersededEpisodeId != null) {
        if (accepted) {
          await _markNotCurrent(transaction, supersededEpisodeId, now);
        }
        final predecessorRecord = MemoryGovernanceStores.episodeGovernance
            .record(supersededEpisodeId);
        final predecessorGovernance = await predecessorRecord.get(transaction);
        if (predecessorGovernance == null ||
            predecessorGovernance['accountScopeDigest'] !=
                _accountScopeDigest) {
          throw StateError('memory_revision_predecessor_invalid');
        }
        await predecessorRecord.put(transaction, <String, Object?>{
          ...predecessorGovernance,
          'lineageId': lineageId,
          'supersededByEpisodeId': id,
          'projectionUnlinkComplete': false,
          'updatedAt': now.millisecondsSinceEpoch,
        });
      }
      if (accepted &&
          previousActiveEpisodeId != null &&
          previousActiveEpisodeId != supersededEpisodeId) {
        await _markNotCurrent(transaction, previousActiveEpisodeId, now);
        final activeRecord = MemoryGovernanceStores.episodeGovernance.record(
          previousActiveEpisodeId,
        );
        final activeGovernance = await activeRecord.get(transaction);
        if (activeGovernance == null ||
            activeGovernance['accountScopeDigest'] != _accountScopeDigest ||
            activeGovernance['governedProjectionKind'] !=
                governedProjection?.kind) {
          throw StateError('memory_projection_active_invalid');
        }
        await activeRecord.put(transaction, <String, Object?>{
          ...activeGovernance,
          'projectionGovernedUnlinkComplete': false,
          'updatedAt': now.millisecondsSinceEpoch,
        });
      }
      await MemoryGovernanceStores.revisionHeads
          .record(lineageId)
          .put(transaction, <String, Object?>{
            'schemaVersion': 1,
            'accountScopeDigest': _accountScopeDigest,
            'lineageId': lineageId,
            'headEpisodeId': id,
            'revision': revision,
            'reviewState': decision.reviewState.name,
            'updatedAt': now.millisecondsSinceEpoch,
          });
      if (governedProjection != null) {
        final activeEpisodeId = accepted ? id : previousActiveEpisodeId;
        final materializationComplete = projectionHead == null
            ? activeEpisodeId == null
            : projectionHead.materializationComplete &&
                  projectionHead.activeEpisodeId == activeEpisodeId;
        await MemoryGovernanceStores.governedProjectionHeads
            .record(governedProjection.kind)
            .put(
              transaction,
              GovernedMemoryProjectionHeadRecord(
                kind: governedProjection.kind,
                headEpisodeId: id,
                activeEpisodeId: activeEpisodeId,
                revision: revision,
                reviewState: decision.reviewState,
                materializationComplete: materializationComplete,
                materializedActiveEpisodeId: materializationComplete
                    ? activeEpisodeId
                    : null,
              ).toStored(
                accountScopeDigest: _accountScopeDigest,
                updatedAt: now,
              ),
            );
      }
      if (governedProjection == null) {
        await _episodeStore.updateRecallIndexInTransaction(
          transaction,
          episode,
          removeEpisodeId: accepted ? supersededEpisodeId : null,
          now: now,
        );
      } else {
        await MemoryGovernanceStores.episodeRecallIndex
            .record(id)
            .delete(transaction);
        if (accepted && supersededEpisodeId != null) {
          await MemoryGovernanceStores.episodeRecallIndex
              .record(supersededEpisodeId)
              .delete(transaction);
        }
      }
      if (accepted && claimSlotFingerprint != null) {
        await MemoryGovernanceStores.claimHeads
            .record(claimSlotFingerprint)
            .put(transaction, <String, Object?>{
              'schemaVersion': 1,
              'accountScopeDigest': _accountScopeDigest,
              'episodeId': id,
              'revision': revision,
              'slotFingerprint': claimSlotFingerprint,
              'valueFingerprint': claimValueFingerprint,
              'updatedAt': now.millisecondsSinceEpoch,
            });
      }
      final dedupRow = _dedupRow(
        fingerprint: exactFingerprint,
        episode: episode,
        now: now,
      );
      await MemoryGovernanceStores.exactDedup
          .record(exactFingerprint)
          .put(transaction, dedupRow);
      await MemoryGovernanceStores.semanticDedup
          .record(semanticFingerprint)
          .put(
            transaction,
            _dedupRow(
              fingerprint: semanticFingerprint,
              episode: episode,
              now: now,
            ),
          );
      await _writeAuditInTransaction(
        transaction,
        mode: mode,
        disposition: decision.disposition,
        reason: decision.reason,
        exactFingerprint: exactFingerprint,
        semanticFingerprint: semanticFingerprint,
        episodeId: id,
        created: true,
        sourceRef: resolved.ref,
      );
      await Future<void>.sync(
        () => _faultInjector?.call(
          MemoryWriteFaultPoint.beforeCommit,
          exactFingerprint,
        ),
      );
      committed = _CommittedMemory(
        disposition: decision.disposition,
        episode: episode,
        created: true,
        exactFingerprint: exactFingerprint,
        semanticFingerprint: semanticFingerprint,
        reason: decision.reason,
      );
    });

    if (committed.created) _episodeStore.invalidateRecallCache();
    final episode = committed.episode;
    if (episode == null) {
      return MemoryWriteResult(
        disposition: committed.disposition,
        episode: null,
        created: false,
        projected: false,
        reason: committed.reason,
      );
    }
    await Future<void>.sync(
      () => _faultInjector?.call(
        MemoryWriteFaultPoint.afterCommit,
        committed.exactFingerprint!,
      ),
    );
    final supersedesId = episode.supersedesId;
    final supersededProjectionComplete = supersedesId == null
        ? true
        : await _unlinkSupersededProjection(supersedesId);
    var projected = false;
    final governedProjectionKind = draft.projection?.kind;
    if (governedProjectionKind != null) {
      var materialized = await _materializeGovernedProjectionKind(
        governedProjectionKind,
      );
      if (!materialized) {
        materialized = await _materializeGovernedProjectionKind(
          governedProjectionKind,
        );
      }
      projected =
          episode.reviewState == EpisodeReviewState.accepted &&
          supersededProjectionComplete &&
          materialized;
    } else if (episode.reviewState == EpisodeReviewState.accepted) {
      projected =
          supersededProjectionComplete &&
          await _projectIfNeeded(episode, committed.exactFingerprint!);
    }
    return MemoryWriteResult(
      disposition: committed.disposition,
      episode: episode,
      created: committed.created,
      projected: projected,
      reason: committed.reason,
    );
  }

  Future<MemoryWriteResult> _writeLegacy(
    MemoryWriteDraft draft,
    MemoryWriteDisposition disposition,
  ) async {
    final episode = draft.toLegacyEpisode();
    final id = await _episodeStore.addLegacy(episode);
    await _projectLegacy(episode);
    return MemoryWriteResult(
      disposition: disposition,
      episode: episode..id = id,
      created: true,
      projected: true,
    );
  }

  Future<_ShadowEvaluation> _evaluateShadow(
    MemoryWriteDraft draft,
    MemoryWriteSource source,
    MemoryWriteAuthority authority, {
    required _PersistedChatSourceScope? sourceScope,
  }) async {
    final resolved = await _db.transaction(
      (transaction) => _resolveSource(
        transaction,
        source,
        scope: sourceScope,
        persistImported: false,
      ),
    );
    if (resolved == null) {
      return const _ShadowEvaluation(
        disposition: MemoryWriteDisposition.rejected,
        reason: 'trusted_source_missing_or_invalid',
      );
    }
    final decision = _decideReview(draft, authority, resolved);
    final governedDraft = _governedDraftForWrite(
      draft,
      authority: authority,
      decision: decision,
      sourceText: resolved.chatMessage?.content,
    );
    final when =
        resolved.chatMessage?.timestamp.toUtc() ?? governedDraft.when.toUtc();
    return _ShadowEvaluation(
      disposition: decision.disposition,
      reason: decision.reason,
      exactFingerprint: _exactFingerprint(governedDraft, resolved.ref, when),
      semanticFingerprint: _semanticFingerprint(governedDraft, when),
      sourceRef: resolved.ref,
    );
  }

  Future<_ResolvedMemorySource?> _resolveSource(
    DatabaseClient client,
    MemoryWriteSource source, {
    required _PersistedChatSourceScope? scope,
    bool persistImported = true,
  }) async {
    if (source is CurrentTurnMemorySource) {
      if (scope == null || !scope.isCurrentFor(this)) return null;
      final raw = await MemoryGovernanceStores.chatMessages
          .record(scope.messageRecordId)
          .get(client);
      if (raw == null) return null;
      final persistedTimestamp = raw['timestamp'];
      final parsedTimestamp = persistedTimestamp is String
          ? DateTime.tryParse(persistedTimestamp)
          : null;
      if (raw['sessionId'] is! String ||
          raw['senderId'] != 'user' ||
          raw['receiverId'] != scope.agentId ||
          raw['content'] is! String ||
          (raw['content'] as String).isEmpty ||
          parsedTimestamp == null ||
          raw['isUserMessage'] != true ||
          raw['turnOrigin'] is! String ||
          !ChatMessageTurnOrigins.humanAuthored.contains(raw['turnOrigin'])) {
        return null;
      }
      final message = ChatMessage.fromJson(raw, id: scope.messageRecordId);
      final origin = message.turnOrigin;
      if (!message.isUserMessage ||
          message.sessionId != scope.sessionId ||
          !ChatMessageTurnOrigins.humanAuthored.contains(origin)) {
        return null;
      }
      return _ResolvedMemorySource(
        ref: EpisodeSourceRef(
          sourceId: 'chat_message:${scope.messageRecordId}',
          sessionId: message.sessionId,
          origin: EpisodeSourceOrigin.user,
          contentHash: _digest(message.content),
        ),
        agentId: scope.agentId,
        chatMessage: message,
        sourceType: EpisodeSourceType.conversation,
      );
    }
    if (source is! ImportedMemorySource) return null;
    final sourceIdentity = _digest(
      'imported-source-v1:${source.sourceKind}:${source.sourceKey}',
    );
    final sourceId = 'imported:$sourceIdentity';
    final contentHash = _digest(source.canonicalMaterial);
    final sessionId = '${source.sourceKind}:${sourceIdentity.substring(0, 32)}';
    if (persistImported) {
      final record = MemoryGovernanceStores.sourceMaterial.record(sourceId);
      final existing = await record.get(client);
      final material = <String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': _accountScopeDigest,
        'sourceId': sourceId,
        'sourceKind': source.sourceKind,
        'contentHash': contentHash,
        'canonicalMaterial': source.canonicalMaterial,
        'createdAt': _clock().toUtc().millisecondsSinceEpoch,
      };
      if (existing != null &&
          (existing['accountScopeDigest'] != _accountScopeDigest ||
              existing['contentHash'] != contentHash ||
              existing['canonicalMaterial'] != source.canonicalMaterial)) {
        return null;
      }
      if (existing == null) await record.put(client, material);
    }
    return _ResolvedMemorySource(
      ref: EpisodeSourceRef(
        sourceId: sourceId,
        sessionId: sessionId,
        origin: EpisodeSourceOrigin.imported,
        contentHash: contentHash,
      ),
      agentId: 'self',
      sourceType: EpisodeSourceType.inherited,
    );
  }

  _ReviewDecision _decideReview(
    MemoryWriteDraft draft,
    MemoryWriteAuthority authority,
    _ResolvedMemorySource source,
  ) {
    if (authority == MemoryWriteAuthority.verifiedHost) {
      return _ReviewDecision.accepted(
        sourceType: source.sourceType == EpisodeSourceType.inherited
            ? EpisodeSourceType.inherited
            : EpisodeSourceType.explicitSave,
        confidence: 1,
        reason: 'verified_host_source',
      );
    }
    final sourceMessage = source.chatMessage;
    if (authority == MemoryWriteAuthority.governedProposal) {
      if (sourceMessage == null) {
        return const _ReviewDecision.rejected(
          sourceType: EpisodeSourceType.runtimeUnknown,
          reason: 'governed_proposal_requires_human_source',
        );
      }
      if (_isExplicitNoSaveRequest(
        sourceMessage.content,
        structuredProposal: true,
      )) {
        return const _ReviewDecision.rejected(
          sourceType: EpisodeSourceType.conversation,
          reason: 'explicit_no_save_request',
        );
      }
      return const _ReviewDecision.quarantined(
        sourceType: EpisodeSourceType.conversation,
        confidence: 0.75,
        reason: 'structured_memory_requires_review',
      );
    }
    if (authority == MemoryWriteAuthority.automaticConversation &&
        sourceMessage != null) {
      if (_isExplicitNoSaveRequest(sourceMessage.content)) {
        return const _ReviewDecision.rejected(
          sourceType: EpisodeSourceType.conversation,
          reason: 'explicit_no_save_request',
        );
      }
      final explicitRemember = _isExplicitRememberRequest(
        sourceMessage.content,
      );
      if (explicitRemember &&
          _memoryAssertionForStorage(sourceMessage.content).runes.length >
              _maxAutomaticAcceptedAssertionLength) {
        return const _ReviewDecision.rejected(
          sourceType: EpisodeSourceType.conversation,
          reason: 'explicit_save_too_long',
        );
      }
      if (explicitRemember &&
          !_proposalIsGrounded(draft, sourceMessage.content)) {
        return const _ReviewDecision.quarantined(
          sourceType: EpisodeSourceType.conversation,
          confidence: 0.35,
          reason: 'explicit_save_not_grounded',
        );
      }
      if (explicitRemember) {
        return const _ReviewDecision.accepted(
          sourceType: EpisodeSourceType.explicitSave,
          confidence: 0.9,
          reason: 'explicit_user_save',
        );
      }
    }
    return _ReviewDecision.quarantined(
      sourceType: source.sourceType,
      confidence: authority == MemoryWriteAuthority.inherited ? 0.45 : 0.6,
      reason: authority == MemoryWriteAuthority.inherited
          ? 'import_requires_review'
          : 'automatic_summary_requires_review',
    );
  }

  Future<Episode?> _validIndexedEpisode(
    DatabaseClient client,
    Map<String, Object?>? index, {
    String? expectedFingerprint,
    String fingerprintField = 'fingerprint',
    String? governanceFingerprintField,
    bool requireAcceptedCurrent = true,
  }) async {
    if (index == null || index['accountScopeDigest'] != _accountScopeDigest) {
      return null;
    }
    if (expectedFingerprint != null &&
        index[fingerprintField] != expectedFingerprint) {
      return null;
    }
    final id = (index['episodeId'] as num?)?.toInt();
    if (id == null || id < 1) return null;
    final raw = await MemoryGovernanceStores.episodes.record(id).get(client);
    if (raw == null) return null;
    try {
      final episode = Episode.fromJson(raw)..id = id;
      final indexedReviewState = index['reviewState'];
      if (indexedReviewState != null &&
          indexedReviewState != episode.reviewState.name) {
        return null;
      }
      final governance = await MemoryGovernanceStores.episodeGovernance
          .record(id)
          .get(client);
      if (governance == null ||
          governance['accountScopeDigest'] != _accountScopeDigest ||
          governance['episodeId'] != id ||
          governance['reviewState'] != episode.reviewState.name) {
        return null;
      }
      if (expectedFingerprint != null &&
          governanceFingerprintField != null &&
          governance[governanceFingerprintField] != expectedFingerprint) {
        return null;
      }
      if (requireAcceptedCurrent &&
          episode.reviewState == EpisodeReviewState.accepted &&
          governance['current'] != true) {
        return null;
      }
      return episode;
    } on FormatException {
      return null;
    }
  }

  Future<GovernedMemoryProjectionRecord> _boundGovernedProjectionRecord(
    DatabaseClient client, {
    required int episodeId,
    required String kind,
    required EpisodeReviewState expectedReviewState,
    required bool requireCurrent,
  }) async {
    final episodeRaw = await MemoryGovernanceStores.episodes
        .record(episodeId)
        .get(client);
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(episodeId)
        .get(client);
    if (episodeRaw == null ||
        governance?['schemaVersion'] != 1 ||
        governance?['accountScopeDigest'] != _accountScopeDigest ||
        governance?['episodeId'] != episodeId ||
        governance?['reviewState'] != expectedReviewState.name ||
        governance?['governedProjectionKind'] != kind ||
        (requireCurrent && governance?['current'] != true)) {
      throw const FormatException('governed projection binding is invalid');
    }
    final episode = Episode.fromJson(episodeRaw)..id = episodeId;
    if (episode.reviewState != expectedReviewState) {
      throw const FormatException('governed projection binding is invalid');
    }
    final projection = GovernedMemoryProjectionRecord.fromStored(
      await MemoryGovernanceStores.governedProjections
          .record(episodeId)
          .get(client),
      expectedEpisodeId: episodeId,
      expectedAccountScopeDigest: _accountScopeDigest,
      expectedKind: kind,
    );
    final sink = _projectionSink(kind);
    if (sink == null) {
      throw const FormatException('governed projection sink is missing');
    }
    try {
      sink.validateProjection(
        GovernedMemoryProjectionDraft(
          kind: projection.kind,
          payload: projection.payload,
        ),
      );
    } on Object {
      throw const FormatException('governed projection schema is invalid');
    }
    if (!projection.matchesClaimValueFingerprint(
      governance?['claimValueFingerprint'],
    )) {
      throw const FormatException('governed projection binding is invalid');
    }
    return projection;
  }

  Future<Episode> _validateGovernedProjectionHeadBinding(
    DatabaseClient client,
    GovernedMemoryProjectionHeadRecord head,
  ) async {
    final headProjection = await _boundGovernedProjectionRecord(
      client,
      episodeId: head.headEpisodeId,
      kind: head.kind,
      expectedReviewState: head.reviewState,
      requireCurrent: head.activeEpisodeId == head.headEpisodeId,
    );
    if (!headProjection.matchesClaimValueFingerprint(
      (await MemoryGovernanceStores.episodeGovernance
          .record(head.headEpisodeId)
          .get(client))?['claimValueFingerprint'],
    )) {
      throw const FormatException('governed projection head is invalid');
    }
    final episodeRaw = await MemoryGovernanceStores.episodes
        .record(head.headEpisodeId)
        .get(client);
    final episode = Episode.fromJson(episodeRaw!)..id = head.headEpisodeId;
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(head.headEpisodeId)
        .get(client);
    final lineageId = (governance?['lineageId'] as num?)?.toInt();
    final revisionHead = lineageId == null
        ? null
        : await MemoryGovernanceStores.revisionHeads
              .record(lineageId)
              .get(client);
    final headIsActive = head.activeEpisodeId == head.headEpisodeId;
    final validActiveShape = switch (head.reviewState) {
      EpisodeReviewState.accepted => headIsActive,
      EpisodeReviewState.pending ||
      EpisodeReviewState.rejected => !headIsActive,
      EpisodeReviewState.tombstoned => head.activeEpisodeId == null,
    };
    if (episode.revision != head.revision ||
        lineageId == null ||
        lineageId < 1 ||
        governance?['current'] != headIsActive ||
        revisionHead?['schemaVersion'] != 1 ||
        revisionHead?['accountScopeDigest'] != _accountScopeDigest ||
        revisionHead?['lineageId'] != lineageId ||
        revisionHead?['headEpisodeId'] != head.headEpisodeId ||
        revisionHead?['revision'] != head.revision ||
        revisionHead?['reviewState'] != head.reviewState.name ||
        !validActiveShape) {
      throw const FormatException('governed projection head is invalid');
    }
    final detachedActiveEpisodeId = head.activeEpisodeId;
    if (detachedActiveEpisodeId != null && !headIsActive) {
      await _boundGovernedProjectionRecord(
        client,
        episodeId: detachedActiveEpisodeId,
        kind: head.kind,
        expectedReviewState: EpisodeReviewState.accepted,
        requireCurrent: true,
      );
    }
    return episode;
  }

  Future<bool> _materializeGovernedProjectionKind(
    String kind, {
    bool force = false,
  }) async {
    final sink = _projectionSink(kind);
    if (sink == null) return false;
    try {
      final rawHead = await MemoryGovernanceStores.governedProjectionHeads
          .record(kind)
          .get(_db);
      final head = GovernedMemoryProjectionHeadRecord.fromStored(
        rawHead,
        expectedKind: kind,
        expectedAccountScopeDigest: _accountScopeDigest,
      );
      await _validateGovernedProjectionHeadBinding(_db, head);
      if (_projectionFamily(kind) != null && head.activeEpisodeId != null) {
        final active = await _boundGovernedProjectionRecord(
          _db,
          episodeId: head.activeEpisodeId!,
          kind: kind,
          expectedReviewState: EpisodeReviewState.accepted,
          requireCurrent: true,
        );
        if (!await _familyProjectionSourcesLive(_db, active)) {
          await sink.clear();
          final row = MemoryGovernanceStores.episodeGovernance.record(
            active.episodeId,
          );
          final raw = await row.get(_db);
          if (raw != null) {
            await row.put(_db, <String, Object?>{
              ...raw,
              'projectionSourceInvalidated': true,
              'projectionGovernedComplete': false,
            });
          }
          return false;
        }
      }
      if (head.materializationComplete && !force) {
        final activeEpisodeId = head.activeEpisodeId;
        if (activeEpisodeId != null) {
          final active = await _boundGovernedProjectionRecord(
            _db,
            episodeId: activeEpisodeId,
            kind: kind,
            expectedReviewState: EpisodeReviewState.accepted,
            requireCurrent: true,
          );
          await _rehydrateMatchingLegacyProjectionOverride(active, sink: sink);
        }
        return true;
      }

      final activeEpisodeId = head.activeEpisodeId;
      GovernedMemoryProjectionRecord? materializedProjection;
      if (activeEpisodeId == null) {
        await sink.clear();
      } else {
        final projection = await _boundGovernedProjectionRecord(
          _db,
          episodeId: activeEpisodeId,
          kind: kind,
          expectedReviewState: EpisodeReviewState.accepted,
          requireCurrent: true,
        );
        materializedProjection = projection;
        await sink.apply(projection);
        var activeGovernance = await _markProjection(
          activeEpisodeId,
          'projectionGovernedComplete',
        );
        if (activeGovernance['projectionLinkComplete'] != true) {
          activeGovernance = await _markProjection(
            activeEpisodeId,
            'projectionLinkComplete',
            skippedReason: 'governed_projection',
          );
        }
        if (activeGovernance['projectionMilestoneComplete'] != true) {
          await _markProjection(
            activeEpisodeId,
            'projectionMilestoneComplete',
            skippedReason: 'governed_projection',
          );
        }
      }

      var receiptCommitted = false;
      await _db.transaction((transaction) async {
        final record = MemoryGovernanceStores.governedProjectionHeads.record(
          kind,
        );
        final currentRaw = await record.get(transaction);
        final current = GovernedMemoryProjectionHeadRecord.fromStored(
          currentRaw,
          expectedKind: kind,
          expectedAccountScopeDigest: _accountScopeDigest,
        );
        if (current.headEpisodeId != head.headEpisodeId ||
            current.activeEpisodeId != head.activeEpisodeId ||
            current.revision != head.revision) {
          return;
        }
        await record.put(
          transaction,
          GovernedMemoryProjectionHeadRecord(
            kind: current.kind,
            headEpisodeId: current.headEpisodeId,
            activeEpisodeId: current.activeEpisodeId,
            revision: current.revision,
            reviewState: current.reviewState,
            materializationComplete: true,
            materializedActiveEpisodeId: current.activeEpisodeId,
          ).toStored(
            accountScopeDigest: _accountScopeDigest,
            updatedAt: _clock().toUtc(),
          ),
        );
        final overrideRecord = MemoryGovernanceStores
            .governedProjectionRollbackOverrides
            .record(kind);
        final overrideRaw = await overrideRecord.get(transaction);
        if (overrideRaw != null && materializedProjection != null) {
          try {
            final overrideDigest = _decodeLegacyProjectionOverrideDigest(
              overrideRaw,
              expectedKind: kind,
              expectedAccountScopeDigest: _accountScopeDigest,
            );
            if (overrideDigest == materializedProjection.digest) {
              await overrideRecord.delete(transaction);
            }
          } on Object {
            // Corrupt or foreign rollback markers are fail-closed.
          }
        }
        receiptCommitted = true;
      });
      if (receiptCommitted && activeEpisodeId == null) {
        await _markGovernanceProjection(
          head.headEpisodeId,
          'projectionGovernedUnlinkComplete',
        );
      }
      return receiptCommitted;
    } on Object {
      return false;
    }
  }

  Future<void> _rehydrateMatchingLegacyProjectionOverride(
    GovernedMemoryProjectionRecord projection, {
    required GovernedMemoryProjectionSink sink,
  }) async {
    final kind = projection.kind;
    final record = MemoryGovernanceStores.governedProjectionRollbackOverrides
        .record(kind);
    final raw = await record.get(_db);
    if (raw == null) return;
    try {
      final overrideDigest = _decodeLegacyProjectionOverrideDigest(
        raw,
        expectedKind: kind,
        expectedAccountScopeDigest: _accountScopeDigest,
      );
      if (overrideDigest != projection.digest) return;
    } on Object {
      return;
    }

    // Applying before consuming the marker makes a crash retryable: a marker
    // is never lost until its exact accepted projection reaches the sink.
    await sink.apply(projection);
    await _db.transaction((transaction) async {
      final currentRaw = await record.get(transaction);
      if (currentRaw == null) return;
      try {
        final overrideDigest = _decodeLegacyProjectionOverrideDigest(
          currentRaw,
          expectedKind: kind,
          expectedAccountScopeDigest: _accountScopeDigest,
        );
        if (overrideDigest == projection.digest) {
          await record.delete(transaction);
        }
      } on Object {
        // Invalid or foreign markers are never consumed by a successful
        // materialization for this account.
      }
    });
  }

  Future<bool> _projectIfNeeded(
    Episode episode,
    String fingerprint, {
    bool forceGovernedProjection = false,
  }) async {
    final id = episode.id;
    if (id == null || episode.reviewState != EpisodeReviewState.accepted) {
      return false;
    }
    var governance = await MemoryGovernanceStores.episodeGovernance
        .record(id)
        .get(_db);
    if (governance == null || governance['current'] != true) return false;
    Map<String, Object?> currentGovernance = governance;
    final governedProjectionKind = currentGovernance['governedProjectionKind'];

    await Future<void>.sync(
      () => _faultInjector?.call(
        MemoryWriteFaultPoint.beforeProjection,
        fingerprint,
      ),
    );
    if (governedProjectionKind is String) {
      return _materializeGovernedProjectionKind(
        governedProjectionKind,
        force: forceGovernedProjection,
      );
    }

    if (!await _episodeStore.isRecallEligible(episode)) return false;
    _episodeStore.scheduleEmbedding(episode);

    if (currentGovernance['projectionLinkComplete'] != true) {
      try {
        await _linkEpisode(episode);
        currentGovernance = await _markProjection(id, 'projectionLinkComplete');
      } catch (_) {
        // A later exact replay retries only the missing derived projection.
      }
    }
    if (currentGovernance['projectionMilestoneComplete'] != true) {
      if (currentGovernance['claimSlotFingerprint'] != null) {
        currentGovernance = await _markProjection(
          id,
          'projectionMilestoneComplete',
          skippedReason: 'mutable_claim',
        );
      } else {
        try {
          await _projectMilestone(episode);
          currentGovernance = await _markProjection(
            id,
            'projectionMilestoneComplete',
          );
        } catch (_) {
          // Primary memory stays durable and the receipt remains retryable.
        }
      }
    }
    return currentGovernance['projectionLinkComplete'] == true &&
        currentGovernance['projectionMilestoneComplete'] == true;
  }

  Future<Map<String, Object?>> _markProjection(
    int id,
    String field, {
    String? skippedReason,
  }) async {
    final now = _clock().toUtc().millisecondsSinceEpoch;
    await MemoryGovernanceStores.episodeGovernance
        .record(id)
        .update(_db, <String, Object?>{
          field: true,
          'projectionMilestoneSkippedReason': ?skippedReason,
          'updatedAt': now,
        });
    return await MemoryGovernanceStores.episodeGovernance.record(id).get(_db) ??
        const <String, Object?>{};
  }

  Future<void> _projectLegacy(Episode episode) async {
    try {
      await _linkEpisode(episode);
    } catch (_) {}
    try {
      await _projectMilestone(episode);
    } catch (_) {}
  }

  Future<void> _linkEpisode(Episode episode) {
    final override = _linkEpisodeOverride;
    if (override != null) return override(episode);
    final service = appServices.maybeFind<EntangledMemoryService>();
    return service?.linkEpisode(episode) ?? Future<void>.value();
  }

  Future<void> _removeEpisodeLinks(int episodeId) {
    final override = _removeEpisodeLinksOverride;
    if (override != null) return override(episodeId);
    final service = appServices.maybeFind<EntangledMemoryService>();
    return service?.removeEpisodeLinks(episodeId) ?? Future<void>.value();
  }

  Future<void> _projectMilestone(Episode episode) {
    final override = _projectMilestoneOverride;
    if (override != null) return override(episode);
    final service = appServices.maybeFind<RelationshipService>();
    return service?.maybeAutoMilestoneFromEpisode(episode) ??
        Future<void>.value();
  }

  Future<void> _markNotCurrent(
    DatabaseClient transaction,
    int episodeId,
    DateTime now,
  ) async {
    final record = MemoryGovernanceStores.episodeGovernance.record(episodeId);
    final existing = await record.get(transaction);
    if (existing == null ||
        existing['accountScopeDigest'] != _accountScopeDigest) {
      return;
    }
    await record.put(transaction, <String, Object?>{
      ...existing,
      'current': false,
      'updatedAt': now.millisecondsSinceEpoch,
    });
  }

  Map<String, Object?> _dedupRow({
    required String fingerprint,
    required Episode episode,
    required DateTime now,
  }) => <String, Object?>{
    'schemaVersion': 1,
    'accountScopeDigest': _accountScopeDigest,
    'fingerprint': fingerprint,
    'episodeId': episode.id,
    'reviewState': episode.reviewState.name,
    'writtenAt': now.millisecondsSinceEpoch,
  };

  Future<void> _appendAudit({
    required FeatureRolloutMode mode,
    required MemoryWriteDisposition disposition,
    required String? reason,
    required String? exactFingerprint,
    required String? semanticFingerprint,
    required int? episodeId,
    required bool created,
    EpisodeSourceRef? sourceRef,
  }) => _db.transaction(
    (transaction) => _writeAuditInTransaction(
      transaction,
      mode: mode,
      disposition: disposition,
      reason: reason,
      exactFingerprint: exactFingerprint,
      semanticFingerprint: semanticFingerprint,
      episodeId: episodeId,
      created: created,
      sourceRef: sourceRef,
    ),
  );

  Future<void> _writeAuditInTransaction(
    DatabaseClient transaction, {
    required FeatureRolloutMode mode,
    required MemoryWriteDisposition disposition,
    required String? reason,
    required String? exactFingerprint,
    required String? semanticFingerprint,
    required int? episodeId,
    required bool created,
    EpisodeSourceRef? sourceRef,
  }) => MemoryGovernanceStores.audit
      .add(transaction, <String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': _accountScopeDigest,
        'mode': mode.name,
        'disposition': disposition.name,
        'reason': reason,
        'exactFingerprint': exactFingerprint,
        'semanticFingerprint': semanticFingerprint,
        'episodeId': episodeId,
        'created': created,
        'sourceRef': sourceRef?.toJson(),
        'writtenAt': _clock().toUtc().millisecondsSinceEpoch,
      })
      .then<void>((_) {});

  String _exactFingerprint(
    MemoryWriteDraft draft,
    EpisodeSourceRef source,
    DateTime when,
  ) => _digest(
    jsonEncode(<String, Object?>{
      'domain': 'memory-exact-v2',
      'kind': draft.kind.name,
      'what': draft.what,
      'entities': (draft.entities.map(_normalizeForFingerprint).toList()
        ..sort()),
      'emotion': _normalizeForFingerprint(draft.emotion ?? ''),
      'salience': draft.salience,
      'retentionClass': draft.retentionClass.name,
      'when': when.toUtc().toIso8601String(),
      'claimSlot': _normalizeForFingerprint(draft.claimSlot ?? ''),
      'claimValue': draft.claimValue ?? '',
      if (draft.projection != null) ...<String, Object?>{
        'projectionKind': draft.projection!.kind,
        'projectionDigest': draft.projection!.digest,
      },
      'sourceId': source.sourceId,
      'sourceHash': source.contentHash,
    }),
  );

  String _semanticFingerprint(MemoryWriteDraft draft, DateTime when) {
    final day = when.toUtc().toIso8601String().substring(0, 10);
    return _digest(
      jsonEncode(<String, Object?>{
        'domain': 'memory-semantic-v2',
        'kind': draft.kind.name,
        // Host-accepted assertions and verified claim values can contain
        // case/whitespace-sensitive identifiers. Public model drafts are
        // already normalized by MemoryWriteDraft, so verbatim keys retain
        // useful semantic dedup there without merging distinct credentials.
        'what': draft.what,
        'entities': (draft.entities.map(_normalizeForFingerprint).toList()
          ..sort()),
        'claimSlot': _normalizeForFingerprint(draft.claimSlot ?? ''),
        'claimValue': draft.claimValue ?? '',
        if (draft.projection != null) ...<String, Object?>{
          'projectionKind': draft.projection!.kind,
          'projectionDigest': draft.projection!.digest,
        },
        if (draft.claimSlot == null) 'day': day,
      }),
    );
  }

  FeatureRolloutMode _effectiveMode() {
    final override = _memoryV2ModeOverride;
    if (override != null) return override();
    return appServices.maybeFind<MaasoFeatureFlagService>()?.effectiveMode(
          MaasoFeatureFlag.memoryV2,
        ) ??
        FeatureRolloutMode.off;
  }

  _PersistedChatSourceScope? get _currentSourceScope {
    final value = Zone.current[_sourceZoneKey];
    if (value is! _PersistedChatSourceScope || !value.isCurrentFor(this)) {
      return null;
    }
    return value;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_retiring || isClosed) {
      return Future<T>.error(StateError('memory_write_coordinator_retired'));
    }
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

  @override
  void onClose() {
    _retiring = true;
    super.onClose();
  }
}

final class _CommittedGovernanceMutation {
  const _CommittedGovernanceMutation({
    required this.action,
    required this.previousEpisodeId,
    required this.episode,
    required this.exactFingerprint,
    required this.governedProjectionKind,
  });

  final MemoryGovernanceAction action;
  final int previousEpisodeId;
  final Episode episode;
  final String exactFingerprint;
  final String? governedProjectionKind;
}

final class _PersistedChatSourceScope {
  _PersistedChatSourceScope({
    required this.owner,
    required this.messageRecordId,
    required this.sessionId,
    required this.agentId,
  });

  final MemoryWriteCoordinator owner;
  final int messageRecordId;
  final String sessionId;
  final String agentId;
  bool active = true;

  bool isCurrentFor(MemoryWriteCoordinator candidate) =>
      active && identical(owner, candidate);
}

final class _ResolvedMemorySource {
  const _ResolvedMemorySource({
    required this.ref,
    required this.agentId,
    required this.sourceType,
    this.chatMessage,
  });

  final EpisodeSourceRef ref;
  final String agentId;
  final EpisodeSourceType sourceType;
  final ChatMessage? chatMessage;
}

final class _ReviewDecision {
  const _ReviewDecision._({
    required this.disposition,
    required this.reviewState,
    required this.sourceType,
    required this.confidence,
    required this.reason,
  });

  const _ReviewDecision.accepted({
    required EpisodeSourceType sourceType,
    required double confidence,
    required String reason,
  }) : this._(
         disposition: MemoryWriteDisposition.accepted,
         reviewState: EpisodeReviewState.accepted,
         sourceType: sourceType,
         confidence: confidence,
         reason: reason,
       );

  const _ReviewDecision.quarantined({
    required EpisodeSourceType sourceType,
    required double confidence,
    required String reason,
  }) : this._(
         disposition: MemoryWriteDisposition.quarantined,
         reviewState: EpisodeReviewState.pending,
         sourceType: sourceType,
         confidence: confidence,
         reason: reason,
       );

  const _ReviewDecision.rejected({
    required EpisodeSourceType sourceType,
    required String reason,
  }) : this._(
         disposition: MemoryWriteDisposition.rejected,
         reviewState: EpisodeReviewState.rejected,
         sourceType: sourceType,
         confidence: 0,
         reason: reason,
       );

  final MemoryWriteDisposition disposition;
  final EpisodeReviewState reviewState;
  final EpisodeSourceType sourceType;
  final double confidence;
  final String reason;
}

final class _CommittedMemory {
  const _CommittedMemory({
    required this.disposition,
    required this.episode,
    required this.created,
    required this.exactFingerprint,
    required this.semanticFingerprint,
    this.reason,
  });

  const _CommittedMemory.rejected(String reason)
    : this(
        disposition: MemoryWriteDisposition.rejected,
        episode: null,
        created: false,
        exactFingerprint: null,
        semanticFingerprint: null,
        reason: reason,
      );

  factory _CommittedMemory.duplicate(
    Episode episode, {
    required String exactFingerprint,
    required String semanticFingerprint,
  }) => _CommittedMemory(
    disposition: MemoryWriteDisposition.duplicate,
    episode: episode,
    created: false,
    exactFingerprint: exactFingerprint,
    semanticFingerprint: semanticFingerprint,
  );

  final MemoryWriteDisposition disposition;
  final Episode? episode;
  final bool created;
  final String? exactFingerprint;
  final String? semanticFingerprint;
  final String? reason;
}

final class _ShadowEvaluation {
  const _ShadowEvaluation({
    required this.disposition,
    required this.reason,
    this.exactFingerprint,
    this.semanticFingerprint,
    this.sourceRef,
  });

  final MemoryWriteDisposition disposition;
  final String? reason;
  final String? exactFingerprint;
  final String? semanticFingerprint;
  final EpisodeSourceRef? sourceRef;
}

MemoryWriteDraft _governedDraftForWrite(
  MemoryWriteDraft draft, {
  required MemoryWriteAuthority authority,
  required _ReviewDecision decision,
  required String? sourceText,
}) {
  if (authority != MemoryWriteAuthority.automaticConversation ||
      decision.disposition != MemoryWriteDisposition.accepted) {
    return draft;
  }
  final assertion = sourceText == null
      ? ''
      : _memoryAssertionForStorage(sourceText);
  if (assertion.isEmpty) {
    throw StateError('accepted_automatic_source_missing_assertion');
  }
  if (assertion.runes.length > _maxAutomaticAcceptedAssertionLength) {
    throw StateError('accepted_automatic_source_assertion_too_long');
  }
  return MemoryWriteDraft._acceptedSourceAssertion(
    what: assertion,
    when: draft.when,
    // Model metadata cannot become an accepted fact. Importance and retention
    // are Host policy, while entities/emotion stay absent until a trusted Host
    // extractor can derive them from the durable source.
    salience: 0.7,
    retentionClass: EpisodeRetentionClass.durable,
  );
}

const int _maxAutomaticAcceptedAssertionLength = 4096;

List<GovernedMemoryProjectionFamilySink> _validatedProjectionFamilies(
  List<GovernedMemoryProjectionFamilySink> families,
) {
  final prefixes = <String>{};
  for (final family in families) {
    if (family.projectionKindPrefix != 'conversation.fact.' ||
        !prefixes.add(family.projectionKindPrefix)) {
      throw ArgumentError(
        'unsupported or duplicate governed projection family',
      );
    }
  }
  return List.unmodifiable(families);
}

final class _FamilyProjectionSink implements GovernedMemoryProjectionSink {
  const _FamilyProjectionSink(this.family, this.projectionKind);
  final GovernedMemoryProjectionFamilySink family;
  @override
  final String projectionKind;
  @override
  void validateProjection(GovernedMemoryProjectionDraft projection) {
    if (projection.kind != projectionKind) {
      throw const FormatException('projection family kind mismatch');
    }
    family.validateProjection(projection);
  }

  @override
  Future<void> apply(GovernedMemoryProjectionRecord record) =>
      family.apply(record);
  @override
  Future<void> clear() => family.clear(projectionKind);
}

Map<String, GovernedMemoryProjectionSink> _indexProjectionSinks(
  List<GovernedMemoryProjectionSink> sinks,
) {
  final indexed = <String, GovernedMemoryProjectionSink>{};
  for (final sink in sinks) {
    final kind = sink.projectionKind;
    GovernedMemoryProjectionDraft(
      kind: kind,
      payload: const <String, Object?>{},
    );
    if (indexed.containsKey(kind)) {
      throw ArgumentError.value(kind, 'governedProjectionSinks', 'duplicate');
    }
    indexed[kind] = sink;
  }
  return Map<String, GovernedMemoryProjectionSink>.unmodifiable(indexed);
}

String _decodeLegacyProjectionOverrideDigest(
  Object? source, {
  required String expectedKind,
  required String expectedAccountScopeDigest,
}) {
  if (source is! Map) {
    throw const FormatException('legacy projection override is invalid');
  }
  final row = Map<String, Object?>.from(source);
  final writtenAt = row['writtenAt'];
  final rolloutMode = row['rolloutMode'];
  if (row.length != 6 ||
      row['schemaVersion'] != 1 ||
      row['accountScopeDigest'] != expectedAccountScopeDigest ||
      row['kind'] != expectedKind ||
      row['digest'] is! String ||
      (rolloutMode != FeatureRolloutMode.off.name &&
          rolloutMode != FeatureRolloutMode.shadow.name) ||
      writtenAt is! int ||
      writtenAt < 0) {
    throw const FormatException('legacy projection override is invalid');
  }
  final digest = row['digest']! as String;
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
    throw const FormatException('legacy projection override is invalid');
  }
  return digest;
}

bool _isRevokedLegacyProjectionOverride(
  Object? source, {
  required String expectedKind,
  required String expectedAccountScopeDigest,
}) {
  if (source is! Map) return false;
  final row = Map<String, Object?>.from(source);
  final digest = row['digest'];
  final writtenAt = row['writtenAt'];
  return row.length == 6 &&
      row['schemaVersion'] == 1 &&
      row['accountScopeDigest'] == expectedAccountScopeDigest &&
      row['kind'] == expectedKind &&
      digest is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) &&
      row['rolloutMode'] == 'revoked' &&
      writtenAt is int &&
      writtenAt >= 0;
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

String _normalizeSummary(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _normalizeForFingerprint(String value) =>
    _normalizeSummary(value).toLowerCase();

String? _optionalNormalized(String? value) {
  if (value == null) return null;
  final normalized = _normalizeSummary(value);
  return normalized.isEmpty ? null : normalized;
}

List<String> _normalizeEntities(List<String> values) {
  final normalized = values
      .map(_normalizeSummary)
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
  normalized.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return normalized;
}

bool _isExplicitRememberRequest(String value) {
  return _extractExplicitMemoryAssertion(value) != null;
}

bool _isExplicitNoSaveRequest(String value, {bool structuredProposal = false}) {
  final normalized = _normalizeForFingerprint(value);
  final explicitDenial = RegExp(
    r"(?:请|麻烦|帮我|请帮我)?\s*(?:不要|别|无需|不用|不必|禁止)\s*(?:(?:再|长期|永久|持久|一直|长期地|永久地)\s*)*(?:记住|记得|保存|存下|保留|记录|存储|持久化|留存|写入\s*记忆)|\b(?:please\s+)?(?:do\s+not|don't|don’t|never)\s+(?:(?:permanently|long[- ]term)\s+)?(?:remember|save|store|record|keep|persist|retain)\b",
    caseSensitive: false,
  ).hasMatch(normalized);
  if (explicitDenial) return true;
  final explicitEphemeralCommand = RegExp(
    r'^(?:(?:请|麻烦|帮我|请帮我)\s*)?(?:(?:临时|暂时|短期)\s*(?:记住|记得|保存|存下|保留|记录|存储|写入\s*记忆)|(?:(?:只|仅)(?:在|限于)?\s*)?(?:本次|当前|这个|本轮|这轮)\s*(?:会话|对话|轮次|回合)(?:期间|内)?[，,、:：\s]*(?:记住|记得|保存|存下|保留|记录|存储))|^(?:please\s+)?(?:temporarily|for\s+now|only\s+for\s+(?:this|the\s+current)\s+(?:turn|session|chat|conversation)|(?:during|for)\s+(?:only\s+)?(?:this|current|the\s+current|the)\s+(?:turn|session|chat|conversation))[,\s]+(?:remember|save|store|record|keep|persist|retain)\b',
    caseSensitive: false,
  ).hasMatch(normalized);
  if (explicitEphemeralCommand) return true;
  if (!structuredProposal && _extractExplicitMemoryAssertion(value) == null) {
    return false;
  }
  final unsupportedRetentionMarkers = <RegExp>[
    RegExp(
      r'(?:只|仅)\s*(?:临时|暂时)?\s*(?:记住|记得|保存|存下|保留|记录)|(?:临时|暂时|短期)\s*(?:记住|记得|保存|存下|保留|记录)?',
    ),
    RegExp(
      r'(?:记住|记得|保存|存下|保留|记录).{0,24}?(?:\d+|半|[一二三四五六七八九十百两]+)\s*(?:秒钟?|分钟|小时|天|周|个月|月)',
    ),
    RegExp(
      r'(?:过\s*)?(?:\d+|半|[一二三四五六七八九十百两]+)\s*(?:秒钟?|分钟|小时|天|周|个月|月)(?:之)?后.{0,12}?(?:忘掉|忘记|删掉|删除|清除)',
    ),
    RegExp(r'(?:到|直到|直至|截至)\s*(?:现在|目前|当下|今天|今日|今晚|明天|后天|下次|会话结束|本次会话结束)'),
    RegExp(
      r'(?:只|仅)?.{0,8}(?:本次|这次|当前|这个|本轮|这轮)\s*(?:会话|对话|轮次|回合)|(?:本次|这次|当前|这个|本轮|这轮)?\s*(?:会话|对话|轮次|回合)(?:结束)?后\s*(?:忘掉|忘记|删掉|删除|清除)',
    ),
    RegExp(
      r'(?:只|仅)(?:限|在|到)?\s*(?:现在|目前|当下|今天|今日|(?:本次|这次|当前|这个|本轮|这轮)\s*(?:会话|对话|轮次|回合))|(?:本次|这次|当前|这个|本轮|这轮)\s*(?:会话|对话|轮次|回合)\s*(?:期间|内)',
    ),
    RegExp(
      r'\b(?:temporarily|temporary|short[- ]term)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\bfor\s+(?:the\s+next\s+)?(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|a|an)\s+(?:seconds?|minutes?|hours?|days?|weeks?|months?)\b',
      caseSensitive: false,
    ),
    RegExp(r'\buntil\b', caseSensitive: false),
    RegExp(
      r'\b(?:after|in)\s+(?:the\s+next\s+)?(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|a|an)\s+(?:seconds?|minutes?|hours?|days?|weeks?|months?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:for\s+now|today\s+only|only\s+(?:for\s+)?today|only\s+for\s+(?:this|the\s+current)\s+(?:turn|session|chat|conversation)|(?:during|for)\s+(?:only\s+)?(?:this|the\s+current|the)\s+(?:turn|session|chat|conversation)|(?:this|the\s+current)\s+(?:turn|session|chat|conversation)\s+only)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:forget|delete|clear)\b.{0,24}\b(?:after|when)\b.{0,24}\bsession\b',
      caseSensitive: false,
    ),
  ];
  return unsupportedRetentionMarkers.any(
    (marker) => marker.hasMatch(normalized),
  );
}

bool _proposalIsGrounded(MemoryWriteDraft draft, String sourceText) {
  final sourceAssertion = _memoryAssertionText(sourceText);
  if (_looksInterrogative(sourceAssertion) ||
      !_preservesSourceQualifiers(sourceAssertion, draft.what)) {
    return false;
  }
  final sourceSequence = _evidenceSequence(sourceAssertion);
  if (sourceSequence.isEmpty) return false;
  final sourceTokens = sourceSequence.toSet();
  final sourceHasNegation = _hasSemanticNegation(sourceAssertion);
  final proposalHasNegation = _hasSemanticNegation(draft.what);
  if (sourceHasNegation != proposalHasNegation) return false;
  final claimValue = draft.claimValue;
  if (claimValue != null) {
    final valueSequence = _evidenceSequence(claimValue);
    final valueTokens = valueSequence.toSet();
    if (valueTokens.isEmpty ||
        !_isOrderedSubsequence(valueSequence, sourceSequence) ||
        valueTokens.intersection(sourceTokens).length / valueTokens.length <
            0.8) {
      return false;
    }
  }
  final proposalSequence = _evidenceSequence(draft.what);
  final proposalTokens = proposalSequence.toSet();
  if (proposalTokens.isEmpty) return false;
  if (!_isOrderedSubsequence(proposalSequence, sourceSequence)) return false;
  final shared = proposalTokens.intersection(sourceTokens);
  final coverage = shared.length / proposalTokens.length;
  if (coverage < (sourceHasNegation ? 0.8 : 0.5)) return false;
  if (shared.length / sourceTokens.length < 0.5) return false;
  for (final entity in draft.entities) {
    if (!_metadataValueIsGrounded(entity, sourceSequence)) return false;
  }
  final emotion = draft.emotion;
  if (emotion != null && !_metadataValueIsGrounded(emotion, sourceSequence)) {
    return false;
  }
  final claimSlot = draft.claimSlot;
  if (claimSlot != null &&
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(claimSlot)) {
    return false;
  }
  return shared.length >= 2 ||
      shared.any((token) => RegExp(r'^[a-z0-9]{3,}$').hasMatch(token));
}

bool _metadataValueIsGrounded(String value, List<String> sourceSequence) {
  final normalized = _normalizeForFingerprint(value);
  final sequence = _evidenceSequence(normalized);
  if (sequence.isEmpty) {
    return const <String>{'我', '用户', 'user', 'self'}.contains(normalized);
  }
  return _isOrderedSubsequence(sequence, sourceSequence);
}

bool _looksInterrogative(String value) {
  final normalized = _normalizeForFingerprint(value);
  return normalized.contains('?') ||
      normalized.contains('？') ||
      RegExp(r'(?:吗|么|是否|是不是)(?:[。.!！]?$)').hasMatch(normalized);
}

bool _preservesSourceQualifiers(String source, String proposal) {
  final normalizedSource = _normalizeForFingerprint(source);
  final normalizedProposal = _normalizeForFingerprint(proposal);
  final qualifierClasses = <RegExp>[
    RegExp(
      r'(?:说|告诉|听说|据说|转述|声称|提到|说法)|\b(?:say|says|said|tell|tells|told|heard|according|claim|claims|claimed|reported)\b',
    ),
    RegExp(
      r'(?:猜|可能|也许|或许|大概|似乎|好像|不确定)|\b(?:guess|think|believe|maybe|might|may|possibly|probably|seem|seems|appears|unsure|uncertain)\b',
    ),
    RegExp(
      r'(?:如果|假如|倘若|除非|条件|前提)|\b(?:if|unless|conditional|condition|provided)\b',
    ),
    RegExp(
      r'(?:计划|打算|准备|希望|想要|将会)|\b(?:plan|plans|planned|intend|intends|hope|hopes|want|wants|will)\b',
    ),
  ];
  for (final qualifierClass in qualifierClasses) {
    if (qualifierClass.hasMatch(normalizedSource) &&
        !qualifierClass.hasMatch(normalizedProposal)) {
      return false;
    }
  }
  return true;
}

String _memoryAssertionText(String value) {
  return _normalizeForFingerprint(_memoryAssertionForStorage(value));
}

String _memoryAssertionForStorage(String value) {
  return _extractExplicitMemoryAssertion(value) ?? '';
}

String? _extractExplicitMemoryAssertion(String value) {
  final source = value.trim();
  if (source.isEmpty) return null;
  final chinese = RegExp(
    r'^(?:(?:请帮我|请|麻烦|帮我|务必|一定要)?\s*(?:不要忘记|别忘记|别忘了|记住)|(?:请帮我|请|麻烦|帮我|务必|一定要)?\s*(?:保存|存下|记录|写入)\s*(?:到|进|在)?\s*(?:长期)?\s*记忆(?:里|中)?)\s*(?:一下|这件事|这条信息)?\s*[:：，,]?\s*',
    caseSensitive: false,
  ).firstMatch(source);
  final english = RegExp(
    r"^(?:(?:please\s+)?(?:remember\b(?:\s+that\b)?|(?:save|store|record)\s+(?:(?:this|the\s+following)\s+)?(?:fact|detail|preference|memory)\b|(?:save|store|record)\s+(?:this\s+)?(?:to|in)\s+(?:my\s+|long[- ]term\s+)?memory\b|do\s+not\s+forget\b(?:\s+that\b)?|don't\s+forget\b(?:\s+that\b)?))\s*[:,-]?\s*",
    caseSensitive: false,
  ).firstMatch(source);
  final match = chinese ?? english;
  if (match == null) return null;
  final assertion = source.substring(match.end).trim();
  return assertion.isEmpty ? null : assertion;
}

bool _hasSemanticNegation(String value) {
  final normalized = _normalizeForFingerprint(value);
  return RegExp(
    r"(?:不|没|无|未|并非|并不|从不)|\b(?:no|not|never|without|cannot|can't|won't|isn't|aren't|wasn't|weren't|doesn't|don't|didn't)\b",
    caseSensitive: false,
  ).hasMatch(normalized);
}

bool _isOrderedSubsequence(List<String> needle, List<String> haystack) {
  if (needle.isEmpty) return false;
  var needleIndex = 0;
  for (final token in haystack) {
    if (token != needle[needleIndex]) continue;
    needleIndex++;
    if (needleIndex == needle.length) return true;
  }
  return false;
}

List<String> _evidenceSequence(String value) {
  const stopWords = <String>{
    '请',
    '帮',
    '我',
    '你',
    '他',
    '她',
    '它',
    '的',
    '是',
    '这',
    '条',
    '用户',
    '用',
    '户',
    '记',
    '住',
    '记住',
    'remember',
    'that',
    'this',
    'user',
    'my',
    'is',
    'the',
    'a',
  };
  final normalized = _normalizeForFingerprint(value);
  final tokens = <String>[];
  for (final match in RegExp(r'[a-z0-9]+|[㐀-鿿]').allMatches(normalized)) {
    final token = match.group(0)!;
    if (!stopWords.contains(token)) tokens.add(token);
  }
  return tokens;
}

void _requireBounded(String value, String field, {required int maxLength}) {
  if (value.isEmpty || value.trim() != value || value.length > maxLength) {
    throw ArgumentError.value(
      value,
      field,
      'must be non-empty, trimmed, and at most $maxLength characters',
    );
  }
}
