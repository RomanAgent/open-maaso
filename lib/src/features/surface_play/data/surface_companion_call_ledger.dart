import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

import '../domain/surface_play_budget.dart';
import '../domain/surface_play_protocol.dart';

enum SurfaceCompanionCallOutcome { completed, unknown, notDispatched }

abstract interface class SurfaceCompanionCallLedgerOwner {
  SurfaceCompanionCallLedger get callLedger;
}

/// A local-device, account/environment + Agent call ceiling. Formal games,
/// previews and applet agents share this ledger when they use the same scope.
/// This is neither a monetary budget nor cross-device server admission.
/// Request receipts are small immutable identity records, not model prompts.
/// Held/unknown calls never expire or get refunded by a new 30-minute period.
final class SurfaceCompanionCallLedger {
  SurfaceCompanionCallLedger({
    required DBService database,
    required this.scopeKey,
    required bool Function() isCurrent,
    DateTime Function()? now,
  }) : _database = database,
       _isCurrent = isCurrent,
       _now = now ?? DateTime.now {
    if (scopeKey.isEmpty || scopeKey.length > 512) {
      throw ArgumentError('invalid_companion_budget_scope');
    }
  }
  static const period = Duration(minutes: 30);
  static const unknownUsage = <String, Object?>{
    'status': 'unknown',
    'completed': null,
    'unknown': null,
    'pending': null,
    'notDispatched': null,
  };
  static final _calls = stringMapStoreFactory.store(
    'surface_companion_calls.v1',
  );
  static final _periods = stringMapStoreFactory.store(
    'surface_companion_periods.v1',
  );
  static final _legacy = stringMapStoreFactory.store(
    'surface_companion_legacy_calls.v1',
  );
  static final _migration = stringMapStoreFactory.store(
    'surface_companion_migration.v1',
  );
  static final _matches = stringMapStoreFactory.store(
    'surface_play_matches.v2',
  );
  final DBService _database;
  final String scopeKey;
  final bool Function() _isCurrent;
  final DateTime Function() _now;
  String _key(String agent, String invocation) => sha256
      .convert(utf8.encode(jsonEncode([scopeKey, agent, invocation])))
      .toString();
  void _guard() {
    if (!_isCurrent()) throw StateError('PLAY_SCOPE_CHANGED');
  }

