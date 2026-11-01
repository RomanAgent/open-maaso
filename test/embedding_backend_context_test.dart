import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'the default embedding context follows actual account mount generations',
    () async {
      final scopes = appServices.put(AccountStorageScopeService());
      final backend = _Backend();
      final service = EmbeddingService(backend: backend);
      expect(service.isAvailable, isFalse);
      final scope = AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'account-a',
      );
      final first = scopes.mount(scope);
      expect(await service.embed('same text'), [1.0]);
      scopes.unmount(first);
      expect(await service.embed('same text'), isNull);
      scopes.mount(scope);
      expect(await service.embed('same text'), [2.0]);
    },
  );

  test(
    'an old provider failure cannot disable the newly selected provider',
    () async {
      final scopes = appServices.put(AccountStorageScopeService());
      appServices.put<SecureStorageService>(SecureStorageService());
      final config = appServices.put(
        LLMConfigController(storageScopes: scopes),
      );
      config.cloudEnabled.value = true;
      config.baseUrl.value = 'https://first.invalid/v1';
      config.apiKey.value = 'test-only-key-a';
      final entered = Completer<(RequestOptions, RequestInterceptorHandler)>();
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              entered.complete((options, handler));
            },
          ),
        );
      final backend = CloudEmbeddingBackend(dio: dio);
      final result = backend.embed('fixture input');
      final (options, handler) = await entered.future;
      expect(options.uri.host, 'first.invalid');
      config.baseUrl.value = 'https://second.invalid/v1';
      config.apiKey.value = 'test-only-key-b';
      handler.reject(
        DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
          type: DioExceptionType.badResponse,
        ),
      );
      expect(await result, isNull);
      expect(backend.isAvailable, isTrue);
      dio.close(force: true);
    },
  );
}

class _Backend extends EmbeddingBackend {
  int calls = 0;
  @override
  bool get isAvailable => true;
  @override
  Future<List<double>?> embed(String text) async => [(++calls).toDouble()];
}
