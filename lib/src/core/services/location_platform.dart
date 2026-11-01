import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

enum LocationPermissionState { denied, deniedForever, granted, unknown }

enum LocationPlatformFailure {
  denied,
  servicesDisabled,
  timeout,
  cancelled,
  unavailable,
  cityUnavailable,
}

final class LocationPlatformException implements Exception {
  const LocationPlatformException(this.failure);
  final LocationPlatformFailure failure;
}

/// Coordinates exist only at this platform boundary, never in persisted state
/// or in the city-only result consumed by the Agent.
final class LocationCoordinates {
  const LocationCoordinates(this.latitude, this.longitude);
  final double latitude;
  final double longitude;

  bool get isValid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180;
}

final class LocationCity {
  const LocationCity({
    required this.city,
    this.region,
    this.country,
    this.countryCode,
  });
  final String city;
  final String? region;
  final String? country;
  final String? countryCode;
}

abstract interface class LocationPlatform {
  bool get isSupported;
  Future<bool> isServiceEnabled();
  Future<LocationPermissionState> checkPermission();
  Future<LocationPermissionState> requestPermission();
  Future<LocationCoordinates> currentPosition();
  Future<LocationCity> reverseGeocode(LocationCoordinates position);
  Future<void> cancel();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}

final class GeolocatorLocationPlatform implements LocationPlatform {
  GeolocatorLocationPlatform({MethodChannel? channel, DateTime Function()? now})
    : _channel = channel ?? const MethodChannel('maaso/location'),
      _now = now ?? DateTime.now;

  final MethodChannel _channel;
  final DateTime Function() _now;
  StreamSubscription<Position>? _positionSubscription;
  Completer<LocationCoordinates>? _positionResult;

  @override
  bool get isSupported =>
      !kIsWeb &&
      <TargetPlatform>{
        TargetPlatform.iOS,
        TargetPlatform.android,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  static LocationPermissionState _permission(LocationPermission value) =>
      switch (value) {
        LocationPermission.denied => LocationPermissionState.denied,
        LocationPermission.deniedForever =>
          LocationPermissionState.deniedForever,
        LocationPermission.whileInUse ||
        LocationPermission.always => LocationPermissionState.granted,
        LocationPermission.unableToDetermine => LocationPermissionState.unknown,
      };

  @override
  Future<LocationPermissionState> checkPermission() async =>
      _permission(await Geolocator.checkPermission());

  @override
  Future<LocationPermissionState> requestPermission() async =>
      _permission(await Geolocator.requestPermission());

  @override
  Future<LocationCoordinates> currentPosition() async {
    if (_positionResult != null) {
      throw const LocationPlatformException(
        LocationPlatformFailure.unavailable,
      );
    }
    final result = Completer<LocationCoordinates>();
    _positionResult = result;
    final settings =
        defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS
        ? AppleSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: const Duration(seconds: 8),
            allowBackgroundLocationUpdates: false,
            pauseLocationUpdatesAutomatically: true,
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 8),
          );
    try {
      // A stream is used for one fix only so retirement/backgrounding can
      // cancel the native GPS request; getCurrentPosition has no cancel API.
      _positionSubscription =
          Geolocator.getPositionStream(locationSettings: settings).listen(
            (position) {
              if (!result.isCompleted) {
                final coordinates = LocationCoordinates(
                  position.latitude,
                  position.longitude,
                );
                if (!coordinates.isValid) {
                  result.completeError(
                    const LocationPlatformException(
                      LocationPlatformFailure.unavailable,
                    ),
                  );
                  return;
                }
                // The Apple plugin filters cached fixes only for its separate
                // getCurrentPosition manager. The cancellable stream path may
                // first deliver an old fix, so wait for a recent one within
                // this request's original eight-second deadline.
                final age = _now().difference(position.timestamp);
                if (age > const Duration(minutes: 2) ||
                    age < -const Duration(seconds: 30)) {
                  return;
                }
                result.complete(coordinates);
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!result.isCompleted) {
                result.completeError(_boundedFailure(error), stack);
              }
            },
            onDone: () {
              if (!result.isCompleted) {
                result.completeError(
                  const LocationPlatformException(
                    LocationPlatformFailure.unavailable,
                  ),
                );
              }
            },
          );
      return await result.future.timeout(const Duration(seconds: 8));
    } catch (error) {
      throw _boundedFailure(error);
    } finally {
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      if (identical(_positionResult, result)) _positionResult = null;
    }
  }

  @override
  Future<LocationCity> reverseGeocode(LocationCoordinates position) async {
    if (!position.isValid) {
      throw const LocationPlatformException(
        LocationPlatformFailure.unavailable,
      );
    }
    try {
      final result = await _channel
          .invokeMapMethod<String, Object?>('reverseGeocode', <String, Object?>{
            'latitude': position.latitude,
            'longitude': position.longitude,
          })
          .timeout(const Duration(seconds: 11));
      final city = _cityField(result?['city']);
      if (result?['status'] != 'available' || city == null) {
        final code = result?['code'];
        throw LocationPlatformException(
          code == 'timeout'
              ? LocationPlatformFailure.timeout
              : code == 'cancelled'
              ? LocationPlatformFailure.cancelled
              : LocationPlatformFailure.cityUnavailable,
        );
      }
      return LocationCity(
        city: city,
        region: _cityField(result?['region']),
        country: _cityField(result?['country']),
        countryCode: _countryCodeField(result?['countryCode']),
      );
    } catch (error) {
      throw _boundedFailure(error);
    }
  }

  static String? _cityField(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty ||
        text.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
      return null;
    }
    return text;
  }

  static String? _countryCodeField(Object? value) =>
      value is String && RegExp(r'^[A-Z]{2}$').hasMatch(value) ? value : null;

  static LocationPlatformException _boundedFailure(Object error) {
    if (error is LocationPlatformException) return error;
    if (error is TimeoutException) {
      return const LocationPlatformException(LocationPlatformFailure.timeout);
    }
    if (error is PermissionDeniedException) {
      return const LocationPlatformException(LocationPlatformFailure.denied);
    }
    if (error is LocationServiceDisabledException) {
      return const LocationPlatformException(
        LocationPlatformFailure.servicesDisabled,
      );
    }
    return const LocationPlatformException(LocationPlatformFailure.unavailable);
  }

  @override
  Future<void> cancel() async {
    final result = _positionResult;
    if (result != null && !result.isCompleted) {
      result.completeError(
        const LocationPlatformException(LocationPlatformFailure.cancelled),
      );
    }
    await _positionSubscription?.cancel();
    try {
      await _channel
          .invokeMethod<void>('cancelReverseGeocode')
          .timeout(const Duration(seconds: 1));
    } on Object {
      // Cancellation is best effort; the service also fences every late result.
    }
  }

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
}
