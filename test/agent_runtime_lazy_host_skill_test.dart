import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

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
    'runtime initializes zero factories then activates one selected host once',
    () async {
      var alphaCreated = 0;
      var betaCreated = 0;
      SkillCatalog.all
        ..clear()
        ..addAll(<SkillSpec>[
          _spec(
            id: 'alpha',
            skillName: 'AlphaHost',
            terms: const <String>['alpha ritual'],
            factory: (_) {
              alphaCreated++;
              return _RecordingHostSkill('AlphaHost');
            },
          ),
          _spec(
            id: 'beta',
            skillName: 'BetaHost',
            terms: const <String>['beta ritual'],
            factory: (_) {
              betaCreated++;
              return _RecordingHostSkill('BetaHost');
            },
          ),
        ]);
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();

      await runtime.init(enabledSkillIds: const <String>{'alpha', 'beta'});

      expect(alphaCreated, 0);
      expect(betaCreated, 0);
      expect(runtime.skillManager.skills, isEmpty);

      expect(
        (await runtime.chat('please use alpha ritual', const [])).isSuccess,
        isTrue,
      );
      expect(alphaCreated, 1);
      expect(betaCreated, 0);
      expect(runtime.skillManager.skills.map((skill) => skill.skillName), [
        'AlphaHost',
      ]);

      expect(
        (await runtime.chat(
          'please use alpha ritual again',
          const [],
        )).isSuccess,
        isTrue,
      );
      expect(alphaCreated, 1);
      expect(betaCreated, 0);
    },
  );

  test('a no-match turn leaves every host factory cold', () async {
    var created = 0;
    SkillCatalog.all
      ..clear()
      ..add(
        _spec(
          id: 'alpha',
          skillName: 'AlphaHost',
          terms: const <String>['alpha ritual'],
          factory: (_) {
            created++;
            return _RecordingHostSkill('AlphaHost');
          },
        ),
      );
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: _NoActionLlm(),
    );
    addTearDown(runtime.dispose);
    _useDirectCloudMode();

    await runtime.init(enabledSkillIds: const <String>{'alpha'});
    expect((await runtime.chat('hello there', const [])).isSuccess, isTrue);

    expect(created, 0);
    expect(runtime.skillManager.skills, isEmpty);
  });

  test('existing runtime resnapshots availability off-enforce-off', () async {
    var available = false;
    var created = 0;
    SkillCatalog.all
      ..clear()
      ..add(
        _spec(
          id: 'activity',
          skillName: 'CompanionActivity',
          methodName: 'activitySummary',
          terms: const <String>['activity ritual'],
          availability: () => available,
          factory: (_) {
            created++;
            return _RecordingHostSkill(
              'CompanionActivity',
              methodName: 'activitySummary',
            );
          },
        ),
      );
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: _NoActionLlm(),
    );
    addTearDown(runtime.dispose);
    _useDirectCloudMode();
    await runtime.init(enabledSkillIds: const <String>{'activity'});

    await runtime.chat('please use activity ritual', const []);
    expect(created, 0);

    available = true;
    await runtime.chat('please use activity ritual', const []);
    expect(created, 1);

    available = false;
    await runtime.chat('please use activity ritual', const []);
    expect(created, 1);

    available = true;
    await runtime.chat('please use activity ritual', const []);
    expect(created, 1, reason: 'off revoked but retained the bounded identity');
  });

  test(
    'runtime recovers the same host identity after snapshot off-on',
    () async {
      var created = 0;
      final resolver = _ToggleSkillSnapshotResolver('alpha');
      final snapshots = appServices.put(
        AppCapabilitySnapshotService(
          resolver: resolver,
          initialContext: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.macos,
            rolloutGeneration: 0,
          ),
        ),
      );
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'alpha',
            skillName: 'AlphaHost',
            terms: const <String>['alpha ritual'],
            factory: (_) {
              created += 1;
              return _RecordingHostSkill('AlphaHost');
            },
          ),
        );
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();
      await runtime.init(enabledSkillIds: const <String>{'alpha'});

      await runtime.chat('please use alpha ritual', const []);
      final original = runtime.skillManager.findSkill('AlphaHost');
      expect(original, isNotNull);
      expect(created, 1);

      resolver.enabled = false;
      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      await runtime.chat('please use alpha ritual', const []);
      expect(runtime.skillManager.findSkill('AlphaHost'), isNull);
      expect(created, 1);

      resolver.enabled = true;
      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 2));
      await runtime.chat('please use alpha ritual', const []);
      expect(runtime.skillManager.findSkill('AlphaHost'), same(original));
      expect(created, 1);
    },
  );

  test(
    'surface lexical evidence without explicit surface policy stays cold',
    () async {
      var created = 0;
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'surface',
            skillName: 'FreeformSurface',
            terms: const <String>['generate game'],
            factory: (_) {
              created++;
              return _RecordingHostSkill('FreeformSurface');
            },
          ),
        );
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();

      await runtime.init(enabledSkillIds: const <String>{'surface'});
      final result = await runtime.chat(
        "don't generate game; explain the rules only",
        const [],
      );

      expect(result.isSuccess, isTrue);
      expect(created, 0);
      expect(runtime.skillManager.skills, isEmpty);
    },
  );

  test(
    'denied surface routing still activates an unrelated selected host',
    () async {
      var surfaceCreated = 0;
      var rulesCreated = 0;
      SkillCatalog.all
        ..clear()
        ..addAll(<SkillSpec>[
          _spec(
            id: 'surface',
            skillName: 'FreeformSurface',
            terms: const <String>['generate game'],
            factory: (_) {
              surfaceCreated++;
              return _RecordingHostSkill('FreeformSurface');
            },
          ),
          _spec(
            id: 'rules',
            skillName: 'RulesHost',
            terms: const <String>['rules only'],
            positiveExamples: const <String>[
              "don't generate game; use rules only",
            ],
            factory: (_) {
              rulesCreated++;
              return _RecordingHostSkill('RulesHost');
            },
          ),
        ]);
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();

      await runtime.init(enabledSkillIds: const <String>{'surface', 'rules'});
      final result = await runtime.chat(
        "don't generate game; use rules only",
        const [],
      );

      expect(result.isSuccess, isTrue);
      expect(surfaceCreated, 0);
      expect(rulesCreated, 1);
      expect(runtime.skillManager.skills.single.skillName, 'RulesHost');
    },
  );

  test(
    'an explicit edit exposes and executes only the bound edit method',
    () async {
      final skill = _SurfaceInteractionHostSkill();
      SkillCatalog.all
        ..clear()
        ..add(
          SkillSpec(
            id: 'surface',
            name: 'surface',
            description: 'surface',
            icon: Icons.layers_rounded,
            color: Colors.blue,
            category: SkillCategory.expression,
            factory: (_) => skill,
            hostRouting: HostSkillRoutingManifest(
              skillName: 'FreeformSurface',
              summary: 'Edit the visible surface.',
              methods: const <String>[
                'showSurface',
                'editSurface',
                'listSurfaces',
                'reopenSurface',
                'revertSurface',
              ],
              terms: const <String>['再加一行'],
            ),
          ),
        );
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
      final llm = _ActionLlm('''
{"reply":"edited","actions":[{"type":"skill.call","tool":"skill_freeformsurface_editsurface","args":{"surfaceId":"existing-surface","html":"<main>edited</main>"}}]}
''');
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();

      await runtime.init(enabledSkillIds: const <String>{'surface'});
      final result = await runtime.chat('再加一行文字', const []);

      expect(result.isSuccess, isTrue);
      expect(skill.calls['editSurface'], 1);
      expect(skill.calls['showSurface'] ?? 0, 0);
      final systemPrompt = llm.lastMessages
          .where((message) => message.role == 'system')
          .map((message) => message.content)
          .join('\n');
      expect(systemPrompt, contains('skill_freeformsurface_editsurface'));
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

  test('a Persona reply does not activate a routed host skill', () async {
    var created = 0;
    SkillCatalog.all
      ..clear()
      ..add(
        _spec(
          id: 'alpha',
          skillName: 'AlphaHost',
          terms: const <String>['alpha ritual'],
          factory: (_) {
            created++;
            return _RecordingHostSkill('AlphaHost');
          },
        ),
      );
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: _NoActionLlm(),
    );
    addTearDown(runtime.dispose);

    await runtime.init(enabledSkillIds: const <String>{'alpha'});
    final result = await runtime.chat('please use alpha ritual', const []);

    expect(result.isSuccess, isTrue);
    expect(created, 0);
    expect(runtime.skillManager.skills, isEmpty);
  });

  test(
    'AppControl policy bypasses Persona and exposes the selected Host tool',
    () async {
      var created = 0;
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'app_control',
            skillName: 'AppControl',
            terms: const <String>['打开设置页面'],
            methodName: 'execute',
            factory: (_) {
              created++;
              return _RecordingHostSkill('AppControl', methodName: 'execute');
            },
          ),
        );
      final llm = _ActionLlm('''
{"reply":"正在打开设置","actions":[{"type":"skill.call","tool":"skill_appcontrol_execute","args":{"page":"settings"}}]}
''');
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(runtime.dispose);

      await runtime.init(enabledSkillIds: const <String>{'app_control'});
      final result = await runtime.chat('打开设置页面', const []);

      expect(result.isSuccess, isTrue);
      expect(created, 1);
      expect(runtime.skillManager.skills.single.skillName, 'AppControl');
      expect(
        llm.lastMessages.map((message) => message.content).join('\n'),
        contains('skill_appcontrol_execute'),
      );
    },
  );

  test(
    'ordinary editorial request bypasses Persona and invokes Creator',
    () async {
      var created = 0;
      SkillCatalog.all
        ..clear()
        ..add(
          _spec(
            id: 'creator',
            skillName: 'Creator',
            terms: const <String>['developer-only-creator-token'],
            methodName: 'prepareEditorialWriting',
            factory: (_) {
              created++;
              return _RecordingHostSkill(
                'Creator',
                methodName: 'prepareEditorialWriting',
              );
            },
          ),
        );
      final llm = _ActionLlm('''
{"reply":"我来准备文章","actions":[{"type":"skill.call","tool":"skill_creator_prepareeditorialwriting","args":{"title":"AI Agent 的下一步","outline":"一、现状\n二、趋势","body":"AI Agent 正在从对话工具走向行动系统。"}}]}
''');
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(runtime.dispose);

      await runtime.init(enabledSkillIds: const <String>{'creator'});
      final result = await runtime.chat('帮我写一篇关于 AI Agent 的文章', const []);

      expect(result.isSuccess, isTrue);
      expect(created, 1);
      expect(runtime.skillManager.skills.single.skillName, 'Creator');
      expect(
        llm.lastMessages.map((message) => message.content).join('\n'),
        contains('skill_creator_prepareeditorialwriting'),
      );
    },
  );

  test(
    'reload reuses enabled instances and re-enabled skills stay cold',
    () async {
      var created = 0;
      SkillCatalog.all
        ..clear()
        ..addAll(<SkillSpec>[
          _spec(
            id: 'alpha',
            skillName: 'AlphaHost',
            terms: const <String>['alpha ritual'],
            factory: (_) {
              created++;
              return _RecordingHostSkill('AlphaHost');
            },
          ),
          _spec(
            id: 'beta',
            skillName: 'BetaHost',
            terms: const <String>['beta ritual'],
            factory: (_) => _RecordingHostSkill('BetaHost'),
          ),
        ]);
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _NoActionLlm(),
      );
      addTearDown(runtime.dispose);
      _useDirectCloudMode();
      await runtime.init(enabledSkillIds: const <String>{'alpha', 'beta'});

      await runtime.chat('please use alpha ritual', const []);
      final first = runtime.skillManager.findSkill('AlphaHost');
      expect(first, isNotNull);
      expect(created, 1);

      await runtime.reloadSkills(const <String>{'alpha', 'beta'});
      expect(runtime.skillManager.findSkill('AlphaHost'), same(first));
      await runtime.chat('please use alpha ritual again', const []);
      expect(created, 1);

      await runtime.reloadSkills(const <String>{'beta'});
      expect(runtime.skillManager.findSkill('AlphaHost'), isNull);
      await runtime.reloadSkills(const <String>{'alpha', 'beta'});
      expect(runtime.skillManager.findSkill('AlphaHost'), isNull);
      await runtime.chat('please use alpha ritual once more', const []);
      expect(created, 2);
    },
  );
}

