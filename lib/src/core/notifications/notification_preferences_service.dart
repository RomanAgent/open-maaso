import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/proactive_category_persona_memory.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationPreferences {
  const NotificationPreferences({
    this.enabled = false,
    this.permissionGranted = false,
    this.greetingsEnabled = true,
    this.randomCheckInsEnabled = true,
    this.scheduledTasksEnabled = true,
    this.quietStartMinutes = 22 * 60,
    this.quietEndMinutes = 7 * 60,
    this.dailyProactiveBudget = 3,
  });

  final bool enabled;
  final bool permissionGranted;
  final bool greetingsEnabled;
  final bool randomCheckInsEnabled;
  final bool scheduledTasksEnabled;
  final int quietStartMinutes;
  final int quietEndMinutes;
  final int dailyProactiveBudget;

  bool get canNotify => enabled && permissionGranted;

  bool isQuietAt(DateTime time) {
    final minute = time.hour * 60 + time.minute;
    if (quietStartMinutes == quietEndMinutes) return false;
    if (quietStartMinutes < quietEndMinutes) {
      return minute >= quietStartMinutes && minute < quietEndMinutes;
    }
    return minute >= quietStartMinutes || minute < quietEndMinutes;
  }

  NotificationPreferences copyWith({
    bool? enabled,
    bool? permissionGranted,
    bool? greetingsEnabled,
    bool? randomCheckInsEnabled,
    bool? scheduledTasksEnabled,
    int? quietStartMinutes,
    int? quietEndMinutes,
    int? dailyProactiveBudget,
  }) => NotificationPreferences(
    enabled: enabled ?? this.enabled,
    permissionGranted: permissionGranted ?? this.permissionGranted,
    greetingsEnabled: greetingsEnabled ?? this.greetingsEnabled,
    randomCheckInsEnabled: randomCheckInsEnabled ?? this.randomCheckInsEnabled,
    scheduledTasksEnabled: scheduledTasksEnabled ?? this.scheduledTasksEnabled,
    quietStartMinutes: quietStartMinutes ?? this.quietStartMinutes,
    quietEndMinutes: quietEndMinutes ?? this.quietEndMinutes,
    dailyProactiveBudget: (dailyProactiveBudget ?? this.dailyProactiveBudget)
        .clamp(1, 4),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'permissionGranted': permissionGranted,
    'greetingsEnabled': greetingsEnabled,
    'randomCheckInsEnabled': randomCheckInsEnabled,
    'scheduledTasksEnabled': scheduledTasksEnabled,
    'quietStartMinutes': quietStartMinutes,
    'quietEndMinutes': quietEndMinutes,
    'dailyProactiveBudget': dailyProactiveBudget,
  };

  static NotificationPreferences fromJson(Map<String, Object?> json) {
    int boundedMinute(Object? value, int fallback) {
      final parsed = value is num ? value.toInt() : int.tryParse('$value');
      if (parsed == null || parsed < 0 || parsed >= 24 * 60) return fallback;
      return parsed;
    }

    int boundedBudget(Object? value) {
      final parsed = value is num ? value.toInt() : int.tryParse('$value');
      return (parsed ?? 3).clamp(1, 4);
    }

    return NotificationPreferences(
      enabled: json['enabled'] == true,
      permissionGranted: json['permissionGranted'] == true,
      greetingsEnabled: json['greetingsEnabled'] != false,
      randomCheckInsEnabled: json['randomCheckInsEnabled'] != false,
      scheduledTasksEnabled: json['scheduledTasksEnabled'] != false,
      quietStartMinutes: boundedMinute(json['quietStartMinutes'], 22 * 60),
      quietEndMinutes: boundedMinute(json['quietEndMinutes'], 7 * 60),
      dailyProactiveBudget: boundedBudget(json['dailyProactiveBudget']),
    );
  }
}

