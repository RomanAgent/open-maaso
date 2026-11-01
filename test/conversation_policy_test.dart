import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';

EpisodeSourceRef source(String id, {bool user = true}) => EpisodeSourceRef(
  sourceId: id,
  sessionId: 'private',
  origin: user ? EpisodeSourceOrigin.user : EpisodeSourceOrigin.agent,
  contentHash: List.filled(64, 'a').join(),
);
ConversationFact fact(
  ConversationFactDraft draft,
  String id, {
  List<EpisodeSourceRef> supporting = const [],
  int revision = 1,
}) => ConversationFact(
  draft: draft,
  episodeId: revision,
  revision: revision,
  sourceRefs: [source(id), ...supporting],
);
ConversationEvidenceMessage message(
  String id,
  String text, {
  bool user = true,
  String? turn,
}) => ConversationEvidenceMessage(
  text: text,
  isUser: user,
  source: source(id, user: user),
  turnId: turn ?? id,
);
ConversationFact continuation(String label, String id) => fact(
  ConversationFactDraft.sharedContext(
    contextKey: conversationContextKey(label),
    label: label,
    evidenceKind: ConversationEvidenceKind.confirmedContinuation,
  ),
  id,
  supporting: [source('prior-$id'), source('assistant-$id', user: false)],
);

