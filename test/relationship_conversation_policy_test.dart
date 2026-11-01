import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/features/agent/application/skills/log_milestone_skill.dart';
import 'package:sembast/sembast_memory.dart';

const _account =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
int _databaseSequence = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late RelationshipService relationship;
  MemoryWriteCoordinator? writer;
  EpisodeStore? episodes;

  setUp(() async {
    await appServices.reset();
    writer = null;
    episodes = null;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'relationship-policy-${_databaseSequence++}.db',
    );
    appServices.put(database);
    relationship = appServices.put(RelationshipService());
  });

  tearDown(() async {
    await writer?.deactivateAndDrain();
    await episodes?.deactivateAndDrain();
    await appServices.reset();
    await database.close();
  });

  Future<void> installWriter({
    FeatureRolloutMode mode = FeatureRolloutMode.enforce,
  }) async {
    episodes = EpisodeStore(
      database: database.raw,
      accountScopeDigest: _account,
      memoryV2Mode: () => mode,
    );
    writer = appServices.put(
      MemoryWriteCoordinator(
        database: database.raw,
        episodeStore: episodes,
        accountScopeDigest: _account,
        memoryV2Mode: () => mode,
        linkEpisode: (_) async {},
        removeEpisodeLinks: (_) async {},
        projectMilestone: relationship.maybeAutoMilestoneFromEpisode,
      ),
    );
    await relationship.init();
  }

  Future<Map<String, dynamic>> callSkill(
    String method, {
    String? text,
    String agentId = 'self',
    Map<String, Object?> proposal = const {},
  }) async {
    Future<Map<String, dynamic>> invoke() async {
      final output = await LogMilestoneSkill().methods[method]!(
        method == 'getRelationship' ? const [] : [jsonEncode(proposal)],
      );
      return jsonDecode(output as String) as Map<String, dynamic>;
    }

    if (text == null) return invoke();
    final id = await database.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: agentId,
        content: text,
        timestamp: DateTime(2026, 9, 15),
        isUserMessage: true,
        turnOrigin: ChatMessageTurnOrigins.user,
      ),
    );
    return writer!.runWithPersistedChatSource(
      messageRecordId: id,
      sessionId: 'self',
      agentId: agentId,
      operation: invoke,
    );
  }

  test(
    'legacy history migrates without granting expression permissions',
    () async {
      final firstMet = DateTime(2020, 1, 1);
      await database.saveRelationship(
        RelationshipState(
          firstMetAt: firstMet,
          score: 500,
          stage: RelationshipStage.attuned,
          totalActiveDays: 100,
          longestStreak: 70,
        ),
      );
      await relationship.init();
      expect(relationship.state.value!.stage, RelationshipStage.attuned);
      expect(relationship.state.value!.score, 500);
      expect(relationship.effectiveStage, RelationshipExpressionStage.newlyMet);
      expect(
        relationship.state.value!.expressionStage,
        relationship.effectiveStage,
      );
      await relationship.recordInteraction();
      await relationship.addMilestone(
        type: 'inside_joke',
        title: '未经确认的共同梗',
        weight: 1000,
      );
      expect(relationship.effectiveStage, RelationshipExpressionStage.newlyMet);
      final saved = (await database.getRelationship())!;
      expect(saved.firstMetAt, firstMet);
      expect(saved.longestStreak, 70);
      expect(saved.toJson()['schemaVersion'], 2);
      expect(saved.expressionStage, RelationshipExpressionStage.newlyMet);
    },
  );

  test(
    'effective projection survives history pagination and time apart',
    () async {
      await relationship.init(firstMetFallback: DateTime(2000, 1, 1));
      relationship.updateConversationPolicy(_familiarPolicy(7));
      relationship.state.value!.lastActiveDate = DateTime(2001, 1, 1);
      relationship.milestones.assignAll(
        List.generate(
          101,
          (index) => Milestone(
            id: index + 1,
            when: DateTime(2026, 1, 1),
            type: 'custom',
            title: '历史 $index',
          ),
        ),
      );
      await relationship.recordInteraction();
      relationship.milestones.clear();
      expect(relationship.effectiveStage, RelationshipExpressionStage.familiar);
      expect(
        relationship.state.value!.expressionStage,
        RelationshipExpressionStage.familiar,
      );
      expect(relationship.policyVersion, 7);
      expect(
        relationship.summaryForPrompt(locale: AppLocale.en),
        contains('familiar'),
      );
    },
  );

  test(
    'revocation updates stage and signature without resurrecting wall text',
    () async {
      await relationship.init();
      relationship.milestones.add(
        Milestone(
          when: DateTime.now(),
          type: 'inside_joke',
          title: '已删除的秘密共同梗',
          note: '原来源已经删除',
        ),
      );
      relationship.updateConversationPolicy(_familiarPolicy(4));
      final previous = relationship.promptSignature(locale: AppLocale.en);
      relationship.updateConversationPolicy(
        ConversationPolicy.fromFacts(const [], policyVersion: 5),
      );
      expect(
        relationship.state.value!.expressionStage,
        RelationshipExpressionStage.newlyMet,
      );
      expect(
        relationship.promptSignature(locale: AppLocale.en),
        isNot(previous),
      );
      expect(
        relationship.summaryForPrompt(locale: AppLocale.zh),
        isNot(contains('秘密共同梗')),
      );
      expect(
        relationship.summaryForPrompt(locale: AppLocale.zh),
        isNot(contains('原来源')),
      );
    },
  );

  test(
    'memory binding updates the reactive state and releases its listener',
    () async {
      final memory = ConversationMemoryService(
        database: database.raw,
        accountScopeDigest: _account,
        memoryV2Mode: () => FeatureRolloutMode.enforce,
      );
      addTearDown(memory.closeLifecycle);
      await relationship.init();
      relationship.bindConversationMemory(memory);
      memory.state.value = _familiarPolicy(3);
      expect(
        relationship.state.value!.expressionStage,
        RelationshipExpressionStage.familiar,
      );
      memory.state.value = ConversationPolicy.fromFacts(
        const [],
        policyVersion: 4,
      );
      expect(relationship.effectiveStage, RelationshipExpressionStage.newlyMet);
      relationship.closeLifecycle();
      memory.state.value = _familiarPolicy(5);
      expect(relationship.state.value, isNull);
      expect(relationship.effectiveStage, RelationshipExpressionStage.newlyMet);
    },
  );

  test(
    'skill event remains pending and cannot raise the relationship stage',
    () async {
      await installWriter();
      final result = await callSkill(
        'logMilestone',
        text: '今天我们讨论了报告。',
        proposal: {'type': 'deep_talk', 'title': '完成报告讨论', 'note': '一起整理了报告思路'},
      );
      expect(result['status'], 'pending_review');
      final raw = await MemoryGovernanceStores.episodes
          .record(result['episodeId'] as int)
          .get(database.raw);
      final episode = Episode.fromJson(raw!);
      expect(episode.kind, EpisodeKind.relationship);
      expect(episode.reviewState, EpisodeReviewState.pending);
      expect(episode.sourceRefs.single.sourceId, startsWith('chat_message:'));
      expect(relationship.milestones, isEmpty);
      expect(relationship.effectiveStage, RelationshipExpressionStage.newlyMet);
    },
  );

  test(
    'accepted then deleted event has no ungoverned wall or prompt copy',
    () async {
      await installWriter();
      final result = await callSkill(
        'logMilestone',
        text: '记住：今天一起完成了报告',
        proposal: {'type': 'goal_done', 'title': '今天一起完成了报告'},
      );
      expect(result['status'], 'applied');
      final id = result['episodeId'] as int;
      final deleted = await writer!.review(
        MemoryGovernanceCommand(
          action: MemoryGovernanceAction.delete,
          targetEpisodeId: id,
          expectedHeadEpisodeId: id,
          expectedRevision: 1,
        ),
      );
      expect(deleted.status, MemoryGovernanceStatus.applied);
      expect(relationship.milestones, isEmpty);
      expect(await database.getMilestones(), isEmpty);
      expect(
        relationship.summaryForPrompt(locale: AppLocale.zh),
        isNot(contains('完成了报告')),
      );
      final current = await callSkill('getRelationship', text: '我们现在怎么样？');
      expect(current['stage'], 'new');
      expect(current.containsKey('recent'), isFalse);
    },
  );

  test('skill denies missing or foreign private sources', () async {
    await installWriter();
    for (final agent in [null, 'other-agent']) {
      final result = await callSkill(
        'logMilestone',
        text: agent == null ? null : '今天完成了报告',
        agentId: agent ?? 'self',
        proposal: {'title': '完成报告'},
      );
      expect(result['status'], 'rejected');
      final read = await callSkill(
        'getRelationship',
        text: agent == null ? null : '我们多熟',
        agentId: agent ?? 'self',
      );
      expect(read['error'], 'private_human_source_required');
    }
    expect(await MemoryGovernanceStores.episodes.count(database.raw), 0);
  });

  test('rollout off does not restore direct milestone writes', () async {
    await installWriter(mode: FeatureRolloutMode.off);
    final result = await callSkill(
      'logMilestone',
      text: '记住完成报告',
      proposal: {'title': '完成报告'},
    );
    expect(result['status'], 'rejected');
    expect(relationship.milestones, isEmpty);
    expect(await MemoryGovernanceStores.episodes.count(database.raw), 0);
  });
}

ConversationPolicy _familiarPolicy(int version) =>
    ConversationPolicy.fromFacts([
      for (var index = 1; index <= 2; index++)
        ConversationFact(
          draft: ConversationFactDraft.sharedContext(
            contextKey: 'scene-$index',
            label: '真实话题 $index',
            evidenceKind: ConversationEvidenceKind.confirmedContinuation,
          ),
          episodeId: index,
          revision: 1,
          sourceRefs: [
            EpisodeSourceRef(
              sourceId: 'chat_message:$index',
              sessionId: 'scene-$index',
              origin: EpisodeSourceOrigin.user,
              contentHash: '$index'.padLeft(64, '0'),
            ),
          ],
        ),
    ], policyVersion: version);
