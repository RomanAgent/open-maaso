import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_skill_action_metadata.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

void main() {
  test('only source-reviewed exact skill methods are read-only', () {
    const schema = <String, dynamic>{'type': 'object'};

    for (final entry in <(String, String)>[
      ('AppNavigate', 'listPages'),
      ('AppControl', 'listCapabilities'),
    ]) {
      final metadata = productionSkillActionContractMetadata(
        _NamedSkill(entry.$1),
        entry.$2,
        schema,
      );
      expect(metadata, isNotNull, reason: '${entry.$1}.${entry.$2}');
      expect(metadata!.risk, ActionRisk.readOnly);
      expect(
        metadata.enforcementEligibility,
        ActionEnforcementEligibility.readOnly,
      );
      expect(metadata.outputSchema, isNotEmpty);
    }

    expect(
      productionSkillActionContractMetadata(
        _NamedSkill('AppNavigate'),
        'openPage',
        schema,
      ),
      isNull,
    );
    for (final retired in <(String, String)>[
      ('Calc', 'eval'),
      ('RealWeather', 'getWeather'),
      ('TripPlan', 'planTrip'),
      ('SetTheme', 'getTheme'),
      ('SetTheme', 'setTheme'),
    ]) {
      expect(
        productionSkillActionContractMetadata(
          _NamedSkill(retired.$1),
          retired.$2,
          schema,
        ),
        isNull,
        reason: '${retired.$1}.${retired.$2} is retired',
      );
    }
    expect(
      productionSkillActionContractMetadata(
        _NamedSkill('LooksReadOnly'),
        'listEverything',
        schema,
      ),
      isNull,
    );
  });

  test(
    'allowlisted schemas accept each production handler success shape',
    () async {
      const validator = ActionSchemaValidator();
      final cases = <(AgentSkill, String, Map<String, dynamic>)>[
        (AppNavigateSkill(), 'listPages', const <String, dynamic>{}),
        (AppControlSkill(), 'listCapabilities', const <String, dynamic>{}),
      ];

      for (final entry in cases) {
        final skill = entry.$1;
        final method = entry.$2;
        final metadata = productionSkillActionContractMetadata(
          skill,
          method,
          skill.nativeToolSchemas![method]!,
        )!;
        final raw = await Future<Object?>.sync(
          () => skill.methods[method]!([jsonEncode(entry.$3)]),
        );
        final output = jsonDecode(raw.toString());

        expect(
          validator
              .validate(schema: metadata.outputSchema, value: output)
              .isValid,
          isTrue,
          reason: '${skill.skillName}.$method returned $output',
        );
      }
    },
  );

  test('allowlisted schemas reject malformed but valid JSON success data', () {
    const validator = ActionSchemaValidator();
    final cases = <(String, String, Object?)>[
      (
        'AppNavigate',
        'listPages',
        <String, Object?>{'pages': 'private-sentinel'},
      ),
      (
        'AppNavigate',
        'listPages',
        <String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'id': 'home'},
          ],
        },
      ),
      (
        'AppControl',
        'listCapabilities',
        <String, Object?>{'pages': <Object?>[], 'pageActionProtocol': 7},
      ),
    ];

    for (final entry in cases) {
      final metadata = productionSkillActionContractMetadata(
        _NamedSkill(entry.$1),
        entry.$2,
        const <String, dynamic>{'type': 'object'},
      )!;

      expect(
        validator
            .validate(schema: metadata.outputSchema, value: entry.$3)
            .isValid,
        isFalse,
        reason: '${entry.$1}.${entry.$2}',
      );
    }
  });
}

final class _NamedSkill extends AgentSkill {
  _NamedSkill(this.name);

  final String name;

  @override
  String get skillName => name;

  @override
  String get description => 'metadata test';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => const {};
}