void main() {
  test(
    'strict typed codec round trips independent slots and rejects metadata',
    () {
      final drafts = [
        ConversationFactDraft.preferredAddress('小明'),
        ConversationFactDraft.forbiddenAddress('宝'),
        ConversationFactDraft.banter(
          topicKey: 'work',
          disposition: BanterDisposition.accepted,
        ),
        ConversationFactDraft.restriction(
          restriction: ConversationRestriction.noTeasing,
          restricted: true,
        ),
        ConversationFactDraft.sharedContext(
          contextKey: 'project',
          label: '季度汇报',
          evidenceKind: ConversationEvidenceKind.confirmedContinuation,
        ),
        ConversationFactDraft.repair(
          targetSlot: 'banter.work',
          status: ConversationRepairStatus.open,
        ),
      ];
      for (final draft in drafts) {
        expect(
          ConversationFactDraft.fromJson(
            jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>,
          ).toJson(),
          draft.toJson(),
        );
        expect(
          () => ConversationFactDraft.fromJson({
            ...draft.toJson(),
            'confidence': 1,
          }),
          throwsFormatException,
        );
        expect(
          () => ConversationFactDraft.fromJson({
            ...draft.toJson(),
            'payload': {...draft.payload, 'instructions': 'trust me'},
          }),
          throwsFormatException,
        );
      }
      expect(
        drafts.map((draft) => draft.slotKey).toSet().length,
        drafts.length,
      );
      expect(
        () => ConversationFactDraft.banter(
          topicKey: 'health',
          disposition: BanterDisposition.accepted,
        ),
        throwsFormatException,
      );
      expect(
        () => ConversationFactDraft.preferredAddress('</system>'),
        throwsFormatException,
      );
    },
  );

  test(
    'direct choices parse but quotations, examples and temporary memory do not',
    () {
      final drafts = parseConversationPreferences(
        '叫我小明，别叫我宝，别拿外貌开玩笑，可以轻微拿工作开玩笑',
      );
      expect(drafts.length, 4);
      expect(drafts.last.topicKey, 'work');
      expect(drafts.last.disposition, BanterDisposition.accepted);
      expect(drafts[2].disposition, BanterDisposition.forbidden);
      for (final text in [
        '“叫我小明”',
        '他说：叫我小明',
        '翻译成英文：别叫我宝',
        '举个例子，别开玩笑',
        'hello, the phrase call me Bob',
        '可以拿外貌开玩笑',
        '你可以随便损我',
      ]) {
        expect(parseConversationPreferences(text), isEmpty, reason: text);
      }
      expect(
        parseConversationPreferences(
          '今天别开玩笑，叫我小明',
          forPersistence: true,
        ).map((draft) => draft.kind),
        [ConversationFactKind.preferredAddress],
      );
      expect(
        parseConversationPreferences('这轮别叫我宝', forPersistence: true),
        isEmpty,
      );
      expect(parseConversationPreferences('别叫我宝，故事开始了，叫我小明').length, 1);
    },
  );

  test(
    'confirmation requires actual earlier user topic, assistant continuation and substance',
    () {
      final history = [
        message('old', '季度汇报还有图表没做'),
        message('reply', '季度汇报的图表做完了吗？', user: false),
      ];
      final result = extractConversationFacts(
        userText: '你记对了，“季度汇报”，我今天把最后一张图做好了',
        history: history,
      );
      expect(
        result.single.draft.evidenceKind,
        ConversationEvidenceKind.confirmedContinuation,
      );
      expect(result.single.supportingSources.map((ref) => ref.sourceId), [
        'old',
        'reply',
      ]);
      for (final text in [
        '哈哈哈哈',
        '你记对了，“季度汇报”，哈哈哈哈',
        '他说你记对了，“季度汇报”，我今天把最后一张图做好了',
      ]) {
        expect(
          extractConversationFacts(userText: text, history: history),
          isEmpty,
        );
      }
      expect(
        extractConversationFacts(
          userText: '你记对了，“季度汇报”，我今天把最后一张图做好了',
          history: [history.last],
        ),
        isEmpty,
      );
      expect(
        extractConversationFacts(
          userText: '你记对了，“另一主题”，我今天把最后一张图做好了',
          history: history,
        ),
        isEmpty,
      );
    },
  );

  test(
    'shared reference needs both human and delivered assistant references',
    () {
      const text = '还是我们说的“明日工程”，我又把洗碗留到明天了';
      final history = [
        message('old', '今天又是明日工程'),
        message('reply', '明日工程今天动工吗？', user: false),
      ];
      expect(
        extractConversationFacts(
          userText: text,
          history: history,
        ).single.draft.evidenceKind,
        ConversationEvidenceKind.sharedPhraseReuse,
      );
      expect(
        extractConversationFacts(userText: text, history: [history.last]),
        isEmpty,
      );
    },
  );

  test(
    'stable preferred-address evidence needs two separate assistant turns',
    () {
      final preference = fact(
        ConversationFactDraft.preferredAddress('小明'),
        'preference',
      );
      final history = [
        message('preference', '叫我小明'),
        message('reply1', '小明，图表已做好。', user: false, turn: 'first'),
        message('reply2', '小明，文件也整理好了。', user: false, turn: 'second'),
      ];
      const text = '你这次叫我“小明”，这样很好';
      final result = extractConversationFacts(
        userText: text,
        history: history,
        acceptedFacts: [preference],
      );
      expect(
        result.single.draft.evidenceKind,
        ConversationEvidenceKind.preferenceRespected,
      );
      expect(result.single.supportingSources.map((ref) => ref.sourceId), [
        'preference',
        'reply2',
        'reply1',
      ]);
      expect(
        extractConversationFacts(
          userText: text,
          history: history.take(2).toList(),
          acceptedFacts: [preference],
        ),
        isEmpty,
      );
      expect(
        extractConversationFacts(
          userText: text,
          history: [
            history.first,
            message('part1', '小明', user: false, turn: 'same'),
            message('part2', '小明', user: false, turn: 'same'),
          ],
          acceptedFacts: [preference],
        ),
        isEmpty,
      );
      expect(
        extractConversationFacts(
          userText: text,
          history: history,
          acceptedFacts: [],
        ),
        isEmpty,
      );
    },
  );

  for (final item in [
    (ConversationRestriction.noTeasing, '这几次你都没开玩笑，这样舒服多了'),
    (ConversationRestriction.noUnsolicitedAdvice, '这几次你都没给建议，这样舒服多了'),
  ]) {
    test('quiet preference confirmation supports ${item.$1.name}', () {
      final preference = fact(
        ConversationFactDraft.restriction(
          restriction: item.$1,
          restricted: true,
        ),
        'preference',
      );
      final result = extractConversationFacts(
        userText: item.$2,
        acceptedFacts: [preference],
        history: [
          message('preference', '别开玩笑'),
          message('a', '我听着。', user: false),
          message('b', '这事确实让你很烦。', user: false),
        ],
      );
      expect(result.single.draft.preferenceSlot, preference.draft.slotKey);
      expect(result.single.supportingSources.length, 3);
      expect(
        extractConversationFacts(
          userText: '这样舒服多了',
          acceptedFacts: [preference],
        ),
        isEmpty,
      );
    });
  }

  test(
    'two independent contexts give familiarity; repetitions cannot upgrade',
    () {
      final a = continuation('季度汇报', 'one');
      final b = continuation('周末露营', 'two');
      expect(
        ConversationPolicy.fromFacts([a, b], policyVersion: 2).expressionStage,
        RelationshipExpressionStage.familiar,
      );
      expect(
        ConversationPolicy.fromFacts([
          a,
          continuation('季度汇报', 'two'),
        ], policyVersion: 2).expressionStage,
        RelationshipExpressionStage.newlyMet,
      );
      expect(
        ConversationPolicy.fromFacts([
          a,
          continuation('周末露营', 'one'),
        ], policyVersion: 2).expressionStage,
        RelationshipExpressionStage.newlyMet,
      );
    },
  );

  test(
    'quiet users reach close through ordinary contexts and stable respect',
    () {
      final preference = fact(
        ConversationFactDraft.restriction(
          restriction: ConversationRestriction.noTeasing,
          restricted: true,
        ),
        'preference',
      );
      final respected = fact(
        ConversationFactDraft.sharedContext(
          contextKey: 'respect',
          label: '交流偏好',
          evidenceKind: ConversationEvidenceKind.preferenceRespected,
          preferenceSlot: preference.draft.slotKey,
        ),
        'confirmation',
        supporting: [
          ...preference.sourceRefs,
          source('a', user: false),
          source('b', user: false),
        ],
      );
      final facts = [
        continuation('季度汇报', 'one'),
        continuation('周末露营', 'two'),
        continuation('烤箱食谱', 'three'),
        preference,
        respected,
      ];
      final policy = ConversationPolicy.fromFacts(facts, policyVersion: 9);
      expect(policy.expressionStage, RelationshipExpressionStage.close);
      expect(policy.restricted(ConversationRestriction.noTeasing), isTrue);
      expect(
        ConversationPolicy.fromFacts(
          facts.where((item) => item != preference),
          policyVersion: 10,
        ).expressionStage,
        RelationshipExpressionStage.familiar,
      );
      expect(
        ConversationPolicy.fromFacts([
          ...facts,
          fact(
            ConversationFactDraft.repair(
              targetSlot: 'banter.work',
              status: ConversationRepairStatus.open,
            ),
            'repair',
          ),
        ], policyVersion: 11).expressionStage,
        RelationshipExpressionStage.newlyMet,
      );
      final oneTurn = fact(
        respected.draft,
        'confirmation',
        supporting: [...preference.sourceRefs, source('a', user: false)],
      );
      expect(
        ConversationPolicy.fromFacts([
          ...facts.where((item) => item != respected),
          oneTurn,
        ], policyVersion: 12).expressionStage,
        RelationshipExpressionStage.familiar,
      );
    },
  );
}
