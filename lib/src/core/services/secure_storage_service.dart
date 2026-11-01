import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

final Object _strictSecureStorageReadZoneKey = Object();

class SecureStorageService extends AppService {
  final _storage = const FlutterSecureStorage();

  Future<bool> write(String key, String? value) async {
    try {
      await _storage.write(key: key, value: value);
      return true;
    } catch (e) {
      debugPrint('SecureStorageService.write($key) failed: $e');
      return false;
    }
  }

  Future<String?> read(String key) async {
    try {
      return await readPlatformValue(key);
    } catch (error, stackTrace) {
      debugPrint('SecureStorageService.read($key) failed: $error');
      if (Zone.current[_strictSecureStorageReadZoneKey] == true) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      return null;
    }
  }

  /// Reads a value while preserving the distinction between a missing key and
  /// a platform read failure.
  ///
  /// Credential transactions must use this API. The regular [read] contract
  /// remains best effort for non-security-critical preferences.
  Future<String?> readStrict(String key) {
    return runZoned(
      () => read(key),
      zoneValues: <Object, Object>{_strictSecureStorageReadZoneKey: true},
    );
  }

  /// Platform seam used by production-parity fault-injection tests.
  @protected
  Future<String?> readPlatformValue(String key) => _storage.read(key: key);

  Future<bool> writeBool(String key, bool value) {
    return write(key, value ? 'true' : 'false');
  }

  Future<bool?> readBool(String key) async {
    final value = await read(key);
    if (value == null) return null;
    return value == 'true';
  }

  Future<bool> delete(String key) async {
    try {
      await _storage.delete(key: key);
      return true;
    } catch (e) {
      debugPrint('SecureStorageService.delete($key) failed: $e');
      return false;
    }
  }
}
