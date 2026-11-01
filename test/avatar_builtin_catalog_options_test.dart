import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

void main() {
  test(
    'builtin version is explicit in reads commits and exact outbox recovery',
    () {
      final options = AvatarSelectionAssetOptions.forPlatform(
        'ios',
        builtinCatalogVersion: 2,
      );
      final request = AvatarSelectionCommitRequest(
        agentId: 'self',
        modelId: 12,
        expectedVersion: 4,
        idempotencyKey: 'matt_select_01',
        assetOptions: options,
      );
      expect(
        options.toQueryParameters(agentId: 'self')['builtinCatalogVersion'],
        '2',
      );
      expect(request.toWireJson()['builtinCatalogVersion'], 2);
      final restored = AvatarSelectionCommitRequest.fromPersistenceJson(
        request.toPersistenceJson(),
      );
      expect(restored.hasSameSemanticValue(request), isTrue);
      expect(restored.toWireJson(), request.toWireJson());
      expect(
        options.hasSameSemanticValue(
          AvatarSelectionAssetOptions.forPlatform('ios'),
        ),
        isFalse,
      );
    },
  );
  test(
    'new requests negotiate the active catalog without changing old requests',
    () {
      final current = AvatarSelectionAssetOptions.forPlatform(
        'ios',
        builtinCatalogVersion: avatarBuiltinCatalogVersion,
      );
      expect(
        current.toQueryParameters(agentId: 'self')['builtinCatalogVersion'],
        '$avatarBuiltinCatalogVersion',
      );
      final currentRequest = AvatarSelectionCommitRequest(
        agentId: 'self',
        modelId: 12,
        expectedVersion: 4,
        idempotencyKey: 'matt_select_v3',
        assetOptions: current,
      );
      expect(
        currentRequest.toWireJson()['builtinCatalogVersion'],
        avatarBuiltinCatalogVersion,
      );
      expect(
        AvatarSelectionCommitRequest.fromPersistenceJson(
          currentRequest.toPersistenceJson(),
        ).toWireJson(),
        currentRequest.toWireJson(),
      );
      final oldRequest = AvatarSelectionCommitRequest(
        agentId: 'self',
        modelId: 12,
        expectedVersion: 4,
        idempotencyKey: 'matt_select_v2',
        assetOptions: AvatarSelectionAssetOptions.forPlatform(
          'ios',
          builtinCatalogVersion: 2,
        ),
      );
      expect(
        AvatarSelectionCommitRequest.fromPersistenceJson(
          oldRequest.toPersistenceJson(),
        ).toWireJson()['builtinCatalogVersion'],
        2,
      );
    },
  );
  test(
    'old persisted requests stay old rather than acquiring new capabilities',
    () {
      final legacy = AvatarSelectionCommitRequest(
        agentId: 'self',
        modelId: null,
        expectedVersion: 1,
        idempotencyKey: 'old_clear_01',
        assetOptions: const AvatarSelectionAssetOptions.none(),
      );
      final restored = AvatarSelectionCommitRequest.fromPersistenceJson(
        legacy.toPersistenceJson(),
      );
      expect(restored.assetOptions.builtinCatalogVersion, 0);
      expect(
        restored.toWireJson().containsKey('builtinCatalogVersion'),
        isFalse,
      );
      expect(
        restored.assetOptions.toPersistenceJson().containsKey(
          'builtinCatalogVersion',
        ),
        isFalse,
      );
    },
  );
  test(
    'builtin negotiation does not enable remote platform bundles on desktop',
    () {
      const options = AvatarSelectionAssetOptions.none(
        builtinCatalogVersion: 2,
      );
      expect(options.platformAssets, isFalse);
      expect(options.platform, isNull);
      expect(options.toQueryParameters(agentId: 'self'), {
        'agentId': 'self',
        'platformAssets': 'false',
        'builtinCatalogVersion': '2',
      });
    },
  );
  test('invalid persisted builtin version fails closed', () {
    for (final value in [
      null,
      -1,
      avatarBuiltinCatalogVersion + 1,
      2.5,
      '3',
      true,
    ]) {
      expect(
        () => AvatarSelectionAssetOptions.fromPersistenceJson({
          'platformAssets': false,
          'platform': null,
          'builtinCatalogVersion': value,
        }),
        throwsFormatException,
      );
    }
  });
}
