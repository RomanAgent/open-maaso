import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/companion_activity/data/activity_evidence_image_transformer.dart';
import 'package:maaso/src/features/companion_activity/domain/activity_evidence_privacy.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'decodes pixels, bounds output, and strips EXIF GPS before persistence',
    () async {
      final authority = ActivityEvidencePrivacyAuthority.create();
      final store = _CapturingDerivedStore();
      final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 3);
      final sourceImage = image.Image(width: 48, height: 32)
        ..exif.imageIfd[0x010f] = image.IfdValueAscii('secret-camera')
        ..exif.gpsIfd[0x0001] = image.IfdValueAscii('N');
      image.fill(sourceImage, color: image.ColorRgb8(40, 80, 120));
      final source = image.encodeJpg(sourceImage);
      expect(image.decodeJpg(source)!.exif.isEmpty, isFalse);

      final transformer = ActivityEvidenceImageTransformer(
        scope: scope,
        receiptIssuer: authority.issuer,
        thumbnailStore: store,
        clock: () => DateTime.utc(2026, 8, 30, 8),
        objectIdFactory: (_, _) => 'thumbnail-opaque-1',
      );
      final result = await transformer.transform(source);

      expect(store.writes, 1);
      expect(store.bytes, isNot(equals(source)));
      final persisted = image.decodeJpg(store.bytes!);
      expect(persisted, isNotNull);
      expect(persisted!.exif.isEmpty, isTrue);
      expect(persisted.textData, anyOf(isNull, isEmpty));
      expect(result.artifact.localObjectId, 'thumbnail-opaque-1');
      expect(result.artifact.byteLength, store.bytes!.length);
      expect(result.artifact.pixelWidth, 48);
      expect(result.artifact.pixelHeight, 32);

      expect(
        authority.verifier.consume(
          receipt: result.receipt,
          artifact: result.artifact,
          accountId: scope.accountId,
          facadeGeneration: scope.facadeGeneration,
          admittedAt: DateTime.utc(2026, 8, 30, 8, 1),
        ),
        isTrue,
      );
      expect(
        authority.verifier.consume(
          receipt: result.receipt,
          artifact: result.artifact,
          accountId: scope.accountId,
          facadeGeneration: scope.facadeGeneration,
          admittedAt: DateTime.utc(2026, 8, 30, 8, 1),
        ),
        isFalse,
      );
    },
  );

  test('rejects source outside byte budget without persistence', () async {
    final authority = ActivityEvidencePrivacyAuthority.create();
    final store = _CapturingDerivedStore();
    final transformer = ActivityEvidenceImageTransformer(
      scope: ActivityScope(accountId: 'account-a', facadeGeneration: 1),
      receiptIssuer: authority.issuer,
      thumbnailStore: store,
    );

    await expectLater(
      transformer.transform(
        Uint8List(ActivityEvidenceImageTransformer.maxSourceBytes + 1),
      ),
      throwsA(isA<StateError>()),
    );
    expect(store.writes, 0);
  });

  test(
    'Sembast adapter persists only derived bytes and bounded metadata',
    () async {
      final database = await databaseFactoryMemory.openDatabase('thumb.db');
      final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 2);
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final digest =
          '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';
      final store = SembastActivityEvidenceDerivedThumbnailStore(
        database: database,
        scope: scope,
      );
      await store.put(
        objectId: 'thumbnail-opaque-1',
        derivedSha256: digest,
        bytes: bytes,
      );

      final rows = await StoreRef<String, Map<String, Object?>>(
        'companion_activity_derived_thumbnails.v1',
      ).find(database);
      expect(rows, hasLength(1));
      expect(rows.single.value.keys, <String>{
        'accountId',
        'facadeGeneration',
        'derivedSha256',
        'bytes',
      });
      expect(rows.single.value.toString(), isNot(contains('path')));
      expect(rows.single.value.toString(), isNot(contains('source')));
      await database.close();
    },
  );
}

final class _CapturingDerivedStore
    implements ActivityEvidenceDerivedThumbnailStore {
  int writes = 0;
  Uint8List? bytes;

  @override
  Future<void> put({
    required String objectId,
    required String derivedSha256,
    required Uint8List bytes,
  }) async {
    writes += 1;
    this.bytes = Uint8List.fromList(bytes);
  }
}
