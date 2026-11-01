import 'dart:convert';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import '../domain/deletion_models.dart';

abstract interface class DeletionReceiptStore {
  Future<Map<String, Object?>?> read();
  Future<void> write(Map<String, Object?> receipt);
}

/// A narrow receipt survives account-scoped database erasure. It contains no
/// password, authorization proof, email, chat or public identity.
final class SecureDeletionReceiptStore implements DeletionReceiptStore {
  SecureDeletionReceiptStore(this.storage);
  final SecureStorageService storage;
  static const key = 'maaso.account.deletion.receipt.v1';
  @override
  Future<Map<String, Object?>?> read() async {
    final value = await storage.readStrict(key);
    if (value == null) return null;
    return deletionObject(jsonDecode(value));
  }

  @override
  Future<void> write(Map<String, Object?> receipt) async {
    if (!await storage.write(key, jsonEncode(receipt))) {
      throw const DeletionException('receipt_storage_failed');
    }
  }
}
