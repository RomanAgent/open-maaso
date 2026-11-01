import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

/// The actual execution lane, never the source of a suggestion or discovery.
/// Prompt usage means selected instructions reached an actual model dispatch.
enum SkillUsageChannel { native, structured, local, delayed, prompt }

class SkillUsageSummary {
  const SkillUsageSummary({
    this.started = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.lastUsed,
  });

  final int started;

  /// Handler execution outcome, not proof that a user's wider goal completed.
  final int succeeded;
  final int failed;
  final DateTime? lastUsed;

  /// Includes work still running and work interrupted before a completion.
  int get unfinished => started - succeeded - failed;
}

final class SkillUsageStats extends SkillUsageSummary {
  const SkillUsageStats({
    required this.skillName,
    required this.method,
    required this.channel,
    super.started,
    super.succeeded,
    super.failed,
    super.lastUsed,
  });

  final String skillName;
  final String method;
  final SkillUsageChannel channel;
}

/// A one-use completion callback bound to the service that admitted the call.
/// It never resolves a replacement account's service or stores handler data.
final class SkillUsageAttempt {
  SkillUsageAttempt._({
    required SkillUsageService owner,
    required this.skillName,
    required this.method,
    required this.channel,
    required DateTime startedAt,
  }) : _owner = owner,
       _startedAt = startedAt;

  final SkillUsageService _owner;
  final String skillName;
  final String method;
  final SkillUsageChannel channel;
  final DateTime _startedAt;
  bool _finished = false;
  bool _recorded = false;

  /// Repeated callbacks do not create extra completions. Stats failures are
  /// contained by the owner and must never change the handler's own result.
  Future<void> finish({required bool succeeded}) {
    if (_finished) return Future<void>.value();
    _finished = true;
    return _owner._complete(this, succeeded: succeeded);
  }
}

/// Local-only usage in one account's database and backend environment.
///
/// Call [start] only after discovery, schema and permission checks, immediately
/// before invoking the actual handler. A retry that reaches a handler is a new
/// use. Nothing here can record arguments, replies, errors or network addresses.
final class SkillUsageService extends AppService with WidgetsBindingObserver {
  SkillUsageService({
    required Database database,
    required this.accountScopeDigest,
    required bool Function() isCurrent,
    DateTime Function()? now,
  }) : _database = database,
       _current = isCurrent,
       _now = now ?? DateTime.now {
    if (RegExp(r'^[a-f0-9]{64}$').stringMatch(accountScopeDigest) !=
        accountScopeDigest) {
      throw ArgumentError('Skill usage requires an account storage digest');
    }
  }

  final Database _database;
  final String accountScopeDigest;
  final bool Function() _current;
  final DateTime Function() _now;
  final entries = Rx<List<SkillUsageStats>>(const []);
  final loading = true.obs;
  final unavailable = false.obs;
  Future<void> _pending = Future<void>.value();
  Timer? _midnight;
  bool _retired = false;
  bool _closing = false;

  static final _totals = StoreRef<String, Map<String, Object?>>(
    'skill_usage_totals.v1',
  );
  static final _days = StoreRef<String, Map<String, Object?>>(
    'skill_usage_days.v1',
  );
  static final _skillName = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$');
  static final _method = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');
  static final _promptSkillName = RegExp(
    r'^(marketplace|learned):[a-f0-9]{64}$',
  );
  static final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static const _maxCount = 9007199254740991;

  Future<void> get whenSettled => _pending;

  bool get isCurrent {
    if (_retired) return false;
    try {
      return _current();
    } catch (_) {
      return false;
    }
  }

  Future<SkillUsageService> init({bool observeLifecycle = true}) async {
    await refresh();
    if (observeLifecycle && isCurrent) {
      WidgetsBinding.instance.addObserver(this);
      _scheduleMidnight();
    }
    return this;
  }

