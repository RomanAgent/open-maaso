import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() => appServices.reset());

  SkillManager manager(
    _SearchProbe skill, {
    SkillHandlerPresentation? presentation,
    bool requirePinnedContract = false,
  }) => SkillManager(
    useAppServicesUsageFallback: false,
    useAppServicesActionContractFallback: false,
    requirePinnedActionContract: requirePinnedContract,
    beginHandlerPresentation: presentation,
  )..registerSkill(skill);

  for (final method in ['webSearch', 'imageSearch']) {
    test(
      'native $method begins before its handler and cleans up once',
      () async {
        final events = <String>[];
        final skill = _SearchProbe(events);
        final owner = manager(
          skill,
          presentation: (observedSkill, observedMethod) {
            expect(observedSkill, same(skill));
            expect(observedMethod, method);
            events.add('begin:$observedMethod');
            return () => events.add('end:$observedMethod');
          },
        );

        expect(
          await owner.invokeTool(
            SkillManager.nativeToolName(skill, method),
            _args,
          ),
          _output,
        );
        expect(events, ['begin:$method', 'handler:$method', 'end:$method']);
      },
    );
  }

  test('presentation stays owned until a pending handler returns', () async {
    final events = <String>[];
    final pending = Completer<String>();
    final skill = _SearchProbe(events)..pending = pending.future;
    final owner = manager(
      skill,
      presentation: (_, method) {
        events.add('begin:$method');
        return () => events.add('end:$method');
      },
    );

    final request = owner.invokeTool('skill_websearch_websearch', _args);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['begin:webSearch', 'handler:webSearch']);
    pending.complete(_output);
    expect(events, ['begin:webSearch', 'handler:webSearch']);
    expect(await request, _output);
    expect(events, ['begin:webSearch', 'handler:webSearch', 'end:webSearch']);
  });

  for (final cleanupFails in [false, true]) {
    test('handler failure is preserved and cleanup runs once '
        '(cleanup fails: $cleanupFails)', () async {
      final events = <String>[];
      final failure = StateError('original handler failure');
      final skill = _SearchProbe(events)..failure = failure;
      final owner = manager(
        skill,
        presentation: (_, method) {
          events.add('begin:$method');
          return () {
            events.add('end:$method');
            if (cleanupFails) throw StateError('cleanup failed');
          };
        },
      );

      await expectLater(
        owner.invokeTool('skill_websearch_websearch', _args),
        throwsA(same(failure)),
      );
      expect(events, ['begin:webSearch', 'handler:webSearch', 'end:webSearch']);
    });
  }

  test(
    'a failed begin cannot prevent or replace a successful result',
    () async {
      final events = <String>[];
      final owner = manager(
        _SearchProbe(events),
        presentation: (_, method) {
          events.add('begin:$method');
          throw StateError('renderer unavailable');
        },
      );

      expect(
        await owner.invokeTool('skill_websearch_websearch', _args),
        _output,
      );
      expect(events, ['begin:webSearch', 'handler:webSearch']);
    },
  );

  test('a failed cleanup cannot replace a successful result', () async {
    final events = <String>[];
    final owner = manager(
      _SearchProbe(events),
      presentation: (_, method) {
        events.add('begin:$method');
        return () {
          events.add('end:$method');
          throw StateError('renderer detached');
        };
      },
    );

    expect(await owner.invokeTool('skill_websearch_websearch', _args), _output);
    expect(events, ['begin:webSearch', 'handler:webSearch', 'end:webSearch']);
  });

  test(
    'discovery and invalid native arguments never begin presentation',
    () async {
      final events = <String>[];
      final owner = manager(
        _SearchProbe(events),
        presentation: (_, method) {
          events.add('begin:$method');
          return () => events.add('end:$method');
        },
      );
      owner.toNativeTools(locale: AppLocale.en);
      owner.validateToolArguments('skill_websearch_websearch', _args);
      await expectLater(
        owner.invokeTool('skill_websearch_websearch', {}),
        throwsA(isA<InvalidToolArgumentsException>()),
      );
      expect(events, isEmpty);
    },
  );

  test('a contract rejection never begins presentation or handler', () async {
    final events = <String>[];
    final owner = manager(
      _SearchProbe(events),
      requirePinnedContract: true,
      presentation: (_, method) {
        events.add('begin:$method');
        return () => events.add('end:$method');
      },
    );

    final result = await owner.invokeToolWithContract(
      'skill_websearch_websearch',
      _args,
    );
    expect(result.isRejected, isTrue);
    expect(
      jsonDecode(result.output as String)['code'],
      'contract_dependency_unavailable',
    );
    expect(events, isEmpty);
  });

  test('structured grants present only the single admitted dispatch', () async {
    final events = <String>[];
    final skill = _SearchProbe(events);
    final owner = manager(
      skill,
      presentation: (_, method) {
        events.add('begin:$method');
        return () => events.add('end:$method');
      },
    );
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: [
        SkillSpec(
          id: 'web_search',
          name: 'Search',
          description: 'Read a search fixture',
          icon: Icons.search,
          color: Colors.blue,
          category: SkillCategory.core,
          isCore: true,
          factory: (_) => skill,
          hostRouting: HostSkillRoutingManifest(
            skillName: 'WebSearch',
            summary: 'Read a search fixture',
            methods: ['webSearch', 'imageSearch'],
            nativeMethods: ['webSearch', 'imageSearch'],
          ),
        ),
      ],
    );
    addTearDown(registry.invalidate);
    final grant = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: registry.descriptors(),
        maxSkills: 1,
        promptBudget: 4096,
      ),
    );
    final envelope = AgentActionEnvelope.parse(
      jsonEncode({
        'reply': '',
        'actions': [
          {
            'type': 'skill.call',
            'tool': 'skill_websearch_websearch',
            'args': _args,
          },
        ],
      }),
    );
    AgentActionExecutor executor(ExecutableHostGrant supplied) =>
        AgentActionExecutor(
          agentId: 'self',
          skillManager: owner,
          locale: AppLocale.en,
          executableHostGrant: supplied,
          useAppServicesActionContractFallback: false,
        );

    expect(
      (await executor(ExecutableHostGrant.none).execute(envelope)).ok,
      isFalse,
    );
    expect(events, isEmpty);
    expect((await executor(grant).execute(envelope)).ok, isTrue);
    expect(events, ['begin:webSearch', 'handler:webSearch', 'end:webSearch']);
    events.clear();
    registry.invalidate();
    expect((await executor(grant).execute(envelope)).ok, isFalse);
    expect(events, isEmpty);
  });

  test(
    'local manifests present once after validation and confirmation',
    () async {
      final events = <String>[];
      final owner = manager(
        _SearchProbe(events),
        presentation: (_, method) {
          events.add('begin:$method');
          return () => events.add('end:$method');
        },
      );
      final invoker = LocalSkillInvoker(skillManager: owner);
      const read = LocalSkillManifest(
        id: 'search_fixture',
        skillName: 'WebSearch',
        method: 'webSearch',
        summary: 'Read a search fixture',
        tags: ['search'],
        risk: LocalSkillRisk.read,
        argsSchema: _schema,
      );
      const write = LocalSkillManifest(
        id: 'search_fixture',
        skillName: 'WebSearch',
        method: 'webSearch',
        summary: 'A confirmation fixture',
        tags: ['search'],
        risk: LocalSkillRisk.sideEffect,
        argsSchema: _schema,
      );

      expect(
        (await invoker.invoke(read, {})).status,
        LocalSkillResultStatus.invalidArguments,
      );
      expect(
        (await invoker.invoke(write, _args)).status,
        LocalSkillResultStatus.commitRequired,
      );
      expect(events, isEmpty);
      expect(
        (await invoker.invoke(read, _args)).status,
        LocalSkillResultStatus.ok,
      );
      expect(events, ['begin:webSearch', 'handler:webSearch', 'end:webSearch']);
    },
  );

  test('the optional observer may decline non-search skills', () async {
    final events = <String>[];
    final skill = _SearchProbe(events, name: 'OrdinaryProbe');
    final owner = manager(
      skill,
      presentation: (observedSkill, method) {
        if (observedSkill.skillName != 'WebSearch') return null;
        events.add('begin:$method');
        return () => events.add('end:$method');
      },
    );

    expect(
      await owner.invokeTool('skill_ordinaryprobe_websearch', _args),
      _output,
    );
    expect(events, ['handler:webSearch']);
  });

  test(
    'default managers require no presentation observer or renderer',
    () async {
      final events = <String>[];
      final owner = manager(_SearchProbe(events));

      expect(
        await owner.invokeTool('skill_websearch_websearch', _args),
        _output,
      );
      expect(
        await owner.invokeTool('skill_websearch_imagesearch', _args),
        _output,
      );
      expect(events, ['handler:webSearch', 'handler:imageSearch']);
    },
  );
}

const _args = <String, dynamic>{'query': 'a fixture query'};
const _output = '{"ok":true,"results":[]}';
const _schema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'query': {'type': 'string'},
  },
  'required': ['query'],
  'additionalProperties': false,
};

class _SearchProbe extends AgentSkill {
  _SearchProbe(this.events, {this.name = 'WebSearch'});

  final List<String> events;
  final String name;
  Object? failure;
  Future<String>? pending;

  @override
  String get skillName => name;
  @override
  String get description => 'A local search handler fixture without HTTP';
  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'webSearch': 'Return a local text search fixture without HTTP.',
    'imageSearch': 'Return a local image search fixture without HTTP.',
  };
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    for (final method in ['webSearch', 'imageSearch'])
      method: (_) {
        events.add('handler:$method');
        if (failure case final error?) throw error;
        return pending ?? _output;
      },
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'webSearch': _schema,
    'imageSearch': _schema,
  };
}
