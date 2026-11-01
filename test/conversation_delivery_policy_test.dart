import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_delivery_policy.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';

void main() {
  const account =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  test(
    'explicit playful mode withdraws old approved teasing without changing evidence',
    () {
      final saved = ConversationPolicy.fromFacts([
        ConversationFact(
          draft: ConversationFactDraft.banter(
            topicKey: 'work',
            disposition: BanterDisposition.accepted,
          ),
          episodeId: 1,
          revision: 1,
          sourceRefs: [
            EpisodeSourceRef(
              sourceId: 'original',
              sessionId: 'self',
              origin: EpisodeSourceOrigin.user,
              contentHash: account,
            ),
          ],
        ),
      ], policyVersion: 1);
      final session = ConversationStyleSession();
      final defaultStyle = session.snapshot(
        isPrivate: true,
        persistentPolicy: saved,
        explicitPreferences: ConversationPreferenceSnapshot(
          accountScopeDigest: account,
        ),
      );
      expect(defaultStyle.banterBoundaries['work'], BanterDisposition.accepted);
      final withdrawn = session.snapshot(
        isPrivate: true,
        persistentPolicy: saved,
        explicitPreferences: ConversationPreferenceSnapshot(
          accountScopeDigest: account,
          revision: 1,
          humorStyleExplicit: true,
        ),
      );
      expect(
        withdrawn.banterBoundaries['work'],
        isNot(BanterDisposition.accepted),
      );
      expect(saved.banterBoundaries['work'], BanterDisposition.accepted);
    },
  );

  test('a temporary permission expires at the output boundary', () {
    final gate = ConversationTextGate(
      ConversationStyleSnapshot(
        isPrivate: true,
        validUntil: DateTime.now().subtract(const Duration(milliseconds: 1)),
      ),
    );
    expect(gate.allows('聊点轻松的。'), isFalse);
  });
  test(
    'new settings forbid teasing even after an older conversational release',
    () {
      final session = ConversationStyleSession();
      session.snapshot(
        isPrivate: true,
        currentUserText: '可以开玩笑了',
        explicitPreferences: ConversationPreferenceSnapshot(
          accountScopeDigest: account,
        ),
      );
      final changed = session.snapshot(
        isPrivate: true,
        explicitPreferences: ConversationPreferenceSnapshot(
          accountScopeDigest: account,
          revision: 1,
          banterBoundaries: {'general': BanterDisposition.forbidden},
        ),
      );
      expect(changed.noTeasing, isTrue);
      expect(changed.expressionStage, RelationshipExpressionStage.newlyMet);
    },
  );

  test(
    'current correction overrides a configured name without granting intimacy',
    () {
      final session = ConversationStyleSession();
      final settings = ConversationPreferenceSnapshot(
        accountScopeDigest: account,
        revision: 1,
        preferredAddress: '阿舟',
      );
      final style = session.snapshot(
        isPrivate: true,
        explicitPreferences: settings,
        currentUserText: '以后别叫我阿舟',
        currentSourceId: 'actual-user',
      );
      expect(style.preferredAddress, isNull);
      expect(style.forbiddenAddresses, contains('阿舟'));
      expect(style.expressionStage, RelationshipExpressionStage.newlyMet);
    },
  );
  test('a forbidden name split across model tokens never becomes visible', () {
    final buffer = ConversationSegmentBuffer(
      ConversationTextGate(
        ConversationStyleSnapshot(isPrivate: true, forbiddenAddresses: ['阿舟']),
      ),
    );
    expect(buffer.add('收到。阿'), ['收到。']);
    expect(buffer.add('舟，我们聊聊。'), isEmpty);
    expect(buffer.blocked, isTrue);
    expect(buffer.finish(), isEmpty);
  });

  test('Latin names are word bounded and case insensitive', () {
    final gate = ConversationTextGate(
      ConversationStyleSnapshot(isPrivate: true, forbiddenAddresses: ['Al']),
    );
    expect(gate.allows('also fine'), isTrue);
    expect(gate.allows('Hey, AL!'), isFalse);
  });

  test(
    'an exact repeated utterance is suppressed but its speech is allowed',
    () {
      final gate = ConversationTextGate(
        ConversationStyleSnapshot(isPrivate: true),
      );
      expect(gate.admit('收到。'), isTrue);
      expect(gate.allows('收到。'), isTrue);
      expect(gate.admit(' 收到。 '), isFalse);
    },
  );

  test('revoking a captured version drops the unsent tail', () {
    var current = true;
    final buffer = ConversationSegmentBuffer(
      ConversationTextGate(
        ConversationStyleSnapshot(
          isPrivate: true,
          deliveryGuard: () => current,
        ),
      ),
    );
    expect(buffer.add('第一句。还没说完'), ['第一句。']);
    current = false;
    expect(buffer.finish(), isEmpty);
    expect(buffer.blocked, isTrue);
  });

  test(
    'oversized incomplete output fails closed instead of splitting a name',
    () {
      final buffer = ConversationSegmentBuffer(ConversationTextGate(null));
      expect(buffer.add('a' * 4097), isEmpty);
      expect(buffer.blocked, isTrue);
    },
  );

  test('batch retains turn-only corrections from earlier original input', () {
    final style = ConversationStyleSession().snapshot(
      isPrivate: true,
      currentUserInputs: const [
        ConversationStyleInput('这次别开玩笑', sourceId: 'first'),
        ConversationStyleInput('以后叫我阿舟', sourceId: 'second'),
      ],
    );
    expect(style.noTeasing, isTrue);
    expect(style.preferredAddress, '阿舟');
  });

  test(
    'batch source deletion removes only the corresponding lasting lease',
    () {
      final session = ConversationStyleSession();
      session.snapshot(
        isPrivate: true,
        currentUserInputs: const [
          ConversationStyleInput('以后别叫我宝', sourceId: 'first'),
          ConversationStyleInput('以后不要主动给建议', sourceId: 'second'),
        ],
      );
      session.invalidateSources({'first'});
      final next = session.snapshot(isPrivate: true);
      expect(next.forbiddenAddresses, isEmpty);
      expect(next.noUnsolicitedAdvice, isTrue);
    },
  );

  test('later original input can forbid an earlier preferred name', () {
    final style = ConversationStyleSession().snapshot(
      isPrivate: true,
      currentUserInputs: const [
        ConversationStyleInput('以后叫我阿舟', sourceId: 'first'),
        ConversationStyleInput('以后别叫我阿舟', sourceId: 'second'),
      ],
    );
    expect(style.preferredAddress, isNull);
    expect(style.forbiddenAddresses, contains('阿舟'));
  });
}
