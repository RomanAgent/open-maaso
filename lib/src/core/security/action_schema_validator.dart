/// Deterministic, side-effect-free validation for Agent action arguments.
///
/// This intentionally implements only the JSON Schema subset used by Maaso's
/// native tool and structured-action declarations. Unsupported or malformed
/// schemas fail closed instead of silently weakening an action boundary.
final class ActionSchemaValidator {
  const ActionSchemaValidator({
    this.maxErrors = 32,
    this.maxDepth = 64,
    this.maxNodes = 4096,
  }) : assert(maxErrors > 0),
       assert(maxDepth > 0),
       assert(maxNodes > 0);

  /// Maximum number of public errors returned by one validation.
  final int maxErrors;

  /// Maximum nesting depth accepted for schemas and argument values.
  final int maxDepth;

  /// Maximum number of schema or argument nodes inspected per phase.
  final int maxNodes;

  /// Validates [value] against [schema].
  ///
  /// Error paths are RFC 6901 JSON Pointers. The empty string identifies the
  /// root value or schema. Schema errors are returned before value errors, and
  /// no value is accepted when its schema is malformed or unsupported.
  ActionSchemaValidationResult validate({
    required Object? schema,
    required Object? value,
  }) {
    final errorLimit = maxErrors.clamp(1, 128);
    final depthLimit = maxDepth.clamp(1, 128);
    final nodeLimit = maxNodes.clamp(1, 65536);
    final schemaErrors = _ErrorCollector(errorLimit);
    final compiled = _compileSchema(
      schema,
      schemaPath: '',
      depth: 0,
      maxDepth: depthLimit,
      budget: _TraversalBudget(nodeLimit),
      activeContainers: Set<Object>.identity(),
      errors: schemaErrors,
    );

    if (compiled == null || schemaErrors.hasErrors) {
      return ActionSchemaValidationResult._(
        schemaValid: false,
        errors: schemaErrors.errors,
        truncated: schemaErrors.truncated,
      );
    }

    final valueErrors = _ErrorCollector(errorLimit);
    _validateJsonValue(
      value,
      path: '',
      depth: 0,
      maxDepth: depthLimit,
      budget: _TraversalBudget(nodeLimit),
      activeContainers: Set<Object>.identity(),
      errors: valueErrors,
    );
    if (!valueErrors.hasErrors) {
      _validateNode(
        compiled,
        value,
        path: '',
        depth: 0,
        maxDepth: depthLimit,
        errors: valueErrors,
      );
    }

    return ActionSchemaValidationResult._(
      schemaValid: true,
      errors: valueErrors.errors,
      truncated: valueErrors.truncated,
    );
  }
}

/// Immutable result of one action-schema validation.
final class ActionSchemaValidationResult {
  ActionSchemaValidationResult._({
    required this.schemaValid,
    required List<ActionSchemaValidationError> errors,
    required this.truncated,
  }) : errors = List<ActionSchemaValidationError>.unmodifiable(errors);

  /// Whether the schema was well-formed and entirely supported.
  final bool schemaValid;

  /// Stable, bounded validation errors in deterministic traversal order.
  final List<ActionSchemaValidationError> errors;

  /// Whether more errors existed than the configured public error limit.
  final bool truncated;

  bool get isValid => schemaValid && errors.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'valid': isValid,
    'schemaValid': schemaValid,
    'truncated': truncated,
    'errors': errors.map((error) => error.toJson()).toList(growable: false),
  };
}

/// One stable validation failure.
final class ActionSchemaValidationError {
  const ActionSchemaValidationError({
    required this.path,
    required this.schemaPath,
    required this.code,
    required this.message,
  });

  /// RFC 6901 pointer to the rejected argument value.
  final String path;

  /// RFC 6901 pointer to the schema keyword that produced the error.
  final String schemaPath;

  /// Machine-readable code. Codes are stable; messages are diagnostic only.
  final String code;

  /// Bounded diagnostic text that never includes the rejected value.
  final String message;

  Map<String, String> toJson() => <String, String>{
    'path': path,
    'schemaPath': schemaPath,
    'code': code,
    'message': message,
  };

  @override
  String toString() => '$code at ${path.isEmpty ? '<root>' : path}';
}

