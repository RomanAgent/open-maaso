import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/sherpa_model_download_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    TTSEngineRegistry.current = null;
  });

  tearDown(() async {
    TTSEngineRegistry.current = null;
    await appServices.reset();
  });

  test(
    'deadline fences gated account A pipeline refresh before B activation',
    () async {
      final localTtsGate = Completer<bool>();
      final localTtsRead = Completer<void>();
      final scopes = appServices.put(AccountStorageScopeService());
      final pipeline = appServices.put(
        _GatedPipelineRuntimeService(localTtsGate, localTtsRead),
      );
      final mountA = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'account-a'),
      );

      await pipeline.activateAccount(mountA);
      final accountA = pipeline.activeAccountSession!;
      final refreshA = pipeline.refreshForMode(
        AgentPipelineMode.localFull,
        accountSession: accountA,
      );
      await localTtsRead.future;

      var drainCompleted = false;
      final drain = pipeline.deactivateAccountAndDrain().then(
        (_) => drainCompleted = true,
      );
      final fencedEngine = TTSEngineRegistry.current;
      expect(pipeline.isAccountSessionActive(accountA), isFalse);
      expect(drainCompleted, isFalse);

      scopes.unmount(mountA);
      final mountB = scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'account-b'),
      );
      expect(() => pipeline.activateAccount(mountB), throwsStateError);

      localTtsGate.complete(true);
      await refreshA;
      await drain;

      expect(TTSEngineRegistry.current, same(fencedEngine));
      expect(appServices.isRegistered<SherpaModelDownloadService>(), isFalse);
      expect(appServices.isRegistered<SherpaNeuralTts>(), isFalse);

      await pipeline.activateAccount(mountB);
      final accountB = pipeline.activeAccountSession!;
      expect(accountB.mount, same(mountB));
      expect(pipeline.isAccountSessionActive(accountB), isTrue);
      expect(pipeline.isAccountSessionActive(accountA), isFalse);
    },
  );
}

final class _GatedPipelineRuntimeService extends AgentPipelineRuntimeService {
  _GatedPipelineRuntimeService(this._gate, this._read)
    : super(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.macos,
        ),
      );

  final Completer<bool> _gate;
  final Completer<void> _read;

  @override
  Future<bool> localTtsEnabled() {
    if (!_read.isCompleted) _read.complete();
    return _gate.future;
  }
}
