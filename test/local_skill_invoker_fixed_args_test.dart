import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';

/// Minimal skill that echoes whatever JSON args it receives, so we can assert
/// exactly what the invoker passed to the handler.
class _EchoSkill extends AgentSkill {
  @override
  String get skillName => 'Echo';
  @override
  String get description => 'echo';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'echo': (args) => jsonEncode({'got': jsonDecode(args[0] as String)}),
  };
}

LocalSkillManifest _manifest({
  Map<String, dynamic> fixedArgs = const {},
  LocalSkillRisk risk = LocalSkillRisk.read,
}) => LocalSkillManifest(
  id: 'echo',
  skillName: 'Echo',
  method: 'echo',
  summary: 'echo',
  tags: const ['echo'],
  argsSchema: const {},
  fixedArgs: fixedArgs,
  risk: risk,
);

void main() {
  late SkillManager manager;
  setUp(() => manager = SkillManager()..registerSkill(_EchoSkill()));

  test(
    'fixedArgs are merged into planner args before the handler runs',
    () async {
      final result = await LocalSkillInvoker(skillManager: manager).invoke(
        _manifest(fixedArgs: {'page': 'settings'}),
        const {}, // planner sent nothing
      );

      expect(result.status, LocalSkillResultStatus.ok);
      expect(jsonDecode(result.output)['got'], {'page': 'settings'});
    },
  );

  test('fixed host args win over planner args on key collision', () async {
    final result = await LocalSkillInvoker(skillManager: manager).invoke(
      _manifest(fixedArgs: {'page': 'settings'}),
      const {'page': 'skills'},
    );

    expect(jsonDecode(result.output)['got'], {'page': 'settings'});
  });

  test('empty fixedArgs leaves args unchanged', () async {
    final result = await LocalSkillInvoker(
      skillManager: manager,
    ).invoke(_manifest(), const {'a': 1});

    expect(jsonDecode(result.output)['got'], {'a': 1});
  });

  test(
    'confirmation payload contains merged fixedArgs when confirmation is required',
    () async {
      final result = await LocalSkillInvoker(skillManager: manager).invoke(
        _manifest(
          fixedArgs: {'page': 'settings'},
          risk: LocalSkillRisk.sideEffect,
        ),
        const {}, // planner sent nothing
        confirmed: false,
      );

      expect(result.status, LocalSkillResultStatus.commitRequired);
      expect(jsonDecode(result.output)['args'], {'page': 'settings'});
    },
  );

  test(
    'confirmation shows the host target instead of a planner override',
    () async {
      final result = await LocalSkillInvoker(skillManager: manager).invoke(
        _manifest(
          fixedArgs: {'page': 'settings'},
          risk: LocalSkillRisk.sideEffect,
        ),
        const {'page': 'skills'},
        confirmed: false,
      );

      expect(result.status, LocalSkillResultStatus.commitRequired);
      expect(jsonDecode(result.output)['args'], {'page': 'settings'});
    },
  );
}
