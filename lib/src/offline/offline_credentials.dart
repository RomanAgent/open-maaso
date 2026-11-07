import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'offline_model_client.dart';

/// API keys never enter the local document database, backups or logs.
class OfflineCredentials {
  OfflineCredentials({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  static const keyPrefix = 'open_maaso_offline_api_key_v1.';
  final FlutterSecureStorage _storage;
  Future<void> _tail = Future<void>.value();

  static String _key(String providerId) {
    OfflineModelProvider.fromId(providerId);
    return '$keyPrefix$providerId';
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<String?> read(String providerId) {
    final key = _key(providerId);
    return _serial(() async {
      try {
        return await _storage.read(key: key);
      } catch (_) {
        throw const OfflineCredentialException('read_failed');
      }
    });
  }

  Future<void> write(String providerId, String value) {
    final key = _key(providerId);
    final credential = value.trim();
    if (credential.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(credential)) {
      return Future.error(const OfflineCredentialException('invalid_key'));
    }
    return _serial(() async {
      try {
        if (credential.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: credential);
        }
      } catch (_) {
        throw const OfflineCredentialException('write_failed');
      }
    });
  }

  Future<void> delete(String providerId) => write(providerId, '');

  /// Deletes only this edition's provider slots, without reading other values.
  Future<void> clear() => _serial(() async {
    try {
      for (final provider in OfflineModelProvider.presets) {
        await _storage.delete(key: _key(provider.id));
      }
    } catch (_) {
      throw const OfflineCredentialException('delete_failed');
    }
  });
}

class OfflineCredentialException implements Exception {
  const OfflineCredentialException(this.code);
  final String code;
  @override
  String toString() =>
      code == 'invalid_key' ? 'API Key 格式无效。' : '无法访问设备安全存储，请检查设备解锁状态后重试。';
}
