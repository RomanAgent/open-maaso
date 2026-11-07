import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_model_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    documents = await Directory.systemTemp.createTemp(
      'open-maaso-speech-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => documents.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await documents.delete(recursive: true);
  });
  const absent = SherpaModel(
    id: 'absent-local-model',
    displayName: 'Absent',
    releaseUrl: 'https://example.com/model.tar.bz2',
    approxBytes: 100,
    directFiles: {'model.onnx': 'https://example.com/model.onnx'},
  );

  test(
    'local speech preparation fails before direct-file or archive networking',
    () async {
      var networkClients = 0;
      await HttpOverrides.runZoned(
        () async {
          final service = SherpaModelDownloadService(allowNetwork: false);
          await expectLater(
            service.ensure(absent),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('not available in the app bundle'),
              ),
            ),
          );
          expect(service.statusOf(absent.id).isReady.value, isFalse);
          expect(networkClients, 0);
        },
        createHttpClient: (_) {
          networkClients++;
          throw StateError('unexpected network');
        },
      );
    },
  );

  test(
    'an already installed local model stays available without downloads',
    () async {
      final cache = Directory('${documents.path}/sherpa_models/${absent.id}');
      await cache.create(recursive: true);
      await File('${cache.path}/.ready').create();
      final service = SherpaModelDownloadService(allowNetwork: false);
      expect((await service.ensure(absent)).path, cache.path);
      expect(service.statusOf(absent.id).isReady.value, isTrue);
    },
  );
}
