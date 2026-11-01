import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/location_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test the public preference adapter against deliberately delayed platform IO.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final class _DelayedPreferenceStore extends InMemorySharedPreferencesStore {
  _DelayedPreferenceStore() : super.empty();
  final firstEntered = Completer<void>();
  final firstGate = Completer<void>();
  final secondGate = Completer<void>();
  final values = <Object>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    values.add(value);
    if (values.length == 1) {
      firstEntered.complete();
      await firstGate.future;
    } else if (values.length == 2) {
      await secondGate.future;
    }
    return super.setValue(valueType, key, value);
  }
}

final class FakeLocationPlatform implements LocationPlatform {
  @override
  bool isSupported = true;
  bool serviceEnabled = true;
  LocationPermissionState permission = LocationPermissionState.granted;
  LocationPermissionState requestedPermission = LocationPermissionState.granted;
  int statusChecks = 0;
  int permissionChecks = 0;
  int permissionRequests = 0;
  int positionRequests = 0;
  int geocodeRequests = 0;
  int cancels = 0;
  Completer<LocationCoordinates>? positionCompleter;
  Completer<LocationCity>? cityCompleter;
  Completer<LocationPermissionState>? permissionCompleter;
  Object? positionError;
  LocationCoordinates position = const LocationCoordinates(31.23, 121.47);
  LocationCity city = const LocationCity(city: 'Shanghai', country: 'China');

  @override
  Future<bool> isServiceEnabled() async {
    statusChecks++;
    return serviceEnabled;
  }

  @override
  Future<LocationPermissionState> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<LocationPermissionState> requestPermission() async {
    permissionRequests++;
    return permissionCompleter?.future ?? requestedPermission;
  }

  @override
  Future<LocationCoordinates> currentPosition() async {
    positionRequests++;
    if (positionError != null) throw positionError!;
    return positionCompleter?.future ?? position;
  }

  @override
  Future<LocationCity> reverseGeocode(LocationCoordinates position) async {
    geocodeRequests++;
    return cityCompleter?.future ?? city;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<bool> openLocationSettings() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = AccountStorageScope(environmentKey: 'test', accountUuid: 'a');

  Future<LocationService> create(
    FakeLocationPlatform platform, {
    AccountStorageScope? owner,
    bool Function()? isOwnerCurrent,
    DateTime Function()? now,
  }) => LocationService(
    platform: platform,
    isOwnerCurrent: isOwnerCurrent,
    now: now,
  ).init(scope: owner ?? scope);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'startup restores only preference; never reads location or asks permission',
    () async {
      final platform = FakeLocationPlatform();
      final service = await create(platform);
      expect(service.enabled.value, true);
      expect(service.state.value.status, LocationStatus.permissionRequired);
      expect(platform.statusChecks, 0);
      expect(platform.permissionChecks, 0);
      expect(platform.permissionRequests, 0);
      expect(platform.positionRequests, 0);
    },
  );

  test(
    'city result excludes precise position and uses memory cache only',
    () async {
      final platform = FakeLocationPlatform();
      final service = await create(platform);
      final first = await service.locate();
      expect(first.isSuccess, true);
      expect(first.cityQuery, 'Shanghai China');
      expect(await service.locate(), same(first));
      expect(platform.positionRequests, 1);
      expect(platform.permissionChecks, 2);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      final recreated = await create(FakeLocationPlatform());
      expect(recreated.state.value.city, null);
    },
  );

  test('refresh permission does not prompt or acquire GPS', () async {
    final platform = FakeLocationPlatform()
      ..permission = LocationPermissionState.denied;
    final service = await create(platform);
    expect(
      (await service.refreshPermission()).status,
      LocationStatus.permissionRequired,
    );
    expect(platform.permissionRequests, 0);
    expect(platform.positionRequests, 0);
    platform.permission = LocationPermissionState.granted;
    expect((await service.refreshPermission()).status, LocationStatus.idle);
  });

  test(
    'permission requested only on explicit locate and denied results are real',
    () async {
      final platform = FakeLocationPlatform()
        ..permission = LocationPermissionState.denied
        ..requestedPermission = LocationPermissionState.denied;
      final service = await create(platform);
      expect(
        (await service.locate(requestPermission: false)).status,
        LocationStatus.permissionRequired,
      );
      expect(platform.permissionRequests, 0);
      expect((await service.locate()).status, LocationStatus.denied);
      expect(platform.permissionRequests, 1);
      expect(platform.positionRequests, 0);
      platform.permission = LocationPermissionState.deniedForever;
      expect((await service.locate()).status, LocationStatus.deniedForever);
      expect(platform.permissionRequests, 1);
    },
  );

