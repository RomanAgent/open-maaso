import 'dart:math' as math;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';

import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';

/// Why a foreground proactive attempt did not advance to generation.
enum ProactivePreparationStatus {
  ready,
  silenced,
  expired,
  leaseUnavailable,
  duplicateInFlight,
}

/// A generation capability that is valid only while its ledger lease is live.
final class ProactiveOutreachAttempt {
  const ProactiveOutreachAttempt({
    required this.candidate,
    required this.reservation,
    required this.preparedAt,
    required this.respectQuietHours,
    this.authorizationRevision,
    this.authorizationGeneration,
    this.lastUserActivityAt,
    this.executionGuard,
  });

  final ProactiveTopicCandidate candidate;
  final OutreachReservation reservation;
  final DateTime preparedAt;
  final bool respectQuietHours;
  final int? authorizationRevision;
  final int? authorizationGeneration;
  final DateTime? lastUserActivityAt;
  final bool Function()? executionGuard;

  String get outreachId => reservation.outreachId;
  String get sourceEventId => candidate.sourceEventId!;
  DateTime get leaseUntil => reservation.leaseUntil;
  DateTime? get expiresAt => reservation.expiresAt;
}

/// Result of policy evaluation plus the durable lease acquisition step.
final class ProactivePreparation {
  const ProactivePreparation._({
    required this.status,
    this.decision,
    this.attempt,
  });

  factory ProactivePreparation.ready({
    required ProactiveNoveltyDecision decision,
    required ProactiveOutreachAttempt attempt,
  }) => ProactivePreparation._(
    status: ProactivePreparationStatus.ready,
    decision: decision,
    attempt: attempt,
  );

  factory ProactivePreparation.stopped({
    required ProactivePreparationStatus status,
    ProactiveNoveltyDecision? decision,
  }) {
    if (status == ProactivePreparationStatus.ready) {
      throw ArgumentError.value(status, 'status', 'must not be ready');
    }
    return ProactivePreparation._(status: status, decision: decision);
  }

  final ProactivePreparationStatus status;
  final ProactiveNoveltyDecision? decision;
  final ProactiveOutreachAttempt? attempt;

  bool get shouldGenerate =>
      status == ProactivePreparationStatus.ready && attempt != null;
}

enum ProactiveDraftStatus { accepted, rejected }

/// Outcome of the final novelty gate and atomic visible-message commit.
final class ProactiveDraftCommit {
  const ProactiveDraftCommit._({
    required this.status,
    required this.decision,
    required this.record,
  });

  factory ProactiveDraftCommit.accepted({
    required ProactiveNoveltyDecision decision,
    required OutreachRecord record,
  }) => ProactiveDraftCommit._(
    status: ProactiveDraftStatus.accepted,
    decision: decision,
    record: record,
  );

  factory ProactiveDraftCommit.rejected({
    required ProactiveNoveltyDecision decision,
    required OutreachRecord record,
  }) => ProactiveDraftCommit._(
    status: ProactiveDraftStatus.rejected,
    decision: decision,
    record: record,
  );

  final ProactiveDraftStatus status;
  final ProactiveNoveltyDecision decision;
  final OutreachRecord record;

  bool get isAccepted => status == ProactiveDraftStatus.accepted;
  ProactiveTextSignature? get signature => decision.textSignature;
}

/// Coordinates pure policy decisions with the durable account ledger.
///
/// This boundary deliberately has no model, TTS, EventBus, or Avatar access.
/// Callers may generate only after [prepare] returns [shouldGenerate], and may
/// present a draft only after [commitDraft] returns [isAccepted].
final class ProactiveOutreachCoordinator {
  ProactiveOutreachCoordinator({
    required ProactiveCompanionPolicy policy,
    required ProactiveOutreachLedger ledger,
    required String accountKey,
    DateTime Function()? clock,
    ProactivePreferenceService? preferences,
  }) : _policy = policy,
       _ledger = ledger,
       _accountKey = _requiredValue(accountKey, 'accountKey'),
       _clock = clock ?? DateTime.now,
       _preferenceOverride = preferences;

