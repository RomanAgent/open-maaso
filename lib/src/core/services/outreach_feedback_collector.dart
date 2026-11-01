import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:sembast/sembast.dart';

const int _maximumStoredRevision = 0x1fffffffffffff;

enum OutreachFeedbackSignal {
  delivered,
  opened,
  responded,
  dismissed,
  ignored,
  muted,
}

enum OutreachFeedbackOutcome { responded, dismissed, ignored, muted }

enum OutreachResponseLatencyBucket {
  under1Minute,
  under5Minutes,
  under30Minutes,
  under2Hours,
  twoHoursOrMore,
}

/// Bounded storage policy for shadow outreach feedback.
///
/// Pending entries and ignored entries that are still inside their correction
/// grace are protected from count-based compaction. The compacted rollup keeps
/// only fixed-cardinality counters; digest-only markers suppress replay while
/// the matching ledger row is still retained.
final class OutreachFeedbackRetentionPolicy {
  const OutreachFeedbackRetentionPolicy({
    this.maxResolvedEntries = 256,
    this.maxResolvedAge = const Duration(days: 30),
    this.ignoredCorrectionGrace,
    this.maxMuteMarkers = 64,
    this.maxMuteAge = const Duration(days: 90),
  });

  final int maxResolvedEntries;
  final Duration maxResolvedAge;

  /// Additional correction horizon for ignored entries. Values shorter than
  /// the collector response window are raised to that response window.
  final Duration? ignoredCorrectionGrace;
  final int maxMuteMarkers;
  final Duration maxMuteAge;
}

enum OutreachFeedbackMutationResult {
  recorded,
  duplicate,
  noEligibleOutreach,
  disabled,
  retired,
  rejected,
  storageUnavailable,
}

enum _OutreachFeedbackLifecycle {
  created,
  initializing,
  active,
  degraded,
  retired,
}

/// Privacy-minimized feedback for one opaque outreach lifecycle.
///
/// The domain-separated digest [outreachId] is the Sembast record key. The raw
/// ledger id never leaves the ledger store, and the stored value never contains
/// a message body, topic, source event, account, locale, prompt, or exact
/// drive/timing score.
final class OutreachFeedbackEntry {
  const OutreachFeedbackEntry({
    required this.outreachId,
    required this.channel,
    required this.deliveredAt,
    this.openedAt,
    this.respondedAt,
    this.dismissedAt,
    this.ignoredAt,
    this.mutedAt,
  });

  static const int schemaVersion = 1;

  final String outreachId;
  final OutreachChannel channel;
  final DateTime deliveredAt;
  final DateTime? openedAt;
  final DateTime? respondedAt;
  final DateTime? dismissedAt;
  final DateTime? ignoredAt;
  final DateTime? mutedAt;

  DateTime get feedbackAnchorAt => openedAt ?? deliveredAt;

  Duration? get responseLatency {
    final response = respondedAt;
    if (response == null) return null;
    final latency = response.difference(feedbackAnchorAt);
    return latency.isNegative ? Duration.zero : latency;
  }

  OutreachFeedbackOutcome? get outcome {
    if (mutedAt != null) return OutreachFeedbackOutcome.muted;
    if (respondedAt != null) return OutreachFeedbackOutcome.responded;
    if (dismissedAt != null) return OutreachFeedbackOutcome.dismissed;
    if (ignoredAt != null) return OutreachFeedbackOutcome.ignored;
    return null;
  }

  DateTime? get outcomeAt => switch (outcome) {
    OutreachFeedbackOutcome.muted => mutedAt,
    OutreachFeedbackOutcome.responded => respondedAt,
    OutreachFeedbackOutcome.dismissed => dismissedAt,
    OutreachFeedbackOutcome.ignored => ignoredAt,
    null => null,
  };

  bool get awaitingFeedback => outcome == null;

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'channel': channel.name,
    'deliveredAt': _writeDate(deliveredAt),
    'openedAt': _writeOptionalDate(openedAt),
    'respondedAt': _writeOptionalDate(respondedAt),
    'dismissedAt': _writeOptionalDate(dismissedAt),
    'ignoredAt': _writeOptionalDate(ignoredAt),
    'mutedAt': _writeOptionalDate(mutedAt),
    'responseLatencyMs': responseLatency?.inMilliseconds,
  };

  factory OutreachFeedbackEntry.fromStorageJson(
    String outreachId,
    Map<String, Object?> json,
  ) {
    _validateOutreachId(outreachId);
    const fields = <String>{
      'schemaVersion',
      'channel',
      'deliveredAt',
      'openedAt',
      'respondedAt',
      'dismissedAt',
      'ignoredAt',
      'mutedAt',
      'responseLatencyMs',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException('outreach feedback fields are invalid');
    }
    final deliveredAt = _readDate(json['deliveredAt'], 'deliveredAt');
    final openedAt = _readOptionalDateAfter(
      json['openedAt'],
      'openedAt',
      deliveredAt,
    );
    final respondedAt = _readOptionalDateAfter(
      json['respondedAt'],
      'respondedAt',
      deliveredAt,
    );
    final dismissedAt = _readOptionalDateAfter(
      json['dismissedAt'],
      'dismissedAt',
      deliveredAt,
    );
    final ignoredAt = _readOptionalDateAfter(
      json['ignoredAt'],
      'ignoredAt',
      deliveredAt,
    );
    final mutedAt = _readOptionalDateAfter(
      json['mutedAt'],
      'mutedAt',
      deliveredAt,
    );
    final latency = json['responseLatencyMs'];
    if (openedAt != null &&
        respondedAt != null &&
        respondedAt.isBefore(openedAt)) {
      throw const FormatException('response predates open');
    }
    if ((respondedAt == null) != (latency == null) ||
        (latency != null &&
            (latency is! int ||
                latency < 0 ||
                latency > const Duration(days: 7).inMilliseconds))) {
      throw const FormatException('response latency is invalid');
    }
    if (respondedAt != null) {
      final expected = respondedAt
          .difference(openedAt ?? deliveredAt)
          .inMilliseconds;
      if (latency != (expected < 0 ? 0 : expected)) {
        throw const FormatException('response latency does not match events');
      }
    }
    final channelName = json['channel'];
    final channel = OutreachChannel.values.where(
      (candidate) => candidate.name == channelName,
    );
    if (channel.length != 1) {
      throw const FormatException('outreach feedback channel is invalid');
    }
    return OutreachFeedbackEntry(
      outreachId: outreachId,
      channel: channel.single,
      deliveredAt: deliveredAt,
      openedAt: openedAt,
      respondedAt: respondedAt,
      dismissedAt: dismissedAt,
      ignoredAt: ignoredAt,
      mutedAt: mutedAt,
    );
  }

  OutreachFeedbackEntry mergeDelivery({
    required OutreachChannel channel,
    required DateTime deliveredAt,
    DateTime? openedAt,
  }) {
    if (channel != this.channel) {
      throw StateError('outreach feedback channel changed');
    }
    final delivery = _earlier(this.deliveredAt, deliveredAt.toUtc());
    final open = _earlierOptional(this.openedAt, openedAt?.toUtc());
    return OutreachFeedbackEntry(
      outreachId: outreachId,
      channel: channel,
      deliveredAt: delivery,
      openedAt: open,
      respondedAt: respondedAt,
      dismissedAt: dismissedAt,
      ignoredAt: ignoredAt,
      mutedAt: mutedAt,
    );
  }

  OutreachFeedbackEntry record(OutreachFeedbackSignal signal, DateTime at) {
    final timestamp = at.toUtc();
    if (timestamp.isBefore(deliveredAt)) {
      throw StateError('feedback predates delivery');
    }
    return switch (signal) {
      OutreachFeedbackSignal.delivered => this,
      OutreachFeedbackSignal.opened => OutreachFeedbackEntry(
        outreachId: outreachId,
        channel: channel,
        deliveredAt: deliveredAt,
        openedAt: _earlierOptional(openedAt, timestamp),
        respondedAt: respondedAt,
        dismissedAt: dismissedAt,
        ignoredAt: ignoredAt,
        mutedAt: mutedAt,
      ),
      OutreachFeedbackSignal.responded => OutreachFeedbackEntry(
        outreachId: outreachId,
        channel: channel,
        deliveredAt: deliveredAt,
        openedAt: openedAt,
        respondedAt: _earlierOptional(respondedAt, timestamp),
        dismissedAt: dismissedAt,
        ignoredAt: ignoredAt,
        mutedAt: mutedAt,
      ),
      OutreachFeedbackSignal.dismissed => OutreachFeedbackEntry(
        outreachId: outreachId,
        channel: channel,
        deliveredAt: deliveredAt,
        openedAt: openedAt,
        respondedAt: respondedAt,
        dismissedAt: _earlierOptional(dismissedAt, timestamp),
        ignoredAt: ignoredAt,
        mutedAt: mutedAt,
      ),
      OutreachFeedbackSignal.ignored => OutreachFeedbackEntry(
        outreachId: outreachId,
        channel: channel,
        deliveredAt: deliveredAt,
        openedAt: openedAt,
        respondedAt: respondedAt,
        dismissedAt: dismissedAt,
        ignoredAt: _earlierOptional(ignoredAt, timestamp),
        mutedAt: mutedAt,
      ),
      OutreachFeedbackSignal.muted => OutreachFeedbackEntry(
        outreachId: outreachId,
        channel: channel,
        deliveredAt: deliveredAt,
        openedAt: openedAt,
        respondedAt: respondedAt,
        dismissedAt: dismissedAt,
        ignoredAt: ignoredAt,
        mutedAt: _earlierOptional(mutedAt, timestamp),
      ),
    };
  }
}

/// Fixed-cardinality account metrics. Exact outreach ids and timestamps stay
/// in the private feedback store and never enter this snapshot.
final class OutreachFeedbackSnapshot {
  const OutreachFeedbackSnapshot({
    this.events = const <OutreachFeedbackSignal, int>{},
    this.outcomes = const <OutreachFeedbackOutcome, int>{},
    this.channelDeliveries = const <OutreachChannel, int>{},
    this.responseLatencyBuckets = const <OutreachResponseLatencyBucket, int>{},
    this.posterior = ContactAvailabilityBelief.conservative,
    this.posteriorSamples = 0,
    this.pending = 0,
    this.duplicateSignals = 0,
    this.rejectedSignals = 0,
    this.unattributedResponses = 0,
    this.unattributedMutes = 0,
    this.storageErrors = 0,
  });

  final Map<OutreachFeedbackSignal, int> events;
  final Map<OutreachFeedbackOutcome, int> outcomes;
  final Map<OutreachChannel, int> channelDeliveries;
  final Map<OutreachResponseLatencyBucket, int> responseLatencyBuckets;
  final ContactAvailabilityBelief posterior;
  final int posteriorSamples;
  final int pending;
  final int duplicateSignals;
  final int rejectedSignals;
  final int unattributedResponses;
  final int unattributedMutes;
  final int storageErrors;

  Map<String, Object?> toJson() => <String, Object?>{
    'events': _namedCounts(OutreachFeedbackSignal.values, events),
    'outcomes': _namedCounts(OutreachFeedbackOutcome.values, outcomes),
    'channelDeliveries': _namedCounts(
      OutreachChannel.values,
      channelDeliveries,
    ),
    'responseLatencyBuckets': _namedCounts(
      OutreachResponseLatencyBucket.values,
      responseLatencyBuckets,
    ),
    'posteriorAvailableMass': posterior.availableMass,
    'posteriorUnavailableMass': posterior.unavailableMass,
    'posteriorProbability': posterior.probability.value,
    'posteriorSamples': posteriorSamples,
    'pending': pending,
    'duplicateSignals': duplicateSignals,
    'rejectedSignals': rejectedSignals,
    'unattributedResponses': unattributedResponses,
    'unattributedMutes': unattributedMutes,
    'storageErrors': storageErrors,
  };

