import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';

void main() {
  test('pins exact immutable Moonshine Tiny EN artifact contract', () {
    final model = DesktopLocalAsrModelCatalog.moonshineTinyEnInt8;

    expect(model.id, 'moonshine-tiny-en-int8-bf2b762c');
    expect(model.engine, DesktopLocalAsrEngine.moonshineV1);
    expect(model.sourceRevision, 'bf2b762c076d8ea61e2af0b3851c9564fb77552e');
    expect(model.licenseId, 'MIT');
    expect(model.requiresLicenseAcknowledgement, isFalse);
    expect(model.requiresLegalApproval, isFalse);
    expect(model.userImportOnly, isTrue);
    expect(model.locales, <String>['en']);
    expect(_fileContract(model), <String, Object>{
      'cached_decode.int8.onnx': <Object>[
        45264830,
        '2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6',
      ],
      'encode.int8.onnx': <Object>[
        18249187,
        '8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb',
      ],
      'preprocess.onnx': <Object>[
        6800738,
        'f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e',
      ],
      'tokens.txt': <Object>[
        436688,
        '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea',
      ],
      'uncached_decode.int8.onnx': <Object>[
        53216096,
        '216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41',
      ],
    });
  });

  test('pins SenseVoice behind acknowledgement and legal approval', () {
    final model = DesktopLocalAsrModelCatalog.senseVoiceInt8;

    expect(model.id, 'sense-voice-int8-2365baea');
    expect(model.engine, DesktopLocalAsrEngine.senseVoice);
    expect(model.sourceRevision, '2365baeacb507f821a0c8120fcee3d484dba7a07');
    expect(model.requiresLicenseAcknowledgement, isTrue);
    expect(model.requiresLegalApproval, isTrue);
    expect(model.userImportOnly, isTrue);
    expect(model.locales, <String>['zh', 'yue', 'en', 'ja', 'ko']);
    expect(
      model.licenseReference,
      contains('58830eca4012644aac0c3218c3ccc7d98f003fda/MODEL_LICENSE'),
    );
    expect(_fileContract(model), <String, Object>{
      'model.int8.onnx': <Object>[
        239233841,
        'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
      ],
      'tokens.txt': <Object>[
        315894,
        'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
      ],
    });
  });

  test('production selection excludes every legal-gated descriptor', () {
    expect(
      DesktopLocalAsrModelCatalog.productionSelectableModelPacks
          .map((pack) => pack.id)
          .toList(growable: false),
      <String>[DesktopLocalAsrModelCatalog.moonshineTinyEnInt8.id],
    );
    expect(
      DesktopLocalAsrModelCatalog.productionSelectableModelPacks.any(
        (pack) => pack.id == DesktopLocalAsrModelCatalog.senseVoiceInt8.id,
      ),
      isFalse,
    );
  });

  test('descriptor rejects traversal and duplicate file names', () {
    expect(
      () => DesktopLocalAsrModelFileDescriptor(
        name: '../model.onnx',
        byteLength: 1,
        sha256Digest: 'a' * 64,
      ),
      throwsArgumentError,
    );
    expect(
      () => _descriptor(
        files: <DesktopLocalAsrModelFileDescriptor>[
          _file('model.onnx', <int>[1]),
          _file('model.onnx', <int>[2]),
        ],
      ),
      throwsArgumentError,
    );
  });
}

Map<String, Object> _fileContract(DesktopLocalAsrModelDescriptor model) =>
    <String, Object>{
      for (final file in model.files)
        file.name: <Object>[file.byteLength, file.sha256Digest],
    };

DesktopLocalAsrModelDescriptor _descriptor({
  required Iterable<DesktopLocalAsrModelFileDescriptor> files,
}) => DesktopLocalAsrModelDescriptor(
  id: 'tiny-test-model',
  displayName: 'Tiny test model',
  engine: DesktopLocalAsrEngine.senseVoice,
  sourceRepository: 'https://example.com/model',
  sourceRevision: 'a' * 40,
  licenseId: 'Test',
  licenseReference: 'https://example.com/license',
  requiresLicenseAcknowledgement: false,
  requiresLegalApproval: false,
  locales: const <String>['en'],
  files: files,
);

DesktopLocalAsrModelFileDescriptor _file(String name, List<int> bytes) =>
    DesktopLocalAsrModelFileDescriptor(
      name: name,
      byteLength: bytes.length,
      sha256Digest: _digest(bytes),
    );

String _digest(List<int> bytes) {
  // The duplicate-file test does not depend on exact content hashes.
  const hex = '0123456789abcdef';
  final seed = bytes.fold<int>(0, (value, byte) => (value + byte) & 15);
  return List<String>.generate(64, (index) => hex[(seed + index) & 15]).join();
}
