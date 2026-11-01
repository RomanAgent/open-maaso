import 'dart:async';
import 'dart:math';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef SecureRandomBytesGenerator = List<int> Function(int length);

abstract interface class AppInstallationIdentityStore {
  Future<String?> read(String key);
  Future<bool> write(String key, String value);
}

class SharedPreferencesInstallationIdentityStore
    implements AppInstallationIdentityStore {
  const SharedPreferencesInstallationIdentityStore(this.preferences);

  final SharedPreferences preferences;

  @override
  Future<String?> read(String key) async => preferences.getString(key);

  @override
  Future<bool> write(String key, String value) =>
      preferences.setString(key, value);
}

class AppInstallationIdentityService extends AppService {
  AppInstallationIdentityService({
    SharedPreferences? sharedPreferences,
    AppInstallationIdentityStore? store,
    SecureRandomBytesGenerator? randomBytes,
  }) : assert(
         sharedPreferences == null || store == null,
         'sharedPreferences and store are mutually exclusive',
       ),
       _sharedPreferences = sharedPreferences,
       _store = store,
       _randomBytes = randomBytes ?? _secureRandomBytes;

  /// This is the key used by PushTokenRegistrationService before installation
  /// identity became an app-wide concern. Keeping it stable migrates existing
  /// installations without coupling the identity to the Push binding journal.
  static const preferencesKey = 'maaso.notification.installation.v1';

  final SecureRandomBytesGenerator _randomBytes;
  SharedPreferences? _sharedPreferences;
  AppInstallationIdentityStore? _store;
  AccountDeviceIdentity? _identity;
  Future<AppInstallationIdentityService>? _initFuture;

  bool get isInitialized => _identity != null;

  AccountDeviceIdentity get identity {
    final value = _identity;
    if (value == null) {
      throw StateError('App installation identity is not initialized');
    }
    return value;
  }

  String get installationId => identity.installationId;
  String get runtimeInstanceId => identity.runtimeInstanceId;

  Future<AppInstallationIdentityService> init() {
    final pending = _initFuture;
    if (pending != null) return pending;
    final completer = Completer<AppInstallationIdentityService>();
    final future = completer.future;
    _initFuture = future;
    unawaited(_initialize(completer, future));
    return future;
  }

  Future<void> _initialize(
    Completer<AppInstallationIdentityService> completer,
    Future<AppInstallationIdentityService> ownedFuture,
  ) async {
    try {
      final store = await _resolveStore();
      final restored = await store.read(preferencesKey);
      final installationId = _validLegacyInstallationId(restored)
          ? restored!
          : _hexId(_randomBytes, 16);
      if (installationId != restored) {
        final persisted = await store.write(preferencesKey, installationId);
        if (!persisted) {
          throw StateError('App installation identity could not be persisted');
        }
      }
      final confirmed = await store.read(preferencesKey);
      if (confirmed != installationId) {
        throw StateError('App installation identity read-back did not match');
      }
      final candidate = AccountDeviceIdentity(
        installationId: installationId,
        runtimeInstanceId: _hexId(_randomBytes, 16),
      );
      _identity = candidate;
      completer.complete(this);
    } catch (error, stackTrace) {
      if (identical(_initFuture, ownedFuture)) _initFuture = null;
      completer.completeError(error, stackTrace);
    }
  }

  Future<AppInstallationIdentityStore> _resolveStore() async {
    final existing = _store;
    if (existing != null) return existing;
    final preferences = _sharedPreferences ??=
        await SharedPreferences.getInstance();
    return _store = SharedPreferencesInstallationIdentityStore(preferences);
  }

  static bool _validLegacyInstallationId(String? value) =>
      value != null && RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  static String _hexId(SecureRandomBytesGenerator randomBytes, int length) {
    final bytes = randomBytes(length);
    if (bytes.length != length ||
        bytes.any((value) => value < 0 || value > 255)) {
      throw StateError('Secure random byte generator returned invalid data');
    }
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _secureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
