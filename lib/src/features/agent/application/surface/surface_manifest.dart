import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/action_schema_validator.dart';

enum SurfaceEntryKind { event, action }

/// One declared interaction in a surface's manifest: an event the surface emits
/// (surface to agent) or an action the agent can invoke (agent to surface).
class SurfaceEntry {
  const SurfaceEntry(this.name, this.schema)
    : schemaVersion = 1,
      _jsonSchema = const <String, Object?>{},
      _riskName = null,
      _consequencePolicyName = null;

  SurfaceEntry.v2({
    required this.name,
    required Map<String, Object?> schema,
    required ActionRisk risk,
    required ActionConsequencePolicy consequencePolicy,
  }) : schemaVersion = 2,
       schema = const <String, String>{},
       _jsonSchema = _snapshotSurfaceSchema(schema),
       _riskName = risk.name,
       _consequencePolicyName = consequencePolicy.name;

  SurfaceEntry._v2Raw({
    required this.name,
    required this.schemaVersion,
    required Map schema,
    required String? riskName,
    required String? consequencePolicyName,
  }) : schema = const <String, String>{},
       _jsonSchema = _snapshotSurfaceSchema(schema),
       _riskName = riskName,
       _consequencePolicyName = consequencePolicyName;

  final String name;

  /// Legacy v1 flat field-to-type mapping. V2 entries expose an empty map.
  final Map<String, String> schema;
  final int schemaVersion;
  final Map<String, Object?> _jsonSchema;
  final String? _riskName;
  final String? _consequencePolicyName;

  factory SurfaceEntry.fromJson(
    Map<dynamic, dynamic> json, {
    int schemaVersion = 1,
  }) {
    if (schemaVersion != 1) {
      final rawSchema = json['schema'];
      return SurfaceEntry._v2Raw(
        name: (json['name'] ?? '').toString(),
        schemaVersion: schemaVersion,
        schema: rawSchema is Map
            ? rawSchema
            : const <String, Object?>{'maaso.invalid_schema_snapshot': true},
        riskName: json['risk']?.toString(),
        consequencePolicyName: json['consequencePolicy']?.toString(),
      );
    }
    final schema = <String, String>{};
    final raw = json['schema'];
    if (raw is Map) {
      raw.forEach((key, value) {
        schema[key.toString()] = value.toString();
      });
    }
    return SurfaceEntry((json['name'] ?? '').toString(), schema);
  }

  Map<String, Object?> get jsonSchema =>
      schemaVersion == 1 ? _legacyJsonSchema(schema) : _jsonSchema;

