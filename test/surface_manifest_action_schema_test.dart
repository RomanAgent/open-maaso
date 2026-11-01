import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

void main() {
  group('Surface manifest v1 compatibility', () {
    test('round-trips the legacy wire format without adding a version', () {
      final raw = <String, Object?>{
        'events': <Object?>[
          <String, Object?>{
            'name': 'star.tap',
            'schema': <String, Object?>{'id': 'string'},
          },
        ],
        'actions': <Object?>[
          <String, Object?>{
            'name': 'star.spawn',
            'schema': <String, Object?>{
              'speed': 'number',
              'legacy': 'unknown_type',
            },
          },
        ],
        'instructions': 'Keep reactions brief.',
      };

      final manifest = SurfaceManifest.fromSpec(raw);

      expect(manifest.schemaVersion, 1);
      expect(manifest.toJson(), raw);
      expect(manifest.diagnoseContract(), isEmpty);
      expect(
        manifest.action('star.spawn')?.effectiveRisk(SurfaceEntryKind.action),
        ActionRisk.localMutation,
      );
      expect(
        manifest.event('star.tap')?.effectiveRisk(SurfaceEntryKind.event),
        ActionRisk.readOnly,
      );
      expect(
        manifest
            .action('star.spawn')
            ?.effectiveConsequencePolicy(SurfaceEntryKind.action),
        ActionConsequencePolicy.reversible,
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'speed': 2,
          'legacy': <String, Object?>{'still': 'accepted'},
          'extra': true,
        }),
        isNull,
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'speed': 'fast',
        }),
        contains('invalid_arguments'),
      );
      expect(manifest.validateAction('star.spawn', null), isNull);
      expect(manifest.validateEvent('star.tap', null), isNull);
    });

    test('preserves an explicitly declared legacy version', () {
      final manifest = SurfaceManifest.fromSpec(const <String, Object?>{
        'schemaVersion': 1,
        'events': <Object?>[],
        'actions': <Object?>[],
      });

      expect(manifest.toJson(), <String, Object?>{
        'schemaVersion': 1,
        'events': <Object?>[],
        'actions': <Object?>[],
      });
    });
  });

  group('Surface manifest v2 schema contract', () {
    test('round-trips canonical schemas, risk, and consequence metadata', () {
      final raw = _validV2Spec();

      final manifest = SurfaceManifest.fromSpec(raw);

      expect(manifest.schemaVersion, 2);
      expect(manifest.toJson(), raw);
      expect(manifest.diagnoseContract(), isEmpty);
      expect(manifest.toPromptText('surface-v2'), contains('localMutation'));
      expect(manifest.toPromptText('surface-v2'), contains('prepareOnly'));
    });

    test('enforces nested required, enum, and additional properties', () {
      final manifest = SurfaceManifest.fromSpec(_validV2Spec());

      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'star': <String, Object?>{'kind': 'gold', 'speed': 2},
        }),
        isNull,
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'star': <String, Object?>{'speed': 2},
        }),
        contains('invalid_arguments'),
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'star': <String, Object?>{'kind': 'purple', 'speed': 2},
        }),
        contains('invalid_arguments'),
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'star': <String, Object?>{'kind': 'gold', 'speed': 2, 'extra': true},
        }),
        contains('invalid_arguments'),
      );
      expect(
        manifest.validateEvent('star.tapped', <String, Object?>{'id': 's1'}),
        isNull,
      );
    });

    test('snapshots nested schemas against later mutation', () {
      final kindRule = <String, Object?>{
        'type': 'string',
        'enum': <String>['gold'],
      };
      final properties = <String, Object?>{'kind': kindRule};
      final rawSchema = <String, Object?>{
        'type': 'object',
        'properties': properties,
        'required': <String>['kind'],
        'additionalProperties': false,
      };
      final entry = SurfaceEntry.v2(
        name: 'star.choose',
        schema: rawSchema,
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
      );
      final manifest = SurfaceManifest.v2(actions: <SurfaceEntry>[entry]);

      (kindRule['enum']! as List<String>).add('purple');
      properties['extra'] = const <String, Object?>{'type': 'boolean'};
      rawSchema['additionalProperties'] = true;

      expect(
        manifest.validateAction('star.choose', <String, Object?>{
          'kind': 'purple',
          'extra': true,
        }),
        contains('invalid_arguments'),
      );
      expect(manifest.diagnoseContract(), isEmpty);
    });

    test('bounds snapshots for over-wide maps and lists', () {
      final wideProperties = <String, Object?>{
        for (var index = 0; index < 5000; index += 1)
          'field$index': const <String, Object?>{'type': 'string'},
      };
      final manifest = _manifestWithAction(
        schema: <String, Object?>{
          'type': 'object',
          'properties': wideProperties,
          'examples': <Object?>[
            for (var index = 0; index < 5000; index += 1) index,
          ],
        },
      );

      final action = (manifest.toJson()['actions']! as List<Object?>).single;
      final schema = (action! as Map<String, Object?>)['schema']! as Map;
      final snapshottedProperties = schema['properties']! as Map;
      final listManifest = _manifestWithAction(
        schema: <String, Object?>{
          'type': 'object',
          'examples': <Object?>[
            for (var index = 0; index < 5000; index += 1) index,
          ],
        },
      );
      final listAction =
          (listManifest.toJson()['actions']! as List<Object?>).single;
      final listSchema =
          (listAction! as Map<String, Object?>)['schema']! as Map;
      final snapshottedExamples = listSchema['examples']! as List<Object?>;

      expect(schema['maaso.invalid_schema_snapshot'], isTrue);
      expect(snapshottedProperties.length, lessThan(4096));
      expect(manifest.diagnoseContract(), isNotEmpty);
      expect(listSchema['maaso.invalid_schema_snapshot'], isTrue);
      expect(snapshottedExamples.length, lessThan(4096));
      expect(listManifest.diagnoseContract(), isNotEmpty);
    });

    test('omits non-validation annotations from the agent prompt', () {
      const annotationSecret = 'annotation-must-not-reach-the-prompt';
      final manifest = _manifestWithAction(
        schema: const <String, Object?>{
          'type': 'object',
          'description': annotationSecret,
          'properties': <String, Object?>{
            'value': <String, Object?>{
              'type': 'string',
              'title': annotationSecret,
              'default': annotationSecret,
              'examples': <Object?>[annotationSecret],
              r'$comment': annotationSecret,
            },
          },
        },
      );

      final prompt = manifest.toPromptText('annotation-test');

      expect(prompt, isNot(contains(annotationSecret)));
      expect(prompt, contains('"value":{"type":"string"}'));
    });

    test('redacts rejected values from validation errors', () {
      const secret = 'private-surface-payload';
      final manifest = SurfaceManifest.fromSpec(_validV2Spec());

      final error = manifest.validateAction('star.spawn', <String, Object?>{
        'star': <String, Object?>{'kind': secret, 'speed': 2},
      });

      expect(error, contains('invalid_arguments'));
      expect(error, isNot(contains(secret)));
    });
  });

  group('Surface manifest v2 admission policy', () {
    test('rejects malformed, non-object, and unsupported schemas', () {
      final malformed = _manifestWithAction(
        schema: const <String, Object?>{'type': 'object', 'unsupported': true},
      );
      final nonObject = _manifestWithAction(
        schema: const <String, Object?>{'type': 'string'},
      );

      expect(
        malformed.diagnoseContract(),
        contains('surface.manifest.actions[0].schema_invalid'),
      );
      expect(
        malformed.validateAction('contract.action', const <String, Object?>{}),
        contains('host_contract_invalid'),
      );
      expect(
        nonObject.diagnoseContract(),
        contains('surface.manifest.actions[0].schema_not_object'),
      );
      expect(
        nonObject.validateAction('contract.action', const <String, Object?>{}),
        contains('host_contract_invalid'),
      );
      expect(
        _manifestWithAction(
          schema: const <String, Object?>{},
        ).validateAction('contract.action', const <String, Object?>{}),
        contains('host_contract_invalid'),
      );
    });

    test('rejects unsafe action and event authority', () {
      final unsafeAction = _manifestWithAction(risk: ActionRisk.externalWrite);
      final exactCommit = _manifestWithAction(
        consequencePolicy: ActionConsequencePolicy.exactTextCommit,
      );
      final unsafeEvent = SurfaceManifest.v2(
        events: <SurfaceEntry>[
          SurfaceEntry.v2(
            name: 'host.write',
            schema: const <String, Object?>{'type': 'object'},
            risk: ActionRisk.localMutation,
            consequencePolicy: ActionConsequencePolicy.reversible,
          ),
        ],
      );

      expect(
        unsafeAction.diagnoseContract(),
        contains('surface.manifest.actions[0].unsafe_policy'),
      );
      expect(
        unsafeAction.validateAction(
          'contract.action',
          const <String, Object?>{},
        ),
        contains('host_contract_invalid'),
      );
      expect(
        exactCommit.diagnoseContract(),
        contains('surface.manifest.actions[0].unsafe_policy'),
      );
      expect(
        unsafeEvent.diagnoseContract(),
        contains('surface.manifest.events[0].unsafe_policy'),
      );
    });

    test('rejects untrusted regular expressions before payload validation', () {
      final manifest = _manifestWithAction(
        schema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'value': <String, Object?>{
              'type': 'string',
              'pattern': r'^(a*|b)*c',
            },
          },
        },
      );

      expect(
        manifest.diagnoseContract(),
        contains('surface.manifest.actions[0].unsafe_pattern'),
      );
      expect(
        manifest.validateAction('contract.action', <String, Object?>{
          'value': 'aaaaaaaaaaaaaaaaaaaaaaaaaa',
        }),
        contains('host_contract_invalid'),
      );
    });

    test('rejects invalid names, duplicates, and oversized collections', () {
      final duplicate = SurfaceManifest.v2(
        actions: <SurfaceEntry>[
          _safeEntry('duplicate'),
          _safeEntry('duplicate'),
          _safeEntry('contains space'),
        ],
      );
      final oversized = SurfaceManifest.v2(
        actions: List<SurfaceEntry>.generate(
          SurfaceManifest.maxEntriesPerKind + 1,
          (index) => _safeEntry('action.$index'),
        ),
      );

      expect(
        duplicate.diagnoseContract(),
        contains('surface.manifest.actions[1].duplicate_name'),
      );
      expect(
        duplicate.diagnoseContract(),
        contains('surface.manifest.actions[2].invalid_name'),
      );
      expect(
        oversized.diagnoseContract(),
        contains('surface.manifest.actions.too_many'),
      );
    });

    test('rejects unsupported manifest versions', () {
      final manifest = SurfaceManifest.fromSpec(<String, Object?>{
        ..._validV2Spec(),
        'schemaVersion': 3,
      });

      expect(
        manifest.diagnoseContract(),
        contains('surface.manifest.unsupported_schema_version'),
      );
      expect(
        manifest.validateAction('star.spawn', <String, Object?>{
          'star': <String, Object?>{'kind': 'gold', 'speed': 2},
        }),
        contains('host_contract_invalid'),
      );
    });

    test('rejects malformed v2 collection and instruction shapes', () {
      final manifest = SurfaceManifest.fromSpec(const <String, Object?>{
        'schemaVersion': 2,
        'events': <String, Object?>{},
        'actions': <Object?>[null, 7],
        'instructions': 42,
      });

      expect(
        manifest.diagnoseContract(),
        containsAll(<String>[
          'surface.manifest.events.expected_array',
          'surface.manifest.actions[0].expected_object',
          'surface.manifest.actions[1].expected_object',
          'surface.manifest.instructions_expected_string',
        ]),
      );

      final reparsed = SurfaceManifest.fromSpec(manifest.toJson());
      expect(
        reparsed.diagnoseContract(),
        contains('surface.manifest.invalid_contract_marker'),
      );
      expect(reparsed.toJson()['_maasoInvalidContract'], isTrue);
    });

    test('rejects manifests whose combined schemas exceed prompt budget', () {
      final annotation = List<String>.filled(28 * 1024, 'x').join();
      final manifest = SurfaceManifest.v2(
        actions: List<SurfaceEntry>.generate(
          5,
          (index) => SurfaceEntry.v2(
            name: 'budget.$index',
            schema: <String, Object?>{
              'type': 'object',
              'description': annotation,
            },
            risk: ActionRisk.localMutation,
            consequencePolicy: ActionConsequencePolicy.reversible,
          ),
        ),
      );

      expect(
        manifest.diagnoseContract(),
        contains('surface.manifest.schema_budget_exceeded'),
      );
      expect(
        manifest.diagnoseContract(),
        isNot(contains('surface.manifest.actions[0].schema_too_large')),
      );
    });

    test('show validation inherits manifest contract failures', () {
      final project = _project(
        _manifestWithAction(risk: ActionRisk.destructive),
      );

      expect(
        SurfaceProjectValidator.diagnoseForShow(project),
        contains('surface.manifest.actions[0].unsafe_policy'),
      );
      expect(
        () => SurfaceProjectValidator.validateForShow(project),
        throwsA(isA<SurfaceProjectValidationException>()),
      );
      expect(
        SurfaceProjectValidator.diagnoseForShow(
          _project(
            const SurfaceManifest(
              actions: <SurfaceEntry>[
                SurfaceEntry('legacy.action', <String, String>{
                  'value': 'number',
                }),
              ],
            ),
          ),
        ),
        isEmpty,
      );
    });
  });
}