  final ProactiveCompanionPolicy _policy;
  final ProactiveOutreachLedger _ledger;
  final String _accountKey;
  final DateTime Function() _clock;
  final ProactivePreferenceService? _preferenceOverride;
  ProactivePreferenceService? get _preferences =>
      _preferenceOverride ??
      (_policy is ProactivePreferencePolicyAdapter
          ? _policy.preferences
          : appServices.maybeFind<ProactivePreferenceService>());

  /// Captures the canonical device lease; later checks retain its exact epoch.
  /// Without a lifecycle this is a standalone policy/test host only.
  bool Function() captureExecutionGuard() {
    final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    if (lifecycle == null) return () => true;
    try {
      if (!lifecycle.canExecuteAgent ||
          appServices.maybeFind<AgentHandoffService>()?.isBusy == true) {
        return () => false;
      }
      final authority = lifecycle.usesExclusiveDeviceLease
          ? appServices
                .find<AccountDeviceLeaseCoordinator>()
                .requireCurrentRequestAuthority()
          : null;
      return () {
        try {
          if (!lifecycle.canExecuteAgent ||
              appServices.maybeFind<AgentHandoffService>()?.isBusy == true) {
            return false;
          }
          authority?.requireCurrent();
          return true;
        } on Object {
          return false;
        }
      };
    } on Object {
      return () => false;
    }
  }

