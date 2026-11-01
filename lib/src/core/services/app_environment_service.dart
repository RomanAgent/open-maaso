import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

const bool kMaasoStoreInternalBuild = bool.fromEnvironment(
  'MAASO_STORE_INTERNAL_BUILD',
);

enum MaasoEnvironment {
  test(
    'test',
    'Test',
    String.fromEnvironment(
      'MAASO_TEST_BASE_URL',
      defaultValue: 'https://test-api.open-maaso.invalid',
    ),
  ),
  production(
    'prod',
    'Production',
    String.fromEnvironment(
      'MAASO_PRODUCTION_BASE_URL',
      defaultValue: 'https://api.open-maaso.invalid',
    ),
  );

  const MaasoEnvironment(this.key, this.label, this.baseUrl);

  final String key;
  final String label;
  final String baseUrl;

  static MaasoEnvironment fromKey(String? key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return MaasoEnvironment.test;
  }
}

class AppEnvironmentService extends AppService {
  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();

  final environment = MaasoEnvironment.test.obs;
  Future<void> _operationTail = Future<void>.value();
  int _operationEpoch = 0;

  List<MaasoEnvironment> get allowedEnvironments => kMaasoStoreInternalBuild
      ? const <MaasoEnvironment>[MaasoEnvironment.test]
      : MaasoEnvironment.values;

  String get baseUrl => environment.value.baseUrl;
  Uri get baseUri => Uri.parse('${environment.value.baseUrl}/');

  Future<AppEnvironmentService> init() async {
    final restored = MaasoEnvironment.fromKey(
      await _storage.read(GlobalConstant.keyMaasoEnvironment),
    );
    if (!allowedEnvironments.contains(restored)) {
      if (!await _storage.write(
        GlobalConstant.keyMaasoEnvironment,
        MaasoEnvironment.test.key,
      )) {
        throw StateError('Failed to persist the allowed app environment.');
      }
      environment.value = MaasoEnvironment.test;
    } else {
      environment.value = restored;
    }
    return this;
  }

  Future<void> setEnvironment(MaasoEnvironment next) {
    if (!allowedEnvironments.contains(next)) {
      return Future<void>.error(
        StateError(
          'Environment ${next.key} is disabled for this store-internal build',
        ),
      );
    }
    final operation = ++_operationEpoch;
    final completer = Completer<void>();
    _operationTail = _operationTail.then((_) async {
      try {
        if (operation != _operationEpoch) {
          throw StateError('Environment operation was superseded.');
        }
        if (!await _storage.write(
          GlobalConstant.keyMaasoEnvironment,
          next.key,
        )) {
          throw StateError('Failed to persist app environment ${next.key}.');
        }
        if (operation != _operationEpoch) {
          throw StateError('Environment operation was superseded.');
        }
        environment.value = next;
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
