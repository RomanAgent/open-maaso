import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  test('10k no-schema skills do not get rescanned by indexed reads', () async {
    final counters = _SharedCounters();
    final manager = SkillManager();
    late _CountingSkill last;
    for (var index = 0; index < 10000; index++) {
      last = _CountingSkill(
        name: 'Legacy$index',
        counters: counters,
        hasMethod: true,
      );
      manager.registerSkill(last);
    }
    final lastTool = SkillManager.nativeToolName(last, 'run');
    counters.enabled = true;

    expect(manager.hasNativeTools, isFalse);
    expect(manager.containsSkill('Legacy9999'), isTrue);
    expect(manager.findSkill('Legacy9999'), same(last));
    expect(manager.skillOwnerForTool(lastTool), same(last));
    expect(manager.methodNameForTool(lastTool), 'run');
    expect(manager.toNativeTools(), isEmpty);
    await expectLater(
      manager.invokeTool('skill_missing_run', const {}),
      throwsStateError,
    );

    expect(counters.skillNameReads, 0);
    expect(counters.methodMapReads, 0);
    expect(counters.schemaMapReads, 0);
    expect(counters.handlerCalls, 0);
  });

  test(
    'invoking the last of 10k skills touches only its handler map',
    () async {
      final counters = _SharedCounters();
      final manager = SkillManager();
      for (var index = 0; index < 9999; index++) {
        manager.registerSkill(
          _CountingSkill(name: 'Idle$index', counters: counters),
        );
      }
      final target = _CountingSkill(
        name: 'Target',
        counters: counters,
        hasMethod: true,
        hasSchema: true,
      );
      manager.registerSkill(target);
      final targetTool = SkillManager.nativeToolName(target, 'run');
      counters.enabled = true;

      final result = jsonDecode(await manager.invokeTool(targetTool, const {}));

      expect(result, <String, dynamic>{'status': 'ok'});
      expect(counters.skillNameReads, 0);
      expect(counters.schemaMapReads, 0);
      expect(counters.methodMapReads, 1);
      expect(counters.handlerCalls, 1);
    },
  );
}

class _SharedCounters {
  bool enabled = false;
  int skillNameReads = 0;
  int methodMapReads = 0;
  int schemaMapReads = 0;
  int handlerCalls = 0;
}

class _CountingSkill extends AgentSkill {
  _CountingSkill({
    required this.name,
    required this.counters,
    this.hasMethod = false,
    this.hasSchema = false,
  });

  final String name;
  final _SharedCounters counters;
  final bool hasMethod;
  final bool hasSchema;

  @override
  String get skillName {
    if (counters.enabled) counters.skillNameReads++;
    return name;
  }

  @override
  String get description => 'Counting skill';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods {
    if (counters.enabled) counters.methodMapReads++;
    if (!hasMethod) return const <String, dynamic Function(List<dynamic>)>{};
    return <String, dynamic Function(List<dynamic>)>{
      'run': (_) {
        if (counters.enabled) counters.handlerCalls++;
        return jsonEncode(const <String, dynamic>{'status': 'ok'});
      },
    };
  }

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas {
    if (counters.enabled) counters.schemaMapReads++;
    if (!hasSchema) return null;
    return const <String, Map<String, dynamic>>{
      'run': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    };
  }
}