class NotificationPreferencesService extends AppService {
  NotificationPreferencesService({
    SharedPreferences? preferences,
    this.requirePersonaMemory = true,
  }) : _preferences = preferences;

  /// Standalone device fixtures do not impersonate a mounted production account.
  NotificationPreferencesService.forTesting({SharedPreferences? preferences})
    : _preferences = preferences,
      requirePersonaMemory = false;

  static const _storageKey = 'notification_preferences.v1';

  SharedPreferences? _preferences;
  final bool requirePersonaMemory;
  final state = const NotificationPreferences().obs;
  ProactiveCategoryPersonaMemoryStore? _categoryStore;
  ProactiveCategoryPersonaMemory _categoryMemory =
      const ProactiveCategoryPersonaMemory();
  bool _categoryReady = false;
  int _categoryGeneration = 0;
  Future<void> _categoryTail = Future<void>.value();
  Future<void> _deviceTail = Future<void>.value();
  Future<void>? _categoryBinding;

  bool get personaMemoryAvailable => !requirePersonaMemory || _categoryReady;
  String? get personaMemoryAccount => _categoryStore?.accountScopeDigest;

  Future<NotificationPreferencesService> init() async {
    _preferences ??= await SharedPreferences.getInstance();
    final raw = _preferences?.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          state.value = NotificationPreferences.fromJson(
            decoded.cast<String, Object?>(),
          );
        }
      } catch (_) {
        // Invalid legacy state is ignored in favour of privacy-safe defaults.
      }
    }
    if (requirePersonaMemory) _clearCategoryPresentation();
    return this;
  }

  /// The service itself stays app-wide because it owns this device's OS
  /// consent. Only these two remembered choices join the account lifecycle.
  Future<void> bindPersonaMemory(ProactiveCategoryPersonaMemoryStore store) {
    final retired = deactivatePersonaMemoryAndDrain();
    final generation = _categoryGeneration;
    final operation = () async {
      await retired;
      if (generation != _categoryGeneration || isClosed) return;
      _categoryStore = store;
      try {
        var memory = await store.read();
        final migration = ProactiveCategoryPersonaLegacyMigration(
          _preferences!,
        );
        ProactiveCategoryPersonaMemory? legacy;
        var legacyValid = true;
        try {
          legacy = await migration.claim(store.accountScopeDigest);
        } on Object {
          if (memory == null) rethrow;
          legacyValid = false;
          TurnTrace.event('agent.persona_categories.legacy_invalid');
        }
        if (memory == null && legacy != null) {
          await store.write(legacy);
          memory = legacy;
        }
        if (memory != null &&
            legacyValid &&
            await migration.completeOwnedClaim(store.accountScopeDigest)) {
          await _removeLegacyCategoryFields();
        }
        if (generation != _categoryGeneration || isClosed) return;
        _categoryMemory = memory ?? const ProactiveCategoryPersonaMemory();
        _categoryReady = true;
        state.value = state.value.copyWith(
          greetingsEnabled: _categoryMemory.greetings ?? true,
          randomCheckInsEnabled: _categoryMemory.randomCheckIns ?? true,
        );
      } on Object {
        if (generation == _categoryGeneration) {
          _categoryReady = false;
          _clearCategoryPresentation();
          TurnTrace.event('agent.persona_categories.unavailable');
        }
      }
    }();
    _categoryBinding = operation;
    return operation;
  }

  Future<void> deactivatePersonaMemoryAndDrain() {
    _categoryGeneration++;
    _categoryReady = false;
    _categoryStore = null;
    _categoryMemory = const ProactiveCategoryPersonaMemory();
    _clearCategoryPresentation();
    final binding = _categoryBinding;
    _categoryBinding = null;
    return Future.wait<void>([_categoryTail, ?binding]);
  }

  void _clearCategoryPresentation() {
    state.value = state.value.copyWith(
      greetingsEnabled: false,
      randomCheckInsEnabled: false,
    );
  }

  Future<void> setConsent({
    required bool enabled,
    required bool permissionGranted,
  }) => _update(
    (current) => current.copyWith(
      enabled: enabled && permissionGranted,
      permissionGranted: permissionGranted,
    ),
  );

  Future<void> setGreetingsEnabled(bool enabled) => requirePersonaMemory
      ? _rememberCategory(greetings: enabled)
      : _update((current) => current.copyWith(greetingsEnabled: enabled));

  Future<void> setRandomCheckInsEnabled(bool enabled) => requirePersonaMemory
      ? _rememberCategory(randomCheckIns: enabled)
      : _update((current) => current.copyWith(randomCheckInsEnabled: enabled));

  Future<void> setScheduledTasksEnabled(bool enabled) =>
      _update((current) => current.copyWith(scheduledTasksEnabled: enabled));

  Future<void> setQuietHours({required int start, required int end}) {
    if (start < 0 || start >= 24 * 60 || end < 0 || end >= 24 * 60) {
      throw ArgumentError('quiet-hour minutes must be within a day');
    }
    return _update(
      (current) =>
          current.copyWith(quietStartMinutes: start, quietEndMinutes: end),
    );
  }

  Future<void> setDailyProactiveBudget(int budget) =>
      _update((current) => current.copyWith(dailyProactiveBudget: budget));

  Future<void> _rememberCategory({bool? greetings, bool? randomCheckIns}) {
    final store = _categoryStore;
    final generation = _categoryGeneration;
    final operation = _categoryTail.then((_) async {
      if (!_categoryReady ||
          store == null ||
          !identical(store, _categoryStore) ||
          generation != _categoryGeneration ||
          isClosed) {
        throw StateError('persona_category_memory_unavailable');
      }
      final next = _categoryMemory.withChoice(
        greetings: greetings,
        randomCheckIns: randomCheckIns,
      );
      await store.write(next);
      if (generation != _categoryGeneration || isClosed) return;
      _categoryMemory = next;
      state.value = state.value.copyWith(
        greetingsEnabled: next.greetings ?? true,
        randomCheckInsEnabled: next.randomCheckIns ?? true,
      );
    });
    _categoryTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _update(
    NotificationPreferences Function(NotificationPreferences) mutate,
  ) {
    final operation = _deviceTail.then((_) async {
      final next = mutate(state.value);
      final json = next.toJson();
      if (requirePersonaMemory) {
        json.remove('greetingsEnabled');
        json.remove('randomCheckInsEnabled');
        // Preserve unclaimed legacy fields until the account copy commits.
        final raw = _preferences?.getString(_storageKey);
        if (raw != null) {
          try {
            final old = jsonDecode(raw);
            if (old is! Map) {
              throw const FormatException('invalid legacy notification record');
            }
            for (final key in ['greetingsEnabled', 'randomCheckInsEnabled']) {
              if (old.containsKey(key)) json[key] = old[key];
            }
          } on Object {
            // Never overwrite an invalid recoverable legacy record.
            throw StateError('notification_preferences_legacy_invalid');
          }
        }
      }
      if (!await _preferences!.setString(_storageKey, jsonEncode(json))) {
        throw StateError('notification_preferences_write_failed');
      }
      if (!isClosed) state.value = mutate(state.value);
    });
    _deviceTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _removeLegacyCategoryFields() {
    final operation = _deviceTail.then((_) async {
      final raw = _preferences!.getString(_storageKey);
      if (raw == null) return;
      final old = jsonDecode(raw);
      if (old is! Map) return;
      final next = Map<String, Object?>.from(old)
        ..remove('greetingsEnabled')
        ..remove('randomCheckInsEnabled');
      if (!await _preferences!.setString(_storageKey, jsonEncode(next))) {
        throw StateError('persona_category_legacy_cleanup_failed');
      }
    });
    _deviceTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  void onClose() {
    deactivatePersonaMemoryAndDrain();
    super.onClose();
  }
}