final class _CompiledSchema {
  const _CompiledSchema({
    required this.schemaPath,
    required this.type,
    required this.properties,
    required this.requiredProperties,
    required this.additionalProperties,
    required this.items,
    required this.anyOf,
    required this.enumValues,
    required this.hasConst,
    required this.constValue,
    required this.minimum,
    required this.maximum,
    required this.minLength,
    required this.maxLength,
    required this.pattern,
    required this.minItems,
    required this.maxItems,
  });

  final String schemaPath;
  final String? type;
  final Map<String, _CompiledSchema> properties;
  final List<String> requiredProperties;
  final Object? additionalProperties;
  final _CompiledSchema? items;
  final List<_CompiledSchema> anyOf;
  final List<Object?>? enumValues;
  final bool hasConst;
  final Object? constValue;
  final num? minimum;
  final num? maximum;
  final int? minLength;
  final int? maxLength;
  final RegExp? pattern;
  final int? minItems;
  final int? maxItems;
}

const Set<String> _supportedKeywords = <String>{
  'type',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'enum',
  'const',
  'anyOf',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
  'minItems',
  'maxItems',
  'title',
  'description',
  'default',
  'examples',
  r'$comment',
};

const Set<String> _supportedTypes = <String>{
  'object',
  'array',
  'string',
  'number',
  'integer',
  'boolean',
  'null',
};

