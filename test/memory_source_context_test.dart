import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'persisted source binds the exact record, session, and human origin',
    () async {
      final harness = await _MemorySourceHarness.open('exact-source');
      addTearDown(harness.close);
      final userId = await harness.persist(
        _message(
          sessionId: 'self',
          content: '请记住我喜欢青苹果',
          origin: ChatMessageTurnOrigins.user,
        ),
      );
      final assistantId = await harness.persist(
        _message(
          sessionId: 'self',
          content: '请记住这是助手行',
          origin: ChatMessageTurnOrigins.user,
          isUserMessage: false,
        ),
      );
      final systemId = await harness.persist(
        _message(
          sessionId: 'self',
          content: '请记住这是系统行',
          origin: ChatMessageTurnOrigins.system,
        ),
      );
      final voiceId = await harness.persist(
        _message(
          sessionId: 'voice-self',
          content: '请记住我喜欢蓝莓',
          origin: ChatMessageTurnOrigins.voice,
        ),
      );

      final accepted = await harness.runWithSource(
        recordId: userId,
        sessionId: 'self',
        operation: () => harness.writeVerified(_draft('green-apple-memory')),
      );
      final wrongSession = await harness.runWithSource(
        recordId: userId,
        sessionId: 'another-session',
        operation: () => harness.writeVerified(_draft('wrong-session')),
      );
      final assistant = await harness.runWithSource(
        recordId: assistantId,
        sessionId: 'self',
        operation: () => harness.writeVerified(_draft('assistant-row')),
      );
      final system = await harness.runWithSource(
        recordId: systemId,
        sessionId: 'self',
        operation: () => harness.writeVerified(_draft('system-row')),
      );
      final voice = await harness.runWithSource(
        recordId: voiceId,
        sessionId: 'voice-self',
        operation: () => harness.writeVerified(_draft('voice-blueberry')),
      );

      expect(accepted.disposition, MemoryWriteDisposition.accepted);
      expect(accepted.episode?.sourceRefs, hasLength(1));
      expect(
        accepted.episode!.sourceRefs.single.sourceId,
        'chat_message:$userId',
      );
      expect(accepted.episode!.sourceRefs.single.sessionId, 'self');
      expect(
        accepted.episode!.sourceRefs.single.origin,
        EpisodeSourceOrigin.user,
      );
      expect(
        accepted.episode!.sourceRefs.single.contentHash,
        sha256.convert(utf8.encode('请记住我喜欢青苹果')).toString(),
      );
      for (final rejected in <MemoryWriteResult>[
        wrongSession,
        assistant,
        system,
      ]) {
        expect(rejected.disposition, MemoryWriteDisposition.rejected);
        expect(rejected.episode, isNull);
        expect(rejected.reason, 'trusted_source_missing_or_invalid');
      }
      expect(voice.disposition, MemoryWriteDisposition.accepted);
      expect(
        voice.episode!.sourceRefs.single.sourceId,
        'chat_message:$voiceId',
      );
      expect(voice.episode!.sourceRefs.single.sessionId, 'voice-self');
    },
  );

  test(
    'a persisted source capability cannot cross account coordinators',
    () async {
      final accountA = await _MemorySourceHarness.open(
        'account-a',
        accountDigest: _accountADigest,
      );
      final accountB = await _MemorySourceHarness.open(
        'account-b',
        accountDigest: _accountBDigest,
      );
      addTearDown(accountB.close);
      addTearDown(accountA.close);
      final recordA = await accountA.persist(
        _message(
          sessionId: 'self',
          content: '请记住这只属于 A',
          origin: ChatMessageTurnOrigins.user,
        ),
      );
      await accountB.persist(
        _message(
          sessionId: 'self',
          content: '请记住这只属于 B',
          origin: ChatMessageTurnOrigins.user,
        ),
      );

      late MemoryWriteResult accountAResult;
      late MemoryWriteResult accountBResult;
      await accountA.runWithSource(
        recordId: recordA,
        sessionId: 'self',
        operation: () async {
          accountBResult = await accountB.writeVerified(
            _draft('must-not-cross-account'),
          );
          accountAResult = await accountA.writeVerified(_draft('belongs-to-a'));
        },
      );

      expect(accountBResult.disposition, MemoryWriteDisposition.rejected);
      expect(accountBResult.episode, isNull);
      expect(accountAResult.disposition, MemoryWriteDisposition.accepted);
      expect(
        accountAResult.episode!.sourceRefs.single.sourceId,
        'chat_message:$recordA',
      );
    },
  );

  test(
    'source scope expires on return and in a late unawaited continuation',
    () async {
      final harness = await _MemorySourceHarness.open('expired-source');
      addTearDown(harness.close);
      final recordId = await harness.persist(
        _message(
          sessionId: 'self',
          content: '请记住这个临时能力',
          origin: ChatMessageTurnOrigins.user,
        ),
      );
      final releaseLateContinuation = Completer<void>();
      late Future<MemoryWriteResult> lateWrite;

      final inScope = await harness.runWithSource(
        recordId: recordId,
        sessionId: 'self',
        operation: () async {
          lateWrite = releaseLateContinuation.future.then(
            (_) => harness.writeVerified(_draft('late-unawaited-write')),
          );
          return harness.writeVerified(_draft('in-scope-write'));
        },
      );
      final afterScope = await harness.writeVerified(
        _draft('after-scope-write'),
      );
      releaseLateContinuation.complete();
      final lateResult = await lateWrite;

      expect(inScope.disposition, MemoryWriteDisposition.accepted);
      for (final rejected in <MemoryWriteResult>[afterScope, lateResult]) {
        expect(rejected.disposition, MemoryWriteDisposition.rejected);
        expect(rejected.episode, isNull);
      }
    },
  );

  test(
    'sequential and nested source scopes do not leak into each other',
    () async {
      final harness = await _MemorySourceHarness.open('ordered-sources');
      addTearDown(harness.close);
      final firstId = await harness.persist(
        _message(
          sessionId: 'first',
          content: '请记住第一个来源',
          origin: ChatMessageTurnOrigins.user,
        ),
      );
      final secondId = await harness.persist(
        _message(
          sessionId: 'second',
          content: '请记住第二个来源',
          origin: ChatMessageTurnOrigins.user,
        ),
      );

      final sequentialFirst = await harness.runWithSource(
        recordId: firstId,
        sessionId: 'first',
        operation: () => harness.writeVerified(_draft('sequential-first')),
      );
      final sequentialSecond = await harness.runWithSource(
        recordId: secondId,
        sessionId: 'second',
        operation: () => harness.writeVerified(_draft('sequential-second')),
      );
      late MemoryWriteResult nestedInner;
      late MemoryWriteResult outerAfterInner;
      final nestedOuter = await harness.runWithSource(
        recordId: firstId,
        sessionId: 'first',
        operation: () async {
          nestedInner = await harness.runWithSource(
            recordId: secondId,
            sessionId: 'second',
            operation: () => harness.writeVerified(_draft('nested-inner')),
          );
          outerAfterInner = await harness.writeVerified(
            _draft('outer-after-inner'),
          );
          return harness.writeVerified(_draft('nested-outer'));
        },
      );

      expect(_sourceId(sequentialFirst), 'chat_message:$firstId');
      expect(_sourceId(sequentialSecond), 'chat_message:$secondId');
      expect(_sourceId(nestedInner), 'chat_message:$secondId');
      expect(_sourceId(outerAfterInner), 'chat_message:$firstId');
      expect(_sourceId(nestedOuter), 'chat_message:$firstId');
    },
  );

  test(
    'human text and voice entry points bind persisted source around chat',
    () {
      final home = File(
        'lib/src/features/home/application/home_controller.dart',
      ).readAsStringSync();
      final u2a = File(
        'lib/src/features/chat/application/u2a_chat_controller.dart',
      ).readAsStringSync();
      final voice = File(
        'lib/src/features/agent/application/companion/'
        'companion_voice_session_controller.dart',
      ).readAsStringSync();

      _expectPersistedSourceWrap(
        _blockMethod(home, 'Future<void> _sendTracedActive('),
        saveExpression: '_db.saveChatMessage(userMsg)',
        sessionExpression: 'sessionId: userMsg.sessionId',
      );
      _expectPersistedSourceWrap(
        _blockMethod(u2a, 'Future<void> _sendMessageActive('),
        saveExpression: '_db.saveChatMessage(userMsg)',
        sessionExpression: 'sessionId: userMsg.sessionId',
      );
      final voiceTurn = _blockMethod(
        voice,
        'Future<void> _runVoiceMessageTurn({',
      );
      _expectPersistedSourceWrap(
        voiceTurn,
        saveExpression: '_database.saveChatMessage(userMessage)',
        sessionExpression: 'sessionId: userMessage.sessionId',
        agentExpression: 'agentId: _agentId',
        runtimeExpression: 'runtime.runGuardedVoiceChat(',
      );
      expect(voiceTurn, contains('origin: TurnOrigin.voice'));
      expect(voiceTurn, contains('isCurrent:'));
      expect(voiceTurn, contains('onRevoked:'));
    },
  );

  test(
    'enforce mode without a write coordinator fails closed for every bus entry',
    () async {
      final database = await databaseFactoryMemory.openDatabase(
        'missing-writer-${_databaseSequence++}.db',
      );
      final store = EpisodeStore(
        database: database,
        accountScopeDigest: _accountADigest,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      appServices.put<EpisodeStore>(store);
      final bus = MemoryBus(memoryV2Mode: () => FeatureRolloutMode.enforce);
      addTearDown(() async {
        await store.deactivateAndDrain();
        await database.close();
      });
      final directEpisode = Episode(
        when: DateTime.utc(2026, 8, 29, 12),
        what: 'must not bypass governance',
      );
      final importedEpisode = Episode(
        when: DateTime.utc(2026, 8, 29, 12),
        what: 'import must not bypass governance',
      );

      final direct = await bus.writeEpisodeWithResult(directEpisode);
      final imported = await bus.writeImportedEpisode(
        importedEpisode,
        sourceKind: 'test',
        sourceKey: 'missing-writer-import',
        canonicalMaterial: 'missing-writer-import-material',
      );

      for (final result in <MemoryWriteResult>[direct, imported]) {
        expect(result.disposition, MemoryWriteDisposition.rejected);
        expect(result.reason, 'memory_write_coordinator_unavailable');
        expect(result.episode, isNull);
        expect(result.created, isFalse);
        expect(result.projected, isFalse);
      }
      await expectLater(
        bus.writeEpisode(
          Episode(
            when: DateTime.utc(2026, 8, 29, 12),
            what: 'throwing facade must also fail closed',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await MemoryGovernanceStores.episodes.count(database), 0);
      expect(await MemoryGovernanceStores.episodeGovernance.count(database), 0);
    },
  );
}

const String _accountADigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _accountBDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final StoreRef<int, Map<String, Object?>> _chatMessages = intMapStoreFactory
    .store('chat_messages');
var _databaseSequence = 0;

final class _MemorySourceHarness {
  _MemorySourceHarness._({
    required this.database,
    required this.store,
    required this.writer,
  });

  final Database database;
  final EpisodeStore store;
  final MemoryWriteCoordinator writer;

  static Future<_MemorySourceHarness> open(
    String label, {
    String accountDigest = _accountADigest,
  }) async {
    final database = await databaseFactoryMemory.openDatabase(
      '$label-${_databaseSequence++}.db',
    );
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: accountDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
    );
    final writer = MemoryWriteCoordinator(
      database: database,
      episodeStore: store,
      accountScopeDigest: accountDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      linkEpisode: (_) async {},
      projectMilestone: (_) async {},
    );
    return _MemorySourceHarness._(
      database: database,
      store: store,
      writer: writer,
    );
  }

  Future<int> persist(ChatMessage message) =>
      _chatMessages.add(database, message.toJson());

  Future<MemoryWriteResult> writeVerified(MemoryWriteDraft draft) =>
      writer.write(draft, authority: MemoryWriteAuthority.verifiedHost);

  Future<T> runWithSource<T>({
    required int recordId,
    required String sessionId,
    required Future<T> Function() operation,
  }) => writer.runWithPersistedChatSource(
    messageRecordId: recordId,
    sessionId: sessionId,
    agentId: 'self',
    operation: operation,
  );

  Future<void> close() async {
    await writer.deactivateAndDrain();
    await store.deactivateAndDrain();
    await database.close();
  }
}

ChatMessage _message({
  required String sessionId,
  required String content,
  required String origin,
  bool isUserMessage = true,
}) => ChatMessage(
  sessionId: sessionId,
  senderId: isUserMessage ? 'user' : 'self',
  receiverId: isUserMessage ? 'self' : 'user',
  content: content,
  timestamp: DateTime.utc(2026, 8, 29, 12),
  isUserMessage: isUserMessage,
  turnOrigin: origin,
);

MemoryWriteDraft _draft(String what) =>
    MemoryWriteDraft.event(what: what, when: DateTime.utc(2026, 8, 29, 12));

String _sourceId(MemoryWriteResult result) {
  expect(result.disposition, MemoryWriteDisposition.accepted);
  return result.episode!.sourceRefs.single.sourceId;
}

void _expectPersistedSourceWrap(
  String method, {
  required String saveExpression,
  required String sessionExpression,
  String agentExpression = "agentId: 'self'",
  String runtimeExpression = 'runtime.chat(',
}) {
  final save = method.indexOf(saveExpression);
  expect(save, greaterThanOrEqualTo(0));
  final runChat =
      RegExp(
        r'Future\s*<\s*ExecutionResult\s*>\s+runChat\s*\(\s*\)',
      ).firstMatch(method)?.start ??
      -1;
  expect(runChat, greaterThan(save));
  final runtimeChat = method.indexOf(runtimeExpression, runChat);
  expect(runtimeChat, greaterThan(runChat));
  final wrapper = method.indexOf('runWithPersistedChatSource(', runtimeChat);
  expect(wrapper, greaterThan(runtimeChat));
  expect(method, contains('messageRecordId: messageRecordId'));
  expect(method, contains(sessionExpression));
  expect(method, contains(agentExpression));
  expect(method.substring(wrapper), contains('operation: runChat'));
}

String _blockMethod(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  final asyncMarker = source.indexOf('async {', start);
  expect(asyncMarker, greaterThanOrEqualTo(0), reason: 'missing method body');
  final openingBrace = asyncMarker + 'async '.length;
  var depth = 0;
  for (var index = openingBrace; index < source.length; index++) {
    final codeUnit = source.codeUnitAt(index);
    if (codeUnit == 0x7b) depth += 1;
    if (codeUnit == 0x7d) depth -= 1;
    if (depth == 0) return source.substring(start, index + 1);
  }
  throw StateError('unterminated method body: $signature');
}
