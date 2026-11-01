import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
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

  group('MemoryWriteCoordinator enforce provenance and review', () {
    test(
      'rehydrates the durable human ChatMessage and quarantines automatic summaries',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        const content = '今天我在公园散步，天气很好。';
        final messageId = await harness.persistHumanMessage(content);

        final result = await harness.writeFromMessage(
          messageId,
          _event('用户今天在公园散步'),
        );

        expect(result.disposition, MemoryWriteDisposition.quarantined);
        expect(result.created, isTrue);
        expect(result.projected, isFalse);
        expect(result.episode, isNotNull);
        final episode = result.episode!;
        expect(episode.reviewState, EpisodeReviewState.pending);
        expect(episode.sourceType, EpisodeSourceType.conversation);
        expect(episode.confidence, 0.6);
        expect(episode.agentId, 'agent-a');
        expect(episode.sourceRefs, hasLength(1));
        expect(episode.sourceRefs.single.sourceId, 'chat_message:$messageId');
        expect(episode.sourceRefs.single.sessionId, 'self');
        expect(episode.sourceRefs.single.origin, EpisodeSourceOrigin.user);
        expect(
          episode.sourceRefs.single.contentHash,
          sha256.convert(utf8.encode(content)).toString(),
        );
        expect(episode.when, _messageTime);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);

        final persisted = await MemoryGovernanceStores.episodes
            .record(episode.id!)
            .get(harness.database);
        final governance = await MemoryGovernanceStores.episodeGovernance
            .record(episode.id!)
            .get(harness.database);
        expect(Episode.fromJson(persisted!).toJson(), episode.toJson());
        expect(governance?['current'], isFalse);
        expect(governance?['reviewState'], EpisodeReviewState.pending.name);
        expect(await harness.store.isRecallEligible(episode), isFalse);
      },
    );

    test('ordinary memory keeps the pre-projection v2 fingerprints', () async {
      final harness = await _Harness.create(FeatureRolloutMode.enforce);
      addTearDown(harness.close);
      const sourceContent = '普通记忆来源';
      const memoryText = '普通记忆内容';
      final messageId = await harness.persistHumanMessage(sourceContent);

      final result = await harness.writeFromMessage(
        messageId,
        _event(memoryText),
      );

      final governance = await MemoryGovernanceStores.episodeGovernance
          .record(result.episodeId!)
          .get(harness.database);
      final sourceHash = sha256.convert(utf8.encode(sourceContent)).toString();
      final expectedExact = sha256
          .convert(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'domain': 'memory-exact-v2',
                'kind': EpisodeKind.episode.name,
                'what': memoryText,
                'entities': <String>[],
                'emotion': '',
                'salience': 0.5,
                'retentionClass': EpisodeRetentionClass.durable.name,
                'when': _messageTime.toIso8601String(),
                'claimSlot': '',
                'claimValue': '',
                'sourceId': 'chat_message:$messageId',
                'sourceHash': sourceHash,
              }),
            ),
          )
          .toString();
      final expectedSemantic = sha256
          .convert(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'domain': 'memory-semantic-v2',
                'kind': EpisodeKind.episode.name,
                'what': memoryText,
                'entities': <String>[],
                'claimSlot': '',
                'claimValue': '',
                'day': _messageTime.toIso8601String().substring(0, 10),
              }),
            ),
          )
          .toString();

      expect(governance?['exactFingerprint'], expectedExact);
      expect(governance?['semanticFingerprint'], expectedSemantic);
    });

    test(
      'an explicit remember request is canonicalized from the durable source',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住我最喜欢的饮料是乌龙茶。');

        final result = await harness.writeFromMessage(
          messageId,
          MemoryWriteDraft.claim(
            slot: 'favorite_drink',
            value: '乌龙茶',
            summary: '用户最喜欢乌龙茶',
            when: _draftTime,
            entities: const <String>['乌龙茶'],
            salience: 1,
            retentionClass: EpisodeRetentionClass.transient,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.accepted);
        expect(result.created, isTrue);
        expect(result.projected, isTrue);
        expect(result.episode!.reviewState, EpisodeReviewState.accepted);
        expect(result.episode!.sourceType, EpisodeSourceType.explicitSave);
        expect(result.episode!.confidence, 0.9);
        expect(result.episode!.what, '我最喜欢的饮料是乌龙茶。');
        expect(result.episode!.kind, EpisodeKind.episode);
        expect(result.episode!.entities, isEmpty);
        expect(result.episode!.emotion, isNull);
        expect(result.episode!.salience, 0.7);
        expect(result.episode!.retentionClass, EpisodeRetentionClass.durable);
        expect(await harness.store.isRecallEligible(result.episode!), isTrue);
        expect(harness.linkedEpisodes, <Episode>[result.episode!]);
        expect(harness.projectedMilestones, <Episode>[result.episode!]);
        expect(
          await MemoryGovernanceStores.claimHeads.count(harness.database),
          0,
        );
      },
    );

    test(
      'an accepted explicit save preserves source casing and internal whitespace',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        const source = '请记住门禁码是 AB  12\n第二行。';
        final messageId = await harness.persistHumanMessage(source);

        final result = await harness.writeFromMessage(
          messageId,
          _event('门禁码是 AB 12 第二行。'),
        );

        expect(result.disposition, MemoryWriteDisposition.accepted);
        expect(result.episode!.what, '门禁码是 AB  12\n第二行。');
        final persisted = await MemoryGovernanceStores.episodes
            .record(result.episodeId!)
            .get(harness.database);
        expect(persisted?['what'], '门禁码是 AB  12\n第二行。');
      },
    );

    test('accepts save verbs only when long-term memory is explicit', () async {
      final cases = <Map<String, String>>[
        <String, String>{
          'source': '请保存到记忆：我的备用城市是杭州。',
          'draft': '我的备用城市是杭州。',
          'expected': '我的备用城市是杭州。',
        },
        <String, String>{
          'source': 'Please save this fact: my backup city is Hangzhou.',
          'draft': 'my backup city is Hangzhou.',
          'expected': 'my backup city is Hangzhou.',
        },
      ];

      for (final testCase in cases) {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage(
          testCase['source']!,
        );

        final result = await harness.writeFromMessage(
          messageId,
          _event(testCase['draft']!),
        );

        expect(result.disposition, MemoryWriteDisposition.accepted);
        expect(result.episode!.what, testCase['expected']);
      }
    });

    test(
      'case and whitespace-sensitive explicit values do not semantic-deduplicate',
      () async {
        final scenarios = <Map<String, String>>[
          <String, String>{
            'firstSource': '请记住门禁码是 AB  12',
            'secondSource': '请记住门禁码是 AB 12',
            'firstDraft': '门禁码是 AB 12',
            'secondDraft': '门禁码是 AB 12',
            'firstExpected': '门禁码是 AB  12',
            'secondExpected': '门禁码是 AB 12',
          },
          <String, String>{
            'firstSource': 'Please remember my code is AbC.',
            'secondSource': 'Please remember my code is ABC.',
            'firstDraft': 'my code is AbC',
            'secondDraft': 'my code is ABC',
            'firstExpected': 'my code is AbC.',
            'secondExpected': 'my code is ABC.',
          },
        ];

        for (final scenario in scenarios) {
          final harness = await _Harness.create(FeatureRolloutMode.enforce);
          addTearDown(harness.close);
          final firstMessage = await harness.persistHumanMessage(
            scenario['firstSource']!,
          );
          final secondMessage = await harness.persistHumanMessage(
            scenario['secondSource']!,
            timestamp: _messageTime.add(const Duration(minutes: 1)),
          );

          final first = await harness.writeFromMessage(
            firstMessage,
            _event(scenario['firstDraft']!),
          );
          final second = await harness.writeFromMessage(
            secondMessage,
            _event(scenario['secondDraft']!),
          );

          expect(first.disposition, MemoryWriteDisposition.accepted);
          expect(second.disposition, MemoryWriteDisposition.accepted);
          expect(first.created, isTrue);
          expect(second.created, isTrue);
          expect(first.episodeId, isNot(second.episodeId));
          expect(first.episode!.what, scenario['firstExpected']);
          expect(second.episode!.what, scenario['secondExpected']);
          expect(
            await MemoryGovernanceStores.episodes.count(harness.database),
            2,
          );
        }
      },
    );

    test(
      'verified claim values preserve case and whitespace revision boundaries',
      () async {
        final scenarios = <Map<String, String>>[
          <String, String>{'first': 'AbC', 'second': 'ABC'},
          <String, String>{'first': 'AB  12', 'second': 'AB 12'},
        ];

        for (final scenario in scenarios) {
          final harness = await _Harness.create(FeatureRolloutMode.enforce);
          addTearDown(harness.close);
          final firstMessage = await harness.persistHumanMessage(
            '可信来源值 ${scenario['first']}',
          );
          final secondMessage = await harness.persistHumanMessage(
            '可信来源值 ${scenario['second']}',
            timestamp: _messageTime.add(const Duration(minutes: 1)),
          );

          final first = await harness.writeVerifiedFromMessage(
            firstMessage,
            MemoryWriteDraft.claim(
              slot: 'case_sensitive_code',
              value: scenario['first']!,
              summary: '门禁码 ${scenario['first']}',
              when: _draftTime,
            ),
          );
          final second = await harness.writeVerifiedFromMessage(
            secondMessage,
            MemoryWriteDraft.claim(
              slot: 'case_sensitive_code',
              value: scenario['second']!,
              summary: '门禁码 ${scenario['second']}',
              when: _draftTime.add(const Duration(minutes: 1)),
            ),
          );

          expect(first.disposition, MemoryWriteDisposition.accepted);
          expect(second.disposition, MemoryWriteDisposition.accepted);
          expect(second.created, isTrue);
          expect(second.episodeId, isNot(first.episodeId));
          expect(second.episode!.revision, 2);
          expect(second.episode!.supersedesId, first.episodeId);
          expect(second.episode!.contradictionIds, <int>[first.episodeId!]);
          expect(await harness.store.isRecallEligible(first.episode!), isFalse);
          expect(await harness.store.isRecallEligible(second.episode!), isTrue);
        }
      },
    );

    test(
      'quarantines an ungrounded model draft despite an explicit remember request',
      () async {
        final embedding = _RecordingEmbeddingService();
        appServices.put<EmbeddingService>(embedding);
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住我喜欢乌龙茶。');

        final result = await harness.writeFromMessage(
          messageId,
          MemoryWriteDraft.claim(
            slot: 'residence_city',
            value: '巴黎',
            summary: '用户住在巴黎',
            when: _draftTime,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.quarantined);
        expect(result.reason, 'explicit_save_not_grounded');
        expect(result.created, isTrue);
        expect(result.projected, isFalse);
        expect(result.episode, isNotNull);
        expect(result.episode!.reviewState, EpisodeReviewState.pending);
        expect(result.episode!.sourceType, EpisodeSourceType.conversation);
        expect(await harness.store.isRecallEligible(result.episode!), isFalse);
        await harness.store.waitForIdle();
        expect(embedding.calls, 0);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);
      },
    );

    test(
      'quarantines a proposal that drops reported-speech attribution',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住小王说我住在巴黎。');

        final result = await harness.writeFromMessage(
          messageId,
          MemoryWriteDraft.claim(
            slot: 'residence_city',
            value: '巴黎',
            summary: '用户住在巴黎',
            when: _draftTime,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.quarantined);
        expect(result.reason, 'explicit_save_not_grounded');
        expect(result.episode!.reviewState, EpisodeReviewState.pending);
        expect(await harness.store.isRecallEligible(result.episode!), isFalse);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);
      },
    );

    test(
      'quarantines factual metadata absent from the durable source',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住我住在巴黎。');

        final result = await harness.writeFromMessage(
          messageId,
          MemoryWriteDraft.event(
            what: '用户住在巴黎',
            entities: const <String>['伦敦'],
            emotion: '高兴',
            when: _draftTime,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.quarantined);
        expect(result.reason, 'explicit_save_not_grounded');
        expect(result.episode!.reviewState, EpisodeReviewState.pending);
        expect(await harness.store.isRecallEligible(result.episode!), isFalse);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);
      },
    );

    test(
      'an automatic draft cannot overwrite a verified claim through its slot',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final colorMessage = await harness.persistHumanMessage('我最喜欢的颜色是蓝色。');
        final color = await harness.writeVerifiedFromMessage(
          colorMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '蓝色',
            summary: '用户最喜欢蓝色',
            when: _draftTime,
          ),
        );
        final residenceMessage = await harness.persistHumanMessage(
          '请记住我住在巴黎。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );

        final residence = await harness.writeFromMessage(
          residenceMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '巴黎',
            summary: '用户住在巴黎',
            when: _draftTime.add(const Duration(minutes: 1)),
          ),
        );

        expect(color.disposition, MemoryWriteDisposition.accepted);
        expect(residence.disposition, MemoryWriteDisposition.accepted);
        expect(residence.episode!.kind, EpisodeKind.episode);
        expect(residence.episode!.what, '我住在巴黎。');
        expect(residence.episode!.supersedesId, isNull);
        expect(residence.episode!.contradictionIds, isEmpty);
        expect(await harness.store.isRecallEligible(color.episode!), isTrue);
        expect(
          await harness.store.isRecallEligible(residence.episode!),
          isTrue,
        );
        final head = await MemoryGovernanceStores.claimHeads
            .record(
              sha256
                  .convert(utf8.encode('claim-slot-v1:favorite_color'))
                  .toString(),
            )
            .get(harness.database);
        expect(head?['episodeId'], color.episodeId);
        expect(head?['revision'], 1);
      },
    );

    test(
      'accepted automatic writes preserve source negation and pronoun roles',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final preferenceMessage = await harness.persistHumanMessage(
          '请记住我不喜欢咖啡，喜欢茶。',
        );
        final preference = await harness.writeFromMessage(
          preferenceMessage,
          MemoryWriteDraft.claim(
            slot: 'tea_preference',
            value: '茶',
            summary: '用户不喜欢茶',
            when: _draftTime,
          ),
        );
        final pronounMessage = await harness.persistHumanMessage(
          '请记住我喜欢他。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );
        final pronoun = await harness.writeFromMessage(
          pronounMessage,
          MemoryWriteDraft.event(
            what: '他喜欢我',
            when: _draftTime.add(const Duration(minutes: 1)),
          ),
        );

        expect(preference.disposition, MemoryWriteDisposition.accepted);
        expect(preference.episode!.kind, EpisodeKind.episode);
        expect(preference.episode!.what, '我不喜欢咖啡，喜欢茶。');
        expect(pronoun.disposition, MemoryWriteDisposition.accepted);
        expect(pronoun.episode!.kind, EpisodeKind.episode);
        expect(pronoun.episode!.what, '我喜欢他。');
        expect(
          await MemoryGovernanceStores.claimHeads.count(harness.database),
          0,
        );
      },
    );

    test(
      'rejects explicit no-save requests without creating or projecting memory',
      () async {
        final embedding = _RecordingEmbeddingService();
        appServices.put<EmbeddingService>(embedding);
        final cases = <Map<String, String>>[
          <String, String>{
            'source': '请不要记住我住在巴黎。',
            'slot': 'residence_city',
            'value': '巴黎',
            'summary': '用户住在巴黎',
          },
          <String, String>{
            'source': "please don't save this: I live in London.",
            'slot': 'residence_city',
            'value': 'London',
            'summary': 'The user lives in London',
          },
          <String, String>{
            'source':
                'Remember my code is AB12, but do not persist or retain it.',
            'slot': 'access_code',
            'value': 'AB12',
            'summary': 'my code is AB12',
          },
          <String, String>{
            'source': '请记住密码是AB12，但不要持久化或留存。',
            'slot': 'access_code',
            'value': 'AB12',
            'summary': '密码是AB12',
          },
        ];

        for (final testCase in cases) {
          final harness = await _Harness.create(FeatureRolloutMode.enforce);
          addTearDown(harness.close);
          final messageId = await harness.persistHumanMessage(
            testCase['source']!,
          );

          final result = await harness.writeFromMessage(
            messageId,
            MemoryWriteDraft.claim(
              slot: testCase['slot']!,
              value: testCase['value']!,
              summary: testCase['summary']!,
              when: _draftTime,
            ),
          );

          expect(result.disposition, MemoryWriteDisposition.rejected);
          expect(result.reason, 'explicit_no_save_request');
          expect(result.episode, isNull);
          expect(result.created, isFalse);
          expect(result.projected, isFalse);
          expect(
            await MemoryGovernanceStores.episodes.count(harness.database),
            0,
          );
          expect(harness.linkedEpisodes, isEmpty);
          expect(harness.projectedMilestones, isEmpty);
          await harness.store.waitForIdle();
        }
        expect(embedding.calls, 0);
      },
    );

    test(
      'rejects explicit ephemeral retention instead of forcing durable storage',
      () async {
        final cases = <Map<String, String>>[
          <String, String>{
            'source': '请记住我的验证码是1234，但不要长期保存。',
            'draft': '我的验证码是1234',
          },
          <String, String>{
            'source': '请记住我的验证码是1234，只保留五分钟。',
            'draft': '我的验证码是1234',
          },
          <String, String>{
            'source': '请记住我的验证码是1234，保存五分钟。',
            'draft': '我的验证码是1234',
          },
          <String, String>{
            'source': '请记住我的验证码是1234，五分钟后忘掉。',
            'draft': '我的验证码是1234',
          },
          <String, String>{
            'source': '请记住我的验证码是1234，本次会话后忘掉。',
            'draft': '我的验证码是1234',
          },
          <String, String>{'source': '请记住验证码1234到今晚。', 'draft': '验证码1234'},
          <String, String>{'source': '请记住验证码1234，半小时后删掉。', 'draft': '验证码1234'},
          <String, String>{'source': '请记住验证码1234，过五分钟删掉。', 'draft': '验证码1234'},
          <String, String>{'source': '请记住密码是AB12，只保留30秒。', 'draft': '密码是AB12'},
          <String, String>{'source': '请记住密码是AB12，仅限今天。', 'draft': '密码是AB12'},
          <String, String>{
            'source': '请记住密码是AB12，本次会话期间有效。',
            'draft': '密码是AB12',
          },
          <String, String>{
            'source': 'Please remember my code is 1234 for five minutes.',
            'draft': 'my code is 1234',
          },
          <String, String>{
            'source':
                'Please remember my code is 1234 for the next five minutes.',
            'draft': 'my code is 1234',
          },
          <String, String>{
            'source': 'Please remember my code is 1234 until tonight.',
            'draft': 'my code is 1234',
          },
          <String, String>{
            'source': 'Remember my code is AB12 for 30 seconds.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'Remember my code is AB12 for now.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'Remember my code is AB12 during this session.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'Remember my code is AB12 today only.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'Temporarily remember my code is AB12.',
            'draft': 'my code is AB12',
          },
          <String, String>{'source': '暂时记住验证码是1234。', 'draft': '验证码是1234'},
          <String, String>{'source': '本次会话期间记住验证码1234。', 'draft': '验证码1234'},
          <String, String>{
            'source': 'For this session, remember my code is AB12.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'During this session remember my code is AB12.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source': 'Remember my code is AB12 only for this turn.',
            'draft': 'my code is AB12',
          },
          <String, String>{
            'source':
                "Please remember my code is 1234, but don't keep it long-term.",
            'draft': 'my code is 1234',
          },
        ];

        for (final testCase in cases) {
          final harness = await _Harness.create(FeatureRolloutMode.enforce);
          addTearDown(harness.close);
          final messageId = await harness.persistHumanMessage(
            testCase['source']!,
          );

          final result = await harness.writeFromMessage(
            messageId,
            _event(testCase['draft']!),
          );

          expect(result.disposition, MemoryWriteDisposition.rejected);
          expect(result.reason, 'explicit_no_save_request');
          expect(result.episode, isNull);
          expect(
            await MemoryGovernanceStores.episodes.count(harness.database),
            0,
          );
          expect(harness.linkedEpisodes, isEmpty);
          expect(harness.projectedMilestones, isEmpty);
        }
      },
    );

    test(
      'rejects an oversized explicit-save assertion before persistence',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final payload = List<String>.filled(4097, 'x').join();
        final messageId = await harness.persistHumanMessage(
          'Please remember $payload',
        );

        final result = await harness.writeFromMessage(
          messageId,
          _event('oversized explicit memory'),
        );

        expect(result.disposition, MemoryWriteDisposition.rejected);
        expect(result.reason, 'explicit_save_too_long');
        expect(result.episode, isNull);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          0,
        );
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);
      },
    );

    test(
      'quarantines a claim that drops source negation from an explicit save',
      () async {
        final embedding = _RecordingEmbeddingService();
        appServices.put<EmbeddingService>(embedding);
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住我不喜欢咖啡。');

        final result = await harness.writeFromMessage(
          messageId,
          MemoryWriteDraft.claim(
            slot: 'coffee_preference',
            value: '咖啡',
            summary: '用户喜欢咖啡',
            when: _draftTime,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.quarantined);
        expect(result.reason, 'explicit_save_not_grounded');
        expect(result.created, isTrue);
        expect(result.projected, isFalse);
        expect(result.episode, isNotNull);
        expect(result.episode!.reviewState, EpisodeReviewState.pending);
        expect(await harness.store.isRecallEligible(result.episode!), isFalse);
        await harness.store.waitForIdle();
        expect(embedding.calls, 0);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);
      },
    );

    test('quarantines an Alice and Bob subject-object reversal', () async {
      final embedding = _RecordingEmbeddingService();
      appServices.put<EmbeddingService>(embedding);
      final harness = await _Harness.create(FeatureRolloutMode.enforce);
      addTearDown(harness.close);
      final messageId = await harness.persistHumanMessage(
        'Please remember Alice likes Bob.',
      );

      final result = await harness.writeFromMessage(
        messageId,
        MemoryWriteDraft.claim(
          slot: 'relationship',
          value: 'Bob likes Alice',
          summary: 'Bob likes Alice',
          when: _draftTime,
        ),
      );

      expect(result.disposition, MemoryWriteDisposition.quarantined);
      expect(result.reason, 'explicit_save_not_grounded');
      expect(result.created, isTrue);
      expect(result.projected, isFalse);
      expect(result.episode, isNotNull);
      expect(result.episode!.reviewState, EpisodeReviewState.pending);
      expect(await harness.store.isRecallEligible(result.episode!), isFalse);
      await harness.store.waitForIdle();
      expect(embedding.calls, 0);
      expect(harness.linkedEpisodes, isEmpty);
      expect(harness.projectedMilestones, isEmpty);
    });

    test(
      'a statement about remembering does not grant explicit-save authority',
      () async {
        final embedding = _RecordingEmbeddingService();
        appServices.put<EmbeddingService>(embedding);
        final cases = <Map<String, String>>[
          <String, String>{
            'source': 'I remember Alice likes Bob.',
            'draft': 'Alice likes Bob',
          },
          <String, String>{
            'source': 'Remembering Alice makes me sad.',
            'draft': 'ing Alice makes me sad.',
          },
          <String, String>{
            'source': '记录显示 Alice 很难过。',
            'draft': '显示 Alice 很难过。',
          },
          <String, String>{'source': '记得那年我们在巴黎。', 'draft': '那年我们在巴黎。'},
          <String, String>{'source': '保存下来的照片让我难过。', 'draft': '下来的照片让我难过。'},
          <String, String>{'source': '记录着 Alice 的变化。', 'draft': '着 Alice 的变化。'},
          <String, String>{'source': 'Please save this file.', 'draft': 'file'},
          <String, String>{
            'source': 'Record this meeting.',
            'draft': 'meeting',
          },
          <String, String>{'source': '请保存这张照片。', 'draft': '照片'},
        ];

        for (final testCase in cases) {
          final harness = await _Harness.create(FeatureRolloutMode.enforce);
          addTearDown(harness.close);
          final messageId = await harness.persistHumanMessage(
            testCase['source']!,
          );

          final result = await harness.writeFromMessage(
            messageId,
            _event(testCase['draft']!),
          );

          expect(result.disposition, MemoryWriteDisposition.quarantined);
          expect(result.reason, 'automatic_summary_requires_review');
          expect(result.created, isTrue);
          expect(result.projected, isFalse);
          expect(result.episode, isNotNull);
          expect(result.episode!.reviewState, EpisodeReviewState.pending);
          expect(result.episode!.sourceType, EpisodeSourceType.conversation);
          expect(
            await harness.store.isRecallEligible(result.episode!),
            isFalse,
          );
          await harness.store.waitForIdle();
          expect(harness.linkedEpisodes, isEmpty);
          expect(harness.projectedMilestones, isEmpty);
        }
        expect(embedding.calls, 0);
      },
    );

    test(
      'serializes concurrent exact replays and deduplicates the same semantic event across sources',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage('今天去了图书馆。');
        final draft = _event('用户今天去了图书馆', emotion: '平静');

        final concurrent = await harness.runFromMessage(
          firstMessage,
          () => Future.wait(
            List<Future<MemoryWriteResult>>.generate(
              12,
              (_) => harness.coordinator.write(draft),
            ),
          ),
        );

        expect(
          concurrent.where(
            (result) =>
                result.disposition == MemoryWriteDisposition.quarantined,
          ),
          hasLength(1),
        );
        expect(
          concurrent.where(
            (result) => result.disposition == MemoryWriteDisposition.duplicate,
          ),
          hasLength(11),
        );
        expect(
          concurrent.map((result) => result.episodeId).toSet(),
          hasLength(1),
        );

        final secondMessage = await harness.persistHumanMessage(
          '我今天确实去了图书馆。',
          timestamp: _messageTime.add(const Duration(hours: 1)),
        );
        final semanticReplay = await harness.writeFromMessage(
          secondMessage,
          _event('  用户今天去了图书馆  ', emotion: '兴奋'),
        );

        expect(semanticReplay.disposition, MemoryWriteDisposition.duplicate);
        expect(semanticReplay.created, isFalse);
        expect(semanticReplay.episodeId, concurrent.first.episodeId);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          1,
        );
        final auditRows = await MemoryGovernanceStores.audit.find(
          harness.database,
        );
        expect(
          auditRows.map((row) => row.value['reason']),
          containsAll(<String>['exact_replay', 'semantic_duplicate']),
        );
      },
    );

    test(
      'salience and retention changes are semantic rather than exact replays',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('今天去了博物馆。');
        final initial = MemoryWriteDraft.event(
          what: '用户今天去了博物馆',
          when: _draftTime,
          salience: 0.4,
          retentionClass: EpisodeRetentionClass.durable,
        );
        final changedSalience = MemoryWriteDraft.event(
          what: initial.what,
          when: _draftTime,
          salience: 0.8,
          retentionClass: EpisodeRetentionClass.durable,
        );
        final changedRetention = MemoryWriteDraft.event(
          what: initial.what,
          when: _draftTime,
          salience: 0.4,
          retentionClass: EpisodeRetentionClass.standard,
        );

        final first = await harness.writeFromMessage(messageId, initial);
        final salienceReplay = await harness.writeFromMessage(
          messageId,
          changedSalience,
        );
        final retentionReplay = await harness.writeFromMessage(
          messageId,
          changedRetention,
        );

        expect(first.disposition, MemoryWriteDisposition.quarantined);
        expect(salienceReplay.disposition, MemoryWriteDisposition.duplicate);
        expect(retentionReplay.disposition, MemoryWriteDisposition.duplicate);
        expect(salienceReplay.episodeId, first.episodeId);
        expect(retentionReplay.episodeId, first.episodeId);
        final audits = await MemoryGovernanceStores.audit.find(
          harness.database,
        );
        expect(
          audits.where((row) => row.value['reason'] == 'semantic_duplicate'),
          hasLength(2),
        );
        expect(
          audits.where((row) => row.value['reason'] == 'exact_replay'),
          isEmpty,
        );
      },
    );

    test(
      'missing, mismatched, synthetic, and foreign scopes fail closed',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final proposal = _event('不应落库');

        final missingScope = await harness.coordinator.write(proposal);
        final missingRecord = await harness.writeFromMessage(9999, proposal);
        final wrongSessionId = await harness.persistHumanMessage('普通用户消息');
        final wrongSession = await harness.coordinator
            .runWithPersistedChatSource(
              messageRecordId: wrongSessionId,
              sessionId: 'different-session',
              agentId: 'agent-a',
              operation: () => harness.coordinator.write(proposal),
            );
        final assistantId = await harness.persistMessage(
          content: '模型生成的消息',
          isUserMessage: false,
          origin: ChatMessageTurnOrigins.system,
        );
        final synthetic = await harness.writeFromMessage(assistantId, proposal);
        final foreign = MemoryWriteCoordinator(
          database: harness.database,
          episodeStore: harness.store,
          accountScopeDigest: _accountScopeDigest,
          memoryV2Mode: () => FeatureRolloutMode.enforce,
        );
        addTearDown(foreign.deactivateAndDrain);
        final foreignScope = await harness.runFromMessage(
          wrongSessionId,
          () => foreign.write(proposal),
        );

        for (final result in <MemoryWriteResult>[
          missingScope,
          missingRecord,
          wrongSession,
          synthetic,
          foreignScope,
        ]) {
          expect(result.disposition, MemoryWriteDisposition.rejected);
          expect(result.reason, 'trusted_source_missing_or_invalid');
          expect(result.episode, isNull);
          expect(result.created, isFalse);
          expect(result.projected, isFalse);
        }
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          0,
        );
        expect(harness.linkedEpisodes, isEmpty);
      },
    );
  });

  group('MemoryWriteCoordinator transaction and projection receipts', () {
    test(
      'a before-commit failure rolls back every primary and governance row',
      () async {
        var failBeforeCommit = true;
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          faultInjector: (point, _) {
            if (point == MemoryWriteFaultPoint.beforeCommit &&
                failBeforeCommit) {
              failBeforeCommit = false;
              throw StateError('before-commit fault');
            }
          },
        );
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住回滚测试。');
        final draft = _event('回滚测试');

        await expectLater(
          harness.writeFromMessage(messageId, draft),
          throwsA(isA<StateError>()),
        );

        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          0,
        );
        expect(
          await MemoryGovernanceStores.episodeGovernance.count(
            harness.database,
          ),
          0,
        );
        expect(
          await MemoryGovernanceStores.episodeRecallIndex.count(
            harness.database,
          ),
          0,
        );
        expect(
          await MemoryGovernanceStores.exactDedup.count(harness.database),
          0,
        );
        expect(
          await MemoryGovernanceStores.semanticDedup.count(harness.database),
          0,
        );
        expect(await MemoryGovernanceStores.audit.count(harness.database), 0);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);

        final retry = await harness.writeFromMessage(messageId, draft);

        expect(retry.disposition, MemoryWriteDisposition.accepted);
        expect(retry.created, isTrue);
        expect(retry.projected, isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          1,
        );
        expect(
          await MemoryGovernanceStores.episodeRecallIndex.count(
            harness.database,
          ),
          1,
        );
        expect(harness.linkedEpisodes, <Episode>[retry.episode!]);
        expect(harness.projectedMilestones, <Episode>[retry.episode!]);
      },
    );

    test(
      'an after-commit failure is recovered by exact replay projections only',
      () async {
        var failAfterCommit = true;
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          faultInjector: (point, _) {
            if (point == MemoryWriteFaultPoint.afterCommit && failAfterCommit) {
              failAfterCommit = false;
              throw StateError('after-commit fault');
            }
          },
        );
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住写后恢复测试。');
        final draft = _event('写后恢复测试');

        await expectLater(
          harness.writeFromMessage(messageId, draft),
          throwsA(isA<StateError>()),
        );

        final committedRows = await MemoryGovernanceStores.episodes.find(
          harness.database,
        );
        expect(committedRows, hasLength(1));
        final committedId = committedRows.single.key;
        final beforeRetryGovernance = await MemoryGovernanceStores
            .episodeGovernance
            .record(committedId)
            .get(harness.database);
        expect(beforeRetryGovernance?['projectionLinkComplete'], isFalse);
        expect(beforeRetryGovernance?['projectionMilestoneComplete'], isFalse);
        expect(harness.linkedEpisodes, isEmpty);
        expect(harness.projectedMilestones, isEmpty);

        final retry = await harness.writeFromMessage(messageId, draft);

        expect(retry.disposition, MemoryWriteDisposition.duplicate);
        expect(retry.created, isFalse);
        expect(retry.projected, isTrue);
        expect(retry.episodeId, committedId);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          1,
        );
        expect(harness.linkedEpisodes, <Episode>[retry.episode!]);
        expect(harness.projectedMilestones, <Episode>[retry.episode!]);
        final afterRetryGovernance = await MemoryGovernanceStores
            .episodeGovernance
            .record(committedId)
            .get(harness.database);
        expect(afterRetryGovernance?['projectionLinkComplete'], isTrue);
        expect(afterRetryGovernance?['projectionMilestoneComplete'], isTrue);
      },
    );

    test(
      'link observes the committed Episode and governance receipt',
      () async {
        late _Harness harness;
        Map<String, Object?>? rowSeenByLink;
        Map<String, Object?>? governanceSeenByLink;
        harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          linkEpisode: (episode) async {
            rowSeenByLink = await MemoryGovernanceStores.episodes
                .record(episode.id!)
                .get(harness.database);
            governanceSeenByLink = await MemoryGovernanceStores
                .episodeGovernance
                .record(episode.id!)
                .get(harness.database);
            harness.linkedEpisodes.add(episode);
          },
        );
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住这条事务记录。');

        final result = await harness.writeFromMessage(
          messageId,
          _event('事务记录'),
        );

        expect(result.disposition, MemoryWriteDisposition.accepted);
        expect(rowSeenByLink, isNotNull);
        expect(rowSeenByLink?['what'], '这条事务记录。');
        expect(governanceSeenByLink?['episodeId'], result.episodeId);
        expect(governanceSeenByLink?['current'], isTrue);
        expect(governanceSeenByLink?['projectionLinkComplete'], isFalse);
        expect(harness.linkedEpisodes, <Episode>[result.episode!]);
      },
    );

    test(
      'an exact replay retries only a failed link without duplicating memory',
      () async {
        var linkAttempts = 0;
        var milestoneAttempts = 0;
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          linkEpisode: (_) async {
            linkAttempts++;
            if (linkAttempts == 1) throw StateError('temporary link failure');
          },
          projectMilestone: (_) async {
            milestoneAttempts++;
          },
        );
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住重试投影。');
        final draft = _event('重试投影');

        final first = await harness.writeFromMessage(messageId, draft);
        final retry = await harness.writeFromMessage(messageId, draft);

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(first.created, isTrue);
        expect(first.projected, isFalse);
        expect(retry.disposition, MemoryWriteDisposition.duplicate);
        expect(retry.created, isFalse);
        expect(retry.episodeId, first.episodeId);
        expect(retry.projected, isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          1,
        );
        expect(linkAttempts, 2);
        expect(milestoneAttempts, 1);
        final governance = await MemoryGovernanceStores.episodeGovernance
            .record(first.episodeId!)
            .get(harness.database);
        expect(governance?['projectionLinkComplete'], isTrue);
        expect(governance?['projectionMilestoneComplete'], isTrue);
      },
    );

    test(
      'claim projection links memory and records its milestone as safely skipped',
      () async {
        var milestoneAttempts = 0;
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          projectMilestone: (_) async {
            milestoneAttempts++;
          },
        );
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('请记住我最喜欢的饮料是乌龙茶。');

        final result = await harness.writeVerifiedFromMessage(
          messageId,
          MemoryWriteDraft.claim(
            slot: 'favorite_drink',
            value: '乌龙茶',
            summary: '用户最喜欢乌龙茶',
            when: _draftTime,
          ),
        );

        expect(result.disposition, MemoryWriteDisposition.accepted);
        expect(result.projected, isTrue);
        expect(harness.linkedEpisodes, <Episode>[result.episode!]);
        expect(milestoneAttempts, 0);
        final governance = await MemoryGovernanceStores.episodeGovernance
            .record(result.episodeId!)
            .get(harness.database);
        expect(governance?['projectionLinkComplete'], isTrue);
        expect(governance?['projectionMilestoneComplete'], isTrue);
        expect(
          governance?['projectionMilestoneSkippedReason'],
          'mutable_claim',
        );
      },
    );

    test(
      'verified host appends an accepted revision after the same automatic draft was pending',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final messageId = await harness.persistHumanMessage('我最喜欢的饮料是乌龙茶。');
        final draft = MemoryWriteDraft.claim(
          slot: 'favorite_drink',
          value: '乌龙茶',
          summary: '用户最喜欢乌龙茶',
          when: _draftTime,
        );

        final pending = await harness.writeFromMessage(messageId, draft);
        final accepted = await harness.runFromMessage(
          messageId,
          () => harness.coordinator.write(
            draft,
            authority: MemoryWriteAuthority.verifiedHost,
          ),
        );

        expect(pending.disposition, MemoryWriteDisposition.quarantined);
        expect(pending.episode!.reviewState, EpisodeReviewState.pending);
        expect(accepted.disposition, MemoryWriteDisposition.accepted);
        expect(accepted.created, isTrue);
        expect(accepted.projected, isTrue);
        expect(accepted.episodeId, isNot(pending.episodeId));
        expect(accepted.episode!.reviewState, EpisodeReviewState.accepted);
        expect(accepted.episode!.revision, 2);
        expect(accepted.episode!.supersedesId, pending.episodeId);
        expect(await harness.store.isRecallEligible(pending.episode!), isFalse);
        expect(await harness.store.isRecallEligible(accepted.episode!), isTrue);
        expect(harness.linkedEpisodes, <Episode>[accepted.episode!]);
        expect(harness.projectedMilestones, isEmpty);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );
      },
    );

    test(
      'deactivate drains every admitted writer and rejects later admission',
      () async {
        final firstWriterEntered = Completer<void>();
        final releaseFirstWriter = Completer<void>();
        var shouldBlock = true;
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          faultInjector: (point, _) async {
            if (point != MemoryWriteFaultPoint.beforeCommit || !shouldBlock) {
              return;
            }
            shouldBlock = false;
            firstWriterEntered.complete();
            await releaseFirstWriter.future;
          },
        );
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage('请记住第一条。');
        final secondMessage = await harness.persistHumanMessage('请记住第二条。');

        final firstWrite = harness.writeFromMessage(
          firstMessage,
          _event('第一条'),
        );
        await firstWriterEntered.future;
        final secondWrite = harness.writeFromMessage(
          secondMessage,
          _event('第二条'),
        );
        final drain = harness.coordinator.deactivateAndDrain();
        releaseFirstWriter.complete();

        final first = await firstWrite;
        final second = await secondWrite;
        await drain;

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(second.disposition, MemoryWriteDisposition.accepted);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );
        await expectLater(
          harness.writeFromMessage(firstMessage, _event('不应入队')),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'accepted claim conflicts append a revision and supersede the old head',
      () async {
        final removedEpisodeIds = <int>[];
        final harness = await _Harness.create(
          FeatureRolloutMode.enforce,
          removeEpisodeLinks: (episodeId) async {
            removedEpisodeIds.add(episodeId);
          },
        );
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage(
          '请记住我最喜欢的颜色是蓝色。',
        );
        final first = await harness.writeVerifiedFromMessage(
          firstMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '蓝色',
            summary: '用户最喜欢蓝色',
            when: _draftTime,
          ),
        );
        expect(
          (await harness.store.recallEligibleRecent(
            limit: 5,
          )).map((episode) => episode.id),
          <int?>[first.episodeId],
        );
        final secondMessage = await harness.persistHumanMessage(
          '请记住我现在最喜欢的颜色是绿色。',
          timestamp: _messageTime.add(const Duration(days: 1)),
        );
        final second = await harness.writeVerifiedFromMessage(
          secondMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '绿色',
            summary: '用户最喜欢绿色',
            when: _draftTime.add(const Duration(days: 1)),
          ),
        );

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(first.episode!.revision, 1);
        expect(first.episode!.supersedesId, isNull);
        expect(second.disposition, MemoryWriteDisposition.accepted);
        expect(second.episode!.revision, 2);
        expect(second.episode!.supersedesId, first.episodeId);
        expect(second.episode!.contradictionIds, <int>[first.episodeId!]);
        expect(await harness.store.isRecallEligible(first.episode!), isFalse);
        expect(await harness.store.isRecallEligible(second.episode!), isTrue);
        expect(
          (await harness.store.recallEligibleRecent(
            limit: 5,
          )).map((episode) => episode.id),
          <int?>[second.episodeId],
        );
        expect(removedEpisodeIds, <int>[first.episodeId!]);
        expect(
          (await MemoryGovernanceStores.episodeRecallIndex.find(
            harness.database,
          )).map((record) => record.key),
          <int>[second.episodeId!],
        );
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );

        final firstGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(first.episodeId!)
            .get(harness.database);
        final secondGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(second.episodeId!)
            .get(harness.database);
        expect(firstGovernance?['current'], isFalse);
        expect(secondGovernance?['current'], isTrue);
      },
    );

    test(
      'same-value claim summaries append one current revision instead of leaving two heads',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage(
          '请记住我最喜欢的饮料是乌龙茶。',
        );
        final first = await harness.writeVerifiedFromMessage(
          firstMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_drink',
            value: '乌龙茶',
            summary: '用户最喜欢乌龙茶',
            when: _draftTime,
          ),
        );
        final secondMessage = await harness.persistHumanMessage(
          '请记住乌龙茶是我最喜欢的茶饮。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );
        final second = await harness.writeVerifiedFromMessage(
          secondMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_drink',
            value: '乌龙茶',
            summary: '乌龙茶是用户最喜欢的茶饮',
            when: _draftTime.add(const Duration(minutes: 1)),
          ),
        );

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(first.episode!.revision, 1);
        expect(second.disposition, MemoryWriteDisposition.accepted);
        expect(second.created, isTrue);
        expect(second.episodeId, isNot(first.episodeId));
        expect(second.episode!.revision, 2);
        expect(second.episode!.supersedesId, first.episodeId);
        expect(second.episode!.contradictionIds, isEmpty);
        expect(await harness.store.isRecallEligible(first.episode!), isFalse);
        expect(await harness.store.isRecallEligible(second.episode!), isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );

        final firstGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(first.episodeId!)
            .get(harness.database);
        final secondGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(second.episodeId!)
            .get(harness.database);
        expect(firstGovernance?['current'], isFalse);
        expect(secondGovernance?['current'], isTrue);
      },
    );

    test(
      'accepted A-B-A claims create revision three instead of deduplicating an old value',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage(
          '请记住我最喜欢的颜色是蓝色。',
        );
        final first = await harness.writeVerifiedFromMessage(
          firstMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '蓝色',
            summary: '用户最喜欢蓝色',
            when: _draftTime,
          ),
        );
        final secondMessage = await harness.persistHumanMessage(
          '请记住我现在最喜欢的颜色是绿色。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );
        final second = await harness.writeVerifiedFromMessage(
          secondMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '绿色',
            summary: '用户最喜欢绿色',
            when: _draftTime.add(const Duration(minutes: 1)),
          ),
        );
        final thirdMessage = await harness.persistHumanMessage(
          '请记住我最喜欢蓝色。',
          timestamp: _messageTime.add(const Duration(minutes: 2)),
        );
        final third = await harness.writeVerifiedFromMessage(
          thirdMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '蓝色',
            summary: '用户最喜欢蓝色',
            when: _draftTime.add(const Duration(minutes: 2)),
          ),
        );

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(second.disposition, MemoryWriteDisposition.accepted);
        expect(third.disposition, MemoryWriteDisposition.accepted);
        expect(third.created, isTrue);
        expect(third.episodeId, isNot(first.episodeId));
        expect(third.episode!.revision, 3);
        expect(third.episode!.supersedesId, second.episodeId);
        expect(third.episode!.contradictionIds, <int>[second.episodeId!]);
        expect(await harness.store.isRecallEligible(first.episode!), isFalse);
        expect(await harness.store.isRecallEligible(second.episode!), isFalse);
        expect(await harness.store.isRecallEligible(third.episode!), isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          3,
        );

        final firstGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(first.episodeId!)
            .get(harness.database);
        final secondGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(second.episodeId!)
            .get(harness.database);
        final thirdGovernance = await MemoryGovernanceStores.episodeGovernance
            .record(third.episodeId!)
            .get(harness.database);
        expect(firstGovernance?['current'], isFalse);
        expect(secondGovernance?['current'], isFalse);
        expect(thirdGovernance?['current'], isTrue);
      },
    );

    test(
      'an exact replay of a superseded claim cannot restore the stale value',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final firstMessage = await harness.persistHumanMessage(
          '请记住我最喜欢的颜色是蓝色。',
        );
        final firstDraft = MemoryWriteDraft.claim(
          slot: 'favorite_color',
          value: '蓝色',
          summary: '用户最喜欢蓝色',
          when: _draftTime,
        );
        final first = await harness.writeVerifiedFromMessage(
          firstMessage,
          firstDraft,
        );
        final secondMessage = await harness.persistHumanMessage(
          '请记住我现在最喜欢的颜色是绿色。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );
        final second = await harness.writeVerifiedFromMessage(
          secondMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '绿色',
            summary: '用户最喜欢绿色',
            when: _draftTime.add(const Duration(minutes: 1)),
          ),
        );

        final replay = await harness.writeVerifiedFromMessage(
          firstMessage,
          firstDraft,
        );

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(second.disposition, MemoryWriteDisposition.accepted);
        expect(replay.disposition, MemoryWriteDisposition.duplicate);
        expect(replay.created, isFalse);
        expect(replay.episodeId, first.episodeId);
        expect(await harness.store.isRecallEligible(first.episode!), isFalse);
        expect(await harness.store.isRecallEligible(second.episode!), isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );
        final head = await MemoryGovernanceStores.claimHeads
            .record(
              sha256
                  .convert(utf8.encode('claim-slot-v1:favorite_color'))
                  .toString(),
            )
            .get(harness.database);
        expect(head?['episodeId'], second.episodeId);
        expect(head?['revision'], 2);
      },
    );

    test(
      'a superseded semantic alias cannot restore the stale claim on replay',
      () async {
        final harness = await _Harness.create(FeatureRolloutMode.enforce);
        addTearDown(harness.close);
        final blueDraft = MemoryWriteDraft.claim(
          slot: 'favorite_color',
          value: '蓝色',
          summary: '用户最喜欢蓝色',
          when: _draftTime,
        );
        final firstMessage = await harness.persistHumanMessage(
          '请记住我最喜欢的颜色是蓝色。',
        );
        final first = await harness.writeVerifiedFromMessage(
          firstMessage,
          blueDraft,
        );
        final aliasMessage = await harness.persistHumanMessage(
          '请记住我依然最喜欢蓝色。',
          timestamp: _messageTime.add(const Duration(minutes: 1)),
        );
        final alias = await harness.writeVerifiedFromMessage(
          aliasMessage,
          blueDraft,
        );
        final greenMessage = await harness.persistHumanMessage(
          '请记住我现在最喜欢的颜色是绿色。',
          timestamp: _messageTime.add(const Duration(minutes: 2)),
        );
        final green = await harness.writeVerifiedFromMessage(
          greenMessage,
          MemoryWriteDraft.claim(
            slot: 'favorite_color',
            value: '绿色',
            summary: '用户最喜欢绿色',
            when: _draftTime.add(const Duration(minutes: 2)),
          ),
        );

        final replay = await harness.writeVerifiedFromMessage(
          aliasMessage,
          blueDraft,
        );

        expect(first.disposition, MemoryWriteDisposition.accepted);
        expect(alias.disposition, MemoryWriteDisposition.duplicate);
        expect(alias.episodeId, first.episodeId);
        expect(green.disposition, MemoryWriteDisposition.accepted);
        expect(replay.disposition, MemoryWriteDisposition.duplicate);
        expect(replay.created, isFalse);
        expect(replay.episodeId, first.episodeId);
        expect(await harness.store.isRecallEligible(first.episode!), isFalse);
        expect(await harness.store.isRecallEligible(green.episode!), isTrue);
        expect(
          await MemoryGovernanceStores.episodes.count(harness.database),
          2,
        );
        final head = await MemoryGovernanceStores.claimHeads
            .record(
              sha256
                  .convert(utf8.encode('claim-slot-v1:favorite_color'))
                  .toString(),
            )
            .get(harness.database);
        expect(head?['episodeId'], green.episodeId);
        expect(head?['revision'], 2);
      },
    );
  });

  test(
    'off and shadow preserve legacy writes and projections without a source',
    () async {
      for (final mode in <FeatureRolloutMode>[
        FeatureRolloutMode.off,
        FeatureRolloutMode.shadow,
      ]) {
        final harness = await _Harness.create(mode);
        addTearDown(harness.close);

        final result = await harness.coordinator.write(
          _event('legacy-${mode.name}'),
        );

        expect(
          result.disposition,
          mode == FeatureRolloutMode.off
              ? MemoryWriteDisposition.legacy
              : MemoryWriteDisposition.shadow,
        );
        expect(result.created, isTrue);
        expect(result.projected, isTrue);
        expect(result.episodeId, isNotNull);
        expect(harness.linkedEpisodes, <Episode>[result.episode!]);
        expect(harness.projectedMilestones, <Episode>[result.episode!]);
        final row = await MemoryGovernanceStores.episodes
            .record(result.episodeId!)
            .get(harness.database);
        expect(row, isNot(contains('schemaVersion')));
        expect(row, isNot(contains('sourceRefs')));
        expect(
          await MemoryGovernanceStores.episodeGovernance
              .record(result.episodeId!)
              .get(harness.database),
          isNull,
        );
        final audits = await MemoryGovernanceStores.audit.find(
          harness.database,
        );
        if (mode == FeatureRolloutMode.off) {
          expect(audits, isEmpty);
        } else {
          expect(audits, hasLength(1));
          expect(audits.single.value['mode'], FeatureRolloutMode.shadow.name);
          expect(
            audits.single.value['disposition'],
            MemoryWriteDisposition.rejected.name,
          );
          expect(
            audits.single.value['reason'],
            'trusted_source_missing_or_invalid',
          );
        }
      }
    },
  );

  test('shadow sidecar failures never alter the legacy write result', () async {
    for (final faultPoint in <MemoryWriteFaultPoint>[
      MemoryWriteFaultPoint.shadowEvaluation,
      MemoryWriteFaultPoint.shadowAudit,
    ]) {
      final harness = await _Harness.create(
        FeatureRolloutMode.shadow,
        faultInjector: (point, _) {
          if (point == faultPoint) throw StateError('shadow sidecar fault');
        },
      );
      addTearDown(harness.close);

      final result = await harness.coordinator.write(
        _event('shadow-sidecar-${faultPoint.name}'),
      );

      expect(result.disposition, MemoryWriteDisposition.shadow);
      expect(result.created, isTrue);
      expect(result.projected, isTrue);
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
      final row = await MemoryGovernanceStores.episodes
          .record(result.episodeId!)
          .get(harness.database);
      expect(row, isNot(contains('schemaVersion')));
      expect(row, isNot(contains('sourceRefs')));
      expect(await MemoryGovernanceStores.audit.count(harness.database), 0);
      expect(harness.linkedEpisodes, <Episode>[result.episode!]);
      expect(harness.projectedMilestones, <Episode>[result.episode!]);
    }
  });

  test(
    'a shadow write keeps its captured legacy codec when rollout changes',
    () async {
      var mode = FeatureRolloutMode.shadow;
      final harness = await _Harness.create(
        mode,
        modeProvider: () => mode,
        faultInjector: (point, _) {
          if (point == MemoryWriteFaultPoint.shadowEvaluation) {
            mode = FeatureRolloutMode.enforce;
          }
        },
      );
      addTearDown(harness.close);

      final result = await harness.coordinator.write(_event('rollout-race'));

      expect(mode, FeatureRolloutMode.enforce);
      expect(result.disposition, MemoryWriteDisposition.shadow);
      expect(result.projected, isTrue);
      final row = await MemoryGovernanceStores.episodes
          .record(result.episodeId!)
          .get(harness.database);
      expect(row, isNot(contains('schemaVersion')));
      expect(row, isNot(contains('sourceRefs')));
      expect(
        await MemoryGovernanceStores.episodeGovernance
            .record(result.episodeId!)
            .get(harness.database),
        isNull,
      );
      final audits = await MemoryGovernanceStores.audit.find(harness.database);
      expect(audits, hasLength(1));
      expect(audits.single.value['mode'], FeatureRolloutMode.shadow.name);
      expect(harness.linkedEpisodes, <Episode>[result.episode!]);
      expect(harness.projectedMilestones, <Episode>[result.episode!]);
    },
  );

  test(
    'an admitted enforce write cannot downgrade after its source scope expires',
    () async {
      var mode = FeatureRolloutMode.enforce;
      var blockFirstWrite = true;
      final firstWriteReachedCommit = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final harness = await _Harness.create(
        mode,
        modeProvider: () => mode,
        faultInjector: (point, _) async {
          if (point == MemoryWriteFaultPoint.beforeCommit && blockFirstWrite) {
            blockFirstWrite = false;
            firstWriteReachedCommit.complete();
            await releaseFirstWrite.future;
          }
        },
      );
      addTearDown(harness.close);
      addTearDown(() {
        if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete();
      });
      final messageId = await harness.persistHumanMessage('请记住排队写入一和排队写入二。');
      late final Future<MemoryWriteResult> firstWrite;
      late final Future<MemoryWriteResult> queuedWrite;

      await harness.coordinator.runWithPersistedChatSource(
        messageRecordId: messageId,
        sessionId: 'self',
        agentId: 'agent-a',
        operation: () async {
          firstWrite = harness.coordinator.write(_event('排队写入一'));
          await firstWriteReachedCommit.future;
          queuedWrite = harness.coordinator.write(_event('排队写入二'));
        },
      );
      mode = FeatureRolloutMode.off;
      releaseFirstWrite.complete();

      final first = await firstWrite;
      final queued = await queuedWrite;

      expect(first.disposition, MemoryWriteDisposition.accepted);
      expect(queued.disposition, MemoryWriteDisposition.rejected);
      expect(queued.reason, 'trusted_source_missing_or_invalid');
      expect(queued.created, isFalse);
      expect(await MemoryGovernanceStores.episodes.count(harness.database), 1);
      final rows = await MemoryGovernanceStores.episodes.find(harness.database);
      expect(rows.single.value['schemaVersion'], 2);
    },
  );
}

