import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

class AgentTokenService extends AppService {
  final agentToken = ''.obs;
  static const _storageKey = 'agent_token';
  String? _activeStorageKey;

  Future<AgentTokenService> init({AccountStorageScope? scope}) async {
    final storage = appServices.find<SecureStorageService>();
    final storageKey = scope == null
        ? (_activeStorageKey ?? _storageKey)
        : '${scope.storageNamespace}.secure.$_storageKey';
    if (_activeStorageKey == storageKey && agentToken.value.isNotEmpty) {
      return this;
    }
    _activeStorageKey = storageKey;
    final existing = await storage.read(storageKey);
    if (existing != null && existing.isNotEmpty) {
      agentToken.value = existing;
    } else {
      agentToken.value = await _generate();
      await storage.write(storageKey, agentToken.value);
    }
    return this;
  }

  Future<String> _generate() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final nonce = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final input = '$timestamp${base64Encode(nonce)}';
    final hash = _simpleHash(input);
    return 'MAASO-$timestamp-$hash';
  }

  String _simpleHash(String input) {
    final bytes = Uint8List.fromList(utf8.encode(input));
    const int prime1 = 0x01000193;
    const int prime2 = 0x811C9DC5;
    int h1 = 0x6A09E667;
    int h2 = 0xBB67AE85;
    int h3 = 0x3C6EF372;
    int h4 = 0xA54FF53A;
    for (final b in bytes) {
      h1 = (h1 ^ b) * prime1;
      h2 = (h2 ^ b) * prime2;
      h3 = (h3 ^ ((b << 3) & 0xFFFFFFFF)) * prime1;
      h4 = (h4 ^ ((b >> 1) & 0xFF)) * prime2;
      h1 &= 0xFFFFFFFF;
      h2 &= 0xFFFFFFFF;
      h3 &= 0xFFFFFFFF;
      h4 &= 0xFFFFFFFF;
    }
    final out = Uint8List(16);
    out.buffer.asByteData().setUint32(0, h1, Endian.little);
    out.buffer.asByteData().setUint32(4, h2, Endian.little);
    out.buffer.asByteData().setUint32(8, h3, Endian.little);
    out.buffer.asByteData().setUint32(12, h4, Endian.little);
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
