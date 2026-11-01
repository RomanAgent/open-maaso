import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/firebase_bootstrap_service.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/push_token_registration_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bindingStateKey = 'maaso.notification.push-binding.v1';
const _installationKey = 'maaso.notification.installation.v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'gated Firebase deletion blocks B activation until A drain settles',
    () async {
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      await _eventually(() => harness.registrar.upserts.length == 1);

      final deleteGate = Completer<void>();
      harness.messaging.deleteGate = deleteGate;
      harness.session.value = null;
      final drain = harness.service.deactivateAccountAndDrain();
      final activation = harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );

      await _expectPending(drain);
      await _expectPending(activation);
      deleteGate.complete();
      await drain;
      await activation;

      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();
      await _eventually(() => harness.registrar.upserts.length == 2);
      expect(harness.registrar.upserts.last.accountUuid, 'account-b');
      expect(harness.registrar.upserts.last.token, 'fcm-b');
      expect(harness.messaging.operations, contains('delete.done'));

      await harness.close();
    },
  );

  test(
    'delete failure blocks activation and strict drain retries safely',
    () async {
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      await _eventually(() => harness.registrar.upserts.length == 1);
      harness.messaging.deleteFailures = 1;

      await expectLater(
        harness.service.deactivateAccountAndDrain(),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        harness.service.activateAccount(
          environmentKey: 'test',
          accountUuid: 'account-b',
        ),
        throwsA(isA<StateError>()),
      );

      await harness.service.deactivateAccountAndDrain();
      harness.session.value = null;
      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();
      await _eventually(() => harness.registrar.upserts.length == 2);
      expect(harness.registrar.upserts.last.token, 'fcm-b');

      await harness.close();
    },
  );

  test(
    'missing APNs token defers local cleanup without blocking account mount',
    () async {
      final harness = await _Harness.create(
        session: null,
        token: 'unknown-old-token',
        tokenAfterDelete: 'fresh-b-token',
        platformOverride: 'ios',
        apnsToken: null,
        apnsTokenUnavailable: true,
        apnsWaitTimeout: const Duration(milliseconds: 25),
        apnsPollInterval: const Duration(milliseconds: 5),
      );

      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();

      expect(harness.registrar.upserts, isEmpty);
      expect(harness.messaging.autoInitEnabled, isFalse);
      final pendingState =
          jsonDecode(harness.shared.getString(_bindingStateKey)!)
              as Map<String, dynamic>;
      expect(pendingState['localTokenCleanupRequired'], isTrue);

      // This is longer than the ordinary retry budget would cover. APNs
      // cleanup must remain recoverable without a user action or manual sync.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(harness.registrar.upserts, isEmpty);

      harness.messaging
        ..apnsToken = 'apns-b'
        ..apnsTokenUnavailable = false;
      await _eventually(() => harness.registrar.upserts.length == 1);

      expect(harness.registrar.upserts.single.accountUuid, 'account-b');
      expect(harness.registrar.upserts.single.token, 'fresh-b-token');
      final trustedState =
          jsonDecode(harness.shared.getString(_bindingStateKey)!)
              as Map<String, dynamic>;
      expect(trustedState['localTokenCleanupRequired'], isFalse);

      await harness.close();
    },
  );

  test(
    'late A token refresh cannot cross the deferred cleanup fence into B',
    () async {
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fresh-b-token',
        platformOverride: 'ios',
        retryBaseDelay: const Duration(seconds: 1),
        apnsWaitTimeout: const Duration(milliseconds: 25),
        apnsPollInterval: const Duration(milliseconds: 5),
      );
      await _eventually(() => harness.registrar.upserts.length == 1);

      harness.messaging
        ..apnsToken = null
        ..apnsTokenUnavailable = true;
      await harness.service.deactivateAccountAndDrain();
      harness.session.value = null;
      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();

      final enableGate = Completer<void>();
      harness.messaging
        ..apnsToken = 'apns-b'
        ..apnsTokenUnavailable = false
        ..autoInitEnableGate = enableGate;
      final priorEnableCount = harness.messaging.operations
          .where((operation) => operation == 'autoInit.true')
          .length;
      final sync = harness.service.sync();
      await _eventually(
        () =>
            harness.messaging.operations
                .where((operation) => operation == 'autoInit.true')
                .length >
            priorEnableCount,
      );

      harness.messaging.emitToken('late-a-token');
      enableGate.complete();
      await sync;
      await _eventually(() => harness.registrar.upserts.length == 2);

      expect(harness.registrar.upserts.last.accountUuid, 'account-b');
      expect(harness.registrar.upserts.last.token, 'fresh-b-token');
      expect(
        harness.registrar.upserts.map((binding) => binding.token),
        isNot(contains('late-a-token')),
      );

      await harness.close();
    },
  );

  test(
    'APNs cleanup journal failure still blocks account activation',
    () async {
      final harness = await _Harness.create(
        session: null,
        token: 'unknown-old-token',
        tokenAfterDelete: 'fresh-b-token',
        platformOverride: 'ios',
        apnsToken: null,
        apnsTokenUnavailable: true,
        bindingStateWriter: (_, _) async => false,
      );

      await expectLater(
        harness.service.activateAccount(
          environmentKey: 'test',
          accountUuid: 'account-b',
        ),
        throwsA(anything),
      );
      expect(harness.registrar.upserts, isEmpty);

      await harness.close();
    },
  );

  test(
    'timed-out registrar Future remains admitted until its A token settles',
    () async {
      final upsertGate = Completer<void>();
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
        operationTimeout: const Duration(milliseconds: 20),
        upsertGate: upsertGate,
      );
      await _eventually(() => harness.registrar.upserts.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 35));

      final drain = harness.service.deactivateAccountAndDrain();
      await _expectPending(drain);
      upsertGate.complete();
      await drain;
      expect(harness.messaging.deleteCount, greaterThan(0));
      expect(harness.registrar.accessTokens, contains('access-a'));

      await harness.close();
    },
  );

  test(
    'missing and corrupt binding authority fail closed before B bind',
    () async {
      for (final raw in <String?>[null, '{not-json']) {
        SharedPreferences.setMockInitialValues(
          raw == null
              ? <String, Object>{}
              : <String, Object>{_bindingStateKey: raw},
        );
        final harness = await _Harness.create(
          session: null,
          token: 'unknown-old-token',
          tokenAfterDelete: 'fresh-b-token',
          failDeletes: true,
        );

        await expectLater(
          harness.service.activateAccount(
            environmentKey: 'test',
            accountUuid: 'account-b',
          ),
          throwsA(isA<StateError>()),
        );
        expect(harness.registrar.upserts, isEmpty);

        harness.messaging.failDeletes = false;
        await harness.service.activateAccount(
          environmentKey: 'test',
          accountUuid: 'account-b',
        );
        harness.session.value = _session('account-b', 'access-b');
        await harness.service.sync();
        await _eventually(() => harness.registrar.upserts.length == 1);
        expect(harness.registrar.upserts.single.token, 'fresh-b-token');
        final stored =
            jsonDecode(harness.shared.getString(_bindingStateKey)!)
                as Map<String, dynamic>;
        expect(stored['version'], 2);
        expect(stored['localTokenCleanupRequired'], isFalse);

        await harness.close();
      }
    },
  );

  test('cold process rotates even a valid persisted cleanup proof', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      _bindingStateKey: jsonEncode(<String, Object?>{
        'version': 2,
        'lastIssuedRevision': 0,
        'localTokenCleanupRequired': false,
        'pendingRevocations': <Object?>[],
      }),
    });
    final harness = await _Harness.create(
      session: null,
      token: 'old-process-token',
      tokenAfterDelete: 'fresh-process-token',
      failDeletes: true,
    );

    await expectLater(
      harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      ),
      throwsA(isA<StateError>()),
    );
    expect(harness.registrar.upserts, isEmpty);

    harness.messaging.failDeletes = false;
    await harness.service.activateAccount(
      environmentKey: 'test',
      accountUuid: 'account-b',
    );
    harness.session.value = _session('account-b', 'access-b');
    await harness.service.sync();
    await _eventually(() => harness.registrar.upserts.length == 1);

    expect(harness.messaging.deleteCount, greaterThanOrEqualTo(2));
    expect(harness.registrar.upserts.single.token, 'fresh-process-token');
    await harness.close();
  });

  test(
    'valid v1 authority preserves the installation revision high-water',
    () async {
      const installationId = '0123456789abcdef0123456789abcdef';
      SharedPreferences.setMockInitialValues(<String, Object>{
        _installationKey: installationId,
        _bindingStateKey: jsonEncode(<String, Object?>{
          'version': 1,
          'lastIssuedRevision': 7,
          'active': _persistentBinding(
            installationId: installationId,
            accountUuid: 'account-a',
            revision: 7,
          ),
          'activeExpiresAt': DateTime.utc(2099).toIso8601String(),
          'pendingRevocations': <Object?>[],
        }),
      });
      final harness = await _Harness.create(
        session: null,
        token: 'old-v1-token',
        tokenAfterDelete: 'fresh-v1-token',
        initialRevisionLedger: const <String, int>{installationId: 7},
      );

      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      harness.session.value = _session('account-a', 'access-a');
      await harness.service.sync();
      await _eventually(() => harness.registrar.upserts.isNotEmpty);

      final binding = harness.registrar.upserts.single;
      expect(binding.installationId, installationId);
      expect(binding.bindingRevision, 8);
      expect(harness.registrar.rejectedUpserts, isEmpty);
      final stored =
          jsonDecode(harness.shared.getString(_bindingStateKey)!)
              as Map<String, dynamic>;
      expect(stored['version'], 2);
      expect(stored['lastIssuedRevision'], 8);
      await harness.close();
    },
  );

  test(
    'missing or corrupt Push authority preserves shared installation identity',
    () async {
      const oldInstallationId = 'fedcba9876543210fedcba9876543210';
      for (final raw in <String?>[null, '{not-json']) {
        SharedPreferences.setMockInitialValues(
          raw == null
              ? <String, Object>{_installationKey: oldInstallationId}
              : <String, Object>{
                  _installationKey: oldInstallationId,
                  _bindingStateKey: raw,
                },
        );
        final harness = await _Harness.create(
          session: null,
          token: 'unknown-old-token',
          tokenAfterDelete: 'fresh-rotated-token',
          initialRevisionLedger: const <String, int>{oldInstallationId: 1},
        );

        await harness.service.activateAccount(
          environmentKey: 'test',
          accountUuid: 'account-b',
        );
        harness.session.value = _session('account-b', 'access-b');
        await harness.service.sync();
        await _eventually(() => harness.registrar.upserts.length == 2);

        final binding = harness.registrar.upserts.last;
        expect(binding.installationId, oldInstallationId);
        expect(binding.bindingRevision, 2);
        expect(harness.registrar.rejectedUpserts, hasLength(1));
        expect(
          harness.shared.getString(_installationKey),
          binding.installationId,
        );
        await harness.close();
      }
    },
  );

  test(
    'receipt persistence failure blocks once and retry keeps no secret',
    () async {
      var failNextWrite = false;
      late SharedPreferences shared;
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
        bindingStateWriter: (key, value) async {
          if (failNextWrite) {
            failNextWrite = false;
            return false;
          }
          return shared.setString(key, value);
        },
        onSharedReady: (value) => shared = value,
      );
      await _eventually(() => harness.registrar.upserts.length == 1);

      failNextWrite = true;
      await expectLater(
        harness.service.deactivateAccountAndDrain(),
        throwsA(anything),
      );
      await expectLater(
        harness.service.activateAccount(
          environmentKey: 'test',
          accountUuid: 'account-b',
        ),
        throwsA(isA<StateError>()),
      );
      await harness.service.deactivateAccountAndDrain();

      final raw = harness.shared.getString(_bindingStateKey)!;
      expect(raw, isNot(contains('access-a')));
      expect(raw, isNot(contains('fcm-a')));
      expect(
        (jsonDecode(raw) as Map<String, dynamic>)['localTokenCleanupRequired'],
        isFalse,
      );
      await harness.close();
    },
  );

  test(
    'queued A token refresh is discarded before B subscription is armed',
    () async {
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      await _eventually(() => harness.registrar.upserts.length == 1);

      harness.messaging.emitToken('late-a-token');
      await harness.service.deactivateAccountAndDrain();
      harness.session.value = null;
      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();
      await _eventually(() => harness.registrar.upserts.length == 2);

      expect(
        harness.registrar.upserts.map((binding) => binding.token),
        isNot(contains('late-a-token')),
      );
      expect(harness.registrar.upserts.last.token, 'fcm-b');
      await harness.close();
    },
  );

  test(
    'failed A remote revoke never borrows B credentials on later sync',
    () async {
      final harness = await _Harness.create(
        session: _session('account-a', 'access-a'),
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      await _eventually(() => harness.registrar.upserts.length == 1);
      harness.registrar.removeFailures = 10;

      await harness.service.deactivateAccountAndDrain();
      final oldAccountAttempts = harness.registrar.removals.length;
      expect(oldAccountAttempts, greaterThan(0));
      expect(harness.registrar.removeAccessTokens, everyElement('access-a'));

      harness.session.value = null;
      await harness.service.activateAccount(
        environmentKey: 'test',
        accountUuid: 'account-b',
      );
      harness.session.value = _session('account-b', 'access-b');
      await harness.service.sync();
      await harness.service.sync();
      await _eventually(() => harness.registrar.upserts.length == 2);

      expect(harness.registrar.removals, hasLength(oldAccountAttempts));
      expect(harness.registrar.removeAccessTokens, everyElement('access-a'));
      expect(harness.registrar.upserts.last.accountUuid, 'account-b');
      await harness.close();
    },
  );

  test(
    'main mounts and drains the permanent push service at account boundary',
    () async {
      final source = await File('lib/main.dart').readAsString();
      final firebaseSource = await File(
        'lib/src/core/notifications/firebase_bootstrap_service.dart',
      ).readAsString();
      final disposeStart = source.indexOf(
        'Future<void> _disposeAccountRuntime',
      );
      final producerDrainStart = source.indexOf(
        'Future<void> _drainAccountRuntimeProducers',
        disposeStart,
      );
      final producerDrainEnd = source.indexOf(
        'void _registerDefaultVadServices',
        producerDrainStart,
      );
      final disposeBody = source.substring(disposeStart, producerDrainStart);
      final producerDrainBody = source.substring(
        producerDrainStart,
        producerDrainEnd,
      );
      expect(source, contains('?.activateAccount('));
      expect(producerDrainBody, contains("'push_token_registration'"));
      expect(producerDrainBody, contains('?.deactivateAccountAndDrain()'));
      expect(
        source.indexOf('?.activateAccount('),
        lessThan(source.indexOf('() => DBService().init(scope: accountScope)')),
      );
      expect(
        producerDrainBody.indexOf("'push_token_registration'"),
        lessThan(
          producerDrainBody.indexOf('await Future.wait<void>(<Future<void>>['),
        ),
      );
      expect(
        disposeBody.indexOf('await producerFence.fenceAndDrain()'),
        lessThan(disposeBody.indexOf('await appServices.delete<DBService>')),
      );
      expect(firebaseSource, contains("error.plugin == 'firebase_messaging'"));
      expect(firebaseSource, contains("error.code == 'apns-token-not-set'"));
      expect(firebaseSource, contains('FirebaseMessagingApnsTokenUnavailable'));
    },
  );
}