  Future<bool> refreshContactAuthorization() async {
    try {
      await _preferences?.refreshContactSources();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> contactTopicAllowed(
    String topicKey, {
    required DateTime at,
    bool os = false,
  }) async {
    final preferences = _preferences;
    if (preferences == null) return true;
    try {
      await preferences.refreshContactSources();
      return preferences.effectiveSnapshot.allowsTopic(topicKey, at, os: os);
    } on Object {
      return false;
    }
  }

  Future<bool> hasUnansweredOutreach({
    DateTime? now,
    DateTime? lastUserActivityAt,
    String? excludingOutreachId,
    DatabaseClient? transaction,
  }) async {
    final latest = await _ledger.latestOrdinaryContactAt(
      now: _at(now),
      excludingOutreachId: excludingOutreachId,
      transaction: transaction,
    );
    if (latest == null) return false;
    final config = _policy.config;
    final returns = <DateTime>[
      ?lastUserActivityAt,
      ?config.lastUserReturnAt,
      ?config.agreementChangedAt,
    ];
    return !returns.any((event) => event.isAfter(latest));
  }

  /// Runs a short foreground presentation boundary against one stable policy
  /// snapshot. Model generation must remain outside this boundary.
  Future<T> runWithStableForegroundPolicy<T>(Future<T> Function() operation) =>
      _policy.runWithStableConfig((_) => operation());

  /// Stable per-account, per-local-day input for deterministic jitter.
  String deterministicJitterKeyFor(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$_accountKey:${local.year}-$month-$day';
  }

  /// Reads bounded, occurrence-ordered policy history. Attempts and negative
  /// terminals are absent. Same-day future OS reservations are included only
  /// for the shared budget and cannot crowd out the bounded spoken history.
  Future<List<ProactiveOutreachHistoryEntry>> readHistory({
    DateTime? now,
    String? excludingOutreachId,
  }) async {
    final timestamp = _at(now);
    await _ledger.recover(now: timestamp);
    final records = await _ledger.policyHistory(
      limit: math.max(64, _policy.config.fingerprintRetentionCount * 2),
      since: timestamp.subtract(_policy.config.fingerprintRetention),
      until: timestamp,
    );
    final history = <ProactiveOutreachHistoryEntry>[];
    for (final record in records) {
      if (record.outreachId == excludingOutreachId) continue;
      final entry = _historyEntry(record);
      if (entry != null) history.add(entry);
    }
    history.sort((left, right) => right.occurredAt.compareTo(left.occurredAt));
    return List<ProactiveOutreachHistoryEntry>.unmodifiable(history);
  }

  /// Atomically reserves one one-shot OS notification occurrence under the
  /// shared account/day outreach budget.
  ///
  /// The caller's preference may only tighten the product policy. It can
  /// never raise [_policy]'s foreground limit, because foreground and OS
  /// outreach intentionally consume the same daily budget.
  Future<OutreachRecord?> scheduleOsOccurrence({
    required String sourceEventId,
    required String deliveryId,
    required String topicKey,
    String? evidenceKey,
    required DateTime scheduledFor,
    required DateTime expiresAt,
    required int requestedDailyBudgetLimit,
    DateTime? now,
  }) async {
    if (requestedDailyBudgetLimit < 0) {
      throw ArgumentError.value(
        requestedDailyBudgetLimit,
        'requestedDailyBudgetLimit',
        'must not be negative',
      );
    }
    final executionGuard = captureExecutionGuard();
    if (!executionGuard() ||
        !await contactTopicAllowed(topicKey, at: scheduledFor, os: true) ||
        await hasUnansweredOutreach(now: now)) {
      return null;
    }
    final scheduled = await _ledger.activeScheduledOs(recoverThrough: _at(now));
    if (scheduled.any((record) => record.sourceEventId != sourceEventId)) {
      return null;
    }
    if (!executionGuard()) return null;
    return _ledger.tryScheduleOs(
      sourceEventId: _requiredValue(sourceEventId, 'sourceEventId'),
      deliveryId: _requiredValue(deliveryId, 'deliveryId'),
      topicKey: _requiredValue(topicKey, 'topicKey'),
      evidenceKey: _optionalValue(evidenceKey, 'evidenceKey'),
      scheduledFor: scheduledFor,
      expiresAt: expiresAt,
      dailyBudgetLimit: math.min(
        _policy.config.foregroundDailyLimit,
        requestedDailyBudgetLimit,
      ),
      now: _at(now),
    );
  }

  /// Releases ledger reservations after the platform has confirmed that the
  /// matching notification delivery is cancelled.
  ///
  /// Callers must not invoke this merely because cancellation was requested:
  /// keeping the reservation until platform confirmation prevents an active
  /// notification from escaping the shared account/day budget.
  Future<List<OutreachRecord>> confirmOsDeliveryCancelled({
    required String deliveryId,
    String reason = 'platform_schedule_cancelled',
    DateTime? now,
  }) => _ledger.cancelScheduledOsByDeliveryId(
    _requiredValue(deliveryId, 'deliveryId'),
    reason: _requiredValue(reason, 'reason'),
    now: _at(now),
  );

  /// Recovers expired leases and conservatively closes elapsed OS windows.
  Future<List<OutreachRecord>> recoverOutreach({DateTime? now}) =>
      _ledger.recover(now: _at(now));

  /// Returns the account's active one-shot OS occurrences after recovery.
  Future<List<OutreachRecord>> activeScheduledOs({DateTime? recoverThrough}) =>
      _ledger.activeScheduledOs(recoverThrough: _at(recoverThrough));

  /// Reads one immutable outreach lifecycle record by its durable identifier.
  Future<OutreachRecord?> getOutreach(String outreachId) =>
      _ledger.get(_requiredValue(outreachId, 'outreachId'));

  /// Grants exactly one runtime turn for a user-opened OS occurrence.
  /// Metadata must match the account ledger row byte-for-byte.
  Future<bool> claimOsNotificationInteraction({
    required String outreachId,
    required String deliveryId,
    required String sourceEventId,
    DateTime? now,
  }) async {
    final id = _requiredValue(outreachId, 'outreachId');
    final delivery = _requiredValue(deliveryId, 'deliveryId');
    final source = _requiredValue(sourceEventId, 'sourceEventId');
    final executionGuard = captureExecutionGuard();
    final record = await _ledger.get(id);
    if (record == null ||
        !executionGuard() ||
        !await contactTopicAllowed(record.topicKey, at: _at(now), os: true) ||
        !executionGuard()) {
      return false;
    }
    return _ledger.claimOsNotificationInteraction(
      outreachId: id,
      deliveryId: delivery,
      sourceEventId: source,
      now: _at(now),
    );
  }

  /// Evaluates candidates, acquires the single account lease, revalidates
  /// against freshly committed history, then marks the attempt as generating.
  Future<ProactivePreparation> prepare({
    required String sourceEventId,
    required Iterable<ProactiveTopicCandidate> candidates,
    DateTime? lastUserActivityAt,
    DateTime? expiresAt,
    Duration leaseDuration = const Duration(minutes: 2),
    bool respectQuietHours = true,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final executionGuard = captureExecutionGuard();
    if (!executionGuard()) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.authorizationChanged,
        ),
      );
    }
    final admittedConfig = _policy.config;
    await _ledger.recover(now: timestamp);
    if (await _ledger.hasOutstandingOsContact() ||
        await hasUnansweredOutreach(
          now: timestamp,
          lastUserActivityAt: lastUserActivityAt,
        )) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.waitingForReply,
        ),
      );
    }
    final source = _requiredValue(sourceEventId, 'sourceEventId');
    final hardExpiry = expiresAt?.toUtc();
    if (hardExpiry != null && !hardExpiry.isAfter(timestamp)) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.expired,
      );
    }
    final boundCandidates = candidates
        .map((candidate) => _bindSource(candidate, source))
        .toList(growable: false);
    final freshCandidates = <ProactiveTopicCandidate>[];
    ProactiveNoveltyDecision? markerSuppression;
    for (final candidate in boundCandidates) {
      if (!await contactTopicAllowed(candidate.topicKey, at: timestamp)) {
        markerSuppression ??= ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.topicUnavailable,
          candidate: candidate,
        );
        continue;
      }
      final candidateSource = candidate.sourceEventId;
      if (candidateSource != null &&
          await _ledger.hasSourceEventBeenConsumed(candidateSource)) {
        markerSuppression ??= ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.duplicateSourceEvent,
          candidate: candidate,
        );
        continue;
      }
      final evidence = candidate.evidenceKey;
      if (evidence != null && await _ledger.hasEvidenceBeenUsed(evidence)) {
        markerSuppression ??= ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.duplicateEvidence,
          candidate: candidate,
        );
        continue;
      }
      freshCandidates.add(candidate);
    }
    if (freshCandidates.isEmpty && markerSuppression != null) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: markerSuppression,
      );
    }
    final history = await readHistory(now: timestamp);
    var decision = _policy.evaluate(
      now: timestamp,
      candidates: freshCandidates,
      history: history,
      lastUserActivityAt: lastUserActivityAt?.toUtc(),
      deterministicJitterKey: deterministicJitterKeyFor(timestamp),
      respectQuietHours: respectQuietHours,
    );
    if (!decision.shouldReserve || decision.candidate == null) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: decision,
      );
    }

    final candidate = decision.candidate!;
    final candidateSource = candidate.sourceEventId!;
    final reservation = await _ledger.reserve(
      sourceEventId: candidateSource,
      topicKey: candidate.topicKey,
      evidenceKey: candidate.evidenceKey,
      leaseDuration: leaseDuration,
      expiresAt: hardExpiry,
      dailyBudgetLimit: _policy.config.foregroundDailyLimit,
      now: timestamp,
    );
    if (reservation == null) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.leaseUnavailable,
        decision: decision,
      );
    }
    if (reservation.reused) {
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.duplicateInFlight,
        decision: decision,
      );
    }

    // Close the read-before-reserve window. The ledger lease prevents a
    // second foreground generator while this fresh policy read is performed.
    final freshHistory = await readHistory(
      now: timestamp,
      excludingOutreachId: reservation.outreachId,
    );
    final revalidated = _policy.evaluate(
      now: timestamp,
      candidates: freshCandidates,
      history: freshHistory,
      lastUserActivityAt: lastUserActivityAt?.toUtc(),
      deterministicJitterKey: deterministicJitterKeyFor(timestamp),
      respectQuietHours: respectQuietHours,
    );
    if (!revalidated.shouldReserve ||
        !_sameCandidate(revalidated.candidate, candidate)) {
      await _ledger.abandon(
        reservation,
        reason: 'policy_revalidation_${revalidated.reason.name}',
        now: timestamp,
      );
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: revalidated,
      );
    }
    decision = revalidated;

    try {
      await _ledger.markGenerating(reservation, now: timestamp);
    } catch (_) {
      try {
        await _ledger.abandon(
          reservation,
          reason: 'mark_generating_failed',
          now: timestamp,
        );
      } catch (_) {
        // Preserve the original transition failure. The lease remains bounded
        // and ledger recovery will eventually abandon it.
      }
      rethrow;
    }

    final currentPreferences = _preferences?.effectiveSnapshot;
    if (!executionGuard() ||
        (currentPreferences != null &&
            (currentPreferences.revision !=
                    admittedConfig.authorizationRevision ||
                !currentPreferences.allowsTopic(
                  candidate.topicKey,
                  _clock(),
                )))) {
      await _ledger.abandon(
        reservation,
        reason: 'authorization_changed_before_generation',
        now: timestamp,
      );
      return ProactivePreparation.stopped(
        status: ProactivePreparationStatus.silenced,
        decision: ProactiveNoveltyDecision.silence(
          ProactiveSilenceReason.authorizationChanged,
        ),
      );
    }
    return ProactivePreparation.ready(
      decision: decision,
      attempt: ProactiveOutreachAttempt(
        candidate: candidate,
        reservation: reservation,
        preparedAt: timestamp,
        respectQuietHours: respectQuietHours,
        authorizationRevision: admittedConfig.authorizationRevision,
        authorizationGeneration: admittedConfig.authorizationGeneration,
        lastUserActivityAt: lastUserActivityAt,
        executionGuard: executionGuard,
      ),
    );
  }

  /// Rechecks text novelty and atomically persists the accepted visible row.
  /// Any persistence or lifecycle error is propagated; callers must therefore
  /// treat every non-accepted result and every exception as silence.
  Future<ProactiveDraftCommit> commitDraft({
    required ProactiveOutreachAttempt attempt,
    required String draft,
    required Map<String, Object?> visibleMessageJson,
    required String idempotencyKey,
    DateTime? now,
  }) async {
    final timestamp = _at(now);
    final closedReason =
        !await contactTopicAllowed(attempt.candidate.topicKey, at: timestamp)
        ? ProactiveSilenceReason.topicUnavailable
        : await hasUnansweredOutreach(
            now: timestamp,
            excludingOutreachId: attempt.outreachId,
            lastUserActivityAt: attempt.lastUserActivityAt,
          )
        ? ProactiveSilenceReason.waitingForReply
        : null;
    if (closedReason != null) {
      final suppressed = await _ledger.suppress(
        outreachId: attempt.outreachId,
        reservationToken: attempt.reservation.reservationToken,
        reason: 'hard_gate_${closedReason.name}',
        now: timestamp,
      );
      return ProactiveDraftCommit.rejected(
        decision: ProactiveNoveltyDecision.silence(
          closedReason,
          candidate: attempt.candidate,
        ),
        record: suppressed,
      );
    }
    final history = await readHistory(
      now: timestamp,
      excludingOutreachId: attempt.outreachId,
    );
    final decision = _policy.evaluateDraft(
      now: timestamp,
      candidate: attempt.candidate,
      draft: draft,
      history: history,
    );
    if (!decision.isAccepted || decision.textSignature == null) {
      final suppressed = await _ledger.suppress(
        outreachId: attempt.outreachId,
        reservationToken: attempt.reservation.reservationToken,
        reason: 'novelty_${decision.reason.name}',
        now: timestamp,
      );
      return ProactiveDraftCommit.rejected(
        decision: decision,
        record: suppressed,
      );
    }

    final signature = decision.textSignature!;
    late final OutreachRecord committed;
    try {
      committed = await _policy.runWithStableConfig((commitConfig) async {
        final gateReason = _foregroundGateReason(
          attempt,
          commitConfig,
          _at(null),
        );
        if (gateReason != null) {
          throw _ProactiveCommitGateClosed(gateReason);
        }
        return _ledger.commitAccepted(
          attempt.reservation,
          normalizedFingerprint: signature.fingerprint,
          nearDuplicateFeatures: signature.similarityFeatures,
          visibleMessageJson: Map<String, Object?>.from(visibleMessageJson),
          visibleMessageIdempotencyKey: _requiredValue(
            idempotencyKey,
            'idempotencyKey',
          ),
          onFirstCommit: (transaction, _) async {
            if (await _ledger.hasOutstandingOsContact(
                  transaction: transaction,
                ) ||
                await hasUnansweredOutreach(
                  now: _at(null),
                  excludingOutreachId: attempt.outreachId,
                  lastUserActivityAt: attempt.lastUserActivityAt,
                  transaction: transaction,
                )) {
              throw const _ProactiveCommitGateClosed(
                ProactiveSilenceReason.waitingForReply,
              );
            }
            if (await _preferences?.topicSourceIsLiveWithinTransaction(
                  transaction,
                  attempt.candidate.topicKey,
                ) ==
                false) {
              throw const _ProactiveCommitGateClosed(
                ProactiveSilenceReason.topicUnavailable,
              );
            }
            final reason = _foregroundGateReason(
              attempt,
              _policy.config,
              _at(null),
              expectedDailyBudgetLimit: commitConfig.foregroundDailyLimit,
            );
            if (reason != null) throw _ProactiveCommitGateClosed(reason);
          },
          dailyBudgetLimit: commitConfig.foregroundDailyLimit,
          now: timestamp,
        );
      });
    } on _ProactiveCommitGateClosed catch (error) {
      final rejected = ProactiveNoveltyDecision.silence(
        error.reason,
        candidate: attempt.candidate,
        textSignature: signature,
      );
      final suppressed = await _ledger.suppress(
        outreachId: attempt.outreachId,
        reservationToken: attempt.reservation.reservationToken,
        reason: 'hard_gate_${rejected.reason.name}',
        now: timestamp,
      );
      return ProactiveDraftCommit.rejected(
        decision: rejected,
        record: suppressed,
      );
    } on OutreachDailyBudgetExceeded {
      final rejected = ProactiveNoveltyDecision.silence(
        ProactiveSilenceReason.dailyBudgetExhausted,
        candidate: attempt.candidate,
        textSignature: signature,
      );
      final suppressed = await _ledger.suppress(
        outreachId: attempt.outreachId,
        reservationToken: attempt.reservation.reservationToken,
        reason: 'novelty_${rejected.reason.name}',
        now: timestamp,
      );
      return ProactiveDraftCommit.rejected(
        decision: rejected,
        record: suppressed,
      );
    }
    if (committed.committedAt == null ||
        (committed.state != OutreachState.committed &&
            committed.state != OutreachState.delivered)) {
      throw StateError('accepted proactive draft was not durably committed');
    }
    return ProactiveDraftCommit.accepted(decision: decision, record: committed);
  }

  bool canPresentForeground(
    ProactiveOutreachAttempt attempt, {
    DateTime? now,
  }) =>
      _foregroundGateReason(attempt, _policy.config, _at(now)) == null &&
      (_preferences?.effectiveSnapshot.allowsTopic(
            attempt.candidate.topicKey,
            _at(now),
          ) ??
          true);

  Future<OutreachRecord> abandon(
    ProactiveOutreachAttempt attempt, {
    String reason = 'generation_failed',
    DateTime? now,
  }) => _ledger.abandon(attempt.reservation, reason: reason, now: _at(now));

  Future<OutreachRecord> markDelivered(
    ProactiveOutreachAttempt attempt, {
    DateTime? now,
  }) => _ledger.markDelivered(attempt.reservation, now: _at(now));

  DateTime _at(DateTime? now) => (now ?? _clock()).toUtc();
}

