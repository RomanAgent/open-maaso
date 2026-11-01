import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:sembast/sembast_memory.dart';

class _ControllerResolver<T extends Object> extends ConsumerWidget {
  const _ControllerResolver();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServicesProvider);
    appServices.find<T>();
    return const SizedBox.shrink();
  }
}

class _IdleAgentCoreController extends AgentCoreController {
  @override
  // Test double isolates lazy controller initialization from profile loading.
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets(
    'lazy SkillStoreController initialization does not modify providers during build',
    (tester) async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'skill-store-riverpod-lifecycle.db',
      );
      appServices.put<DBService>(database);
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      appServices.put(AppEnvironmentService());
      final auth = appServices.put(AuthSessionService());
      auth.session.value = MaasoAuthSession(
        accountUuid: 'account-1',
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
      var requests = 0;
      appServices.put(
        SkillMarketplaceService(
          httpClient: MockClient((_) async {
            requests++;
            return http.Response(
              jsonEncode(<String, Object?>{'code': 'OK', 'data': <Object?>[]}),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        ),
      );
      appServices.put<AgentCoreController>(_IdleAgentCoreController());
      appServices.put(InstalledSkillRegistry(database: database));
      appServices.put(AgentRuntimeRegistry());
      appServices.lazyPut<SkillStoreController>(SkillStoreController.new);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(
            home: _ControllerResolver<SkillStoreController>(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(requests, 5);
      expect(appServices.find<SkillStoreController>().isLoading.value, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async => values.remove(key) != null;
}
