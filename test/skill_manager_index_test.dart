import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  group('SkillManager indexes', () {
    test('skills snapshots are cached and stay immutable by generation', () {
      final first = _ProbeSkill(name: 'First');
      final second = _ProbeSkill(name: 'Second');
      final manager = SkillManager()..registerSkill(first);

      final initial = manager.skills;

      expect(identical(initial, manager.skills), isTrue);
      expect(() => initial.add(second), throwsUnsupportedError);

      manager.registerSkill(second);

      final refreshed = manager.skills;
      expect(identical(initial, refreshed), isFalse);
      expect(initial, <AgentSkill>[first]);
      expect(refreshed, <AgentSkill>[first, second]);
      expect(identical(refreshed, manager.skills), isTrue);
    });

    test('name and method ownership indexes keep first-match semantics', () {
      final legacyOwner = _ProbeSkill(
        name: 'Shared',
        methodNames: const <String>['run'],
        result: 'legacy',
      );
      final nativeOwner = _ProbeSkill(
        name: 'Shared',
        methodNames: const <String>['run'],
        schemaMethods: const <String>['run'],
        result: 'native',
      );
      final manager = SkillManager()
        ..registerSkill(legacyOwner)
        ..registerSkill(nativeOwner);
      final tool = SkillManager.nativeToolName(legacyOwner, 'run');

      expect(manager.findSkill('Shared'), same(legacyOwner));
      expect(manager.containsSkill('Shared'), isTrue);
      expect(manager.containsSkill('shared'), isFalse);
      expect(manager.skillOwnerForTool(tool), same(legacyOwner));
      expect(manager.methodNameForTool(tool), 'run');
      expect(manager.hasNativeTools, isTrue);
    });

    test(
      'native invocation keeps schema-first match separate from owner',
      () async {
        final legacyOwner = _ProbeSkill(
          name: 'Shared',
          methodNames: const <String>['run'],
          result: 'legacy',
        );
        final nativeOwner = _ProbeSkill(
          name: 'Shared',
          methodNames: const <String>['run'],
          schemaMethods: const <String>['run'],
          result: 'native',
        );
        final manager = SkillManager()
          ..registerSkill(legacyOwner)
          ..registerSkill(nativeOwner);
        final tool = SkillManager.nativeToolName(legacyOwner, 'run');

        final result = jsonDecode(await manager.invokeTool(tool, const {}));

        expect(result, <String, dynamic>{'result': 'native'});
        expect(legacyOwner.handlerCalls, 0);
        expect(nativeOwner.handlerCalls, 1);
      },
    );

    test(
      'native tool output preserves duplicate names and registration order',
      () async {
        final first = _ProbeSkill(
          name: 'A.B',
          methodNames: const <String>['run'],
          schemaMethods: const <String>['run'],
          result: 'first',
        );
        final second = _ProbeSkill(
          name: 'A/B',
          methodNames: const <String>['run'],
          schemaMethods: const <String>['run'],
          result: 'second',
        );
        final manager = SkillManager()
          ..registerSkill(first)
          ..registerSkill(second);

        final tools = manager.toNativeTools();
        final names = tools.map(_openAiToolName).toList(growable: false);

        expect(names, <String>['skill_a_b_run', 'skill_a_b_run']);
        expect(
          jsonDecode(await manager.invokeTool(names.first, const {})),
          <String, dynamic>{'result': 'first'},
        );
        expect(first.handlerCalls, 1);
        expect(second.handlerCalls, 0);
      },
    );

    test('64 character truncation collisions keep ordered declarations', () {
      final sharedPrefix = List<String>.filled(80, 'x').join();
      final first = _ProbeSkill(
        name: '${sharedPrefix}a',
        methodNames: const <String>['run'],
        schemaMethods: const <String>['run'],
      );
      final second = _ProbeSkill(
        name: '${sharedPrefix}b',
        methodNames: const <String>['run'],
        schemaMethods: const <String>['run'],
      );
      final manager = SkillManager()
        ..registerSkill(first)
        ..registerSkill(second);

      final names = manager
          .toNativeTools()
          .map(_openAiToolName)
          .toList(growable: false);

      expect(names, hasLength(2));
      expect(names.first, hasLength(64));
      expect(names.last, names.first);
    });

    test('handler values are resolved at invocation time', () async {
      final skill = _ProbeSkill(
        name: 'MutableHandler',
        methodNames: const <String>['run'],
        schemaMethods: const <String>['run'],
        result: 'before',
      );
      final manager = SkillManager()..registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'run');
      skill.result = 'after';

      expect(
        jsonDecode(await manager.invokeTool(tool, const {})),
        <String, dynamic>{'result': 'after'},
      );
    });

    test(
      'unknown and missing handlers preserve exact StateError messages',
      () async {
        final missing = _ProbeSkill(
          name: 'Missing',
          schemaMethods: const <String>['ghost'],
        );
        final manager = SkillManager()..registerSkill(missing);
        final missingTool = SkillManager.nativeToolName(missing, 'ghost');

        await expectLater(
          manager.invokeTool(missingTool, const {}),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Tool $missingTool found, but skill "Missing" has no '
                  'method "ghost" in its methods map',
            ),
          ),
        );
        await expectLater(
          manager.invokeTool('skill_unknown_run', const {}),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Unknown tool: skill_unknown_run',
            ),
          ),
        );
      },
    );

    test('registering later skills incrementally updates every index', () {
      final manager = SkillManager();
      final skill = _ProbeSkill(
        name: 'Later',
        methodNames: const <String>['run'],
        schemaMethods: const <String>['run'],
      );

      expect(manager.hasNativeTools, isFalse);
      expect(manager.findSkill('Later'), isNull);
      expect(manager.toNativeTools(), isEmpty);

      manager.registerSkill(skill);
      final tool = SkillManager.nativeToolName(skill, 'run');

      expect(manager.hasNativeTools, isTrue);
      expect(manager.findSkill('Later'), same(skill));
      expect(manager.skillOwnerForTool(tool), same(skill));
      expect(manager.methodNameForTool(tool), 'run');
      expect(manager.toNativeTools().map(_openAiToolName), <String>[tool]);
    });
  });
}

String _openAiToolName(Map<String, dynamic> tool) =>
    (tool['function'] as Map<String, dynamic>)['name']! as String;

class _ProbeSkill extends AgentSkill {
  _ProbeSkill({
    required this.name,
    this.methodNames = const <String>[],
    this.schemaMethods = const <String>[],
    this.result = 'ok',
  });

  final String name;
  final List<String> methodNames;
  final List<String> schemaMethods;
  String result;
  int handlerCalls = 0;

  @override
  String get skillName => name;

  @override
  String get description => 'Probe $name';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    for (final method in methodNames)
      method: (_) {
        handlerCalls++;
        return jsonEncode(<String, dynamic>{'result': result});
      },
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    for (final method in schemaMethods)
      method: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
  };
}
