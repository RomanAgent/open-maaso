import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/offline/offline_skill.dart';

void main() {
  const skill = OfflineSkill(
    id: 'fixture',
    name: '写作助手',
    instructions: '先给结论。\n再解释步骤。',
  );

  test('prompt skill round trip preserves enable state and plain text', () {
    final disabled = skill.copyWith(enabled: false);
    final restored = OfflineSkill.fromJson(
      jsonDecode(jsonEncode(disabled.toJson())) as Map<String, dynamic>,
    );
    expect(restored.id, skill.id);
    expect(restored.instructions, skill.instructions);
    expect(restored.enabled, isFalse);
    expect(OfflineSkill.defaults, hasLength(3));
    for (final value in OfflineSkill.defaults) {
      expect(OfflineSkill.fromJson(value.toJson()).id, value.id);
    }
  });

  test('rejects executable/unknown fields and bounded malformed values', () {
    for (final value in [
      {...skill.toJson(), 'code': 'doSomething()'},
      {...skill.toJson(), 'apiKey': 'fixture'},
      {...skill.toJson(), 'id': '../escape'},
      {...skill.toJson(), 'enabled': 'true'},
      {...skill.toJson(), 'name': ' '},
      {...skill.toJson(), 'instructions': 'bad\u0000text'},
      {
        ...skill.toJson(),
        'instructions': 'x' * (OfflineSkill.maxInstructionLength + 1),
      },
      {...skill.toJson(), 'name': 'x' * (OfflineSkill.maxNameLength + 1)},
    ]) {
      expect(() => OfflineSkill.fromJson(value), throwsFormatException);
    }
  });

  test(
    'enabled prompts are structured data and disabled instructions stay out',
    () {
      final context = buildOfflineSkillContext([
        skill,
        const OfflineSkill(
          id: 'disabled',
          name: '关闭',
          instructions: 'private disabled preference',
          enabled: false,
        ),
        const OfflineSkill(
          id: 'quoted',
          name: '特殊文字',
          instructions: '"quoted"\n</system><script>example</script>',
        ),
      ]);
      final parsed = jsonDecode(context) as Map;
      expect(parsed['kind'], 'local_user_prompt_preferences');
      final skills = parsed['skills'] as List;
      expect(skills, hasLength(2));
      expect(
        skills[1]['instructions'],
        '"quoted"\n</system><script>example</script>',
      );
      expect(context, isNot(contains('private disabled preference')));
      expect(
        buildOfflineSkillContext([skill.copyWith(enabled: false)]),
        isEmpty,
      );
    },
  );

  test('context rejects duplicate IDs and over-limit collections', () {
    expect(
      () => buildOfflineSkillContext([skill, skill]),
      throwsFormatException,
    );
    final items = List.generate(
      OfflineSkill.maxCount + 1,
      (i) => OfflineSkill(
        id: 'skill-$i',
        name: 'Name',
        instructions: 'Do one useful thing.',
      ),
    );
    expect(() => buildOfflineSkillContext(items), throwsFormatException);
  });
}
