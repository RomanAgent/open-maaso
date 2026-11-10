import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<SkillSpec> catalog;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    catalog = List.of(SkillCatalog.all);
    SkillCatalog.all.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  tearDown(() async {
    SkillCatalog.all
      ..clear()
      ..addAll(catalog);
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  for (final configured in [false, true]) {
    test(
      'API-only turn configured=$configured cannot load or infer a stale local model',
      () async {
        final storage = appServices.put<SecureStorageService>(_MemoryStorage());
        final scopes = AccountStorageScopeService();
        final mount = scopes.mount(
          AccountStorageScope(
            environmentKey: 'test',
            accountUuid: 'api-only-runtime',
          ),
        );
        final config = appServices.put(
          LLMConfigController(
            storage: storage,
            storageScopes: scopes,
            localEdition: true,
          ),
        );
        await config.activateAccount(mount);
        if (configured) {
          await config.saveConfig(
            'fixture-key',
            'https://model.example.test/v1',
            'fixture-model',
            session: config.requireActiveAccountSession(),
            enabled: false,
          );
        }
        final staleLocal = appServices.put<LocalLLMService>(
          _StaleLocalService(),
        );
        final backend = appServices.put<LocalLLMBackend>(
          _ForbiddenLocalBackend(),
        );
        appServices.put(LocalBrainService());
        appServices.put(AgentTaskJobStore());
        final staleMode = appServices.put(MaasoAgentModeService());
        staleMode.pipelineMode.value = AgentPipelineMode.localFull;
        // A retired health service must neither veto a user's saved key nor
        // trigger a different answer engine in the API-only edition.
        appServices.put(CloudLLMHealthService());
        final llm = _RecordingLlm();
        final runtime = AgentRuntime(
          agentId: 'self',
          profile: AgentProfile(
            nickname: 'Maaso',
            avatar: '',
            bio: 'test',
            personalityTraits: const ['warm'],
            catchphrase: 'ok',
          ),
          llmClient: llm,
        );
        await runtime.init(enabledSkillIds: const {});
        final result = await runtime.chat('hello there', const []);
        expect(result.isSuccess, isTrue);
        expect((staleLocal as _StaleLocalService).loadCalls, 0);
        expect((backend as _ForbiddenLocalBackend).inferenceCalls, 0);
        if (configured) {
          expect(llm.calls, greaterThan(0));
          expect(result.stdout, 'configured provider reply');
        } else {
          expect(llm.calls, 0);
          expect(result.stdout.toLowerCase(), contains('api key'));
          expect(result.stdout, isNot(contains('Cloud brain')));
        }
        runtime.dispose();
        scopes.unmount(mount);
        await config.deactivateAccountAndDrain();
      },
    );
  }
}

final class _StaleLocalService extends Fake implements LocalLLMService {
  int loadCalls = 0;
  @override
  final isEnabled = true.obs;
  @override
  final isAvailable = true.obs;
  @override
  Future<bool> ensureLoadedForFallback({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    loadCalls++;
    return true;
  }

  @override
  void initializeLifecycle() {}
  @override
  void closeLifecycle() {}
}

final class _ForbiddenLocalBackend extends Fake implements LocalLLMBackend {
  int inferenceCalls = 0;
  @override
  bool get isReady => true;
  @override
  void cancelTransient() {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    inferenceCalls++;
    throw StateError('API-only turns must never reach a local model.');
  }
}

final class _RecordingLlm extends Fake implements LLMClient {
  int calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    return '{"reply":"configured provider reply","actions":[]}';
  }

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }
}

final class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
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
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
