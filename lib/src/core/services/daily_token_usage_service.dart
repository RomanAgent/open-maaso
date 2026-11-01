import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

import 'metered_llm_http_client.dart';

/// Provider-reported numbers, never context estimates or quota reservations.
/// Completion already includes reasoning; cached input already belongs to input.
final class ReportedTokenUsage {
  const ReportedTokenUsage({
    this.input,
    this.output,
    required this.total,
    this.incomplete = false,
  });
  final int? input;
  final int? output;
  final int total;
  final bool incomplete;

  ReportedTokenUsage asIncomplete() => ReportedTokenUsage(
    input: input,
    output: output,
    total: total,
    incomplete: true,
  );

  static ReportedTokenUsage? fromPayload(Object? payload) {
    if (payload is! Map) return null;
    final gemini = payload['usageMetadata'];
    final raw = gemini is Map ? gemini : payload['usage'];
    if (raw is! Map) return null;
    // Explicit estimate metadata is never actual provider usage. Missing is
    // compatible with standard providers; present must be the boolean false.
    if (raw.containsKey('estimated') && raw['estimated'] != false) return null;
    int? number(Object? value) =>
        value is int && value >= 0 && value <= 1000000000 ? value : null;
    final input = number(
      raw[gemini is Map ? 'promptTokenCount' : 'prompt_tokens'],
    );
    var output = number(
      raw[gemini is Map ? 'candidatesTokenCount' : 'completion_tokens'],
    );
    final explicitTotal = number(
      raw[gemini is Map ? 'totalTokenCount' : 'total_tokens'],
    );
    final fields = gemini is Map
        ? const [
            'promptTokenCount',
            'candidatesTokenCount',
            'totalTokenCount',
            'thoughtsTokenCount',
          ]
        : const ['prompt_tokens', 'completion_tokens', 'total_tokens'];
    if (fields.any((key) => raw[key] != null && number(raw[key]) == null)) {
      return null;
    }
    if (gemini is Map) {
      if (explicitTotal != null && input != null && explicitTotal >= input) {
        final reportedOutput =
            (output ?? 0) + (number(raw['thoughtsTokenCount']) ?? 0);
        if (reportedOutput > explicitTotal - input) return null;
        output = explicitTotal - input;
      } else if (output != null) {
        output += number(raw['thoughtsTokenCount']) ?? 0;
      }
    }
    final total =
        explicitTotal ??
        (input != null && output != null ? input + output : null);
    if (total == null ||
        input != null && input > total ||
        output != null && output > total ||
        input != null && output != null && input + output > total) {
      return null;
    }
    return ReportedTokenUsage(input: input, output: output, total: total);
  }
}

final class DailyTokenUsage {
  const DailyTokenUsage({
    required this.day,
    this.total = 0,
    this.input = 0,
    this.output = 0,
    this.reportedRequests = 0,
    this.unreportedRequests = 0,
    this.missingInput = 0,
    this.missingOutput = 0,
    this.incompleteRequests = 0,
  });
  final String day;
  final int total, input, output;
  final int reportedRequests, unreportedRequests, missingInput, missingOutput;
  final int incompleteRequests;
  bool get partial =>
      unreportedRequests > 0 ||
      missingInput > 0 ||
      missingOutput > 0 ||
      incompleteRequests > 0;

  factory DailyTokenUsage.fromJson(String day, Map<String, Object?>? value) {
    int read(String key) => value?[key] is int ? value![key] as int : 0;
    return DailyTokenUsage(
      day: day,
      total: read('total'),
      input: read('input'),
      output: read('output'),
      reportedRequests: read('reportedRequests'),
      unreportedRequests: read('unreportedRequests'),
      missingInput: read('missingInput'),
      missingOutput: read('missingOutput'),
      incompleteRequests: read('incompleteRequests'),
    );
  }
}