  OutreachFeedbackSnapshot copyWith({
    Map<OutreachFeedbackSignal, int>? events,
    Map<OutreachFeedbackOutcome, int>? outcomes,
    Map<OutreachChannel, int>? channelDeliveries,
    Map<OutreachResponseLatencyBucket, int>? responseLatencyBuckets,
    ContactAvailabilityBelief? posterior,
    int? posteriorSamples,
    int? pending,
    int? duplicateSignals,
    int? rejectedSignals,
    int? unattributedResponses,
    int? unattributedMutes,
    int? storageErrors,
  }) => OutreachFeedbackSnapshot(
    events: events ?? this.events,
    outcomes: outcomes ?? this.outcomes,
    channelDeliveries: channelDeliveries ?? this.channelDeliveries,
    responseLatencyBuckets:
        responseLatencyBuckets ?? this.responseLatencyBuckets,
    posterior: posterior ?? this.posterior,
    posteriorSamples: posteriorSamples ?? this.posteriorSamples,
    pending: pending ?? this.pending,
    duplicateSignals: duplicateSignals ?? this.duplicateSignals,
    rejectedSignals: rejectedSignals ?? this.rejectedSignals,
    unattributedResponses: unattributedResponses ?? this.unattributedResponses,
    unattributedMutes: unattributedMutes ?? this.unattributedMutes,
    storageErrors: storageErrors ?? this.storageErrors,
  );
}

/// Account-owned rollout lifecycle collector for proactive outreach.
///
/// It learns a bounded availability posterior from explicit/inferred outcomes,
/// but never authorizes outreach. Existing mute/quiet/budget/policy/ledger
/// gates remain the only production decision path.
final class OutreachFeedbackCollector extends AppService {
  OutreachFeedbackCollector({
    required DBService accountDatabase,
    required ProactiveOutreachLedger ledger,
    required MaasoFeatureFlagService featureFlags,
    DateTime Function()? clock,
    this.responseWindow = const Duration(hours: 2),
    this.retentionPolicy = const OutreachFeedbackRetentionPolicy(),
  }) : _database = accountDatabase.raw,
       _ledger = ledger,
       _featureFlags = featureFlags,
       _clock = clock ?? DateTime.now,
       _ignoredCorrectionGrace =
           retentionPolicy.ignoredCorrectionGrace == null ||
               retentionPolicy.ignoredCorrectionGrace! < responseWindow
           ? responseWindow
           : retentionPolicy.ignoredCorrectionGrace! {
    if (responseWindow <= Duration.zero ||
        responseWindow > const Duration(days: 7)) {
      throw ArgumentError.value(
        responseWindow,
        'responseWindow',
        'must be positive and at most seven days',
      );
    }
    if (retentionPolicy.maxResolvedEntries < 0 ||
        retentionPolicy.maxMuteMarkers < 0 ||
        retentionPolicy.maxResolvedAge.isNegative ||
        retentionPolicy.maxMuteAge.isNegative ||
        (retentionPolicy.ignoredCorrectionGrace?.isNegative ?? false)) {
      throw ArgumentError.value(
        retentionPolicy,
        'retentionPolicy',
        'counts and durations must not be negative',
      );
    }
  }

  static const String storageName = 'outreach_feedback.v1';
  static const String metadataStorageName = 'outreach_feedback_meta.v1';
  static const String compactedStorageName = 'outreach_feedback_compacted.v1';
  static const int _maximumCounter = 0x7fffffff;
  static const int _ledgerReadLimit = 1024;
  static const String _activationKey = 'activation';
  static const String _muteStateKey = 'mute_state';
  static const String _rollupKey = 'rollup';
  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>(storageName);
  static final StoreRef<String, Map<String, Object?>> _muteStore =
      StoreRef<String, Map<String, Object?>>('outreach_feedback_mutes.v1');
  static final StoreRef<String, Map<String, Object?>> _compactedStore =
      StoreRef<String, Map<String, Object?>>(compactedStorageName);
  static final StoreRef<String, Map<String, Object?>> _metadataStore =
      StoreRef<String, Map<String, Object?>>(metadataStorageName);
  static final StoreRef<int, Map<String, Object?>> _chatMessageStore =
      intMapStoreFactory.store('chat_messages');

  final Database _database;
  final ProactiveOutreachLedger _ledger;
  final MaasoFeatureFlagService _featureFlags;
  final DateTime Function() _clock;
  final Duration responseWindow;
  final OutreachFeedbackRetentionPolicy retentionPolicy;
  final Duration _ignoredCorrectionGrace;
  final state = const OutreachFeedbackSnapshot().obs;

  _OutreachFeedbackLifecycle _lifecycle = _OutreachFeedbackLifecycle.created;
  Future<void> _mutationTail = Future<void>.value();
  Timer? _reconcileTimer;
  Worker? _featureFlagWorker;
  _OutreachFeedbackCursor? _cursor;
  int _executingRolloutRevision = 0;
  bool _rolloutInterrupted = false;
  bool _retiring = false;

  ContactAvailabilityBelief get posterior => isCollecting
      ? state.value.posterior
      : ContactAvailabilityBelief.conservative;

  bool get isCollecting {
    if (isClosed ||
        _retiring ||
        _lifecycle != _OutreachFeedbackLifecycle.active) {
      return false;
    }
    try {
      return _featureFlags.isObservationEnabled(
        MaasoFeatureFlag.proactiveDrive,
        now: _clock(),
      );
    } catch (_) {
      return false;
    }
  }

  Future<OutreachFeedbackCollector> init() async {
    if (isClosed || _lifecycle != _OutreachFeedbackLifecycle.created) {
      throw StateError('outreach_feedback_already_initialized');
    }
    _lifecycle = _OutreachFeedbackLifecycle.initializing;
    try {
      final initializedAt = _clock().toUtc();
      final rolloutRevision = _shadowRolloutRevision(initializedAt);
      final restored = await _database.transaction((transaction) async {
        final cursorJson = await _metadataStore
            .record(_activationKey)
            .get(transaction);
        final storedCursor = cursorJson == null
            ? null
            : _OutreachFeedbackCursor.fromStorageJson(cursorJson);
        final sameRevision =
            storedCursor != null &&
            storedCursor.collecting == (rolloutRevision > 0) &&
            storedCursor.rolloutRevision == rolloutRevision;
        final cursor = sameRevision
            ? storedCursor
            : _OutreachFeedbackCursor(
                activatedAt: initializedAt,
                lastChatMessageRecordId: await _latestChatMessageRecordId(
                  transaction,
                ),
                rolloutRevision: rolloutRevision,
                collecting: rolloutRevision > 0,
              );
        if (!sameRevision) {
          await _metadataStore
              .record(_activationKey)
              .put(transaction, cursor.toStorageJson());
        }
        final entries = await _readEntries(transaction);
        final compacted = await _readCompactedMarkers(transaction);
        final rollup = await _readRollup(transaction);
        _validateDisjointFeedback(entries, compacted);
        _validateCompactedRollup(rollup, compacted);
        // A revision mismatch observed only after restart cannot prove that
        // collection stayed enabled while this process was offline. Start a
        // fresh epoch so an unseen off assignment cannot bridge attribution.
        if (storedCursor != null && !sameRevision) {
          await _deletePendingEntries(transaction, entries);
          entries.removeWhere((_, entry) => entry.awaitingFeedback);
        }
        return (
          entries: entries,
          mutes: await _readMutes(transaction),
          rollup: rollup,
          cursor: cursor,
        );
      });
      if (_retiring ||
          isClosed ||
          _lifecycle != _OutreachFeedbackLifecycle.initializing) {
        return this;
      }
      _cursor = restored.cursor;
      _publish(restored.rollup, restored.entries.values, restored.mutes.values);
      _lifecycle = _OutreachFeedbackLifecycle.active;
      _featureFlagWorker = _featureFlags.state.listen((_) {
        if (_shadowRolloutRevision(_clock().toUtc()) == 0) {
          _rolloutInterrupted = true;
          _queueRolloutDisabled();
        } else {
          unawaited(reconcile(now: _clock()));
        }
      });
      if (isCollecting) await reconcile(now: _clock());
    } catch (error) {
      _degradeStorage();
      Log.w('[OutreachFeedback] restore failed: $error');
    }
    return this;
  }

  Future<OutreachFeedbackMutationResult> recordDelivered(
    OutreachRecord record,
  ) => _enqueue(() async {
    final projection = _projectionFor(record, now: _clock().toUtc());
    if (projection == null ||
        record.channel != OutreachChannel.foreground ||
        record.state != OutreachState.delivered) {
      return OutreachFeedbackMutationResult.rejected;
    }
    return _mutate(
      now: projection.deliveredAt,
      mutation: (entries, projectionChanges) {
        return projectionChanges.contains(projection.outreachId)
            ? OutreachFeedbackMutationResult.recorded
            : OutreachFeedbackMutationResult.duplicate;
      },
    );
  });

  /// Records an OS open only after the existing ledger claim succeeded.
  Future<OutreachFeedbackMutationResult> recordOpened({
    required String outreachId,
  }) => _enqueue(() async {
    final safeId = _tryOutreachId(outreachId);
    if (safeId == null) return OutreachFeedbackMutationResult.rejected;
    final record = await _ledger.get(safeId);
    final projection = record == null
        ? null
        : _projectionFor(record, now: _clock().toUtc());
    if (record == null ||
        projection == null ||
        record.channel != OutreachChannel.osNotification ||
        record.notificationInteractionClaimedAt == null) {
      return OutreachFeedbackMutationResult.rejected;
    }
    return _mutate(
      now: record.notificationInteractionClaimedAt!,
      mutation: (entries, projectionChanges) {
        final current = entries[projection.outreachId];
        if (current?.openedAt == null) {
          return OutreachFeedbackMutationResult.rejected;
        }
        return projectionChanges.contains(projection.outreachId)
            ? OutreachFeedbackMutationResult.recorded
            : OutreachFeedbackMutationResult.duplicate;
      },
    );
  });

  /// Attributes a durable user message to the latest eligible outreach.
  ///
  /// Only the Sembast record id is accepted. The collector re-reads strict
  /// metadata from the durable chat row, never accepts or persists body text,
  /// and advances a replay cursor in the same transaction as feedback facts.
  Future<OutreachFeedbackMutationResult> recordUserResponse({
    required int messageRecordId,
  }) async {
    if (messageRecordId < 1) {
      _noteRejected();
      return OutreachFeedbackMutationResult.rejected;
    }
    return _enqueue(() async {
      final timestamp = _clock().toUtc();
      return _mutate(
        now: timestamp,
        targetMessageRecordId: messageRecordId,
        mutation: (_, _) => OutreachFeedbackMutationResult.recorded,
      );
    });
  }

  /// Strict explicit dismissal hook. Current mobile notification APIs do not
  /// expose a trustworthy swipe-away callback, so callers must provide a
  /// concrete, already-attributed outreach id rather than infer a dismissal.
  Future<OutreachFeedbackMutationResult> recordDismissed({
    required String outreachId,
    DateTime? at,
  }) => _recordExplicit(
    outreachId: outreachId,
    signal: OutreachFeedbackSignal.dismissed,
    at: at,
  );

  /// Records a post-durable false-to-true preference transition.
  ///
  /// The preference revision is an account-local idempotency marker. A mute is
  /// retained as an account-level contact preference event and deliberately
  /// does not update the availability posterior for any particular outreach.
  Future<OutreachFeedbackMutationResult> recordMuted({
    required int preferenceRevision,
    DateTime? at,
  }) => _recordMuteState(
    hardMuted: true,
    preferenceRevision: preferenceRevision,
    at: at,
  );

  /// Records a post-durable true-to-false preference transition without
  /// adding availability or mute outcome evidence.
  Future<OutreachFeedbackMutationResult> recordUnmuted({
    required int preferenceRevision,
    DateTime? at,
  }) => _recordMuteState(
    hardMuted: false,
    preferenceRevision: preferenceRevision,
    at: at,
  );

