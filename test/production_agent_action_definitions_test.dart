import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_schema_validator.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/action/production_agent_action_definitions.dart';

void main() {
  test('fixed production actions are metadata-only and schema-valid', () {
    final catalog = ProductionActionDefinitionCatalog.intrinsics();
    registerProductionAgentActionDefinitions(catalog);

    expect(
      catalog.definitions.map((entry) => entry.definition.id),
      containsAll(<String>[
        'voice.fallback',
        'avatar.auto_react',
        'emotion.set',
        'voice.speak',
        'surface.show',
        'surface.call',
        'avatar.motion',
        'avatar.act',
        'avatar.react',
      ]),
    );
    expect(catalog.find('world.intent'), isNull);

    const validator = ActionSchemaValidator();
    for (final production in catalog.definitions) {
      final definition = production.definition;
      expect(
        validator
            .validate(schema: definition.inputSchema, value: null)
            .schemaValid,
        isTrue,
        reason: '${definition.id} input schema must compile',
      );
      expect(
        validator
            .validate(schema: definition.outputSchema, value: null)
            .schemaValid,
        isTrue,
        reason: '${definition.id} output schema must compile',
      );
    }
  });

  test('fixed definitions reject malformed bounded arguments', () {
    final catalog = ProductionActionDefinitionCatalog.intrinsics();
    registerProductionAgentActionDefinitions(catalog);
    const validator = ActionSchemaValidator();

    final voice = catalog.find('voice.speak')!.definition;
    expect(
      validator
          .validate(
            schema: voice.inputSchema,
            value: const <String, Object?>{'text': ''},
          )
          .isValid,
      isFalse,
    );

    final surfaceCall = catalog.find('surface.call')!.definition;
    expect(
      validator
          .validate(
            schema: surfaceCall.inputSchema,
            value: const <String, Object?>{
              'action': '',
              'data': <String, Object?>{},
            },
          )
          .isValid,
      isFalse,
    );
  });
}
