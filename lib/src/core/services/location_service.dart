import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_platform.dart';
export 'location_platform.dart';

enum LocationStatus {
  idle,
  locating,
  available,
  disabled,
  permissionRequired,
  denied,
  deniedForever,
  servicesDisabled,
  timeout,
  unavailable,
  cityUnavailable,
  cancelled,
  retired,
}

/// City-level state only. Precise coordinates are never persisted, published
/// to the reactive graph, or included in the Agent's result.
final class LocationSnapshot {
  const LocationSnapshot(
    this.status, {
    this.city,
    this.region,
    this.country,
    this.countryCode,
  });
  final LocationStatus status;
  final String? city;
  final String? region;
  final String? country;
  final String? countryCode;

  bool get isSuccess =>
      status == LocationStatus.available && city?.isNotEmpty == true;
  String? get cityQuery => isSuccess
      ? <String>{
          city!,
          if (region?.isNotEmpty == true) region!,
          if (country?.isNotEmpty == true) country!,
        }.join(' ')
      : null;
}

/// Account-owned, foreground-only, on-demand city lookup. Initialization reads
/// one account preference and never starts GPS or shows a permission dialog.
final class LocationService extends AppService with WidgetsBindingObserver {
  LocationService({
    LocationPlatform? platform,
    Future<SharedPreferences> Function()? preferencesLoader,
    bool Function()? isForeground,
    bool Function()? isOwnerCurrent,
    DateTime Function()? now,
  }) : _platform = platform ?? GeolocatorLocationPlatform(),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _isForeground = isForeground ?? (() => true),
       _isOwnerCurrent = isOwnerCurrent ?? (() => true),
       _now = now ?? DateTime.now;

  final LocationPlatform _platform;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final bool Function() _isForeground;
  final bool Function() _isOwnerCurrent;
  final DateTime Function() _now;
  final enabled = true.obs;
  final state = const LocationSnapshot(LocationStatus.permissionRequired).obs;
  SharedPreferences? _preferences;
  String? _storageKey;
  bool _active = false;
  bool _retired = false;
  bool _foreground = true;
  bool _observing = false;
  int _generation = 0;
  int _settingRevision = 0;
  Future<void> _writes = Future<void>.value();
  Future<void> _cancellations = Future<void>.value();
  Future<LocationSnapshot>? _pending;
  LocationSnapshot? _cache;
  DateTime? _cachedAt;

  bool get _owns => _active && !_retired && !isClosed && _isOwnerCurrent();
  bool get _canLocate =>
      _owns && enabled.value && _foreground && _isForeground();

  /// Invalidates consumers when permission, foreground, or ownership changes.
  int get authorityGeneration => _generation;

  /// Platform capability, separate from a temporarily unavailable fix so the
  /// settings UI can offer retries only on supported hosts.
  bool get isSupported => _platform.isSupported;

  /// Existing authorized country only, without permission checks or new GPS.
  /// Country remains in the same short-lived in-memory city cache; callers
  /// cannot read it after opt-out, backgrounding, expiry or account retirement.
  String? get cachedCountryCode {
    if (!_canLocate || state.value.status != LocationStatus.available) {
      return null;
    }
    final cachedAt = _cachedAt;
    if (cachedAt == null) return null;
    final age = _now().difference(cachedAt);
    if (age < Duration.zero || age >= const Duration(minutes: 5)) return null;
    return _cache?.countryCode;
  }

  Future<LocationService> init({required AccountStorageScope scope}) async {
    if (_storageKey != null || isClosed || _retired) {
      throw StateError('location_service_already_initialized');
    }
    _storageKey = '${scope.storageNamespace}.preferences.location.enabled.v1';
    try {
      final preferences = await _preferencesLoader();
      if (isClosed || _retired || !_isOwnerCurrent()) {
        return this;
      }
      _preferences = preferences;
      final stored = preferences.get(_storageKey!);
      enabled.value = stored == null || stored == true;
      _active = true;
      state.value = LocationSnapshot(
        !enabled.value
            ? LocationStatus.disabled
            : !_platform.isSupported
            ? LocationStatus.unavailable
            : LocationStatus.permissionRequired,
      );
    } on Object {
      if (!_retired && !isClosed && _isOwnerCurrent()) {
        enabled.value = false;
        state.value = const LocationSnapshot(LocationStatus.unavailable);
      }
    }
    return this;
  }