Map<String, Object?> _validV2Spec() => <String, Object?>{
  'schemaVersion': 2,
  'events': <Object?>[
    <String, Object?>{
      'name': 'star.tapped',
      'schema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{'type': 'string', 'minLength': 1},
        },
        'required': <String>['id'],
        'additionalProperties': false,
      },
      'risk': 'readOnly',
      'consequencePolicy': 'reversible',
    },
  ],
  'actions': <Object?>[
    <String, Object?>{
      'name': 'star.spawn',
      'schema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'star': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'kind': <String, Object?>{
                'type': 'string',
                'enum': <String>['gold', 'silver'],
              },
              'speed': <String, Object?>{
                'type': 'number',
                'minimum': 0,
                'maximum': 10,
              },
            },
            'required': <String>['kind', 'speed'],
            'additionalProperties': false,
          },
        },
        'required': <String>['star'],
        'additionalProperties': false,
      },
      'risk': 'localMutation',
      'consequencePolicy': 'prepareOnly',
    },
  ],
  'instructions': 'Animate locally and keep narration short.',
};

SurfaceManifest _manifestWithAction({
  Map<String, Object?> schema = const <String, Object?>{'type': 'object'},
  ActionRisk risk = ActionRisk.localMutation,
  ActionConsequencePolicy consequencePolicy =
      ActionConsequencePolicy.reversible,
}) => SurfaceManifest.v2(
  actions: <SurfaceEntry>[
    SurfaceEntry.v2(
      name: 'contract.action',
      schema: schema,
      risk: risk,
      consequencePolicy: consequencePolicy,
    ),
  ],
);

SurfaceEntry _safeEntry(String name) => SurfaceEntry.v2(
  name: name,
  schema: const <String, Object?>{'type': 'object'},
  risk: ActionRisk.localMutation,
  consequencePolicy: ActionConsequencePolicy.reversible,
);

SurfaceProject _project(SurfaceManifest manifest) => SurfaceProject(
  id: 'manifest-contract',
  title: 'Manifest Contract',
  kind: SurfaceKind.card,
  rendering: SurfaceRendering.dom,
  html: '<main>Ready</main>',
  css: '',
  js: '',
  transparent: false,
  placement: const SurfacePlacement(x: 0, y: 0, width: 1, height: 1),
  manifest: manifest,
  backend: const <String, Object?>{},
  revisions: const <SurfaceRevision>[],
);
