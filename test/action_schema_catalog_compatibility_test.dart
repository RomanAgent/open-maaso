import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/action_schema_validator.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';

void main() {
  const validator = ActionSchemaValidator();

  test(
    'all constructible catalog native and structured-only schemas compile',
    () {
      final failures = <String>[];
      final executableSpecs = SkillCatalog.all
          .where((spec) => spec.factory != null)
          .toList(growable: false);
      var constructedFactories = 0;
      var nativeSchemaCount = 0;
      var structuredOnlySchemaCount = 0;

      for (final spec in executableSpecs) {
        AgentSkill skill;
        try {
          skill = spec.factory!('schema-catalog-compatibility');
          constructedFactories += 1;
        } on Object catch (error) {
          failures.add(
            'catalog:${spec.id}: factory construction failed '
            '(${error.runtimeType})',
          );
          continue;
        }

        final nativeSchemas =
            skill.nativeToolSchemas ?? const <String, Map<String, dynamic>>{};
        for (final entry in nativeSchemas.entries) {
          nativeSchemaCount += 1;
          _recordSchemaFailure(
            failures: failures,
            validator: validator,
            label: 'catalog:${spec.id}:native:${entry.key}',
            schema: entry.value,
          );
        }

        if (skill is! StructuredActionPromptSchemaProvider) continue;
        final promptSchemas = (skill as StructuredActionPromptSchemaProvider)
            .structuredActionPromptSchemas;
        for (final method in promptSchemas.methodNames) {
          if (nativeSchemas.containsKey(method)) continue;
          structuredOnlySchemaCount += 1;
          _recordSchemaFailure(
            failures: failures,
            validator: validator,
            label: 'catalog:${spec.id}:structured-only:$method',
            schema: promptSchemas.schemaFor(method)!,
          );
        }
      }

      expect(executableSpecs, isNotEmpty);
      expect(
        constructedFactories,
        executableSpecs.length,
        reason: 'Every executable catalog factory must be safe to inspect.',
      );
      expect(nativeSchemaCount, greaterThan(0));
      expect(structuredOnlySchemaCount, greaterThan(0));
      expect(failures, isEmpty, reason: failures.join('\n'));
    },
  );

  test('all catalog and navigation local manifest schemas compile', () {
    final failures = <String>[];
    var catalogManifestCount = 0;
    var navigationManifestCount = 0;

    for (final spec in SkillCatalog.all) {
      final manifest = spec.localManifest;
      if (manifest == null) continue;
      catalogManifestCount += 1;
      _recordLocalRootFailure(
        failures: failures,
        label: 'catalog:${spec.id}:manifest:${manifest.id}',
        schema: manifest.argsSchema,
      );
      _recordSchemaFailure(
        failures: failures,
        validator: validator,
        label: 'catalog:${spec.id}:manifest:${manifest.id}',
        schema: manifest.argsSchema,
      );
    }

    for (final manifest in navigationManifests(locale: AppLocale.en)) {
      navigationManifestCount += 1;
      _recordLocalRootFailure(
        failures: failures,
        label: 'navigation:manifest:${manifest.id}',
        schema: manifest.argsSchema,
      );
      _recordSchemaFailure(
        failures: failures,
        validator: validator,
        label: 'navigation:manifest:${manifest.id}',
        schema: manifest.argsSchema,
      );
    }

    expect(catalogManifestCount, greaterThan(0));
    expect(navigationManifestCount, greaterThan(0));
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}

void _recordLocalRootFailure({
  required List<String> failures,
  required String label,
  required Map<String, dynamic> schema,
}) {
  final declaredType = schema['type'];
  if (declaredType == null || declaredType == 'object') return;
  failures.add('$label: local action args must declare an object root');
}

void _recordSchemaFailure({
  required List<String> failures,
  required ActionSchemaValidator validator,
  required String label,
  required Map<String, dynamic> schema,
}) {
  final result = validator.validate(schema: schema, value: null);
  if (result.schemaValid) return;

  final diagnostics = result.errors
      .map(
        (error) =>
            '${error.code}@${error.schemaPath.isEmpty ? '<root>' : error.schemaPath}',
      )
      .join(', ');
  failures.add('$label: $diagnostics');
}
