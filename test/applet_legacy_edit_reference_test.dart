import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/surface/surface_interaction_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy Home chat carries selected applet context and edit authority',
    () async {
      await appServices.reset();
      appServices.testMode = true;
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'legacy-applet-edit.db',
      );
      final profile = AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: '',
        personalityTraits: const [],
        catchphrase: '',
      );
      await database.saveAgentProfile(profile);
      final runtime = _LegacyRuntime(profile);
      appServices.put<DBService>(database);
      appServices.put<AgentRuntimeRegistry>(_LegacyRegistry(runtime));
      appServices.put<AgentCoreController>(_LegacyCore(profile));
      appServices.put(AgentTaskJobStore());
      final surface = appServices.put(SurfaceRuntime());
      appServices.put(WidgetStageController());
      final home = appServices.put(HomeController());
      addTearDown(() async {
        clearAppletEditReference();
        await appServices.delete<HomeController>(force: true);
        runtime.dispose();
        await appServices.reset();
        await database.close();
      });
      await Future<void>.delayed(Duration.zero);
      final item = AgentWidget(
        agentId: 'self',
        title: '旅行助手',
        kind: 'surface',
        createdAt: DateTime.now(),
        seen: true,
        spec: {
          'surfaceId': 'legacy-trip',
          'surfaceKind': 'card',
          'rendering': 'dom',
          'experienceType': 'utility',
          'html': '<main>Travel plan</main>',
          'css': '',
          'js': '',
          'manifest': {'events': [], 'actions': []},
        },
      );
      AppletLocalOwnership.stamp(item);
      item.id = await database.saveAgentWidget(item);
      appletEditReference.value = AppletEditReference(
        item: item,
        scopeKey: AppletLocalOwnership.currentScopeKey(),
      );

      home.inputController.text = '增加一个预算功能';
      await home.send();

      expect(runtime.userText, '增加一个预算功能');
      final quoted = runtime.history
          .map((entry) => entry.content)
          .firstWhere(
            (text) => text.contains('user_selected_applet_for_editing'),
          );
      expect((jsonDecode(quoted) as Map)['surfaceId'], 'legacy-trip');
      expect(surface.activeSurfaceId, 'legacy-trip');
      expect(
        SurfaceInteractionAuthority.resolve(
          text: runtime.userText!,
          activeSurfaceId: surface.activeSurfaceId,
        )?.methodName,
        'editSurface',
      );
      expect(runtime.scope, AppletLocalOwnership.currentScopeKey());
      expect(await database.getAllWidgets(), hasLength(1));
    },
  );
}

class _LegacyRuntime extends AgentRuntime {
  _LegacyRuntime(AgentProfile profile)
    : super(agentId: 'self', profile: profile, llmClient: _UnusedLlm());
  String? userText;
  String? scope;
  List<Message> history = const [];
  @override
  bool get usesConversationTurns => false;
  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) async {
    userText = currentUserText;
    scope = expectedAppletScopeKey;
    this.history = history;
    return ExecutionResult.success('ready');
  }
}

class _LegacyRegistry extends AgentRuntimeRegistry {
  _LegacyRegistry(this.runtime);
  final AgentRuntime runtime;
  @override
  AgentRuntime? get(String agentId) => runtime;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async => runtime;
}

class _LegacyCore extends AgentCoreController {
  _LegacyCore(this.testProfile);
  final AgentProfile testProfile;
  @override
  // The fixture owns the profile and does not run startup ceremony.
  // ignore: must_call_super
  void onInit() => profile.value = testProfile;
}

class _UnusedLlm implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
