import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/skills/set_soul_skill.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/data/identity_local_store.dart';
import 'package:maaso/src/features/identity/domain/identity_local_state.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sembast/sembast_io.dart';

import 'identity_test_support.dart';

final class _MemoryStore implements IdentityLocalStore {
  IdentityLocalState? value;
  Object? readError;
  Object? writeError;
  int writes = 0;
  Completer<void>? holdWrite;

  @override
  Future<IdentityLocalState?> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(IdentityLocalState state) async {
    if (writeError case final error?) throw error;
    await holdWrite?.future;
    value = IdentityLocalState.fromJson(state.toJson());
    writes++;
  }
}

FakeIdentityGateway _unavailable() =>
    FakeIdentityGateway()
      ..fetchOverride = () async =>
          throw const IdentityException(IdentityFailure.unavailable);

final class _LocalSoul extends SoulService {
  @override
  Future<void> update({
    String? name,
    int? age,
    String? gender,
    String? notesAppend,
    String? notesReplace,
  }) async {
    if (name != null) this.name.value = name;
    if (age != null) this.age.value = age;
  }
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'first test naming survives an absent API without fabricated actors',
    () async {
      final store = _MemoryStore();
      final gateway = _unavailable();
      var projected = '';
      final service = appServices.put(
        IdentityService(
          gateway: gateway,
          localStore: store,
          allowLocalSetup: () => true,
          projectLocalAgentName: (name) async => projected = name,
        ),
      );
      final controller = IdentitySetupController(
        service: service,
        legacyAgentName: () => 'Old Friend',
      );
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.onboarding);
      await controller.initialize();
      expect(controller.ready.value, isTrue);
      expect(controller.error.value, isNull);
      expect(controller.agentName.value, 'Old Friend');
      expect(controller.agentLocked, isTrue);
      controller.setPlayerName('Nova');
      final result = await controller.save();
      expect(result?.pendingSync, isTrue);
      expect(result?.profile, isNull);
      expect(projected, 'Old Friend');
      expect(service.completed, isFalse);
      expect(service.profile, isNull);
      expect(service.onboardingCompleted, isTrue);
      expect(store.value?.serverProfile, isNull);
      expect(store.value?.pendingNames?.toJson(), {
        'playerName': 'Nova',
        'agentName': 'Old Friend',
      });
      expect(gateway.writes, 0);
      expect(IdentityRoutePolicy.initialRoute(), AppRouteCatalog.home);
      for (final route in [
        AppRouteCatalog.agentSpace,
        AppRouteCatalog.gameFeed,
        AppRouteCatalog.settings,
      ]) {
        expect(IdentityRoutePolicy.redirect(route), isNull);
      }
      expect(
        IdentityRoutePolicy.redirect('/wallet'),
        isNull,
        reason:
            'The router normalizes legacy links after completed local setup.',
      );
    },
  );

  test(
    'restart restores the one-time naming without a network request',
    () async {
      final store = _MemoryStore()
        ..value = IdentityLocalState(
          pendingNames: IdentityLocalNames(
            playerName: 'Nova',
            agentName: 'Rice',
          ),
        );
      final gateway = _unavailable();
      var projected = 0;
      final service = IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
        projectProfile: (_) async => projected++,
        projectLocalAgentName: (_) async => projected++,
      );
      await service.restore();
      final controller = IdentitySetupController(service: service);
      await controller.initialize();
      expect(controller.playerName.value, 'Nova');
      expect(controller.agentName.value, 'Rice');
      expect(controller.ready.value, isTrue);
      expect(service.onboardingCompleted, isTrue);
      expect(service.completed, isFalse);
      expect(service.profile, isNull);
      expect(gateway.reads + gateway.writes, 0);
      expect(
        projected,
        0,
        reason: 'startup restore must not call runtime callbacks',
      );
    },
  );

  test(
    'real server cache restores navigation but requires fresh public verification',
    () async {
      final store = _MemoryStore();
      final first = IdentityService(
        gateway: FakeIdentityGateway(initial: identityFixture()),
        localStore: store,
      );
      await first.load();
      expect(first.completed, isTrue);
      first.onClose();
      final gateway = _unavailable();
      final service = appServices.put(
        IdentityService(gateway: gateway, localStore: store),
      );
      await service.restore();
      expect(
        service.setupResult?.profile?.playerActorId,
        identityFixture().playerActorId,
      );
      expect(service.onboardingCompleted, isTrue);
      expect(service.completed, isFalse);
      expect(service.profile, isNull);
      expect(IdentityRoutePolicy.redirect(AppRouteCatalog.agentSpace), isNull);
      await expectLater(service.load(), throwsA(isA<IdentityException>()));
      expect(service.onboardingCompleted, isTrue);
      expect(service.completed, isFalse);
      gateway.fetchOverride = null;
      gateway.stored = identityFixture();
      await service.load();
      expect(service.completed, isTrue);
    },
  );

  test(
    'an ordinary build cannot invent a local identity when server is unavailable',
    () async {
      final store = _MemoryStore();
      final service = IdentityService(
        gateway: _unavailable(),
        localStore: store,
      );
      final controller = IdentitySetupController(service: service);
      await controller.initialize();
      expect(controller.ready.value, isFalse);
      expect(controller.error.value, IdentityFailure.unavailable);
      expect(service.canSaveLocally, isFalse);
      expect(service.onboardingCompleted, isFalse);
      await expectLater(
        service.saveSetup(playerName: 'Nova', agentName: 'Rice'),
        throwsA(isA<IdentityException>()),
      );
      expect(store.writes, 0);
    },
  );

  test(
    'authentication rejection never becomes successful local setup',
    () async {
      final store = _MemoryStore();
      final gateway = _unavailable()
        ..fetchOverride = () async => throw const IdentityException(
          IdentityFailure.authenticationRequired,
        );
      final service = IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
      );
      final controller = IdentitySetupController(service: service);
      await controller.initialize();
      expect(controller.ready.value, isFalse);
      expect(controller.error.value, IdentityFailure.authenticationRequired);
      await expectLater(
        service.saveSetup(playerName: 'Nova', agentName: 'Rice'),
        throwsA(
          isA<IdentityException>().having(
            (e) => e.failure,
            'failure',
            IdentityFailure.authenticationRequired,
          ),
        ),
      );
      expect(service.onboardingCompleted, isFalse);
      expect(store.writes, 0);
    },
  );

  test('failed local persistence does not report completed naming', () async {
    final store = _MemoryStore()..writeError = StateError('disk unavailable');
    final service = IdentityService(
      gateway: _unavailable(),
      localStore: store,
      allowLocalSetup: () => true,
    );
    final controller = IdentitySetupController(service: service);
    await controller.initialize();
    controller.setPlayerName('Nova');
    controller.setAgentName('Rice');
    expect(await controller.save(), isNull);
    expect(service.onboardingCompleted, isFalse);
    expect(controller.error.value, IdentityFailure.unavailable);
    expect(controller.playerName.value, 'Nova');
    expect(store.value, isNull);
  });

  test(
    'corrupt cache falls back to first-use naming with a bounded diagnostic',
    () async {
      final store = _MemoryStore()
        ..readError = const FormatException('corrupt');
      final service = IdentityService(
        gateway: _unavailable(),
        localStore: store,
        allowLocalSetup: () => true,
      );
      await service.restore();
      expect(service.cacheIssue, 'invalid_identity_cache');
      expect(service.onboardingCompleted, isFalse);
      final controller = IdentitySetupController(service: service);
      await controller.initialize();
      expect(controller.ready.value, isTrue);
      controller.setPlayerName('Nova');
      controller.setAgentName('Rice');
      expect((await controller.save())?.pendingSync, isTrue);
      expect(service.cacheIssue, isNull);
    },
  );

  test('retired account cannot publish a pending save result', () async {
    final store = _MemoryStore();
    final service = IdentityService(
      gateway: _unavailable(),
      localStore: store,
      allowLocalSetup: () => true,
    );
    await expectLater(service.load(), throwsA(isA<IdentityException>()));
    store.holdWrite = Completer<void>();
    final saving = service.saveSetup(playerName: 'Nova', agentName: 'Rice');
    final checked = expectLater(
      saving,
      throwsA(
        isA<IdentityException>().having(
          (e) => e.failure,
          'failure',
          IdentityFailure.contextChanged,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    service.onClose();
    store.holdWrite!.complete();
    await checked;
    expect(service.onboardingCompleted, isFalse);
    expect(service.setupNames, isNull);
  });

  for (final remote in ['empty', 'completed', 'partial']) {
    test(
      'pending registration reconciles $remote server identity without overwriting names',
      () async {
        final store = _MemoryStore()
          ..value = IdentityLocalState(
            pendingNames: IdentityLocalNames(
              playerName: 'Nova',
              agentName: 'Rice',
            ),
          );
        final gateway = FakeIdentityGateway(
          initial: switch (remote) {
            'completed' => identityFixture(
              player: 'Other Player',
              agent: 'Other Agent',
            ),
            'partial' => identityFixture(player: '', agent: 'Existing Agent'),
            _ => identityFixture(version: 0, player: '', agent: ''),
          },
        );
        final service = IdentityService(
          gateway: gateway,
          localStore: store,
          allowLocalSetup: () => true,
        );
        await service.restore();
        await service.load();
        expect(service.completed, isTrue);
        expect(service.pendingSync, isFalse);
        expect(store.value?.pendingNames, isNull);
        expect(gateway.writes, remote == 'completed' ? 0 : 1);
        expect(
          service.profile?.playerName,
          remote == 'completed' ? 'Other Player' : 'Nova',
        );
        expect(service.profile?.agentName, switch (remote) {
          'completed' => 'Other Agent',
          'partial' => 'Existing Agent',
          _ => 'Rice',
        });
      },
    );
  }

  test(
    'sync conflict keeps local names without inventing server authority',
    () async {
      final store = _MemoryStore()
        ..value = IdentityLocalState(
          pendingNames: IdentityLocalNames(
            playerName: 'Nova',
            agentName: 'Rice',
          ),
        );
      final gateway = FakeIdentityGateway()
        ..updateOverride = (_, _, _) async =>
            throw const IdentityException(IdentityFailure.conflict);
      final service = IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
      );
      await service.restore();
      await expectLater(service.load(), throwsA(isA<IdentityException>()));
      expect(gateway.writes, 1);
      expect(service.completed, isFalse);
      expect(service.pendingSync, isTrue);
      expect(service.onboardingCompleted, isTrue);
    },
  );

  test(
    'Sembast storage survives reopen and rejects a different environment or account',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'identity-local-scoped',
      );
      addTearDown(db.close);
      var current = true;
      final store = SembastIdentityLocalStore(
        database: db,
        contextKey: 'test|account-a',
        isCurrent: () => current,
      );
      await store.write(
        IdentityLocalState(
          pendingNames: IdentityLocalNames(
            playerName: 'Nova',
            agentName: 'Rice',
          ),
        ),
      );
      final reopened = SembastIdentityLocalStore(
        database: db,
        contextKey: 'test|account-a',
        isCurrent: () => current,
      );
      expect((await reopened.read())?.pendingNames?.playerName, 'Nova');
      for (final context in ['prod|account-a', 'test|account-b']) {
        final other = SembastIdentityLocalStore(
          database: db,
          contextKey: context,
          isCurrent: () => true,
        );
        await expectLater(other.read(), throwsA(isA<IdentityException>()));
        await expectLater(
          other.write(const IdentityLocalState()),
          throwsA(isA<IdentityException>()),
        );
      }
      current = false;
      await expectLater(store.read(), throwsA(isA<IdentityException>()));
      await expectLater(
        store.write(const IdentityLocalState()),
        throwsA(isA<IdentityException>()),
      );
    },
  );

  test('Sembast rolls back a write retired inside its transaction', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'identity-local-rollback',
    );
    addTearDown(db.close);
    var checks = 0;
    final store = SembastIdentityLocalStore(
      database: db,
      contextKey: 'test|account-a',
      isCurrent: () => ++checks < 3,
    );
    await expectLater(
      store.write(
        IdentityLocalState(
          pendingNames: IdentityLocalNames(
            playerName: 'Nova',
            agentName: 'Rice',
          ),
        ),
      ),
      throwsA(isA<IdentityException>()),
    );
    final current = SembastIdentityLocalStore(
      database: db,
      contextKey: 'test|account-a',
      isCurrent: () => true,
    );
    expect(await current.read(), isNull);
  });

  test('offline edits cannot replace an already registered identity', () async {
    final store = _MemoryStore()
      ..value = IdentityLocalState(serverProfile: identityFixture());
    final service = IdentityService(
      gateway: _unavailable(),
      localStore: store,
      allowLocalSetup: () => true,
    );
    await service.restore();
    await expectLater(service.load(), throwsA(isA<IdentityException>()));
    expect(service.canSaveLocally, isFalse);
    await expectLater(
      service.saveSetup(playerName: 'Changed', agentName: 'Changed'),
      throwsA(isA<IdentityException>()),
    );
    expect(store.value?.pendingNames, isNull);
    expect(store.value?.serverProfile?.playerName, 'Star');
  });

  test(
    'SetSoul preserves locally saved setup names without an identity editor',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'identity-local-soul',
      );
      appServices.put<DBService>(db);
      final core = appServices.put(AgentCoreController());
      await core.ensureLoaded();
      appServices.put<SoulService>(_LocalSoul());
      final store = _MemoryStore()
        ..value = IdentityLocalState(
          pendingNames: IdentityLocalNames(
            playerName: 'Nova',
            agentName: 'Rice',
          ),
        );
      final identity = appServices.put(
        IdentityService(
          gateway: _unavailable(),
          localStore: store,
          allowLocalSetup: () => true,
        ),
      );
      await identity.restore();
      final method = SetSoulSkill().methods['setSoul']!;
      final same = jsonDecode(
        await method([
              jsonEncode({'name': 'Rice', 'age': 18}),
            ])
            as String,
      );
      expect(same['status'], 'ok');
      expect(core.profile.value?.nickname, 'Rice');
      expect(identity.completed, isFalse);
      final different = jsonDecode(
        await method([
              jsonEncode({'name': 'Other'}),
            ])
            as String,
      );
      expect(different['status'], 'agent_name_from_setup');
      expect(different.containsKey('route'), isFalse);
      expect(different['agentName'], 'Rice');
      expect(core.profile.value?.nickname, 'Rice');
      expect(store.writes, 0);
    },
  );

  test(
    'pending names survive closing and reopening the account database',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-identity-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/account.db';
      final database = await databaseFactoryIo.openDatabase(path);
      final first = IdentityService(
        gateway: _unavailable(),
        allowLocalSetup: () => true,
        localStore: SembastIdentityLocalStore(
          database: database,
          contextKey: 'test|account-a',
          isCurrent: () => true,
        ),
      );
      await expectLater(first.load(), throwsA(isA<IdentityException>()));
      await first.saveSetup(playerName: 'Nova', agentName: 'Rice');
      first.onClose();
      await database.close();
      final reopened = await databaseFactoryIo.openDatabase(path);
      addTearDown(reopened.close);
      final gateway = _unavailable();
      final second = IdentityService(
        gateway: gateway,
        allowLocalSetup: () => true,
        localStore: SembastIdentityLocalStore(
          database: reopened,
          contextKey: 'test|account-a',
          isCurrent: () => true,
        ),
      );
      await second.restore();
      expect(second.onboardingCompleted, isTrue);
      expect(second.pendingSync, isTrue);
      expect(second.setupPlayerName, 'Nova');
      expect(second.setupAgentName, 'Rice');
      expect(second.profile, isNull);
      expect(second.completed, isFalse);
      expect(gateway.reads + gateway.writes, 0);
    },
  );

  test(
    'an empty server read cannot erase a local save committing concurrently',
    () async {
      final store = _MemoryStore();
      final gateway = _unavailable();
      final service = IdentityService(
        gateway: gateway,
        localStore: store,
        allowLocalSetup: () => true,
      );
      await expectLater(service.load(), throwsA(isA<IdentityException>()));
      store.holdWrite = Completer<void>();
      final save = service.saveSetup(playerName: 'Nova', agentName: 'Rice');
      await Future<void>.delayed(Duration.zero);
      gateway.fetchOverride = null;
      final read = service.load();
      await Future<void>.delayed(Duration.zero);
      store.holdWrite!.complete();
      await save;
      await read;
      expect(service.onboardingCompleted, isTrue);
      expect(service.pendingSync, isTrue);
      expect(store.value?.pendingNames?.playerName, 'Nova');
      expect(store.value?.pendingNames?.agentName, 'Rice');
      expect(service.completed, isFalse);
      await service.load();
      expect(service.completed, isTrue);
      expect(service.pendingSync, isFalse);
      expect(gateway.writes, 1);
    },
  );
}