  test(
    'services disabled, unsupported, timeout and missing city remain distinct',
    () async {
      final platform = FakeLocationPlatform();
      final service = await create(platform);
      platform.serviceEnabled = false;
      expect((await service.locate()).status, LocationStatus.servicesDisabled);
      platform.serviceEnabled = true;
      platform.isSupported = false;
      expect(service.isSupported, false);
      expect((await service.locate()).status, LocationStatus.unavailable);
      platform.isSupported = true;
      expect(service.isSupported, true);
      platform.positionError = TimeoutException('private provider details');
      expect((await service.locate()).status, LocationStatus.timeout);
      platform.positionError = null;
      platform.city = const LocationCity(city: '', region: 'Province');
      expect((await service.locate()).status, LocationStatus.cityUnavailable);
      expect(service.state.value.cityQuery, null);
    },
  );

  test('invalid coordinates never reach geocoder', () async {
    final platform = FakeLocationPlatform()
      ..position = const LocationCoordinates(double.nan, 121);
    expect(
      (await (await create(platform)).locate()).status,
      LocationStatus.unavailable,
    );
    expect(platform.geocodeRequests, 0);
  });

  test('concurrent explicit lookups share one native request', () async {
    final platform = FakeLocationPlatform()
      ..positionCompleter = Completer<LocationCoordinates>();
    final service = await create(platform);
    final first = service.locate();
    final second = service.locate();
    await Future<void>.delayed(Duration.zero);
    expect(platform.positionRequests, 1);
    platform.positionCompleter!.complete(platform.position);
    final results = await Future.wait(<Future<LocationSnapshot>>[
      first,
      second,
    ]);
    expect(results.every((result) => result.isSuccess), true);
    expect(platform.geocodeRequests, 1);
  });