  ActionRisk? get declaredRisk {
    final name = _riskName;
    if (name == null) return null;
    for (final value in ActionRisk.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  ActionConsequencePolicy? get declaredConsequencePolicy {
    final name = _consequencePolicyName;
    if (name == null) return null;
    for (final value in ActionConsequencePolicy.values) {
      if (value.name == name) return value;
    }
    return null;
  }

  ActionRisk effectiveRisk(SurfaceEntryKind kind) {
    if (schemaVersion == 1) {
      return kind == SurfaceEntryKind.event
          ? ActionRisk.readOnly
          : ActionRisk.localMutation;
    }
    return declaredRisk ?? ActionRisk.destructive;
  }

  ActionConsequencePolicy effectiveConsequencePolicy(SurfaceEntryKind kind) {
    if (schemaVersion == 1) return ActionConsequencePolicy.reversible;
    return declaredConsequencePolicy ?? ActionConsequencePolicy.destructive;
  }

  bool requiresApproval(SurfaceEntryKind kind) =>
      effectiveRisk(kind).requiresApproval ||
      effectiveConsequencePolicy(kind).requiresApproval;

  Map<String, Object?> toJson() {
    if (schemaVersion == 1) {
      return <String, Object?>{'name': name, 'schema': schema};
    }
    return <String, Object?>{
      'name': name,
      'schema': _jsonSchema,
      if (_riskName != null) 'risk': _riskName,
      if (_consequencePolicyName != null)
        'consequencePolicy': _consequencePolicyName,
    };
  }
}

/// A surface's interaction contract: the events it emits, the actions it
/// accepts, and the agent-facing instructions for driving it.
class SurfaceManifest {
  static const String _invalidContractMarker = '_maasoInvalidContract';

  const SurfaceManifest({
    this.events = const [],
    this.actions = const [],
    this.instructions = '',
  }) : schemaVersion = 1,
       _emitSchemaVersion = false,
       _parseIssues = const <String>[];

  SurfaceManifest.v2({
    List<SurfaceEntry> events = const <SurfaceEntry>[],
    List<SurfaceEntry> actions = const <SurfaceEntry>[],
    this.instructions = '',
  }) : schemaVersion = 2,
       _emitSchemaVersion = true,
       _parseIssues = const <String>[],
       events = List<SurfaceEntry>.unmodifiable(events),
       actions = List<SurfaceEntry>.unmodifiable(actions);

  SurfaceManifest._parsed({
    required this.schemaVersion,
    required bool emitSchemaVersion,
    required List<SurfaceEntry> events,
    required List<SurfaceEntry> actions,
    required this.instructions,
    required List<String> parseIssues,
  }) : _emitSchemaVersion = emitSchemaVersion,
       _parseIssues = List<String>.unmodifiable(parseIssues),
       events = List<SurfaceEntry>.unmodifiable(events),
       actions = List<SurfaceEntry>.unmodifiable(actions);

  static const ActionSchemaValidator _schemaValidator = ActionSchemaValidator();
  static const int maxEntriesPerKind = 32;
  static const int maxEntryNameRunes = 96;
  static const int maxInstructionsRunes = 4096;
  static const int maxEntrySchemaBytes = 32 * 1024;
  static const int maxManifestSchemaBytes = 128 * 1024;

  final int schemaVersion;
  final List<SurfaceEntry> events;
  final List<SurfaceEntry> actions;
  final String instructions;
  final bool _emitSchemaVersion;
  final List<String> _parseIssues;

  static SurfaceManifest fromSpec(Object? raw) {
    if (raw is! Map) return const SurfaceManifest();
    final schemaVersion = _parseManifestVersion(raw['schemaVersion']);
    final parseIssues = <String>[];
    if (schemaVersion != 1 && raw[_invalidContractMarker] == true) {
      parseIssues.add('surface.manifest.invalid_contract_marker');
    }
    List<SurfaceEntry> parse(Object? rawEntries, String kind) {
      if (rawEntries == null) return const <SurfaceEntry>[];
      if (rawEntries is! List) {
        if (schemaVersion != 1) {
          parseIssues.add('surface.manifest.$kind.expected_array');
        }
        return const <SurfaceEntry>[];
      }
      final entries = <SurfaceEntry>[];
      for (var index = 0; index < rawEntries.length; index += 1) {
        final rawEntry = rawEntries[index];
        if (rawEntry is! Map) {
          if (schemaVersion != 1) {
            parseIssues.add('surface.manifest.$kind[$index].expected_object');
          }
          continue;
        }
        final entry = SurfaceEntry.fromJson(
          rawEntry,
          schemaVersion: schemaVersion,
        );
        if (schemaVersion != 1 || entry.name.isNotEmpty) entries.add(entry);
      }
      return entries;
    }

    final rawInstructions = raw['instructions'];
    if (schemaVersion != 1 &&
        rawInstructions != null &&
        rawInstructions is! String) {
      parseIssues.add('surface.manifest.instructions_expected_string');
    }

    return SurfaceManifest._parsed(
      schemaVersion: schemaVersion,
      emitSchemaVersion: raw.containsKey('schemaVersion'),
      events: parse(raw['events'], 'events'),
      actions: parse(raw['actions'], 'actions'),
      instructions: (rawInstructions ?? '').toString(),
      parseIssues: parseIssues,
    );
  }

  Map<String, Object?> toJson() => {
    if (_emitSchemaVersion || schemaVersion != 1)
      'schemaVersion': schemaVersion,
    if (schemaVersion != 1 && _parseIssues.isNotEmpty)
      _invalidContractMarker: true,
    'events': events.map((entry) => entry.toJson()).toList(),
    'actions': actions.map((entry) => entry.toJson()).toList(),
    if (instructions.isNotEmpty) 'instructions': instructions,
  };

  List<String> diagnoseContract() {
    if (schemaVersion == 1) return const <String>[];
    final issues = <String>[..._parseIssues];
    if (schemaVersion != 2) {
      issues.add('surface.manifest.unsupported_schema_version');
    }
    if (instructions.runes.length > maxInstructionsRunes) {
      issues.add('surface.manifest.instructions_too_long');
    }
    final totalSchemaBytes =
        _diagnoseEntries(
          entries: events,
          kind: SurfaceEntryKind.event,
          issues: issues,
        ) +
        _diagnoseEntries(
          entries: actions,
          kind: SurfaceEntryKind.action,
          issues: issues,
        );
    if (totalSchemaBytes > maxManifestSchemaBytes) {
      issues.add('surface.manifest.schema_budget_exceeded');
    }
    return List<String>.unmodifiable(issues.toSet());
  }

  SurfaceEntry? action(String name) => _find(actions, name);
  SurfaceEntry? event(String name) => _find(events, name);

  String? validateAction(String name, Object? data) => _validateManifestEntry(
    entries: actions,
    kind: SurfaceEntryKind.action,
    name: name,
    data: data,
  );

  String? validateEvent(String name, Object? data) => _validateManifestEntry(
    entries: events,
    kind: SurfaceEntryKind.event,
    name: name,
    data: data,
  );

  String toPromptText(String surfaceId, {String? title, AppLocale? locale}) {
    String fmt(List<SurfaceEntry> list, SurfaceEntryKind kind) => list.isEmpty
        ? AgentPromptCatalog.text('surface.active.none', locale: locale)
        : list
              .map((entry) {
                if (entry.schemaVersion == 1) {
                  final schema = entry.schema.isEmpty
                      ? '{}'
                      : '{${entry.schema.entries.map((field) => '${field.key}:${field.value}').join(', ')}}';
                  return '${entry.name}$schema';
                }
                return '${entry.name}${jsonEncode(_surfacePromptSchema(entry.jsonSchema))}'
                    '[risk=${entry.effectiveRisk(kind).name},'
                    'consequence=${entry.effectiveConsequencePolicy(kind).name}]';
              })
              .join(', ');

    final head = title == null ? 'id=$surfaceId' : '$title (id=$surfaceId)';
    final base = <String>[
      AgentPromptCatalog.text(
        'surface.active.identity',
        locale: locale,
        params: {'head': head},
      ),
      AgentPromptCatalog.text(
        'surface.active.events',
        locale: locale,
        params: {
          'id': surfaceId,
          'events': fmt(events, SurfaceEntryKind.event),
        },
      ),
      AgentPromptCatalog.text(
        'surface.active.actions',
        locale: locale,
        params: {'actions': fmt(actions, SurfaceEntryKind.action)},
      ),
    ].join('\n');
    return instructions.isEmpty
        ? base
        : '$base\n${AgentPromptCatalog.text('surface.active.instructions', locale: locale, params: {'instructions': instructions})}';
  }

  static SurfaceEntry? _find(List<SurfaceEntry> list, String name) {
    for (final entry in list) {
      if (entry.name == name) return entry;
    }
    return null;
  }

  String? _validateManifestEntry({
    required List<SurfaceEntry> entries,
    required SurfaceEntryKind kind,
    required String name,
    required Object? data,
  }) {
    if (schemaVersion != 1 && diagnoseContract().isNotEmpty) {
      return '${kind.name} "$name" host_contract_invalid';
    }
    return _validate(entries, kind, name, data);
  }

  static String? _validate(
    List<SurfaceEntry> entries,
    SurfaceEntryKind kind,
    String name,
    Object? data,
  ) {
    final entry = _find(entries, name);
    if (entry == null) {
      final known = entries.map((item) => item.name).join(', ');
      return 'unknown ${kind.name} "$name" '
          '(declared: ${known.isEmpty ? "none" : known})';
    }
    if (entry.schemaVersion != 1 &&
        (entry.schemaVersion != 2 || !_safeV2Policy(entry, kind))) {
      return '${kind.name} "$name" host_contract_invalid';
    }
    final validatedData = entry.schemaVersion == 1 && data == null
        ? const <String, Object?>{}
        : data;
    final validation = _schemaValidator.validate(
      schema: entry.jsonSchema,
      value: validatedData,
    );
    if (validation.isValid) return null;
    if (!validation.schemaValid) {
      return '${kind.name} "$name" host_schema_invalid';
    }
    final codes = validation.errors
        .map((error) => error.code)
        .toSet()
        .take(8)
        .join(',');
    return '${kind.name} "$name" invalid_arguments'
        '${codes.isEmpty ? "" : ":$codes"}';
  }

  int _diagnoseEntries({
    required List<SurfaceEntry> entries,
    required SurfaceEntryKind kind,
    required List<String> issues,
  }) {
    var totalSchemaBytes = 0;
    final kindName = '${kind.name}s';
    if (entries.length > maxEntriesPerKind) {
      issues.add('surface.manifest.$kindName.too_many');
    }
    final names = <String>{};
    for (var index = 0; index < entries.length; index += 1) {
      final entry = entries[index];
      String issue(String code) => 'surface.manifest.$kindName[$index].$code';
      if (entry.schemaVersion != 2) {
        issues.add(issue('wrong_schema_version'));
      }
      if (entry.name.runes.length > maxEntryNameRunes ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9._:-]{0,95}$').hasMatch(entry.name)) {
        issues.add(issue('invalid_name'));
      } else if (!names.add(entry.name)) {
        issues.add(issue('duplicate_name'));
      }
      final schema = entry.jsonSchema;
      if (schema['type'] != 'object') {
        issues.add(issue('schema_not_object'));
      }
      if (_surfaceSchemaContainsPattern(schema)) {
        issues.add(issue('unsafe_pattern'));
      } else {
        final schemaValidation = _schemaValidator.validate(
          schema: schema,
          value: const <String, Object?>{},
        );
        if (!schemaValidation.schemaValid) {
          issues.add(issue('schema_invalid'));
        }
      }
      try {
        final schemaBytes = utf8.encode(jsonEncode(schema)).length;
        totalSchemaBytes += schemaBytes;
        if (schemaBytes > maxEntrySchemaBytes) {
          issues.add(issue('schema_too_large'));
        }
      } catch (_) {
        issues.add(issue('schema_invalid'));
      }
      if (entry.declaredRisk == null) {
        issues.add(issue('risk_invalid'));
      }
      if (entry.declaredConsequencePolicy == null) {
        issues.add(issue('consequence_invalid'));
      }
      if (!_safeV2Policy(entry, kind)) {
        issues.add(issue('unsafe_policy'));
      }
    }
    return totalSchemaBytes;
  }

  static bool _safeV2Policy(SurfaceEntry entry, SurfaceEntryKind kind) {
    final risk = entry.declaredRisk;
    final consequence = entry.declaredConsequencePolicy;
    if (kind == SurfaceEntryKind.event) {
      return risk == ActionRisk.readOnly &&
          consequence == ActionConsequencePolicy.reversible;
    }
    return switch ((risk, consequence)) {
      (ActionRisk.readOnly, ActionConsequencePolicy.reversible) => true,
      (
        ActionRisk.localMutation,
        ActionConsequencePolicy.reversible ||
            ActionConsequencePolicy.prepareOnly,
      ) =>
        true,
      _ => false,
    };
  }
}

int _parseManifestVersion(Object? raw) {
  if (raw == null) return 1;
  if (raw is int) return raw;
  if (raw is num && raw.isFinite && raw == raw.toInt()) return raw.toInt();
  return int.tryParse(raw.toString()) ?? -1;
}

Map<String, Object?> _legacyJsonSchema(Map<String, String> schema) {
  final properties = <String, Object?>{};
  for (final field in schema.entries) {
    final type = switch (field.value) {
      'string' => 'string',
      'number' => 'number',
      'bool' => 'boolean',
      'object' => 'object',
      'array' => 'array',
      _ => null,
    };
    properties[field.key] = type == null
        ? const <String, Object?>{}
        : <String, Object?>{'type': type};
  }
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'type': 'object',
    'properties': Map<String, Object?>.unmodifiable(properties),
  });
}

