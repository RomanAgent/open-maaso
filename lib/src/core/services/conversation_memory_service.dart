import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/governed_memory_projection.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:sembast/sembast.dart';

/// Account-owned, source-bound read model. Every fact is a separate reviewed
/// claim; immediate turn preferences remain in ConversationStyleSession.
final class ConversationMemoryService extends AppService
    implements GovernedMemoryProjectionFamilySink {
  ConversationMemoryService({
    required Database database,
    required String accountScopeDigest,
    this.agentId = 'self',
    FeatureRolloutMode Function()? memoryV2Mode,
  }) : _database = database,
       _accountScopeDigest = accountScopeDigest,
       _memoryV2Mode = memoryV2Mode {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest) ||
        agentId.isEmpty ||
        agentId.length > 256) {
      throw ArgumentError('invalid conversation memory account or agent');
    }
  }

  static const int maxWatchedSources = 256;
  final Database _database;
  final String _accountScopeDigest;
  final String agentId;
  final FeatureRolloutMode Function()? _memoryV2Mode;
  MemoryWriteCoordinator? _coordinator;
  final state = Rx<ConversationPolicy>(
    ConversationPolicy.fromFacts(const [], policyVersion: 0),
  );
  final _facts = <String, ConversationFact>{};
  final _sources = <String, EpisodeSourceRef>{};
  final _subscriptions = <String, StreamSubscription<Object?>>{};
  final _invalidated = <String>{};
  final _deadSources = <String>{};
  final _invalidatedFacts = <String, Set<String>>{};
  Set<String> _rebuildingDurableSourceIds = const {};
  Future<void> _tail = Future<void>.value();
  bool _retiring = false;
  bool _batching = false;
  bool _forcePublishPending = false;
  bool _needsRehydrate = true;
  int _version = 0;
  String _publishedSignature = '[]';

  List<ConversationFact> get facts => List.unmodifiable(_facts.values);
  int get policyVersion => _version;
  Set<String> get invalidatedSourceIds => Set.unmodifiable(_invalidated);
  Map<String, Set<String>> get invalidatedFactSources => Map.unmodifiable({
    for (final entry in _invalidatedFacts.entries)
      entry.key: Set<String>.unmodifiable(entry.value),
  });

  void bindGovernance(MemoryWriteCoordinator coordinator) {
    if (_coordinator != null && !identical(_coordinator, coordinator)) {
      throw StateError('conversation memory already bound');
    }
    _coordinator = coordinator;
  }

  FeatureRolloutMode get _mode =>
      _memoryV2Mode?.call() ??
      _coordinator?.rolloutMode ??
      FeatureRolloutMode.off;

  @override
  String get projectionKindPrefix => 'conversation.fact.';

  String _kindFor(ConversationFactDraft draft) =>
      '$projectionKindPrefix${sha256.convert(utf8.encode('$agentId:${draft.slotKey}')).toString().substring(0, 32)}';

  @override
  bool acceptsProjectionKind(String kind) =>
      RegExp(r'^conversation\.fact\.[a-f0-9]{32}$').hasMatch(kind);

  ConversationFactDraft _decode(GovernedMemoryProjectionDraft projection) {
    final payload = projection.payload;
    if (!acceptsProjectionKind(projection.kind) ||
        payload.length != 4 ||
        payload['schemaVersion'] != 1 ||
        payload['agentId'] != agentId ||
        payload['fact'] is! Map ||
        payload['supportingSources'] is! List) {
      throw const FormatException('invalid conversation projection');
    }
    final draft = ConversationFactDraft.fromJson(
      Map<String, Object?>.from(payload['fact']! as Map),
    );
    if (_kindFor(draft) != projection.kind) {
      throw const FormatException('conversation slot does not match kind');
    }
    final refs = (payload['supportingSources']! as List)
        .map(EpisodeSourceRef.fromJson)
        .toList();
    if (refs.length > 7 ||
        refs.map((ref) => ref.sourceId).toSet().length != refs.length ||
        refs.any(
          (ref) =>
              ref.origin != EpisodeSourceOrigin.user &&
              ref.origin != EpisodeSourceOrigin.agent,
        )) {
      throw const FormatException('invalid conversation supporting sources');
    }
    return draft;
  }

  @override
  void validateProjection(GovernedMemoryProjectionDraft projection) {
    _decode(projection);
  }

  @override
  List<EpisodeSourceRef> supportingSources(
    GovernedMemoryProjectionDraft projection,
  ) {
    _decode(projection);
    return List.unmodifiable(
      (projection.payload['supportingSources']! as List).map(
        EpisodeSourceRef.fromJson,
      ),
    );
  }

  /// Only the coordinator's still-live persisted-human source zone can supply
  /// text. A caller cannot pass a model assertion or a fabricated transcript.
  Future<String?> observeCurrentTurn() => _enqueue(() async {
    final coordinator = _coordinator;
    if (coordinator == null) return null;
    final current = await coordinator.currentPersistedUserSource();
    if (current == null || current.agentId != agentId || _retiring) return null;
    _watch(current.reference);
    try {
      if (_mode == FeatureRolloutMode.off ||
          await coordinator.currentSourceStructuredPersistenceRejection() !=
              null) {
        return current.reference.sourceId;
      }
      final history = await coordinator.recentConversationSources(
        sessionId: current.reference.sessionId,
        agentId: agentId,
        before: current.timestamp,
      );
      final proposals = extractConversationFacts(
        userText: current.text,
        history: [
          for (final item in history)
            ConversationEvidenceMessage(
              text: item.text,
              isUser: item.reference.origin == EpisodeSourceOrigin.user,
              source: item.reference,
              turnId: item.turnId,
            ),
        ],
        acceptedFacts: facts,
      );
      for (final proposal in proposals.take(16)) {
        if (_retiring) break;
        final kind = _kindFor(proposal.draft);
        final projection = GovernedMemoryProjectionDraft(
          kind: kind,
          payload: {
            'schemaVersion': 1,
            'agentId': agentId,
            'fact': proposal.draft.toJson(),
            'supportingSources': [
              for (final ref in proposal.supportingSources) ref.toJson(),
            ],
          },
        );
        validateProjection(projection);
        await coordinator.write(
          MemoryWriteDraft.claim(
            slot: kind,
            value: projection.canonicalPayload,
            summary: 'Conversation preference: ${proposal.draft.slotKey}',
            when: current.timestamp,
            projection: projection,
          ),
          authority: MemoryWriteAuthority.governedProposal,
        );
      }
    } catch (_) {
      // The source was verified independently. A candidate/storage failure
      // must not orphan the immediate lease attached to that real message.
      TurnTrace.event(
        'conversation.memory.proposal_failed',
        details: 'status=deferred',
      );
    }
    return current.reference.sourceId;
  });

  /// Rehydrate on mount or invalidation, then validate cached sources before
  /// use. Unchanged facts publish no new version and do not replay other sinks.
  Future<void> refresh() => _enqueue(() async {
    _batching = true;
    try {
      if (_mode != FeatureRolloutMode.enforce) {
        _facts.clear();
        _needsRehydrate = true;
      } else {
        final refs = <String, EpisodeSourceRef>{
          ..._sources,
          for (final fact in _facts.values)
            for (final ref in fact.sourceRefs) ref.sourceId: ref,
        };
        for (final ref in refs.values) {
          final id = _recordId(ref);
          final raw = id == null
              ? null
              : await MemoryGovernanceStores.chatMessages
                    .record(id)
                    .get(_database);
          if (!_matches(ref, raw)) _invalidate(ref.sourceId);
        }
        if (_needsRehydrate) {
          _rebuildingDurableSourceIds = _facts.values
              .expand((fact) => fact.sourceRefs)
              .map((ref) => ref.sourceId)
              .toSet();
          _facts.clear();
          _needsRehydrate = false;
          await _coordinator?.rehydrateGovernedProjections(
            familyPrefix: projectionKindPrefix,
          );
        }
      }
    } catch (_) {
      _facts.clear();
      _needsRehydrate = true;
      _batching = false;
      _publish(force: true);
      rethrow;
    } finally {
      _rebuildingDurableSourceIds = const {};
      _batching = false;
      _publish();
    }
  });

  @override
  Future<void> apply(GovernedMemoryProjectionRecord record) async {
    if (_retiring || _mode != FeatureRolloutMode.enforce) return;
    if (record.accountScopeDigest != _accountScopeDigest) {
      throw const FormatException('conversation projection account mismatch');
    }
    final draft = _decode(
      GovernedMemoryProjectionDraft(kind: record.kind, payload: record.payload),
    );
    final raw = await MemoryGovernanceStores.episodes
        .record(record.episodeId)
        .get(_database);
    if (raw == null) {
      throw const FormatException('conversation episode missing');
    }
    final episode = Episode.fromJson(raw);
    if (episode.agentId != agentId ||
        episode.reviewState != EpisodeReviewState.accepted ||
        episode.sourceRefs.isEmpty ||
        episode.sourceRefs.first.origin != EpisodeSourceOrigin.user) {
      throw const FormatException('conversation episode not accepted');
    }
    for (final ref in episode.sourceRefs) {
      final id = _recordId(ref);
      final message = id == null
          ? null
          : await MemoryGovernanceStores.chatMessages.record(id).get(_database);
      if (!_matches(ref, message) || _deadSources.contains(ref.sourceId)) {
        _invalidate(ref.sourceId);
        throw const FormatException('conversation source unavailable');
      }
    }
    if (_retiring) return;
    _facts[record.kind] = ConversationFact(
      draft: draft,
      episodeId: record.episodeId,
      revision: episode.revision,
      sourceRefs: episode.sourceRefs,
    );
    for (final ref in episode.sourceRefs) {
      _watch(ref);
    }
    _publish();
  }

  @override
  Future<void> clear(String kind) async {
    final removed = _facts.remove(kind);
    if (removed == null) return;
    _invalidatedFacts
        .putIfAbsent(removed.draft.slotKey, () => <String>{})
        .add(removed.currentUserSourceId);
    _publish(force: true);
  }

  void _watch(EpisodeSourceRef ref) {
    if (_retiring || _deadSources.contains(ref.sourceId)) return;
    final previous = _sources[ref.sourceId];
    if (previous != null) {
      if (previous.contentHash != ref.contentHash) _invalidate(ref.sourceId);
      return;
    }
    while (_sources.length >= maxWatchedSources) {
      // Prefer evicting an immediate-only lease, preserving accepted evidence.
      final durable = <String>{
        ..._rebuildingDurableSourceIds,
        ..._facts.values
            .expand((fact) => fact.sourceRefs)
            .map((ref) => ref.sourceId),
      };
      final oldest = _sources.keys.firstWhere(
        (id) => !durable.contains(id),
        orElse: () => _sources.keys.first,
      );
      _sources.remove(oldest);
      final subscription = _subscriptions.remove(oldest);
      if (subscription != null) unawaited(subscription.cancel());
      // A listener limit is not a revocation of accepted evidence. Active
      // sources outside this window are still validated in every refresh.
      if (!durable.contains(oldest) && _invalidated.add(oldest)) {
        _publish(force: true);
      }
    }
    final id = _recordId(ref);
    if (id == null) {
      _invalidate(ref.sourceId);
      return;
    }
    _sources[ref.sourceId] = ref;
    _subscriptions[ref.sourceId] = MemoryGovernanceStores.chatMessages
        .record(id)
        .onSnapshot(_database)
        .listen(
          (snapshot) {
            if (!_retiring && !_matches(ref, snapshot?.value)) {
              _invalidate(ref.sourceId);
              // Persist the invalidation marker via the sole writer. Do not
              // await inside apply(), which itself runs in that writer queue.
              unawaited(refresh().catchError((Object _) {}));
            }
          },
          onError: (Object _) {
            if (!_retiring) _invalidate(ref.sourceId);
          },
        );
  }

  void _invalidate(String sourceId) {
    final leaseChanged = _invalidated.add(sourceId);
    final sourceChanged = _deadSources.add(sourceId);
    _needsRehydrate = true;
    _sources.remove(sourceId);
    final subscription = _subscriptions.remove(sourceId);
    if (subscription != null) unawaited(subscription.cancel());
    _facts.removeWhere(
      (_, fact) => fact.sourceRefs.any((ref) => ref.sourceId == sourceId),
    );
    if (leaseChanged || sourceChanged) _publish(force: true);
  }

  int? _recordId(EpisodeSourceRef ref) {
    final match = RegExp(
      r'^chat_message:([1-9][0-9]*)$',
    ).firstMatch(ref.sourceId);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  bool _matches(EpisodeSourceRef ref, Map<String, Object?>? raw) {
    if (raw == null ||
        raw['sessionId'] != ref.sessionId ||
        raw['content'] is! String ||
        sha256.convert(utf8.encode(raw['content']! as String)).toString() !=
            ref.contentHash ||
        !ChatMessageTurnOrigins.humanAuthored.contains(raw['turnOrigin']) ||
        (raw['deliveryStatus'] != null &&
            raw['deliveryStatus'] != 'published')) {
      return false;
    }
    return switch (ref.origin) {
      EpisodeSourceOrigin.user =>
        raw['isUserMessage'] == true &&
            raw['senderId'] == 'user' &&
            raw['receiverId'] == agentId,
      EpisodeSourceOrigin.agent =>
        raw['isUserMessage'] == false &&
            raw['senderId'] == agentId &&
            raw['receiverId'] == 'user',
      _ => false,
    };
  }

  void _publish({bool force = false}) {
    if (_batching) {
      _forcePublishPending = _forcePublishPending || force;
      return;
    }
    force = force || _forcePublishPending;
    _forcePublishPending = false;
    final entries = _facts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final signature = jsonEncode([
      for (final entry in entries)
        [entry.key, entry.value.episodeId, entry.value.revision],
    ]);
    if (!force && signature == _publishedSignature) return;
    _publishedSignature = signature;
    state.value = ConversationPolicy.fromFacts(
      _facts.values,
      policyVersion: ++_version,
    );
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_retiring || isClosed) {
      return Future.error(StateError('conversation_memory_retired'));
    }
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> deactivateAndDrain() async {
    _retiring = true;
    final subscriptions = _subscriptions.values.toList();
    _subscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    await _tail;
    _sources.clear();
    _facts.clear();
    _publish(force: true);
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