  test(
    'disable cancels pending work, clears city and persists no coordinates',
    () async {
      final platform = FakeLocationPlatform()
        ..cityCompleter = Completer<LocationCity>();
      final service = await create(platform);
      final pending = service.locate();
      await Future<void>.delayed(Duration.zero);
      final generation = service.authorityGeneration;
      await service.setEnabled(false);
      expect(service.authorityGeneration, greaterThan(generation));
      expect(platform.cancels, greaterThan(0));
      platform.cityCompleter!.complete(platform.city);
      expect((await pending).status, LocationStatus.disabled);
      expect(service.state.value.city, null);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), <String>{
        '${scope.storageNamespace}.preferences.location.enabled.v1',
      });
      expect(preferences.getBool(preferences.getKeys().single), false);
    },
  );

  test(
    'background cancels position and never submits stale coordinates',
    () async {
      final platform = FakeLocationPlatform()
        ..positionCompleter = Completer<LocationCoordinates>();
      final service = await create(platform);
      final pending = service.locate();
      await Future<void>.delayed(Duration.zero);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      platform.positionCompleter!.complete(platform.position);
      expect((await pending).status, LocationStatus.cancelled);
      expect(platform.cancels, greaterThan(0));
      expect(platform.geocodeRequests, 0);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(service.state.value.city, null);
    },
  );

  test(
    'iOS permission sheet inactive state preserves explicit authorization',
    () async {
      final platform = FakeLocationPlatform()
        ..permission = LocationPermissionState.denied
        ..permissionCompleter = Completer<LocationPermissionState>();
      final service = await create(platform);
      final pending = service.locate();
      await Future<void>.delayed(Duration.zero);
      service.didChangeAppLifecycleState(AppLifecycleState.inactive);
      platform.permissionCompleter!.complete(LocationPermissionState.granted);
      expect((await pending).isSuccess, true);
      expect(platform.positionRequests, 1);
    },
  );

  test('turn cancellation suppresses geocoding and late result', () async {
    final platform = FakeLocationPlatform()
      ..positionCompleter = Completer<LocationCoordinates>();
    final service = await create(platform);
    var current = true;
    final pending = service.locate(isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    platform.positionCompleter!.complete(platform.position);
    expect((await pending).status, LocationStatus.cancelled);
    expect(platform.geocodeRequests, 0);
    expect(service.state.value.city, null);
  });

  test(
    'retire fences pending init and location; old owner cannot write preferences',
    () async {
      var currentOwner = true;
      final platform = FakeLocationPlatform()
        ..cityCompleter = Completer<LocationCity>();
      final service = await create(
        platform,
        isOwnerCurrent: () => currentOwner,
      );
      final pending = service.locate();
      await Future<void>.delayed(Duration.zero);
      currentOwner = false;
      await service.deactivateAndDrain();
      platform.cityCompleter!.complete(platform.city);
      expect((await pending).status, LocationStatus.retired);
      expect(service.state.value.city, null);
      expect(service.enabled.value, false);
      await expectLater(service.setEnabled(true), throwsStateError);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'late enable write cannot reopen the latest disabled location choice',
    () async {
      final store = _DelayedPreferenceStore();
      SharedPreferencesStorePlatform.instance = store;
      final platform = FakeLocationPlatform();
      final service = await create(platform);
      final enabling = service.setEnabled(true);
      await store.firstEntered.future;
      final disabling = service.setEnabled(false);
      expect(service.enabled.value, false);
      final generation = service.authorityGeneration;
      store.firstGate.complete();
      await enabling;
      expect(service.enabled.value, false);
      expect(service.authorityGeneration, generation);
      expect((await service.locate()).status, LocationStatus.disabled);
      expect(platform.positionRequests, 0);
      store.secondGate.complete();
      await disabling;
      expect(store.values, <Object>[true, false]);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          '${scope.storageNamespace}.preferences.location.enabled.v1',
        ),
        false,
      );
    },
  );

  test(
    'account retirement drains admitted preference IO without publishing its late enable',
    () async {
      final store = _DelayedPreferenceStore();
      SharedPreferencesStorePlatform.instance = store;
      final platform = FakeLocationPlatform();
      var ownerCurrent = true;
      final service = await create(
        platform,
        isOwnerCurrent: () => ownerCurrent,
      );
      final enabling = service.setEnabled(true);
      await store.firstEntered.future;
      ownerCurrent = false;
      final retirement = service.deactivateAndDrain();
      expect(service.enabled.value, false);
      expect(service.state.value.status, LocationStatus.retired);
      store.firstGate.complete();
      await enabling;
      await retirement;
      expect(service.enabled.value, false);
      expect(service.state.value.status, LocationStatus.retired);
      await expectLater(service.setEnabled(true), throwsStateError);
      expect(store.values, <Object>[true]);
      expect(platform.positionRequests, 0);
    },
  );

  test('account and environment switches isolate preference', () async {
    final first = await create(FakeLocationPlatform());
    await first.setEnabled(false);
    final same = await create(FakeLocationPlatform());
    final other = await create(
      FakeLocationPlatform(),
      owner: AccountStorageScope(environmentKey: 'test', accountUuid: 'b'),
    );
    final prod = await create(
      FakeLocationPlatform(),
      owner: AccountStorageScope(environmentKey: 'prod', accountUuid: 'a'),
    );
    expect(same.enabled.value, false);
    expect(other.enabled.value, true);
    expect(prod.enabled.value, true);
  });

  test(
    'permission revocation clears cached city and invalidates search authority',
    () async {
      final platform = FakeLocationPlatform();
      final service = await create(platform);
      await service.locate();
      final generation = service.authorityGeneration;
      platform.permission = LocationPermissionState.deniedForever;
      expect(
        (await service.refreshPermission()).status,
        LocationStatus.deniedForever,
      );
      expect(service.authorityGeneration, greaterThan(generation));
      expect(service.state.value.city, null);
      expect((await service.locate()).isSuccess, false);
    },
  );

  test('expired city cache reacquires GPS', () async {
    var now = DateTime.utc(2026, 10, 14);
    final platform = FakeLocationPlatform();
    final service = await create(platform, now: () => now);
    await service.locate();
    now = now.add(const Duration(minutes: 6));
    await service.locate();
    expect(platform.positionRequests, 2);
  });

  test(
    'retire during preference loading never publishes active state',
    () async {
      final preferences = Completer<SharedPreferences>();
      final platform = FakeLocationPlatform();
      final service = LocationService(
        platform: platform,
        preferencesLoader: () => preferences.future,
      );
      final initializing = service.init(scope: scope);
      await service.deactivateAndDrain();
      preferences.complete(await SharedPreferences.getInstance());
      await initializing;
      expect(service.state.value.status, LocationStatus.retired);
      expect(service.enabled.value, false);
      expect(platform.positionRequests, 0);
    },
  );

  test(
    'background during preference loading preserves service for foreground use',
    () async {
      final preferences = Completer<SharedPreferences>();
      final platform = FakeLocationPlatform();
      final service = LocationService(
        platform: platform,
        preferencesLoader: () => preferences.future,
      );
      final initializing = service.init(scope: scope);
      service.setForeground(false);
      preferences.complete(await SharedPreferences.getInstance());
      await initializing;
      expect((await service.locate()).status, LocationStatus.cancelled);
      service.setForeground(true);
      expect((await service.locate()).isSuccess, true);
    },
  );
}
