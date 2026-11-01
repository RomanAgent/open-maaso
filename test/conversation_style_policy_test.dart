import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';

ConversationPolicy policy(
  List<ConversationFactDraft> drafts, {
  int version = 1,
}) => ConversationPolicy.fromFacts([
  for (var index = 0; index < drafts.length; index++)
    ConversationFact(
      draft: drafts[index],
      episodeId: index + 1,
      revision: 1,
      sourceRefs: [
        EpisodeSourceRef(
          sourceId: 'saved-$index',
          sessionId: 'private',
          origin: EpisodeSourceOrigin.user,
          contentHash: List.filled(64, 'a').join(),
        ),
      ],
    ),
], policyVersion: version);

void main() {
  test('revoking a release restores an independently sourced restriction', () {
    for (final factOnly in [false, true]) {
      final session = ConversationStyleSession();
      session.snapshot(
        isPrivate: true,
        currentUserText: '不要开玩笑',
        currentSourceId: 'restriction',
      );
      expect(
        session
            .snapshot(
              isPrivate: true,
              currentUserText: '可以开玩笑了',
              currentSourceId: 'release',
            )
            .noTeasing,
        isFalse,
      );
      if (factOnly) {
        session.invalidateFacts({
          'restriction.noTeasing': {'release'},
        });
      } else {
        session.invalidateSources({'release'});
      }
      expect(session.snapshot(isPrivate: true).noTeasing, isTrue);
    }
  });
  test('strict domain commands allow subsequent direct restrictions', () {
    final saved = policy([ConversationFactDraft.preferredAddress('宝')]);
    final style = ConversationStyleSession().snapshot(
      isPrivate: true,
      persistentPolicy: saved,
      currentUserText: '可以拿游戏开玩笑，别叫我宝',
      currentSourceId: 'topic-ban',
    );
    expect(style.preferredAddress, isNull);
    expect(style.forbiddenAddresses, contains('宝'));
    expect(style.banterBoundaries['gaming'], BanterDisposition.accepted);
    final repair = ConversationStyleSession().snapshot(
      isPrivate: true,
      currentUserText: '刚才拿游戏开玩笑过分了，今天别开玩笑',
      currentSourceId: 'repair',
    );
    expect(repair.repairRequired, isTrue);
    expect(repair.noTeasing, isTrue);
    final story = ConversationStyleSession().snapshot(
      isPrivate: true,
      currentUserText: '可以拿游戏开玩笑，故事开始了，别叫我宝',
    );
    expect(story.forbiddenAddresses, isEmpty);
  });
  test('legacy trusted history does not grant familiarity', () {
    final snapshot = ConversationStyleSession().snapshot(
      isPrivate: true,
      relationshipStage: RelationshipStage.trusted,
    );
    expect(snapshot.expressionStage, RelationshipExpressionStage.newlyMet);
  });
  test(
    'accepted policy is read separately; current corrections win immediately',
    () {
      final saved = policy([
        ConversationFactDraft.preferredAddress('小明'),
        ConversationFactDraft.forbiddenAddress('小李'),
      ], version: 7);
      final session = ConversationStyleSession();
      expect(
        session
            .snapshot(isPrivate: true, persistentPolicy: saved)
            .preferredAddress,
        '小明',
      );
      final corrected = session.snapshot(
        isPrivate: true,
        persistentPolicy: saved,
        currentUserText: '叫我小李',
        currentSourceId: 'new',
      );
      expect(corrected.preferredAddress, '小李');
      expect(corrected.forbiddenAddresses, isNot(contains('小李')));
      expect(corrected.policyVersion, 7);
      expect(saved.preferredAddress, '小明');
      session.invalidateSources({'new'});
      expect(
        session
            .snapshot(isPrivate: true, persistentPolicy: saved)
            .preferredAddress,
        '小明',
      );
      expect(
        ConversationStyleSession()
            .snapshot(
              isPrivate: true,
              persistentPolicy: saved,
              currentUserText: '别叫我小明',
              currentSourceId: 'ban',
            )
            .preferredAddress,
        isNull,
      );
    },
  );
  test(
    'last explicit address command wins and temporary choice does not erase ban',
    () {
      final session = ConversationStyleSession();
      var snapshot = session.snapshot(
        isPrivate: true,
        currentUserText: '叫我小明，别叫我小明',
        currentSourceId: 'one',
      );
      expect(snapshot.preferredAddress, isNull);
      expect(snapshot.forbiddenAddresses, contains('小明'));
      snapshot = session.snapshot(
        isPrivate: true,
        currentUserText: '这轮叫我小明',
        currentSourceId: 'two',
      );
      expect(snapshot.preferredAddress, '小明');
      snapshot = session.snapshot(isPrivate: true);
      expect(snapshot.preferredAddress, isNull);
      expect(snapshot.forbiddenAddresses, contains('小明'));
    },
  );
  test('same boundary keeps independent source contributions', () {
    final session = ConversationStyleSession();
    session.snapshot(
      isPrivate: true,
      currentUserText: '别叫我宝',
      currentSourceId: 'first',
    );
    session.snapshot(
      isPrivate: true,
      currentUserText: '别叫我宝',
      currentSourceId: 'second',
    );
    session.invalidateSources({'first'});
    expect(session.snapshot(isPrivate: true).forbiddenAddresses, contains('宝'));
    session.invalidateSources({'second'});
    expect(session.snapshot(isPrivate: true).forbiddenAddresses, isEmpty);
  });
  test(
    'reiterated preferred address has independent sources without revival',
    () {
      final session = ConversationStyleSession();
      session.snapshot(
        isPrivate: true,
        currentUserText: '叫我小明',
        currentSourceId: 'first',
      );
      session.snapshot(
        isPrivate: true,
        currentUserText: '叫我小明',
        currentSourceId: 'second',
      );
      session.invalidateSources({'first'});
      expect(session.snapshot(isPrivate: true).preferredAddress, '小明');
      session.invalidateSources({'second'});
      expect(session.snapshot(isPrivate: true).preferredAddress, isNull);
    },
  );
  test(
    'fact deletion removes matching slot only and preserves a newer source',
    () {
      final session = ConversationStyleSession();
      session.snapshot(
        isPrivate: true,
        currentUserText: '别叫我宝，别开玩笑',
        currentSourceId: 'both',
      );
      final addressSlot = ConversationFactDraft.forbiddenAddress('宝').slotKey;
      session.invalidateFacts({
        addressSlot: {'both'},
      });
      var snapshot = session.snapshot(isPrivate: true);
      expect(snapshot.forbiddenAddresses, isEmpty);
      expect(snapshot.noTeasing, isTrue);
      session.snapshot(
        isPrivate: true,
        currentUserText: '别开玩笑',
        currentSourceId: 'new',
      );
      final jokeSlot = ConversationFactDraft.restriction(
        restriction: ConversationRestriction.noTeasing,
        restricted: true,
      ).slotKey;
      session.invalidateFacts({
        jokeSlot: {'both'},
      });
      expect(session.snapshot(isPrivate: true).noTeasing, isTrue);
      session.invalidateFacts({
        jokeSlot: {'new'},
      });
      expect(session.snapshot(isPrivate: true).noTeasing, isFalse);
    },
  );
  test('removing durable policy does not revive a session copy', () {
    final session = ConversationStyleSession();
    final saved = policy([ConversationFactDraft.forbiddenAddress('宝')]);
    session.snapshot(
      isPrivate: true,
      persistentPolicy: saved,
      currentUserText: '今天别开玩笑',
      currentSourceId: 'today',
    );
    final after = session.snapshot(
      isPrivate: true,
      persistentPolicy: policy([], version: 2),
    );
    expect(after.forbiddenAddresses, isEmpty);
    expect(after.noTeasing, isTrue);
  });
  test('source lifetimes remain independent after source invalidation', () {
    final session = ConversationStyleSession();
    final day = DateTime(2026, 9, 15, 12);
    session.snapshot(
      isPrivate: true,
      currentUserText: '别叫我宝',
      currentSourceId: 'long',
      now: day,
    );
    session.snapshot(
      isPrivate: true,
      currentUserText: '今天别叫我宝',
      currentSourceId: 'short',
      now: day,
    );
    session.invalidateSources({'long'});
    expect(
      session.snapshot(isPrivate: true, now: day).forbiddenAddresses,
      contains('宝'),
    );
    expect(
      session
          .snapshot(isPrivate: true, now: day.add(const Duration(days: 1)))
          .forbiddenAddresses,
      isEmpty,
    );
  });
  test('public snapshot has no private state or version', () {
    final session = ConversationStyleSession();
    final saved = policy([
      ConversationFactDraft.preferredAddress('私昵称'),
      ConversationFactDraft.banter(
        topicKey: 'work',
        disposition: BanterDisposition.accepted,
      ),
    ]);
    final public = session.snapshot(
      isPrivate: false,
      persistentPolicy: saved,
      currentUserText: '别叫我宝',
      currentSourceId: 'public',
    );
    expect(public.preferredAddress, isNull);
    expect(public.forbiddenAddresses, isEmpty);
    expect(public.banterBoundaries, isEmpty);
    expect(public.sharedContexts, isEmpty);
    expect(public.policyVersion, 0);
    expect(session.snapshot(isPrivate: true).forbiddenAddresses, isEmpty);
  });
  test(
    'current topic ban overrides accepted light teasing, without blanket license',
    () {
      final saved = policy([
        ConversationFactDraft.banter(
          topicKey: 'work',
          disposition: BanterDisposition.accepted,
        ),
      ]);
      final session = ConversationStyleSession();
      final after = session.snapshot(
        isPrivate: true,
        persistentPolicy: saved,
        currentUserText: '别拿工作开玩笑',
        currentSourceId: 'ban',
      );
      expect(after.banterBoundaries['work'], BanterDisposition.forbidden);
      expect(after.banterBoundaries['health'], isNull);
      session.invalidateSources({'ban'});
      expect(
        session
            .snapshot(isPrivate: true, persistentPolicy: saved)
            .banterBoundaries['work'],
        BanterDisposition.accepted,
      );
    },
  );
}
