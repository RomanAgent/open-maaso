import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

Future<DBService> _memoryDatabase() => DBService().init(
  factory: databaseFactoryMemory,
  path: 'applet_ownership_${DateTime.now().microsecondsSinceEpoch}.db',
);

AgentWidget _applet(String id, {String? scope}) {
  final widget = AgentWidget(
    agentId: 'self',
    title: 'Applet $id',
    kind: 'surface',
    spec: <String, Object?>{'surfaceId': id, 'experienceType': 'utility'},
    createdAt: DateTime.utc(2026, 8, 8),
  );
  if (scope != null) {
    AppletLocalOwnership.stamp(widget, scopeKey: scope);
  }
  return widget;
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('public Applet summary is bounded plain display metadata', () {
    expect(
      normalizeAppletCatalogSummary('  塔防\n  游戏，支持三条路线。  '),
      '塔防 游戏，支持三条路线。',
    );
    expect(
      () => normalizeAppletCatalogSummary(List.filled(301, 'x').join()),
      throwsFormatException,
    );
    expect(
      () => normalizeAppletCatalogSummary(<String>['not text']),
      throwsFormatException,
    );
  });

  test(
    'legacy records stay device-only instead of attaching to an account',
    () {
      final legacy = _applet('legacy');

      expect(AppletLocalOwnership.storedScopeKey(legacy), 'device-legacy');
      expect(
        AppletLocalOwnership.isVisible(legacy, scopeKey: 'device-legacy'),
        isTrue,
      );
      expect(
        AppletLocalOwnership.isVisible(
          legacy,
          scopeKey: 'https://api.example|account-a',
        ),
        isFalse,
      );
    },
  );

  test('offline local creation accepts more than five Applets', () async {
    final database = await _memoryDatabase();
    for (var index = 0; index < 12; index++) {
      await AppletLocalOwnership.ensureCanCreate(
        database,
        proposedSurfaceId: 'local-$index',
      );
      await AppletLocalOwnership.saveNew(
        database,
        _applet('local-$index', scope: AppletLocalOwnership.deviceLegacyScope),
        expectedScopeKey: AppletLocalOwnership.deviceLegacyScope,
      );
    }
    expect(await database.getAllWidgets(), hasLength(12));
  });

  test(
    'signed-in local creation does not require a remote catalog service',
    () async {
      final database = await _memoryDatabase();
      await _signIn('account-a');
      final scope = AppletLocalOwnership.currentScopeKey();
      expect(appServices.isRegistered<AppletCatalogService>(), isFalse);
      for (var index = 0; index < 8; index++) {
        await AppletLocalOwnership.ensureCanCreate(database);
        await AppletLocalOwnership.saveNew(
          database,
          _applet('signed-in-$index', scope: scope),
          expectedScopeKey: scope,
        );
      }
      expect(await AppletLocalOwnership.ownedCount(database), 8);
    },
  );

  test(
    'unavailable registered cloud inventory cannot block local creation',
    () async {
      final database = await _memoryDatabase();
      final auth = await _signIn('account-a');
      final locale = appServices.put(LocaleConfigService());
      var requests = 0;
      appServices.put(
        AppletCatalogService(
          httpClient: MockClient((_) async {
            requests++;
            throw TimeoutException('cloud inventory unavailable');
          }),
          auth: auth,
          environment: appServices.find<AppEnvironmentService>(),
          locale: locale,
        ),
      );
      final scope = AppletLocalOwnership.currentScopeKey();

      await AppletLocalOwnership.ensureCanCreate(database);
      await AppletLocalOwnership.saveNew(
        database,
        _applet('cloud-unavailable', scope: scope),
        expectedScopeKey: scope,
      );
      expect(await database.getAllWidgets(), hasLength(1));
      expect(requests, 0);
    },
  );

  test('a previous account cannot create under a stale scope', () async {
    final database = await _memoryDatabase();
    final auth = await _signIn('account-a');
    final previousScope = AppletLocalOwnership.currentScopeKey();
    auth.session.value = _session('account-b');

    await expectLater(
      AppletLocalOwnership.ensureCanCreate(database, scopeKey: previousScope),
      throwsA(isA<AppletQuotaUnavailableException>()),
    );
    await expectLater(
      AppletLocalOwnership.saveNew(
        database,
        _applet('previous-account', scope: previousScope),
        expectedScopeKey: previousScope,
      ),
      throwsA(isA<AppletQuotaUnavailableException>()),
    );
    expect(await database.getAllWidgets(), isEmpty);
  });

  test('account change invalidates an in-flight local preflight', () async {
    final database = await _memoryDatabase();
    final auth = await _signIn('account-a');
    final checking = AppletLocalOwnership.ensureCanCreate(database);
    auth.session.value = _session('account-b');
    await expectLater(
      checking,
      throwsA(isA<AppletQuotaUnavailableException>()),
    );
    expect(await database.getAllWidgets(), isEmpty);
  });

  test('unlimited local ownership remains isolated across accounts', () async {
    final database = await _memoryDatabase();
    final auth = await _signIn('account-a');
    final scopeA = AppletLocalOwnership.currentScopeKey();
    for (var index = 0; index < 8; index++) {
      await AppletLocalOwnership.saveNew(
        database,
        _applet('surface-$index', scope: scopeA),
        expectedScopeKey: scopeA,
      );
    }
    auth.session.value = _session('account-b');
    final scopeB = AppletLocalOwnership.currentScopeKey();
    await AppletLocalOwnership.saveNew(
      database,
      _applet('surface-0', scope: scopeB),
      expectedScopeKey: scopeB,
    );
    expect(
      await AppletLocalOwnership.ownedCount(database, scopeKey: scopeA),
      8,
    );
    expect(
      await AppletLocalOwnership.ownedCount(database, scopeKey: scopeB),
      1,
    );

    final ownedByB = (await database.getAllWidgets()).firstWhere(
      (item) => AppletLocalOwnership.isVisible(item, scopeKey: scopeB),
    );
    await database.deleteWidget(ownedByB.id!);
    await AppletLocalOwnership.ensureCanCreate(database);
    expect(
      await AppletLocalOwnership.ownedCount(database, scopeKey: scopeA),
      8,
    );
    expect(await AppletLocalOwnership.ownedCount(database), 0);
  });

  test(
    'editing an existing Applet remains allowed after many local creations',
    () async {
      final database = await _memoryDatabase();
      await _signIn('account-a');
      final scope = AppletLocalOwnership.currentScopeKey();
      for (var index = 0; index < 8; index++) {
        await database.saveAgentWidget(_applet('surface-$index', scope: scope));
      }

      await AppletLocalOwnership.ensureCanCreate(
        database,
        scopeKey: scope,
        existingSurfaceId: 'surface-2',
      );
    },
  );

  test('concurrent creation keeps one local record per Surface id', () async {
    final database = await _memoryDatabase();
    final first = _applet('same-surface', scope: 'device-legacy');
    final second = _applet('same-surface', scope: 'device-legacy');

    final outcomes = await Future.wait(
      <AgentWidget>[first, second].map((widget) async {
        try {
          await AppletLocalOwnership.saveNew(
            database,
            widget,
            expectedScopeKey: AppletLocalOwnership.deviceLegacyScope,
          );
          return 'saved';
        } catch (error) {
          return error.toString();
        }
      }),
    );

    expect(outcomes.where((value) => value == 'saved'), hasLength(1));
    expect(
      outcomes.where((value) => value.contains('duplicate_applet_surface_id')),
      hasLength(1),
    );
    expect(await database.getAllWidgets(), hasLength(1));
  });

  test(
    'authority revocation rolls back an in-flight validated insert',
    () async {
      final database = await _memoryDatabase();
      final widget = _applet('revoked', scope: 'device-legacy');
      var checks = 0;

      await expectLater(
        AppletLocalOwnership.saveNew(
          database,
          widget,
          expectedScopeKey: AppletLocalOwnership.deviceLegacyScope,
          validateAuthority: () {
            checks++;
            if (checks >= 3) throw StateError('authority_revoked');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(checks, greaterThanOrEqualTo(3));
      expect(await database.getAllWidgets(), isEmpty);
    },
  );

  test('account change rolls back an in-flight validated insert', () async {
    final database = await _memoryDatabase();
    final auth = await _signIn('account-a');
    final scope = AppletLocalOwnership.currentScopeKey();
    var checks = 0;
    await expectLater(
      AppletLocalOwnership.saveNew(
        database,
        _applet('scope-changed', scope: scope),
        expectedScopeKey: scope,
        validateAuthority: () {
          checks++;
          if (checks == 3) auth.session.value = _session('account-b');
        },
      ),
      throwsA(isA<AppletQuotaUnavailableException>()),
    );
    expect(checks, greaterThanOrEqualTo(3));
    expect(await database.getAllWidgets(), isEmpty);
  });

  test('concurrent distinct local Applets are not capped at five', () async {
    final database = await _memoryDatabase();

    final outcomes = await Future.wait(
      List<AgentWidget>.generate(
        30,
        (index) => _applet('surface-$index', scope: 'device-legacy'),
      ).map((widget) async {
        try {
          await AppletLocalOwnership.saveNew(
            database,
            widget,
            expectedScopeKey: AppletLocalOwnership.deviceLegacyScope,
          );
          return 'saved';
        } catch (error) {
          return error.toString();
        }
      }),
    );

    expect(outcomes.where((value) => value == 'saved'), hasLength(30));
    expect(await database.getAllWidgets(), hasLength(30));
  });

  test(
    'concurrent signed-in local Applets require no cloud inventory',
    () async {
      final database = await _memoryDatabase();
      await _signIn('account-a');
      final scope = AppletLocalOwnership.currentScopeKey();
      final outcomes = await Future.wait(
        List<AgentWidget>.generate(
          30,
          (index) => _applet('signed-in-$index', scope: scope),
        ).map((widget) async {
          try {
            await AppletLocalOwnership.saveNew(
              database,
              widget,
              expectedScopeKey: scope,
            );
            return 'saved';
          } catch (error) {
            return error.toString();
          }
        }),
      );

      expect(outcomes.where((value) => value == 'saved'), hasLength(30));
      expect(await database.getAllWidgets(), hasLength(30));
    },
  );

  test('a duplicate proposed Surface id is still rejected locally', () async {
    final database = await _memoryDatabase();
    await database.saveAgentWidget(_applet('existing-id'));

    await expectLater(
      AppletLocalOwnership.ensureCanCreate(
        database,
        proposedSurfaceId: 'existing-id',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'duplicate_applet_surface_id',
        ),
      ),
    );
  });

  test('a widget stamped for another account cannot be inserted', () async {
    final database = await _memoryDatabase();
    await _signIn('account-a');
    final scope = AppletLocalOwnership.currentScopeKey();
    await expectLater(
      AppletLocalOwnership.saveNew(
        database,
        _applet('wrong-owner', scope: 'https://api.example|account-b'),
        expectedScopeKey: scope,
      ),
      throwsA(isA<AppletQuotaUnavailableException>()),
    );
    expect(await database.getAllWidgets(), isEmpty);
  });
}

Future<AuthSessionService> _signIn(String account) async {
  appServices.put<SecureStorageService>(_MemorySecureStorage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async {
        throw UnimplementedError('Auth refresh is not expected');
      }),
    ),
  );
  await auth.init();
  auth.session.value = _session(account);
  return auth;
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token-$account',
  refreshToken: 'refresh-$account',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
