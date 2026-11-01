import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise asynchronous cleanup through the actual public adapter.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final class _RegionCleanupStore extends InMemorySharedPreferencesStore {
  _RegionCleanupStore(Map<String, Object> values) : super.withData(values);

  final entered = Completer<void>();
  Completer<void>? gate;
  final removedKeys = <String>[];
  bool failRemoval = false;
  bool throwOnRemoval = false;

  @override
  Future<bool> remove(String key) async {
    removedKeys.add(key);
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (throwOnRemoval) throw StateError('cleanup unavailable');
    if (failRemoval) return false;
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = AccountStorageScope(environmentKey: 'test', accountUuid: 'a');
  String key(AccountStorageScope owner) =>
      '${owner.storageNamespace}.preferences.network_region.choice.v1';
  Future<NetworkRegionService> create({
    String? Function()? location,
    String? Function()? device,
    bool Function()? current,
    AccountStorageScope? owner,
  }) => NetworkRegionService(
    countryCodeSupplier: location,
    deviceCountryCodeSupplier: device ?? (() => null),
    isOwnerCurrent: current,
  ).init(scope: owner ?? scope);

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'startup does not locate; automatic resolve has no asynchronous IO',
    () async {
      var locationReads = 0;
      var deviceReads = 0;
      final service = await create(
        location: () {
          locationReads++;
          return null;
        },
        device: () {
          deviceReads++;
          return 'CN';
        },
      );
      expect(service.isAvailable, true);
      expect(locationReads, 0);
      expect(deviceReads, 0);
      expect(service.resolve().toJson(), <String, String>{
        'region': 'china_mainland',
        'source': 'device_locale',
      });
      expect(locationReads, 1);
      expect(deviceReads, 1);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test('missing country information defaults to overseas', () async {
    final service = await create();
    expect(service.isAvailable, true);
    expect(service.resolve(), same(NetworkRegionService.fallback));
    expect(service.resolve().toJson(), <String, String>{
      'region': 'overseas',
      'source': 'default',
    });
  });

  test(
    'authorized country outranks device and is read anew each request',
    () async {
      String? authorized = 'CN';
      var deviceReads = 0;
      final service = await create(
        location: () => authorized,
        device: () {
          deviceReads++;
          return 'CN';
        },
      );
      expect(service.resolve().region, NetworkRegion.mainlandChina);
      authorized = 'US';
      expect(service.resolve().region, NetworkRegion.overseas);
      expect(service.resolve().source, NetworkRegionSource.authorizedLocation);
      expect(deviceReads, 0);
      authorized = null;
      expect(service.resolve().source, NetworkRegionSource.deviceLocale);
    },
  );

  test('locale language never defines the region', () async {
    var locale = const Locale('zh', 'US');
    final service = await create(device: () => locale.countryCode);
    expect(service.resolve().region, NetworkRegion.overseas);
    locale = const Locale('en', 'CN');
    expect(service.resolve().region, NetworkRegion.mainlandChina);
    locale = const Locale('zh');
    expect(service.resolve(), same(NetworkRegionService.fallback));
    locale = const Locale('en', 'HK');
    expect(service.resolve().region, NetworkRegion.overseas);
  });

  test(
    'CN is mainland; HK MO TW and other valid regions are overseas',
    () async {
      for (final code in <String>['CN', 'HK', 'MO', 'TW', 'US', 'SG', 'JP']) {
        final service = await create(device: () => code);
        expect(
          service.resolve().region,
          code == 'CN' ? NetworkRegion.mainlandChina : NetworkRegion.overseas,
        );
        expect(service.resolve().source, NetworkRegionSource.deviceLocale);
      }
    },
  );

  test('malformed and throwing suppliers use the overseas default', () async {
    for (final code in <String?>[
      null,
      '',
      'cn',
      'CN ',
      ' CN',
      'CHN',
      '中',
      'CＮ',
      'CN\n',
    ]) {
      final service = await create(location: () => code, device: () => code);
      expect(service.resolve(), same(NetworkRegionService.fallback));
    }
    final service = await create(
      location: () => throw StateError('private details'),
      device: () => throw StateError('private details'),
    );
    expect(service.resolve(), same(NetworkRegionService.fallback));
  });

  test(
    'old choices and corrupt values are deleted without selecting a region',
    () async {
      for (final stored in <Object>[
        'chinaMainland',
        'overseas',
        'automatic',
        'anything',
        1,
        true,
        'CN',
      ]) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          key(scope): stored,
        });
        final service = await create();
        expect(
          service.resolve(),
          same(NetworkRegionService.fallback),
          reason: '$stored',
        );
        expect(
          (await SharedPreferences.getInstance()).containsKey(key(scope)),
          false,
        );
      }
    },
  );

  test(
    'stored overseas choice cannot override current authorized mainland country',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        key(scope): 'overseas',
      });
      final service = await create(location: () => 'CN', device: () => 'US');
      expect(service.resolve().region, NetworkRegion.mainlandChina);
      expect(service.resolve().source, NetworkRegionSource.authorizedLocation);
      expect(
        (await SharedPreferences.getInstance()).containsKey(key(scope)),
        false,
      );
    },
  );

  test(
    'cleanup is limited to this account and environment preference',
    () async {
      final other = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'b',
      );
      final production = AccountStorageScope(
        environmentKey: 'prod',
        accountUuid: 'a',
      );
      final retained = <String, Object>{
        key(other): 'chinaMainland',
        key(production): 'overseas',
        '${scope.storageNamespace}.preferences.location.enabled.v1': false,
        '${scope.storageNamespace}.chat.history': 'keep chat',
        '${scope.storageNamespace}.memory': 'keep memory',
      };
      SharedPreferences.setMockInitialValues(<String, Object>{
        key(scope): 'chinaMainland',
        ...retained,
      });
      await create();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), retained.keys.toSet());
      for (final entry in retained.entries) {
        expect(preferences.get(entry.key), entry.value);
      }
      await create(owner: other);
      expect(preferences.containsKey(key(other)), false);
      expect(preferences.get(key(production)), 'overseas');
      expect(key(scope), isNot(contains('.a.')));
    },
  );

  test(
    'preference loader failure does not disable automatic country resolution',
    () async {
      final service = await NetworkRegionService(
        preferencesLoader: () =>
            Future<SharedPreferences>.error(StateError('storage unavailable')),
        countryCodeSupplier: () => 'CN',
        deviceCountryCodeSupplier: () => 'US',
      ).init(scope: scope);
      expect(service.isAvailable, true);
      expect(service.resolve().region, NetworkRegion.mainlandChina);
      expect(service.resolve().source, NetworkRegionSource.authorizedLocation);
    },
  );

  for (final throwsError in [false, true]) {
    test(
      'failed removal (${throwsError ? 'throw' : 'false'}) cannot restore old manual behavior',
      () async {
        final store =
            _RegionCleanupStore(<String, Object>{
                'flutter.${key(scope)}': 'chinaMainland',
              })
              ..throwOnRemoval = throwsError
              ..failRemoval = !throwsError;
        SharedPreferencesStorePlatform.instance = store;
        final service = await create(device: () => 'US');
        expect(store.removedKeys, ['flutter.${key(scope)}']);
        expect(service.isAvailable, true);
        expect(service.resolve().region, NetworkRegion.overseas);
        expect(service.resolve().source, NetworkRegionSource.deviceLocale);
        // The disk still contains the rejected preference, but a later service
        // also ignores it instead of restoring manual behavior.
        expect(
          (await store.getAll())['flutter.${key(scope)}'],
          'chinaMainland',
        );
        final recreated = await create(
          location: () => 'US',
          device: () => 'CN',
        );
        expect(recreated.resolve().region, NetworkRegion.overseas);
        expect(
          recreated.resolve().source,
          NetworkRegionSource.authorizedLocation,
        );
      },
    );
  }

  test(
    'uninitialized and retired services never read country suppliers',
    () async {
      var reads = 0;
      final service = NetworkRegionService(
        countryCodeSupplier: () {
          reads++;
          return 'CN';
        },
        deviceCountryCodeSupplier: () => 'CN',
      );
      expect(service.isAvailable, false);
      expect(service.resolve(), same(NetworkRegionService.fallback));
      expect(reads, 0);
      await service.init(scope: scope);
      expect(service.resolve().region, NetworkRegion.mainlandChina);
      await service.deactivateAndDrain();
      expect(service.isAvailable, false);
      expect(service.resolve(), same(NetworkRegionService.fallback));
      expect(reads, 1);
      await expectLater(service.init(scope: scope), throwsStateError);
    },
  );

  test('owner loss or exception yields no old-account country', () async {
    var current = true;
    final service = await create(device: () => 'CN', current: () => current);
    expect(service.resolve().region, NetworkRegion.mainlandChina);
    current = false;
    expect(service.isAvailable, false);
    expect(service.resolve(), same(NetworkRegionService.fallback));
    final broken = await create(current: () => throw StateError('stale mount'));
    expect(broken.isAvailable, false);
    expect(broken.resolve(), same(NetworkRegionService.fallback));
  });

  for (final invalidation in ['retirement', 'owner']) {
    test(
      'late initialization cannot revive a service after $invalidation',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          key(scope): 'chinaMainland',
        });
        final loaded = Completer<SharedPreferences>();
        var current = true;
        final service = NetworkRegionService(
          preferencesLoader: () => loaded.future,
          countryCodeSupplier: () => 'CN',
          isOwnerCurrent: () => current,
        );
        final initialize = service.init(scope: scope);
        Future<void>? drain;
        if (invalidation == 'retirement') {
          drain = service.deactivateAndDrain();
        } else {
          current = false;
        }
        loaded.complete(await SharedPreferences.getInstance());
        await initialize;
        await drain;
        expect(service.isAvailable, false);
        expect(service.resolve(), same(NetworkRegionService.fallback));
        expect(
          (await SharedPreferences.getInstance()).get(key(scope)),
          'chinaMainland',
        );
      },
    );
  }

  test(
    'retirement drains admitted cleanup and cannot publish late country',
    () async {
      final store = _RegionCleanupStore(<String, Object>{
        'flutter.${key(scope)}': 'chinaMainland',
      })..gate = Completer<void>();
      SharedPreferencesStorePlatform.instance = store;
      final service = NetworkRegionService(
        deviceCountryCodeSupplier: () => 'CN',
      );
      final initialize = service.init(scope: scope);
      await store.entered.future;
      var drained = false;
      final drain = service.deactivateAndDrain().then((_) => drained = true);
      expect(service.isAvailable, false);
      expect(service.resolve(), same(NetworkRegionService.fallback));
      await Future<void>.delayed(Duration.zero);
      expect(drained, false);
      store.gate!.complete();
      await initialize;
      await drain;
      expect(drained, true);
      expect(service.isAvailable, false);
      expect(service.resolve(), same(NetworkRegionService.fallback));
      expect(store.removedKeys, ['flutter.${key(scope)}']);
      expect(
        (await store.getAll()).containsKey('flutter.${key(scope)}'),
        false,
      );
    },
  );
}