_CompiledSchema? _compileSchema(
  Object? raw, {
  required String schemaPath,
  required int depth,
  required int maxDepth,
  required _TraversalBudget budget,
  required Set<Object> activeContainers,
  required _ErrorCollector errors,
}) {
  if (errors.saturated) return null;
  if (depth > maxDepth) {
    errors.add(
      _schemaError(
        schemaPath,
        'schema.max_depth',
        'Schema nesting exceeds the configured limit.',
      ),
    );
    return null;
  }
  if (!budget.take()) {
    errors.add(
      _schemaError(
        schemaPath,
        'schema.too_complex',
        'Schema exceeds the configured node limit.',
      ),
    );
    return null;
  }
  if (raw is! Map) {
    errors.add(
      _schemaError(
        schemaPath,
        'schema.expected_object',
        'A schema must be an object.',
      ),
    );
    return null;
  }
  if (!activeContainers.add(raw)) {
    errors.add(
      _schemaError(
        schemaPath,
        'schema.cycle',
        'Schema containers must not contain cycles.',
      ),
    );
    return null;
  }

  try {
    final schema = <String, Object?>{};
    var hasNonStringKey = false;
    for (final entry in raw.entries) {
      if (entry.key is! String) {
        hasNonStringKey = true;
        continue;
      }
      schema[entry.key as String] = entry.value;
    }
    if (hasNonStringKey) {
      errors.add(
        _schemaError(
          schemaPath,
          'schema.non_string_key',
          'Schema object keys must be strings.',
        ),
      );
    }

    final unknownKeywords =
        schema.keys
            .where((key) => !_supportedKeywords.contains(key))
            .toList(growable: false)
          ..sort();
    for (final keyword in unknownKeywords) {
      errors.add(
        _schemaError(
          _appendPointer(schemaPath, keyword),
          'schema.unsupported_keyword',
          'Schema contains an unsupported keyword.',
        ),
      );
    }

    String? type;
    if (schema.containsKey('type')) {
      final rawType = schema['type'];
      if (rawType is! String || !_supportedTypes.contains(rawType)) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'type'),
            'schema.invalid_type',
            'Schema type must be one supported type name.',
          ),
        );
      } else {
        type = rawType;
      }
    }

    _validateTextAnnotation(schema, 'title', schemaPath, errors);
    _validateTextAnnotation(schema, 'description', schemaPath, errors);
    _validateTextAnnotation(schema, r'$comment', schemaPath, errors);
    _validateJsonAnnotation(schema, 'default', schemaPath, maxDepth, errors);
    if (schema.containsKey('examples')) {
      final examples = schema['examples'];
      if (examples is! List) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'examples'),
            'schema.invalid_examples',
            'Schema examples must be an array of JSON values.',
          ),
        );
      } else {
        for (var index = 0; index < examples.length; index++) {
          if (!_isJsonLiteral(
            examples[index],
            maxDepth: maxDepth,
            activeContainers: Set<Object>.identity(),
          )) {
            errors.add(
              _schemaError(
                _appendPointer(
                  _appendPointer(schemaPath, 'examples'),
                  '$index',
                ),
                'schema.invalid_examples',
                'Schema examples must contain only JSON values.',
              ),
            );
          }
        }
      }
    }

    final properties = <String, _CompiledSchema>{};
    if (schema.containsKey('properties')) {
      final rawProperties = schema['properties'];
      if (rawProperties is! Map) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'properties'),
            'schema.invalid_properties',
            'Schema properties must be an object.',
          ),
        );
      } else {
        final propertyEntries = <MapEntry<String, Object?>>[];
        var hasInvalidPropertyKey = false;
        for (final entry in rawProperties.entries) {
          if (entry.key is! String) {
            hasInvalidPropertyKey = true;
            continue;
          }
          propertyEntries.add(MapEntry(entry.key as String, entry.value));
        }
        if (hasInvalidPropertyKey) {
          errors.add(
            _schemaError(
              _appendPointer(schemaPath, 'properties'),
              'schema.non_string_key',
              'Property names must be strings.',
            ),
          );
        }
        propertyEntries.sort((left, right) => left.key.compareTo(right.key));
        for (final entry in propertyEntries) {
          final childPath = _appendPointer(
            _appendPointer(schemaPath, 'properties'),
            entry.key,
          );
          final child = _compileSchema(
            entry.value,
            schemaPath: childPath,
            depth: depth + 1,
            maxDepth: maxDepth,
            budget: budget,
            activeContainers: activeContainers,
            errors: errors,
          );
          if (child != null) properties[entry.key] = child;
        }
      }
    }

    final requiredProperties = <String>[];
    if (schema.containsKey('required')) {
      final rawRequired = schema['required'];
      if (rawRequired is! List) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'required'),
            'schema.invalid_required',
            'Schema required must be an array of unique strings.',
          ),
        );
      } else {
        final seen = <String>{};
        for (var index = 0; index < rawRequired.length; index++) {
          final property = rawRequired[index];
          if (property is! String || !seen.add(property)) {
            errors.add(
              _schemaError(
                _appendPointer(
                  _appendPointer(schemaPath, 'required'),
                  '$index',
                ),
                'schema.invalid_required',
                'Schema required must contain unique strings.',
              ),
            );
          } else {
            requiredProperties.add(property);
          }
        }
        requiredProperties.sort();
      }
    }

    Object? additionalProperties;
    if (schema.containsKey('additionalProperties')) {
      final rawAdditional = schema['additionalProperties'];
      if (rawAdditional is bool) {
        additionalProperties = rawAdditional;
      } else if (rawAdditional is Map) {
        additionalProperties = _compileSchema(
          rawAdditional,
          schemaPath: _appendPointer(schemaPath, 'additionalProperties'),
          depth: depth + 1,
          maxDepth: maxDepth,
          budget: budget,
          activeContainers: activeContainers,
          errors: errors,
        );
      } else {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'additionalProperties'),
            'schema.invalid_additional_properties',
            'Schema additionalProperties must be a boolean or schema.',
          ),
        );
      }
    }

    _CompiledSchema? items;
    if (schema.containsKey('items')) {
      items = _compileSchema(
        schema['items'],
        schemaPath: _appendPointer(schemaPath, 'items'),
        depth: depth + 1,
        maxDepth: maxDepth,
        budget: budget,
        activeContainers: activeContainers,
        errors: errors,
      );
    }

    final anyOf = <_CompiledSchema>[];
    if (schema.containsKey('anyOf')) {
      final rawAnyOf = schema['anyOf'];
      if (rawAnyOf is! List || rawAnyOf.isEmpty) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'anyOf'),
            'schema.invalid_any_of',
            'Schema anyOf must be a non-empty array of schemas.',
          ),
        );
      } else {
        for (var index = 0; index < rawAnyOf.length; index++) {
          final branch = _compileSchema(
            rawAnyOf[index],
            schemaPath: _appendPointer(
              _appendPointer(schemaPath, 'anyOf'),
              '$index',
            ),
            depth: depth + 1,
            maxDepth: maxDepth,
            budget: budget,
            activeContainers: activeContainers,
            errors: errors,
          );
          if (branch != null) anyOf.add(branch);
        }
      }
    }

    List<Object?>? enumValues;
    if (schema.containsKey('enum')) {
      final rawEnum = schema['enum'];
      if (rawEnum is! List || rawEnum.isEmpty) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'enum'),
            'schema.invalid_enum',
            'Schema enum must be a non-empty array of unique JSON values.',
          ),
        );
      } else {
        enumValues = <Object?>[];
        for (var index = 0; index < rawEnum.length; index++) {
          final candidate = rawEnum[index];
          final entryPath = _appendPointer(
            _appendPointer(schemaPath, 'enum'),
            '$index',
          );
          if (!_isJsonLiteral(
            candidate,
            maxDepth: maxDepth,
            activeContainers: Set<Object>.identity(),
          )) {
            errors.add(
              _schemaError(
                entryPath,
                'schema.invalid_enum',
                'Schema enum values must be valid JSON values.',
              ),
            );
          } else if (enumValues.any(
            (existing) => _jsonDeepEquals(existing, candidate),
          )) {
            errors.add(
              _schemaError(
                entryPath,
                'schema.invalid_enum',
                'Schema enum values must be unique.',
              ),
            );
          } else {
            enumValues.add(candidate);
          }
        }
      }
    }

    final hasConst = schema.containsKey('const');
    final constValue = schema['const'];
    if (hasConst &&
        !_isJsonLiteral(
          constValue,
          maxDepth: maxDepth,
          activeContainers: Set<Object>.identity(),
        )) {
      errors.add(
        _schemaError(
          _appendPointer(schemaPath, 'const'),
          'schema.invalid_const',
          'Schema const must be a valid JSON value.',
        ),
      );
    }

    final minimum = _readFiniteNumber(schema, 'minimum', schemaPath, errors);
    final maximum = _readFiniteNumber(schema, 'maximum', schemaPath, errors);
    final minLength = _readNonNegativeInteger(
      schema,
      'minLength',
      schemaPath,
      errors,
    );
    final maxLength = _readNonNegativeInteger(
      schema,
      'maxLength',
      schemaPath,
      errors,
    );
    final minItems = _readNonNegativeInteger(
      schema,
      'minItems',
      schemaPath,
      errors,
    );
    final maxItems = _readNonNegativeInteger(
      schema,
      'maxItems',
      schemaPath,
      errors,
    );
    _validateOrderedBounds(
      minimum,
      maximum,
      schemaPath: schemaPath,
      maximumKeyword: 'maximum',
      errors: errors,
    );
    _validateOrderedBounds(
      minLength,
      maxLength,
      schemaPath: schemaPath,
      maximumKeyword: 'maxLength',
      errors: errors,
    );
    _validateOrderedBounds(
      minItems,
      maxItems,
      schemaPath: schemaPath,
      maximumKeyword: 'maxItems',
      errors: errors,
    );

    RegExp? pattern;
    if (schema.containsKey('pattern')) {
      final rawPattern = schema['pattern'];
      if (rawPattern is! String) {
        errors.add(
          _schemaError(
            _appendPointer(schemaPath, 'pattern'),
            'schema.invalid_pattern',
            'Schema pattern must be a valid regular expression string.',
          ),
        );
      } else {
        try {
          pattern = RegExp(rawPattern);
        } on FormatException {
          errors.add(
            _schemaError(
              _appendPointer(schemaPath, 'pattern'),
              'schema.invalid_pattern',
              'Schema pattern must be a valid regular expression string.',
            ),
          );
        }
      }
    }

    return _CompiledSchema(
      schemaPath: schemaPath,
      type: type,
      properties: Map<String, _CompiledSchema>.unmodifiable(properties),
      requiredProperties: List<String>.unmodifiable(requiredProperties),
      additionalProperties: additionalProperties,
      items: items,
      anyOf: List<_CompiledSchema>.unmodifiable(anyOf),
      enumValues: enumValues == null
          ? null
          : List<Object?>.unmodifiable(enumValues),
      hasConst: hasConst,
      constValue: constValue,
      minimum: minimum,
      maximum: maximum,
      minLength: minLength,
      maxLength: maxLength,
      pattern: pattern,
      minItems: minItems,
      maxItems: maxItems,
    );
  } finally {
    activeContainers.remove(raw);
  }
}

