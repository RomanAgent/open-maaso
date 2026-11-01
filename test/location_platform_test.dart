import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maaso/src/core/services/location_platform.dart';

final class _SingleFixGeolocator extends GeolocatorPlatform {
  _SingleFixGeolocator() {
    positions = StreamController<Position>.broadcast(
      onCancel: () {
        cancellationCount++;
      },
    );
  }
  late final StreamController<Position> positions;
  LocationSettings? requestedSettings;
  int cancellationCount = 0;
  LocationPermission permission = LocationPermission.whileInUse;

  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async => permission;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) {
    requestedSettings = locationSettings;
    return positions.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('maaso/location');
  late GeolocatorPlatform original;
  late _SingleFixGeolocator native;
  final now = DateTime.utc(2026, 10, 14, 15);
  Position fix({DateTime? timestamp, double latitude = 31.23}) => Position(
    latitude: latitude,
    longitude: 121.47,
    timestamp: timestamp ?? now,
    accuracy: 3000,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  final position = fix();

  setUp(() {
    original = GeolocatorPlatform.instance;
    native = _SingleFixGeolocator();
    GeolocatorPlatform.instance = native;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });
  tearDown(() async {
    await native.positions.close();
    GeolocatorPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'one fix uses low accuracy, stops native subscription, excludes background updates',
    () async {
      final adapter = GeolocatorLocationPlatform(now: () => now);
      final pending = adapter.currentPosition();
      native.positions.add(position);
      final result = await pending;
      expect(result.latitude, 31.23);
      expect(native.cancellationCount, 1);
      final settings = native.requestedSettings! as AppleSettings;
      expect(settings.accuracy, LocationAccuracy.low);
      expect(settings.timeLimit, const Duration(seconds: 8));
      expect(settings.allowBackgroundLocationUpdates, false);
      expect(settings.showBackgroundLocationIndicator, false);
    },
  );

  test(
    'old and implausibly future GPS fixes are ignored until a current fix arrives',
    () async {
      final adapter = GeolocatorLocationPlatform(now: () => now);
      var completed = false;
      final pending = adapter.currentPosition().then((value) {
        completed = true;
        return value;
      });
      native.positions.add(
        fix(timestamp: now.subtract(const Duration(days: 10)), latitude: 45),
      );
      native.positions.add(
        fix(timestamp: now.add(const Duration(minutes: 10)), latitude: 46),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, false);
      expect(native.cancellationCount, 0);
      native.positions.add(position);
      final result = await pending;
      expect(result.latitude, 31.23);
      expect(native.cancellationCount, 1);
      expect(native.requestedSettings!.timeLimit, const Duration(seconds: 8));
    },
  );

  test(
    'invalid GPS coordinates fail and stop the single-fix subscription',
    () async {
      final adapter = GeolocatorLocationPlatform(now: () => now);
      final pending = adapter.currentPosition();
      native.positions.add(fix(latitude: double.nan));
      await expectLater(
        pending,
        throwsA(
          isA<LocationPlatformException>().having(
            (error) => error.failure,
            'failure',
            LocationPlatformFailure.unavailable,
          ),
        ),
      );
      expect(native.cancellationCount, 1);
    },
  );

  test(
    'background and retirement cancellation stops native GPS request',
    () async {
      final adapter = GeolocatorLocationPlatform();
      final pending = adapter.currentPosition();
      final assertion = expectLater(
        pending,
        throwsA(
          isA<LocationPlatformException>().having(
            (error) => error.failure,
            'failure',
            LocationPlatformFailure.cancelled,
          ),
        ),
      );
      await adapter.cancel();
      await assertion;
      expect(native.cancellationCount, 1);
    },
  );

  test(
    'native denied error remains bounded instead of leaking provider text',
    () async {
      final pending = GeolocatorLocationPlatform().currentPosition();
      native.positions.addError(
        const PermissionDeniedException('private location details'),
      );
      await expectLater(
        pending,
        throwsA(
          isA<LocationPlatformException>().having(
            (error) => error.failure,
            'failure',
            LocationPlatformFailure.denied,
          ),
        ),
      );
      expect(native.cancellationCount, 1);
    },
  );

  test(
    'native city protocol exposes only city and coarse country fields',
    () async {
      MethodCall? sent;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            sent = call;
            return <String, Object?>{
              'status': 'available',
              'city': ' Shanghai ',
              'region': 'Shanghai',
              'country': 'China',
              'countryCode': 'CN',
              'street': 'private street ignored',
            };
          });
      final result = await GeolocatorLocationPlatform().reverseGeocode(
        const LocationCoordinates(31.23, 121.47),
      );
      expect(sent!.method, 'reverseGeocode');
      expect(sent!.arguments, <String, double>{
        'latitude': 31.23,
        'longitude': 121.47,
      });
      expect(result.city, 'Shanghai');
      expect(result.region, 'Shanghai');
      expect(result.country, 'China');
      expect(result.countryCode, 'CN');
    },
  );

  test('countryCode only accepts two uppercase ASCII letters', () async {
    for (final countryCode in <Object?>[
      null,
      42,
      '',
      'cn',
      'CN ',
      'CN\n',
      'CHN',
      'CＮ',
      'ß',
      '中国',
      'CN',
      'HK',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => <String, Object?>{
              'status': 'available',
              'city': 'City',
              'countryCode': countryCode,
            },
          );
      final result = await GeolocatorLocationPlatform().reverseGeocode(
        const LocationCoordinates(1, 2),
      );
      expect(
        result.countryCode,
        countryCode == 'CN' || countryCode == 'HK' ? countryCode : null,
      );
    }
  });

  test('invalid coordinates never invoke native reverse lookup', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return null;
        });
    await expectLater(
      GeolocatorLocationPlatform().reverseGeocode(
        const LocationCoordinates(double.infinity, 200),
      ),
      throwsA(isA<LocationPlatformException>()),
    );
    expect(calls, 0);
  });

  test(
    'no city and malformed city fail explicitly without falling back to region',
    () async {
      final adapter = GeolocatorLocationPlatform();
      for (final city in <Object?>[null, 42, '', 'City\nprovider', 'a' * 129]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => <String, Object?>{
                'status': 'available',
                'city': city,
                'region': 'Province',
              },
            );
        await expectLater(
          adapter.reverseGeocode(const LocationCoordinates(1, 2)),
          throwsA(
            isA<LocationPlatformException>().having(
              (error) => error.failure,
              'failure',
              LocationPlatformFailure.cityUnavailable,
            ),
          ),
        );
      }
    },
  );

  test(
    'native timeout and cancelled status map to explicit bounded failures',
    () async {
      final adapter = GeolocatorLocationPlatform();
      for (final expected in <String, LocationPlatformFailure>{
        'timeout': LocationPlatformFailure.timeout,
        'cancelled': LocationPlatformFailure.cancelled,
      }.entries) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => <String, Object?>{
                'status': 'unavailable',
                'code': expected.key,
              },
            );
        await expectLater(
          adapter.reverseGeocode(const LocationCoordinates(1, 2)),
          throwsA(
            isA<LocationPlatformException>().having(
              (error) => error.failure,
              'failure',
              expected.value,
            ),
          ),
        );
      }
    },
  );

  test(
    'SDK permission mappings distinguish permanent denial and granted while in use',
    () async {
      final adapter = GeolocatorLocationPlatform();
      for (final expected in <LocationPermission, LocationPermissionState>{
        LocationPermission.denied: LocationPermissionState.denied,
        LocationPermission.deniedForever: LocationPermissionState.deniedForever,
        LocationPermission.whileInUse: LocationPermissionState.granted,
        LocationPermission.always: LocationPermissionState.granted,
        LocationPermission.unableToDetermine: LocationPermissionState.unknown,
      }.entries) {
        native.permission = expected.key;
        expect(await adapter.checkPermission(), expected.value);
        expect(await adapter.requestPermission(), expected.value);
      }
    },
  );
}
