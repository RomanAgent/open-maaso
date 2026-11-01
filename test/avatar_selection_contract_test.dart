import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

void main() {
  group('AvatarSelectionAssetOptions', () {
    test('desktop-safe none omits platform from the wire query', () {
      const options = AvatarSelectionAssetOptions.none();

      expect(
        AvatarSelectionContractCodec.currentQueryParameters(
          agentId: ' self ',
          assetOptions: options,
        ),
        <String, String>{'agentId': 'self', 'platformAssets': 'false'},
      );
      expect(options.toPersistenceJson(), <String, Object?>{
        'platformAssets': false,
        'platform': null,
      });
    });

    test('mobile platform is normalized and round-trips strictly', () {
      final options = AvatarSelectionAssetOptions.forPlatform(' IOS ');
      final restored = AvatarSelectionAssetOptions.fromPersistenceJson(
        options.toPersistenceJson(),
      );

      expect(options.platformAssets, isTrue);
      expect(options.platform, 'ios');
      expect(options.toQueryParameters(agentId: 'self'), <String, String>{
        'agentId': 'self',
        'platformAssets': 'true',
        'platform': 'ios',
      });
      expect(restored.hasSameSemanticValue(options), isTrue);
    });

    test('rejects desktop platform assets and non-strict persistence', () {
      expect(
        () => AvatarSelectionAssetOptions.forPlatform('macos'),
        throwsFormatException,
      );
      expect(
        () => AvatarSelectionAssetOptions.fromPersistenceJson(<String, Object?>{
          'platformAssets': false,
          'platform': 'ios',
        }),
        throwsFormatException,
      );
      expect(
        () => AvatarSelectionAssetOptions.fromPersistenceJson(<String, Object?>{
          'platformAssets': false,
          'platform': null,
          'extra': true,
        }),
        throwsFormatException,
      );
    });
  });

  group('AvatarSelectionIdempotencyKey', () {
    test('enforces the backend 8-96 ASCII alphabet', () {
      expect(AvatarSelectionIdempotencyKey.isValid('12345678'), isTrue);
      expect(AvatarSelectionIdempotencyKey.isValid('a' * 96), isTrue);
      for (final invalid in <String>[
        '1234567',
        'a' * 97,
        ' avatar_key',
        'avatar.key',
        'avatar/key',
        'avatar_键值',
      ]) {
        expect(
          AvatarSelectionIdempotencyKey.isValid(invalid),
          isFalse,
          reason: invalid,
        );
        expect(
          () => AvatarSelectionIdempotencyKey.validate(invalid),
          throwsFormatException,
        );
      }
    });

    test('generates unpadded URL-safe keys with secure-compatible entropy', () {
      final deterministic = AvatarSelectionIdempotencyKey.generate(
        random: Random(7),
      );
      final generated = AvatarSelectionIdempotencyKey.generate();

      expect(deterministic, startsWith('avatar_'));
      expect(deterministic, isNot(contains('=')));
      expect(AvatarSelectionIdempotencyKey.isValid(deterministic), isTrue);
      expect(AvatarSelectionIdempotencyKey.isValid(generated), isTrue);
      expect(generated, isNot(deterministic));
    });
  });

  group('AvatarSelectionCommitRequest', () {
    test('keeps clear as an explicit-null modelId on wire and persistence', () {
      final request = _request(
        modelId: null,
        expectedVersion: 7,
        key: 'avatar_clear_01',
      );

      final wire = AvatarSelectionContractCodec.encodeCommitRequest(request);
      expect(wire.containsKey('modelId'), isTrue);
      expect(wire['modelId'], isNull);
      expect(wire, <String, Object?>{
        'agentId': 'self',
        'modelId': null,
        'expectedVersion': 7,
        'idempotencyKey': 'avatar_clear_01',
        'platformAssets': false,
      });

      final persisted = request.toPersistenceJson();
      expect(persisted.containsKey('modelId'), isTrue);
      expect(persisted['modelId'], isNull);
      final restored = AvatarSelectionCommitRequest.fromPersistenceJson(
        persisted,
      );
      expect(restored.hasSameSemanticValue(request), isTrue);
    });

    test('encodes mobile remote request with the exact platform tuple', () {
      final request = _request(
        modelId: 24,
        expectedVersion: 6,
        key: 'avatar_remote_01',
        options: AvatarSelectionAssetOptions.forPlatform('android'),
      );

      expect(request.toWireJson(), <String, Object?>{
        'agentId': 'self',
        'modelId': 24,
        'expectedVersion': 6,
        'idempotencyKey': 'avatar_remote_01',
        'platformAssets': true,
        'platform': 'android',
      });
      expect(
        AvatarSelectionCommitRequest.fromPersistenceJson(
          request.toPersistenceJson(),
        ).hasSameSemanticValue(request),
        isTrue,
      );
    });

    test(
      'accepts the maximum JSON-safe version and rejects its boundaries',
      () {
        expect(
          _request(
            modelId: maxAvatarSelectionJsonSafeInteger,
            expectedVersion: maxAvatarSelectionJsonSafeInteger,
            key: 'avatar_maximum_01',
          ).expectedVersion,
          maxAvatarSelectionJsonSafeInteger,
        );
        expect(
          () => _request(
            modelId: 24,
            expectedVersion: maxAvatarSelectionJsonSafeInteger + 1,
            key: 'avatar_unsafe_01',
          ),
          throwsFormatException,
        );
        expect(
          () => _request(
            modelId: 24,
            expectedVersion: -1,
            key: 'avatar_negative_01',
          ),
          throwsFormatException,
        );
      },
    );

    test(
      'counts agentId by Unicode code points and rejects missing fields',
      () {
        expect(
          _request(
            agentId: '猫' * 96,
            modelId: null,
            expectedVersion: 0,
            key: 'avatar_unicode_01',
          ).agentId.runes.length,
          96,
        );
        expect(
          () => _request(
            agentId: '猫' * 97,
            modelId: null,
            expectedVersion: 0,
            key: 'avatar_unicode_02',
          ),
          throwsFormatException,
        );
        final persistence = _request(
          modelId: null,
          expectedVersion: 0,
          key: 'avatar_missing_01',
        ).toPersistenceJson();
        persistence.remove('modelId');
        expect(
          () => AvatarSelectionCommitRequest.fromPersistenceJson(persistence),
          throwsFormatException,
        );
      },
    );
  });

  group('selection state and persistence', () {
    test('round-trips virtual v0, persisted clear, and remote states', () {
      final states = <AvatarSelectionState>[
        _state(version: 0),
        _state(version: 7, selectionId: 9, selectedAt: _time(8)),
        _state(version: 8, selectionId: 9, modelId: 24, selectedAt: _time(9)),
      ];

      for (final state in states) {
        final restored = AvatarSelectionState.fromPersistenceJson(
          state.toPersistenceJson(),
        );
        expect(restored.hasSameSemanticValue(state), isTrue);
      }
      expect(states[0].toPersistenceJson().containsKey('modelId'), isTrue);
      expect(states[1].modelId, isNull);
      expect(states[2].modelId, 24);
    });

    test('enforces virtual/persisted invariants, UTC, and safe integers', () {
      expect(() => _state(version: 0, modelId: 24), throwsFormatException);
      expect(() => _state(version: 1, selectionId: 9), throwsFormatException);
      expect(
        () => _state(
          version: 1,
          selectionId: 9,
          selectedAt: DateTime(2026, 9, 1, 8),
        ),
        throwsFormatException,
      );
      expect(
        () => _state(version: maxAvatarSelectionJsonSafeInteger + 1),
        throwsFormatException,
      );
      expect(
        () => AvatarSelectionState.fromJson(<String, Object?>{
          ..._state(version: 0).toPersistenceJson(),
          'extra': true,
        }),
        throwsFormatException,
      );
      expect(
        () => AvatarSelectionState.fromJson(<String, Object?>{
          'selectionId': 9,
          'agentId': 'self',
          'modelId': null,
          'version': 1,
          'selectedAt': '2026-09-01T08:00:00',
        }),
        throwsFormatException,
      );
    });
  });

  group('asset descriptor codec', () {
    test(
      'accepts backend omitempty fields and preserves immutable metadata',
      () {
        final minimal = AvatarSelectionAssetDescriptor.fromJson(
          _assetJson(includeOptional: false),
        );
        final full = AvatarSelectionAssetDescriptor.fromJson(
          _assetJson(includeOptional: true, includePlatformAssets: true),
        );

        expect(minimal.assetUrl, isNull);
        expect(minimal.runtimeConfig, isEmpty);
        expect(full.assetUrl, 'https://cdn.example.com/avatar.vrm');
        expect(
          full.platformAssets.keys,
          containsAll(<String>['ios', 'android']),
        );
        expect(
          () => full.runtimeConfig['assetName'] = 'mutated',
          throwsUnsupportedError,
        );
        expect(
          AvatarSelectionAssetDescriptor.fromPersistenceJson(
            full.toPersistenceJson(),
          ).hasSameSemanticValue(full),
          isTrue,
        );
      },
    );

    test('accepts the trusted bundled unity descriptor returned for v0', () {
      final bundled = AvatarSelectionAssetDescriptor.fromJson(
        _bundledAssetJson(),
      );

      expect(bundled.modelKey, 'masso.bundled.agent');
      expect(bundled.assetUrl, 'unity://masso/avatar_agent');
    });

    test('rejects unknown descriptor and nested platform fields', () {
      expect(
        () => AvatarSelectionAssetDescriptor.fromJson(<String, Object?>{
          ..._assetJson(includeOptional: false),
          'unknown': true,
        }),
        throwsFormatException,
      );
      final asset = _assetJson(
        includeOptional: true,
        includePlatformAssets: true,
      );
      final platforms = asset['platformAssets']! as Map<String, Object?>;
      final ios = platforms['ios']! as Map<String, Object?>;
      ios['unknown'] = true;
      expect(
        () => AvatarSelectionAssetDescriptor.fromJson(asset),
        throwsFormatException,
      );
    });

    test('rejects explicit null for backend omitempty descriptor fields', () {
      for (final key in <String>[
        'previewImageUrl',
        'assetUrl',
        'assetSha256',
        'runtimeConfig',
        'platformAssets',
      ]) {
        final json = _assetJson(includeOptional: false)..[key] = null;
        expect(
          () => AvatarSelectionAssetDescriptor.fromJson(json),
          throwsFormatException,
          reason: key,
        );
      }
    });
  });

  group('AvatarSelectionContractCodec current', () {
    test('decodes virtual v0 with the effective bundled descriptor', () {
      final current = AvatarSelectionContractCodec.decodeCurrentResponse(
        _currentEnvelope(selection: _stateJson(version: 0)),
        agentId: 'self',
      );

      expect(current.selection.selectionId, isNull);
      expect(current.selection.modelId, isNull);
      expect(current.selection.version, 0);
      expect(current.selection.selectedAt, isNull);
      expect(current.asset.modelKey, 'masso.bundled.agent');
      expect(current.selectionAvailable, isTrue);
    });

    test(
      'distinguishes remote, explicit clear, and unavailable remote heads',
      () {
        final remote = AvatarSelectionContractCodec.decodeCurrentResponse(
          _currentEnvelope(
            selection: _stateJson(
              version: 7,
              selectionId: 9,
              modelId: 24,
              selectedAt: '2026-09-01T08:00:00Z',
            ),
            asset: _assetJson(includeOptional: true),
          ),
          agentId: 'self',
        );
        final clear = AvatarSelectionContractCodec.decodeCurrentResponse(
          _currentEnvelope(
            selection: _stateJson(
              version: 8,
              selectionId: 9,
              selectedAt: '2026-09-01T09:00:00Z',
            ),
          ),
          agentId: 'self',
        );
        final unavailable = AvatarSelectionContractCodec.decodeCurrentResponse(
          _currentEnvelope(
            selection: _stateJson(
              version: 9,
              selectionId: 9,
              modelId: 24,
              selectedAt: '2026-09-01T10:00:00Z',
            ),
            selectionAvailable: false,
          ),
          agentId: 'self',
        );

        expect(remote.selection.modelId, 24);
        expect(clear.selection.modelId, isNull);
        expect(clear.selection.version, 8);
        expect(unavailable.selection.modelId, 24);
        expect(unavailable.asset.modelKey, 'masso.bundled.agent');
        expect(unavailable.selectionAvailable, isFalse);
      },
    );

    test('requires strict envelope/data shape and contract version', () {
      final unknownEnvelope = _currentEnvelope(
        selection: _stateJson(version: 0),
      )..['extra'] = true;
      expect(
        () => AvatarSelectionContractCodec.decodeCurrentResponse(
          unknownEnvelope,
          agentId: 'self',
        ),
        throwsFormatException,
      );

      final unknownData = _currentEnvelope(selection: _stateJson(version: 0));
      (unknownData['data']! as Map<String, Object?>)['extra'] = true;
      expect(
        () => AvatarSelectionContractCodec.decodeCurrentResponse(
          unknownData,
          agentId: 'self',
        ),
        throwsFormatException,
      );

      final wrongVersion = _currentEnvelope(selection: _stateJson(version: 0));
      (wrongVersion['data']! as Map<String, Object?>)['contractVersion'] = 1;
      expect(
        () => AvatarSelectionContractCodec.decodeCurrentResponse(
          wrongVersion,
          agentId: 'self',
        ),
        throwsFormatException,
      );

      final wrongEnvelopeType = _currentEnvelope(
        selection: _stateJson(version: 0),
      )..['traceId'] = 42;
      expect(
        () => AvatarSelectionContractCodec.decodeCurrentResponse(
          wrongEnvelopeType,
          agentId: 'self',
        ),
        throwsFormatException,
      );
    });

    test('binds current and version conflicts to exact authority', () {
      final crossAgent = _currentEnvelope(
        selection: _stateJson(version: 0, agentId: 'other'),
      );
      expect(
        () => AvatarSelectionContractCodec.decodeCurrentResponse(
          crossAgent,
          agentId: 'self',
        ),
        throwsFormatException,
      );

      final conflict = _envelope(<String, Object?>{
        'currentSelection': <String, Object?>{
          'selection': _stateJson(version: 0),
          'asset': _bundledAssetJson(),
          'selectionAvailable': true,
        },
      });
      expect(
        () => AvatarSelectionContractCodec.decodeConflictCurrentSelection(
          conflict,
          agentId: 'self',
        ),
        throwsFormatException,
      );
      conflict['code'] = 'AVATAR_SELECTION_VERSION_CHANGED';
      final decoded =
          AvatarSelectionContractCodec.decodeConflictCurrentSelection(
            conflict,
            agentId: 'self',
          );
      expect(decoded.selection.version, 0);
    });

    test('rejects impossible effective asset and availability relations', () {
      final cases = <Map<String, Object?>>[
        _currentEnvelope(
          selection: _stateJson(version: 0),
          asset: _assetJson(includeOptional: true),
        ),
        _currentEnvelope(
          selection: _stateJson(
            version: 1,
            selectionId: 9,
            modelId: 24,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
        ),
        _currentEnvelope(
          selection: _stateJson(
            version: 1,
            selectionId: 9,
            modelId: 24,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
          asset: _assetJson(includeOptional: true),
          selectionAvailable: false,
        ),
        _currentEnvelope(
          selection: _stateJson(
            version: 1,
            selectionId: 9,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
          selectionAvailable: false,
        ),
      ];
      for (final envelope in cases) {
        expect(
          () => AvatarSelectionContractCodec.decodeCurrentResponse(
            envelope,
            agentId: 'self',
          ),
          throwsFormatException,
        );
      }
    });
  });

  group('receipt and commit response', () {
    test('validates first remote commit and persistence round-trip', () {
      final request = _request(
        modelId: 24,
        expectedVersion: 0,
        key: 'avatar_first_01',
      );
      final receiptJson = _receiptJson(
        key: request.idempotencyKey,
        previous: _stateJson(version: 0),
        selection: _stateJson(
          version: 1,
          selectionId: 9,
          modelId: 24,
          selectedAt: '2026-09-01T08:00:00Z',
        ),
      );

      final result = AvatarSelectionContractCodec.decodeCommitResponse(
        _envelope(<String, Object?>{
          'contractVersion': avatarSelectionContractVersion,
          'receipt': receiptJson,
          'replayed': false,
        }),
        request: request,
      );
      final restored = AvatarSelectionReceipt.fromPersistenceJson(
        result.receipt.toPersistenceJson(),
      );

      expect(result.replayed, isFalse);
      expect(result.receipt.previousSelection.version, 0);
      expect(result.receipt.selection.version, 1);
      expect(result.receipt.selection.modelId, 24);
      expect(restored.hasSameSemanticValue(result.receipt), isTrue);
    });

    test('validates explicit-null clear and exact replay receipt', () {
      final request = _request(
        modelId: null,
        expectedVersion: 7,
        key: 'avatar_clear_02',
      );
      final result = AvatarSelectionContractCodec.decodeCommitResponse(
        _envelope(<String, Object?>{
          'contractVersion': avatarSelectionContractVersion,
          'receipt': _receiptJson(
            key: request.idempotencyKey,
            previous: _stateJson(
              version: 7,
              selectionId: 9,
              modelId: 24,
              selectedAt: '2026-09-01T08:00:00Z',
            ),
            selection: _stateJson(
              version: 8,
              selectionId: 9,
              selectedAt: '2026-09-01T09:00:00Z',
            ),
            asset: _bundledAssetJson(),
          ),
          'replayed': true,
        }),
        request: request,
      );

      expect(result.replayed, isTrue);
      expect(result.receipt.selection.modelId, isNull);
      expect(
        result.receipt.toPersistenceJson()['selection'],
        containsPair('modelId', null),
      );
    });

    test('rejects wrong receipt key, agent, model, and version relations', () {
      final request = _request(
        modelId: 24,
        expectedVersion: 6,
        key: 'avatar_exact_01',
      );
      final valid = _receiptJson(
        key: request.idempotencyKey,
        previous: _stateJson(
          version: 6,
          selectionId: 9,
          modelId: 18,
          selectedAt: '2026-09-01T07:00:00Z',
        ),
        selection: _stateJson(
          version: 7,
          selectionId: 9,
          modelId: 24,
          selectedAt: '2026-09-01T08:00:00Z',
        ),
      );

      final mutations = <void Function(Map<String, Object?>)>[
        (json) => json['idempotencyKey'] = 'avatar_wrong_01',
        (json) =>
            (json['selection']! as Map<String, Object?>)['agentId'] = 'other',
        (json) => (json['selection']! as Map<String, Object?>)['modelId'] = 18,
        (json) =>
            (json['previousSelection']! as Map<String, Object?>)['version'] = 5,
        (json) => (json['selection']! as Map<String, Object?>)['version'] = 8,
      ];
      for (final mutate in mutations) {
        final receipt = _deepCopy(valid);
        mutate(receipt);
        expect(
          () => AvatarSelectionContractCodec.decodeCommitResponse(
            _envelope(<String, Object?>{
              'contractVersion': avatarSelectionContractVersion,
              'receipt': receipt,
              'replayed': false,
            }),
            request: request,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects missing and unknown receipt/commit fields', () {
      final request = _request(
        modelId: 24,
        expectedVersion: 0,
        key: 'avatar_strict_01',
      );
      final receipt = _receiptJson(
        key: request.idempotencyKey,
        previous: _stateJson(version: 0),
        selection: _stateJson(
          version: 1,
          selectionId: 9,
          modelId: 24,
          selectedAt: '2026-09-01T08:00:00Z',
        ),
      )..['extra'] = true;
      expect(
        () => AvatarSelectionContractCodec.decodeCommitResponse(
          _envelope(<String, Object?>{
            'contractVersion': avatarSelectionContractVersion,
            'receipt': receipt,
            'replayed': false,
          }),
          request: request,
        ),
        throwsFormatException,
      );

      final data = <String, Object?>{
        'contractVersion': avatarSelectionContractVersion,
        'receipt': _deepCopy(receipt)..remove('extra'),
        'replayed': false,
        'extra': true,
      };
      expect(
        () => AvatarSelectionContractCodec.decodeCommitResponse(
          _envelope(data),
          request: request,
        ),
        throwsFormatException,
      );
    });

    test('rejects backend-impossible receipt authority relations', () {
      final request = _request(
        modelId: 24,
        expectedVersion: 6,
        key: 'avatar_invariant_01',
      );
      final base = _receiptJson(
        key: request.idempotencyKey,
        previous: _stateJson(
          version: 6,
          selectionId: 9,
          modelId: 18,
          selectedAt: '2026-09-01T07:00:00Z',
        ),
        selection: _stateJson(
          version: 7,
          selectionId: 9,
          modelId: 24,
          selectedAt: '2026-09-01T08:00:00Z',
        ),
      );
      final invalid = <Map<String, Object?>>[
        _deepCopy(base)..['selectionAvailable'] = false,
        _deepCopy(base)..['asset'] = _bundledAssetJson(),
        _deepCopy(base)
          ..['selection'] = _stateJson(
            version: 7,
            selectionId: 10,
            modelId: 24,
            selectedAt: '2026-09-01T08:00:00Z',
          ),
      ];
      for (final receipt in invalid) {
        expect(
          () => AvatarSelectionContractCodec.decodeCommitResponse(
            _envelope(<String, Object?>{
              'contractVersion': avatarSelectionContractVersion,
              'receipt': receipt,
              'replayed': false,
            }),
            request: request,
          ),
          throwsFormatException,
        );
      }
    });
  });

  test('typed errors keep branching code stable and toString sanitized', () {
    const validation = AvatarSelectionValidationException(
      message: 'presentation text that must not drive control flow',
      traceId: 'trace-1',
      statusCode: 400,
    );
    const unavailable = AvatarSelectionContractUnavailableException(
      statusCode: 410,
    );
    const ambiguous = AvatarSelectionAmbiguousTransportException(
      cause: 'secret transport detail',
    );

    expect(validation.code, 'VALIDATION_ERROR');
    expect(validation.toString(), 'VALIDATION_ERROR');
    expect(unavailable, isA<AvatarSelectionException>());
    expect(ambiguous.toString(), 'AVATAR_SELECTION_TRANSPORT_AMBIGUOUS');
    expect(ambiguous.toString(), isNot(contains('secret')));
  });
}

AvatarSelectionCommitRequest _request({
  String agentId = 'self',
  required int? modelId,
  required int expectedVersion,
  required String key,
  AvatarSelectionAssetOptions options =
      const AvatarSelectionAssetOptions.none(),
}) => AvatarSelectionCommitRequest(
  agentId: agentId,
  modelId: modelId,
  expectedVersion: expectedVersion,
  idempotencyKey: key,
  assetOptions: options,
);

AvatarSelectionState _state({
  int? selectionId,
  int? modelId,
  required int version,
  DateTime? selectedAt,
  String agentId = 'self',
}) => AvatarSelectionState(
  selectionId: selectionId,
  agentId: agentId,
  modelId: modelId,
  version: version,
  selectedAt: selectedAt,
);

DateTime _time(int hour) => DateTime.utc(2026, 9, 1, hour);

Map<String, Object?> _stateJson({
  int? selectionId,
  int? modelId,
  required int version,
  String? selectedAt,
  String agentId = 'self',
}) => <String, Object?>{
  'selectionId': selectionId,
  'agentId': agentId,
  'modelId': modelId,
  'version': version,
  'selectedAt': selectedAt,
};

Map<String, Object?> _assetJson({
  required bool includeOptional,
  bool includePlatformAssets = false,
}) => <String, Object?>{
  'id': 24,
  'modelKey': 'community.creator.v1',
  'displayName': 'Creator',
  'modelSource': 'community',
  'compatibility': <String, Object?>{
    'backends': <Object?>['unity'],
  },
  if (includeOptional) ...<String, Object?>{
    'previewImageUrl': 'https://cdn.example.com/avatar.png',
    'assetUrl': 'https://cdn.example.com/avatar.vrm',
    'assetSha256': 'a' * 64,
    'runtimeConfig': <String, Object?>{'assetName': 'Creator'},
  },
  if (includePlatformAssets)
    'platformAssets': <String, Object?>{
      'ios': _platformAssetJson('ios', 'b'),
      'android': _platformAssetJson('android', 'c'),
    },
};

Map<String, Object?> _platformAssetJson(String platform, String shaDigit) =>
    <String, Object?>{
      'platform': platform,
      'bundleVersion': 'v1',
      'assetUrl': 'https://cdn.example.com/avatar-$platform.bundle',
      'assetSha256': shaDigit * 64,
      'assetBytes': 2048,
      'runtimeConfig': <String, Object?>{'assetName': 'Creator'},
    };

Map<String, Object?> _bundledAssetJson() => <String, Object?>{
  'id': 1,
  'modelKey': 'masso.bundled.agent',
  'displayName': 'Agent',
  'modelSource': 'official',
  'assetUrl': 'unity://masso/avatar_agent',
  'assetSha256':
      '82e306d47cd720b6ba121bfab08f07de5cb50e8046e34bd52d959b55012240cd',
  'runtimeConfig': <String, Object?>{'avatar': 'agent', 'assetName': 'Agent'},
  'compatibility': <String, Object?>{
    'backends': <Object?>['unity'],
  },
};

Map<String, Object?> _currentEnvelope({
  required Map<String, Object?> selection,
  Map<String, Object?>? asset,
  bool selectionAvailable = true,
}) => _envelope(<String, Object?>{
  'contractVersion': avatarSelectionContractVersion,
  'selection': selection,
  'asset': asset ?? _bundledAssetJson(),
  'selectionAvailable': selectionAvailable,
});

Map<String, Object?> _receiptJson({
  required String key,
  required Map<String, Object?> previous,
  required Map<String, Object?> selection,
  Map<String, Object?>? asset,
}) => <String, Object?>{
  'idempotencyKey': key,
  'previousSelection': previous,
  'selection': selection,
  'asset': asset ?? _assetJson(includeOptional: true),
  'selectionAvailable': true,
};

Map<String, Object?> _envelope(Object? data) => <String, Object?>{
  'code': 'OK',
  'message': 'success',
  'traceId': 'trace-avatar-selection',
  'data': data,
};

Map<String, Object?> _deepCopy(Map<String, Object?> value) {
  Object? copy(Object? source) {
    if (source is Map) {
      return <String, Object?>{
        for (final entry in source.entries)
          entry.key as String: copy(entry.value),
      };
    }
    if (source is List) return <Object?>[for (final item in source) copy(item)];
    return source;
  }

  return copy(value)! as Map<String, Object?>;
}
