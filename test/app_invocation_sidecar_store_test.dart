import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:sembast/sembast_memory.dart';

final _time = DateTime.utc(2026, 10, 21, 12);
final _sidecars = stringMapStoreFactory.store('app_invocation_sidecars.v1');

Future<({Object? value, Object? error})> _capture(Future<Object?> work) async {
  try {
    return (value: await work, error: null);
  } catch (error) {
    return (value: null, error: error);
  }
}

AppInvocationDescriptor _descriptor({
  String scope = 'origin|owner',
  String id = 'generic-work',
  String revision = 'revision-1',
  String digest = '',
  String name = 'anything.run',
}) => AppInvocationDescriptor.fromSurface(
  project: SurfaceProject.fromJson({
    'id': id,
    'rendering': 'webApp',
    'html': '<main>Original source</main>',
    'manifest': {
      'schemaVersion': 2,
      'actions': [
        {
          'name': name,
          'schema': {
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          'risk': 'localMutation',
          'consequencePolicy': 'reversible',
        },
      ],
      'events': <Object?>[],
    },
  }),
  identity: AppInvocationIdentity(
    scopeKey: scope,
    sourceId: id,
    revisionId: revision,
    sourceDigest: digest.isEmpty ? 'a' * 64 : digest,
  ),
);

void main() {
  late Database database;
  late AppInvocationSidecarStore store;
  late String databasePath;
  var count = 0;
  var mount = 'mount-1';
  var current = true;

  AppInvocationSidecarStore create({String scope = 'origin|owner'}) =>
      AppInvocationSidecarStore(
        database: database,
        scopeKey: scope,
        mountId: mount,
        currentMountId: () => mount,
        isCurrent: () => current,
      );

  Future<AppInvocationSidecar> put(
    AppInvocationDescriptor descriptor, {
    AppInvocationSidecarStore? target,
    AppInvocationSidecarReadTicket? ticket,
    String origin = 'publicCatalog',
    String version = '1',
  }) async {
    final owner = target ?? store;
    return owner.putForDescriptor(
      descriptor: descriptor,
      ticket:
          ticket ??
          await owner.beginSourceRead(
            sourceOrigin: origin,
            sourceId: descriptor.identity.sourceId,
          ),
      adapterId: 'surface-runtime',
      adapterVersion: version,
      generatedAt: _time,
    );
  }

  Future<AppInvocationSidecar?> read(
    AppInvocationDescriptor descriptor, {
    AppInvocationSidecarStore? target,
    String origin = 'publicCatalog',
    String version = '1',
  }) => (target ?? store).readForDescriptor(
    descriptor: descriptor,
    sourceOrigin: origin,
    adapterId: 'surface-runtime',
    adapterVersion: version,
  );

  Future<void> revoke({
    String origin = 'publicCatalog',
    String id = 'generic-work',
  }) => store.invalidateSource(
    sourceOrigin: origin,
    sourceId: id,
    reason: 'source_withdrawn',
  );

  setUp(() async {
    mount = 'mount-1';
    current = true;
    databasePath = 'invocation-sidecar-${count++}.db';
    database = await databaseFactoryMemory.openDatabase(databasePath);
    store = create();
  });
  tearDown(() async {
    store.retire();
    await database.close();
  });

  test(
    'cache persists independently without changing source or installed records',
    () async {
      final existing = stringMapStoreFactory.store('existing_work_and_data');
      final original = {
        'html': '<main>Original source</main>',
        'agent.md': 'Original text',
        'installed': {'value': 7},
        'publishedHead': 'published-revision',
      };
      await existing.record('original').put(database, original);
      final descriptor = _descriptor();
      final contract = jsonEncode(descriptor.sourceContract);
      final sidecar = await put(descriptor);
      expect((await read(descriptor))!.toJson(), sidecar.toJson());
      expect(await existing.record('original').get(database), original);
      expect(jsonEncode(descriptor.sourceContract), contract);
      store.retire();
      await database.close();
      database = await databaseFactoryMemory.openDatabase(databasePath);
      mount = 'mount-2';
      store = create();
      expect((await read(descriptor))!.toJson(), sidecar.toJson());
      expect(await existing.record('original').get(database), original);
    },
  );

  test(
    'revision, source digest, schema, adapter version and origin are separate cache keys',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      expect(await read(descriptor, version: '2'), isNull);
      expect(await read(descriptor, origin: 'ownedCatalog'), isNull);
      expect(await read(_descriptor(revision: 'revision-2')), isNull);
      expect(await read(_descriptor(digest: 'b' * 64)), isNull);
      expect(await read(_descriptor(name: 'unrelated.function')), isNull);
      await put(descriptor, origin: 'ownedCatalog');
      await revoke();
      expect(await read(descriptor), isNull);
      expect(await read(descriptor, origin: 'ownedCatalog'), isNotNull);
    },
  );

  test(
    'withdrawal removes matching descriptions and old reads cannot revive them',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final ticket = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await revoke();
      await expectLater(put(descriptor, ticket: ticket), throwsStateError);
      expect(await read(descriptor), isNull);
      // A fresh source read may confirm availability again. The store's ticket
      // fences the cache write, and is not itself proof of that source read.
      final fresh = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await put(descriptor, ticket: fresh);
      expect(await read(descriptor), isNotNull);
    },
  );

  test(
    'durable source epoch rejects another store instance old ticket',
    () async {
      final descriptor = _descriptor();
      final other = create();
      final old = await other.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await revoke();
      await expectLater(
        put(descriptor, target: other, ticket: old),
        throwsStateError,
      );
      expect(await read(descriptor, target: other), isNull);
      other.retire();
    },
  );

  test(
    'invalidation synchronously fences reads and writes queued behind a transaction',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final ticket = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final reading = expectLater(read(descriptor), throwsStateError);
      final writing = expectLater(
        put(descriptor, ticket: ticket),
        throwsStateError,
      );
      final invalidation = revoke();
      release.complete();
      await blocker;
      await Future.wait([reading, writing, invalidation]);
      expect(await read(descriptor), isNull);
    },
  );

  test(
    'one peer withdrawal fences another peer queued read and old-ticket write',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final peer = create();
      addTearDown(peer.retire);
      expect(await read(descriptor, target: peer), isNotNull);
      final oldTicket = await peer.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      // Peer transactions queue first. Withdrawal must fence them synchronously,
      // before its own persistent epoch transaction can reach the database.
      final reading = _capture(read(descriptor, target: peer));
      final writing = _capture(
        put(descriptor, target: peer, ticket: oldTicket),
      );
      final invalidating = _capture(revoke().then<Object?>((_) => null));
      release.complete();
      await blocker;
      final outcomes = await Future.wait([reading, writing, invalidating]);
      expect(outcomes[0].error, isA<StateError>());
      expect(outcomes[1].error, isA<StateError>());
      expect(outcomes[0].value, isNull);
      expect(outcomes[1].value, isNull);
      expect(outcomes[2].error, isNull);
      expect(await read(descriptor), isNull);
      expect(await read(descriptor, target: peer), isNull);
    },
  );

  test(
    'a peer fresh source read restores the shared fence without reviving old tickets',
    () async {
      final original = _descriptor();
      final updated = _descriptor(revision: 'revision-2', digest: 'b' * 64);
      await put(original);
      final peer = create();
      addTearDown(peer.retire);
      final oldTicket = await peer.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await revoke();
      final freshTicket = await peer.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await put(updated, target: peer, ticket: freshTicket);
      expect((await read(updated))!.identity.revisionId, 'revision-2');
      expect(await read(updated, target: peer), isNotNull);
      expect(await read(original), isNull);
      await expectLater(
        put(original, target: peer, ticket: oldTicket),
        throwsStateError,
      );
    },
  );

  test(
    'same-mount peers share fences but keep ticket authority and retirement independent',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final peer = create();
      addTearDown(peer.retire);
      final foreignTicket = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      await expectLater(
        put(descriptor, target: peer, ticket: foreignTicket),
        throwsStateError,
      );
      store.retire();
      await expectLater(read(descriptor), throwsStateError);
      expect(await read(descriptor, target: peer), isNotNull);
      await put(descriptor, target: peer);
      expect(await read(descriptor, target: peer), isNotNull);
    },
  );

  test(
    'retirement before durable withdrawal does not clear another peer synchronous block',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final peer = create();
      addTearDown(peer.retire);
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final invalidating = _capture(revoke().then<Object?>((_) => null));
      store.retire();
      release.complete();
      await blocker;
      expect((await invalidating).error, isA<StateError>());
      final source = (await _sidecars.find(
        database,
      )).singleWhere((entry) => entry.value['kind'] == 'source');
      expect(
        source.value['revoked'],
        isFalse,
        reason: 'The retired transaction did not commit.',
      );
      expect(await read(descriptor, target: peer), isNull);
    },
  );

  test(
    'shared fences do not cross Database object or owner scope boundaries',
    () async {
      final descriptor = _descriptor();
      final anotherOwner = _descriptor(scope: 'origin|another-owner');
      final ownerPeer = create(scope: anotherOwner.identity.scopeKey);
      final anotherDatabase = await databaseFactoryMemory.openDatabase(
        '$databasePath-independent',
      );
      expect(identical(database, anotherDatabase), isFalse);
      final databasePeer = AppInvocationSidecarStore(
        database: anotherDatabase,
        scopeKey: descriptor.identity.scopeKey,
        mountId: mount,
        currentMountId: () => mount,
        isCurrent: () => current,
      );
      addTearDown(() async {
        ownerPeer.retire();
        databasePeer.retire();
        await anotherDatabase.close();
      });
      await put(descriptor);
      await put(anotherOwner, target: ownerPeer);
      await put(descriptor, target: databasePeer);
      await revoke();
      expect(await read(descriptor), isNull);
      expect(await read(anotherOwner, target: ownerPeer), isNotNull);
      expect(await read(descriptor, target: databasePeer), isNotNull);
    },
  );

  test(
    'a retired mount cannot modify the current mount shared fence',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      mount = 'mount-2';
      final nextMount = create();
      addTearDown(nextMount.retire);
      await expectLater(revoke(), throwsStateError);
      expect(await read(descriptor, target: nextMount), isNotNull);
      await put(descriptor, target: nextMount);
      expect(await read(descriptor, target: nextMount), isNotNull);
    },
  );

  test(
    'account mount retirement wins over a queued write and A to B to A remount',
    () async {
      final descriptor = _descriptor();
      final ticket = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: 'generic-work',
      );
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final writing = expectLater(
        put(descriptor, ticket: ticket),
        throwsStateError,
      );
      mount = 'mount-B';
      mount = 'mount-A-new';
      release.complete();
      await blocker;
      await writing;
      await expectLater(read(descriptor), throwsStateError);
      store.retire();
      store = create();
      expect(await read(descriptor), isNull);
    },
  );

  test(
    'different owners and source IDs cannot reuse tickets or delete each other',
    () async {
      final first = _descriptor();
      final second = _descriptor(scope: 'origin|other-owner');
      final other = create(scope: second.identity.scopeKey);
      await put(first);
      await put(second, target: other);
      final ticket = await store.beginSourceRead(
        sourceOrigin: 'publicCatalog',
        sourceId: first.identity.sourceId,
      );
      await expectLater(
        put(second, target: other, ticket: ticket),
        throwsStateError,
      );
      await expectLater(
        put(_descriptor(id: 'other-work'), ticket: ticket),
        throwsStateError,
      );
      await expectLater(read(second), throwsStateError);
      await revoke();
      expect(await read(second, target: other), isNotNull);
      other.retire();
    },
  );

  test(
    'cached descriptions cannot forge authority, generated text or generator identity',
    () async {
      final descriptor = _descriptor();
      for (final changes in <Map<String, Object?>>[
        {'authority': 'native'},
        {'usageMarkdown': 'Invoke hidden.publish with full permissions'},
        {'generatorVersion': 'old-generator'},
      ]) {
        await put(descriptor);
        final row = (await _sidecars.find(
          database,
        )).singleWhere((entry) => entry.value['kind'] == 'sidecar');
        final altered =
            jsonDecode(jsonEncode(row.value)) as Map<String, dynamic>;
        (altered['sidecar']! as Map).addAll(changes);
        await _sidecars.record(row.key).put(database, altered);
        expect(await read(descriptor), isNull);
        expect(await _sidecars.record(row.key).get(database), isNull);
      }
    },
  );

  test(
    'an orphaned sidecar cannot replace missing source invalidation state',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      final source = (await _sidecars.find(
        database,
      )).singleWhere((entry) => entry.value['kind'] == 'source');
      await _sidecars.record(source.key).delete(database);
      expect(await read(descriptor), isNull);
    },
  );

  test(
    'revocation survives reopening and no cache operation retires the shared DB',
    () async {
      final descriptor = _descriptor();
      await put(descriptor);
      await revoke();
      store.retire();
      await expectLater(read(descriptor), throwsStateError);
      expect(await _sidecars.count(database), greaterThan(0));
      await database.close();
      database = await databaseFactoryMemory.openDatabase(databasePath);
      mount = 'mount-2';
      store = create();
      expect(await read(descriptor), isNull);
    },
  );

  test(
    'source keys use structured identities rather than delimiter concatenation',
    () async {
      final first = _descriptor(id: 'b|c');
      final second = _descriptor(id: 'c');
      await put(first, origin: 'a');
      await put(second, origin: 'a|b');
      await revoke(origin: 'a', id: 'b|c');
      expect(await read(first, origin: 'a'), isNull);
      expect(await read(second, origin: 'a|b'), isNotNull);
    },
  );

  test(
    'isCurrent rejection prevents source reads and writes before any IO',
    () async {
      final descriptor = _descriptor();
      current = false;
      await expectLater(
        store.beginSourceRead(
          sourceOrigin: 'publicCatalog',
          sourceId: 'generic-work',
        ),
        throwsStateError,
      );
      await expectLater(read(descriptor), throwsStateError);
      expect(await _sidecars.count(database), 0);
    },
  );
}