ProactiveSilenceReason? _foregroundGateReason(
  ProactiveOutreachAttempt attempt,
  ProactivePolicyConfig config,
  DateTime timestamp, {
  int? expectedDailyBudgetLimit,
}) {
  if (attempt.executionGuard?.call() == false) {
    return ProactiveSilenceReason.authorizationChanged;
  }
  if (attempt.authorizationRevision != config.authorizationRevision ||
      attempt.authorizationGeneration != config.authorizationGeneration) {
    return ProactiveSilenceReason.authorizationChanged;
  }
  if (config.authorizedUntil != null &&
      !timestamp.isBefore(config.authorizedUntil!) &&
      !attempt.candidate.topicKey.startsWith('conversation.followup.')) {
    return ProactiveSilenceReason.authorizationExpired;
  }
  if (config.foregroundDailyLimit <= 0 ||
      (expectedDailyBudgetLimit != null &&
          config.foregroundDailyLimit != expectedDailyBudgetLimit)) {
    return ProactiveSilenceReason.dailyBudgetExhausted;
  }
  if (attempt.respectQuietHours && config.isQuietAt(timestamp)) {
    return ProactiveSilenceReason.quietHours;
  }
  return null;
}

final class _ProactiveCommitGateClosed implements Exception {
  const _ProactiveCommitGateClosed(this.reason);

