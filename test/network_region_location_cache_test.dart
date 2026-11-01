import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/location_service.dart';
import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_service_test.dart' show FakeLocationPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = AccountStorageScope(
    environmentKey: 'test',
    accountUuid: 'country-cache',
  );
  FakeLocationPlatform platform() => FakeLocationPlatform()
    ..city = const LocationCity(
      city: 'Shenzhen',
      country: 'China',
      countryCode: 'CN',
    );

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('read-only country cache never locates or persists a country', () async {
    final native = platform();
    final service = await LocationService(platform: native).init(scope: scope);
    expect(service.cachedCountryCode, null);
    expect(native.positionRequests, 0);
    expect(native.permissionRequests, 0);
    final city = await service.locate();
    expect(city.countryCode, 'CN');
    expect(city.cityQuery, 'Shenzhen China');
    for (var index = 0; index < 10; index++) {
      expect(service.cachedCountryCode, 'CN');
    }
    expect(native.positionRequests, 1);
    expect(native.permissionChecks, 1);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'country expires after five minutes and rejects future cache timestamps',
    () async {
      var now = DateTime.utc(2026, 10, 14);
      final initial = now;
      final native = platform();
      final service = await LocationService(
        platform: native,
        now: () => now,
      ).init(scope: scope);
      await service.locate();
      now = initial
          .add(const Duration(minutes: 5))
          .subtract(const Duration(microseconds: 1));
      expect(service.cachedCountryCode, 'CN');
      now = initial.add(const Duration(minutes: 5));
      expect(service.cachedCountryCode, null);
      now = initial.subtract(const Duration(microseconds: 1));
      expect(service.cachedCountryCode, null);
      expect(native.positionRequests, 1);
    },
  );

  test(
    'invalid country codes cannot route even if the city is valid',
    () async {
      for (final code in <String?>[
        null,
        '',
        'cn',
        'CN ',
        'CN\n',
        'CHN',
        'CＮ',
        'ß',
        '中国',
      ]) {
        final native = platform()
          ..city = LocationCity(city: 'City', countryCode: code);
        final service = await LocationService(
          platform: native,
        ).init(scope: scope);
        expect((await service.locate()).isSuccess, true);
        expect(service.cachedCountryCode, null);
        expect(service.state.value.countryCode, null);
      }
    },
  );

  test(
    'disabled, background, denied, retired and stale owners clear authority',
    () async {
      for (final reason in <String>[
        'disabled',
        'background',
        'denied',
        'retired',
        'owner',
      ]) {
        var current = true;
        final native = platform();
        final service = await LocationService(
          platform: native,
          isOwnerCurrent: () => current,
        ).init(scope: scope);
        await service.locate();
        expect(service.cachedCountryCode, 'CN');
        switch (reason) {
          case 'disabled':
            await service.setEnabled(false);
            break;
          case 'background':
            service.setForeground(false);
            service.setForeground(true);
            break;
          case 'denied':
            native.permission = LocationPermissionState.deniedForever;
            await service.refreshPermission();
            break;
          case 'retired':
            await service.deactivateAndDrain();
            break;
          case 'owner':
            current = false;
            break;
        }
        expect(service.cachedCountryCode, null, reason: reason);
        expect(native.positionRequests, 1);
        // Keep each variant independent of the opt-out preference written above.
        SharedPreferences.setMockInitialValues(<String, Object>{});
      }
    },
  );

  test('foreground supplier also fences read-only country access', () async {
    var foreground = true;
    final native = platform();
    final service = await LocationService(
      platform: native,
      isForeground: () => foreground,
    ).init(scope: scope);
    await service.locate();
    expect(service.cachedCountryCode, 'CN');
    foreground = false;
    expect(service.cachedCountryCode, null);
    expect(native.positionRequests, 1);
  });

  test(
    'late native country cannot republish after background cancellation',
    () async {
      final native = platform()..cityCompleter = Completer<LocationCity>();
      final service = await LocationService(
        platform: native,
      ).init(scope: scope);
      final lookup = service.locate();
      await Future<void>.delayed(Duration.zero);
      service.setForeground(false);
      native.cityCompleter!.complete(native.city);
      await lookup;
      service.setForeground(true);
      expect(service.cachedCountryCode, null);
      expect(service.state.value.countryCode, null);
    },
  );

  test(
    'region resolves the authorized cache then device fallback without GPS',
    () async {
      final native = platform();
      final location = await LocationService(
        platform: native,
      ).init(scope: scope);
      final region = await NetworkRegionService(
        countryCodeSupplier: () => location.cachedCountryCode,
        deviceCountryCodeSupplier: () => 'US',
      ).init(scope: scope);
      expect(region.resolve().region, NetworkRegion.overseas);
      expect(native.positionRequests, 0);
      await location.locate();
      expect(region.resolve().region, NetworkRegion.mainlandChina);
      expect(region.resolve().source, NetworkRegionSource.authorizedLocation);
      location.setForeground(false);
      expect(region.resolve().region, NetworkRegion.overseas);
      expect(region.resolve().source, NetworkRegionSource.deviceLocale);
      expect(native.positionRequests, 1);
    },
  );

  test(
    'expired country cache defaults to overseas without another fix',
    () async {
      var now = DateTime.utc(2026, 10, 20);
      final native = platform();
      final location = await LocationService(
        platform: native,
        now: () => now,
      ).init(scope: scope);
      final region = await NetworkRegionService(
        countryCodeSupplier: () => location.cachedCountryCode,
        deviceCountryCodeSupplier: () => null,
      ).init(scope: scope);
      expect(region.resolve(), same(NetworkRegionService.fallback));
      await location.locate();
      expect(region.resolve().region, NetworkRegion.mainlandChina);
      expect(region.resolve().source, NetworkRegionSource.authorizedLocation);
      now = now.add(const Duration(minutes: 5));
      expect(region.resolve(), same(NetworkRegionService.fallback));
      expect(native.positionRequests, 1);
      expect(native.permissionRequests, 0);
    },
  );
}