void _validateNode(
  _CompiledSchema schema,
  Object? value, {
  required String path,
  required int depth,
  required int maxDepth,
  required _ErrorCollector errors,
}) {
  if (errors.saturated) return;
  if (depth > maxDepth) {
    errors.add(
      _valueError(
        path,
        schema.schemaPath,
        'value.max_depth',
        'Argument nesting exceeds the configured limit.',
      ),
    );
    return;
  }

  if (schema.type case final expectedType?) {
    if (!_matchesType(expectedType, value)) {
      errors.add(
        _valueError(
          path,
          _appendPointer(schema.schemaPath, 'type'),
          'value.type',
          'Argument does not match the required JSON type.',
        ),
      );
      return;
    }
  }

  if (schema.enumValues case final enumValues?) {
    if (!enumValues.any((candidate) => _jsonDeepEquals(candidate, value))) {
      errors.add(
        _valueError(
          path,
          _appendPointer(schema.schemaPath, 'enum'),
          'value.enum',
          'Argument is not one of the allowed values.',
        ),
      );
    }
  }
  if (schema.hasConst && !_jsonDeepEquals(schema.constValue, value)) {
    errors.add(
      _valueError(
        path,
        _appendPointer(schema.schemaPath, 'const'),
        'value.const',
        'Argument does not match the required constant.',
      ),
    );
  }

  if (schema.anyOf.isNotEmpty) {
    var matched = false;
    for (final branch in schema.anyOf) {
      final branchErrors = _ErrorCollector(1);
      _validateNode(
        branch,
        value,
        path: path,
        depth: depth + 1,
        maxDepth: maxDepth,
        errors: branchErrors,
      );
      if (!branchErrors.hasErrors) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      errors.add(
        _valueError(
          path,
          _appendPointer(schema.schemaPath, 'anyOf'),
          'value.any_of',
          'Argument does not satisfy any allowed schema branch.',
        ),
      );
    }
  }

  if (value is num) {
    if (schema.minimum case final minimum?) {
      if (value < minimum) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'minimum'),
            'value.minimum',
            'Argument is smaller than the allowed minimum.',
          ),
        );
      }
    }
    if (schema.maximum case final maximum?) {
      if (value > maximum) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'maximum'),
            'value.maximum',
            'Argument is larger than the allowed maximum.',
          ),
        );
      }
    }
  }

  if (value is String) {
    final length = value.runes.length;
    if (schema.minLength case final minLength?) {
      if (length < minLength) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'minLength'),
            'value.min_length',
            'Argument is shorter than the allowed minimum.',
          ),
        );
      }
    }
    if (schema.maxLength case final maxLength?) {
      if (length > maxLength) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'maxLength'),
            'value.max_length',
            'Argument is longer than the allowed maximum.',
          ),
        );
      }
    }
    if (schema.pattern case final pattern?) {
      if (!pattern.hasMatch(value)) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'pattern'),
            'value.pattern',
            'Argument does not match the required pattern.',
          ),
        );
      }
    }
  }

  if (value is List) {
    if (schema.minItems case final minItems?) {
      if (value.length < minItems) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'minItems'),
            'value.min_items',
            'Argument has fewer items than allowed.',
          ),
        );
      }
    }
    if (schema.maxItems case final maxItems?) {
      if (value.length > maxItems) {
        errors.add(
          _valueError(
            path,
            _appendPointer(schema.schemaPath, 'maxItems'),
            'value.max_items',
            'Argument has more items than allowed.',
          ),
        );
      }
    }
    if (schema.items case final itemSchema?) {
      for (var index = 0; index < value.length; index++) {
        _validateNode(
          itemSchema,
          value[index],
          path: _appendPointer(path, '$index'),
          depth: depth + 1,
          maxDepth: maxDepth,
          errors: errors,
        );
        if (errors.saturated) break;
      }
    }
  }

  if (value is Map) {
    final object = <String, Object?>{
      for (final entry in value.entries) entry.key as String: entry.value,
    };
    for (final property in schema.requiredProperties) {
      if (!object.containsKey(property)) {
        errors.add(
          _valueError(
            _appendPointer(path, property),
            _appendPointer(schema.schemaPath, 'required'),
            'value.required',
            'A required property is missing.',
          ),
        );
      }
    }
    for (final property in schema.properties.keys) {
      if (!object.containsKey(property)) continue;
      _validateNode(
        schema.properties[property]!,
        object[property],
        path: _appendPointer(path, property),
        depth: depth + 1,
        maxDepth: maxDepth,
        errors: errors,
      );
    }
    final extraProperties =
        object.keys
            .where((property) => !schema.properties.containsKey(property))
            .toList(growable: false)
          ..sort();
    for (final property in extraProperties) {
      final extraPath = _appendPointer(path, property);
      if (schema.additionalProperties == false) {
        errors.add(
          _valueError(
            extraPath,
            _appendPointer(schema.schemaPath, 'additionalProperties'),
            'value.additional_property',
            'Additional properties are not allowed.',
          ),
        );
      } else if (schema.additionalProperties case final _CompiledSchema rule) {
        _validateNode(
          rule,
          object[property],
          path: extraPath,
          depth: depth + 1,
          maxDepth: maxDepth,
          errors: errors,
        );
      }
      if (errors.saturated) break;
    }
  }
}

