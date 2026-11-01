import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<SkillSpec> originalCatalog;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    appServices.put(SecureStorageService());
    appServices.put(AgentTaskJobStore());
    originalCatalog = List<SkillSpec>.from(SkillCatalog.all);
  });

  tearDown(() {
    SkillCatalog.all
      ..clear()
      ..addAll(originalCatalog);
    appServices.reset();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test(
    'structured runtime exposes and executes only the granted prompt-only edit',
    () async {
      final skill = _RuntimePromptOnlySurfaceSkill();
      SkillCatalog.all
        ..clear()
        ..add(_surfaceSpec(skill));
      final surface = appServices.put(SurfaceRuntime());
      await surface.show(
        SurfaceProject.fromJson(<String, Object?>{
          'id': 'existing-surface',
          'title': 'Existing Surface',
          'kind': 'fullscreen',
          'rendering': 'dom',
          'html': '<main>existing</main>',
          'manifest': const <String, Object?>{
            'events': <Object?>[],
            'actions': <Object?>[],
          },
        }),
      );
      final llm = _StructuredActionLlm('''
{"reply":"edited","actions":[{"type":"skill.call","tool":"skill_freeformsurface_editsurface","args":{"surfaceId":"existing-surface","html":"<main>edited</main>"}}]}
''');
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(runtime.dispose);
      final mode = appServices.put(MaasoAgentModeService());
      mode.pipelineMode.value = AgentPipelineMode.directCloud;

      await runtime.init(enabledSkillIds: const <String>{'surface'});
      final result = await runtime.chat('再加一行文字', const <Message>[]);

      expect(result.isSuccess, isTrue);
      expect(skill.calls['editSurface'], 1);
      expect(skill.calls['revertSurface'] ?? 0, 0);
      expect(skill.calls['listSurfaces'] ?? 0, 0);
      expect(skill.nativeToolSchemas, isNull);
      expect(runtime.skillManager.hasNativeTools, isFalse);
      final systemPrompt = llm.lastMessages
          .where((message) => message.role == 'system')
          .map((message) => message.content)
          .join('\n');
      expect(systemPrompt, contains('skill_freeformsurface_editsurface'));
      expect(systemPrompt, contains('"required":["surfaceId"]'));
      expect(systemPrompt, contains('Edit only the currently visible'));
      expect(
        systemPrompt,
        isNot(contains('skill_freeformsurface_revertsurface')),
      );
      expect(
        systemPrompt,
        isNot(contains('skill_freeformsurface_listsurfaces')),
      );
      expect(
        systemPrompt,
        isNot(contains('skill_freeformsurface_showsurface')),
      );
      expect(
        systemPrompt,
        isNot(contains('skill_freeformsurface_reopensurface')),
      );
    },
  );
}

SkillSpec _surfaceSpec(_RuntimePromptOnlySurfaceSkill skill) => SkillSpec(
  id: 'surface',
  name: 'surface',
  description: 'surface',
  icon: Icons.layers_rounded,
  color: Colors.blue,
  category: SkillCategory.expression,
  factory: (_) => skill,
  hostRouting: HostSkillRoutingManifest(
    skillName: 'FreeformSurface',
    summary: 'Edit or revert the visible Surface.',
    methods: const <String>[
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    ],
    nativeMethods: const <String>[],
    terms: const <String>['再加一行'],
  ),
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

final class _RuntimePromptOnlySurfaceSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  final Map<String, int> calls = <String, int>{};

  @override
  String get skillName => 'FreeformSurface';

  @override
  String get description => 'Edit or revert the visible Surface.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    for (final method in const <String>[
      'showSurface',
      'editSurface',
      'listSurfaces',
      'reopenSurface',
      'revertSurface',
    ])
      method: (_) {
        calls[method] = (calls[method] ?? 0) + 1;
        return '{}';
      },
  };

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas =>
      StructuredActionPromptSchemas(<String, Map<String, dynamic>>{
        'editSurface': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'surfaceId': <String, dynamic>{'type': 'string'},
            'html': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['surfaceId'],
          'additionalProperties': false,
        },
        'revertSurface': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'surfaceId': <String, dynamic>{'type': 'string'},
            'revisionId': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['surfaceId'],
          'additionalProperties': false,
        },
      });
}

final class _StructuredActionLlm extends LLMClient {
  _StructuredActionLlm(this.response);

  final String response;
  List<Message> lastMessages = const <Message>[];

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    lastMessages = List<Message>.from(messages);
    return response;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
}