Map<String, Object?> _surfacePromptSchema(Map<String, Object?> schema) {
  final projected = <String, Object?>{};
  for (final entry in schema.entries) {
    switch (entry.key) {
      case 'title':
      case 'description':
      case 'default':
      case 'examples':
      case r'$comment':
        continue;
      case 'properties':
        final properties = entry.value;
        if (properties is Map) {
          projected[entry.key] = <String, Object?>{
            for (final property in properties.entries)
              if (property.key is String && property.value is Map)
                property.key as String: _surfacePromptSchema(
                  Map<String, Object?>.from(property.value as Map),
                ),
          };
        }
        break;
      case 'additionalProperties':
      case 'items':
        final child = entry.value;
        projected[entry.key] = child is Map
            ? _surfacePromptSchema(Map<String, Object?>.from(child))
            : child;
        break;
      case 'anyOf':
        final branches = entry.value;
        projected[entry.key] = branches is List
            ? <Object?>[
                for (final branch in branches)
                  branch is Map
                      ? _surfacePromptSchema(Map<String, Object?>.from(branch))
                      : branch,
              ]
            : branches;
        break;
      default:
        projected[entry.key] = entry.value;
        break;
    }
  }
  return projected;
}

bool _surfaceSchemaContainsPattern(Map<String, Object?> schema) {
  if (schema.containsKey('pattern')) return true;
  final properties = schema['properties'];
  if (properties is Map) {
    for (final child in properties.values) {
      if (child is Map &&
          _surfaceSchemaContainsPattern(Map<String, Object?>.from(child))) {
        return true;
      }
    }
  }
  for (final keyword in const <String>['items', 'additionalProperties']) {
    final child = schema[keyword];
    if (child is Map &&
        _surfaceSchemaContainsPattern(Map<String, Object?>.from(child))) {
      return true;
    }
  }
  final branches = schema['anyOf'];
  if (branches is List) {
    for (final branch in branches) {
      if (branch is Map &&
          _surfaceSchemaContainsPattern(Map<String, Object?>.from(branch))) {
        return true;
      }
    }
  }
  return false;
}

