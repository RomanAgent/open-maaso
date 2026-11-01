import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

/// Durable lifecycle states for one agent-initiated outreach attempt.
enum OutreachState {
  candidateReserved,
  generating,
  committed,
  delivered,
  suppressed,
  abandoned,
  scheduledOs,
  assumedDelivered,
  cancelled,
}

/// The user-visible surface an outreach is intended for.
enum OutreachChannel { foreground, osNotification }

/// Immutable persisted view of an outreach lifecycle entry.
final class OutreachRecord {
  const OutreachRecord({
    required this.outreachId,
    required this.channel,
    required this.state,
    required this.topicKey,
    required this.createdAt,
    required this.updatedAt,
    this.sourceEventId,
    this.deliveryId,
    this.evidenceKey,
    this.reservationToken,
    this.leaseUntil,
    this.expiresAt,
    this.scheduledFor,
    this.normalizedFingerprint,
    this.nearDuplicateFeatures = const <String>{},
    this.lastAttemptAt,
    this.committedAt,
    this.deliveredAt,
    this.suppressedAt,
    this.abandonedAt,
    this.assumedDeliveredAt,
    this.cancelledAt,
    this.notificationInteractionClaimedAt,
    this.terminalReason,
    this.visibleMessageIdempotencyKey,
    this.visibleMessageRecordId,
  });

  final String outreachId;
  final String? sourceEventId;
  final String? deliveryId;
  final OutreachChannel channel;
  final OutreachState state;
  final String topicKey;
  final String? evidenceKey;
  final String? reservationToken;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? leaseUntil;
  final DateTime? expiresAt;
  final DateTime? scheduledFor;
  final String? normalizedFingerprint;
  final Set<String> nearDuplicateFeatures;
  final DateTime? lastAttemptAt;
  final DateTime? committedAt;
  final DateTime? deliveredAt;
  final DateTime? suppressedAt;
  final DateTime? abandonedAt;
  final DateTime? assumedDeliveredAt;
  final DateTime? cancelledAt;
  final DateTime? notificationInteractionClaimedAt;
  final String? terminalReason;
  final String? visibleMessageIdempotencyKey;
  final int? visibleMessageRecordId;

  bool get hasActiveLease =>
      state == OutreachState.candidateReserved ||
      state == OutreachState.generating;

  bool get countsTowardForegroundBudget =>
      channel == OutreachChannel.foreground && committedAt != null;

  bool get countsTowardScheduledBudget =>
      channel == OutreachChannel.osNotification &&
      committedAt == null &&
      (state == OutreachState.scheduledOs ||
          state == OutreachState.assumedDelivered);

  /// Timestamp used by cooldown, novelty, and retention policy.
  ///
  /// This follows the user-visible occurrence rather than [createdAt]. An OS
  /// notification may be created weeks before it is scheduled to appear and
  /// must still count as fresh when that day arrives.
  DateTime? get historyAt => switch (state) {
    OutreachState.committed => committedAt ?? updatedAt,
    OutreachState.delivered => deliveredAt ?? committedAt ?? updatedAt,
    OutreachState.scheduledOs => scheduledFor ?? createdAt,
    OutreachState.assumedDelivered =>
      assumedDeliveredAt ?? scheduledFor ?? updatedAt,
    OutreachState.candidateReserved ||
    OutreachState.generating ||
    OutreachState.suppressed ||
    OutreachState.abandoned ||
    OutreachState.cancelled => null,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'outreachId': outreachId,
    'sourceEventId': sourceEventId,
    'deliveryId': deliveryId,
    'channel': channel.name,
    'state': state.name,
    'topicKey': topicKey,
    'evidenceKey': evidenceKey,
    'reservationToken': reservationToken,
    'createdAt': _writeDate(createdAt),
    'updatedAt': _writeDate(updatedAt),
    'historyAt': _writeOptionalDate(historyAt),
    'leaseUntil': _writeOptionalDate(leaseUntil),
    'expiresAt': _writeOptionalDate(expiresAt),
    'scheduledFor': _writeOptionalDate(scheduledFor),
    'normalizedFingerprint': normalizedFingerprint,
    'nearDuplicateFeatures': nearDuplicateFeatures.toList()..sort(),
    'lastAttemptAt': _writeOptionalDate(lastAttemptAt),
    'committedAt': _writeOptionalDate(committedAt),
    'deliveredAt': _writeOptionalDate(deliveredAt),
    'suppressedAt': _writeOptionalDate(suppressedAt),
    'abandonedAt': _writeOptionalDate(abandonedAt),
    'assumedDeliveredAt': _writeOptionalDate(assumedDeliveredAt),
    'cancelledAt': _writeOptionalDate(cancelledAt),
    'notificationInteractionClaimedAt': _writeOptionalDate(
      notificationInteractionClaimedAt,
    ),
    'terminalReason': terminalReason,
    'visibleMessageIdempotencyKey': visibleMessageIdempotencyKey,
    'visibleMessageRecordId': visibleMessageRecordId,
  };

  factory OutreachRecord.fromJson(Map<String, Object?> json) {
    final outreachId = _requiredString(json, 'outreachId');
    final topicKey = _requiredString(json, 'topicKey');
    return OutreachRecord(
      outreachId: outreachId,
      sourceEventId: _optionalStoredString(json, 'sourceEventId'),
      deliveryId: _optionalStoredString(json, 'deliveryId'),
      channel: _readEnum(
        OutreachChannel.values,
        _requiredString(json, 'channel'),
        'channel',
      ),
      state: _readEnum(
        OutreachState.values,
        _requiredString(json, 'state'),
        'state',
      ),
      topicKey: topicKey,
      evidenceKey: _optionalStoredString(json, 'evidenceKey'),
      reservationToken: _optionalStoredString(json, 'reservationToken'),
      createdAt: _readDate(json, 'createdAt'),
      updatedAt: _readDate(json, 'updatedAt'),
      leaseUntil: _readOptionalDate(json, 'leaseUntil'),
      expiresAt: _readOptionalDate(json, 'expiresAt'),
      scheduledFor: _readOptionalDate(json, 'scheduledFor'),
      normalizedFingerprint: _optionalStoredString(
        json,
        'normalizedFingerprint',
      ),
      nearDuplicateFeatures: _readStringSet(json, 'nearDuplicateFeatures'),
      lastAttemptAt: _readOptionalDate(json, 'lastAttemptAt'),
      committedAt: _readOptionalDate(json, 'committedAt'),
      deliveredAt: _readOptionalDate(json, 'deliveredAt'),
      suppressedAt: _readOptionalDate(json, 'suppressedAt'),
      abandonedAt: _readOptionalDate(json, 'abandonedAt'),
      assumedDeliveredAt: _readOptionalDate(json, 'assumedDeliveredAt'),
      cancelledAt: _readOptionalDate(json, 'cancelledAt'),
      notificationInteractionClaimedAt: _readOptionalDate(
        json,
        'notificationInteractionClaimedAt',
      ),
      terminalReason: _optionalStoredString(json, 'terminalReason'),
      visibleMessageIdempotencyKey: _optionalStoredString(
        json,
        'visibleMessageIdempotencyKey',
      ),
      visibleMessageRecordId: _optionalStoredInt(
        json,
        'visibleMessageRecordId',
      ),
    );
  }