  Future<OutreachFeedbackMutationResult> _recordMuteState({
    required bool hardMuted,
    required int preferenceRevision,
    DateTime? at,
  }) async {
    if (preferenceRevision < 1 || preferenceRevision > _maximumStoredRevision) {
      _noteRejected();
      return OutreachFeedbackMutationResult.rejected;
    }
    final timestamp = (at ?? _clock()).toUtc();
    return _enqueueWithRollout(
      allowDisabledBaseline: true,
      operation: (collecting) async {
        final reconciliationNow = _later(timestamp, _clock().toUtc());
        final marker = _muteMarker(preferenceRevision);
        late final ({
          OutreachFeedbackMutationResult result,
          Map<String, OutreachFeedbackEntry> entries,
          Map<String, _OutreachMuteMarker> mutes,
          _OutreachFeedbackRollup rollup,
          _OutreachFeedbackCursor cursor,
          int unattributedResponses,
          List<OutreachRecord> ledgerRows,
        })
        outcome;
        try {
          outcome = await _database.transaction((transaction) async {
            if (collecting) _requireCurrentRolloutAdmission();
            final ledgerRows = collecting
                ? await _ledgerRowsWithinTransaction(transaction)
                : const <OutreachRecord>[];
            final entries = await _readEntries(transaction);
            final original = <String, OutreachFeedbackEntry>{...entries};
            final mutes = await _readMutes(transaction);
            final originalMutes = <String, _OutreachMuteMarker>{...mutes};
            final rollup = await _readRollup(transaction);
            final originalRollup = rollup.copy();
            final compacted = await _readCompactedMarkers(transaction);
            final originalCompacted = <String, _OutreachFeedbackContribution>{
              ...compacted,
            };
            _validateDisjointFeedback(entries, compacted);
            _validateCompactedRollup(rollup, compacted);
            final muteState = await _readMuteState(transaction);
            final cursor = await _readCursor(transaction);
            final rehydrateIgnored =
                collecting &&
                await _latestChatMessageRecordId(transaction) >
                    cursor.lastChatMessageRecordId;
            for (final record in ledgerRows) {
              final projection = _projectionFor(record, now: reconciliationNow);
              if (projection != null) {
                _mergeProjection(
                  entries,
                  compacted,
                  rollup,
                  projection,
                  rehydrateIgnored: rehydrateIgnored,
                );
              }
            }
            _retractCancelledOsEntries(entries, compacted, rollup, ledgerRows);
            final replay = collecting
                ? await _replayHumanMessages(
                    transaction,
                    entries,
                    cursor,
                    ledgerRows: ledgerRows,
                  )
                : _HumanMessageReplay(
                    cursor: cursor,
                    targetResult: null,
                    unattributedResponses: 0,
                  );
            if (collecting) {
              await _replayAdjacentForegroundResponses(
                transaction,
                entries,
                ledgerRows: ledgerRows,
              );
            }
            final stale = preferenceRevision < muteState.preferenceRevision;
            final inconsistent =
                preferenceRevision == muteState.preferenceRevision &&
                hardMuted != muteState.active;
            final duplicate = hardMuted == muteState.active;
            final stateAdvanced =
                preferenceRevision > muteState.preferenceRevision;
            if (collecting &&
                !stale &&
                !inconsistent &&
                hardMuted &&
                !duplicate) {
              final mute = _OutreachMuteMarker(
                marker: marker,
                preferenceRevision: preferenceRevision,
                recordedAt: timestamp,
              );
              mutes[marker] = mute;
            }
            if (!stale && !inconsistent) {
              await _metadataStore
                  .record(_muteStateKey)
                  .put(
                    transaction,
                    _OutreachMuteState(
                      active: hardMuted,
                      preferenceRevision: preferenceRevision,
                    ).toStorageJson(),
                  );
            }
            if (collecting) {
              _settleIgnored(entries, reconciliationNow);
              _compactFeedback(
                entries: entries,
                mutes: mutes,
                compacted: compacted,
                rollup: rollup,
                ledgerRows: ledgerRows,
                now: reconciliationNow,
              );
              await _persistEntryChanges(transaction, original, entries);
              await _persistMuteChanges(transaction, originalMutes, mutes);
              await _persistCompactedChanges(
                transaction,
                originalCompacted,
                compacted,
              );
              await _persistRollupIfChanged(
                transaction,
                originalRollup,
                rollup,
              );
              await _persistCursorIfChanged(transaction, cursor, replay.cursor);
              _requireCurrentRolloutAdmission();
            }
            return (
              result: stale || inconsistent
                  ? OutreachFeedbackMutationResult.rejected
                  : !collecting
                  ? OutreachFeedbackMutationResult.disabled
                  : duplicate && !stateAdvanced
                  ? OutreachFeedbackMutationResult.duplicate
                  : OutreachFeedbackMutationResult.recorded,
              entries: entries,
              mutes: mutes,
              rollup: rollup,
              cursor: replay.cursor,
              unattributedResponses: replay.unattributedResponses,
              ledgerRows: ledgerRows,
            );
          });
        } on _OutreachRolloutSuperseded {
          return _persistMuteBaseline(
            hardMuted: hardMuted,
            preferenceRevision: preferenceRevision,
          );
        }
        _cursor = outcome.cursor;
        _publish(outcome.rollup, outcome.entries.values, outcome.mutes.values);
        _noteUnattributedResponses(outcome.unattributedResponses);
        _scheduleNext(
          outcome.entries.values,
          outcome.mutes.values,
          outcome.ledgerRows,
          reconciliationNow,
        );
        return outcome.result;
      },
    );
  }

  /// Recovers ledger delivery evidence and deterministically settles ignores.
  Future<OutreachFeedbackMutationResult> reconcile({DateTime? now}) {
    final timestamp = (now ?? _clock()).toUtc();
    return _enqueue(() async {
      return _mutate(
        now: timestamp,
        mutation: (_, _) => OutreachFeedbackMutationResult.recorded,
      );
    });
  }

  Future<OutreachFeedbackEntry?> get(String outreachId) async {
    final safeId = _tryOutreachId(outreachId);
    if (safeId == null ||
        _lifecycle != _OutreachFeedbackLifecycle.active ||
        isClosed) {
      return null;
    }
    try {
      await _mutationTail;
      final marker = _outreachMarker(safeId);
      final json = await _store.record(marker).get(_database);
      return json == null
          ? null
          : OutreachFeedbackEntry.fromStorageJson(marker, json);
    } catch (error) {
      _degradeStorage();
      Log.w('[OutreachFeedback] read failed: $error');
      return null;
    }
  }

  Future<void> waitForIdle() => _mutationTail;

  Future<void> deactivateAndDrain() async {
    if (_retiring || _lifecycle == _OutreachFeedbackLifecycle.retired) {
      await _mutationTail;
      return;
    }
    _retiring = true;
    _featureFlagWorker?.dispose();
    _featureFlagWorker = null;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    await _mutationTail;
    _lifecycle = _OutreachFeedbackLifecycle.retired;
    state.value = const OutreachFeedbackSnapshot();
  }

  Future<OutreachFeedbackMutationResult> _recordExplicit({
    required String outreachId,
    required OutreachFeedbackSignal signal,
    DateTime? at,
  }) {
    final timestamp = (at ?? _clock()).toUtc();
    return _enqueue(() async {
      final safeId = _tryOutreachId(outreachId);
      if (safeId == null) return OutreachFeedbackMutationResult.rejected;
      final marker = _outreachMarker(safeId);
      return _mutate(
        now: timestamp,
        mutation: (entries, _) {
          final current = entries[marker];
          if (current == null ||
              timestamp.isBefore(current.feedbackAnchorAt) ||
              timestamp.isAfter(current.feedbackAnchorAt.add(responseWindow))) {
            return OutreachFeedbackMutationResult.noEligibleOutreach;
          }
          if (current.outcome != null &&
              current.outcome != OutreachFeedbackOutcome.ignored) {
            return OutreachFeedbackMutationResult.duplicate;
          }
          entries[marker] = current.record(signal, timestamp);
          return OutreachFeedbackMutationResult.recorded;
        },
      );
    });
  }

  Future<OutreachFeedbackMutationResult> _enqueue(
    Future<OutreachFeedbackMutationResult> Function() operation,
  ) => _enqueueWithRollout(
    allowDisabledBaseline: false,
    operation: (_) => operation(),
  );

  void _requireCurrentRolloutAdmission() {
    final revision = _executingRolloutRevision;
    final cursor = _cursor;
    if (_rolloutInterrupted ||
        revision < 1 ||
        cursor == null ||
        !cursor.collecting ||
        cursor.rolloutRevision != revision ||
        _shadowRolloutRevision(_clock().toUtc()) != revision) {
      throw const _OutreachRolloutSuperseded();
    }
  }

  Future<OutreachFeedbackMutationResult> _enqueueWithRollout({
    required bool allowDisabledBaseline,
    required Future<OutreachFeedbackMutationResult> Function(bool collecting)
    operation,
  }) {
    if (_retiring ||
        isClosed ||
        _lifecycle == _OutreachFeedbackLifecycle.retired) {
      return Future<OutreachFeedbackMutationResult>.value(
        OutreachFeedbackMutationResult.retired,
      );
    }
    if (_lifecycle != _OutreachFeedbackLifecycle.active) {
      return Future<OutreachFeedbackMutationResult>.value(
        OutreachFeedbackMutationResult.disabled,
      );
    }
    final admissionRevision = _shadowRolloutRevision(_clock().toUtc());
    if (!allowDisabledBaseline && admissionRevision == 0) {
      return Future<OutreachFeedbackMutationResult>.value(
        OutreachFeedbackMutationResult.disabled,
      );
    }
    final previous = _mutationTail;
    Future<OutreachFeedbackMutationResult> guardedOperation() async {
      var activeNow = await _ensureRolloutEpoch();
      if (!activeNow) {
        await _persistRolloutDisabled();
        activeNow = await _ensureRolloutEpoch();
      }
      final cursor = _cursor;
      final collecting =
          activeNow &&
          admissionRevision > 0 &&
          cursor != null &&
          cursor.collecting &&
          cursor.rolloutRevision == admissionRevision &&
          _shadowRolloutRevision(_clock().toUtc()) == admissionRevision;
      if (!collecting && !allowDisabledBaseline) {
        return OutreachFeedbackMutationResult.disabled;
      }
      _executingRolloutRevision = collecting ? admissionRevision : 0;
      try {
        return await operation(collecting);
      } finally {
        _executingRolloutRevision = 0;
      }
    }

    final next = previous.then<OutreachFeedbackMutationResult>(
      (_) => guardedOperation(),
      onError: (Object _, StackTrace _) => guardedOperation(),
    );
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next.then<OutreachFeedbackMutationResult>(
      (result) {
        if (result == OutreachFeedbackMutationResult.duplicate) {
          _noteDuplicate();
        } else if (result == OutreachFeedbackMutationResult.rejected) {
          _noteRejected();
        }
        return result;
      },
      onError: (Object error, StackTrace _) {
        _degradeStorage();
        Log.w('[OutreachFeedback] mutation failed: $error');
        return OutreachFeedbackMutationResult.storageUnavailable;
      },
    );
  }

