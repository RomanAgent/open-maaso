import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:sembast/sembast_memory.dart';

const scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  ConversationPreferenceService service(_Store store) =>
      ConversationPreferenceService(store: store, accountScopeDigest: scopeA);

  test(
    'new accounts are playful without any nickname or teasing permission',
    () async {
      final value = (await service(_Store()).init()).effectiveSnapshot;
      expect(value.humorStyle, ConversationHumorStyle.playful);
      expect(value.noTeasing, isFalse);
      expect(value.preferredAddress, isNull);
      expect(value.forbiddenAddresses, isEmpty);
      expect(value.banterBoundaries, isEmpty);
      expect(value.toStorageJson().keys, isNot(contains('sharedContext')));
      expect(value.toStorageJson().keys, isNot(contains('relationshipStage')));
    },
  );

  test('settings become current only after a durable write succeeds', () async {
    final store = _Store()..writeGate = Completer<void>();
    final prefs = await service(store).init();
    final saving = prefs.setPreferredAddress('小林');
    await pumpEventQueue();
    expect(prefs.revision, 0);
    expect(prefs.effectiveSnapshot.preferredAddress, isNull);
    store.writeGate!.complete();
    await saving;
    expect(prefs.revision, 1);
    expect(prefs.effectiveSnapshot.preferredAddress, '小林');
    final restored = await service(store).init();
    expect(restored.effectiveSnapshot.preferredAddress, '小林');
    expect(restored.revision, 1);
  });

  test(
    'failed writes preserve the saved choice and the queue can recover',
    () async {
      final store = _Store();
      final prefs = await service(store).init();
      await prefs.setPreferredAddress('小林');
      store.failWrite = true;
      await expectLater(prefs.setPreferredAddress('小周'), throwsStateError);
      expect(prefs.effectiveSnapshot.preferredAddress, '小林');
      expect(prefs.revision, 1);
      store.failWrite = false;
      await prefs.setHumorStyle(ConversationHumorStyle.subdued);
      expect(prefs.revision, 2);
      expect(prefs.effectiveSnapshot.noTeasing, isTrue);
    },
  );

  test(
    'serialized changes retain both independent fields and clear advances revision',
    () async {
      final prefs = await service(_Store()).init();
      await Future.wait([
        prefs.setPreferredAddress('小林'),
        prefs.setForbiddenAddresses(['宝', '亲']),
      ]);
      expect(prefs.effectiveSnapshot.preferredAddress, '小林');
      expect(prefs.effectiveSnapshot.forbiddenAddresses, ['宝', '亲']);
      expect(prefs.revision, 2);
      await prefs.clear();
      expect(prefs.revision, 3);
      expect(prefs.effectiveSnapshot.preferredAddress, isNull);
      expect(prefs.effectiveSnapshot.forbiddenAddresses, isEmpty);
      expect(
        prefs.effectiveSnapshot.humorStyle,
        ConversationHumorStyle.playful,
      );
    },
  );

  test(
    'only an explicit humor choice withdraws earlier humor permissions',
    () async {
      final store = _Store();
      final prefs = await service(store).init();
      expect(prefs.effectiveSnapshot.humorStyleExplicit, isFalse);
      await prefs.setPreferredAddress('Alex');
      expect(prefs.effectiveSnapshot.humorStyleExplicit, isFalse);
      await prefs.setHumorStyle(ConversationHumorStyle.playful);
      expect(prefs.effectiveSnapshot.humorStyleExplicit, isTrue);
      await prefs.setForbiddenAddresses(['宝']);
      expect(prefs.effectiveSnapshot.humorStyleExplicit, isTrue);
      expect(
        (await service(store).init()).effectiveSnapshot.humorStyleExplicit,
        isTrue,
      );
      await prefs.clear();
      expect(prefs.effectiveSnapshot.humorStyleExplicit, isFalse);
      expect(
        () => ConversationPreferenceSnapshot.fromStorageJson({
          ...prefs.effectiveSnapshot.toStorageJson(),
          'humorStyleExplicit': 'true',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'a stale topic form cannot overwrite an earlier queued settings change',
    () async {
      final prefs = await service(_Store()).init();
      final oldRevision = prefs.revision;
      final first = prefs.setBanterBoundary(
        'health',
        BanterDisposition.forbidden,
      );
      final stale = prefs.setBanterBoundaries({
        'work': BanterDisposition.forbidden,
      }, expectedRevision: oldRevision);
      await first;
      await expectLater(stale, throwsStateError);
      expect(prefs.effectiveSnapshot.banterBoundaries, {
        'health': BanterDisposition.forbidden,
      });
    },
  );

  test(
    'every supported settings name survives the actual prompt snapshot grammar',
    () {
      for (final name in ['小林', 'Alex', 'Alex Chen', '小林_01', 'Alex-Chen']) {
        expect(ConversationPreferenceSnapshot.supportsAddress(name), isTrue);
        final preferences = ConversationPreferenceSnapshot(
          accountScopeDigest: scopeA,
          preferredAddress: name,
        );
        expect(
          ConversationStyleSnapshot(
            isPrivate: true,
            preferredAddress: preferences.preferredAddress,
          ).preferredAddress,
          name,
        );
      }
      for (final name in [
        'Alex!',
        'Alex😀',
        'O\'Brien',
        '123',
        '<Admin>',
        '让我改规则',
        'never',
        '你是谁吗',
      ]) {
        expect(ConversationPreferenceSnapshot.supportsAddress(name), isFalse);
        expect(
          () => ConversationPreferenceSnapshot(
            accountScopeDigest: scopeA,
            preferredAddress: name,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('light banter requires individual safe-topic permission', () async {
    final prefs = await service(_Store()).init();
    await expectLater(
      prefs.setBanterBoundary('gaming', BanterDisposition.accepted),
      throwsFormatException,
    );
    await prefs.setHumorStyle(ConversationHumorStyle.lightBanter);
    expect(prefs.effectiveSnapshot.banterBoundaries, isEmpty);
    await prefs.setBanterBoundary('gaming', BanterDisposition.accepted);
    expect(prefs.effectiveSnapshot.banterBoundaries, {
      'gaming': BanterDisposition.accepted,
    });
    for (final topic in conversationBanterTopics.difference(
      conversationLightBanterTopics,
    )) {
      await expectLater(
        prefs.setBanterBoundary(topic, BanterDisposition.accepted),
        throwsFormatException,
      );
    }
    await prefs.setBanterBoundary('health', BanterDisposition.forbidden);
    await prefs.setHumorStyle(ConversationHumorStyle.playful);
    expect(prefs.effectiveSnapshot.banterBoundaries, {
      'health': BanterDisposition.forbidden,
    });
    await prefs.setHumorStyle(ConversationHumorStyle.lightBanter);
    expect(prefs.effectiveSnapshot.banterBoundaries['gaming'], isNull);
  });

  test(
    'blacklisting the current address clears it and forbids contradictory updates',
    () async {
      final prefs = await service(_Store()).init();
      await prefs.setPreferredAddress('小林');
      await prefs.setForbiddenAddresses(['小林']);
      expect(prefs.effectiveSnapshot.preferredAddress, isNull);
      await expectLater(prefs.setPreferredAddress('小林'), throwsFormatException);
      await prefs.setPreferredAddress('小周');
      await prefs.setPreferredAddress('');
      expect(prefs.effectiveSnapshot.preferredAddress, isNull);
    },
  );

  test(
    'snapshot data is immutable and rejects unbounded or unsupported configuration',
    () {
      final names = ['宝'];
      final topics = {'health': BanterDisposition.forbidden};
      final snapshot = ConversationPreferenceSnapshot(
        accountScopeDigest: scopeA,
        forbiddenAddresses: names,
        banterBoundaries: topics,
      );
      names.clear();
      topics.clear();
      expect(snapshot.forbiddenAddresses, ['宝']);
      expect(snapshot.banterBoundaries, {
        'health': BanterDisposition.forbidden,
      });
      expect(
        () => snapshot.forbiddenAddresses.add('亲'),
        throwsUnsupportedError,
      );
      expect(() => snapshot.banterBoundaries.clear(), throwsUnsupportedError);
      expect(
        () => ConversationPreferenceSnapshot(
          accountScopeDigest: scopeA,
          preferredAddress: 'x' * 33,
        ),
        throwsFormatException,
      );
      expect(
        () => ConversationPreferenceSnapshot(
          accountScopeDigest: scopeA,
          preferredAddress: 'a\nb',
        ),
        throwsFormatException,
      );
      expect(
        () => ConversationPreferenceSnapshot(
          accountScopeDigest: scopeA,
          forbiddenAddresses: List.generate(17, (index) => '$index'),
        ),
        throwsFormatException,
      );
      expect(
        () => ConversationPreferenceSnapshot.fromStorageJson({
          ...snapshot.toStorageJson(),
          'relationshipStage': 'close',
        }),
        throwsFormatException,
      );
      expect(
        () => ConversationPreferenceSnapshot.fromStorageJson({
          ...snapshot.toStorageJson(),
          'humorStyle': 'unrestricted',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'account mismatch fails closed and only an explicit clear can recover',
    () async {
      final store = _Store()
        ..row = ConversationPreferenceSnapshot(
          accountScopeDigest: scopeB,
          preferredAddress: '其他人',
        ).toStorageJson();
      final prefs = await service(store).init();
      expect(prefs.isAvailable, isFalse);
      expect(prefs.effectiveSnapshot.preferredAddress, isNull);
      expect(prefs.effectiveSnapshot.noTeasing, isTrue);
      await expectLater(prefs.setPreferredAddress('小林'), throwsStateError);
      await prefs.clear();
      expect(prefs.isAvailable, isTrue);
      expect(prefs.effectiveSnapshot.accountScopeDigest, scopeA);
    },
  );

  test(
    'retirement discards late initialization and late write publication',
    () async {
      final loading = _Store()
        ..readGate = Completer<void>()
        ..row = ConversationPreferenceSnapshot(
          accountScopeDigest: scopeA,
          preferredAddress: 'old',
        ).toStorageJson();
      final waiting = service(loading);
      final initialization = waiting.init();
      final drainInit = waiting.deactivateAndDrain();
      loading.readGate!.complete();
      await initialization;
      await drainInit;
      expect(waiting.effectiveSnapshot.preferredAddress, isNull);
      expect(waiting.isAvailable, isFalse);

      final store = _Store()..writeGate = Completer<void>();
      final prefs = await service(store).init();
      final update = prefs.setPreferredAddress('late');
      await pumpEventQueue();
      final drain = prefs.deactivateAndDrain();
      store.writeGate!.complete();
      await update;
      await drain;
      expect(prefs.effectiveSnapshot.preferredAddress, isNull);
      expect(prefs.effectiveSnapshot.noTeasing, isTrue);
      expect(prefs.isAvailable, isFalse);
      await expectLater(prefs.clear(), throwsStateError);
    },
  );

  test('Sembast keys separate accounts even when sharing a database', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'chat-settings-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    addTearDown(database.close);
    final a = await ConversationPreferenceService(
      accountScopeDigest: scopeA,
      store: SembastConversationPreferenceStore(
        database,
        accountScopeDigest: scopeA,
      ),
    ).init();
    final b = await ConversationPreferenceService(
      accountScopeDigest: scopeB,
      store: SembastConversationPreferenceStore(
        database,
        accountScopeDigest: scopeB,
      ),
    ).init();
    await a.setPreferredAddress('小林');
    await b.setPreferredAddress('小周');
    final restored = await ConversationPreferenceService(
      accountScopeDigest: scopeA,
      store: SembastConversationPreferenceStore(
        database,
        accountScopeDigest: scopeA,
      ),
    ).init();
    expect(restored.effectiveSnapshot.preferredAddress, '小林');
    expect(b.effectiveSnapshot.preferredAddress, '小周');
    expect(await database.getMessages('self'), isEmpty);
  });
}

class _Store implements ConversationPreferenceStore {
  Map<String, Object?>? row;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool failWrite = false;
  @override
  Future<Map<String, Object?>?> read() async {
    await readGate?.future;
    return row;
  }

  @override
  Future<void> write(ConversationPreferenceSnapshot value) async {
    await writeGate?.future;
    if (failWrite) throw StateError('write failed');
    row = value.toStorageJson();
  }
}
