import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

AvatarSelectionCommitRequest _request({String? digest}) =>
    AvatarSelectionCommitRequest(
      agentId: 'self',
      modelId: 7,
      expectedVersion: 2,
      idempotencyKey: 'asset_pin_01',
      assetOptions: const AvatarSelectionAssetOptions.none(),
      expectedAssetVersionDigest: digest,
    );

void main() {
  test(
    'optional digest is absent for legacy requests and survives exact outbox serialization',
    () {
      final legacy = _request();
      expect(
        legacy.toWireJson().containsKey('expectedAssetVersionDigest'),
        isFalse,
      );
      expect(
        legacy.toPersistenceJson().containsKey('expectedAssetVersionDigest'),
        isFalse,
      );
      final pinned = _request(digest: 'a' * 64);
      expect(pinned.toWireJson()['expectedAssetVersionDigest'], 'a' * 64);
      final restored = AvatarSelectionCommitRequest.fromPersistenceJson(
        pinned.toPersistenceJson(),
      );
      expect(restored.toWireJson(), pinned.toWireJson());
      expect(restored.hasSameSemanticValue(pinned), isTrue);
      expect(restored.hasSameSemanticValue(legacy), isFalse);
      expect(
        restored.hasSameSemanticValue(_request(digest: 'b' * 64)),
        isFalse,
      );
    },
  );
  test(
    'corrupt or noncanonical digest never falls back to an unpinned request',
    () {
      for (final digest in ['', 'a' * 63, 'A' * 64, 'x' * 64, ' ${'a' * 64}']) {
        expect(() => _request(digest: digest), throwsFormatException);
      }
      final corrupt = {
        ..._request().toPersistenceJson(),
        'expectedAssetVersionDigest': null,
      };
      expect(
        () => AvatarSelectionCommitRequest.fromPersistenceJson(corrupt),
        throwsFormatException,
      );
    },
  );
}
