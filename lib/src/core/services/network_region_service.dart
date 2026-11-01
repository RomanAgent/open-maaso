import 'dart:async';
import 'dart:ui';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Applies only to public internet tools, never model, voice or backend APIs.
enum NetworkRegion { mainlandChina, overseas }

enum NetworkRegionSource { authorizedLocation, deviceLocale, defaultRegion }

/// A request can pin this coarse decision without storing or sharing location.
final class NetworkRegionResolution {
  const NetworkRegionResolution({required this.region, required this.source});

  final NetworkRegion region;
  final NetworkRegionSource source;

  Map<String, String> toJson() => <String, String>{
    'region': region == NetworkRegion.mainlandChina
        ? 'china_mainland'
        : 'overseas',
    'source': switch (source) {
      NetworkRegionSource.authorizedLocation => 'authorized_location',
      NetworkRegionSource.deviceLocale => 'device_locale',
      NetworkRegionSource.defaultRegion => 'default',
    },
  };
}

/// An account-owned, automatic public internet region resolver.
///
/// The location supplier may read only an existing, authorized coarse cache.
/// Initializing or resolving this service never requests GPS, permission,
/// network probes, or language-based routing. No user-selected region is read
/// or saved; initialization only removes the retired account preference.
class NetworkRegionService extends AppService {
  NetworkRegionService({
    String? Function()? countryCodeSupplier,
    String? Function()? deviceCountryCodeSupplier,
    Future<SharedPreferences> Function()? preferencesLoader,
    bool Function()? isOwnerCurrent,
  }) : _countryCodeSupplier = countryCodeSupplier ?? (() => null),
       _deviceCountryCodeSupplier =
           deviceCountryCodeSupplier ??
           (() => PlatformDispatcher.instance.locale.countryCode),
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _isOwnerCurrent = isOwnerCurrent ?? (() => true);

  final String? Function() _countryCodeSupplier;
  final String? Function() _deviceCountryCodeSupplier;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final bool Function() _isOwnerCurrent;
  String? _storageKey;
  bool _active = false;
  bool _retired = false;
  Future<void>? _cleanup;

  static const fallback = NetworkRegionResolution(
    region: NetworkRegion.overseas,
    source: NetworkRegionSource.defaultRegion,
  );

  bool get isAvailable {
    return _active && !_retired && !isClosed && _ownerIsCurrent();
  }

  Future<NetworkRegionService> init({
    required AccountStorageScope scope,
  }) async {
    if (_storageKey != null || _retired || isClosed) {
      throw StateError('network_region_already_initialized');
    }
    _storageKey =
        '${scope.storageNamespace}.preferences.network_region.choice.v1';
    await (_cleanup = _removeRetiredChoice(_storageKey!));
    if (!_retired && !isClosed && _ownerIsCurrent()) _active = true;
    return this;
  }

  Future<void> _removeRetiredChoice(String key) async {
    try {
      final preferences = await _preferencesLoader();
      if (_retired || isClosed || !_ownerIsCurrent()) return;
      await preferences.remove(key);
    } on Object {
      // Automatic routing is independent of preference storage. Even if
      // cleanup fails, the retired value is never consulted.
    }
  }

  NetworkRegionResolution resolve() {
    if (!isAvailable) return fallback;
    final authorized = _readCountryCode(_countryCodeSupplier);
    if (!isAvailable) return fallback;
    if (authorized != null) {
      return _resolution(authorized, NetworkRegionSource.authorizedLocation);
    }
    final device = _readCountryCode(_deviceCountryCodeSupplier);
    if (!isAvailable) return fallback;
    return device == null
        ? fallback
        : _resolution(device, NetworkRegionSource.deviceLocale);
  }

  Future<void> deactivateAndDrain() async {
    _retired = true;
    _active = false;
    await _cleanup;
  }

  bool _ownerIsCurrent() {
    try {
      return _isOwnerCurrent();
    } on Object {
      return false;
    }
  }

  static String? _readCountryCode(String? Function() supplier) {
    try {
      final value = supplier();
      return value != null && RegExp(r'^[A-Z]{2}$').hasMatch(value)
          ? value
          : null;
    } on Object {
      return null;
    }
  }

  static NetworkRegionResolution _resolution(
    String countryCode,
    NetworkRegionSource source,
  ) => NetworkRegionResolution(
    region: countryCode == 'CN'
        ? NetworkRegion.mainlandChina
        : NetworkRegion.overseas,
    source: source,
  );

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
