import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/avatar_voice_service.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';

import 'helpers/bundled_matt_revision_fixture.dart';

Map<String, dynamic> mattDescriptor({int id = 44}) => {
  'id': id,
  'modelKey': BundledAvatarContract.mattModelKey,
  'displayName': 'Matt',
  'modelSource': 'official',
  'assetUrl': BundledAvatarContract.mattAssetUrl,
  'assetSha256': BundledAvatarContract.mattAssetSha256,
  'runtimeConfig': Map<String, dynamic>.from(
    BundledAvatarContract.mattRuntimeConfig,
  ),
  'compatibility': {
    'backends': ['unity'],
    'builtinCatalogVersion': avatarBuiltinCatalogVersion,
  },
};

void main() {
  test('only exact retired official models are unavailable', () {
    for (final key in ['modular-anime-male', 'masso.official.modular-male']) {
      final json = <String, dynamic>{
        'id': 61,
        'modelKey': key,
        'modelSource': 'official',
        'displayName': 'Legacy model',
        'assetUrl': 'https://cdn.example.com/male.bundle',
        'assetSha256': 'a' * 64,
        'runtimeConfig': {'assetName': 'Male'},
        'compatibility': {
          'backends': ['unity'],
        },
      };
      expect(
        ApprovedAvatarModel.fromJson(json).hasExecutableDescriptor,
        isFalse,
      );
      expect(
        AvatarSelectionAssetDescriptor.fromJson(json).isRetiredOfficial,
        isTrue,
      );
      final upload = ApprovedAvatarModel.fromJson({
        ...json,
        'modelKey': 'user-model-61',
        'modelSource': 'uploaded',
        'voiceGender': 'male',
      });
      expect(upload.hasExecutableDescriptor, isTrue);
      expect(upload.voiceGender, AvatarVoiceGender.male);
    }
  });

  test(
    'historical Matt revisions retain exact metadata without execution aliases',
    () {
      for (final version in <int>[1, 2, 3]) {
        final json = historicalMattDescriptor(version: version);
        final model = ApprovedAvatarModel.fromJson(json);
        final asset = AvatarSelectionAssetDescriptor.fromJson(json);
        final installed =
            json['assetSha256'] == BundledAvatarContract.mattAssetSha256;
        expect(model.assetSha256, json['assetSha256']);
        expect(model.runtimeConfig['assetVersion'], version);
        expect(model.isBundledMatt, installed);
        expect(model.isLoadableOnDevice, installed);
        expect(model.toAvatarOption().isTrustedBundledMatt, installed);
        expect(asset.isKnownUninstalledBundledMatt, !installed);
        final restored = AvatarSelectionAssetDescriptor.fromPersistenceJson(
          asset.toPersistenceJson(),
        );
        expect(restored.hasSameSemanticValue(asset), isTrue);
      }
    },
  );
  test('historical Matt rejects forged or cross-revision identities', () {
    final v1 = historicalMattDescriptor();
    final runtime = Map<String, Object?>.from(v1['runtimeConfig'] as Map);
    final compatibility = Map<String, Object?>.from(v1['compatibility'] as Map);
    final cases = <Map<String, dynamic>>[
      {...v1, 'assetSha256': 'a' * 64},
      {...v1, 'modelSource': 'uploaded'},
      {
        ...v1,
        'runtimeConfig': {...runtime, 'assetVersion': 2},
      },
      {
        ...v1,
        'runtimeConfig': {...runtime, 'bundleVersion': '2'},
      },
      {
        ...v1,
        'runtimeConfig': {...runtime, 'assetName': 'OtherAvatar'},
      },
      {
        ...v1,
        'runtimeConfig': {...runtime, 'approvedAssetSha256': 'b' * 64},
      },
      {
        ...v1,
        'compatibility': {...compatibility, 'builtinCatalogVersion': 3},
      },
    ];
    for (final json in cases) {
      expect(() => ApprovedAvatarModel.fromJson(json), throwsStateError);
      expect(
        () => AvatarSelectionAssetDescriptor.fromJson(json),
        throwsFormatException,
      );
    }
  });
  test(
    'historical capability metadata stays decodable but cannot enable retirement',
    () {
      final profile = jsonDecode(
        File(
          'docs/avatar/matt_companion_v4/catalog-capabilities.json',
        ).readAsStringSync(),
      );
      final model = ApprovedAvatarModel.fromJson({
        ...mattDescriptor(),
        'runtimeConfig': {
          ...BundledAvatarContract.mattRuntimeConfig,
          'capabilityProfile': profile,
        },
      });
      expect(model.capabilityProfile.state, AvatarCapabilityState.supported);
      expect(model.capabilityProfile.estimatedTextureBytes, 195777816);
      expect(model.capabilityProfile.vertexCount, 49974);
      expect(model.capabilityProfile.textureCount, 48);
      expect(model.capabilityProfile.issues, isEmpty);
      expect(model.capabilityProfile.lipSync, isTrue);
      expect(model.capabilityProfile.expressions, isTrue);
      expect(
        model.capabilityProfile.estimatedTextureBytes,
        lessThan(256 * 1024 * 1024),
      );
      expect(model.isLoadableOnDevice, isFalse);
    },
  );
  test(
    'historical Matt identity stays exact while its packaged files are removed',
    () {
      final bytes = File(
        'docs/avatar/matt_companion_v4/runtime-manifest.json',
      ).readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        BundledAvatarContract.mattAssetSha256,
      );
      expect(
        File(BundledAvatarContract.mattPreviewAsset).existsSync(),
        isFalse,
      );
    },
  );
  test(
    'retired Matt retains receipt identity without a selectable model or local cover',
    () {
      for (final id in [1, 44, 870]) {
        final model = ApprovedAvatarModel.fromJson(mattDescriptor(id: id));
        final option = model.toAvatarOption();
        expect(model.isLoadableOnDevice, isFalse);
        expect(option.remoteModelId, id);
        expect(option.isDefault, isFalse);
        expect(option.isTrustedBundledMatt, isFalse);
        expect(option.previewAssetPath, isNull);
        expect(option.voiceGender, AvatarVoiceGender.male);
        expect(option.preferredVoiceSid, AvatarVoiceService.defaultMaleSid);
      }
    },
  );
  test(
    'reserved Matt identity fails closed for wrong tuple or runtime config',
    () {
      final cases = <Map<String, dynamic>>[
        {...mattDescriptor(), 'assetSha256': 'a' * 64},
        {...mattDescriptor(), 'modelSource': 'uploaded'},
        {
          ...mattDescriptor(),
          'assetUrl': 'https://cdn.example.com/pretend-matt.bundle',
        },
        {...mattDescriptor(), 'assetUrl': 'unity://masso/avatar_other'},
        {...mattDescriptor(), 'modelKey': 'masso.bundled.unknown'},
        {...mattDescriptor(), 'voiceGender': 'female'},
        {...mattDescriptor(), 'preferredVoiceSid': 0},
        for (final change in [
          {'assetName': 'Agent'},
          {'assetVersion': 1},
          {'assetVersion': '2'},
          {'bundleVersion': '1'},
          {'voiceGender': 'female'},
          {'preferredVoiceSid': 0},
        ])
          {
            ...mattDescriptor(),
            'runtimeConfig': {
              ...BundledAvatarContract.mattRuntimeConfig,
              ...change,
            },
          },
      ];
      for (final json in cases) {
        expect(
          () => ApprovedAvatarModel.fromJson(json),
          throwsStateError,
          reason: jsonEncode(json),
        );
      }
    },
  );
  test('selection keeps Matt real identity and nil still means Joy only', () {
    final asset = AvatarSelectionAssetDescriptor.fromJson(mattDescriptor());
    AvatarSelectionState state(int? id) => AvatarSelectionState(
      selectionId: 5,
      agentId: 'self',
      modelId: id,
      version: 2,
      selectedAt: DateTime.utc(2026, 9, 22),
    );
    expect(
      AvatarSelectionSnapshot(
        selection: state(44),
        asset: asset,
        selectionAvailable: true,
      ).selection.modelId,
      44,
    );
    expect(
      () => AvatarSelectionSnapshot(
        selection: state(null),
        asset: asset,
        selectionAvailable: true,
      ),
      throwsFormatException,
    );
    expect(
      () => AvatarSelectionAssetDescriptor.fromJson({
        ...mattDescriptor(),
        'assetSha256': 'b' * 64,
      }),
      throwsFormatException,
    );
  });
}
