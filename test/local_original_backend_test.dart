import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sembast/sembast_memory.dart';
import 'package:maaso/src/offline/local_original_backend.dart';
import 'package:maaso/src/features/identity/data/identity_http_client.dart';
import 'package:maaso/src/features/identity/data/companion_profile_http_client.dart';
import 'package:maaso/src/features/people_safety/data/people_safety_client.dart';
import 'package:maaso/src/features/people_safety/domain/people_block.dart';
import 'package:maaso/src/features/economy/data/economy_http_client.dart';
import 'package:maaso/src/features/economy/data/store_payment_http_client.dart';
import 'package:maaso/src/features/privacy/data/privacy_http_client.dart';
import 'package:maaso/src/features/account_deletion/application/account_deletion_service.dart';
import 'package:maaso/src/features/account_deletion/data/deletion_receipt_store.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late LocalOriginalBackend backend;
  var current = true;
  final base = Uri.parse('https://test-api.open-maaso.invalid/');
  Future<String> token() async => 'local-test-account-session';
  String account() => 'open-maaso-local-test';

  setUp(() async {
    current = true;
    db = await databaseFactoryMemory.openDatabase('original-local');
    backend = LocalOriginalBackend(
      database: () => db,
      isCurrent: () => current,
      origins: {base.origin},
    );
  });
  tearDown(() async {
    backend.close();
    await db.close();
  });

  test(
    'original identity and profile clients edit and restore local records',
    () async {
      IdentityHttpClient identityClient() => IdentityHttpClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      final identity = identityClient();
      final initial = await identity.fetch(
        expectedContextKey: identity.requestContextKey,
      );
      expect(initial.completed, isTrue);
      final edited = await identity.update(
        expectedContextKey: identity.requestContextKey,
        expectedVersion: initial.version,
        playerName: 'Test Player',
        agentName: 'Nova',
      );
      expect(edited.version, initial.version + 1);
      final restored = identityClient();
      expect(
        (await restored.fetch(
          expectedContextKey: restored.requestContextKey,
        )).agentName,
        'Nova',
      );
      await expectLater(
        identity.update(
          expectedContextKey: identity.requestContextKey,
          expectedVersion: initial.version,
          playerName: 'Stale',
          agentName: 'Stale',
        ),
        throwsA(isA<Exception>()),
      );
      final profiles = CompanionProfileHttpClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      final profile = await profiles.fetch(
        expectedContextKey: profiles.requestContextKey,
      );
      expect(profile.completed, isTrue);
      final updated = await profiles.update(
        expectedContextKey: profiles.requestContextKey,
        profile: profile.copyWith(interests: ['books']),
      );
      expect(updated.interests, ['books']);
      expect(updated.version, profile.version + 1);
    },
  );

  test(
    'original membership and privacy pages receive valid local DTOs',
    () async {
      final economy = EconomyHttpClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      expect(
        (await economy.membership(economy.requestContextKey)).activeTier,
        isNull,
      );
      expect(
        (await economy.catalog(economy.requestContextKey)).cashCheckoutReady,
        isFalse,
      );
      final purchases = StorePaymentHttpClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      expect(
        (await purchases.membershipAvailability(
          purchases.requestContextKey,
        )).tiers,
        hasLength(3),
      );
      expect(
        (await purchases.usage(purchases.requestContextKey)).quotaUnlimited,
        isTrue,
      );
      expect(
        await purchases.catalog(purchases.requestContextKey, 'ios'),
        isEmpty,
      );
      final privacy = PrivacyHttpClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      expect(
        (await privacy.read(
          expectedContextKey: privacy.requestContextKey,
        )).ready,
        isFalse,
      );
    },
  );

  test(
    'original people page persists local blocking without a server',
    () async {
      final people = PeopleSafetyClient(
        baseUri: () => base,
        accountId: account,
        accessToken: token,
        client: backend,
      );
      final actor = PeopleActor(
        id: 'local-other',
        kind: 'agent',
        name: 'Other',
      );
      final before = await people.blockState(actor);
      final after = await people.setBlock(
        PeopleBlockDraft(before: before, blocked: true),
      );
      expect(after.blocked, isTrue);
      expect((await people.listBlocks()).single.version, 1);
    },
  );

  test(
    'unknown operations and external URLs never fall back to HTTP',
    () async {
      final denied = await backend.get(
        Uri.parse('https://example.com/collect'),
      );
      expect(denied.statusCode, 403);
      final unknown = await backend.post(
        base.resolve('v1/unknown-write'),
        body: '{}',
      );
      expect(unknown.statusCode, 404);
      expect(jsonDecode(unknown.body)['code'], 'LOCAL_OPERATION_UNAVAILABLE');
      current = false;
      await expectLater(
        backend.get(base.resolve('v1/identity/profile')),
        throwsA(isA<http.ClientException>()),
      );
    },
  );

  test(
    'local erasure requires test credentials and original explicit acknowledgments',
    () async {
      Future<http.Response> post(String path, Map<String, Object?> body) =>
          backend.post(
            base.resolve('v1/account-deletion/$path'),
            body: jsonEncode(body),
          );
      expect(
        (await post('authorize', {
          'email': 'test',
          'password': 'wrong',
          'expectedAccountUuid': account(),
        })).statusCode,
        403,
      );
      expect(
        (await post('authorize', {
          'email': 'test',
          'password': 'test123456',
          'expectedAccountUuid': account(),
        })).statusCode,
        200,
      );
      expect(
        (await post('confirm', {
          'authorizationToken': 'local-test-erasure-confirmation',
        })).statusCode,
        403,
      );
    },
  );

  test('original Store and workshop accept the local catalog schema', () async {
    final assets = AssetStoreService(
      client: backend,
      baseUri: () => base,
      token: token,
      scope: () => account(),
    );
    expect((await assets.list(type: 'model', locale: 'en')).items, isEmpty);
    expect(
      (await assets.list(type: 'skill', locale: 'zh', workshop: true)).items,
      isEmpty,
    );
  });

  test('original deletion confirmation invokes scoped local cleanup', () async {
    var cleanup = 0;
    final receipts = _Receipts();
    final deletion = AccountDeletionService(
      baseUri: () => base,
      accountId: account,
      client: backend,
      receipts: receipts,
      closeCapturedAccount: (uri, id) async {
        expect(uri, base);
        expect(id, account());
        cleanup++;
      },
    );
    addTearDown(deletion.dispose);
    await deletion.refresh();
    expect(deletion.ready, isTrue);
    await deletion.verify(email: 'test', password: 'test123456');
    expect(deletion.preview, isNotNull);
    expect(
      await deletion.confirmByUser(
        eraseAcknowledged: false,
        billingAcknowledged: true,
      ),
      isFalse,
    );
    expect(cleanup, 0);
    expect(
      await deletion.confirmByUser(
        eraseAcknowledged: true,
        billingAcknowledged: true,
      ),
      isTrue,
    );
    expect(cleanup, 1);
    expect(receipts.value?['localCleanupComplete'], isTrue);
  });
}

final class _Receipts implements DeletionReceiptStore {
  Map<String, Object?>? value;
  @override
  Future<Map<String, Object?>?> read() async => value;
  @override
  Future<void> write(Map<String, Object?> receipt) async =>
      value = Map.of(receipt);
}