  OutreachRecord copyWith({
    OutreachState? state,
    DateTime? updatedAt,
    DateTime? leaseUntil,
    bool clearLeaseUntil = false,
    String? normalizedFingerprint,
    Set<String>? nearDuplicateFeatures,
    DateTime? lastAttemptAt,
    DateTime? committedAt,
    DateTime? deliveredAt,
    DateTime? suppressedAt,
    DateTime? abandonedAt,
    DateTime? assumedDeliveredAt,
    DateTime? cancelledAt,
    bool clearCancelledAt = false,
    DateTime? notificationInteractionClaimedAt,
    String? terminalReason,
    bool clearTerminalReason = false,
    String? visibleMessageIdempotencyKey,
    int? visibleMessageRecordId,
  }) {
    return OutreachRecord(
      outreachId: outreachId,
      sourceEventId: sourceEventId,
      deliveryId: deliveryId,
      channel: channel,
      state: state ?? this.state,
      topicKey: topicKey,
      evidenceKey: evidenceKey,
      reservationToken: reservationToken,
      createdAt: createdAt,
      updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
      leaseUntil: clearLeaseUntil ? null : leaseUntil ?? this.leaseUntil,
      expiresAt: expiresAt,
      scheduledFor: scheduledFor,
      normalizedFingerprint:
          normalizedFingerprint ?? this.normalizedFingerprint,
      nearDuplicateFeatures:
          nearDuplicateFeatures ?? this.nearDuplicateFeatures,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      committedAt: committedAt ?? this.committedAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      suppressedAt: suppressedAt ?? this.suppressedAt,
      abandonedAt: abandonedAt ?? this.abandonedAt,
      assumedDeliveredAt: assumedDeliveredAt ?? this.assumedDeliveredAt,
      cancelledAt: clearCancelledAt ? null : cancelledAt ?? this.cancelledAt,
      notificationInteractionClaimedAt:
          notificationInteractionClaimedAt ??
          this.notificationInteractionClaimedAt,
      terminalReason: clearTerminalReason
          ? null
          : terminalReason ?? this.terminalReason,
      visibleMessageIdempotencyKey:
          visibleMessageIdempotencyKey ?? this.visibleMessageIdempotencyKey,
      visibleMessageRecordId:
          visibleMessageRecordId ?? this.visibleMessageRecordId,
    );
  }
}

/// Capability returned to the generator for one active account lease.
final class OutreachReservation {
  const OutreachReservation({
    required this.outreachId,
    required this.reservationToken,
    required this.leaseUntil,
    required this.expiresAt,
    required this.reused,
  });

  final String outreachId;
  final String reservationToken;
  final DateTime leaseUntil;
  final DateTime? expiresAt;

  /// True when an identical [OutreachRecord.sourceEventId] retried while its
  /// original lease was still active.
  final bool reused;
}

/// Budget-relevant counts and timestamps for a half-open time interval.
final class OutreachLedgerStats {
  const OutreachLedgerStats({
    required this.foregroundCommitted,
    required this.osScheduled,
    this.lastAttemptAt,
    this.lastCommittedAt,
    this.lastDeliveredAt,
  });

  final int foregroundCommitted;
  final int osScheduled;
  final DateTime? lastAttemptAt;
  final DateTime? lastCommittedAt;
  final DateTime? lastDeliveredAt;

  int get totalBudgeted => foregroundCommitted + osScheduled;
}

/// Raised when another transaction consumed the final shared daily slot after
/// policy evaluation but before a foreground draft could be committed.
final class OutreachDailyBudgetExceeded implements Exception {
  const OutreachDailyBudgetExceeded({required this.limit});

  final int limit;

  @override
  String toString() => 'Proactive outreach daily budget exhausted ($limit)';
}

typedef OutreachCommitTransactionHook =
    FutureOr<void> Function(
      DatabaseClient transaction,
      OutreachRecord committedRecord,
    );

/// Bounded storage policy for full outreach lifecycle rows.
///
/// Compact hashed source/evidence tombstones are intentionally durable: source
/// events are exactly-once, and relationship evidence stays consumed until its
/// evidence key changes. The account database lifecycle remains their storage
/// boundary.
final class OutreachLedgerRetention {
  const OutreachLedgerRetention({
    this.historyCount = 32,
    this.historyAge = const Duration(days: 30),
    this.diagnosticCount = 16,
    this.diagnosticAge = const Duration(days: 7),
  }) : assert(historyCount >= 0),
       assert(diagnosticCount >= 0);

  final int historyCount;
  final Duration historyAge;
  final int diagnosticCount;
  final Duration diagnosticAge;
}

/// Account-scoped transactional source of truth for proactive outreach.
///
/// The supplied [DBService] already points at an account-specific database.
/// Keeping the ledger in that database makes account switches a hard storage
/// boundary without adding a second database lifecycle.
final class ProactiveOutreachLedger extends AppService {
  ProactiveOutreachLedger({
    required DBService accountDatabase,
    DateTime Function()? clock,
    String Function()? idFactory,
    this.retention = const OutreachLedgerRetention(),
  }) : _accountDatabase = accountDatabase,
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? _randomOpaqueId;

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('proactive_outreach_ledger.v1');
  static final StoreRef<String, Map<String, Object?>> _markers =
      StoreRef<String, Map<String, Object?>>('proactive_outreach_markers.v1');

  // Keep this exact store name aligned with DBService._messages. The field is
  // intentionally local because DBService's persistence API remains unchanged.
  static final StoreRef<int, Map<String, Object?>> _chatMessages =
      intMapStoreFactory.store('chat_messages');

  final DBService _accountDatabase;
  final DateTime Function() _clock;
  final String Function() _idFactory;
  final OutreachLedgerRetention retention;

  Database get _db => _accountDatabase.raw;

  /// Atomically reserves the account's single foreground generation lease.
  ///
  /// A non-empty [sourceEventId] is exactly-once: an in-flight retry receives
  /// the same reservation, while any terminal or committed retry is denied.
  /// Null/blank source IDs are intentionally anonymous and never collide.
  Future<OutreachReservation?> reserve({
    String? sourceEventId,
    OutreachChannel channel = OutreachChannel.foreground,
    required String topicKey,
    String? evidenceKey,
    Duration leaseDuration = const Duration(minutes: 2),
    DateTime? expiresAt,
    int? dailyBudgetLimit,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final source = _optionalInput(sourceEventId, 'sourceEventId');
    final topic = _requiredInput(topicKey, 'topicKey');
    final evidence = _optionalInput(evidenceKey, 'evidenceKey');
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'must be positive',
      );
    }
    if (dailyBudgetLimit != null && dailyBudgetLimit < 0) {
      throw ArgumentError.value(
        dailyBudgetLimit,
        'dailyBudgetLimit',
        'must not be negative',
      );
    }
    final hardExpiry = expiresAt?.toUtc();
    if (hardExpiry != null && !hardExpiry.isAfter(timestamp)) return null;
    final leaseUntil = timestamp.add(leaseDuration);
    final effectiveLeaseUntil =
        hardExpiry != null && hardExpiry.isBefore(leaseUntil)
        ? hardExpiry
        : leaseUntil;