  @override
  void onInit() {
    super.onInit();
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null) didChangeAppLifecycleState(lifecycle);
    } on FlutterError {
      // Unit tests can inject lifecycle state without installing a binding.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setForeground(true);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      setForeground(false);
    }
    // An iOS permission sheet makes the app inactive; it remains foreground.
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) _invalidate(LocationStatus.cancelled);
  }

  Future<void> setEnabled(bool value) {
    if (!_owns) {
      return Future<void>.error(StateError('location_service_retired'));
    }
    final revision = ++_settingRevision;
    if (!value) {
      enabled.value = false;
      _invalidate(LocationStatus.disabled);
    }
    final write = _writes.then((_) async {
      if (!_owns) throw StateError('location_service_retired');
      final saved = await _preferences!.setBool(_storageKey!, value);
      if (!saved) throw StateError('location_preference_save_failed');
      if (!_owns || revision != _settingRevision) return;
      enabled.value = value;
      if (value) {
        _invalidate(
          _platform.isSupported
              ? LocationStatus.permissionRequired
              : LocationStatus.unavailable,
        );
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  Future<LocationSnapshot> refreshPermission() async {
    if (!_owns) return const LocationSnapshot(LocationStatus.retired);
    if (!enabled.value) {
      return _publish(const LocationSnapshot(LocationStatus.disabled));
    }
    if (!_platform.isSupported) {
      return _publish(const LocationSnapshot(LocationStatus.unavailable));
    }
    final generation = _generation;
    try {
      final serviceEnabled = await _platform.isServiceEnabled();
      if (!_valid(generation)) return _cancelled();
      if (!serviceEnabled) return _fail(LocationStatus.servicesDisabled);
      final permission = await _platform.checkPermission();
      if (!_valid(generation)) return _cancelled();
      if (permission == LocationPermissionState.granted) {
        if (_pending != null) return state.value;
        return _publish(_cache ?? const LocationSnapshot(LocationStatus.idle));
      }
      return _fail(
        permission == LocationPermissionState.deniedForever
            ? LocationStatus.deniedForever
            : LocationStatus.permissionRequired,
      );
    } on Object {
      if (!_valid(generation)) return _cancelled();
      return _fail(LocationStatus.unavailable);
    }
  }

  Future<LocationSnapshot> locate({
    bool requestPermission = true,
    bool Function()? isCurrent,
  }) async {
    if (!_owns) return const LocationSnapshot(LocationStatus.retired);
    if (!enabled.value) return const LocationSnapshot(LocationStatus.disabled);
    if (!_canLocate || isCurrent?.call() == false) return _cancelled();
    if (!_platform.isSupported) {
      return _publish(const LocationSnapshot(LocationStatus.unavailable));
    }
    final generation = _generation;
    final existing = _pending;
    if (existing != null) {
      final result = await existing;
      return _valid(generation, isCurrent) ? result : _cancelled();
    }
    late final Future<LocationSnapshot> work;
    work = _locate(generation, requestPermission, isCurrent).whenComplete(() {
      if (identical(_pending, work)) _pending = null;
    });
    _pending = work;
    return work;
  }

  Future<LocationSnapshot> _locate(
    int generation,
    bool requestPermission,
    bool Function()? isCurrent,
  ) async {
    try {
      await _cancellations;
      if (!_valid(generation, isCurrent)) return _stale(generation);
      if (!await _platform.isServiceEnabled()) {
        return _valid(generation, isCurrent)
            ? _fail(LocationStatus.servicesDisabled)
            : _stale(generation);
      }
      if (!_valid(generation, isCurrent)) return _stale(generation);
      var permission = await _platform.checkPermission();
      if (!_valid(generation, isCurrent)) return _stale(generation);
      if (permission == LocationPermissionState.denied && requestPermission) {
        permission = await _platform.requestPermission();
        if (!_valid(generation, isCurrent)) return _stale(generation);
      }
      if (permission != LocationPermissionState.granted) {
        return _fail(
          permission == LocationPermissionState.deniedForever
              ? LocationStatus.deniedForever
              : permission == LocationPermissionState.denied &&
                    requestPermission
              ? LocationStatus.denied
              : LocationStatus.permissionRequired,
        );
      }
      final cachedAt = _cachedAt;
      final age = cachedAt == null ? null : _now().difference(cachedAt);
      if (_cache != null &&
          age != null &&
          age >= Duration.zero &&
          age < const Duration(minutes: 5)) {
        return _publish(_cache!);
      }
      _publish(const LocationSnapshot(LocationStatus.locating));
      final position = await _platform.currentPosition();
      if (!_valid(generation, isCurrent)) return _stale(generation);
      if (!position.isValid) return _fail(LocationStatus.unavailable);
      final place = await _platform.reverseGeocode(position);
      if (!_valid(generation, isCurrent)) return _stale(generation);
      final city = _placeField(place.city);
      if (city == null) return _fail(LocationStatus.cityUnavailable);
      final result = LocationSnapshot(
        LocationStatus.available,
        city: city,
        region: _placeField(place.region),
        country: _placeField(place.country),
        countryCode: _countryCodeField(place.countryCode),
      );
      _cache = result;
      _cachedAt = _now();
      return _publish(result);
    } catch (error) {
      if (!_valid(generation, isCurrent)) return _stale(generation);
      final status = error is LocationPlatformException
          ? switch (error.failure) {
              LocationPlatformFailure.denied => LocationStatus.denied,
              LocationPlatformFailure.servicesDisabled =>
                LocationStatus.servicesDisabled,
              LocationPlatformFailure.timeout => LocationStatus.timeout,
              LocationPlatformFailure.cancelled => LocationStatus.cancelled,
              LocationPlatformFailure.cityUnavailable =>
                LocationStatus.cityUnavailable,
              LocationPlatformFailure.unavailable => LocationStatus.unavailable,
            }
          : error is TimeoutException
          ? LocationStatus.timeout
          : LocationStatus.unavailable;
      return _fail(status);
    }
  }

  static String? _placeField(String? value) {
    final text = value?.trim();
    if (text == null ||
        text.isEmpty ||
        text.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
      return null;
    }
    return text;
  }

  static String? _countryCodeField(String? value) =>
      value != null && RegExp(r'^[A-Z]{2}$').hasMatch(value) ? value : null;

  bool _valid(int generation, [bool Function()? isCurrent]) =>
      generation == _generation && _canLocate && isCurrent?.call() != false;
  LocationSnapshot _cancelled() => LocationSnapshot(
    !_owns
        ? LocationStatus.retired
        : !enabled.value
        ? LocationStatus.disabled
        : LocationStatus.cancelled,
  );

  LocationSnapshot _stale(int generation) {
    final result = _cancelled();
    if (generation == _generation &&
        _owns &&
        state.value.status == LocationStatus.locating) {
      _cache = null;
      _cachedAt = null;
      state.value = result;
    }
    return result;
  }

  LocationSnapshot _publish(LocationSnapshot value) {
    if (_owns) state.value = value;
    return value;
  }

  LocationSnapshot _fail(LocationStatus status) {
    _cache = null;
    _cachedAt = null;
    if (status == LocationStatus.denied ||
        status == LocationStatus.deniedForever ||
        status == LocationStatus.permissionRequired ||
        status == LocationStatus.servicesDisabled) {
      _generation++;
      _cancelPlatform();
    }
    return _publish(LocationSnapshot(status));
  }

  void _invalidate(LocationStatus status) {
    _generation++;
    _cache = null;
    _cachedAt = null;
    _pending = null;
    if (_active && !isClosed) state.value = LocationSnapshot(status);
    _cancelPlatform();
  }

  void _cancelPlatform() {
    // Finish cancellation before a new request can start, so an old native
    // cancellation never accidentally stops a newly enabled lookup.
    _cancellations = _cancellations
        .then((_) => _platform.cancel())
        .catchError((Object _) {});
  }

  Future<bool> openAppSettings() async {
    if (!_owns || !_foreground || !_isForeground() || !_platform.isSupported) {
      return false;
    }
    try {
      return await _platform.openAppSettings();
    } on Object {
      return false;
    }
  }

  Future<bool> openLocationSettings() async {
    if (!_owns || !_foreground || !_isForeground() || !_platform.isSupported) {
      return false;
    }
    try {
      return await _platform.openLocationSettings();
    } on Object {
      return false;
    }
  }

  Future<void> deactivateAndDrain() async {
    _retired = true;
    _active = false;
    _generation++;
    _settingRevision++;
    _cache = null;
    _cachedAt = null;
    enabled.value = false;
    state.value = const LocationSnapshot(LocationStatus.retired);
    _cancelPlatform();
    await Future.wait<void>(<Future<void>>[_writes, _cancellations]);
  }

  @override
  void onClose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
