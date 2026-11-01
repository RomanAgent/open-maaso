import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/governed_memory_projection.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async => appServices.reset());
  tearDown(() async => appServices.reset());

  test(
    'direct persisted preference is pending, accepted, deleted and restored',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.message('以后叫我阿岚');
      expect(await h.observe(id), 'chat_message:$id');
      final pending = (await h.episodes()).single;
      expect(pending.reviewState, EpisodeReviewState.pending);
      expect(h.memory.state.value.preferredAddress, isNull);
      final accepted = await h.review(pending, MemoryGovernanceAction.accept);
      expect(accepted.status, MemoryGovernanceStatus.applied);
      expect(h.memory.state.value.preferredAddress, '阿岚');
      expect(accepted.episode!.sourceRefs.single.sourceId, 'chat_message:$id');
      final version = h.memory.policyVersion;
      await h.memory.refresh();
      await h.memory.refresh();
      expect(h.memory.policyVersion, version);
      final deleted = await h.review(
        accepted.episode!,
        MemoryGovernanceAction.delete,
      );
      expect(h.memory.state.value.preferredAddress, isNull);
      final restored = await h.review(
        deleted.episode!,
        MemoryGovernanceAction.restore,
      );
      expect(restored.status, MemoryGovernanceStatus.applied);
      expect(h.memory.state.value.preferredAddress, '阿岚');
    },
  );

  test(
    'independent slots survive another source deletion, accept fails closed',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final nameId = await h.message('以后叫我阿岚');
      await h.observe(nameId);
      final name = (await h.episodes()).last;
      final acceptedName = (await h.review(
        name,
        MemoryGovernanceAction.accept,
      )).episode!;
      final banId = await h.message('别叫我宝');
      await h.observe(banId);
      final ban = (await h.episodes()).last;
      await h.review(ban, MemoryGovernanceAction.accept);
      expect(h.memory.state.value.forbiddenAddresses, contains('宝'));
      final version = h.memory.policyVersion;
      await MemoryGovernanceStores.chatMessages
          .record(nameId)
          .delete(h.database);
      await h.memory.refresh();
      expect(h.memory.state.value.preferredAddress, isNull);
      expect(h.memory.state.value.forbiddenAddresses, contains('宝'));
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$nameId'));
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$nameId'));
      expect(h.memory.policyVersion, greaterThan(version));
      final deleted = await h.review(
        acceptedName,
        MemoryGovernanceAction.delete,
      );
      expect(deleted.status, MemoryGovernanceStatus.applied);
      expect(
        (await h.review(
          deleted.episode!,
          MemoryGovernanceAction.restore,
        )).status,
        MemoryGovernanceStatus.invalid,
      );
      final newId = await h.message('以后叫我小林');
      await h.observe(newId);
      final pending = (await h.episodes()).last;
      await MemoryGovernanceStores.chatMessages
          .record(newId)
          .delete(h.database);
      expect(
        (await h.review(pending, MemoryGovernanceAction.accept)).status,
        MemoryGovernanceStatus.invalid,
      );
    },
  );

  test('new pending value preserves an existing accepted slot', () async {
    final h = await _Harness.open();
    addTearDown(h.close);
    await h.observe(await h.message('以后叫我阿岚'));
    await h.review((await h.episodes()).last, MemoryGovernanceAction.accept);
    await h.observe(await h.message('以后叫我小林'));
    expect(h.memory.state.value.preferredAddress, '阿岚');
    await h.memory.refresh();
    expect(h.memory.state.value.preferredAddress, '阿岚');
    await h.review((await h.episodes()).last, MemoryGovernanceAction.accept);
    expect(h.memory.state.value.preferredAddress, '小林');
  });

  test(
    'fact deletion invalidates only its slot lease when source is shared',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.message('以后叫我阿岚，别叫我宝');
      final first = await h.submit(
        id,
        ConversationFactDraft.preferredAddress('阿岚'),
      );
      final accepted = (await h.review(
        first.episode!,
        MemoryGovernanceAction.accept,
      )).episode!;
      final second = await h.submit(
        id,
        ConversationFactDraft.forbiddenAddress('宝'),
      );
      await h.review(second.episode!, MemoryGovernanceAction.accept);
      await h.review(accepted, MemoryGovernanceAction.delete);
      expect(h.memory.invalidatedFactSources, {
        'address.preferred': {'chat_message:$id'},
      });
      expect(h.memory.invalidatedSourceIds, isEmpty);
      expect(h.memory.state.value.forbiddenAddresses, ['宝']);
      expect(
        () => h.memory.invalidatedFactSources['address.preferred']!.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'watch capacity never drops accepted facts and unwatched deletion is checked',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      int? oldest;
      for (
        var index = 0;
        index < ConversationMemoryService.maxWatchedSources + 2;
        index++
      ) {
        final id = await h.message('别叫我 alias$index');
        oldest ??= id;
        final result = await h.submit(
          id,
          ConversationFactDraft.forbiddenAddress('alias$index'),
        );
        await h.review(result.episode!, MemoryGovernanceAction.accept);
      }
      final expected = ConversationMemoryService.maxWatchedSources + 2;
      expect(h.memory.facts, hasLength(expected));
      expect(h.memory.invalidatedSourceIds, isEmpty);
      final version = h.memory.policyVersion;
      await h.memory.refresh();
      expect(h.memory.facts, hasLength(expected));
      expect(h.memory.policyVersion, version);
      expect(h.memory.invalidatedSourceIds, isEmpty);
      await MemoryGovernanceStores.chatMessages
          .record(oldest!)
          .delete(h.database);
      await h.memory.refresh();
      expect(h.memory.facts, hasLength(expected - 1));
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$oldest'));
    },
  );

  test('new account mount rehydrates independent accepted heads', () async {
    final h = await _Harness.open();
    addTearDown(h.close);
    await h.observe(await h.message('以后叫我阿岚'));
    await h.review((await h.episodes()).last, MemoryGovernanceAction.accept);
    await h.memory.deactivateAndDrain();
    await h.writer.deactivateAndDrain();
    final fresh = ConversationMemoryService(
      database: h.database,
      accountScopeDigest: h.account,
      agentId: 'agent-a',
    );
    final writer = MemoryWriteCoordinator(
      database: h.database,
      episodeStore: h.store,
      accountScopeDigest: h.account,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      governedProjectionFamilies: [fresh],
    );
    fresh.bindGovernance(writer);
    addTearDown(() async {
      await fresh.deactivateAndDrain();
      await writer.deactivateAndDrain();
    });
    await fresh.refresh();
    expect(fresh.state.value.preferredAddress, '阿岚');
    final version = fresh.policyVersion;
    await fresh.refresh();
    expect(fresh.policyVersion, version);
  });

  test(
    'no zone and temporary requests never create facts but leases track deletion',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      expect(await h.memory.observeCurrentTurn(), isNull);
      final id = await h.message('今天别开玩笑');
      expect(await h.observe(id), 'chat_message:$id');
      expect(await h.episodes(), isEmpty);
      await MemoryGovernanceStores.chatMessages.record(id).delete(h.database);
      await h.memory.refresh();
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$id'));
      await h.observe(await h.message('别记住，以后叫我阿岚'));
      expect(await h.episodes(), isEmpty);
    },
  );

  for (final mode in [FeatureRolloutMode.off, FeatureRolloutMode.shadow]) {
    test('$mode never persists a preference or reads accepted facts', () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.observe(await h.message('以后叫我阿岚'));
      await h.review((await h.episodes()).last, MemoryGovernanceAction.accept);
      h.mode = mode;
      await h.memory.refresh();
      expect(h.memory.facts, isEmpty);
      final count = (await h.episodes()).length;
      await h.observe(await h.message('以后叫我小林'));
      expect((await h.episodes()).length, count);
      h.mode = FeatureRolloutMode.enforce;
      await h.memory.refresh();
      expect(h.memory.state.value.preferredAddress, '阿岚');
    });
  }

  test(
    'supporting delivered assistant and human refs remain source bound',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final previous = await h.message('我们讨论猫咪项目');
      final reply = await h.message('猫咪项目的第一步是列清单', user: false);
      final current = await h.message('你记对了，“猫咪项目”，我们今天继续做第一步');
      await h.observe(current);
      final pending = (await h.episodes()).single;
      expect(pending.sourceRefs.first.sourceId, 'chat_message:$current');
      expect(
        pending.sourceRefs.map((ref) => ref.sourceId),
        containsAll(['chat_message:$previous', 'chat_message:$reply']),
      );
      await h.review(pending, MemoryGovernanceAction.accept);
      expect(h.memory.state.value.sharedContexts, hasLength(1));
      await MemoryGovernanceStores.chatMessages.record(reply).update(
        h.database,
        {'deliveryStatus': 'cancelled'},
      );
      await h.memory.refresh();
      expect(h.memory.state.value.sharedContexts, isEmpty);
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$reply'));
    },
  );

  test(
    'forged draft, unknown and system assistant evidence cannot be proposed',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      for (final fields in [
        {'deliveryStatus': 'draft'},
        {'turnOrigin': null},
        {'turnOrigin': 'system'},
        {'receiverId': 'someone-else'},
      ]) {
        final reply = await h.message('猫咪项目继续', user: false, fields: fields);
        final current = await h.message('记住猫咪项目');
        final result = await h.submit(
          current,
          ConversationFactDraft.sharedContext(
            contextKey: 'cat_project',
            label: '猫咪项目',
            evidenceKind: ConversationEvidenceKind.confirmedContinuation,
          ),
          supporting: [await h.ref(reply)],
        );
        expect(result.disposition, MemoryWriteDisposition.rejected);
        expect(result.reason, 'conversation_projection_source_invalid');
      }
      expect(await h.episodes(), isEmpty);
    },
  );

  test(
    'family rejects verifiedHost bypass and another agent payload',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.message('以后叫我阿岚');
      final bypass = await h.submit(
        id,
        ConversationFactDraft.preferredAddress('阿岚'),
        authority: MemoryWriteAuthority.verifiedHost,
      );
      expect(bypass.disposition, MemoryWriteDisposition.rejected);
      expect(
        bypass.reason,
        'conversation_projection_requires_governed_proposal',
      );
      final foreign = await h.submit(
        id,
        ConversationFactDraft.preferredAddress('阿岚'),
        payloadAgent: 'other',
      );
      expect(foreign.disposition, MemoryWriteDisposition.rejected);
      expect(await h.episodes(), isEmpty);
    },
  );

  test(
    'changed source content clears accepted fact and prevents rehydration',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.message('以后叫我阿岚');
      await h.observe(id);
      final accepted = (await h.review(
        (await h.episodes()).last,
        MemoryGovernanceAction.accept,
      )).episode!;
      await MemoryGovernanceStores.chatMessages.record(id).update(h.database, {
        'content': '普通消息',
      });
      await h.memory.refresh();
      expect(h.memory.facts, isEmpty);
      await MemoryGovernanceStores.chatMessages.record(id).update(h.database, {
        'content': '以后叫我阿岚',
      });
      await h.writer.rehydrateGovernedProjections();
      expect(h.memory.facts, isEmpty);
      final governance = await MemoryGovernanceStores.episodeGovernance
          .record(accepted.id!)
          .get(h.database);
      expect(governance?['projectionSourceInvalidated'], isTrue);
    },
  );

  test(
    'account service instances and source capabilities remain isolated',
    () async {
      final first = await _Harness.open();
      final second = await _Harness.open(account: 'b' * 64);
      addTearDown(first.close);
      addTearDown(second.close);
      final id = await first.message('以后叫我阿岚');
      await first.inSource(id, () async {
        expect(await second.memory.observeCurrentTurn(), isNull);
      });
      await first.observe(id);
      await first.review(
        (await first.episodes()).last,
        MemoryGovernanceAction.accept,
      );
      expect(first.memory.state.value.preferredAddress, '阿岚');
      expect(second.memory.facts, isEmpty);
      await second.memory.refresh();
      expect(second.memory.policyVersion, 0);
    },
  );

  test(
    'candidate write failure preserves a verified immediate source lease',
    () async {
      final h = await _Harness.open(
        faultInjector: (point, _) {
          if (point == MemoryWriteFaultPoint.beforeCommit) {
            throw StateError('test write fault');
          }
        },
      );
      addTearDown(h.close);
      final id = await h.message('以后叫我阿岚');
      expect(await h.observe(id), 'chat_message:$id');
      expect(await h.episodes(), isEmpty);
      await MemoryGovernanceStores.chatMessages.record(id).delete(h.database);
      await h.memory.refresh();
      expect(h.memory.invalidatedSourceIds, contains('chat_message:$id'));
    },
  );

  test(
    'refresh failure clears the accepted read model and advances version',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.observe(await h.message('以后叫我阿岚'));
      await h.review((await h.episodes()).last, MemoryGovernanceAction.accept);
      final version = h.memory.policyVersion;
      await h.database.close();
      await expectLater(h.memory.refresh(), throwsA(isA<Object>()));
      expect(h.memory.facts, isEmpty);
      expect(h.memory.state.value.preferredAddress, isNull);
      expect(h.memory.policyVersion, greaterThan(version));
    },
  );
}