  /// No database wait is introduced before a handler's first response.
  SkillUsageAttempt? start({
    required String skillName,
    required String method,
    required SkillUsageChannel channel,
  }) {
    if (_closing ||
        !isCurrent ||
        !_validDimensions(skillName, method, channel)) {
      return null;
    }
    DateTime startedAt;
    try {
      startedAt = _now();
    } catch (_) {
      unavailable.value = true;
      return null;
    }
    final attempt = SkillUsageAttempt._(
      owner: this,
      skillName: skillName,
      method: method,
      channel: channel,
      startedAt: startedAt,
    );
    unawaited(_record(attempt));
    return attempt;
  }

  SkillUsageSummary forSkill(String skillName) {
    if (!isCurrent) return const SkillUsageSummary();
    var started = 0;
    var succeeded = 0;
    var failed = 0;
    DateTime? lastUsed;
    for (final entry in entries.value) {
      if (entry.skillName != skillName) continue;
      started += entry.started;
      succeeded += entry.succeeded;
      failed += entry.failed;
      final used = entry.lastUsed;
      if (used != null && (lastUsed == null || used.isAfter(lastUsed))) {
        lastUsed = used;
      }
    }
    return SkillUsageSummary(
      started: started,
      succeeded: succeeded,
      failed: failed,
      lastUsed: lastUsed,
    );
  }

  /// All-time totals by default; a local calendar day queries that day's calls.
  /// Invalid day values and retired accounts return no data.
  Future<List<SkillUsageStats>> read({String? day}) async {
    if (_closing || !isCurrent || day != null && !_validDay(day)) {
      return const [];
    }
    var result = const <SkillUsageStats>[];
    await _enqueue(() async {
      result = await _readEntries(day: day);
    });
    return isCurrent ? result : const [];
  }

  Future<void> refresh() {
    if (_closing || !isCurrent) {
      loading.value = false;
      unavailable.value = true;
      entries.value = const [];
      return Future<void>.value();
    }
    return _enqueue(_refreshEntries);
  }

  Future<void> _refreshEntries() async {
    try {
      final values = await _readEntries();
      if (isCurrent) entries.value = values;
    } finally {
      if (isCurrent) loading.value = false;
    }
  }

  Future<List<SkillUsageStats>> _readEntries({String? day}) async {
    final prefix = '$accountScopeDigest:${day == null ? '' : '$day:'}';
    final store = day == null ? _totals : _days;
    final records = await store.find(
      _database,
      finder: Finder(
        filter: Filter.custom((row) {
          final key = row.key;
          return key is String && key.startsWith(prefix);
        }),
      ),
    );
    _requireCurrent();
    final result = <SkillUsageStats>[];
    for (final record in records) {
      final value = _decode(record.value);
      if (value == null || record.key != _key(value, day: day)) continue;
      result.add(value);
    }
    result.sort((a, b) {
      final skillOrder = a.skillName.compareTo(b.skillName);
      if (skillOrder != 0) return skillOrder;
      final methodOrder = a.method.compareTo(b.method);
      return methodOrder == 0
          ? a.channel.index.compareTo(b.channel.index)
          : methodOrder;
    });
    return List<SkillUsageStats>.unmodifiable(result);
  }

  Future<void> _complete(SkillUsageAttempt attempt, {required bool succeeded}) {
    if (_closing || !isCurrent || !identical(attempt._owner, this)) {
      return Future<void>.value();
    }
    return _record(attempt, succeeded: succeeded);
  }