void _useDirectCloudMode() {
  final mode = appServices.put(MaasoAgentModeService());
  mode.pipelineMode.value = AgentPipelineMode.directCloud;
}

SkillSpec _spec({
  required String id,
  required String skillName,
  required List<String> terms,
  String methodName = 'run',
  List<String> positiveExamples = const <String>[],
  required AgentSkill Function(String agentId) factory,
  bool Function()? availability,
}) => SkillSpec(
  id: id,
  name: id,
  description: id,
  icon: Icons.extension_rounded,
  color: Colors.blue,
  category: SkillCategory.knowledge,
  factory: factory,
  availability: availability,
  hostRouting: HostSkillRoutingManifest(
    skillName: skillName,
    summary: '$skillName test host.',
    methods: <String>[methodName],
    nativeMethods: <String>[methodName],
    terms: terms,
    positiveExamples: positiveExamples,
  ),
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

class _RecordingHostSkill extends AgentSkill {
  _RecordingHostSkill(this._name, {this.methodName = 'run'});

  final String _name;
  final String methodName;

  @override
  String get skillName => _name;

  @override
  String get description => 'Recording host $_name';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    methodName: (_) =>
        jsonEncode(<String, Object?>{'status': 'ok', 'skill': _name}),
  };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    methodName: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  };
}

class _SurfaceInteractionHostSkill extends AgentSkill {
  final Map<String, int> calls = <String, int>{};

  @override
  String get skillName => 'FreeformSurface';

  @override
  String get description => 'surface';

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
}

class _ActionLlm implements LLMClient {
  _ActionLlm(this.response);

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
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode(<String, Object?>{
        'delta': await chat(messages, timeout: timeout),
      }),
    );
  }
}

class _NoActionLlm implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"ok","actions":[]}';

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}

final class _ToggleSkillSnapshotResolver
    implements AppCapabilitySnapshotResolver {
  _ToggleSkillSnapshotResolver(this.skillId);

  final String skillId;
  bool enabled = true;

  @override
  AppCapabilitySnapshotDraft resolve(AppCapabilitySnapshotContext context) =>
      AppCapabilitySnapshotDraft(
        context: context,
        decisions: <AppCapabilityDecision>[
          if (enabled)
            AppCapabilityDecision.available(AppCapabilityKey.skill(skillId)),
        ],
      );
}
