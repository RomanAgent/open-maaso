import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/chat/data/chat_reply_feedback_store.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messages = intMapStoreFactory.store('chat_messages');
  final ratings = StoreRef<String, Map<String, Object?>>(
    'chat_reply_feedback.v1',
  );
  late DBService database;
  late AccountStorageScopeService scopes;
  late AccountStorageScopeMount mount;
  late ChatReplyFeedbackStore store;
  late ChatMessage reply;
  late String path;
  final accountA = AccountStorageScope(
    environmentKey: 'prod',
    accountUuid: 'owner-A',
  );
  final accountB = AccountStorageScope(
    environmentKey: 'prod',
    accountUuid: 'owner-B',
  );

  ChatReplyFeedbackStore currentStore() =>
      ChatReplyFeedbackStore(database: database, scopes: scopes, mount: mount);

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    path = 'reply-feedback-${DateTime.now().microsecondsSinceEpoch}.db';
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    scopes = AccountStorageScopeService();
    mount = scopes.mount(accountA);
    store = currentStore();
    reply = _reply();
    await database.saveChatMessage(reply);
  });

  tearDown(() async {
    await appServices.reset();
    await database.close();
    await databaseFactoryMemory.deleteDatabase(path);
  });

  test(
    'excellent and poor replace one another and tapping again cancels',
    () async {
      final target = store.capture(reply)!;
      final before = await messages.record(reply.id!).get(database.raw);
      expect(await store.read(target), isNull);
      expect(
        await store.toggle(target, ChatReplyFeedback.excellent),
        ChatReplyFeedback.excellent,
      );
      expect(await store.read(target), ChatReplyFeedback.excellent);
      expect(
        await store.toggle(target, ChatReplyFeedback.poor),
        ChatReplyFeedback.poor,
      );
      expect(await store.read(target), ChatReplyFeedback.poor);
      expect(await ratings.count(database.raw), 1);
      expect(await store.toggle(target, ChatReplyFeedback.poor), isNull);
      expect(await ratings.count(database.raw), 0);
      expect(await messages.record(reply.id!).get(database.raw), before);
    },
  );

  test(
    'feedback survives a real file database close and reopen without copying text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-reply-feedback-',
      );
      final diskPath = '${directory.path}/state.db';
      DBService? disk;
      try {
        disk = await DBService().init(
          factory: databaseFactoryIo,
          path: diskPath,
        );
        final original = _reply(content: 'PRIVATE_REPLY_TEXT_NOT_IN_FEEDBACK');
        await disk.saveChatMessage(original);
        final first = ChatReplyFeedbackStore(
          database: disk,
          scopes: scopes,
          mount: mount,
        );
        await first.toggle(
          first.capture(original)!,
          ChatReplyFeedback.excellent,
        );
        final stored = (await ratings.find(disk.raw)).single.value;
        expect(stored.keys, unorderedEquals(['fingerprint', 'value']));
        expect(stored['fingerprint'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(jsonEncode(stored), isNot(contains(original.content)));
        await disk.close();
        expect(first.isCurrent, isFalse);
        disk = await DBService().init(
          factory: databaseFactoryIo,
          path: diskPath,
        );
        final reopened = ChatReplyFeedbackStore(
          database: disk,
          scopes: scopes,
          mount: mount,
        );
        final loaded = (await disk.getMessages('self')).single;
        expect(
          await reopened.read(reopened.capture(loaded)!),
          ChatReplyFeedback.excellent,
        );
      } finally {
        await disk?.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'account and environment namespaces isolate identical message IDs',
    () async {
      final aTarget = store.capture(reply)!;
      await store.toggle(aTarget, ChatReplyFeedback.excellent);
      for (final other in [
        accountB,
        AccountStorageScope(environmentKey: 'test', accountUuid: 'owner-A'),
      ]) {
        scopes.unmount(mount);
        mount = scopes.mount(other);
        final otherStore = currentStore();
        final otherTarget = otherStore.capture(reply)!;
        // Deliberately share the database handle to verify explicit key fencing
        // in addition to production's separate account database files.
        expect(await otherStore.read(otherTarget), isNull);
        await otherStore.toggle(otherTarget, ChatReplyFeedback.poor);
      }
      expect(store.isCurrent, isFalse);
      await expectLater(store.read(aTarget), throwsStateError);
      scopes.unmount(mount);
      mount = scopes.mount(accountA);
      final restored = currentStore();
      expect(
        await restored.read(restored.capture(reply)!),
        ChatReplyFeedback.excellent,
      );
      await expectLater(
        restored.toggle(aTarget, ChatReplyFeedback.poor),
        throwsStateError,
      );
      expect(await ratings.count(database.raw), 3);
    },
  );

  test('distinct replies and sessions retain independent choices', () async {
    final second = _reply(content: 'Another reply');
    final third = _reply(session: 'another-agent');
    await database.saveChatMessage(second);
    await database.saveChatMessage(third);
    final firstTarget = store.capture(reply)!;
    final secondTarget = store.capture(second)!;
    final thirdTarget = store.capture(third)!;
    await store.toggle(firstTarget, ChatReplyFeedback.excellent);
    await store.toggle(secondTarget, ChatReplyFeedback.poor);
    expect(await store.read(firstTarget), ChatReplyFeedback.excellent);
    expect(await store.read(secondTarget), ChatReplyFeedback.poor);
    expect(await store.read(thirdTarget), isNull);
  });

  test('unpersisted, user, empty and undelivered rows cannot be rated', () {
    expect(store.capture(_reply()), isNull);
    for (final invalid in [
      _reply(id: 10)..isUserMessage = true,
      _reply(id: 10)..senderId = 'user',
      _reply(id: 10, content: '  '),
      _reply(id: 10)..deliveryStatus = 'queued',
      _reply(id: 10)..sessionId = '',
    ]) {
      expect(store.capture(invalid), isNull);
    }
    expect(
      store.capture(_reply(id: 10)..deliveryStatus = 'interrupted'),
      isNotNull,
    );
  });

  test(
    'deleted or replaced message IDs reject stale targets and old ratings',
    () async {
      final oldTarget = store.capture(reply)!;
      await store.toggle(oldTarget, ChatReplyFeedback.excellent);
      final replacement = _reply(id: reply.id, content: 'Replacement reply');
      await messages.record(reply.id!).put(database.raw, replacement.toJson());
      await expectLater(
        store.toggle(oldTarget, ChatReplyFeedback.poor),
        throwsStateError,
      );
      final replacementTarget = store.capture(replacement)!;
      expect(await store.read(replacementTarget), isNull);
      await store.toggle(replacementTarget, ChatReplyFeedback.poor);
      expect(await store.read(replacementTarget), ChatReplyFeedback.poor);
      await messages.record(reply.id!).delete(database.raw);
      await expectLater(store.read(replacementTarget), throwsStateError);
      final missing = store.capture(_reply(id: 123456))!;
      await expectLater(
        store.toggle(missing, ChatReplyFeedback.excellent),
        throwsStateError,
      );
      expect(await ratings.count(database.raw), 1);
    },
  );

  test(
    'capture snapshots the selected row before caller-side message mutation',
    () async {
      final target = store.capture(reply)!;
      reply.content = 'A later widget value';
      await store.toggle(target, ChatReplyFeedback.excellent);
      expect(await store.read(target), ChatReplyFeedback.excellent);
      await expectLater(store.read(store.capture(reply)!), throwsStateError);
    },
  );

  for (final write in [false, true]) {
    test(
      'a queued ${write ? 'write' : 'read'} cannot cross an account switch',
      () async {
        final target = store.capture(reply)!;
        final entered = Completer<void>();
        final release = Completer<void>();
        final holding = database.raw.transaction((transaction) async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        final operation = write
            ? store.toggle(target, ChatReplyFeedback.excellent)
            : store.read(target);
        final rejected = expectLater(operation, throwsStateError);
        scopes.unmount(mount);
        mount = scopes.mount(accountB);
        release.complete();
        await holding;
        await rejected;
        expect(await ratings.count(database.raw), 0);
        final next = currentStore();
        expect(await next.read(next.capture(reply)!), isNull);
      },
    );
  }

  test(
    'concurrent toggles are serialized into one mutually exclusive value',
    () async {
      final target = store.capture(reply)!;
      final results = await Future.wait([
        store.toggle(target, ChatReplyFeedback.excellent),
        store.toggle(target, ChatReplyFeedback.excellent),
        store.toggle(target, ChatReplyFeedback.poor),
      ]);
      expect(results, [
        ChatReplyFeedback.excellent,
        null,
        ChatReplyFeedback.poor,
      ]);
      expect(await store.read(target), ChatReplyFeedback.poor);
      expect(await ratings.count(database.raw), 1);
    },
  );

  test(
    'maybeCurrent captures services lazily and rejects replaced database ownership',
    () async {
      expect(ChatReplyFeedbackStore.maybeCurrent(), isNull);
      appServices.put<AccountStorageScopeService>(scopes);
      appServices.put<DBService>(database);
      final selected = ChatReplyFeedbackStore.maybeCurrent()!;
      final target = selected.capture(reply)!;
      await selected.toggle(target, ChatReplyFeedback.excellent);
      await appServices.delete<DBService>(force: true);
      await database.close();
      expect(selected.isCurrent, isFalse);
      expect(ChatReplyFeedbackStore.maybeCurrent(), isNull);
      database = await DBService().init(
        factory: databaseFactoryMemory,
        path: path,
      );
      appServices.put<DBService>(database);
      final current = ChatReplyFeedbackStore.maybeCurrent()!;
      await expectLater(
        selected.toggle(target, ChatReplyFeedback.poor),
        throwsStateError,
      );
      expect(
        await current.read(current.capture(reply)!),
        ChatReplyFeedback.excellent,
      );
      scopes.unmount(mount);
      expect(ChatReplyFeedbackStore.maybeCurrent(), isNull);
    },
  );
}

ChatMessage _reply({
  int? id,
  String content = 'A helpful reply',
  String session = 'self',
}) => ChatMessage(
  id: id,
  sessionId: session,
  senderId: 'self',
  receiverId: 'user',
  content: content,
  timestamp: DateTime.utc(2026, 9, 15, 12, 30),
  deliveryStatus: 'published',
);
