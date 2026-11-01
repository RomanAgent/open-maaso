import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_ledger_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const account =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  test(
    'ledger exposes published assistant evidence and fails closed after edits',
    () async {
      final database = await databaseFactoryMemory.openDatabase(
        'evidence-transcript',
      );
      final writer = MemoryWriteCoordinator(
        database: database,
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      final ledger = MemoryLedgerService(
        database: database,
        coordinator: writer,
        accountScopeDigest: account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      addTearDown(() async {
        await ledger.deactivateAndDrain();
        await writer.deactivateAndDrain();
        await database.close();
      });
      final message = ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: '上次你说周末要练吉他。',
        timestamp: DateTime.now(),
        turnOrigin: 'user',
        deliveryStatus: 'published',
      );
      final id = await MemoryGovernanceStores.chatMessages.add(
        database,
        message.toJson(),
      );
      final source = EpisodeSourceRef(
        sourceId: 'chat_message:$id',
        sessionId: 'self',
        origin: EpisodeSourceOrigin.agent,
        contentHash: sha256.convert(utf8.encode(message.content)).toString(),
      );
      final verified = await ledger.sourceTranscript(source);
      expect(verified.status, MemorySourceTranscriptStatus.verified);
      expect(verified.content, message.content);

      for (final patch in <Map<String, Object?>>[
        {'deliveryStatus': 'draft'},
        {'deliveryStatus': 'interrupted'},
        {'turnOrigin': 'system'},
        {'turnOrigin': 'proactivePresence'},
        {'turnOrigin': null},
        {'isUserMessage': true},
        {'receiverId': 'someone-else'},
        {'sessionId': 'other-session'},
        {'content': '被修改过的文本'},
      ]) {
        await MemoryGovernanceStores.chatMessages.record(id).put(database, {
          ...message.toJson(),
          ...patch,
        });
        final result = await ledger.sourceTranscript(source);
        expect(
          result.status,
          MemorySourceTranscriptStatus.integrityFailure,
          reason: '$patch',
        );
        expect(result.content, isNull);
      }
      await MemoryGovernanceStores.chatMessages.record(id).delete(database);
      expect(
        (await ledger.sourceTranscript(source)).status,
        MemorySourceTranscriptStatus.integrityFailure,
      );
    },
  );
}