  void _validate(String agent, String invocation, String digest) {
    playIdentifier(agent);
    playIdentifier(invocation);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('invalid_companion_request_digest');
    }
  }

  void _identity(
    Map<String, Object?> row,
    String agent,
    String invocation,
    String digest,
  ) {
    if (row['scopeKey'] != scopeKey ||
        row['agentId'] != agent ||
        row['invocationId'] != invocation ||
        row['requestDigest'] != digest) {
      throw StateError('COMPANION_INVOCATION_CONFLICT');
    }
  }

  /// Local admission statistics, not provider billing. Completed/released
  /// outcomes belong to the current anchored period; unresolved holds include
  /// earlier periods exactly as reserve() does. No row identities are exposed.
  Future<Map<String, Object?>> readUsageForAgent(String agentId) async {
    _guard();
    playIdentifier(agentId);
    try {
      final result = await _database.raw.transaction((tx) async {
        _guard();
        // Legacy checkpoints have no reliable Agent attribution. Do not import
        // or inspect their private game bodies just to display diagnostics.
        final legacy = await _legacy.findKeys(
          tx,
          finder: Finder(filter: Filter.equals('scopeKey', scopeKey), limit: 1),
        );
        if (legacy.isNotEmpty) return unknownUsage;
        if (!await _migration.record(scopeKey).exists(tx)) {
          final unresolvedLegacy = await _matches.findKeys(
            tx,
            finder: Finder(
              filter: Filter.and([
                Filter.or([
                  Filter.equals('scopeKey', scopeKey),
                  Filter.equals('scopeKey', '$scopeKey|preview'),
                ]),
                Filter.notEquals('budgetLedgerVersion', 1),
              ]),
              limit: 1,
            ),
          );
          if (unresolvedLegacy.isNotEmpty) return unknownUsage;
        }
        final previous = await _periods
            .record(jsonEncode([scopeKey, agentId]))
            .get(tx);
        final owner = Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('agentId', agentId),
        ]);
        if (previous == null) {
          final unexpectedRows = await _calls.findKeys(
            tx,
            finder: Finder(filter: owner, limit: 1),
          );
          return unexpectedRows.isNotEmpty
              ? unknownUsage
              : const <String, Object?>{
                  'status': 'available',
                  'completed': 0,
                  'unknown': 0,
                  'pending': 0,
                  'notDispatched': 0,
                };
        }
        if (previous['scopeKey'] != scopeKey ||
            previous['agentId'] != agentId) {
          return unknownUsage;
        }
        final last = DateTime.tryParse(
          previous['lastSeenAt'] as String? ?? '',
        )?.toUtc();
        var start = DateTime.tryParse(
          previous['periodStart'] as String? ?? '',
        )?.toUtc();
        if (last == null || start == null || start.isAfter(last)) {
          return unknownUsage;
        }
        var now = _now().toUtc();
        if (now.isBefore(last)) now = last;
        if (now.difference(start) >= period) {
          start = start.add(
            Duration(
              microseconds:
                  period.inMicroseconds *
                  (now.difference(start).inMicroseconds ~/
                      period.inMicroseconds),
            ),
          );
        }
        final rows = await _calls.find(
          tx,
          finder: Finder(
            filter: Filter.and([
              owner,
              Filter.or([
                Filter.equals('outcome', 'reserved'),
                Filter.equals('outcome', 'unknown'),
                Filter.greaterThanOrEquals('at', start.toIso8601String()),
              ]),
            ]),
            limit: 8193,
          ),
        );
        if (rows.length > 8192) return unknownUsage;
        var completed = 0, unknown = 0, pending = 0, notDispatched = 0;
        for (final row in rows) {
          final value = row.value;
          final at = DateTime.tryParse(value['at'] as String? ?? '')?.toUtc();
          if (value['schemaVersion'] != 1 || at == null || at.isAfter(now)) {
            return unknownUsage;
          }
          switch (value['outcome']) {
            case 'reserved':
              pending++;
            case 'unknown':
              unknown++;
            case 'completed':
              if (!at.isBefore(start)) completed++;
            case 'notDispatched':
              if (!at.isBefore(start)) notDispatched++;
            default:
              return unknownUsage;
          }
        }
        _guard();
        return Map<String, Object?>.unmodifiable({
          'status': 'available',
          'completed': completed,
          'unknown': unknown,
          'pending': pending,
          'notDispatched': notDispatched,
        });
      });
      _guard();
      return result;
    } catch (_) {
      _guard();
      return unknownUsage;
    }
  }

  Future<SurfacePlayCallReservation> reserve({
    required String agentId,
    required String invocationId,
    required String requestDigest,
    required bool Function() isAuthorized,
    SurfacePlayCallBudget budget = const SurfacePlayCallBudget(),
  }) async {
    _guard();
    _validate(agentId, invocationId, requestDigest);
    budget.validate();
    if (!isAuthorized()) return SurfacePlayCallReservation.unavailable;
    final result = await _database.raw.transaction((tx) async {
      _guard();
      if (!isAuthorized()) return SurfacePlayCallReservation.unavailable;
      final ref = _calls.record(_key(agentId, invocationId)),
          old = await ref.get(tx);
      if (old != null) {
        _identity(old, agentId, invocationId, requestDigest);
        return SurfacePlayCallReservation.duplicate;
      }
      await _importLegacy(tx);
      final periodRef = _periods.record(jsonEncode([scopeKey, agentId]));
      final previous = await periodRef.get(tx);
      var now = _now().toUtc();
      if (previous != null) {
        if (previous['scopeKey'] != scopeKey ||
            previous['agentId'] != agentId) {
          throw const FormatException('invalid_companion_period');
        }
        final last = DateTime.parse(previous['lastSeenAt']! as String).toUtc();
        if (now.isBefore(last)) now = last;
      }
      var start = previous == null
          ? now
          : DateTime.parse(previous['periodStart']! as String).toUtc();
      if (now.difference(start) >= period) {
        start = start.add(
          Duration(
            microseconds:
                period.inMicroseconds *
                (now.difference(start).inMicroseconds ~/ period.inMicroseconds),
          ),
        );
      }
      final since = now.subtract(const Duration(minutes: 1));
      final rows = await _calls.find(
        tx,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('scopeKey', scopeKey),
            Filter.equals('agentId', agentId),
            Filter.or([
              Filter.equals('outcome', 'reserved'),
              Filter.equals('outcome', 'unknown'),
              Filter.greaterThanOrEquals('at', start.toIso8601String()),
              Filter.greaterThan('at', since.toIso8601String()),
            ]),
          ]),
          limit: 8193,
        ),
      );
      final legacy = await _legacy.find(
        tx,
        finder: Finder(
          filter: Filter.equals('scopeKey', scopeKey),
          limit: 8193,
        ),
      );
      if (rows.length > 8192 || legacy.length > 8192) {
        throw StateError('COMPANION_LEDGER_CAPACITY');
      }
      if (previous == null) {
        for (final row in legacy) {
          final at = DateTime.parse(row.value['at']! as String).toUtc();
          if (at.isAfter(now.subtract(period)) && at.isBefore(start)) {
            start = at;
          }
        }
      }
      final held = <DateTime>[], current = <DateTime>[], recent = <DateTime>[];
      for (final row in [...rows, ...legacy]) {
        final data = row.value, outcome = data['outcome'];
        if (!{
          'reserved',
          'unknown',
          'completed',
          'notDispatched',
        }.contains(outcome)) {
          throw const FormatException('invalid_companion_outcome');
        }
        if (outcome == 'notDispatched') continue;
        final at = DateTime.parse(data['at']! as String).toUtc();
        if (outcome == 'reserved' || outcome == 'unknown') {
          held.add(at);
        } else if (!at.isBefore(start)) {
          current.add(at);
        }
        if (at.isAfter(since)) recent.add(at);
      }
      final maximum = budget.maximumCalls.clamp(1, 64),
          perMinute = budget.maximumCallsPerMinute.clamp(1, 8);
      final exhausted = held.length + current.length >= maximum;
      if (exhausted &&
          held.where((at) => at.isBefore(start)).length >= maximum) {
        return SurfacePlayCallReservation.totalExhausted;
      }
      DateTime? next;
      if (exhausted) next = start.add(period);
      recent.sort();
      if (recent.length >= perMinute) {
        final time = recent[recent.length - perMinute].add(
          const Duration(minutes: 1),
        );
        if (next == null || time.isAfter(next)) next = time;
      }
      await periodRef.put(tx, {
        'scopeKey': scopeKey,
        'agentId': agentId,
        'periodStart': start.toIso8601String(),
        'lastSeenAt': now.toIso8601String(),
      });
      _guard();
      if (!isAuthorized()) throw StateError('PLAY_COMMIT_REVOKED');
      if (next != null) return SurfacePlayCallReservation.rateLimited(next);
      await ref.put(tx, {
        'schemaVersion': 1,
        'scopeKey': scopeKey,
        'agentId': agentId,
        'invocationId': invocationId,
        'requestDigest': requestDigest,
        'at': now.toIso8601String(),
        'outcome': 'reserved',
      });
      _guard();
      if (!isAuthorized()) throw StateError('PLAY_COMMIT_REVOKED');
      return SurfacePlayCallReservation.reserved;
    });
    _guard();
    return result;
  }

  Future<void> settle({
    required String agentId,
    required String invocationId,
    required String requestDigest,
    required SurfaceCompanionCallOutcome outcome,
  }) async {
    _guard();
    _validate(agentId, invocationId, requestDigest);
    await _database.raw.transaction((tx) async {
      _guard();
      final ref = _calls.record(_key(agentId, invocationId)),
          row = await ref.get(tx);
      if (row == null) throw StateError('COMPANION_INVOCATION_NOT_FOUND');
      _identity(row, agentId, invocationId, requestDigest);
      final old = row['outcome'];
      if (old == outcome.name) return;
      if (old != 'reserved' &&
          !(old == 'unknown' &&
              outcome == SurfaceCompanionCallOutcome.completed)) {
        throw StateError('COMPANION_OUTCOME_CONFLICT');
      }
      await ref.put(tx, {...row, 'outcome': outcome.name});
      _guard();
    });
    _guard();
  }

  Future<void> _importLegacy(Transaction tx) async {
    if (await _migration.record(scopeKey).exists(tx)) return;
    final matches = await _matches.find(
      tx,
      finder: Finder(
        filter: Filter.or([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('scopeKey', '$scopeKey|preview'),
        ]),
        limit: 8193,
      ),
    );
    if (matches.length > 8192) {
      throw StateError('COMPANION_LEGACY_REVIEW_REQUIRED');
    }
    for (final match in matches) {
      final record = match.value;
      if (record['budgetLedgerVersion'] == 1) continue;
      // Old checkpoints did not record agentId; preserve their holds in an
      // account-wide conservative pool rather than inventing an owner.
      for (final raw in record['modelCalls'] as List? ?? const []) {
        final call = playObject(raw), id = playIdentifier(call['invocationId']);
        final outcome = call['outcome'];
        if (!{'reserved', 'unknown', 'completed'}.contains(outcome)) {
          throw const FormatException('invalid_legacy_companion_call');
        }
        final at = DateTime.parse(call['at']! as String).toUtc();
        final key = sha256
            .convert(
              utf8.encode(
                jsonEncode([
                  scopeKey,
                  record['scopeKey'],
                  record['matchId'],
                  id,
                ]),
              ),
            )
            .toString();
        await _legacy.record(key).put(tx, {
          'scopeKey': scopeKey,
          'at': at.toIso8601String(),
          'outcome': outcome,
        });
      }
    }
    await _migration.record(scopeKey).put(tx, {
      'scopeKey': scopeKey,
      'schemaVersion': 1,
    });
    _guard();
  }
}
