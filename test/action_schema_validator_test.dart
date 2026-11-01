import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_schema_validator.dart';

void main() {
  const validator = ActionSchemaValidator();

  group('ActionSchemaValidator supported subset', () {
    test('accepts nested object, array, and typed additional properties', () {
      final result = validator.validate(
        schema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'title': <String, Object?>{'type': 'string', 'maxLength': 12},
            'blocks': <String, Object?>{
              'type': 'array',
              'maxItems': 2,
              'items': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'text': <String, Object?>{'type': 'string', 'maxLength': 20},
                  'visible': <String, Object?>{'type': 'boolean'},
                },
                'required': <String>['text'],
                'additionalProperties': false,
              },
            },
            'headers': <String, Object?>{
              'type': 'object',
              'additionalProperties': <String, Object?>{'type': 'string'},
            },
          },
          'required': <String>['title', 'blocks'],
          'additionalProperties': false,
        },
        value: <String, Object?>{
          'title': 'Morning',
          'blocks': <Object?>[
            <String, Object?>{'text': 'Hello', 'visible': true},
          ],
          'headers': <String, Object?>{'Accept': 'application/json'},
        },
      );

      expect(result.isValid, isTrue);
      expect(result.schemaValid, isTrue);
      expect(result.errors, isEmpty);
      expect(result.truncated, isFalse);
    });

    test('supports root arrays, integer semantics, and numeric bounds', () {
      final valid = validator.validate(
        schema: <String, Object?>{
          'type': 'array',
          'minItems': 1,
          'maxItems': 3,
          'items': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 3,
          },
        },
        value: <Object?>[1, 2.0, 3],
      );
      final invalid = validator.validate(
        schema: <String, Object?>{
          'type': 'array',
          'minItems': 1,
          'maxItems': 3,
          'items': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 3,
          },
        },
        value: <Object?>[0, 1.5, 4, 2],
      );

      expect(valid.isValid, isTrue);
      expect(
        invalid.errors.map((error) => (error.path, error.code)),
        containsAll(<(String, String)>[
          ('', 'value.max_items'),
          ('/0', 'value.minimum'),
          ('/1', 'value.type'),
          ('/2', 'value.maximum'),
        ]),
      );
    });

    test('reports required, type, and additional-property errors stably', () {
      final schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'b': <String, Object?>{'type': 'string'},
        },
        'required': <String>['z', 'a'],
        'additionalProperties': false,
      };
      final value = <String, Object?>{'d': 1, 'b': 2, 'c': 3};

      final first = validator.validate(schema: schema, value: value);
      final second = validator.validate(schema: schema, value: value);
      final firstShape = first.errors
          .map((error) => (error.path, error.schemaPath, error.code))
          .toList();
      final secondShape = second.errors
          .map((error) => (error.path, error.schemaPath, error.code))
          .toList();

      expect(firstShape, <(String, String, String)>[
        ('/a', '/required', 'value.required'),
        ('/z', '/required', 'value.required'),
        ('/b', '/properties/b/type', 'value.type'),
        ('/c', '/additionalProperties', 'value.additional_property'),
        ('/d', '/additionalProperties', 'value.additional_property'),
      ]);
      expect(secondShape, firstShape);
    });

    test('validates every unknown property against additionalProperties', () {
      const schema = <String, Object?>{
        'type': 'object',
        'additionalProperties': <String, Object?>{
          'type': 'string',
          'maxLength': 3,
        },
      };

      expect(
        validator
            .validate(
              schema: schema,
              value: <String, Object?>{'A': 'ok', 'B': 'yes'},
            )
            .isValid,
        isTrue,
      );
      final invalid = validator.validate(
        schema: schema,
        value: <String, Object?>{'A': 7, 'B': 'long'},
      );

      expect(
        invalid.errors.map((error) => (error.path, error.code)),
        <(String, String)>[('/A', 'value.type'), ('/B', 'value.max_length')],
      );
    });

    test('supports the anyOf form used by Creator actions', () {
      const schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'draftId': <String, Object?>{'type': 'string'},
          'title': <String, Object?>{'type': 'string'},
          'outline': <String, Object?>{'type': 'string'},
          'body': <String, Object?>{'type': 'string'},
        },
        'anyOf': <Object?>[
          <String, Object?>{
            'required': <String>['draftId'],
          },
          <String, Object?>{
            'required': <String>['title', 'outline', 'body'],
          },
        ],
        'additionalProperties': false,
      };

      expect(
        validator
            .validate(
              schema: schema,
              value: <String, Object?>{'draftId': 'draft_1'},
            )
            .isValid,
        isTrue,
      );
      expect(
        validator
            .validate(
              schema: schema,
              value: <String, Object?>{
                'title': 'T',
                'outline': 'O',
                'body': 'B',
              },
            )
            .isValid,
        isTrue,
      );

      final invalid = validator.validate(
        schema: schema,
        value: const <String, Object?>{'title': 'only one field'},
      );
      expect(invalid.errors, hasLength(1));
      expect(invalid.errors.single.code, 'value.any_of');
      expect(invalid.errors.single.schemaPath, '/anyOf');
    });

    test('supports enum, const, null, Unicode length, and pattern', () {
      expect(
        validator
            .validate(
              schema: const <String, Object?>{
                'enum': <Object?>[
                  <String, Object?>{
                    'mode': <Object?>['safe', 1],
                  },
                ],
              },
              value: <String, Object?>{
                'mode': <Object?>['safe', 1.0],
              },
            )
            .isValid,
        isTrue,
      );
      expect(
        validator
            .validate(
              schema: const <String, Object?>{'const': null},
              value: null,
            )
            .isValid,
        isTrue,
      );
      expect(
        validator
            .validate(
              schema: const <String, Object?>{'type': 'null'},
              value: false,
            )
            .errors
            .single
            .code,
        'value.type',
      );
      expect(
        validator
            .validate(
              schema: const <String, Object?>{'type': 'string', 'maxLength': 1},
              value: '🙂',
            )
            .isValid,
        isTrue,
      );
      expect(
        validator
            .validate(
              schema: <String, Object?>{
                'type': 'string',
                'pattern': r'^[A-Za-z0-9_-]+$',
              },
              value: 'not allowed!',
            )
            .errors
            .single
            .code,
        'value.pattern',
      );
    });

    test('escapes JSON Pointer paths and never echoes rejected values', () {
      const secret = 'secret-user-value';
      final result = validator.validate(
        schema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'a/b': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                '~token': <String, Object?>{'type': 'string', 'maxLength': 3},
              },
            },
          },
        },
        value: const <String, Object?>{
          'a/b': <String, Object?>{'~token': secret},
        },
      );

      expect(result.errors.single.path, '/a~1b/~0token');
      expect(
        result.errors.single.schemaPath,
        '/properties/a~1b/properties/~0token/maxLength',
      );
      expect(result.errors.single.message, isNot(contains(secret)));
      expect(result.errors.single.message.length, lessThan(160));
    });
  });

  group('ActionSchemaValidator fails closed', () {
    test('rejects malformed and unsupported schemas before values', () {
      final cases = <(Object?, String)>[
        ('not a schema', 'schema.expected_object'),
        (<String, Object?>{'oneOf': <Object?>[]}, 'schema.unsupported_keyword'),
        (
          <String, Object?>{
            'type': <String>['string', 'null'],
          },
          'schema.invalid_type',
        ),
        (
          <String, Object?>{'properties': <Object?>[]},
          'schema.invalid_properties',
        ),
        (
          <String, Object?>{
            'required': <String>['same', 'same'],
          },
          'schema.invalid_required',
        ),
        (
          <String, Object?>{'additionalProperties': 1},
          'schema.invalid_additional_properties',
        ),
        (<String, Object?>{'anyOf': <Object?>[]}, 'schema.invalid_any_of'),
        (
          <String, Object?>{
            'enum': <Object?>[1, 1.0],
          },
          'schema.invalid_enum',
        ),
        (<String, Object?>{'pattern': '['}, 'schema.invalid_pattern'),
        (<String, Object?>{'maxItems': -1}, 'schema.invalid_size_bound'),
        (
          <String, Object?>{'minimum': double.nan},
          'schema.invalid_number_bound',
        ),
        (
          <String, Object?>{'minimum': 2, 'maximum': 1},
          'schema.inconsistent_bounds',
        ),
        (
          <String, Object?>{'minLength': 2, 'maxLength': 1},
          'schema.inconsistent_bounds',
        ),
        (
          <String, Object?>{'minItems': 2, 'maxItems': 1},
          'schema.inconsistent_bounds',
        ),
        (<String, Object?>{'items': true}, 'schema.expected_object'),
      ];

      for (final (schema, expectedCode) in cases) {
        final result = validator.validate(schema: schema, value: null);
        expect(result.schemaValid, isFalse, reason: '$schema');
        expect(result.isValid, isFalse, reason: '$schema');
        expect(
          result.errors.map((error) => error.code),
          contains(expectedCode),
          reason: '$schema',
        );
      }
    });

    test('validates unused child schemas instead of bypassing them', () {
      final result = validator.validate(
        schema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'optional': <String, Object?>{
              'type': 'string',
              'format': 'made-up-format',
            },
          },
        },
        value: const <String, Object?>{},
      );

      expect(result.schemaValid, isFalse);
      expect(result.errors.single.code, 'schema.unsupported_keyword');
      expect(result.errors.single.schemaPath, '/properties/optional/format');
    });

    test('rejects non-JSON and cyclic argument values', () {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);

      final nonJson = validator.validate(
        schema: const <String, Object?>{},
        value: <Object?, Object?>{1: 'not a JSON object'},
      );
      final cyclicResult = validator.validate(
        schema: const <String, Object?>{},
        value: cyclic,
      );

      expect(nonJson.schemaValid, isTrue);
      expect(nonJson.errors.single.code, 'value.invalid_json');
      expect(cyclicResult.errors.single.code, 'value.invalid_json');
    });

    test('bounds errors and exposes an immutable structured result', () {
      const bounded = ActionSchemaValidator(maxErrors: 2);
      final result = bounded.validate(
        schema: const <String, Object?>{
          'type': 'object',
          'additionalProperties': false,
        },
        value: const <String, Object?>{'d': 4, 'c': 3, 'b': 2, 'a': 1},
      );

      expect(result.errors, hasLength(2));
      expect(result.errors.map((error) => error.path), <String>['/a', '/b']);
      expect(
        () => result.errors.add(
          const ActionSchemaValidationError(
            path: '',
            schemaPath: '',
            code: 'test',
            message: 'test',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(result.toJson(), <String, Object?>{
        'valid': false,
        'schemaValid': true,
        'truncated': true,
        'errors': <Map<String, String>>[
          <String, String>{
            'path': '/a',
            'schemaPath': '/additionalProperties',
            'code': 'value.additional_property',
            'message': 'Additional properties are not allowed.',
          },
          <String, String>{
            'path': '/b',
            'schemaPath': '/additionalProperties',
            'code': 'value.additional_property',
            'message': 'Additional properties are not allowed.',
          },
        ],
      });
    });
  });
}