int _sequence = 0;

final class _Harness {
  _Harness(this.database, this.account);
  final Database database;
  final String account;
  FeatureRolloutMode mode = FeatureRolloutMode.enforce;
  late final ConversationMemoryService memory;
  late final MemoryWriteCoordinator writer;
  late final EpisodeStore store;
  int ticks = 0;
  DateTime get now => DateTime.utc(2026, 9, 15).add(Duration(seconds: ticks));
  static Future<_Harness> open({
    String? account,
    MemoryWriteFaultInjector? faultInjector,
  }) async {
    final h = _Harness(
      await databaseFactoryMemory.openDatabase('conversation-${_sequence++}'),
      account ?? 'a' * 64,
    );
    h.store = EpisodeStore(
      database: h.database,
      accountScopeDigest: h.account,
      memoryV2Mode: () => h.mode,
      clock: () => h.now,
    );
    h.memory = ConversationMemoryService(
      database: h.database,
      accountScopeDigest: h.account,
      agentId: 'agent-a',
      memoryV2Mode: () => h.mode,
    );
    h.writer = MemoryWriteCoordinator(
      database: h.database,
      episodeStore: h.store,
      accountScopeDigest: h.account,
      memoryV2Mode: () => h.mode,
      clock: () => h.now,
      governedProjectionFamilies: [h.memory],
      faultInjector: faultInjector,
      linkEpisode: (_) async {},
      projectMilestone: (_) async {},
    );
    h.memory.bindGovernance(h.writer);
    return h;
  }

