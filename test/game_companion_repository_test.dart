import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/data/game_companion_repository.dart';
import 'package:sembast/sembast_memory.dart';

GameContentIdentity _identity(
  String digit, {
  GameContentIdentityKind kind = GameContentIdentityKind.ownedSource,
}) => GameContentIdentity(kind: kind, sha256: digit * 64);
GameCompanionAdaptation _rules(String text, {String? summary}) =>
    GameCompanionAdaptation(
      descriptor: GameCompanionDescriptor.tryParse({
        'version': 1,
        'rules': text,
        'summary': ?summary,
      }),
      source: GameCompanionAdaptationSource.observed,
      rulesKnown: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  var serial = 0;
  setUp(() async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'companion-repository-${serial++}.db',
    );
  });
  tearDown(() => db.close());
  GameCompanionRepository repository(
    String scope, {
    bool Function()? current,
    DateTime Function()? now,
    int entries = 48,
    int bytes = 192 * 1024,
  }) => GameCompanionRepository(
    database: db,
    scopeKey: scope,
    isCurrent: current ?? () => true,
    now: now,
    maxEntries: entries,
    maxCacheBytes: bytes,
  );
  Future<bool> write(
    GameCompanionRepository repo,
    String id, {
    String text = 'Match three tiles.',
  }) => repo.writeAdaptation(
    _identity(id),
    _rules(text),
    adapterVersion: 'v1',
    modelPolicyVersion: 'p1',
  );
  Future<GameCompanionAdaptation?> read(
    GameCompanionRepository repo,
    String id,
  ) => repo.readAdaptation(
    _identity(id),
    adapterVersion: 'v1',
    modelPolicyVersion: 'p1',
  );

  test(
    'preferences persist privately and stale revisions cannot overwrite them',
    () async {
      final a = repository('account-a');
      const enabled = GameCompanionPreferences(enabled: true, revision: 2);
      expect(await a.savePreferences(enabled), isTrue);
      expect(
        (await repository('account-a').loadPreferences())!.enabled,
        isTrue,
      );
      expect(await repository('account-b').loadPreferences(), isNull);
      expect(
        await a.savePreferences(
          const GameCompanionPreferences(enabled: false, revision: 1),
        ),
        isFalse,
      );
      expect(
        await a.savePreferences(
          const GameCompanionPreferences(enabled: false, revision: 2),
        ),
        isFalse,
      );
      expect(await a.savePreferences(enabled), isTrue);
      expect(await a.savePreferences(enabled.copyWith(enabled: false)), isTrue);
      expect((await a.loadPreferences())!.enabled, isFalse);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'cache identity includes owner, digest kind, adapter and model policy',
    () async {
      final a = repository('account-a');
      expect(await write(a, 'a'), isTrue);
      final restored = await read(repository('account-a'), 'a');
      expect(restored!.rulesKnown, isTrue);
      expect(restored.fromCache, isTrue);
      expect(restored.source, GameCompanionAdaptationSource.observed);
      expect(await read(repository('account-b'), 'a'), isNull);
      expect(await read(a, 'b'), isNull);
      expect(
        await a.readAdaptation(
          _identity('a', kind: GameContentIdentityKind.publishedRenderDocument),
          adapterVersion: 'v1',
          modelPolicyVersion: 'p1',
        ),
        isNull,
      );
      expect(
        await a.readAdaptation(
          _identity('a'),
          adapterVersion: 'v2',
          modelPolicyVersion: 'p1',
        ),
        isNull,
      );
      expect(
        await a.readAdaptation(
          _identity('a'),
          adapterVersion: 'v1',
          modelPolicyVersion: 'p2',
        ),
        isNull,
      );
    },
  );

  test(
    'the sidecar stores static rules and no live score or unknown adaptation',
    () async {
      final repo = repository('account-a');
      expect(
        await repo.writeAdaptation(
          _identity('a'),
          _rules('Match three tiles.', summary: 'Score: 99'),
          adapterVersion: 'v1',
          modelPolicyVersion: 'p1',
        ),
        isTrue,
      );
      expect(await write(repo, 'b', text: 'Your score is 42'), isFalse);
      expect(
        await repo.writeAdaptation(
          _identity('c'),
          const GameCompanionAdaptation(
            source: GameCompanionAdaptationSource.unknown,
          ),
          adapterVersion: 'v1',
          modelPolicyVersion: 'p1',
        ),
        isFalse,
      );
      final rows = await stringMapStoreFactory
          .store(GameCompanionRepository.adaptationStoreName)
          .find(db.raw);
      expect(rows, hasLength(1));
      final encoded = jsonEncode(rows.single.value);
      expect(encoded, contains('Match three tiles.'));
      for (final transient in [
        'Score: 99',
        'Your score is 42',
        'screenshot',
        'visibleText',
        'currentState',
      ]) {
        expect(encoded, isNot(contains(transient)));
      }
    },
  );

  test(
    'LRU, TTL and byte bounds keep only rebuildable static entries',
    () async {
      var now = DateTime.utc(2026, 10, 22);
      final repo = repository('account-a', now: () => now, entries: 2);
      await write(repo, 'a');
      now = now.add(const Duration(seconds: 1));
      await write(repo, 'b');
      now = now.add(const Duration(seconds: 1));
      expect(await read(repo, 'a'), isNotNull);
      now = now.add(const Duration(seconds: 1));
      await write(repo, 'c');
      expect(await read(repo, 'b'), isNull);
      expect(await read(repo, 'a'), isNotNull);
      expect(await read(repo, 'c'), isNotNull);
      now = now.add(const Duration(days: 15));
      expect(await read(repo, 'a'), isNull);
      expect(await read(repo, 'c'), isNull);
      final tiny = repository('account-tiny', bytes: 512);
      expect(await write(tiny, 'a', text: 'x' * 500), isFalse);
      expect(await read(tiny, 'a'), isNull);
    },
  );

  test('a queued account write is fenced when that account retires', () async {
    var current = true;
    final repo = repository('account-a', current: () => current);
    final entered = Completer<void>(), release = Completer<void>();
    final blocker = db.raw.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final saving = repo.savePreferences(
      const GameCompanionPreferences(enabled: true, revision: 1),
    );
    current = false;
    release.complete();
    await blocker;
    expect(await saving, isFalse);
    expect(await repository('account-a').loadPreferences(), isNull);
    repo.dispose();
    expect(await write(repo, 'a'), isFalse);
    expect(await read(repo, 'a'), isNull);
  });

  test(
    'document revocation fences a queued rule write inside the transaction',
    () async {
      final repo = repository('account-a');
      var documentCurrent = true;
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = db.raw.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final saving = repo.writeAdaptation(
        _identity('a'),
        _rules('Reach the exit.'),
        adapterVersion: 'v1',
        modelPolicyVersion: 'p1',
        canContinue: () => documentCurrent,
      );
      documentCurrent = false;
      release.complete();
      await blocker;
      expect(await saving, isFalse);
      expect(await read(repo, 'a'), isNull);
    },
  );
}