  Future<OutreachFeedbackMutationResult> _mutate({
    required DateTime now,
    int? targetMessageRecordId,
    required OutreachFeedbackMutationResult Function(
      Map<String, OutreachFeedbackEntry> entries,
      Set<String> projectionChanges,
    )
    mutation,
  }) async {
    final reconciliationNow = _later(now.toUtc(), _clock().toUtc());
    late final ({
      OutreachFeedbackMutationResult result,
      Map<String, OutreachFeedbackEntry> entries,
      Map<String, _OutreachMuteMarker> mutes,
      _OutreachFeedbackRollup rollup,
      _OutreachFeedbackCursor cursor,
      int unattributedResponses,
      List<OutreachRecord> ledgerRows,
    })
    outcome;
    try {
      outcome = await _database.transaction((transaction) async {
        _requireCurrentRolloutAdmission();
        final ledgerRows = await _ledgerRowsWithinTransaction(transaction);
        final entries = await _readEntries(transaction);
        final mutes = await _readMutes(transaction);
        final originalMutes = <String, _OutreachMuteMarker>{...mutes};
        final rollup = await _readRollup(transaction);
        final originalRollup = rollup.copy();
        final compacted = await _readCompactedMarkers(transaction);
        final originalCompacted = <String, _OutreachFeedbackContribution>{
          ...compacted,
        };
        _validateDisjointFeedback(entries, compacted);
        _validateCompactedRollup(rollup, compacted);
        final cursor = await _readCursor(transaction);
        final original = <String, OutreachFeedbackEntry>{...entries};
        final projectionChanges = <String>{};
        final rehydrateIgnored =
            await _latestChatMessageRecordId(transaction) >
            cursor.lastChatMessageRecordId;
        for (final record in ledgerRows) {
          final projection = _projectionFor(record, now: reconciliationNow);
          if (projection != null &&
              _mergeProjection(
                entries,
                compacted,
                rollup,
                projection,
                rehydrateIgnored: rehydrateIgnored,
              )) {
            projectionChanges.add(projection.outreachId);
          }
        }
        _retractCancelledOsEntries(entries, compacted, rollup, ledgerRows);
        var result = mutation(entries, projectionChanges);
        final replay = await _replayHumanMessages(
          transaction,
          entries,
          cursor,
          ledgerRows: ledgerRows,
          targetMessageRecordId: targetMessageRecordId,
        );
        await _replayAdjacentForegroundResponses(
          transaction,
          entries,
          ledgerRows: ledgerRows,
        );
        if (targetMessageRecordId != null) {
          result =
              replay.targetResult ?? OutreachFeedbackMutationResult.rejected;
        }
        _settleIgnored(entries, reconciliationNow);
        _compactFeedback(
          entries: entries,
          mutes: mutes,
          compacted: compacted,
          rollup: rollup,
          ledgerRows: ledgerRows,
          now: reconciliationNow,
        );
        await _persistEntryChanges(transaction, original, entries);
        await _persistMuteChanges(transaction, originalMutes, mutes);
        await _persistCompactedChanges(
          transaction,
          originalCompacted,
          compacted,
        );
        await _persistRollupIfChanged(transaction, originalRollup, rollup);
        await _persistCursorIfChanged(transaction, cursor, replay.cursor);
        _requireCurrentRolloutAdmission();
        return (
          result: result,
          entries: entries,
          mutes: mutes,
          rollup: rollup,
          cursor: replay.cursor,
          unattributedResponses: replay.unattributedResponses,
          ledgerRows: ledgerRows,
        );
      });
    } on _OutreachRolloutSuperseded {
      return OutreachFeedbackMutationResult.disabled;
    }
    _cursor = outcome.cursor;
    _publish(outcome.rollup, outcome.entries.values, outcome.mutes.values);
    _noteUnattributedResponses(outcome.unattributedResponses);
    _scheduleNext(
      outcome.entries.values,
      outcome.mutes.values,
      outcome.ledgerRows,
      reconciliationNow,
    );
    return outcome.result;
  }

  Future<List<OutreachRecord>> _ledgerRowsWithinTransaction(
    DatabaseClient transaction,
  ) async {
    final cursor = _cursor;
    if (cursor == null) return const <OutreachRecord>[];
    final rows = await _ledger.recentWithinTransaction(
      transaction,
      limit: _ledgerReadLimit,
    );
    return rows
        .where((record) => _isObservableSince(record, cursor.activatedAt))
        .toList(growable: false);
  }

  int _shadowRolloutRevision(DateTime now) {
    if (!_featureFlags.isObservationEnabled(
      MaasoFeatureFlag.proactiveDrive,
      now: now,
    )) {
      return 0;
    }
    return _featureFlags
            .state
            .value[MaasoFeatureFlag.proactiveDrive]
            ?.revision ??
        0;
  }

  Future<bool> _ensureRolloutEpoch() async {
    final timestamp = _clock().toUtc();
    final revision = _shadowRolloutRevision(timestamp);
    if (revision == 0 || _retiring || isClosed) return false;
    final current = _cursor;
    if (!_rolloutInterrupted &&
        current != null &&
        current.collecting &&
        current.rolloutRevision == revision) {
      return true;
    }
    final reset = await _database.transaction((transaction) async {
      final stored = await _readCursor(transaction);
      final entries = await _readEntries(transaction);
      // Shadow and enforce are one continuous observation lifecycle. A mode
      // or assignment revision change invalidates queued mutations, but must
      // not erase delivered feedback that still belongs to the response
      // window. A real off interruption starts a fresh attribution epoch.
      final continuesObservation = !_rolloutInterrupted && stored.collecting;
      final next = continuesObservation
          ? _OutreachFeedbackCursor(
              activatedAt: stored.activatedAt,
              lastChatMessageRecordId: stored.lastChatMessageRecordId,
              rolloutRevision: revision,
              collecting: true,
            )
          : _OutreachFeedbackCursor(
              activatedAt: timestamp,
              lastChatMessageRecordId: await _latestChatMessageRecordId(
                transaction,
              ),
              rolloutRevision: revision,
              collecting: true,
            );
      if (!continuesObservation) {
        await _deletePendingEntries(transaction, entries);
        entries.removeWhere((_, entry) => entry.awaitingFeedback);
      }
      await _persistCursorIfChanged(transaction, stored, next);
      return (
        cursor: next,
        entries: entries,
        mutes: await _readMutes(transaction),
        rollup: await _readRollup(transaction),
      );
    });
    _cursor = reset.cursor;
    _rolloutInterrupted = false;
    _publish(reset.rollup, reset.entries.values, reset.mutes.values);
    return true;
  }

