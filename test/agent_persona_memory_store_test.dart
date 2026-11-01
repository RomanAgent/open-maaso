import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/services/agent_persona_memory_store.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:sembast/sembast_memory.dart';

const _accountA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _accountB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _oldConversation = StoreRef<String, Map<String, Object?>>(
  'conversation_preferences.v1',
);
final _oldProactive = StoreRef<String, Map<String, Object?>>(
  'proactive_preferences.v1',
);
final _memories = StoreRef<String, Map<String, Object?>>(
  AgentPersonaMemoryStore.storeName,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  var sequence = 0;

  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'persona-memory-${sequence++}.db',
    );
  });
  tearDown(() => database.close());

  SembastConversationPreferenceStore conversation([String scope = _accountA]) =>
      SembastConversationPreferenceStore(database, accountScopeDigest: scope);
  SembastProactivePreferenceStore proactive([String scope = _accountA]) =>
      SembastProactivePreferenceStore(database, accountScopeDigest: scope);
  String memoryKey(AgentPersonaMemoryKind kind, [String scope = _accountA]) =>
      '$scope:self:${kind.name}';

  test(
    'legacy conversation choices move once and retain prompt authority',
    () async {
      final selected = ConversationPreferenceSnapshot(
        accountScopeDigest: _accountA,
        revision: 19,
        humorStyle: ConversationHumorStyle.subdued,
        humorStyleExplicit: true,
        preferredAddress: '小林',
        forbiddenAddresses: ['宝'],
        banterBoundaries: {'health': BanterDisposition.forbidden},
      );
      await _oldConversation
          .record(_accountA)
          .put(database.raw, selected.toStorageJson());
      final service = await ConversationPreferenceService(
        store: conversation(),
        accountScopeDigest: _accountA,
      ).init();
      addTearDown(service.deactivateAndDrain);
      expect(
        service.effectiveSnapshot.toStorageJson(),
        selected.toStorageJson(),
      );
      expect(
        await _oldConversation.record(_accountA).get(database.raw),
        isNull,
      );
      final row = (await _memories
          .record(memoryKey(AgentPersonaMemoryKind.conversationStyle))
          .get(database.raw))!;
      expect(row['source'], 'user_choice');
      expect(row['agentId'], 'self');
      expect(row['accountScopeDigest'], _accountA);
      expect(row['payload'], selected.toStorageJson());
      final style = ConversationStyleSession().snapshot(
        isPrivate: true,
        explicitPreferences: service.effectiveSnapshot,
      );
      expect(style.preferredAddress, '小林');
      expect(style.noTeasing, isTrue);
      expect(style.forbiddenAddresses, ['宝']);
      expect(style.banterBoundaries['health'], BanterDisposition.forbidden);
      final public = ConversationStyleSession().snapshot(
        isPrivate: false,
        explicitPreferences: service.effectiveSnapshot,
      );
      expect(public.preferredAddress, isNull);
      expect(public.banterBoundaries, isEmpty);
      await service.setPreferredAddress('Alex');
      final restored = await ConversationPreferenceService(
        store: conversation(),
        accountScopeDigest: _accountA,
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.effectiveSnapshot.preferredAddress, 'Alex');
      expect(restored.revision, 20);
      expect(
        await _oldConversation.record(_accountA).get(database.raw),
        isNull,
      );
    },
  );

  test(
    'current persona memory wins over a recreated stale legacy row',
    () async {
      final latest = ConversationPreferenceSnapshot(
        accountScopeDigest: _accountA,
        revision: 7,
        preferredAddress: 'Alex',
      );
      await conversation().write(latest);
      await _oldConversation
          .record(_accountA)
          .put(
            database.raw,
            ConversationPreferenceSnapshot(
              accountScopeDigest: _accountA,
              revision: 99,
              preferredAddress: '旧称呼',
            ).toStorageJson(),
          );
      expect(await conversation().read(), latest.toStorageJson());
      expect(
        await _oldConversation.record(_accountA).get(database.raw),
        isNull,
      );
    },
  );

  test(
    'conversation accounts and both memory kinds remain independent',
    () async {
      await conversation().write(
        ConversationPreferenceSnapshot(
          accountScopeDigest: _accountA,
          preferredAddress: 'Alice',
        ),
      );
      await conversation(_accountB).write(
        ConversationPreferenceSnapshot(
          accountScopeDigest: _accountB,
          preferredAddress: 'Bob',
        ),
      );
      await proactive().write(
        const ProactivePreferenceSnapshot.defaults(
          generation: 1,
        ).copyWith(hardMuted: true),
      );
      await proactive(_accountB).write(
        const ProactivePreferenceSnapshot.defaults(
          generation: 1,
        ).copyWith(quietStartMinutes: 23 * 60),
      );
      expect((await conversation().read())!['preferredAddress'], 'Alice');
      expect(
        (await conversation(_accountB).read())!['preferredAddress'],
        'Bob',
      );
      expect((await proactive().read())!['hardMuted'], isTrue);
      expect((await proactive(_accountB).read())!['hardMuted'], isFalse);
      expect(await _memories.count(database.raw), 4);
      await expectLater(
        conversation().write(
          ConversationPreferenceSnapshot(accountScopeDigest: _accountB),
        ),
        throwsStateError,
      );
      expect((await conversation().read())!['preferredAddress'], 'Alice');
    },
  );

  test(
    'proactive migration keeps mute, consent, quiet hours and expiry',
    () async {
      final selected = const ProactivePreferenceSnapshot.defaults(generation: 1)
          .copyWith(
            revision: 12,
            hardMuted: true,
            foregroundEnabled: true,
            osOutreachEnabled: true,
            consentRecorded: true,
            contactScope: ProactiveConversationScope.everyday,
            authorizedUntil: DateTime.utc(2026, 10, 13),
            quietStartMinutes: 21 * 60,
            quietEndMinutes: 8 * 60,
            dailyBudget: 2,
            frequency: ProactiveContactFrequency.high,
            sensitivity: ProactiveContactSensitivity.low,
          );
      await _oldProactive
          .record('self')
          .put(database.raw, selected.toStorageJson());
      final service = await ProactivePreferenceService(
        store: proactive(),
        accountScopeDigest: _accountA,
        generation: 5,
      ).init();
      addTearDown(service.deactivateAndDrain);
      final restored = service.effectiveSnapshot;
      expect(restored.toStorageJson(), selected.toStorageJson());
      expect(restored.generation, 5);
      expect(restored.foregroundAllowed, isFalse);
      expect(restored.osOutreachAllowed, isFalse);
      expect(restored.effectiveDailyBudget, 0);
      expect(restored.isQuietAt(DateTime(2026, 10, 12, 21)), isTrue);
      expect(
        restored.authorizationCurrentAt(DateTime.utc(2026, 10, 14)),
        isFalse,
      );
      expect(await _oldProactive.record('self').get(database.raw), isNull);
      final row = (await _memories
          .record(memoryKey(AgentPersonaMemoryKind.proactiveContact))
          .get(database.raw))!;
      expect(row['source'], 'user_choice');
      expect(row['payload'], selected.toStorageJson());
      await service.setFrequency(ProactiveContactFrequency.low);
      final reboot = await ProactivePreferenceService(
        store: proactive(),
        accountScopeDigest: _accountA,
        generation: 6,
      ).init();
      addTearDown(reboot.deactivateAndDrain);
      expect(reboot.effectiveSnapshot.hardMuted, isTrue);
      expect(reboot.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(reboot.effectiveSnapshot.frequency, ProactiveContactFrequency.low);
      expect(reboot.effectiveSnapshot.revision, 13);
    },
  );

  test('v1 proactive row never gains authorization during migration', () async {
    final legacy =
        const ProactivePreferenceSnapshot.defaults(
            generation: 1,
          ).toStorageJson()
          ..removeWhere(
            (key, _) => !{
              'schemaVersion',
              'revision',
              'hardMuted',
              'foregroundEnabled',
              'osOutreachEnabled',
              'quietStartMinutes',
              'quietEndMinutes',
              'dailyBudget',
              'frequency',
              'sensitivity',
            }.contains(key),
          )
          ..['schemaVersion'] = 1
          ..['foregroundEnabled'] = true
          ..['osOutreachEnabled'] = true;
    await _oldProactive.record('self').put(database.raw, legacy);
    final restored = ProactivePreferenceSnapshot.fromStorageJson(
      await proactive().read(),
      generation: 2,
    );
    expect(restored.consentRecorded, isFalse);
    expect(restored.needsConsentReview, isTrue);
    expect(restored.foregroundEnabled, isFalse);
    expect(restored.osOutreachEnabled, isFalse);
    expect(restored.contactScope, ProactiveConversationScope.openTopics);
    expect(await _oldProactive.record('self').get(database.raw), isNull);
  });

  test(
    'invalid legacy choices are retained rather than destructively migrated',
    () async {
      const invalid = {'schemaVersion': 99, 'preferredAddress': '未迁移'};
      await _oldConversation.record(_accountA).put(database.raw, invalid);
      await expectLater(conversation().read(), throwsFormatException);
      expect(
        await _oldConversation.record(_accountA).get(database.raw),
        invalid,
      );
      expect(await _memories.count(database.raw), 0);
      final selected = ConversationPreferenceSnapshot(
        accountScopeDigest: _accountA,
        preferredAddress: 'Alex',
      );
      await conversation().write(selected);
      expect(await conversation().read(), selected.toStorageJson());
      expect(
        await _oldConversation.record(_accountA).get(database.raw),
        invalid,
      );
      await _oldProactive.record('self').put(database.raw, {
        'schemaVersion': 99,
      });
      await expectLater(proactive().read(), throwsFormatException);
      expect(await _oldProactive.record('self').get(database.raw), {
        'schemaVersion': 99,
      });
    },
  );

  test(
    'corrupted account or kind cannot fall back to legacy choices',
    () async {
      final selected = ConversationPreferenceSnapshot(
        accountScopeDigest: _accountA,
        preferredAddress: 'Alex',
      );
      await conversation().write(selected);
      final key = memoryKey(AgentPersonaMemoryKind.conversationStyle);
      final row = (await _memories.record(key).get(database.raw))!;
      for (final corrupted in [
        {...row, 'accountScopeDigest': _accountB},
        {...row, 'kind': AgentPersonaMemoryKind.proactiveContact.name},
        {...row, 'source': 'model_assertion'},
        {...row, 'schemaVersion': 2},
      ]) {
        await _memories.record(key).put(database.raw, corrupted);
        await _oldConversation
            .record(_accountA)
            .put(database.raw, selected.toStorageJson());
        await expectLater(conversation().read(), throwsFormatException);
        expect(await _memories.record(key).get(database.raw), corrupted);
        expect(
          await _oldConversation.record(_accountA).get(database.raw),
          selected.toStorageJson(),
        );
      }
    },
  );

  test(
    'new proactive account remains disabled and has no inferred consent',
    () async {
      final service = await ProactivePreferenceService(
        store: proactive(),
        accountScopeDigest: _accountA,
        generation: 1,
      ).init();
      addTearDown(service.deactivateAndDrain);
      expect(service.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(service.effectiveSnapshot.osOutreachAllowed, isFalse);
      expect(service.effectiveSnapshot.consentRecorded, isFalse);
      expect(await conversation().read(), isNull);
      expect(await proactive().read(), isNull);
      expect(await _memories.count(database.raw), 0);
      await service.setFrequency(ProactiveContactFrequency.balanced);
      expect((await proactive().read())!['revision'], 2);
      expect(() => proactive('invalid').read(), throwsArgumentError);
    },
  );
}