final class _Harness {
  _Harness({
    required this.shared,
    required this.session,
    required this.messaging,
    required this.registrar,
    required this.service,
  });

  final SharedPreferences shared;
  final Rxn<MaasoAuthSession> session;
  final _DrainMessagingGateway messaging;
  final _DrainRegistrar registrar;
  final PushTokenRegistrationService service;

  static Future<_Harness> create({
    required MaasoAuthSession? session,
    required String token,
    required String tokenAfterDelete,
    bool failDeletes = false,
    Duration operationTimeout = const Duration(milliseconds: 100),
    Completer<void>? upsertGate,
    Map<String, int> initialRevisionLedger = const <String, int>{},
    Future<bool> Function(String key, String value)? bindingStateWriter,
    void Function(SharedPreferences value)? onSharedReady,
    String platformOverride = 'android',
    String? apnsToken = 'apns',
    bool apnsTokenUnavailable = false,
    Duration apnsWaitTimeout = const Duration(milliseconds: 100),
    Duration apnsPollInterval = const Duration(milliseconds: 10),
    Duration retryBaseDelay = const Duration(milliseconds: 5),
    int maxRetryAttempts = 0,
  }) async {
    final shared = await SharedPreferences.getInstance();
    onSharedReady?.call(shared);
    final preferences = await NotificationPreferencesService.forTesting(
      preferences: shared,
    ).init();
    await preferences.setConsent(enabled: true, permissionGranted: true);
    final sessionSignal = Rxn<MaasoAuthSession>(session);
    final messaging =
        _DrainMessagingGateway(
            token: token,
            tokenAfterDelete: tokenAfterDelete,
            apnsToken: apnsToken,
          )
          ..failDeletes = failDeletes
          ..apnsTokenUnavailable = apnsTokenUnavailable;
    final registrar = _DrainRegistrar(
      upsertGate: upsertGate,
      initialRevisionLedger: initialRevisionLedger,
    );
    final service = await PushTokenRegistrationService(
      messaging: messaging,
      preferences: preferences,
      session: sessionSignal,
      environmentSignal: MaasoEnvironment.test.obs,
      registrar: registrar,
      sharedPreferences: shared,
      bindingStateWriter: bindingStateWriter,
      operationTimeout: operationTimeout,
      retryBaseDelay: retryBaseDelay,
      maxRetryAttempts: maxRetryAttempts,
      platformOverride: platformOverride,
      apnsWaitTimeout: apnsWaitTimeout,
      apnsPollInterval: apnsPollInterval,
    ).init();
    return _Harness(
      shared: shared,
      session: sessionSignal,
      messaging: messaging,
      registrar: registrar,
      service: service,
    );
  }