  void _queueRolloutDisabled() {
    if (_retiring ||
        isClosed ||
        _lifecycle != _OutreachFeedbackLifecycle.active) {
      return;
    }
    final previous = _mutationTail;
    final next = previous.then<void>(
      (_) => _persistRolloutDisabled(),
      onError: (Object _, StackTrace _) => _persistRolloutDisabled(),
    );
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        _degradeStorage();
        Log.w('[OutreachFeedback] rollout watermark failed: $error');
      },
    );
  }

  Future<void> _persistRolloutDisabled() async {
    if (_retiring ||
        isClosed ||
        _lifecycle != _OutreachFeedbackLifecycle.active ||
        _shadowRolloutRevision(_clock().toUtc()) > 0) {
      return;
    }
    final timestamp = _clock().toUtc();
    final reset = await _database.transaction((transaction) async {
      final stored = await _readCursor(transaction);
      final next = _OutreachFeedbackCursor(
        activatedAt: timestamp,
        lastChatMessageRecordId: await _latestChatMessageRecordId(transaction),
        rolloutRevision: 0,
        collecting: false,
      );
      final entries = await _readEntries(transaction);
      await _deletePendingEntries(transaction, entries);
      await _persistCursorIfChanged(transaction, stored, next);
      entries.removeWhere((_, entry) => entry.awaitingFeedback);
      return (
        cursor: next,
        entries: entries,
        mutes: await _readMutes(transaction),
        rollup: await _readRollup(transaction),
      );
    });
    _cursor = reset.cursor;
    _publish(reset.rollup, reset.entries.values, reset.mutes.values);
  }

  Future<OutreachFeedbackMutationResult> _persistMuteBaseline({
    required bool hardMuted,
    required int preferenceRevision,
  }) {
    return _database.transaction((transaction) async {
      final muteState = await _readMuteState(transaction);
      final stale = preferenceRevision < muteState.preferenceRevision;
      final inconsistent =
          preferenceRevision == muteState.preferenceRevision &&
          hardMuted != muteState.active;
      if (stale || inconsistent) {
        return OutreachFeedbackMutationResult.rejected;
      }
      await _metadataStore
          .record(_muteStateKey)
          .put(
            transaction,
            _OutreachMuteState(
              active: hardMuted,
              preferenceRevision: preferenceRevision,
            ).toStorageJson(),
          );
      return OutreachFeedbackMutationResult.disabled;
    });
  }

  static Future<void> _deletePendingEntries(
    DatabaseClient transaction,
    Map<String, OutreachFeedbackEntry> entries,
  ) async {
    for (final entry in entries.values) {
      if (entry.awaitingFeedback) {
        await _store.record(entry.outreachId).delete(transaction);
      }
    }
  }

  static _OutreachProjection? _projectionFor(
    OutreachRecord record, {
    required DateTime now,
  }) {
    final timestamp = now.toUtc();
    DateTime? deliveredAt;
    DateTime? openedAt;
    if (record.channel == OutreachChannel.foreground) {
      if (record.state == OutreachState.delivered) {
        deliveredAt = record.deliveredAt;
      }
    } else {
      openedAt = record.notificationInteractionClaimedAt;
      if (openedAt != null) {
        final scheduled = record.scheduledFor ?? record.assumedDeliveredAt;
        deliveredAt = scheduled == null || scheduled.isAfter(openedAt)
            ? openedAt
            : scheduled;
      } else if (record.state == OutreachState.assumedDelivered) {
        deliveredAt =
            record.expiresAt ??
            record.assumedDeliveredAt ??
            record.scheduledFor;
      } else if (record.state == OutreachState.scheduledOs &&
          record.expiresAt != null &&
          !record.expiresAt!.isAfter(timestamp)) {
        // The OS API exposes no delivery receipt. Once its delivery window has
        // elapsed, project a conservative assumed delivery into the shadow
        // store without mutating the production ledger.
        deliveredAt = record.expiresAt;
      }
    }
    if (deliveredAt == null) return null;
    return _OutreachProjection(
      outreachId: _outreachMarker(record.outreachId),
      channel: record.channel,
      deliveredAt: deliveredAt.toUtc(),
      openedAt: openedAt?.toUtc(),
    );
  }

  bool _mergeProjection(
    Map<String, OutreachFeedbackEntry> entries,
    Map<String, _OutreachFeedbackContribution> compacted,
    _OutreachFeedbackRollup rollup,
    _OutreachProjection projection, {
    required bool rehydrateIgnored,
  }) {
    var current = entries[projection.outreachId];
    final archived = compacted[projection.outreachId];
    if (archived != null) {
      final openingUpgrade =
          projection.openedAt != null &&
          !archived.hasEvent(OutreachFeedbackSignal.opened);
      if (archived.outcome != OutreachFeedbackOutcome.ignored ||
          (!rehydrateIgnored && !openingUpgrade)) {
        return false;
      }
      current = _restoreCompactedIgnored(archived, projection);
      rollup.remove(archived);
      compacted.remove(projection.outreachId);
      entries[projection.outreachId] = current;
    }
    final next = current == null
        ? OutreachFeedbackEntry(
            outreachId: projection.outreachId,
            channel: projection.channel,
            deliveredAt: projection.deliveredAt,
            openedAt: projection.openedAt,
          )
        : current.mergeDelivery(
            channel: projection.channel,
            deliveredAt: projection.deliveredAt,
            openedAt: projection.openedAt,
          );
    if (current != null && _sameEntry(current, next)) return false;
    entries[projection.outreachId] = next;
    return true;
  }

  OutreachFeedbackEntry _restoreCompactedIgnored(
    _OutreachFeedbackContribution contribution,
    _OutreachProjection projection,
  ) {
    if (contribution.channel != projection.channel ||
        contribution.outcome != OutreachFeedbackOutcome.ignored ||
        !contribution.hasEvent(OutreachFeedbackSignal.delivered) ||
        !contribution.hasEvent(OutreachFeedbackSignal.ignored)) {
      throw const FormatException(
        'compacted outreach cannot be restored safely',
      );
    }
    final hadOpened = contribution.hasEvent(OutreachFeedbackSignal.opened);
    if (hadOpened && projection.openedAt == null) {
      throw const FormatException('compacted open is missing from ledger');
    }
    final priorAnchor = hadOpened
        ? projection.openedAt!
        : projection.deliveredAt;
    return OutreachFeedbackEntry(
      outreachId: projection.outreachId,
      channel: projection.channel,
      deliveredAt: projection.deliveredAt,
      openedAt: projection.openedAt,
      ignoredAt: priorAnchor.add(responseWindow),
    );
  }

  static void _retractCancelledOsEntries(
    Map<String, OutreachFeedbackEntry> entries,
    Map<String, _OutreachFeedbackContribution> compacted,
    _OutreachFeedbackRollup rollup,
    Iterable<OutreachRecord> ledgerRows,
  ) {
    for (final record in ledgerRows) {
      if (record.channel != OutreachChannel.osNotification ||
          record.state != OutreachState.cancelled ||
          record.notificationInteractionClaimedAt != null) {
        continue;
      }
      final marker = _outreachMarker(record.outreachId);
      entries.remove(marker);
      final contribution = compacted.remove(marker);
      if (contribution != null) {
        if (contribution.channel != OutreachChannel.osNotification) {
          throw const FormatException(
            'cancelled OS marker has another channel',
          );
        }
        rollup.remove(contribution);
      }
    }
  }

  OutreachFeedbackEntry? _onlyEligibleOpenedOs(
    Iterable<OutreachFeedbackEntry> entries, {
    required DateTime at,
  }) {
    final eligible = entries.where((entry) {
      if (entry.channel != OutreachChannel.osNotification ||
          entry.openedAt == null) {
        return false;
      }
      if (entry.outcome != null &&
          entry.outcome != OutreachFeedbackOutcome.ignored) {
        return false;
      }
      final anchor = entry.feedbackAnchorAt;
      return !at.isBefore(anchor) && !at.isAfter(anchor.add(responseWindow));
    }).toList();
    return eligible.length == 1 ? eligible.single : null;
  }

  void _settleIgnored(
    Map<String, OutreachFeedbackEntry> entries,
    DateTime now,
  ) {
    for (final entry in entries.values.toList(growable: false)) {
      if (!entry.awaitingFeedback) continue;
      final deadline = entry.feedbackAnchorAt.add(responseWindow);
      if (now.isBefore(deadline)) continue;
      entries[entry.outreachId] = entry.record(
        OutreachFeedbackSignal.ignored,
        deadline,
      );
    }
  }

  void _publish(
    _OutreachFeedbackRollup rollup,
    Iterable<OutreachFeedbackEntry> source,
    Iterable<_OutreachMuteMarker> muteSource,
  ) {
    if (_retiring ||
        isClosed ||
        _lifecycle == _OutreachFeedbackLifecycle.retired) {
      return;
    }
    final entries = source.toList(growable: false);
    final mutes = muteSource.toList(growable: false);
    final events = _snapshotCounts(rollup.events);
    final outcomes = _snapshotCounts(rollup.outcomes);
    final channels = _snapshotCounts(rollup.channelDeliveries);
    final latencyBuckets = _snapshotCounts(rollup.responseLatencyBuckets);
    var respondedSamples =
        rollup.outcomes[OutreachFeedbackOutcome.responded] ?? 0;
    var ignoredSamples = rollup.outcomes[OutreachFeedbackOutcome.ignored] ?? 0;
    var dismissedSamples =
        rollup.outcomes[OutreachFeedbackOutcome.dismissed] ?? 0;
    var pending = 0;

    void add<T>(Map<T, int> counts, T key, [int amount = 1]) {
      counts[key] = math.min(_maximumCounter, (counts[key] ?? 0) + amount);
    }

    for (final entry in entries) {
      add(events, OutreachFeedbackSignal.delivered);
      add(channels, entry.channel);
      if (entry.openedAt != null) add(events, OutreachFeedbackSignal.opened);
      if (entry.respondedAt != null) {
        add(events, OutreachFeedbackSignal.responded);
        add(latencyBuckets, _latencyBucket(entry.responseLatency!));
      }
      if (entry.dismissedAt != null) {
        add(events, OutreachFeedbackSignal.dismissed);
      }
      if (entry.ignoredAt != null) add(events, OutreachFeedbackSignal.ignored);
      if (entry.mutedAt != null) add(events, OutreachFeedbackSignal.muted);
      final outcome = entry.outcome;
      if (outcome == null) {
        pending = _increment(pending);
      } else {
        add(outcomes, outcome);
        switch (outcome) {
          case OutreachFeedbackOutcome.responded:
            respondedSamples += 1;
          case OutreachFeedbackOutcome.ignored:
            ignoredSamples += 1;
          case OutreachFeedbackOutcome.dismissed:
            dismissedSamples += 1;
          case OutreachFeedbackOutcome.muted:
            break;
        }
      }
    }
    for (final _ in mutes) {
      add(events, OutreachFeedbackSignal.muted);
      add(outcomes, OutreachFeedbackOutcome.muted);
    }
    var availableMass =
        ContactAvailabilityBelief.conservative.availableMass + respondedSamples;
    var unavailableMass =
        ContactAvailabilityBelief.conservative.unavailableMass +
        (ignoredSamples * 1.25) +
        (dismissedSamples * 2);
    final posteriorSamples = math.min(
      _maximumCounter,
      respondedSamples + ignoredSamples + dismissedSamples,
    );
    final largestMass = math.max(availableMass, unavailableMass);
    if (largestMass > ContactAvailabilityBelief.maximumMass) {
      final scale = ContactAvailabilityBelief.maximumMass / largestMass;
      availableMass *= scale;
      unavailableMass *= scale;
    }
    final belief = ContactAvailabilityBelief.bounded(
      availableMass: availableMass,
      unavailableMass: unavailableMass,
    );
    final diagnostics = state.value;
    state.value = OutreachFeedbackSnapshot(
      events: Map<OutreachFeedbackSignal, int>.unmodifiable(events),
      outcomes: Map<OutreachFeedbackOutcome, int>.unmodifiable(outcomes),
      channelDeliveries: Map<OutreachChannel, int>.unmodifiable(channels),
      responseLatencyBuckets:
          Map<OutreachResponseLatencyBucket, int>.unmodifiable(latencyBuckets),
      posterior: belief,
      posteriorSamples: posteriorSamples,
      pending: pending,
      duplicateSignals: diagnostics.duplicateSignals,
      rejectedSignals: diagnostics.rejectedSignals,
      unattributedResponses: diagnostics.unattributedResponses,
      unattributedMutes: diagnostics.unattributedMutes,
      storageErrors: diagnostics.storageErrors,
    );
  }

  void _scheduleNext(
    Iterable<OutreachFeedbackEntry> entries,
    Iterable<_OutreachMuteMarker> mutes,
    Iterable<OutreachRecord> ledgerRows,
    DateTime now,
  ) {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    if (!isCollecting) return;
    DateTime? next;
    void consider(DateTime? candidate) {
      if (candidate == null || !candidate.isAfter(now)) return;
      if (next == null || candidate.isBefore(next!)) next = candidate;
    }

    for (final entry in entries) {
      if (entry.awaitingFeedback) {
        consider(entry.feedbackAnchorAt.add(responseWindow));
      } else {
        consider(entry.outcomeAt?.add(retentionPolicy.maxResolvedAge));
        if (entry.outcome == OutreachFeedbackOutcome.ignored) {
          consider(entry.outcomeAt?.add(_ignoredCorrectionGrace));
        }
      }
    }
    for (final mute in mutes) {
      consider(mute.recordedAt.add(retentionPolicy.maxMuteAge));
    }
    for (final record in ledgerRows) {
      if (record.channel == OutreachChannel.osNotification &&
          record.state == OutreachState.scheduledOs) {
        consider(record.expiresAt);
      }
    }
    consider(
      _featureFlags.state.value[MaasoFeatureFlag.proactiveDrive]?.expiresAt
          .toUtc(),
    );
    final target = next;
    if (target == null) return;
    _reconcileTimer = Timer(target.difference(now), () {
      if (!isCollecting) {
        _rolloutInterrupted = true;
        _queueRolloutDisabled();
        return;
      }
      unawaited(reconcile(now: _clock()));
    });
  }

  void _compactFeedback({
    required Map<String, OutreachFeedbackEntry> entries,
    required Map<String, _OutreachMuteMarker> mutes,
    required Map<String, _OutreachFeedbackContribution> compacted,
    required _OutreachFeedbackRollup rollup,
    required List<OutreachRecord> ledgerRows,
    required DateTime now,
  }) {
    final timestamp = now.toUtc();
    final ledgerMarkers = <String>{
      for (final record in ledgerRows) _outreachMarker(record.outreachId),
    };
    final eligible = entries.values.where((entry) {
      final outcomeAt = entry.outcomeAt;
      if (outcomeAt == null) return false;
      return entry.outcome != OutreachFeedbackOutcome.ignored ||
          !timestamp.isBefore(outcomeAt.add(_ignoredCorrectionGrace));
    }).toList()..sort(_compareFeedbackEntries);
    final selectedEntries = <String>{};
    final entryCutoff = timestamp.subtract(retentionPolicy.maxResolvedAge);
    for (final entry in eligible) {
      if (!entry.outcomeAt!.isAfter(entryCutoff)) {
        selectedEntries.add(entry.outreachId);
      }
    }
    final retainedEligible = eligible
        .where((entry) => !selectedEntries.contains(entry.outreachId))
        .toList(growable: false);
    final entryOverflow = math.max(
      0,
      retainedEligible.length - retentionPolicy.maxResolvedEntries,
    );
    for (final entry in retainedEligible.take(entryOverflow)) {
      selectedEntries.add(entry.outreachId);
    }
    for (final marker in selectedEntries) {
      final entry = entries.remove(marker)!;
      final contribution = _OutreachFeedbackContribution.fromEntry(entry);
      rollup.add(contribution);
      if (ledgerMarkers.contains(marker)) {
        compacted[marker] = contribution;
      }
    }

    final eligibleMutes = mutes.values.toList()..sort(_compareMuteMarkers);
    final selectedMutes = <String>{};
    final muteCutoff = timestamp.subtract(retentionPolicy.maxMuteAge);
    for (final mute in eligibleMutes) {
      if (!mute.recordedAt.isAfter(muteCutoff)) {
        selectedMutes.add(mute.marker);
      }
    }
    final retainedMutes = eligibleMutes
        .where((mute) => !selectedMutes.contains(mute.marker))
        .toList(growable: false);
    final muteOverflow = math.max(
      0,
      retainedMutes.length - retentionPolicy.maxMuteMarkers,
    );
    for (final mute in retainedMutes.take(muteOverflow)) {
      selectedMutes.add(mute.marker);
    }
    for (final marker in selectedMutes) {
      mutes.remove(marker);
      rollup.add(_OutreachFeedbackContribution.mute);
    }

    // A non-saturated ledger read proves these digest-only suppression
    // markers can no longer be projected or corrected. Their contributions
    // remain in the fixed-cardinality rollup.
    if (ledgerRows.length < _ledgerReadLimit) {
      compacted.removeWhere((marker, _) => !ledgerMarkers.contains(marker));
    }
  }

  Future<Map<String, OutreachFeedbackEntry>> _readEntries(
    DatabaseClient client,
  ) async {
    final records = await _store.find(client);
    return <String, OutreachFeedbackEntry>{
      for (final record in records)
        record.key: OutreachFeedbackEntry.fromStorageJson(
          record.key,
          record.value,
        ),
    };
  }

  Future<Map<String, _OutreachMuteMarker>> _readMutes(
    DatabaseClient client,
  ) async {
    final records = await _muteStore.find(client);
    return <String, _OutreachMuteMarker>{
      for (final record in records)
        record.key: _OutreachMuteMarker.fromStorageJson(
          record.key,
          record.value,
        ),
    };
  }

  Future<_OutreachFeedbackRollup> _readRollup(DatabaseClient client) async {
    final json = await _metadataStore.record(_rollupKey).get(client);
    return json == null
        ? _OutreachFeedbackRollup.empty()
        : _OutreachFeedbackRollup.fromStorageJson(json);
  }

  Future<Map<String, _OutreachFeedbackContribution>> _readCompactedMarkers(
    DatabaseClient client,
  ) async {
    final records = await _compactedStore.find(client);
    return <String, _OutreachFeedbackContribution>{
      for (final record in records)
        record.key: _OutreachFeedbackContribution.fromStorageJson(
          record.key,
          record.value,
        ),
    };
  }

  static void _validateDisjointFeedback(
    Map<String, OutreachFeedbackEntry> entries,
    Map<String, _OutreachFeedbackContribution> compacted,
  ) {
    if (entries.keys.any(compacted.containsKey)) {
      throw const FormatException(
        'outreach feedback exists in raw and compacted storage',
      );
    }
  }

  static void _validateCompactedRollup(
    _OutreachFeedbackRollup rollup,
    Map<String, _OutreachFeedbackContribution> compacted,
  ) {
    final remainder = rollup.copy();
    for (final contribution in compacted.values) {
      remainder.remove(contribution);
    }
  }

  Future<_OutreachMuteState> _readMuteState(DatabaseClient client) async {
    final json = await _metadataStore.record(_muteStateKey).get(client);
    return json == null
        ? const _OutreachMuteState(active: false, preferenceRevision: 0)
        : _OutreachMuteState.fromStorageJson(json);
  }

  Future<_OutreachFeedbackCursor> _readCursor(DatabaseClient client) async {
    final json = await _metadataStore.record(_activationKey).get(client);
    if (json == null) {
      throw const FormatException('outreach feedback cursor is missing');
    }
    return _OutreachFeedbackCursor.fromStorageJson(json);
  }

  static Future<int> _latestChatMessageRecordId(DatabaseClient client) async {
    final rows = await _chatMessageStore.find(
      client,
      finder: Finder(
        sortOrders: <SortOrder>[SortOrder(Field.key, false)],
        limit: 1,
      ),
    );
    return rows.isEmpty ? 0 : rows.single.key;
  }

  Future<_HumanMessageReplay> _replayHumanMessages(
    DatabaseClient transaction,
    Map<String, OutreachFeedbackEntry> entries,
    _OutreachFeedbackCursor cursor, {
    required List<OutreachRecord> ledgerRows,
    int? targetMessageRecordId,
  }) async {
    var lastRecordId = cursor.lastChatMessageRecordId;
    OutreachFeedbackMutationResult? targetResult;
    var unattributedResponses = 0;
    final foregroundAnchors = _foregroundResponseAnchors(ledgerRows, entries);
    if (targetMessageRecordId != null &&
        targetMessageRecordId <= lastRecordId) {
      targetResult = OutreachFeedbackMutationResult.duplicate;
    }

    while (true) {
      final rows = await _chatMessageStore.find(
        transaction,
        finder: Finder(
          filter: Filter.greaterThan(Field.key, lastRecordId),
          sortOrders: <SortOrder>[SortOrder(Field.key)],
          limit: 256,
        ),
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        lastRecordId = row.key;
        final receipt = _tryHumanMessageReceipt(row.value);
        if (receipt == null) {
          if (row.key == targetMessageRecordId) {
            targetResult = OutreachFeedbackMutationResult.rejected;
          }
          continue;
        }
        final foreground = await _exactForegroundTarget(
          transaction,
          entries,
          foregroundAnchors,
          humanMessageRecordId: row.key,
          at: receipt.persistedAt,
        );
        final target = foreground.matched
            ? foreground.target
            : _onlyEligibleOpenedOs(entries.values, at: receipt.persistedAt);
        final result = target == null
            ? OutreachFeedbackMutationResult.noEligibleOutreach
            : OutreachFeedbackMutationResult.recorded;
        if (target == null && !foreground.matched) {
          unattributedResponses = _increment(unattributedResponses);
        } else {
          if (target != null) {
            entries[target.outreachId] = target.record(
              OutreachFeedbackSignal.responded,
              receipt.persistedAt,
            );
          }
        }
        if (row.key == targetMessageRecordId) targetResult = result;
      }
      if (rows.length < 256) break;
    }

    if (targetMessageRecordId != null &&
        targetResult == null &&
        targetMessageRecordId > lastRecordId) {
      targetResult = OutreachFeedbackMutationResult.rejected;
    }
    return _HumanMessageReplay(
      cursor: cursor.copyWith(lastChatMessageRecordId: lastRecordId),
      targetResult: targetResult,
      unattributedResponses: unattributedResponses,
    );
  }

  static Map<int, _ForegroundResponseAnchor> _foregroundResponseAnchors(
    Iterable<OutreachRecord> ledgerRows,
    Map<String, OutreachFeedbackEntry> entries,
  ) {
    final anchors = <int, _ForegroundResponseAnchor>{};
    final ambiguousRecordIds = <int>{};
    for (final record in ledgerRows) {
      final recordId = record.visibleMessageRecordId;
      final idempotencyKey = record.visibleMessageIdempotencyKey;
      if (record.channel != OutreachChannel.foreground ||
          (record.state != OutreachState.committed &&
              record.state != OutreachState.delivered) ||
          recordId == null ||
          recordId < 1 ||
          idempotencyKey == null) {
        continue;
      }
      final marker = _outreachMarker(record.outreachId);
      final entry = entries[marker];
      if (entry != null && entry.channel != OutreachChannel.foreground) {
        continue;
      }
      final anchor = _ForegroundResponseAnchor(
        outreachMarker: marker,
        idempotencyKey: idempotencyKey,
      );
      final existing = anchors[recordId];
      if (existing != null && existing != anchor) {
        anchors.remove(recordId);
        ambiguousRecordIds.add(recordId);
      } else if (!ambiguousRecordIds.contains(recordId)) {
        anchors[recordId] = anchor;
      }
    }
    return anchors;
  }

  Future<_ForegroundAttribution> _exactForegroundTarget(
    DatabaseClient transaction,
    Map<String, OutreachFeedbackEntry> entries,
    Map<int, _ForegroundResponseAnchor> anchors, {
    required int humanMessageRecordId,
    required DateTime at,
  }) async {
    if (anchors.isEmpty) return const _ForegroundAttribution.unmatched();
    final predecessor = await _chatMessageStore.find(
      transaction,
      finder: Finder(
        filter: Filter.and(<Filter>[
          Filter.lessThan(Field.key, humanMessageRecordId),
          Filter.equals('sessionId', 'self'),
        ]),
        sortOrders: <SortOrder>[SortOrder(Field.key, false)],
        limit: 1,
      ),
    );
    if (predecessor.isEmpty) {
      return const _ForegroundAttribution.unmatched();
    }
    final row = predecessor.single;
    final expected = anchors[row.key];
    if (expected == null) return const _ForegroundAttribution.unmatched();
    final actual = _tryProactiveMessageAnchor(row.value);
    if (actual != expected) {
      // The ledger binding already identifies this row as the foreground
      // predecessor. Corrupt or inconsistent chat metadata must fail closed
      // instead of falling back to an unrelated opened OS occurrence.
      return const _ForegroundAttribution.matched(null);
    }
    final entry = entries[expected.outreachMarker];
    if (entry == null ||
        entry.channel != OutreachChannel.foreground ||
        (entry.outcome != null &&
            entry.outcome != OutreachFeedbackOutcome.ignored)) {
      return const _ForegroundAttribution.matched(null);
    }
    final anchorAt = entry.feedbackAnchorAt;
    final target =
        !at.isBefore(anchorAt) && !at.isAfter(anchorAt.add(responseWindow))
        ? entry
        : null;
    return _ForegroundAttribution.matched(target);
  }

  Future<void> _replayAdjacentForegroundResponses(
    DatabaseClient transaction,
    Map<String, OutreachFeedbackEntry> entries, {
    required Iterable<OutreachRecord> ledgerRows,
  }) async {
    final anchors = _foregroundResponseAnchors(ledgerRows, entries);
    for (final anchorEntry in anchors.entries) {
      final expected = anchorEntry.value;
      final current = entries[expected.outreachMarker];
      if (current == null ||
          current.channel != OutreachChannel.foreground ||
          (current.outcome != null &&
              current.outcome != OutreachFeedbackOutcome.ignored)) {
        continue;
      }
      final visibleMessage = await _chatMessageStore
          .record(anchorEntry.key)
          .get(transaction);
      if (visibleMessage == null ||
          _tryProactiveMessageAnchor(visibleMessage) != expected) {
        continue;
      }
      final successor = await _chatMessageStore.find(
        transaction,
        finder: Finder(
          filter: Filter.and(<Filter>[
            Filter.greaterThan(Field.key, anchorEntry.key),
            Filter.equals('sessionId', 'self'),
          ]),
          sortOrders: <SortOrder>[SortOrder(Field.key)],
          limit: 1,
        ),
      );
      if (successor.isEmpty) continue;
      final receipt = _tryHumanMessageReceipt(successor.single.value);
      if (receipt == null) continue;
      final anchorAt = current.feedbackAnchorAt;
      if (receipt.persistedAt.isBefore(anchorAt) ||
          receipt.persistedAt.isAfter(anchorAt.add(responseWindow))) {
        continue;
      }
      entries[current.outreachId] = current.record(
        OutreachFeedbackSignal.responded,
        receipt.persistedAt,
      );
    }
  }

  static Future<void> _persistCursorIfChanged(
    DatabaseClient transaction,
    _OutreachFeedbackCursor previous,
    _OutreachFeedbackCursor next,
  ) async {
    if (previous.lastChatMessageRecordId == next.lastChatMessageRecordId &&
        previous.activatedAt == next.activatedAt &&
        previous.rolloutRevision == next.rolloutRevision &&
        previous.collecting == next.collecting) {
      return;
    }
    await _metadataStore
        .record(_activationKey)
        .put(transaction, next.toStorageJson());
  }

  static Future<void> _persistEntryChanges(
    DatabaseClient transaction,
    Map<String, OutreachFeedbackEntry> previous,
    Map<String, OutreachFeedbackEntry> next,
  ) async {
    for (final marker in previous.keys) {
      if (!next.containsKey(marker)) {
        await _store.record(marker).delete(transaction);
      }
    }
    for (final entry in next.values) {
      final prior = previous[entry.outreachId];
      if (prior == null || !_sameEntry(prior, entry)) {
        await _store
            .record(entry.outreachId)
            .put(transaction, entry.toStorageJson());
      }
    }
  }

  static Future<void> _persistMuteChanges(
    DatabaseClient transaction,
    Map<String, _OutreachMuteMarker> previous,
    Map<String, _OutreachMuteMarker> next,
  ) async {
    for (final marker in previous.keys) {
      if (!next.containsKey(marker)) {
        await _muteStore.record(marker).delete(transaction);
      }
    }
    for (final mute in next.values) {
      final prior = previous[mute.marker];
      if (prior == null || !_sameMuteMarker(prior, mute)) {
        await _muteStore
            .record(mute.marker)
            .put(transaction, mute.toStorageJson());
      }
    }
  }

  static Future<void> _persistCompactedChanges(
    DatabaseClient transaction,
    Map<String, _OutreachFeedbackContribution> previous,
    Map<String, _OutreachFeedbackContribution> next,
  ) async {
    for (final marker in previous.keys) {
      if (!next.containsKey(marker)) {
        await _compactedStore.record(marker).delete(transaction);
      }
    }
    for (final entry in next.entries) {
      if (previous[entry.key] != entry.value) {
        await _compactedStore
            .record(entry.key)
            .put(transaction, entry.value.toStorageJson());
      }
    }
  }

  static Future<void> _persistRollupIfChanged(
    DatabaseClient transaction,
    _OutreachFeedbackRollup previous,
    _OutreachFeedbackRollup next,
  ) async {
    if (previous == next) return;
    await _metadataStore
        .record(_rollupKey)
        .put(transaction, next.toStorageJson());
  }

  void _noteDuplicate() {
    final current = state.value;
    state.value = current.copyWith(
      duplicateSignals: _increment(current.duplicateSignals),
    );
  }

  void _noteRejected() {
    final current = state.value;
    state.value = current.copyWith(
      rejectedSignals: _increment(current.rejectedSignals),
    );
  }

  void _noteUnattributedResponses(int count) {
    if (count <= 0) return;
    final current = state.value;
    state.value = current.copyWith(
      unattributedResponses: math.min(
        _maximumCounter,
        current.unattributedResponses + count,
      ),
    );
  }

  void _degradeStorage() {
    if (_retiring ||
        isClosed ||
        _lifecycle == _OutreachFeedbackLifecycle.retired) {
      return;
    }
    final storageErrors = _increment(state.value.storageErrors);
    _lifecycle = _OutreachFeedbackLifecycle.degraded;
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    state.value = OutreachFeedbackSnapshot(storageErrors: storageErrors);
  }

  @override
  void onClose() {
    _retiring = true;
    _lifecycle = _OutreachFeedbackLifecycle.retired;
    _featureFlagWorker?.dispose();
    _featureFlagWorker = null;
    _reconcileTimer?.cancel();
    state.value = const OutreachFeedbackSnapshot();
    super.onClose();
  }

  static OutreachResponseLatencyBucket _latencyBucket(Duration latency) {
    if (latency < const Duration(minutes: 1)) {
      return OutreachResponseLatencyBucket.under1Minute;
    }
    if (latency < const Duration(minutes: 5)) {
      return OutreachResponseLatencyBucket.under5Minutes;
    }
    if (latency < const Duration(minutes: 30)) {
      return OutreachResponseLatencyBucket.under30Minutes;
    }
    if (latency < const Duration(hours: 2)) {
      return OutreachResponseLatencyBucket.under2Hours;
    }
    return OutreachResponseLatencyBucket.twoHoursOrMore;
  }

  static int _increment(int value) =>
      value >= _maximumCounter ? _maximumCounter : value + 1;

  static Map<T, int> _snapshotCounts<T>(Map<T, int> source) => <T, int>{
    for (final entry in source.entries)
      if (entry.value > 0) entry.key: math.min(_maximumCounter, entry.value),
  };
}