const String _accountScopeDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final DateTime _messageTime = DateTime.utc(2026, 8, 29, 10);
final DateTime _draftTime = DateTime.utc(2026, 8, 28, 16);
var _databaseSequence = 0;

MemoryWriteDraft _event(String what, {String? emotion}) =>
    MemoryWriteDraft.event(what: what, when: _draftTime, emotion: emotion);

final class _Harness {
  _Harness._({
    required this.database,
    required this.store,
    required this.coordinator,
  });

  final Database database;
  final EpisodeStore store;
  final MemoryWriteCoordinator coordinator;
  final List<Episode> linkedEpisodes = <Episode>[];
  final List<Episode> projectedMilestones = <Episode>[];

  static Future<_Harness> create(
    FeatureRolloutMode mode, {
    FeatureRolloutMode Function()? modeProvider,
    Future<void> Function(Episode episode)? linkEpisode,
    Future<void> Function(int episodeId)? removeEpisodeLinks,
    Future<void> Function(Episode episode)? projectMilestone,
    MemoryWriteFaultInjector? faultInjector,
  }) async {
    final effectiveMode = modeProvider ?? () => mode;
    final database = await databaseFactoryMemory.openDatabase(
      'memory-write-coordinator-${_databaseSequence++}.db',
    );
    final store = EpisodeStore(
      database: database,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: effectiveMode,
      clock: () => _messageTime,
    );
    late _Harness harness;
    final coordinator = MemoryWriteCoordinator(
      database: database,
      episodeStore: store,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: effectiveMode,
      clock: () => _messageTime,
      linkEpisode:
          linkEpisode ??
          (episode) async {
            harness.linkedEpisodes.add(episode);
          },
      removeEpisodeLinks: removeEpisodeLinks,
      projectMilestone:
          projectMilestone ??
          (episode) async {
            harness.projectedMilestones.add(episode);
          },
      faultInjector: faultInjector,
    );
    harness = _Harness._(
      database: database,
      store: store,
      coordinator: coordinator,
    );
    return harness;
  }