  Future<void> close() async {
    service.onClose();
    await messaging.close();
  }
}

final class _DrainRegistrar implements PushTokenRegistrar {
  _DrainRegistrar({
    this.upsertGate,
    Map<String, int> initialRevisionLedger = const <String, int>{},
  }) : revisionLedger = Map<String, int>.of(initialRevisionLedger);

  final Completer<void>? upsertGate;
  final upserts = <PushTokenBinding>[];
  final removals = <PushTokenBinding>[];
  final accessTokens = <String>[];
  final removeAccessTokens = <String>[];
  final operations = <String>[];
  final Map<String, int> revisionLedger;
  final rejectedUpserts = <PushTokenBinding>[];
  int removeFailures = 0;

  @override
  Future<PushTokenBindingLease> upsert(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    upserts.add(binding);
    accessTokens.add(accessToken);
    operations.add('upsert.${binding.accountUuid}');
    await upsertGate?.future;
    final previousRevision = revisionLedger[binding.installationId] ?? 0;
    if (binding.bindingRevision <= previousRevision) {
      rejectedUpserts.add(binding);
      throw PushTokenRevisionConflict(previousRevision + 1);
    }
    revisionLedger[binding.installationId] = binding.bindingRevision;
    return PushTokenBindingLease(
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 35)),
    );
  }

  @override
  Future<void> remove(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    removals.add(binding);
    accessTokens.add(accessToken);
    removeAccessTokens.add(accessToken);
    operations.add('remove.${binding.accountUuid}');
    if (removeFailures > 0) {
      removeFailures--;
      throw StateError('remove failed');
    }
  }
}