    return _db.transaction((transaction) async {
      await _recoverAndPrune(transaction, timestamp);

      if (source != null) {
        final existing = await _findBySource(transaction, source);
        if (existing != null) {
          if (existing.hasActiveLease &&
              existing.leaseUntil != null &&
              existing.leaseUntil!.isAfter(timestamp)) {
            return _reservation(existing, reused: true);
          }
          return null;
        }
        if (await _hasMarker(transaction, 'source', source)) return null;
      }
      if (evidence != null &&
          await _evidenceOccupiesUniqueness(transaction, evidence)) {
        return null;
      }

      final records = await _store.find(transaction);
      for (final snapshot in records) {
        final record = OutreachRecord.fromJson(snapshot.value);
        if (record.hasActiveLease &&
            record.leaseUntil != null &&
            record.leaseUntil!.isAfter(timestamp)) {
          return null;
        }
      }
      if (dailyBudgetLimit != null &&
          await _budgetCountForDay(
                transaction,
                timestamp,
                includeActiveReservations: true,
              ) >=
              dailyBudgetLimit) {
        return null;
      }

      final outreachId = await _uniqueId(transaction, 'outreach');
      final token = await _uniqueToken(transaction);
      final record = OutreachRecord(
        outreachId: outreachId,
        sourceEventId: source,
        channel: channel,
        state: OutreachState.candidateReserved,
        topicKey: topic,
        evidenceKey: evidence,
        reservationToken: token,
        createdAt: timestamp,
        updatedAt: timestamp,
        leaseUntil: effectiveLeaseUntil,
        expiresAt: hardExpiry,
      );
      await _store.record(outreachId).put(transaction, record.toJson());
      return _reservation(record, reused: false);
    });
  }

  /// Adds an OS notification reservation without taking the generation lease.
  Future<OutreachRecord> scheduleOs({
    String? sourceEventId,
    String? deliveryId,
    required String topicKey,
    String? evidenceKey,
    required DateTime scheduledFor,
    required DateTime expiresAt,
    DateTime? now,
  }) async {
    final scheduled = await _scheduleOs(
      sourceEventId: sourceEventId,
      deliveryId: deliveryId,
      topicKey: topicKey,
      evidenceKey: evidenceKey,
      scheduledFor: scheduledFor,
      expiresAt: expiresAt,
      now: now,
    );
    if (scheduled == null) {
      throw StateError('unbounded OS scheduling unexpectedly exhausted budget');
    }
    return scheduled;
  }

  /// Atomically reserves one OS notification occurrence under the shared
  /// account/day outreach budget. A null result means the target day's budget
  /// was already consumed by foreground or OS outreach.
  Future<OutreachRecord?> tryScheduleOs({
    required String sourceEventId,
    required String deliveryId,
    required String topicKey,
    String? evidenceKey,
    required DateTime scheduledFor,
    required DateTime expiresAt,
    required int dailyBudgetLimit,
    DateTime? now,
  }) {
    if (dailyBudgetLimit < 0) {
      throw ArgumentError.value(
        dailyBudgetLimit,
        'dailyBudgetLimit',
        'must not be negative',
      );
    }
    return _scheduleOs(
      sourceEventId: sourceEventId,
      deliveryId: deliveryId,
      topicKey: topicKey,
      evidenceKey: evidenceKey,
      scheduledFor: scheduledFor,
      expiresAt: expiresAt,
      dailyBudgetLimit: dailyBudgetLimit,
      now: now,
    );
  }

  Future<OutreachRecord?> _scheduleOs({
    String? sourceEventId,
    String? deliveryId,
    required String topicKey,
    String? evidenceKey,
    required DateTime scheduledFor,
    required DateTime expiresAt,
    int? dailyBudgetLimit,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final source = _optionalInput(sourceEventId, 'sourceEventId');
    final delivery = _optionalInput(deliveryId, 'deliveryId');
    final topic = _requiredInput(topicKey, 'topicKey');
    final evidence = _optionalInput(evidenceKey, 'evidenceKey');
    final scheduled = scheduledFor.toUtc();
    final hardExpiry = expiresAt.toUtc();
    if (scheduled.isBefore(timestamp)) {
      throw ArgumentError.value(
        scheduledFor,
        'scheduledFor',
        'must not be before now',
      );
    }
    if (!hardExpiry.isAfter(timestamp) || hardExpiry.isBefore(scheduled)) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'must be after now and not before scheduledFor',
      );
    }

    return _db.transaction((transaction) async {
      await _recoverAndPrune(transaction, timestamp);
      if (source != null) {
        final existing = await _findBySource(transaction, source);
        if (existing != null) {
          _validateOsReplay(
            existing,
            deliveryId: delivery,
            topicKey: topic,
            evidenceKey: evidence,
            scheduledFor: scheduled,
            expiresAt: hardExpiry,
          );
          if (existing.state != OutreachState.cancelled) return existing;
          if (evidence != null &&
              await _evidenceOccupiesUniqueness(transaction, evidence)) {
            return null;
          }
          if (dailyBudgetLimit != null &&
              await _budgetCountForDay(
                    transaction,
                    scheduledFor,
                    excludingOutreachId: existing.outreachId,
                    includeActiveReservations: true,
                  ) >=
                  dailyBudgetLimit) {
            return null;
          }
          final reactivated = existing.copyWith(
            state: OutreachState.scheduledOs,
            updatedAt: timestamp,
            clearCancelledAt: true,
            clearTerminalReason: true,
          );
          await _store
              .record(reactivated.outreachId)
              .put(transaction, reactivated.toJson());
          return reactivated;
        }
        if (await _hasMarker(transaction, 'source', source)) return null;
      }
      if (evidence != null &&
          await _evidenceOccupiesUniqueness(transaction, evidence)) {
        return null;
      }
      if (dailyBudgetLimit != null &&
          await _budgetCountForDay(
                transaction,
                scheduledFor,
                includeActiveReservations: true,
              ) >=
              dailyBudgetLimit) {
        return null;
      }
      final outreachId = await _uniqueId(transaction, 'scheduled');
      final record = OutreachRecord(
        outreachId: outreachId,
        sourceEventId: source,
        deliveryId: delivery,
        channel: OutreachChannel.osNotification,
        state: OutreachState.scheduledOs,
        topicKey: topic,
        evidenceKey: evidence,
        createdAt: timestamp,
        updatedAt: timestamp,
        scheduledFor: scheduled,
        expiresAt: hardExpiry,
      );
      await _store.record(outreachId).put(transaction, record.toJson());
      return record;
    });
  }

  Future<OutreachRecord> markGenerating(
    OutreachReservation reservation, {
    DateTime? now,
  }) {
    return _transitionReservation(
      reservation,
      now: now,
      allowed: const <OutreachState>{OutreachState.candidateReserved},
      idempotent: const <OutreachState>{OutreachState.generating},
      update: (record, timestamp) => record.copyWith(
        state: OutreachState.generating,
        updatedAt: timestamp,
        lastAttemptAt: timestamp,
      ),
    );
  }

  /// Atomically commits the accepted draft and, when supplied, its visible
  /// `chat_messages` row. Repeating the same commit never appends a second row.
  Future<OutreachRecord> commitAccepted(
    OutreachReservation reservation, {
    required String normalizedFingerprint,
    Set<String> nearDuplicateFeatures = const <String>{},
    Map<String, Object?>? visibleMessageJson,
    String? visibleMessageIdempotencyKey,
    OutreachCommitTransactionHook? onFirstCommit,
    int? dailyBudgetLimit,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final fingerprint = _requiredInput(
      normalizedFingerprint,
      'normalizedFingerprint',
    );
    final features = nearDuplicateFeatures
        .map((value) => _requiredInput(value, 'nearDuplicateFeatures'))
        .toSet();
    final messageKey = _messageKey(
      visibleMessageJson,
      visibleMessageIdempotencyKey,
    );
    if (dailyBudgetLimit != null && dailyBudgetLimit < 0) {
      throw ArgumentError.value(
        dailyBudgetLimit,
        'dailyBudgetLimit',
        'must not be negative',
      );
    }

    final outcome = await _db.transaction((transaction) async {
      var current = await _requiredRecord(transaction, reservation.outreachId);
      _requireToken(current, reservation);

      final isPreviouslyCommitted = current.committedAt != null;
      if (isPreviouslyCommitted) {
        if (current.normalizedFingerprint != fingerprint) {
          throw StateError('outreach was already committed with another draft');
        }
        final boundMessageKey = current.visibleMessageIdempotencyKey;
        if (current.visibleMessageRecordId != null && boundMessageKey == null) {
          throw const FormatException(
            'committed outreach visible message binding is corrupt',
          );
        }
        if (boundMessageKey != null &&
            messageKey != null &&
            messageKey != boundMessageKey) {
          throw StateError(
            'outreach was already committed with another visible message key',
          );
        }
      } else {
        current = await _recoverOne(transaction, current, timestamp);
        if (current.state != OutreachState.candidateReserved &&
            current.state != OutreachState.generating) {
          return (
            record: current,
            error: 'cannot commit outreach in ${current.state.name} state',
          );
        }
        if (dailyBudgetLimit != null &&
            await _budgetCountForDay(
                  transaction,
                  timestamp,
                  excludingOutreachId: current.outreachId,
                ) >=
                dailyBudgetLimit) {
          throw OutreachDailyBudgetExceeded(limit: dailyBudgetLimit);
        }
        current = current.copyWith(
          state: OutreachState.committed,
          updatedAt: timestamp,
          clearLeaseUntil: true,
          normalizedFingerprint: fingerprint,
          nearDuplicateFeatures: features,
          committedAt: timestamp,
        );
      }

      final visibleMessageId = await _ensureVisibleMessage(
        transaction,
        outreachId: current.outreachId,
        visibleMessageJson: visibleMessageJson,
        idempotencyKey: messageKey,
      );
      if (visibleMessageId != null &&
          current.visibleMessageRecordId != visibleMessageId) {
        current = current.copyWith(
          updatedAt: timestamp,
          visibleMessageIdempotencyKey: messageKey,
          visibleMessageRecordId: visibleMessageId,
        );
      }

      await _store
          .record(current.outreachId)
          .put(transaction, current.toJson());
      await _writeLifecycleMarkers(transaction, current, timestamp);
      if (!isPreviouslyCommitted && onFirstCommit != null) {
        await onFirstCommit(transaction, current);
      }
      return (record: current, error: null);
    });
    final error = outcome.error;
    if (error != null) throw StateError(error);
    return outcome.record;
  }

  Future<OutreachRecord> markDelivered(
    OutreachReservation reservation, {
    DateTime? now,
  }) {
    return _transitionReservation(
      reservation,
      now: now,
      allowed: const <OutreachState>{OutreachState.committed},
      idempotent: const <OutreachState>{OutreachState.delivered},
      update: (record, timestamp) => record.copyWith(
        state: OutreachState.delivered,
        updatedAt: timestamp,
        deliveredAt: timestamp,
      ),
      recoverLease: false,
    );
  }

  Future<OutreachRecord> suppress({
    required String outreachId,
    String? reservationToken,
    required String reason,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final safeReason = _requiredInput(reason, 'reason');
    return _db.transaction((transaction) async {
      final current = await _requiredRecord(transaction, outreachId);
      _requireOptionalToken(current, reservationToken);
      if (current.state == OutreachState.suppressed) return current;
      if (current.state != OutreachState.candidateReserved &&
          current.state != OutreachState.generating) {
        throw StateError(
          'cannot suppress outreach in ${current.state.name} state',
        );
      }
      final updated = current.copyWith(
        state: OutreachState.suppressed,
        updatedAt: timestamp,
        clearLeaseUntil: true,
        suppressedAt: timestamp,
        terminalReason: safeReason,
      );
      await _store.record(outreachId).put(transaction, updated.toJson());
      await _writeLifecycleMarkers(transaction, updated, timestamp);
      return updated;
    });
  }

  Future<OutreachRecord> abandon(
    OutreachReservation reservation, {
    String reason = 'generation_failed',
    DateTime? now,
  }) {
    final safeReason = _requiredInput(reason, 'reason');
    return _transitionReservation(
      reservation,
      now: now,
      allowed: const <OutreachState>{
        OutreachState.candidateReserved,
        OutreachState.generating,
      },
      idempotent: const <OutreachState>{OutreachState.abandoned},
      update: (record, timestamp) => record.copyWith(
        state: OutreachState.abandoned,
        updatedAt: timestamp,
        clearLeaseUntil: true,
        abandonedAt: timestamp,
        terminalReason: safeReason,
      ),
      recoverLease: false,
    );
  }

  Future<OutreachRecord> cancel({
    required String outreachId,
    String? reservationToken,
    String reason = 'cancelled',
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final safeReason = _requiredInput(reason, 'reason');
    return _db.transaction((transaction) async {
      final current = await _requiredRecord(transaction, outreachId);
      _requireOptionalToken(current, reservationToken);
      if (current.state == OutreachState.cancelled) return current;
      if (current.state != OutreachState.candidateReserved &&
          current.state != OutreachState.generating &&
          current.state != OutreachState.scheduledOs) {
        throw StateError(
          'cannot cancel outreach in ${current.state.name} state',
        );
      }
      final updated = current.copyWith(
        state: OutreachState.cancelled,
        updatedAt: timestamp,
        clearLeaseUntil: true,
        cancelledAt: timestamp,
        terminalReason: safeReason,
      );
      await _store.record(outreachId).put(transaction, updated.toJson());
      await _writeLifecycleMarkers(transaction, updated, timestamp);
      return updated;
    });
  }

  /// Releases every active OS occurrence backed by [deliveryId]. Platform
  /// cancellation happens first; callers retry this transaction if it fails so
  /// a cancelled notification can never continue consuming the shared budget.
  Future<List<OutreachRecord>> cancelScheduledOsByDeliveryId(
    String deliveryId, {
    String reason = 'platform_schedule_cancelled',
    DateTime? now,
  }) async {
    final delivery = _requiredInput(deliveryId, 'deliveryId');
    final safeReason = _requiredInput(reason, 'reason');
    final timestamp = _at(now);
    return _db.transaction((transaction) async {
      final snapshots = await _store.find(
        transaction,
        finder: Finder(filter: Filter.equals('deliveryId', delivery)),
      );
      final results = <OutreachRecord>[];
      for (final snapshot in snapshots) {
        final current = OutreachRecord.fromJson(snapshot.value);
        if (current.channel != OutreachChannel.osNotification) continue;
        if (current.state == OutreachState.cancelled) {
          results.add(current);
          continue;
        }
        if (current.state != OutreachState.scheduledOs) continue;
        final updated = current.copyWith(
          state: OutreachState.cancelled,
          updatedAt: timestamp,
          cancelledAt: timestamp,
          terminalReason: safeReason,
        );
        await _store
            .record(updated.outreachId)
            .put(transaction, updated.toJson());
        results.add(updated);
      }
      return List<OutreachRecord>.unmodifiable(results);
    });
  }

  /// Atomically claims the user interaction for one scheduled OS occurrence.
  ///
  /// Returning `true` grants the caller the only right to produce reply, TTS,
  /// or action side effects for this notification. Missing, cancelled,
  /// mismatched, and already-claimed occurrences fail closed.
  Future<bool> claimOsNotificationInteraction({
    required String outreachId,
    required String deliveryId,
    required String sourceEventId,
    DateTime? now,
  }) async {
    final outreach = _requiredInput(outreachId, 'outreachId');
    final delivery = _requiredInput(deliveryId, 'deliveryId');
    final source = _requiredInput(sourceEventId, 'sourceEventId');
    final timestamp = _at(now);
    return _db.transaction((transaction) async {
      await _recoverAndPrune(transaction, timestamp);
      final json = await _store.record(outreach).get(transaction);
      if (json == null) return false;
      final current = OutreachRecord.fromJson(json);
      if (current.channel != OutreachChannel.osNotification ||
          current.deliveryId != delivery ||
          current.sourceEventId != source ||
          current.scheduledFor == null ||
          current.scheduledFor!.isAfter(
            timestamp.add(const Duration(minutes: 2)),
          ) ||
          (current.state != OutreachState.scheduledOs &&
              current.state != OutreachState.assumedDelivered) ||
          current.notificationInteractionClaimedAt != null) {
        return false;
      }
      final updated = current.copyWith(
        updatedAt: timestamp,
        notificationInteractionClaimedAt: timestamp,
      );
      await _store.record(outreach).put(transaction, updated.toJson());
      return true;
    });
  }

  Future<OutreachRecord> markAssumedDelivered({
    required String outreachId,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    return _db.transaction((transaction) async {
      final current = await _requiredRecord(transaction, outreachId);
      if (current.state == OutreachState.assumedDelivered) return current;
      if (current.state != OutreachState.scheduledOs) {
        throw StateError(
          'cannot assume delivery in ${current.state.name} state',
        );
      }
      if (current.expiresAt != null && current.expiresAt!.isAfter(timestamp)) {
        throw StateError('cannot assume OS delivery before its target window');
      }
      final updated = current.copyWith(
        state: OutreachState.assumedDelivered,
        updatedAt: timestamp,
        assumedDeliveredAt: timestamp,
      );
      await _store.record(outreachId).put(transaction, updated.toJson());
      await _writeLifecycleMarkers(transaction, updated, timestamp);
      return updated;
    });
  }

  /// Recovers expired leases and conservatively counts expired OS schedules.
  Future<List<OutreachRecord>> recover({DateTime? now}) {
    final timestamp = _at(now);
    return _db.transaction((transaction) async {
      return _recoverAndPrune(transaction, timestamp);
    });
  }

  /// Recovers through [recoverThrough], then returns active OS occurrences.
  ///
  /// Recovery, pruning, and the read share one transaction so callers never
  /// reconcile platform schedules against a pre-recovery ledger snapshot.
  Future<List<OutreachRecord>> activeScheduledOs({DateTime? recoverThrough}) {
    final timestamp = _at(recoverThrough);
    return _db.transaction((transaction) async {
      await _recoverAndPrune(transaction, timestamp);
      final snapshots = await _store.find(transaction);
      final records = snapshots
          .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
          .where(
            (record) =>
                record.channel == OutreachChannel.osNotification &&
                record.state == OutreachState.scheduledOs,
          )
          .toList();
      records.sort((left, right) {
        final leftScheduledFor = left.scheduledFor;
        final rightScheduledFor = right.scheduledFor;
        if (leftScheduledFor == null) {
          if (rightScheduledFor != null) return 1;
        } else if (rightScheduledFor == null) {
          return -1;
        } else {
          final bySchedule = leftScheduledFor.compareTo(rightScheduledFor);
          if (bySchedule != 0) return bySchedule;
        }
        return left.outreachId.compareTo(right.outreachId);
      });
      return List<OutreachRecord>.unmodifiable(records);
    });
  }

  Future<OutreachRecord?> get(String outreachId) async {
    final safeId = _requiredInput(outreachId, 'outreachId');
    final json = await _store.record(safeId).get(_db);
    return json == null ? null : OutreachRecord.fromJson(json);
  }

  Future<OutreachRecord?> findBySourceEventId(String sourceEventId) async {
    final source = _requiredInput(sourceEventId, 'sourceEventId');
    return _findBySource(_db, source);
  }

  Future<bool> hasSourceEventBeenConsumed(String sourceEventId) async {
    final source = _requiredInput(sourceEventId, 'sourceEventId');
    if (await _hasMarker(_db, 'source', source)) return true;
    final record = await _findBySource(_db, source);
    return record != null && _stateBlocksSourceReplay(record);
  }

  Future<List<OutreachRecord>> recent({int limit = 32, DateTime? since}) async {
    if (limit <= 0) return const <OutreachRecord>[];
    final floor = since?.toUtc();
    final snapshots = await _store.find(_db);
    final records = snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .where((record) => floor == null || !record.createdAt.isBefore(floor))
        .toList();
    records.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return records.take(limit).toList(growable: false);
  }

  /// A future OS occurrence already owns the next ordinary contact slot.
  Future<bool> hasOutstandingOsContact({DatabaseClient? transaction}) async =>
      (await _store.find(
        transaction ?? _db,
        finder: Finder(
          filter: Filter.equals('state', OutreachState.scheduledOs.name),
          limit: 1,
        ),
      )).isNotEmpty;

  /// The latest ordinary contact is an enduring unanswered marker. It must
  /// not disappear when novelty fingerprints age out or topics change.
  Future<DateTime?> latestOrdinaryContactAt({
    required DateTime now,
    String? excludingOutreachId,
    DatabaseClient? transaction,
  }) async {
    final client = transaction ?? _db;
    final rows = await _store.find(
      client,
      finder: Finder(
        filter: Filter.and([
          Filter.lessThanOrEquals('historyAt', _writeDate(now)),
          Filter.inList('state', [
            'committed',
            'delivered',
            'scheduledOs',
            'assumedDelivered',
          ]),
          if (excludingOutreachId != null)
            Filter.notEquals('outreachId', excludingOutreachId),
        ]),
        sortOrders: [SortOrder('historyAt', false)],
        limit: 1,
      ),
    );
    final stored = await _markers.record('contact.latest').get(client);
    final markerAt = stored?['outreachId'] == excludingOutreachId
        ? DateTime.tryParse(stored?['previousOccurredAt']?.toString() ?? '')
        : DateTime.tryParse(stored?['occurredAt']?.toString() ?? '');
    final rowAt = rows.isEmpty
        ? null
        : OutreachRecord.fromJson(rows.first.value).historyAt;
    if (markerAt == null || markerAt.isAfter(now)) return rowAt;
    return rowAt == null || markerAt.isAfter(rowAt) ? markerAt : rowAt;
  }

  /// Reads recent rows through a caller-owned transaction on this ledger's
  /// account database. Shadow projections use this to make the ledger read and
  /// their derived write one serializable operation, so a concurrent cancel
  /// cannot leave stale assumed-delivery feedback behind.
  Future<List<OutreachRecord>> recentWithinTransaction(
    DatabaseClient transaction, {
    int limit = 32,
    DateTime? since,
  }) async {
    if (limit <= 0) return const <OutreachRecord>[];
    final floor = since?.toUtc();
    final snapshots = await _store.find(transaction);
    final records = snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .where((record) => floor == null || !record.createdAt.isBefore(floor))
        .toList();
    records.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return records.take(limit).toList(growable: false);
  }

  /// Returns policy-relevant occurrences ordered by their actual occurrence
  /// time. Diagnostic rows and later-day OS schedules cannot crowd recent
  /// spoken history out of the bounded result. Same-day future OS schedules
  /// are appended outside [limit] because they reserve today's shared budget;
  /// policy ignores their future timestamp for topic and global-gap checks.
  Future<List<OutreachRecord>> policyHistory({
    int limit = 32,
    DateTime? since,
    DateTime? until,
  }) async {
    if (limit <= 0) return const <OutreachRecord>[];
    final floor = since?.toUtc();
    final ceiling = until?.toUtc();
    final snapshots = await _store.find(_db);
    final allRecords = snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .toList();
    final records = allRecords.where((record) {
      final occurredAt = record.historyAt;
      if (occurredAt == null) return false;
      if (floor != null && occurredAt.isBefore(floor)) return false;
      if (ceiling != null && occurredAt.isAfter(ceiling)) return false;
      return true;
    }).toList();
    records.sort((left, right) => right.historyAt!.compareTo(left.historyAt!));
    final result = records.take(limit).toList();
    if (ceiling != null) {
      final bounds = _calendarDayBounds(ceiling);
      result.addAll(
        allRecords.where((record) {
          final occurredAt = record.historyAt;
          return record.state == OutreachState.scheduledOs &&
              occurredAt != null &&
              occurredAt.isAfter(ceiling) &&
              _inside(occurredAt, bounds.from, bounds.until);
        }),
      );
      result.sort((left, right) => right.historyAt!.compareTo(left.historyAt!));
    }
    return List<OutreachRecord>.unmodifiable(result);
  }

  Future<bool> wasTopicUsedSince(String topicKey, DateTime since) async {
    final topic = _requiredInput(topicKey, 'topicKey');
    final floor = since.toUtc();
    final snapshots = await _store.find(_db);
    return snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .any(
          (record) =>
              record.topicKey == topic &&
              (_budgetTimestamp(record)?.isBefore(floor) == false),
        );
  }

  Future<bool> hasEvidenceBeenUsed(String evidenceKey) async {
    final evidence = _requiredInput(evidenceKey, 'evidenceKey');
    if (await _hasMarker(_db, 'evidence', evidence)) return true;
    final snapshots = await _store.find(_db);
    return snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .any(
          (record) =>
              record.evidenceKey == evidence &&
              _stateConsumesUniqueness(record.state),
        );
  }

  Future<OutreachLedgerStats> summarize({
    required DateTime from,
    required DateTime until,
  }) async {
    final floor = from.toUtc();
    final ceiling = until.toUtc();
    if (!ceiling.isAfter(floor)) {
      throw ArgumentError.value(until, 'until', 'must be after from');
    }
    final snapshots = await _store.find(_db);
    var foregroundCommitted = 0;
    var osScheduled = 0;
    DateTime? lastAttemptAt;
    DateTime? lastCommittedAt;
    DateTime? lastDeliveredAt;
    for (final snapshot in snapshots) {
      final record = OutreachRecord.fromJson(snapshot.value);
      final attempt = record.lastAttemptAt;
      if (attempt != null) lastAttemptAt = _latest(lastAttemptAt, attempt);
      final committed = record.committedAt;
      if (committed != null) {
        lastCommittedAt = _latest(lastCommittedAt, committed);
        if (record.channel == OutreachChannel.foreground &&
            _inside(committed, floor, ceiling)) {
          foregroundCommitted++;
        }
      }
      final delivered = record.deliveredAt ?? record.assumedDeliveredAt;
      if (delivered != null) {
        lastDeliveredAt = _latest(lastDeliveredAt, delivered);
      }
      final scheduled = record.scheduledFor;
      if (scheduled != null &&
          record.countsTowardScheduledBudget &&
          _inside(scheduled, floor, ceiling)) {
        osScheduled++;
      }
    }
    return OutreachLedgerStats(
      foregroundCommitted: foregroundCommitted,
      osScheduled: osScheduled,
      lastAttemptAt: lastAttemptAt,
      lastCommittedAt: lastCommittedAt,
      lastDeliveredAt: lastDeliveredAt,
    );
  }

  Future<int> _budgetCountForDay(
    DatabaseClient transaction,
    DateTime calendarDay, {
    String? excludingOutreachId,
    bool includeActiveReservations = false,
  }) async {
    final bounds = _calendarDayBounds(calendarDay);
    final snapshots = await _store.find(transaction);
    var count = 0;
    for (final snapshot in snapshots) {
      final record = OutreachRecord.fromJson(snapshot.value);
      if (record.outreachId == excludingOutreachId) continue;
      final budgetedAt = includeActiveReservations
          ? _budgetOccupancyTimestamp(record)
          : _budgetTimestamp(record);
      if (budgetedAt != null &&
          _inside(budgetedAt, bounds.from, bounds.until)) {
        count++;
      }
    }
    return count;
  }

  void _validateOsReplay(
    OutreachRecord existing, {
    required String? deliveryId,
    required String topicKey,
    required String? evidenceKey,
    required DateTime scheduledFor,
    required DateTime expiresAt,
  }) {
    if (existing.channel != OutreachChannel.osNotification ||
        existing.deliveryId != deliveryId ||
        existing.topicKey != topicKey ||
        existing.evidenceKey != evidenceKey ||
        existing.scheduledFor != scheduledFor ||
        existing.expiresAt != expiresAt) {
      throw StateError('OS source event was replayed with different metadata');
    }
  }

  Future<OutreachRecord> _transitionReservation(
    OutreachReservation reservation, {
    required Set<OutreachState> allowed,
    required Set<OutreachState> idempotent,
    required OutreachRecord Function(OutreachRecord, DateTime) update,
    bool recoverLease = true,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final outcome = await _db.transaction((transaction) async {
      var current = await _requiredRecord(transaction, reservation.outreachId);
      _requireToken(current, reservation);
      if (recoverLease) {
        current = await _recoverOne(transaction, current, timestamp);
      }
      if (idempotent.contains(current.state)) {
        return (record: current, error: null);
      }
      if (!allowed.contains(current.state)) {
        return (
          record: current,
          error: 'cannot transition outreach from ${current.state.name}',
        );
      }
      final updated = update(current, timestamp);
      await _store
          .record(updated.outreachId)
          .put(transaction, updated.toJson());
      await _writeLifecycleMarkers(transaction, updated, timestamp);
      return (record: updated, error: null);
    });
    final error = outcome.error;
    if (error != null) throw StateError(error);
    return outcome.record;
  }

  Future<List<OutreachRecord>> _recoverExpired(
    DatabaseClient transaction,
    DateTime now,
  ) async {
    final snapshots = await _store.find(transaction);
    final changed = <OutreachRecord>[];
    for (final snapshot in snapshots) {
      final current = OutreachRecord.fromJson(snapshot.value);
      final updated = await _recoverOne(transaction, current, now);
      if (!identical(updated, current)) changed.add(updated);
    }
    return changed;
  }

  Future<List<OutreachRecord>> _recoverAndPrune(
    DatabaseClient transaction,
    DateTime now,
  ) async {
    final recovered = await _recoverExpired(transaction, now);
    await _pruneRecords(transaction, now);
    return recovered;
  }

  Future<void> _pruneRecords(DatabaseClient transaction, DateTime now) async {
    final snapshots = await _store.find(transaction);
    final records = snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .toList();
    final historyCutoff = now.subtract(retention.historyAge);
    final diagnosticCutoff = now.subtract(retention.diagnosticAge);
    final activeBudgetFloor = _calendarDayBounds(now).from;

    final history =
        records
            .where((record) => _stateConsumesUniqueness(record.state))
            .toList()
          ..sort((left, right) => right.historyAt!.compareTo(left.historyAt!));
    var historyRank = 0;
    for (final record in history) {
      await _writeLifecycleMarkers(transaction, record, record.updatedAt);
      final budgetedAt = _budgetTimestamp(record);
      final protected =
          (record.state == OutreachState.scheduledOs &&
              (record.expiresAt == null || record.expiresAt!.isAfter(now))) ||
          (budgetedAt != null && !budgetedAt.isBefore(activeBudgetFloor));
      if (protected) continue;
      final keep =
          historyRank++ < retention.historyCount &&
          !record.historyAt!.isBefore(historyCutoff);
      if (!keep) await _store.record(record.outreachId).delete(transaction);
    }

    final diagnostics =
        records
            .where((record) => !_stateConsumesUniqueness(record.state))
            .toList()
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    var diagnosticRank = 0;
    for (final record in diagnostics) {
      await _writeLifecycleMarkers(transaction, record, record.updatedAt);
      final protected =
          record.hasActiveLease &&
          (record.leaseUntil == null || record.leaseUntil!.isAfter(now));
      if (protected) continue;
      final keep =
          diagnosticRank++ < retention.diagnosticCount &&
          !record.updatedAt.isBefore(diagnosticCutoff);
      if (!keep) await _store.record(record.outreachId).delete(transaction);
    }
  }

  Future<void> _writeLifecycleMarkers(
    DatabaseClient transaction,
    OutreachRecord record,
    DateTime consumedAt,
  ) async {
    final contactAt = record.historyAt;
    if (contactAt != null && record.state != OutreachState.scheduledOs) {
      final current = await _markers.record('contact.latest').get(transaction);
      final previousAt = DateTime.tryParse(
        current?['occurredAt']?.toString() ?? '',
      );
      if (previousAt == null || contactAt.isAfter(previousAt)) {
        await _markers.record('contact.latest').put(transaction, {
          'kind': 'contact',
          'outreachId': record.outreachId,
          'occurredAt': contactAt.toUtc().toIso8601String(),
          'previousOccurredAt': current == null
              ? null
              : (current['outreachId'] == record.outreachId
                    ? current['previousOccurredAt']
                    : current['occurredAt']),
        });
      }
    }
    final source = record.sourceEventId;
    if (source != null && _statePersistsSourceMarker(record)) {
      await _writeMarker(transaction, 'source', source, consumedAt);
    }
    if (!_statePermanentlyConsumesEvidence(record.state)) return;
    final evidence = record.evidenceKey;
    if (evidence != null) {
      await _writeMarker(transaction, 'evidence', evidence, consumedAt);
    }
  }

  Future<void> _writeMarker(
    DatabaseClient transaction,
    String kind,
    String value,
    DateTime consumedAt,
  ) async {
    final key = _markerKey(kind, value);
    if (await _markers.record(key).exists(transaction)) return;
    await _markers.record(key).put(transaction, <String, Object?>{
      'kind': kind,
      'digest': key.substring(kind.length + 1),
      'consumedAt': consumedAt.toUtc().toIso8601String(),
    });
  }

  Future<bool> _hasMarker(DatabaseClient client, String kind, String value) =>
      _markers.record(_markerKey(kind, value)).exists(client);

  Future<bool> _evidenceOccupiesUniqueness(
    DatabaseClient client,
    String evidenceKey,
  ) async {
    if (await _hasMarker(client, 'evidence', evidenceKey)) return true;
    final snapshots = await _store.find(
      client,
      finder: Finder(filter: Filter.equals('evidenceKey', evidenceKey)),
    );
    return snapshots
        .map((snapshot) => OutreachRecord.fromJson(snapshot.value))
        .any((record) => _stateOccupiesUniqueness(record.state));
  }

  Future<OutreachRecord> _recoverOne(
    DatabaseClient transaction,
    OutreachRecord current,
    DateTime now,
  ) async {
    OutreachRecord? updated;
    if (current.hasActiveLease &&
        (current.leaseUntil == null || !current.leaseUntil!.isAfter(now))) {
      updated = current.copyWith(
        state: OutreachState.abandoned,
        updatedAt: now,
        clearLeaseUntil: true,
        abandonedAt: now,
        terminalReason: 'lease_expired',
      );
    } else if (current.state == OutreachState.scheduledOs &&
        current.expiresAt != null &&
        !current.expiresAt!.isAfter(now)) {
      updated = current.copyWith(
        state: OutreachState.assumedDelivered,
        updatedAt: now,
        assumedDeliveredAt: now,
      );
    }
    if (updated == null) return current;
    await _store.record(updated.outreachId).put(transaction, updated.toJson());
    await _writeLifecycleMarkers(transaction, updated, now);
    return updated;
  }

  Future<OutreachRecord?> _findBySource(
    DatabaseClient client,
    String sourceEventId,
  ) async {
    final snapshots = await _store.find(
      client,
      finder: Finder(
        filter: Filter.equals('sourceEventId', sourceEventId),
        sortOrders: <SortOrder>[SortOrder('createdAt', false)],
        limit: 1,
      ),
    );
    if (snapshots.isEmpty) return null;
    return OutreachRecord.fromJson(snapshots.single.value);
  }

  Future<OutreachRecord> _requiredRecord(
    DatabaseClient client,
    String outreachId,
  ) async {
    final json = await _store.record(outreachId).get(client);
    if (json == null) throw StateError('unknown outreach $outreachId');
    return OutreachRecord.fromJson(json);
  }

  Future<String> _uniqueId(DatabaseClient client, String prefix) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final value = '$prefix-${_requiredInput(_idFactory(), 'idFactory')}';
      if (await _store.record(value).get(client) == null) return value;
    }
    throw StateError('could not allocate a unique outreach id');
  }

  Future<String> _uniqueToken(DatabaseClient client) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final token = 'lease-${_requiredInput(_idFactory(), 'idFactory')}';
      final snapshots = await _store.find(
        client,
        finder: Finder(
          filter: Filter.equals('reservationToken', token),
          limit: 1,
        ),
      );
      if (snapshots.isEmpty) return token;
    }
    throw StateError('could not allocate a unique reservation token');
  }

  static OutreachReservation _reservation(
    OutreachRecord record, {
    required bool reused,
  }) {
    final token = record.reservationToken;
    final leaseUntil = record.leaseUntil;
    if (token == null || leaseUntil == null) {
      throw const FormatException('active outreach lease is corrupt');
    }
    return OutreachReservation(
      outreachId: record.outreachId,
      reservationToken: token,
      leaseUntil: leaseUntil,
      expiresAt: record.expiresAt,
      reused: reused,
    );
  }

  static void _requireToken(
    OutreachRecord record,
    OutreachReservation reservation,
  ) {
    if (record.reservationToken != reservation.reservationToken) {
      throw StateError('outreach reservation token does not match');
    }
  }

  static void _requireOptionalToken(
    OutreachRecord record,
    String? reservationToken,
  ) {
    if (!record.hasActiveLease) return;
    if (reservationToken == null ||
        reservationToken != record.reservationToken) {
      throw StateError('active outreach requires its reservation token');
    }
  }

  Future<int?> _ensureVisibleMessage(
    DatabaseClient transaction, {
    required String outreachId,
    required Map<String, Object?>? visibleMessageJson,
    required String? idempotencyKey,
  }) async {
    if (visibleMessageJson == null) return null;
    if (idempotencyKey == null) {
      throw ArgumentError(
        'visibleMessageIdempotencyKey is required with visibleMessageJson',
      );
    }
    final existing = await _chatMessages.findFirst(
      transaction,
      finder: Finder(filter: Filter.equals('idempotencyKey', idempotencyKey)),
    );
    if (existing != null) {
      final existingOutreach = existing.value['outreachId'];
      if (existingOutreach != outreachId) {
        throw StateError('visible message idempotency key belongs elsewhere');
      }
      return existing.key;
    }
    final json = Map<String, Object?>.from(visibleMessageJson)
      ..['idempotencyKey'] = idempotencyKey
      ..['outreachId'] = outreachId;
    return _chatMessages.add(transaction, json);
  }

  static String? _messageKey(
    Map<String, Object?>? visibleMessageJson,
    String? explicit,
  ) {
    if (visibleMessageJson == null) {
      if (explicit != null) {
        throw ArgumentError(
          'visibleMessageIdempotencyKey requires visibleMessageJson',
        );
      }
      return null;
    }
    final embedded = visibleMessageJson['idempotencyKey'];
    if (embedded != null && embedded is! String) {
      throw const FormatException('visible message idempotency key is invalid');
    }
    final key = _optionalInput(
      explicit ?? embedded as String?,
      'idempotencyKey',
    );
    if (key == null) {
      throw ArgumentError(
        'visibleMessageIdempotencyKey is required with visibleMessageJson',
      );
    }
    if (embedded != null && explicit != null && embedded != explicit) {
      throw ArgumentError('visible message idempotency keys do not match');
    }
    return key;
  }

  DateTime _at(DateTime? now) => (now ?? _clock()).toUtc();
}