  Future<int> persistHumanMessage(String content, {DateTime? timestamp}) =>
      persistMessage(
        content: content,
        timestamp: timestamp ?? _messageTime,
        isUserMessage: true,
        origin: ChatMessageTurnOrigins.user,
      );

  Future<int> persistMessage({
    required String content,
    DateTime? timestamp,
    required bool isUserMessage,
    required String origin,
  }) => MemoryGovernanceStores.chatMessages.add(
    database,
    ChatMessage(
      sessionId: 'self',
      senderId: isUserMessage ? 'user' : 'agent-a',
      receiverId: isUserMessage ? 'agent-a' : 'user',
      content: content,
      timestamp: timestamp ?? _messageTime,
      isUserMessage: isUserMessage,
      turnOrigin: origin,
    ).toJson(),
  );

  Future<T> runFromMessage<T>(
    int messageRecordId,
    Future<T> Function() operation,
  ) => coordinator.runWithPersistedChatSource(
    messageRecordId: messageRecordId,
    sessionId: 'self',
    agentId: 'agent-a',
    operation: operation,
  );

  Future<MemoryWriteResult> writeFromMessage(
    int messageRecordId,
    MemoryWriteDraft draft,
  ) => runFromMessage(messageRecordId, () => coordinator.write(draft));

  Future<MemoryWriteResult> writeVerifiedFromMessage(
    int messageRecordId,
    MemoryWriteDraft draft,
  ) => runFromMessage(
    messageRecordId,
    () =>
        coordinator.write(draft, authority: MemoryWriteAuthority.verifiedHost),
  );

  Future<void> close() async {
    await coordinator.deactivateAndDrain();
    await store.deactivateAndDrain();
    coordinator.closeLifecycle();
    store.closeLifecycle();
    await database.close();
  }
}

final class _RecordingEmbeddingService extends EmbeddingService {
  int calls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<List<double>?> embed(String text) async {
    calls++;
    return const <double>[1];
  }
}