final class _DrainMessagingGateway implements FirebaseMessagingGateway {
  _DrainMessagingGateway({
    required this.token,
    required this.tokenAfterDelete,
    this.apnsToken = 'apns',
  });

  String? token;
  final String tokenAfterDelete;
  String? apnsToken;
  bool apnsTokenUnavailable = false;
  Completer<void>? deleteGate;
  Completer<void>? autoInitEnableGate;
  int deleteFailures = 0;
  bool failDeletes = false;
  int deleteCount = 0;
  bool autoInitEnabled = false;
  final operations = <String>[];
  final _foreground = StreamController<FirebasePushMessage>.broadcast();
  final _opened = StreamController<FirebasePushMessage>.broadcast();
  final _refreshes = StreamController<String>.broadcast();

  @override
  Stream<FirebasePushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<FirebasePushMessage> get openedMessages => _opened.stream;

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  void emitToken(String value) => _refreshes.add(value);

  @override
  Future<void> deleteToken() async {
    deleteCount++;
    operations.add('delete.start');
    await deleteGate?.future;
    if (apnsTokenUnavailable) {
      throw const FirebaseMessagingApnsTokenUnavailable();
    }
    if (failDeletes || deleteFailures > 0) {
      if (deleteFailures > 0) deleteFailures--;
      throw StateError('delete failed');
    }
    token = tokenAfterDelete;
    operations.add('delete.done');
  }