DateTime? _budgetTimestamp(OutreachRecord record) {
  if (record.committedAt != null) return record.committedAt;
  if (record.countsTowardScheduledBudget) return record.scheduledFor;
  return null;
}

bool _stateBlocksSourceReplay(OutreachRecord record) =>
    _stateConsumesUniqueness(record.state) ||
    record.state == OutreachState.suppressed ||
    record.state == OutreachState.abandoned ||
    (record.state == OutreachState.cancelled &&
        record.channel == OutreachChannel.foreground);

bool _statePersistsSourceMarker(OutreachRecord record) =>
    _statePermanentlyConsumesEvidence(record.state) ||
    record.state == OutreachState.suppressed ||
    record.state == OutreachState.abandoned ||
    (record.state == OutreachState.cancelled &&
        record.channel == OutreachChannel.foreground);

bool _statePermanentlyConsumesEvidence(OutreachState state) => switch (state) {
  OutreachState.committed ||
  OutreachState.delivered ||
  OutreachState.assumedDelivered => true,
  OutreachState.candidateReserved ||
  OutreachState.generating ||
  OutreachState.suppressed ||
  OutreachState.abandoned ||
  OutreachState.scheduledOs ||
  OutreachState.cancelled => false,
};

bool _stateConsumesUniqueness(OutreachState state) => switch (state) {
  OutreachState.committed ||
  OutreachState.delivered ||
  OutreachState.scheduledOs ||
  OutreachState.assumedDelivered => true,
  OutreachState.candidateReserved ||
  OutreachState.generating ||
  OutreachState.suppressed ||
  OutreachState.abandoned ||
  OutreachState.cancelled => false,
};