Map<String, Object?> _snapshotSurfaceSchema(Map schema) {
  final budget = _SurfaceSchemaSnapshotBudget(
    remaining: 4096,
    remainingTextCodeUnits: SurfaceManifest.maxEntrySchemaBytes,
  );
  final snapshot = _snapshotSurfaceSchemaValue(
    schema,
    depth: 0,
    budget: budget,
    activeContainers: Set<Object>.identity(),
  );
  final map = snapshot is Map<String, Object?>
      ? Map<String, Object?>.from(snapshot)
      : <String, Object?>{};
  if (budget.invalid) map['maaso.invalid_schema_snapshot'] = true;
  return Map<String, Object?>.unmodifiable(map);
}

Object? _snapshotSurfaceSchemaValue(
  Object? value, {
  required int depth,
  required _SurfaceSchemaSnapshotBudget budget,
  required Set<Object> activeContainers,
}) {
  if (depth > 64 || !budget.take()) {
    budget.invalid = true;
    return null;
  }
  if (value == null || value is bool) {
    return value;
  }
  if (value is String) {
    if (!budget.takeText(value)) return null;
    return value;
  }
  if (value is num) {
    if (!value.isFinite) {
      budget.invalid = true;
      return null;
    }
    return value;
  }
  if (value is Map) {
    if (!activeContainers.add(value)) {
      budget.invalid = true;
      return null;
    }
    final snapshot = <String, Object?>{};
    try {
      for (final entry in value.entries) {
        if (budget.remaining <= 0) {
          budget.invalid = true;
          break;
        }
        if (entry.key is! String) {
          budget.invalid = true;
          budget.take();
          continue;
        }
        if (!budget.takeText(entry.key as String)) break;
        snapshot[entry.key as String] = _snapshotSurfaceSchemaValue(
          entry.value,
          depth: depth + 1,
          budget: budget,
          activeContainers: activeContainers,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return Map<String, Object?>.unmodifiable(snapshot);
  }
  if (value is List) {
    if (!activeContainers.add(value)) {
      budget.invalid = true;
      return null;
    }
    try {
      final snapshot = <Object?>[];
      for (final item in value) {
        if (budget.remaining <= 0) {
          budget.invalid = true;
          break;
        }
        snapshot.add(
          _snapshotSurfaceSchemaValue(
            item,
            depth: depth + 1,
            budget: budget,
            activeContainers: activeContainers,
          ),
        );
      }
      return List<Object?>.unmodifiable(snapshot);
    } finally {
      activeContainers.remove(value);
    }
  }
  budget.invalid = true;
  return null;
}

final class _SurfaceSchemaSnapshotBudget {
  _SurfaceSchemaSnapshotBudget({
    required this.remaining,
    required this.remainingTextCodeUnits,
  });

  int remaining;
  int remainingTextCodeUnits;
  bool invalid = false;

  bool take() {
    if (remaining <= 0) return false;
    remaining -= 1;
    return true;
  }

  bool takeText(String value) {
    remainingTextCodeUnits -= value.length;
    if (remainingTextCodeUnits >= 0) return true;
    invalid = true;
    return false;
  }
}

String formatSurfaceEventLine(String surfaceId, String event, Object? data) {
  final payload = data == null ? '' : ' ${jsonEncode(data)}';
  return '[surface:$surfaceId:$event]$payload';
}