  @override
  Future<String?> getAPNSToken() async => apnsToken;

  @override
  Future<FirebasePushMessage?> getInitialMessage() async => null;

  @override
  Future<String?> getToken() async => token;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    autoInitEnabled = enabled;
    operations.add('autoInit.$enabled');
    if (enabled) await autoInitEnableGate?.future;
  }

  Future<void> close() async {
    await _foreground.close();
    await _opened.close();
    await _refreshes.close();
  }
}

MaasoAuthSession _session(String accountUuid, String accessToken) =>
    MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: accessToken,
      refreshToken: 'refresh-$accountUuid',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

Map<String, Object?> _persistentBinding({
  required String installationId,
  required String accountUuid,
  required int revision,
}) => <String, Object?>{
  'firebaseProjectId': FirebaseProjectContract.projectId,
  'tokenSha256': List<String>.filled(64, 'a').join(),
  'accountUuid': accountUuid,
  'environmentKey': 'test',
  'installationId': installationId,
  'platform': 'android',
  'bindingRevision': revision,
};

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

Future<void> _expectPending(Future<void> future) async {
  var settled = false;
  unawaited(
    future.then<void>(
      (_) => settled = true,
      onError: (Object _, StackTrace _) => settled = true,
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 15));
  expect(settled, isFalse);
}