  Future<void> _record(SkillUsageAttempt attempt, {bool? succeeded}) =>
      _enqueue(() async {
        if (succeeded != null && !attempt._recorded) {
          throw StateError('skill_usage_start_not_recorded');
        }
        final day = _dayKey(attempt._startedAt);
        await _database.transaction((tx) async {
          _requireCurrent();
          for (final store in [_totals, _days]) {
            final dimension = SkillUsageStats(
              skillName: attempt.skillName,
              method: attempt.method,
              channel: attempt.channel,
            );
            final record = store.record(
              _key(dimension, day: identical(store, _days) ? day : null),
            );
            final raw = await record.get(tx);
            _requireCurrent();
            final old = raw == null ? dimension : _decode(raw);
            if (old == null ||
                old.skillName != dimension.skillName ||
                old.method != dimension.method ||
                old.channel != dimension.channel) {
              throw const FormatException('invalid_skill_usage_record');
            }
            // If writing the start failed, do not count a phantom completion.
            if (succeeded != null && old.unfinished == 0) continue;
            final lastUsed = old.lastUsed;
            await record.put(tx, {
              'skillName': dimension.skillName,
              'method': dimension.method,
              'channel': dimension.channel.name,
              'started': _increment(old.started, succeeded == null),
              'succeeded': _increment(old.succeeded, succeeded == true),
              'failed': _increment(old.failed, succeeded == false),
              'lastUsed':
                  lastUsed == null || attempt._startedAt.isAfter(lastUsed)
                  ? attempt._startedAt.millisecondsSinceEpoch
                  : lastUsed.millisecondsSinceEpoch,
            });
            _requireCurrent();
          }
        });
        if (succeeded == null) attempt._recorded = true;
        await _refreshEntries();
      });

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) async {
      if (!isCurrent) return;
      try {
        await operation();
        if (isCurrent) unavailable.value = false;
      } catch (_) {
        // Usage must never fail a handler or trigger a retry of its side effect.
        if (isCurrent) {
          unavailable.value = true;
          loading.value = false;
        }
      }
    });
    _pending = result;
    return result;
  }

  void _requireCurrent() {
    if (!isCurrent) throw StateError('skill_usage_account_changed');
  }

  String _key(SkillUsageStats value, {String? day}) =>
      '$accountScopeDigest:${day == null ? '' : '$day:'}'
      '${value.skillName}:${value.method}:${value.channel.name}';

  static int _increment(int count, bool increment) =>
      increment && count < _maxCount ? count + 1 : count;

  static SkillUsageStats? _decode(Map<String, Object?> value) {
    final skillName = value['skillName'];
    final method = value['method'];
    if (skillName is! String || method is! String) return null;
    SkillUsageChannel? channel;
    for (final candidate in SkillUsageChannel.values) {
      if (candidate.name == value['channel']) channel = candidate;
    }
    int? read(String key) {
      final count = value[key];
      return count is int && count >= 0 && count <= _maxCount ? count : null;
    }

    final started = read('started');
    final succeeded = read('succeeded');
    final failed = read('failed');
    final lastUsed = value['lastUsed'];
    if (channel == null ||
        !_validDimensions(skillName, method, channel) ||
        started == null ||
        succeeded == null ||
        failed == null ||
        succeeded + failed > started ||
        lastUsed is! int ||
        lastUsed.abs() > 8640000000000000) {
      return null;
    }
    return SkillUsageStats(
      skillName: skillName,
      method: method,
      channel: channel,
      started: started,
      succeeded: succeeded,
      failed: failed,
      lastUsed: DateTime.fromMillisecondsSinceEpoch(lastUsed),
    );
  }

  static String _dayKey(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static bool _validDimensions(
    String skillName,
    String method,
    SkillUsageChannel channel,
  ) => channel == SkillUsageChannel.prompt
      ? method == 'applyPrompt' &&
            _promptSkillName.stringMatch(skillName) == skillName
      : _skillName.stringMatch(skillName) == skillName &&
            _method.stringMatch(method) == method;

  static bool _validDay(String day) {
    if (_day.stringMatch(day) != day) return false;
    final value = DateTime.tryParse(day);
    return value != null && _dayKey(value) == day;
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    if (_closing || !isCurrent) return;
    final local = _now().toLocal();
    final tomorrow = DateTime(local.year, local.month, local.day + 1);
    _midnight = Timer(tomorrow.difference(local), () {
      unawaited(refresh());
      _scheduleMidnight();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
      _scheduleMidnight();
    }
  }

  /// Called as soon as the captured account mount is invalidated. History stays
  /// in its original database; UI and late handler completions are fenced now.
  void retire() {
    _closing = true;
    _retired = true;
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    entries.value = const [];
    loading.value = false;
    unavailable.value = true;
  }

  Future<void> shutdown() async {
    _closing = true;
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    await _pending;
    retire();
  }

  @override
  void onClose() {
    retire();
    super.onClose();
  }
}