  Future<int> message(
    String content, {
    bool user = true,
    Map<String, Object?> fields = const {},
  }) {
    ticks++;
    return MemoryGovernanceStores.chatMessages.add(database, {
      ...ChatMessage(
        sessionId: 'private',
        senderId: user ? 'user' : 'agent-a',
        receiverId: user ? 'agent-a' : 'user',
        content: content,
        timestamp: now,
        isUserMessage: user,
        turnOrigin: ChatMessageTurnOrigins.user,
        deliveryStatus: 'published',
        turnId: 'turn-$ticks',
      ).toJson(),
      ...fields,
    });
  }

  Future<T> inSource<T>(int id, Future<T> Function() operation) =>
      writer.runWithPersistedChatSource(
        messageRecordId: id,
        sessionId: 'private',
        agentId: 'agent-a',
        operation: operation,
      );
  Future<String?> observe(int id) => inSource(id, memory.observeCurrentTurn);
  Future<List<Episode>> episodes() async => [
    for (final row in await MemoryGovernanceStores.episodes.find(database))
      Episode.fromJson(row.value)..id = row.key,
  ];
  Future<MemoryGovernanceResult> review(
    Episode episode,
    MemoryGovernanceAction action,
  ) => writer.review(
    MemoryGovernanceCommand(
      action: action,
      targetEpisodeId: episode.id!,
      expectedHeadEpisodeId: episode.id!,
      expectedRevision: episode.revision,
    ),
  );
  Future<EpisodeSourceRef> ref(int id) async {
    final raw = (await MemoryGovernanceStores.chatMessages
        .record(id)
        .get(database))!;
    return EpisodeSourceRef(
      sourceId: 'chat_message:$id',
      sessionId: 'private',
      origin: raw['isUserMessage'] == true
          ? EpisodeSourceOrigin.user
          : EpisodeSourceOrigin.agent,
      contentHash: sha256
          .convert(utf8.encode(raw['content']! as String))
          .toString(),
    );
  }

  Future<MemoryWriteResult> submit(
    int id,
    ConversationFactDraft draft, {
    List<EpisodeSourceRef> supporting = const [],
    MemoryWriteAuthority authority = MemoryWriteAuthority.governedProposal,
    String payloadAgent = 'agent-a',
  }) => inSource(id, () {
    final kind =
        'conversation.fact.${sha256.convert(utf8.encode('$payloadAgent:${draft.slotKey}')).toString().substring(0, 32)}';
    final projection = GovernedMemoryProjectionDraft(
      kind: kind,
      payload: {
        'schemaVersion': 1,
        'agentId': payloadAgent,
        'fact': draft.toJson(),
        'supportingSources': supporting.map((ref) => ref.toJson()).toList(),
      },
    );
    return writer.write(
      MemoryWriteDraft.claim(
        slot: kind,
        value: projection.canonicalPayload,
        when: now,
        projection: projection,
      ),
      authority: authority,
    );
  });
  Future<void> close() async {
    await memory.deactivateAndDrain();
    await writer.deactivateAndDrain();
    await store.deactivateAndDrain();
    await database.close();
  }
}