/// Sufficient statistics for one resolved outreach lifecycle.
///
/// This value deliberately contains no timestamp or raw outreach identifier.
/// The Sembast record key is already a domain-separated digest.
final class _OutreachFeedbackContribution {
  const _OutreachFeedbackContribution({
    required this.eventMask,
    required this.outcome,
    required this.channel,
    required this.responseLatencyBucket,
  });

  static const int schemaVersion = 1;
  static final int _allEventBits =
      (1 << OutreachFeedbackSignal.values.length) - 1;
  static final _OutreachFeedbackContribution mute =
      _OutreachFeedbackContribution(
        eventMask: 1 << OutreachFeedbackSignal.muted.index,
        outcome: OutreachFeedbackOutcome.muted,
        channel: null,
        responseLatencyBucket: null,
      );

  final int eventMask;
  final OutreachFeedbackOutcome outcome;
  final OutreachChannel? channel;
  final OutreachResponseLatencyBucket? responseLatencyBucket;

  bool hasEvent(OutreachFeedbackSignal signal) =>
      eventMask & (1 << signal.index) != 0;

  factory _OutreachFeedbackContribution.fromEntry(OutreachFeedbackEntry entry) {
    final outcome = entry.outcome;
    if (outcome == null) {
      throw StateError('pending outreach cannot be compacted');
    }
    var eventMask = 1 << OutreachFeedbackSignal.delivered.index;
    if (entry.openedAt != null) {
      eventMask |= 1 << OutreachFeedbackSignal.opened.index;
    }
    if (entry.respondedAt != null) {
      eventMask |= 1 << OutreachFeedbackSignal.responded.index;
    }
    if (entry.dismissedAt != null) {
      eventMask |= 1 << OutreachFeedbackSignal.dismissed.index;
    }
    if (entry.ignoredAt != null) {
      eventMask |= 1 << OutreachFeedbackSignal.ignored.index;
    }
    if (entry.mutedAt != null) {
      eventMask |= 1 << OutreachFeedbackSignal.muted.index;
    }
    return _OutreachFeedbackContribution(
      eventMask: eventMask,
      outcome: outcome,
      channel: entry.channel,
      responseLatencyBucket: entry.responseLatency == null
          ? null
          : OutreachFeedbackCollector._latencyBucket(entry.responseLatency!),
    );
  }

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'eventMask': eventMask,
    'outcome': outcome.name,
    'channel': channel?.name,
    'responseLatencyBucket': responseLatencyBucket?.name,
  };

  factory _OutreachFeedbackContribution.fromStorageJson(
    String marker,
    Map<String, Object?> json,
  ) {
    _validateOutreachId(marker);
    const fields = <String>{
      'schemaVersion',
      'eventMask',
      'outcome',
      'channel',
      'responseLatencyBucket',
    };
    final eventMask = json['eventMask'];
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion ||
        eventMask is! int ||
        eventMask <= 0 ||
        eventMask & ~_allEventBits != 0) {
      throw const FormatException('compacted outreach fields are invalid');
    }
    final outcome = _readStoredEnum(
      OutreachFeedbackOutcome.values,
      json['outcome'],
      'outcome',
    );
    final channel = _readStoredEnum(
      OutreachChannel.values,
      json['channel'],
      'channel',
    );
    final bucketSource = json['responseLatencyBucket'];
    final bucket = bucketSource == null
        ? null
        : _readStoredEnum(
            OutreachResponseLatencyBucket.values,
            bucketSource,
            'responseLatencyBucket',
          );
    final contribution = _OutreachFeedbackContribution(
      eventMask: eventMask,
      outcome: outcome,
      channel: channel,
      responseLatencyBucket: bucket,
    );
    contribution._validateOutreachSemantics();
    return contribution;
  }

  void _validateOutreachSemantics() {
    final derivedOutcome = hasEvent(OutreachFeedbackSignal.muted)
        ? OutreachFeedbackOutcome.muted
        : hasEvent(OutreachFeedbackSignal.responded)
        ? OutreachFeedbackOutcome.responded
        : hasEvent(OutreachFeedbackSignal.dismissed)
        ? OutreachFeedbackOutcome.dismissed
        : hasEvent(OutreachFeedbackSignal.ignored)
        ? OutreachFeedbackOutcome.ignored
        : null;
    if (channel == null ||
        !hasEvent(OutreachFeedbackSignal.delivered) ||
        derivedOutcome != outcome ||
        (outcome == OutreachFeedbackOutcome.responded) !=
            (responseLatencyBucket != null)) {
      throw const FormatException('compacted outreach is inconsistent');
    }
    if (outcome == OutreachFeedbackOutcome.dismissed &&
        !hasEvent(OutreachFeedbackSignal.dismissed)) {
      throw const FormatException('compacted dismissal is inconsistent');
    }
    if (outcome == OutreachFeedbackOutcome.ignored &&
        !hasEvent(OutreachFeedbackSignal.ignored)) {
      throw const FormatException('compacted ignore is inconsistent');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _OutreachFeedbackContribution &&
      eventMask == other.eventMask &&
      outcome == other.outcome &&
      channel == other.channel &&
      responseLatencyBucket == other.responseLatencyBucket;

  @override
  int get hashCode =>
      Object.hash(eventMask, outcome, channel, responseLatencyBucket);
}

/// Fixed-cardinality, reversible aggregate for compacted facts.
final class _OutreachFeedbackRollup {
  _OutreachFeedbackRollup({
    required this.events,
    required this.outcomes,
    required this.channelDeliveries,
    required this.responseLatencyBuckets,
  });

  static const int schemaVersion = 1;

  factory _OutreachFeedbackRollup.empty() => _OutreachFeedbackRollup(
    events: <OutreachFeedbackSignal, int>{},
    outcomes: <OutreachFeedbackOutcome, int>{},
    channelDeliveries: <OutreachChannel, int>{},
    responseLatencyBuckets: <OutreachResponseLatencyBucket, int>{},
  );

  final Map<OutreachFeedbackSignal, int> events;
  final Map<OutreachFeedbackOutcome, int> outcomes;
  final Map<OutreachChannel, int> channelDeliveries;
  final Map<OutreachResponseLatencyBucket, int> responseLatencyBuckets;

  _OutreachFeedbackRollup copy() => _OutreachFeedbackRollup(
    events: <OutreachFeedbackSignal, int>{...events},
    outcomes: <OutreachFeedbackOutcome, int>{...outcomes},
    channelDeliveries: <OutreachChannel, int>{...channelDeliveries},
    responseLatencyBuckets: <OutreachResponseLatencyBucket, int>{
      ...responseLatencyBuckets,
    },
  );

  void add(_OutreachFeedbackContribution contribution) {
    for (final signal in OutreachFeedbackSignal.values) {
      if (contribution.hasEvent(signal)) _addStoredCount(events, signal);
    }
    _addStoredCount(outcomes, contribution.outcome);
    final channel = contribution.channel;
    if (channel != null) _addStoredCount(channelDeliveries, channel);
    final bucket = contribution.responseLatencyBucket;
    if (bucket != null) _addStoredCount(responseLatencyBuckets, bucket);
  }

  void remove(_OutreachFeedbackContribution contribution) {
    for (final signal in OutreachFeedbackSignal.values) {
      if (contribution.hasEvent(signal)) _removeStoredCount(events, signal);
    }
    _removeStoredCount(outcomes, contribution.outcome);
    final channel = contribution.channel;
    if (channel != null) _removeStoredCount(channelDeliveries, channel);
    final bucket = contribution.responseLatencyBucket;
    if (bucket != null) _removeStoredCount(responseLatencyBuckets, bucket);
  }

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'events': _storedNamedCounts(OutreachFeedbackSignal.values, events),
    'outcomes': _storedNamedCounts(OutreachFeedbackOutcome.values, outcomes),
    'channelDeliveries': _storedNamedCounts(
      OutreachChannel.values,
      channelDeliveries,
    ),
    'responseLatencyBuckets': _storedNamedCounts(
      OutreachResponseLatencyBucket.values,
      responseLatencyBuckets,
    ),
  };

  factory _OutreachFeedbackRollup.fromStorageJson(Map<String, Object?> json) {
    const fields = <String>{
      'schemaVersion',
      'events',
      'outcomes',
      'channelDeliveries',
      'responseLatencyBuckets',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException('outreach feedback rollup is invalid');
    }
    return _OutreachFeedbackRollup(
      events: _readStoredCounts(
        OutreachFeedbackSignal.values,
        json['events'],
        'events',
      ),
      outcomes: _readStoredCounts(
        OutreachFeedbackOutcome.values,
        json['outcomes'],
        'outcomes',
      ),
      channelDeliveries: _readStoredCounts(
        OutreachChannel.values,
        json['channelDeliveries'],
        'channelDeliveries',
      ),
      responseLatencyBuckets: _readStoredCounts(
        OutreachResponseLatencyBucket.values,
        json['responseLatencyBuckets'],
        'responseLatencyBuckets',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _OutreachFeedbackRollup &&
      _sameCounts(events, other.events) &&
      _sameCounts(outcomes, other.outcomes) &&
      _sameCounts(channelDeliveries, other.channelDeliveries) &&
      _sameCounts(responseLatencyBuckets, other.responseLatencyBuckets);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(
      OutreachFeedbackSignal.values.map((value) => events[value] ?? 0),
    ),
    Object.hashAll(
      OutreachFeedbackOutcome.values.map((value) => outcomes[value] ?? 0),
    ),
    Object.hashAll(
      OutreachChannel.values.map((value) => channelDeliveries[value] ?? 0),
    ),
    Object.hashAll(
      OutreachResponseLatencyBucket.values.map(
        (value) => responseLatencyBuckets[value] ?? 0,
      ),
    ),
  );
}

final class _OutreachFeedbackCursor {
  const _OutreachFeedbackCursor({
    required this.activatedAt,
    required this.lastChatMessageRecordId,
    required this.rolloutRevision,
    required this.collecting,
  });

  static const int schemaVersion = 1;

  final DateTime activatedAt;
  final int lastChatMessageRecordId;
  final int rolloutRevision;
  final bool collecting;

  _OutreachFeedbackCursor copyWith({int? lastChatMessageRecordId}) =>
      _OutreachFeedbackCursor(
        activatedAt: activatedAt,
        lastChatMessageRecordId:
            lastChatMessageRecordId ?? this.lastChatMessageRecordId,
        rolloutRevision: rolloutRevision,
        collecting: collecting,
      );

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'activatedAt': _writeDate(activatedAt),
    'lastChatMessageRecordId': lastChatMessageRecordId,
    'rolloutRevision': rolloutRevision,
    'collecting': collecting,
  };

  factory _OutreachFeedbackCursor.fromStorageJson(Map<String, Object?> json) {
    const fields = <String>{
      'schemaVersion',
      'activatedAt',
      'lastChatMessageRecordId',
      'rolloutRevision',
      'collecting',
    };
    final recordId = json['lastChatMessageRecordId'];
    final revision = json['rolloutRevision'];
    final collecting = json['collecting'];
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion ||
        recordId is! int ||
        recordId < 0 ||
        revision is! int ||
        revision < 0 ||
        revision > _maximumStoredRevision ||
        collecting is! bool ||
        (collecting != (revision > 0))) {
      throw const FormatException('outreach feedback cursor is invalid');
    }
    return _OutreachFeedbackCursor(
      activatedAt: _readDate(json['activatedAt'], 'activatedAt'),
      lastChatMessageRecordId: recordId,
      rolloutRevision: revision,
      collecting: collecting,
    );
  }
}

