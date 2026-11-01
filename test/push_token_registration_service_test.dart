import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/notifications/firebase_bootstrap_service.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/notifications/push_token_registration_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'binds token to account, environment, installation and platform',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
      final environment = MaasoEnvironment.test.obs;
      final messaging = _FakeMessagingGateway(token: 'fcm-a');
      final registrar = _FakeRegistrar();
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: session,
        environment: environment,
        registrar: registrar,
        shared: shared,
      ).init();

      await _eventually(() => registrar.upserts.length == 1);
      final binding = registrar.upserts.single;
      expect(binding.firebaseProjectId, 'masso-app-prod');
      expect(binding.token, 'fcm-a');
      expect(binding.accountUuid, 'account-a');
      expect(binding.environmentKey, 'test');
      expect(binding.installationId, hasLength(32));
      expect(binding.platform, isNotEmpty);
      expect(binding.bindingRevision, 1);
      expect(service.isRegistered.value, isTrue);

      service.onClose();
      await messaging.close();
    },
  );

  test(
    'environment switch removes old binding before registering new scope',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
      final environment = MaasoEnvironment.test.obs;
      final messaging = _FakeMessagingGateway(
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      final registrar = _FakeRegistrar();
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: session,
        environment: environment,
        registrar: registrar,
        shared: shared,
      ).init();

      await _eventually(() => registrar.upserts.length == 1);
      environment.value = MaasoEnvironment.production;
      await _eventually(() => registrar.removals.length == 1);
      expect(registrar.upserts, hasLength(1));

      // AuthSessionService emits after activating the newly scoped session.
      session.refresh();
      await _eventually(() => registrar.upserts.length == 2);

      expect(registrar.removals.single.environmentKey, 'test');
      expect(registrar.upserts.last.environmentKey, 'prod');
      expect(registrar.upserts.last.token, 'fcm-b');

      session.value = null;
      await _eventually(() => registrar.removals.length == 2);
      expect(service.isRegistered.value, isFalse);

      service.onClose();
      await messaging.close();
    },
  );

  test('revoking consent unregisters and deletes the FCM token', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: session,
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
    ).init();

    await _eventually(() => registrar.upserts.length == 1);
    await preferences.setConsent(enabled: false, permissionGranted: true);
    await _eventually(() => messaging.deleteCount > 0);

    expect(registrar.removals, hasLength(1));
    expect(messaging.autoInitEnabled, isFalse);
    expect(service.isRegistered.value, isFalse);

    service.onClose();
    await messaging.close();
  });

  test(
    'failed remote revocation keeps retry after local token deletion',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final messaging = _FakeMessagingGateway(token: 'fcm-a');
      var failRemoval = true;
      final registrar = _FakeRegistrar(
        onRemove: (_, _) async {
          if (failRemoval) throw StateError('temporary backend failure');
        },
      );
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
        environment: MaasoEnvironment.test.obs,
        registrar: registrar,
        shared: shared,
        retryBaseDelay: const Duration(milliseconds: 25),
        maxRetryAttempts: 5,
      ).init();
      await _eventually(() => registrar.upserts.length == 1);

      await preferences.setConsent(enabled: false, permissionGranted: true);
      await _eventually(
        () => registrar.removals.isNotEmpty && messaging.deleteCount == 1,
      );
      final storedWhileFailed =
          jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
              as Map<String, dynamic>;
      expect(storedWhileFailed['pendingRevocations'], isNotEmpty);

      failRemoval = false;
      await _eventually(() => registrar.removals.length >= 2);
      await _eventually(() {
        final stored =
            jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
                as Map<String, dynamic>;
        return (stored['pendingRevocations'] as List).isEmpty;
      });
      expect(messaging.deleteCount, 1);

      service.onClose();
      await messaging.close();
    },
  );

  test(
    'pending revocation survives restart and retries after reauth',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final firstMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final firstRegistrar = _FakeRegistrar(
        onRemove: (_, _) async => throw StateError('backend unavailable'),
      );
      final first = await _service(
        messaging: firstMessaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
        environment: MaasoEnvironment.test.obs,
        registrar: firstRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => firstRegistrar.upserts.length == 1);
      await preferences.setConsent(enabled: false, permissionGranted: true);
      await _eventually(
        () =>
            firstRegistrar.removals.length == 1 &&
            firstMessaging.deleteCount == 1,
      );
      first.onClose();
      await firstMessaging.close();

      final persisted =
          jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
              as Map<String, dynamic>;
      expect(persisted['pendingRevocations'], isNotEmpty);
      expect(jsonEncode(persisted), isNot(contains('access-a')));
      expect(jsonEncode(persisted), isNot(contains('fcm-a')));

      final secondMessaging = _FakeMessagingGateway(token: 'fcm-b');
      final secondRegistrar = _FakeRegistrar();
      final second = await _service(
        messaging: secondMessaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-b')),
        environment: MaasoEnvironment.test.obs,
        registrar: secondRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => secondRegistrar.removals.length == 1);
      await _eventually(() {
        final stored =
            jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
                as Map<String, dynamic>;
        return (stored['pendingRevocations'] as List).isEmpty;
      });

      second.onClose();
      await secondMessaging.close();
    },
  );

  test(
    'missing or invalid session disables auto-init and deletes token',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final messaging = _FakeMessagingGateway(token: 'fcm-a');
      final registrar = _FakeRegistrar();
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(),
        environment: MaasoEnvironment.test.obs,
        registrar: registrar,
        shared: shared,
      ).init();

      await _eventually(() => messaging.deleteCount == 1);

      expect(messaging.autoInitEnabled, isFalse);
      expect(messaging.getTokenCount, 0);
      expect(registrar.upserts, isEmpty);
      expect(service.isRegistered.value, isFalse);

      service.onClose();
      await messaging.close();
    },
  );

  test(
    'cold restart restores non-secret binding metadata and confirms it',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
      final firstMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final firstRegistrar = _FakeRegistrar();
      final first = await _service(
        messaging: firstMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: firstRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => firstRegistrar.upserts.length == 1);

      final stored = shared.getString('maaso.notification.push-binding.v1');
      expect(stored, isNotNull);
      expect(stored, isNot(contains('fcm-a')));
      expect(stored, isNot(contains('access-a')));
      expect(stored, contains('tokenSha256'));
      expect(stored, contains('activeExpiresAt'));
      first.onClose();
      await firstMessaging.close();

      final secondMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final secondRegistrar = _FakeRegistrar();
      final second = await _service(
        messaging: secondMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: secondRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => secondRegistrar.upserts.length == 1);

      expect(secondRegistrar.upserts.single.bindingRevision, 1);
      expect(second.isRegistered.value, isTrue);

      second.onClose();
      await secondMessaging.close();
    },
  );

  test(
    'TTL-expired cold restart persists server minimum and retries once',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
      final firstMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final firstRegistrar = _FakeRegistrar();
      final first = await _service(
        messaging: firstMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: firstRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => firstRegistrar.upserts.length == 1);
      first.onClose();
      await firstMessaging.close();

      final secondMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final secondRegistrar = _FakeRegistrar(
        onUpsert: (binding, _) async {
          if (binding.bindingRevision == 1) {
            throw const PushTokenRevisionConflict(2);
          }
        },
      );
      final second = await _service(
        messaging: secondMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: secondRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => secondRegistrar.upserts.length == 2);
      await _eventually(() => second.isRegistered.value);

      expect(
        secondRegistrar.upserts.map((binding) => binding.bindingRevision),
        <int>[1, 2],
      );
      expect(secondMessaging.deleteCount, 0);
      final persisted =
          jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
              as Map<String, dynamic>;
      expect(persisted['lastIssuedRevision'], 2);
      expect(
        (persisted['active'] as Map<String, dynamic>)['bindingRevision'],
        2,
      );

      second.onClose();
      await secondMessaging.close();
    },
  );

  test(
    'revision conflict recovery is one retry and reuses high-water on restart',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
      final seedMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final seedRegistrar = _FakeRegistrar();
      final seed = await _service(
        messaging: seedMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: seedRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => seedRegistrar.upserts.length == 1);
      seed.onClose();
      await seedMessaging.close();

      final failedMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final failedRegistrar = _FakeRegistrar(
        onUpsert: (binding, _) async {
          throw PushTokenRevisionConflict(binding.bindingRevision + 1);
        },
      );
      final failed = await _service(
        messaging: failedMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: failedRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => failedRegistrar.upserts.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(failedRegistrar.upserts, hasLength(2));
      expect(
        failedRegistrar.upserts.map((binding) => binding.bindingRevision),
        <int>[1, 2],
      );
      expect(failed.isRegistered.value, isFalse);
      final failedState =
          jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
              as Map<String, dynamic>;
      expect(failedState['lastIssuedRevision'], 2);
      failed.onClose();
      await failedMessaging.close();

      final restartedMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final restartedRegistrar = _FakeRegistrar();
      final restarted = await _service(
        messaging: restartedMessaging,
        preferences: preferences,
        session: session,
        environment: MaasoEnvironment.test.obs,
        registrar: restartedRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => restartedRegistrar.upserts.length == 1);
      expect(restartedRegistrar.upserts.single.bindingRevision, 2);
      expect(restarted.isRegistered.value, isTrue);

      restarted.onClose();
      await restartedMessaging.close();
    },
  );

  test('generic conflict never mints a higher revision', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
    final seedMessaging = _FakeMessagingGateway(token: 'fcm-a');
    final seedRegistrar = _FakeRegistrar();
    final seed = await _service(
      messaging: seedMessaging,
      preferences: preferences,
      session: session,
      environment: MaasoEnvironment.test.obs,
      registrar: seedRegistrar,
      shared: shared,
    ).init();
    await _eventually(() => seedRegistrar.upserts.length == 1);
    seed.onClose();
    await seedMessaging.close();

    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar(
      onUpsert: (_, _) async => throw StateError('generic conflict'),
    );
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: session,
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
    ).init();
    await _eventually(() => registrar.upserts.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(registrar.upserts, hasLength(1));
    expect(registrar.upserts.single.bindingRevision, 1);
    final persisted =
        jsonDecode(shared.getString('maaso.notification.push-binding.v1')!)
            as Map<String, dynamic>;
    expect(persisted['lastIssuedRevision'], 1);

    service.onClose();
    await messaging.close();
  });

  test('long-running process renews the exact binding before TTL', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
      bindingRenewalLeadTime:
          const Duration(days: 35) - const Duration(milliseconds: 80),
      bindingRenewalJitterWindow: Duration.zero,
    ).init();

    await _eventually(() => registrar.upserts.length >= 2);
    expect(
      registrar.upserts.take(2).map((binding) => binding.bindingRevision),
      <int>[1, 1],
    );
    expect(
      registrar.upserts.take(2).map((binding) => binding.accountUuid),
      everyElement('account-a'),
    );
    expect(registrar.removals, isEmpty);
    expect(messaging.deleteCount, 0);

    service.onClose();
    await messaging.close();
  });

  test(
    'renewal outage exhausts immediate retries then recovers before expiry',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final messaging = _FakeMessagingGateway(token: 'fcm-a');
      var attempt = 0;
      final registrar = _FakeRegistrar(
        onUpsert: (_, _) async {
          attempt++;
          if (attempt >= 2 && attempt <= 4) {
            throw StateError('renewal outage');
          }
        },
      );
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
        environment: MaasoEnvironment.test.obs,
        registrar: registrar,
        shared: shared,
        retryBaseDelay: const Duration(milliseconds: 5),
        maxRetryAttempts: 2,
        bindingRenewalLeadTime:
            const Duration(days: 35) - const Duration(milliseconds: 80),
        bindingRenewalJitterWindow: Duration.zero,
        bindingRenewalRetryDelay: const Duration(milliseconds: 60),
      ).init();

      await _eventually(() => registrar.upserts.length >= 5);
      await _eventually(() => service.isRegistered.value);
      expect(
        registrar.upserts.take(5).map((binding) => binding.bindingRevision),
        everyElement(1),
      );
      expect(registrar.removals, isEmpty);
      expect(messaging.deleteCount, 0);

      service.onClose();
      await messaging.close();
    },
  );

  test('startup bind failure has no lease-driven retry churn', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar(
      onUpsert: (_, _) async => throw StateError('startup outage'),
    );
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
      retryBaseDelay: const Duration(milliseconds: 5),
      maxRetryAttempts: 2,
      bindingRenewalRetryDelay: const Duration(milliseconds: 30),
    ).init();

    await _eventually(() => registrar.upserts.length == 3);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(registrar.upserts, hasLength(3));
    expect(service.isRegistered.value, isFalse);

    service.onClose();
    await messaging.close();
  });

  test('scope switch cancels the old binding renewal timer', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final environment = MaasoEnvironment.test.obs;
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: environment,
      registrar: registrar,
      shared: shared,
      bindingRenewalLeadTime:
          const Duration(days: 35) - const Duration(milliseconds: 150),
      bindingRenewalJitterWindow: Duration.zero,
    ).init();
    await _eventually(() => registrar.upserts.length == 1);

    environment.value = MaasoEnvironment.production;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(registrar.upserts, hasLength(1));

    service.onClose();
    await messaging.close();
  });

  test('close cancels the binding renewal timer', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
      bindingRenewalLeadTime:
          const Duration(days: 35) - const Duration(milliseconds: 150),
      bindingRenewalJitterWindow: Duration.zero,
    ).init();
    await _eventually(() => registrar.upserts.length == 1);

    service.onClose();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(registrar.upserts, hasLength(1));
    await messaging.close();
  });

  test('too-short and over-far binding leases fail closed', () async {
    for (final leaseDuration in <Duration>[
      const Duration(hours: 1),
      const Duration(days: 40),
    ]) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final messaging = _FakeMessagingGateway(token: 'fcm-a');
      final registrar = _FakeRegistrar(
        expiresAtFor: (_) => DateTime.now().toUtc().add(leaseDuration),
      );
      final service = await _service(
        messaging: messaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
        environment: MaasoEnvironment.test.obs,
        registrar: registrar,
        shared: shared,
      ).init();

      await _eventually(() => registrar.upserts.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(registrar.upserts, hasLength(1));
      expect(service.isRegistered.value, isFalse);
      expect(service.error.value, contains('binding lease'));

      service.onClose();
      await messaging.close();
    }
  });

  test(
    'cold restart with stale account rotates local token before transfer',
    () async {
      final shared = await SharedPreferences.getInstance();
      final preferences = await _enabledPreferences(shared);
      final firstMessaging = _FakeMessagingGateway(token: 'fcm-a');
      final firstRegistrar = _FakeRegistrar();
      final first = await _service(
        messaging: firstMessaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
        environment: MaasoEnvironment.test.obs,
        registrar: firstRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => firstRegistrar.upserts.length == 1);
      first.onClose();
      await firstMessaging.close();

      final secondMessaging = _FakeMessagingGateway(
        token: 'fcm-a',
        tokenAfterDelete: 'fcm-b',
      );
      final secondRegistrar = _FakeRegistrar();
      final second = await _service(
        messaging: secondMessaging,
        preferences: preferences,
        session: Rxn<MaasoAuthSession>(_session('account-b', 'access-b')),
        environment: MaasoEnvironment.test.obs,
        registrar: secondRegistrar,
        shared: shared,
      ).init();
      await _eventually(() => secondRegistrar.upserts.length == 1);

      expect(secondMessaging.deleteCount, 1);
      expect(secondRegistrar.removals, isEmpty);
      expect(secondRegistrar.upserts.single.accountUuid, 'account-b');
      expect(secondRegistrar.upserts.single.token, 'fcm-b');
      expect(secondRegistrar.upserts.single.bindingRevision, 2);

      second.onClose();
      await secondMessaging.close();
    },
  );

  test(
    'getToken exception and timeout are deferred without registration',
    () async {
      for (final getToken in <Future<String?> Function()>[
        () async => throw StateError('provider failure'),
        () => Completer<String?>().future,
      ]) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final shared = await SharedPreferences.getInstance();
        final preferences = await _enabledPreferences(shared);
        final messaging = _FakeMessagingGateway(
          token: null,
          getTokenOverride: getToken,
        );
        final registrar = _FakeRegistrar();
        final service = await _service(
          messaging: messaging,
          preferences: preferences,
          session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
          environment: MaasoEnvironment.test.obs,
          registrar: registrar,
          shared: shared,
          operationTimeout: const Duration(milliseconds: 20),
        ).init();

        await service.sync();
        expect(registrar.upserts, isEmpty);
        expect(service.isRegistered.value, isFalse);
        expect(service.error.value, contains('read FCM token'));
        expect(service.error.value, isNot(contains('provider failure')));

        service.onClose();
        await messaging.close();
      }
    },
  );

  test('Apple token wait is bounded before getToken', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final messaging = _FakeMessagingGateway(token: 'fcm-a', apnsToken: null);
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
      operationTimeout: const Duration(milliseconds: 50),
      platformOverride: 'ios',
      apnsWaitTimeout: const Duration(milliseconds: 25),
      apnsPollInterval: const Duration(milliseconds: 5),
    ).init();

    await service.sync();

    expect(messaging.apnsTokenReadCount, greaterThan(0));
    expect(messaging.getTokenCount, 0);
    expect(registrar.upserts, isEmpty);
    expect(service.error.value, contains('APNs token'));

    service.onClose();
    await messaging.close();
  });

  test('token refresh stream errors are contained and redacted', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final messaging = _FakeMessagingGateway(token: 'fcm-a');
    final registrar = _FakeRegistrar();
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: Rxn<MaasoAuthSession>(_session('account-a', 'access-a')),
      environment: MaasoEnvironment.test.obs,
      registrar: registrar,
      shared: shared,
    ).init();
    await _eventually(() => registrar.upserts.length == 1);

    messaging.addTokenError(StateError('sensitive-fcm-token'));
    await _eventually(
      () => service.error.value?.contains('token refresh stream') == true,
    );

    expect(service.error.value, isNot(contains('sensitive-fcm-token')));

    service.onClose();
    await messaging.close();
  });

  test('scope switch during upsert fences stale completion', () async {
    final shared = await SharedPreferences.getInstance();
    final preferences = await _enabledPreferences(shared);
    final session = Rxn<MaasoAuthSession>(_session('account-a', 'access-a'));
    final environment = MaasoEnvironment.test.obs;
    final messaging = _FakeMessagingGateway(
      token: 'fcm-a',
      tokenAfterDelete: 'fcm-b',
    );
    final firstUpsert = Completer<void>();
    final registrar = _FakeRegistrar(
      onUpsert: (binding, _) =>
          binding.environmentKey == 'test' ? firstUpsert.future : null,
    );
    final service = await _service(
      messaging: messaging,
      preferences: preferences,
      session: session,
      environment: environment,
      registrar: registrar,
      shared: shared,
      operationTimeout: const Duration(seconds: 1),
    ).init();

    await _eventually(() => registrar.upserts.length == 1);
    environment.value = MaasoEnvironment.production;
    session.refresh();
    firstUpsert.complete();

    await _eventually(() => registrar.upserts.length == 2);
    expect(registrar.upserts.first.environmentKey, 'test');
    expect(registrar.upserts.last.environmentKey, 'prod');
    expect(registrar.upserts.last.token, 'fcm-b');
    expect(messaging.deleteCount, 1);
    expect(service.isRegistered.value, isTrue);

    service.onClose();
    await messaging.close();
  });

  test(
    'HTTP registrar bounds POST actions and omits raw token on revoke',
    () async {
      final binding = _binding();
      final hanging = HttpPushTokenRegistrar(
        client: _HangingClient(),
        requestTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        hanging.upsert(binding, accessToken: 'access-a'),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(
        hanging.remove(binding, accessToken: 'access-a'),
        throwsA(isA<TimeoutException>()),
      );

      final recording = _RecordingClient();
      final registrar = HttpPushTokenRegistrar(client: recording);
      await registrar.upsert(binding, accessToken: 'access-a');
      await registrar.remove(binding, accessToken: 'access-a');
      expect(recording.methods, everyElement('POST'));
      expect(recording.paths, <String>[
        '/v1/notifications/push-tokens/'
            '0123456789abcdef0123456789abcdef/bind',
        '/v1/notifications/push-tokens/'
            '0123456789abcdef0123456789abcdef/revoke',
      ]);
      final body = jsonDecode(recording.bodies.last) as Map<String, dynamic>;
      expect(body, isNot(contains('token')));
      expect(body['tokenSha256'], binding.tokenSha256);
      expect(body['bindingRevision'], 7);
    },
  );

  test(
    'HTTP registrar accepts only bounded conflict revision envelope',
    () async {
      final binding = _binding();
      final recoverable = HttpPushTokenRegistrar(
        client: _StaticResponseClient(
          statusCode: 409,
          body: jsonEncode(<String, Object?>{
            'code': 'CONFLICT',
            'message': 'conflict',
            'traceId': 'trace-a',
            'data': <String, Object?>{'minimumBindingRevision': 8},
          }),
        ),
      );
      await expectLater(
        recoverable.upsert(binding, accessToken: 'access-a'),
        throwsA(
          isA<PushTokenRevisionConflict>().having(
            (error) => error.minimumBindingRevision,
            'minimumBindingRevision',
            8,
          ),
        ),
      );

      final untrusted = HttpPushTokenRegistrar(
        client: _StaticResponseClient(
          statusCode: 409,
          body: jsonEncode(<String, Object?>{'code': 'CONFLICT', 'data': null}),
        ),
      );
      try {
        await untrusted.upsert(binding, accessToken: 'access-a');
        fail('untrusted conflict unexpectedly succeeded');
      } catch (error) {
        expect(error, isNot(isA<PushTokenRevisionConflict>()));
      }

      final malformedLease = HttpPushTokenRegistrar(
        client: _StaticResponseClient(
          statusCode: 200,
          body: jsonEncode(<String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'accepted': true,
              'bindingRevision': binding.bindingRevision,
              'expiresAt': '2026-09-14T00:00:00+00:00',
            },
          }),
        ),
      );
      try {
        await malformedLease.upsert(binding, accessToken: 'access-a');
        fail('non-canonical binding lease unexpectedly succeeded');
      } catch (error) {
        expect(error, isNot(isA<PushTokenRevisionConflict>()));
      }

      final hangingBody = HttpPushTokenRegistrar(
        client: _HangingResponseClient(),
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        hangingBody.upsert(binding, accessToken: 'access-a'),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}

PushTokenRegistrationService _service({
  required _FakeMessagingGateway messaging,
  required NotificationPreferencesService preferences,
  required AppReactiveValue<MaasoAuthSession?> session,
  required AppReactiveValue<MaasoEnvironment> environment,
  required _FakeRegistrar registrar,
  required SharedPreferences shared,
  Duration operationTimeout = const Duration(milliseconds: 250),
  Duration apnsWaitTimeout = const Duration(milliseconds: 100),
  Duration apnsPollInterval = const Duration(milliseconds: 10),
  Duration retryBaseDelay = const Duration(milliseconds: 5),
  int maxRetryAttempts = 0,
  String platformOverride = 'android',
  Duration bindingRenewalLeadTime = const Duration(days: 7),
  Duration bindingRenewalJitterWindow = const Duration(days: 1),
  Duration bindingRenewalRetryDelay = const Duration(hours: 6),
  DateTime Function()? clock,
}) => PushTokenRegistrationService(
  messaging: messaging,
  preferences: preferences,
  session: session,
  environmentSignal: environment,
  registrar: registrar,
  sharedPreferences: shared,
  operationTimeout: operationTimeout,
  apnsWaitTimeout: apnsWaitTimeout,
  apnsPollInterval: apnsPollInterval,
  retryBaseDelay: retryBaseDelay,
  maxRetryAttempts: maxRetryAttempts,
  platformOverride: platformOverride,
  bindingRenewalLeadTime: bindingRenewalLeadTime,
  bindingRenewalJitterWindow: bindingRenewalJitterWindow,
  bindingRenewalRetryDelay: bindingRenewalRetryDelay,
  clock: clock,
);

Future<NotificationPreferencesService> _enabledPreferences(
  SharedPreferences shared,
) async {
  final preferences = await NotificationPreferencesService.forTesting(
    preferences: shared,
  ).init();
  await preferences.setConsent(enabled: true, permissionGranted: true);
  return preferences;
}

MaasoAuthSession _session(String accountUuid, String accessToken) =>
    MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: accessToken,
      refreshToken: 'refresh-$accountUuid',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

PushTokenBinding _binding() => PushTokenBinding(
  firebaseProjectId: FirebaseProjectContract.projectId,
  token: 'fcm-a',
  accountUuid: 'account-a',
  environmentKey: MaasoEnvironment.test.key,
  installationId: '0123456789abcdef0123456789abcdef',
  platform: 'android',
  baseUri: Uri.parse('${MaasoEnvironment.test.baseUrl}/'),
  bindingRevision: 7,
);

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

class _FakeRegistrar implements PushTokenRegistrar {
  _FakeRegistrar({this.onUpsert, this.onRemove, this.expiresAtFor});

  final Future<void>? Function(PushTokenBinding, String)? onUpsert;
  final Future<void>? Function(PushTokenBinding, String)? onRemove;
  final DateTime Function(PushTokenBinding)? expiresAtFor;
  final upserts = <PushTokenBinding>[];
  final removals = <PushTokenBinding>[];

  @override
  Future<PushTokenBindingLease> upsert(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    upserts.add(binding);
    await onUpsert?.call(binding, accessToken);
    return PushTokenBindingLease(
      expiresAt:
          expiresAtFor?.call(binding).toUtc() ??
          DateTime.now().toUtc().add(const Duration(days: 35)),
    );
  }

  @override
  Future<void> remove(
    PushTokenBinding binding, {
    required String accessToken,
  }) async {
    removals.add(binding);
    await onRemove?.call(binding, accessToken);
  }
}

class _FakeMessagingGateway implements FirebaseMessagingGateway {
  _FakeMessagingGateway({
    required this.token,
    this.tokenAfterDelete,
    this.apnsToken = 'apns-a',
    this.getTokenOverride,
  });

  String? token;
  final String? tokenAfterDelete;
  final String? apnsToken;
  final Future<String?> Function()? getTokenOverride;
  final _foreground = StreamController<FirebasePushMessage>.broadcast();
  final _opened = StreamController<FirebasePushMessage>.broadcast();
  final _refreshes = StreamController<String>.broadcast();
  int deleteCount = 0;
  int getTokenCount = 0;
  int apnsTokenReadCount = 0;
  bool autoInitEnabled = false;

  @override
  Stream<FirebasePushMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<FirebasePushMessage> get openedMessages => _opened.stream;

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  void addTokenError(Object error) => _refreshes.addError(error);

  @override
  Future<void> deleteToken() async {
    deleteCount++;
    token = tokenAfterDelete;
  }

  @override
  Future<String?> getAPNSToken() async {
    apnsTokenReadCount++;
    return apnsToken;
  }

  @override
  Future<FirebasePushMessage?> getInitialMessage() async => null;

  @override
  Future<String?> getToken() {
    getTokenCount++;
    return getTokenOverride?.call() ?? Future<String?>.value(token);
  }

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> setAutoInitEnabled(bool enabled) async {
    autoInitEnabled = enabled;
  }

  Future<void> close() async {
    await _foreground.close();
    await _opened.close();
    await _refreshes.close();
  }
}

class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

class _HangingResponseClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Completer<List<int>>().future.asStream(), 409);
}

class _StaticResponseClient extends http.BaseClient {
  _StaticResponseClient({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(body)),
        statusCode,
      );
}

class _RecordingClient extends http.BaseClient {
  final bodies = <String>[];
  final methods = <String>[];
  final paths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    methods.add(request.method);
    paths.add(request.url.path);
    bodies.add((request as http.Request).body);
    if (request.url.path.endsWith('/bind')) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'code': 'OK',
              'message': 'success',
              'traceId': 'trace-recording',
              'data': <String, Object?>{
                'accepted': true,
                'bindingRevision': body['bindingRevision'],
                'expiresAt': DateTime.now()
                    .toUtc()
                    .add(const Duration(days: 35))
                    .toIso8601String(),
              },
            }),
          ),
        ),
        200,
      );
    }
    return http.StreamedResponse(const Stream<List<int>>.empty(), 204);
  }
}