/// One local account owns the database and these clients. It never reads another
/// device's usage or persists model content, credentials, or provider URLs.
final class DailyTokenUsageService extends AppService
    with WidgetsBindingObserver {
  DailyTokenUsageService({
    required Database database,
    required this.accountScopeDigest,
    required bool Function() isCurrent,
    DateTime Function()? now,
    http.Client Function()? clientFactory,
  }) : _database = database,
       _current = isCurrent,
       _now = now ?? DateTime.now,
       _clientFactory = clientFactory ?? http.Client.new {
    today = DailyTokenUsage(day: dayKey(_now())).obs;
  }

  final Database _database;
  final String accountScopeDigest;
  final bool Function() _current;
  final DateTime Function() _now;
  final http.Client Function() _clientFactory;
  late final Rx<DailyTokenUsage> today;
  final loading = true.obs;
  final unavailable = false.obs;
  final Set<http.Client> _clients = {};
  Future<void> _pending = Future<void>.value();
  Future<void> get whenSettled => _pending;
  Timer? _midnight;
  bool _retired = false;
  bool _closing = false;
  int _refreshGeneration = 0;
  bool get isCurrent => !_retired && _current();
  static final _days = StoreRef<String, Map<String, Object?>>(
    'daily_model_token_usage',
  );
  static final _receipts = StoreRef<String, Map<String, Object?>>(
    'model_token_usage_receipts',
  );
  static String dayKey(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  String _key(String day) => '$accountScopeDigest:$day';

  Future<DailyTokenUsageService> init({bool observeLifecycle = true}) async {
    await refresh();
    if (observeLifecycle && isCurrent) {
      WidgetsBinding.instance.addObserver(this);
      _scheduleMidnight();
    }
    return this;
  }

  Future<void> refresh() async {
    if (!isCurrent) {
      loading.value = false;
      unavailable.value = true;
      return;
    }
    final generation = ++_refreshGeneration;
    final day = dayKey(_now());
    // Clear yesterday immediately, even before the database read completes.
    if (today.value.day != day) today.value = DailyTokenUsage(day: day);
    try {
      final value = await _days.record(_key(day)).get(_database);
      if (!isCurrent ||
          generation != _refreshGeneration ||
          day != dayKey(_now())) {
        return;
      }
      today.value = DailyTokenUsage.fromJson(day, value);
      unavailable.value = false;
    } catch (_) {
      if (isCurrent) unavailable.value = true;
    } finally {
      if (isCurrent) loading.value = false;
    }
  }

  http.Client createClient() {
    if (_closing || !isCurrent) throw StateError('token_usage_account_changed');
    late final MeteredLlmHttpClient client;
    client = MeteredLlmHttpClient(
      inner: _clientFactory(),
      now: _now,
      canDispatch: () => isCurrent,
      record: record,
      onClosed: () => _clients.remove(client),
    );
    _clients.add(client);
    return client;
  }

  Future<void> record({
    required String requestId,
    required DateTime dispatchedAt,
    required ReportedTokenUsage? usage,
  }) {
    if (_closing || !isCurrent) return Future<void>.value();
    final day = dayKey(dispatchedAt);
    final operation = _pending.then((_) async {
      if (!isCurrent) return;
      try {
        await _database.transaction((tx) async {
          if (!isCurrent) return;
          final receipt = _receipts.record('$accountScopeDigest:$requestId');
          if (await receipt.exists(tx)) return;
          if (!isCurrent) throw StateError('token_usage_account_changed');
          final daily = _days.record(_key(day));
          final old = DailyTokenUsage.fromJson(day, await daily.get(tx));
          await daily.put(tx, {
            'total': old.total + (usage?.total ?? 0),
            'input': old.input + (usage?.input ?? 0),
            'output': old.output + (usage?.output ?? 0),
            'reportedRequests': old.reportedRequests + (usage == null ? 0 : 1),
            'unreportedRequests':
                old.unreportedRequests + (usage == null ? 1 : 0),
            'missingInput':
                old.missingInput +
                (usage != null && usage.input == null ? 1 : 0),
            'missingOutput':
                old.missingOutput +
                (usage != null && usage.output == null ? 1 : 0),
            'incompleteRequests':
                old.incompleteRequests + (usage?.incomplete == true ? 1 : 0),
          });
          await receipt.put(tx, {'day': day});
          if (!isCurrent) throw StateError('token_usage_account_changed');
        });
        await refresh();
      } catch (_) {
        // Metering must not fail a valid model response or cause a paid retry.
        if (isCurrent) unavailable.value = true;
      }
    });
    _pending = operation;
    return operation;
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    if (!isCurrent) return;
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

  Future<void> shutdown() async {
    // Account teardown runs this after model/runtime drains. Fence new receipts
    // before closing transport so closure errors cannot publish telemetry into
    // a retired account. Already admitted database writes are awaited below;
    // every callback remains bound to this old service, never a replacement.
    _closing = true;
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final client in List<http.Client>.of(_clients)) {
      client.close();
    }
    _clients.clear();
    await _pending;
    _retired = true;
    loading.value = false;
    unavailable.value = true;
  }

  @override
  void onClose() {
    _closing = true;
    _retired = true;
    loading.value = false;
    unavailable.value = true;
    _midnight?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final client in List<http.Client>.of(_clients)) {
      client.close();
    }
    _clients.clear();
    super.onClose();
  }
}