bool _stateOccupiesUniqueness(OutreachState state) =>
    state == OutreachState.candidateReserved ||
    state == OutreachState.generating ||
    _stateConsumesUniqueness(state);

String _markerKey(String kind, String value) {
  final digest = sha256.convert(utf8.encode(value)).toString();
  return '$kind:$digest';
}

DateTime? _budgetOccupancyTimestamp(OutreachRecord record) {
  if (record.channel == OutreachChannel.foreground && record.hasActiveLease) {
    return record.createdAt;
  }
  return _budgetTimestamp(record);
}

({DateTime from, DateTime until}) _calendarDayBounds(DateTime value) {
  final local = value.toLocal();
  final start = DateTime(local.year, local.month, local.day);
  final end = DateTime(local.year, local.month, local.day + 1);
  return (from: start.toUtc(), until: end.toUtc());
}

bool _inside(DateTime value, DateTime from, DateTime until) =>
    !value.isBefore(from) && value.isBefore(until);

DateTime _latest(DateTime? current, DateTime candidate) =>
    current == null || candidate.isAfter(current) ? candidate : current;

String _requiredInput(String value, String field) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 512) {
    throw ArgumentError.value(value, field, 'must be 1-512 characters');
  }
  return trimmed;
}

String? _optionalInput(String? value, String field) {
  if (value == null || value.trim().isEmpty) return null;
  return _requiredInput(value, field);
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) {
    throw FormatException('outreach $field is invalid');
  }
  return value;
}

String? _optionalStoredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('outreach $field is invalid');
  }
  return value;
}

int? _optionalStoredInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw FormatException('outreach $field is invalid');
  }
  return value;
}

DateTime _readDate(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('outreach $field is invalid');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('outreach $field is invalid');
  return parsed.toUtc();
}

DateTime? _readOptionalDate(Map<String, Object?> json, String field) {
  if (json[field] == null) return null;
  return _readDate(json, field);
}

Set<String> _readStringSet(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return const <String>{};
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('outreach $field is invalid');
  }
  return value.cast<String>().toSet();
}

T _readEnum<T extends Enum>(List<T> values, String encoded, String field) {
  for (final value in values) {
    if (value.name == encoded) return value;
  }
  throw FormatException('outreach $field is invalid');
}

String _writeDate(DateTime value) => value.toUtc().toIso8601String();

String? _writeOptionalDate(DateTime? value) =>
    value == null ? null : _writeDate(value);

final math.Random _secureRandom = math.Random.secure();

String _randomOpaqueId() {
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(
    36,
  );
  final random = List<String>.generate(
    3,
    (_) => _secureRandom.nextInt(0x100000000).toRadixString(36),
    growable: false,
  ).join();
  return '$micros-$random';
}