void _validateJsonValue(
  Object? value, {
  required String path,
  required int depth,
  required int maxDepth,
  required _TraversalBudget budget,
  required Set<Object> activeContainers,
  required _ErrorCollector errors,
}) {
  if (errors.saturated) return;
  if (depth > maxDepth) {
    errors.add(
      _valueError(
        path,
        '',
        'value.max_depth',
        'Argument nesting exceeds the configured limit.',
      ),
    );
    return;
  }
  if (!budget.take()) {
    errors.add(
      _valueError(
        path,
        '',
        'value.too_complex',
        'Arguments exceed the configured node limit.',
      ),
    );
    return;
  }
  if (value == null || value is String || value is bool) return;
  if (value is num) {
    if (!value.isFinite) {
      errors.add(
        _valueError(
          path,
          '',
          'value.invalid_json',
          'Arguments must contain only finite JSON numbers.',
        ),
      );
    }
    return;
  }
  if (value is List) {
    if (!activeContainers.add(value)) {
      errors.add(
        _valueError(
          path,
          '',
          'value.invalid_json',
          'Arguments must not contain cyclic containers.',
        ),
      );
      return;
    }
    try {
      for (var index = 0; index < value.length; index++) {
        _validateJsonValue(
          value[index],
          path: _appendPointer(path, '$index'),
          depth: depth + 1,
          maxDepth: maxDepth,
          budget: budget,
          activeContainers: activeContainers,
          errors: errors,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return;
  }
  if (value is Map) {
    if (!activeContainers.add(value)) {
      errors.add(
        _valueError(
          path,
          '',
          'value.invalid_json',
          'Arguments must not contain cyclic containers.',
        ),
      );
      return;
    }
    try {
      final entries = <MapEntry<String, Object?>>[];
      for (final entry in value.entries) {
        if (entry.key is! String) {
          errors.add(
            _valueError(
              path,
              '',
              'value.invalid_json',
              'JSON object keys must be strings.',
            ),
          );
          continue;
        }
        entries.add(MapEntry(entry.key as String, entry.value));
      }
      entries.sort((left, right) => left.key.compareTo(right.key));
      for (final entry in entries) {
        _validateJsonValue(
          entry.value,
          path: _appendPointer(path, entry.key),
          depth: depth + 1,
          maxDepth: maxDepth,
          budget: budget,
          activeContainers: activeContainers,
          errors: errors,
        );
      }
    } finally {
      activeContainers.remove(value);
    }
    return;
  }
  errors.add(
    _valueError(
      path,
      '',
      'value.invalid_json',
      'Arguments must contain only JSON values.',
    ),
  );
}

void _validateTextAnnotation(
  Map<String, Object?> schema,
  String keyword,
  String schemaPath,
  _ErrorCollector errors,
) {
  if (schema.containsKey(keyword) && schema[keyword] is! String) {
    errors.add(
      _schemaError(
        _appendPointer(schemaPath, keyword),
        'schema.invalid_annotation',
        'Schema text annotations must be strings.',
      ),
    );
  }
}

void _validateJsonAnnotation(
  Map<String, Object?> schema,
  String keyword,
  String schemaPath,
  int maxDepth,
  _ErrorCollector errors,
) {
  if (!schema.containsKey(keyword)) return;
  if (!_isJsonLiteral(
    schema[keyword],
    maxDepth: maxDepth,
    activeContainers: Set<Object>.identity(),
  )) {
    errors.add(
      _schemaError(
        _appendPointer(schemaPath, keyword),
        'schema.invalid_annotation',
        'Schema annotations must contain only JSON values.',
      ),
    );
  }
}

num? _readFiniteNumber(
  Map<String, Object?> schema,
  String keyword,
  String schemaPath,
  _ErrorCollector errors,
) {
  if (!schema.containsKey(keyword)) return null;
  final value = schema[keyword];
  if (value is! num || !value.isFinite) {
    errors.add(
      _schemaError(
        _appendPointer(schemaPath, keyword),
        'schema.invalid_number_bound',
        'Schema numeric bounds must be finite numbers.',
      ),
    );
    return null;
  }
  return value;
}

int? _readNonNegativeInteger(
  Map<String, Object?> schema,
  String keyword,
  String schemaPath,
  _ErrorCollector errors,
) {
  if (!schema.containsKey(keyword)) return null;
  final value = schema[keyword];
  final normalized = switch (value) {
    int integer => integer,
    double number when number.isFinite && number == number.truncateToDouble() =>
      number.toInt(),
    _ => null,
  };
  if (normalized == null || normalized < 0) {
    errors.add(
      _schemaError(
        _appendPointer(schemaPath, keyword),
        'schema.invalid_size_bound',
        'Schema size bounds must be non-negative integers.',
      ),
    );
    return null;
  }
  return normalized;
}

void _validateOrderedBounds(
  num? minimum,
  num? maximum, {
  required String schemaPath,
  required String maximumKeyword,
  required _ErrorCollector errors,
}) {
  if (minimum == null || maximum == null || minimum <= maximum) return;
  errors.add(
    _schemaError(
      _appendPointer(schemaPath, maximumKeyword),
      'schema.inconsistent_bounds',
      'Schema maximum bounds must not be smaller than minimum bounds.',
    ),
  );
}

bool _matchesType(String type, Object? value) => switch (type) {
  'object' => value is Map,
  'array' => value is List,
  'string' => value is String,
  'number' => value is num && value.isFinite,
  'integer' =>
    value is int ||
        (value is double &&
            value.isFinite &&
            value == value.truncateToDouble()),
  'boolean' => value is bool,
  'null' => value == null,
  _ => false,
};

bool _isJsonLiteral(
  Object? value, {
  required int maxDepth,
  required Set<Object> activeContainers,
  int depth = 0,
}) {
  if (depth > maxDepth) return false;
  if (value == null || value is String || value is bool) return true;
  if (value is num) return value.isFinite;
  if (value is List) {
    if (!activeContainers.add(value)) return false;
    try {
      return value.every(
        (item) => _isJsonLiteral(
          item,
          maxDepth: maxDepth,
          activeContainers: activeContainers,
          depth: depth + 1,
        ),
      );
    } finally {
      activeContainers.remove(value);
    }
  }
  if (value is Map) {
    if (!activeContainers.add(value)) return false;
    try {
      for (final entry in value.entries) {
        if (entry.key is! String ||
            !_isJsonLiteral(
              entry.value,
              maxDepth: maxDepth,
              activeContainers: activeContainers,
              depth: depth + 1,
            )) {
          return false;
        }
      }
      return true;
    } finally {
      activeContainers.remove(value);
    }
  }
  return false;
}

bool _jsonDeepEquals(Object? left, Object? right) {
  if (left is num && right is num) return left == right;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonDeepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonDeepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left.runtimeType != right.runtimeType) return false;
  return left == right;
}

String _appendPointer(String base, String segment) {
  final escaped = segment.replaceAll('~', '~0').replaceAll('/', '~1');
  return '$base/$escaped';
}

ActionSchemaValidationError _schemaError(
  String schemaPath,
  String code,
  String message,
) => ActionSchemaValidationError(
  path: '',
  schemaPath: schemaPath,
  code: code,
  message: message,
);

ActionSchemaValidationError _valueError(
  String path,
  String schemaPath,
  String code,
  String message,
) => ActionSchemaValidationError(
  path: path,
  schemaPath: schemaPath,
  code: code,
  message: message,
);

final class _ErrorCollector {
  _ErrorCollector(this.limit);

  final int limit;
  final List<ActionSchemaValidationError> _errors =
      <ActionSchemaValidationError>[];
  bool truncated = false;

  bool get hasErrors => _errors.isNotEmpty;
  bool get saturated => truncated;
  List<ActionSchemaValidationError> get errors => _errors;

  void add(ActionSchemaValidationError error) {
    if (_errors.length >= limit) {
      truncated = true;
      return;
    }
    _errors.add(error);
  }
}

final class _TraversalBudget {
  _TraversalBudget(this.remaining);

  int remaining;

  bool take() {
    if (remaining <= 0) return false;
    remaining--;
    return true;
  }
}
