import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';

import 'project_json_canonicalizer.dart';

final class ProjectBundleDataUpgradeException implements Exception {
  const ProjectBundleDataUpgradeException(this.code);
  final String code;
  @override
  String toString() => code;
}

/// Declarative storage shape and a fixed, side-effect-free migration language.
/// No authored JavaScript, filesystem, network or evaluator is involved.
final class ProjectBundleDataContract {
  ProjectBundleDataContract._(this.version, this.schema, this.migration);
  final int version;
  final Map<String, Object?> schema;
  final Map<String, Object?>? migration;
  static const json = ProjectJsonCanonicalizer(
    maxBytes: 64 * 1024,
    maxDepth: 16,
    maxNodes: 4096,
  );
  static const validator = ActionSchemaValidator(maxDepth: 16, maxNodes: 4096);
  String get digest => sha256
      .convert(json.canonicalBytes({'version': version, 'schema': schema}))
      .toString();
  String? get fromSchemaDigest => migration?['fromSchemaDigest'] as String?;

  static ProjectBundleDataContract? fromProject(Map<String, Object?> project) {
    final hasVersion = project.containsKey('dataSchemaVersion');
    final hasSchema = project.containsKey('dataSchema');
    if (!hasVersion && !hasSchema && !project.containsKey('dataMigration')) {
      return null;
    }
    if (!hasVersion || !hasSchema) {
      throw const FormatException('project_bundle_data_schema_pair');
    }
    final metadata =
        json.parse(
              json.canonicalize({
                'version': project['dataSchemaVersion'],
                'schema': project['dataSchema'],
                if (project.containsKey('dataMigration'))
                  'migration': project['dataMigration'],
              }),
            )!
            as Map<String, Object?>;
    final version = metadata['version'], rawSchema = metadata['schema'];
    if (version is! int ||
        version < 1 ||
        version > 1000000 ||
        rawSchema is! Map<String, Object?>) {
      throw const FormatException('project_bundle_data_schema');
    }
    validateBoundedAgentSchema(rawSchema);
    final properties = rawSchema['properties']! as Map;
    for (final key in properties.keys) {
      _key(key);
    }
    Map<String, Object?>? migration;
    if (metadata.containsKey('migration')) {
      final raw = metadata['migration'];
      if (raw is! Map<String, Object?> ||
          raw.length != 2 ||
          raw['fromSchemaDigest'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(raw['fromSchemaDigest']! as String) ||
          raw['steps'] is! List ||
          (raw['steps']! as List).length > 32) {
        throw const FormatException('project_bundle_data_migration');
      }
      for (final value in raw['steps']! as List) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('project_bundle_data_migration_step');
        }
        switch (value['op']) {
          case 'rename':
            if (value.length != 3 ||
                !value.containsKey('from') ||
                !value.containsKey('to')) {
              throw const FormatException('project_bundle_data_migration_step');
            }
            _key(value['from']);
            _key(value['to']);
            if (value['from'] == value['to']) {
              throw const FormatException('project_bundle_data_migration_step');
            }
          case 'default':
            if (value.length != 3 ||
                !value.containsKey('key') ||
                !value.containsKey('value')) {
              throw const FormatException('project_bundle_data_migration_step');
            }
            _key(value['key']);
            final rule = properties[value['key']];
            if (rule == null ||
                !validator
                    .validate(schema: rule, value: value['value'])
                    .isValid) {
              throw const FormatException('project_bundle_data_default');
            }
          default:
            throw const FormatException(
              'project_bundle_data_migration_operation',
            );
        }
      }
      migration = raw;
    }
    return ProjectBundleDataContract._(version, rawSchema, migration);
  }

  void validateData(Map<String, Object?> data) {
    final snapshot = json.parse(json.canonicalize(data));
    if (!validator.validate(schema: schema, value: snapshot).isValid) {
      throw const ProjectBundleDataUpgradeException(
        'project_bundle_data_schema_mismatch',
      );
    }
  }

  Map<String, Object?> migrate(
    Map<String, Object?> data, {
    required String sourceDigest,
  }) {
    if (sourceDigest != fromSchemaDigest) {
      throw const ProjectBundleDataUpgradeException(
        'project_bundle_data_migration_required',
      );
    }
    final next = Map<String, Object?>.from(data);
    for (final value in migration!['steps']! as List) {
      final step = value as Map<String, Object?>;
      if (step['op'] == 'rename') {
        final from = step['from']! as String, to = step['to']! as String;
        if (!next.containsKey(from)) continue;
        if (next.containsKey(to)) {
          throw const ProjectBundleDataUpgradeException(
            'project_bundle_data_migration_conflict',
          );
        }
        next[to] = next.remove(from);
      } else {
        next.putIfAbsent(step['key']! as String, () => step['value']);
      }
    }
    final frozen = json.parse(json.canonicalize(next))! as Map<String, Object?>;
    validateData(frozen);
    return frozen;
  }

  static void _key(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 96 ||
        value.runes.any((rune) => rune < 32 || rune == 127)) {
      throw const FormatException('project_bundle_data_key');
    }
  }
}