  final ProactiveSilenceReason reason;
}

ProactiveOutreachHistoryEntry? _historyEntry(OutreachRecord record) {
  final occurredAt = record.historyAt;
  if (occurredAt == null) return null;
  return ProactiveOutreachHistoryEntry(
    topicKey: record.topicKey,
    occurredAt: occurredAt,
    consumesSourceEvent: true,
    consumesEvidence: true,
    sourceEventId: record.sourceEventId,
    evidenceKey: record.evidenceKey,
    normalizedTextHash: record.normalizedFingerprint,
    similarityFeatures: record.nearDuplicateFeatures,
    // This is the shared account/day budget, despite the policy field's
    // historical foreground-oriented name.
    countsTowardForegroundBudget: true,
    countsTowardGlobalGap: true,
  );
}

ProactiveTopicCandidate _bindSource(
  ProactiveTopicCandidate candidate,
  String sourceEventId,
) {
  final candidateSource = candidate.sourceEventId?.trim();
  final boundSource = candidateSource == null || candidateSource.isEmpty
      ? sourceEventId
      : candidateSource;
  return ProactiveTopicCandidate(
    kind: candidate.kind,
    topicKey: candidate.topicKey,
    sourceEventId: boundSource,
    evidenceKey: candidate.evidenceKey,
    textSeed: candidate.textSeed,
    priority: candidate.priority,
  );
}

bool _sameCandidate(
  ProactiveTopicCandidate? left,
  ProactiveTopicCandidate right,
) =>
    left != null &&
    left.kind == right.kind &&
    left.topicKey == right.topicKey &&
    left.sourceEventId == right.sourceEventId &&
    left.evidenceKey == right.evidenceKey;

String _requiredValue(String value, String field) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 512) {
    throw ArgumentError.value(value, field, 'must be 1-512 characters');
  }
  return trimmed;
}

String? _optionalValue(String? value, String field) {
  if (value == null) return null;
  return _requiredValue(value, field);
}