final class _HumanMessageReceipt {
  const _HumanMessageReceipt({required this.persistedAt});

  final DateTime persistedAt;
}

final class _ForegroundResponseAnchor {
  const _ForegroundResponseAnchor({
    required this.outreachMarker,
    required this.idempotencyKey,
  });

  final String outreachMarker;
  final String idempotencyKey;

  @override
  bool operator ==(Object other) =>
      other is _ForegroundResponseAnchor &&
      outreachMarker == other.outreachMarker &&
      idempotencyKey == other.idempotencyKey;

  @override
  int get hashCode => Object.hash(outreachMarker, idempotencyKey);
}

final class _ForegroundAttribution {
  const _ForegroundAttribution.matched(this.target) : matched = true;

  const _ForegroundAttribution.unmatched() : matched = false, target = null;

  final bool matched;
  final OutreachFeedbackEntry? target;
}

final class _HumanMessageReplay {
  const _HumanMessageReplay({
    required this.cursor,
    required this.targetResult,
    required this.unattributedResponses,
  });

  final _OutreachFeedbackCursor cursor;
  final OutreachFeedbackMutationResult? targetResult;
  final int unattributedResponses;
}

final class _OutreachRolloutSuperseded implements Exception {
  const _OutreachRolloutSuperseded();
}

