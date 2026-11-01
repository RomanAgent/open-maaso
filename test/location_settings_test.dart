import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/location_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/settings/presentation/location_settings_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _switch = ValueKey('settings-location-enabled');
const _action = ValueKey('settings-location-action');
const _status = ValueKey('settings-location-status');

void main() {
  final services = <LocationService>[];
  late SharedPreferences preferences;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });
  tearDown(() async {
    // These injected services are not lifecycle-registered and have no native
    // resources. The cancellation test below explicitly retires its request.
    for (final service in services) {
      service.setForeground(false);
    }
    services.clear();
    await appServices.reset();
  });

  Future<LocationService> create(
    WidgetTester tester,
    _Platform platform,
  ) async {
    final service =
        await LocationService(
          platform: platform,
          preferencesLoader: () async => preferences,
        ).init(
          scope: AccountStorageScope(
            environmentKey: 'test',
            accountUuid: 'location-settings',
          ),
        );
    services.add(service);
    return service;
  }

  Future<void> mount(
    WidgetTester tester, {
    LocationService? service,
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LocationSettingsRow(service: service),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mount inspects actual permission without requesting or GPS', (
    tester,
  ) async {
    final platform = _Platform();
    await mount(tester, service: await create(tester, platform));
    expect(platform.permissionChecks, 1);
    expect(platform.permissionRequests, 0);
    expect(platform.positions, 0);
    expect(
      _statusText(tester),
      contains('settings.location_not_authorized'.tr),
    );
    expect(
      _statusText(tester),
      isNot(contains('settings.location_allowed'.tr)),
    );
    expect(_toggle(tester).value, isTrue);
  });

  testWidgets('human tap requests permission and displays the resulting city', (
    tester,
  ) async {
    final platform = _Platform()
      ..requestedPermission = LocationPermissionState.granted;
    final service = await create(tester, platform);
    await mount(tester, service: service);
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, 1);
    expect(platform.positions, 1);
    expect(platform.geocodes, 1);
    expect(_statusText(tester), contains('Shanghai'));
    expect(find.textContaining('31.23'), findsNothing);
    expect(find.textContaining('121.47'), findsNothing);
    expect(service.state.value.status, LocationStatus.available);
    expect(find.text('settings.location_refresh'.tr), findsOneWidget);
  });

  testWidgets('declined permission stays usable with a manual city hint', (
    tester,
  ) async {
    final platform = _Platform();
    await mount(tester, service: await create(tester, platform));
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(platform.permissionRequests, 1);
    expect(platform.positions, 0);
    expect(_statusText(tester), 'settings.location_denied'.tr);
    expect(_toggle(tester).onChanged, isNotNull);
    expect(tester.widget<TextButton>(find.byKey(_action)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'blocked permission opens App settings without requesting again',
    (tester) async {
      final platform = _Platform()
        ..permission = LocationPermissionState.deniedForever;
      await mount(tester, service: await create(tester, platform));
      expect(_statusText(tester), 'settings.location_denied_forever'.tr);
      await tester.tap(find.byKey(_action));
      await tester.pumpAndSettle();
      expect(platform.appSettings, 1);
      expect(platform.locationSettings, 0);
      expect(platform.permissionRequests, 0);
      expect(platform.positions, 0);
    },
  );

  testWidgets('system location off opens location settings', (tester) async {
    final platform = _Platform()..systemEnabled = false;
    await mount(tester, service: await create(tester, platform));
    expect(_statusText(tester), 'settings.location_system_disabled'.tr);
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(platform.locationSettings, 1);
    expect(platform.appSettings, 0);
    expect(platform.permissionRequests, 0);
    expect(platform.positions, 0);
  });

  testWidgets(
    'local opt-out restores and explicit re-enable requests location',
    (tester) async {
      final platform = _Platform()
        ..requestedPermission = LocationPermissionState.granted;
      final service = await create(tester, platform);
      final disabled = service.setEnabled(false);
      await tester.pump();
      await disabled;
      await mount(tester, service: service);
      expect(_toggle(tester).value, isFalse);
      expect(_statusText(tester), 'settings.location_disabled'.tr);
      expect(find.byKey(_action), findsNothing);
      expect(platform.positions, 0);
      await tester.tap(find.byKey(_switch));
      await tester.pumpAndSettle();
      expect(_toggle(tester).value, isTrue);
      expect(platform.permissionRequests, 1);
      expect(_statusText(tester), contains('Shanghai'));
    },
  );

  testWidgets(
    'missing runtime disables controls and does not claim permission',
    (tester) async {
      await mount(tester);
      expect(_toggle(tester).value, isFalse);
      expect(_toggle(tester).onChanged, isNull);
      expect(_statusText(tester), 'settings.location_unavailable'.tr);
      expect(find.byKey(_action), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'in-flight lookup disables duplicate requests and remains reactive',
    (tester) async {
      final platform = _Platform()
        ..permission = LocationPermissionState.granted
        ..positionGate = Completer<LocationCoordinates>();
      await mount(tester, service: await create(tester, platform));
      expect(_statusText(tester), 'settings.location_allowed'.tr);
      await tester.tap(find.byKey(_action));
      await tester.pump();
      await tester.pump();
      expect(_statusText(tester), 'settings.location_loading'.tr);
      expect(_toggle(tester).onChanged, isNull);
      expect(tester.widget<TextButton>(find.byKey(_action)).onPressed, isNull);
      expect(platform.positions, 1);
      platform.positionGate!.complete(const LocationCoordinates(31.23, 121.47));
      await tester.pumpAndSettle();
      expect(_statusText(tester), contains('Shanghai'));
      expect(platform.positions, 1);
      expect(_toggle(tester).onChanged, isNotNull);
    },
  );

  testWidgets('temporary lookup unavailability can retry to obtain the city', (
    tester,
  ) async {
    final platform = _Platform()
      ..permission = LocationPermissionState.granted
      ..positionError = const LocationPlatformException(
        LocationPlatformFailure.unavailable,
      );
    await mount(tester, service: await create(tester, platform));
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(_statusText(tester), 'settings.location_action_failed'.tr);
    expect(find.text('common.retry'.tr), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_action)).onPressed, isNotNull);
    platform.positionError = null;
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(platform.positions, 2);
    expect(_statusText(tester), contains('Shanghai'));
    expect(platform.permissionRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported platform has no location action or native request', (
    tester,
  ) async {
    final platform = _Platform()..isSupported = false;
    await mount(tester, service: await create(tester, platform));
    expect(_statusText(tester), 'settings.location_unavailable'.tr);
    expect(find.byKey(_action), findsNothing);
    expect(platform.positions, 0);
    expect(platform.permissionChecks, 0);
    expect(platform.permissionRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from system settings only refreshes permission', (
    tester,
  ) async {
    final platform = _Platform()
      ..permission = LocationPermissionState.deniedForever;
    await mount(tester, service: await create(tester, platform));
    platform.permission = LocationPermissionState.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_statusText(tester), 'settings.location_allowed'.tr);
    expect(platform.permissionRequests, 0);
    expect(platform.positions, 0);
  });

  testWidgets(
    'retirement discards late city and disables the old account row',
    (tester) async {
      final platform = _Platform()
        ..permission = LocationPermissionState.granted
        ..positionGate = Completer<LocationCoordinates>();
      final service = await create(tester, platform);
      await mount(tester, service: service);
      await tester.tap(find.byKey(_action));
      await tester.pump();
      final drained = service.deactivateAndDrain();
      await tester.pump();
      await drained;
      platform.positionGate!.complete(const LocationCoordinates(31.23, 121.47));
      await tester.pumpAndSettle();
      expect(_statusText(tester), 'settings.location_unavailable'.tr);
      expect(find.textContaining('Shanghai'), findsNothing);
      expect(_toggle(tester).value, isFalse);
      expect(_toggle(tester).onChanged, isNull);
      expect(find.byKey(_action), findsNothing);
    },
  );

  testWidgets('failed system settings action presents a recoverable error', (
    tester,
  ) async {
    final platform = _Platform()
      ..permission = LocationPermissionState.deniedForever
      ..settingsResult = false;
    await mount(tester, service: await create(tester, platform));
    await tester.tap(find.byKey(_action));
    await tester.pumpAndSettle();
    expect(find.text('settings.location_settings_failed'.tr), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_action)).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'zh']) {
    for (final dark in [false, true]) {
      testWidgets(
        '$language 320px large-text ${dark ? "dark" : "light"} state fits',
        (tester) async {
          AppLocalization.updateLocale(Locale(language));
          tester.view.physicalSize = const Size(320, 740);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final platform = _Platform()
            ..permission = LocationPermissionState.deniedForever;
          await mount(
            tester,
            service: await create(tester, platform),
            dark: dark,
            scale: 2,
          );
          expect(_statusText(tester), 'settings.location_denied_forever'.tr);
          expect(
            find.text('settings.location_open_settings'.tr),
            findsOneWidget,
          );
          expect(
            tester.getSize(find.byKey(_action)).height,
            greaterThanOrEqualTo(48),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

SwitchListTile _toggle(WidgetTester tester) =>
    tester.widget<SwitchListTile>(find.byKey(_switch));
String _statusText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_status)).data!;

class _Platform implements LocationPlatform {
  LocationPermissionState permission = LocationPermissionState.denied;
  LocationPermissionState requestedPermission = LocationPermissionState.denied;
  bool systemEnabled = true;
  bool settingsResult = true;
  int permissionChecks = 0;
  int permissionRequests = 0;
  int positions = 0;
  int geocodes = 0;
  int appSettings = 0;
  int locationSettings = 0;
  Completer<LocationCoordinates>? positionGate;
  Object? positionError;

  @override
  bool isSupported = true;
  @override
  Future<bool> isServiceEnabled() async => systemEnabled;
  @override
  Future<LocationPermissionState> checkPermission() async {
    permissionChecks++;
    return permission;
  }

  @override
  Future<LocationPermissionState> requestPermission() async {
    permissionRequests++;
    return permission = requestedPermission;
  }

  @override
  Future<LocationCoordinates> currentPosition() async {
    positions++;
    if (positionError != null) throw positionError!;
    return positionGate?.future ?? const LocationCoordinates(31.23, 121.47);
  }

  @override
  Future<LocationCity> reverseGeocode(LocationCoordinates position) async {
    geocodes++;
    return const LocationCity(
      city: 'Shanghai',
      region: 'Shanghai',
      country: 'China',
    );
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<bool> openAppSettings() async {
    appSettings++;
    return settingsResult;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettings++;
    return settingsResult;
  }
}