final class _OutreachProjection {
  const _OutreachProjection({
    required this.outreachId,
    required this.channel,
    required this.deliveredAt,
    this.openedAt,
  });

  final String outreachId;
  final OutreachChannel channel;
  final DateTime deliveredAt;
  final DateTime? openedAt;
}

final class _OutreachMuteState {
  const _OutreachMuteState({
    required this.active,
    required this.preferenceRevision,
  });

  static const int schemaVersion = 1;

  final bool active;
  final int preferenceRevision;

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'active': active,
    'preferenceRevision': preferenceRevision,
  };

  factory _OutreachMuteState.fromStorageJson(Map<String, Object?> json) {
    const fields = <String>{'schemaVersion', 'active', 'preferenceRevision'};
    final active = json['active'];
    final revision = json['preferenceRevision'];
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion ||
        active is! bool ||
        revision is! int ||
        revision < 0 ||
        revision > _maximumStoredRevision ||
        (active && revision == 0)) {
      throw const FormatException('outreach mute state is invalid');
    }
    return _OutreachMuteState(active: active, preferenceRevision: revision);
  }
}

final class _OutreachMuteMarker {
  const _OutreachMuteMarker({
    required this.marker,
    required this.preferenceRevision,
    required this.recordedAt,
  });

  static const int schemaVersion = 1;

  final String marker;
  final int preferenceRevision;
  final DateTime recordedAt;

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'preferenceRevision': preferenceRevision,
    'recordedAt': _writeDate(recordedAt),
  };

  factory _OutreachMuteMarker.fromStorageJson(
    String marker,
    Map<String, Object?> json,
  ) {
    const fields = <String>{
      'schemaVersion',
      'preferenceRevision',
      'recordedAt',
    };
    final revision = json['preferenceRevision'];
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != schemaVersion ||
        revision is! int ||
        revision < 1 ||
        revision > _maximumStoredRevision ||
        marker != _muteMarker(revision)) {
      throw const FormatException('outreach mute marker is invalid');
    }
    return _OutreachMuteMarker(
      marker: marker,
      preferenceRevision: revision,
      recordedAt: _readDate(json['recordedAt'], 'recordedAt'),
    );
  }
}

bool _sameEntry(OutreachFeedbackEntry left, OutreachFeedbackEntry right) =>
    left.outreachId == right.outreachId &&
    left.channel == right.channel &&
    left.deliveredAt == right.deliveredAt &&
    left.openedAt == right.openedAt &&
    left.respondedAt == right.respondedAt &&
    left.dismissedAt == right.dismissedAt &&
    left.ignoredAt == right.ignoredAt &&
    left.mutedAt == right.mutedAt;

bool _sameMuteMarker(_OutreachMuteMarker left, _OutreachMuteMarker right) =>
    left.marker == right.marker &&
    left.preferenceRevision == right.preferenceRevision &&
    left.recordedAt == right.recordedAt;

int _compareFeedbackEntries(
  OutreachFeedbackEntry left,
  OutreachFeedbackEntry right,
) {
  final byTime = left.outcomeAt!.compareTo(right.outcomeAt!);
  return byTime != 0 ? byTime : left.outreachId.compareTo(right.outreachId);
}

int _compareMuteMarkers(_OutreachMuteMarker left, _OutreachMuteMarker right) {
  final byTime = left.recordedAt.compareTo(right.recordedAt);
  return byTime != 0 ? byTime : left.marker.compareTo(right.marker);
}

void _addStoredCount<T>(Map<T, int> counts, T key) {
  final current = counts[key] ?? 0;
  if (current >= _maximumStoredRevision) {
    throw StateError('outreach feedback rollup overflow');
  }
  counts[key] = current + 1;
}

void _removeStoredCount<T>(Map<T, int> counts, T key) {
  final current = counts[key] ?? 0;
  if (current < 1) {
    throw const FormatException('outreach feedback rollup underflow');
  }
  if (current == 1) {
    counts.remove(key);
  } else {
    counts[key] = current - 1;
  }
}

Map<String, int> _storedNamedCounts<T extends Enum>(
  Iterable<T> values,
  Map<T, int> counts,
) => <String, int>{for (final value in values) value.name: counts[value] ?? 0};

Map<T, int> _readStoredCounts<T extends Enum>(
  Iterable<T> values,
  Object? source,
  String field,
) {
  final expected = values.toList(growable: false);
  if (source is! Map || source.length != expected.length) {
    throw FormatException('$field counts are invalid');
  }
  final result = <T, int>{};
  for (final value in expected) {
    if (!source.containsKey(value.name)) {
      throw FormatException('$field counts are invalid');
    }
    final count = source[value.name];
    if (count is! int || count < 0 || count > _maximumStoredRevision) {
      throw FormatException('$field counts are invalid');
    }
    if (count > 0) result[value] = count;
  }
  return result;
}

T _readStoredEnum<T extends Enum>(
  Iterable<T> values,
  Object? source,
  String field,
) {
  final matches = values.where((value) => value.name == source);
  if (matches.length != 1) throw FormatException('$field is invalid');
  return matches.single;
}

bool _sameCounts<T>(Map<T, int> left, Map<T, int> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

Map<String, int> _namedCounts<T extends Enum>(
  Iterable<T> values,
  Map<T, int> counts,
) => <String, int>{for (final value in values) value.name: counts[value] ?? 0};

String _writeDate(DateTime value) => value.toUtc().toIso8601String();

String? _writeOptionalDate(DateTime? value) =>
    value == null ? null : _writeDate(value);

DateTime _readDate(Object? source, String field) {
  if (source is! String || source.isEmpty || !source.endsWith('Z')) {
    throw FormatException('$field is invalid');
  }
  final parsed = DateTime.tryParse(source);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != source) {
    throw FormatException('$field is invalid');
  }
  return parsed;
}

DateTime? _readOptionalDateAfter(Object? source, String field, DateTime floor) {
  if (source == null) return null;
  final parsed = _readDate(source, field);
  if (parsed.isBefore(floor)) throw FormatException('$field predates delivery');
  return parsed;
}

DateTime _earlier(DateTime left, DateTime right) =>
    left.isBefore(right) ? left : right;

DateTime? _earlierOptional(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return _earlier(left, right);
}

String? _tryOutreachId(String source) {
  final value = source.trim();
  if (value.isEmpty || value.length > 256) return null;
  return value;
}

void _validateOutreachId(String source) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(source)) {
    throw const FormatException('outreach id is invalid');
  }
}

bool _isObservableSince(OutreachRecord record, DateTime activatedAt) {
  final observedAt = record.channel == OutreachChannel.foreground
      ? record.deliveredAt ?? record.committedAt
      : record.notificationInteractionClaimedAt ??
            record.expiresAt ??
            record.assumedDeliveredAt ??
            record.scheduledFor;
  return observedAt != null && !observedAt.isBefore(activatedAt);
}

_HumanMessageReceipt? _tryHumanMessageReceipt(Map<String, Object?> json) {
  if (json['isUserMessage'] != true || json['sessionId'] != 'self') return null;
  final origin = json['turnOrigin'];
  if (origin != null && origin != 'user' && origin != 'voice') {
    return null;
  }
  try {
    return _HumanMessageReceipt(
      persistedAt: _readChatTimestamp(json['timestamp']),
    );
  } on FormatException {
    return null;
  }
}

_ForegroundResponseAnchor? _tryProactiveMessageAnchor(
  Map<String, Object?> json,
) {
  if (json['sessionId'] != 'self' ||
      json['isUserMessage'] != false ||
      json['turnOrigin'] != ChatMessageTurnOrigins.proactivePresence ||
      json['senderId'] is! String ||
      json['senderId'] == 'user' ||
      json['receiverId'] != 'user' ||
      json['content'] is! String) {
    return null;
  }
  final outreachSource = json['outreachId'];
  final idempotencySource = json['idempotencyKey'];
  if (outreachSource is! String || idempotencySource is! String) return null;
  final outreachId = _tryOutreachId(outreachSource);
  final idempotencyKey = idempotencySource.trim();
  if (outreachId == null || idempotencyKey != 'proactive:$outreachId') {
    return null;
  }
  try {
    _readChatTimestamp(json['timestamp']);
  } on FormatException {
    return null;
  }
  return _ForegroundResponseAnchor(
    outreachMarker: _outreachMarker(outreachId),
    idempotencyKey: idempotencyKey,
  );
}

DateTime _readChatTimestamp(Object? source) {
  if (source is! String || source.isEmpty || !source.endsWith('Z')) {
    throw const FormatException('chat timestamp is invalid');
  }
  final parsed = DateTime.tryParse(source);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != source) {
    throw const FormatException('chat timestamp is invalid');
  }
  return parsed;
}

DateTime _later(DateTime left, DateTime right) =>
    left.isAfter(right) ? left : right;

String _muteMarker(int preferenceRevision) => sha256
    .convert(utf8.encode('maaso-outreach-feedback-mute-v1|$preferenceRevision'))
    .toString();

String _outreachMarker(String outreachId) => sha256
    .convert(utf8.encode('maaso-outreach-feedback-subject-v1|$outreachId'))
    .toString();
