import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/account_deletion/application/account_deletion_service.dart';
import 'package:maaso/src/features/account_deletion/data/deletion_receipt_store.dart';
import 'package:maaso/src/features/account_deletion/domain/deletion_models.dart';

class DeletionMemoryReceipt implements DeletionReceiptStore {
  Map<String, Object?>? value;
  bool fail = false;
  @override
  Future<Map<String, Object?>?> read() async => value;
  @override
  Future<void> write(Map<String, Object?> receipt) async {
    if (fail) throw const DeletionException('receipt_storage_failed');
    value = Map.of(receipt);
  }
}

Map<String, Object?> deletionStatusJson() => {
  'requestId': 'request-1',
  'state': 'queued',
  'requestedAt': '2026-09-13T00:00:00Z',
  'dueAt': '2026-09-20T00:00:00Z',
  'retainsOtherProducts': false,
  'needsOperatorAttention': false,
};
Map<String, Object?> deletionPreviewJson() => {
  'previewId': 'request-1',
  'expiresAt': '2026-09-13T00:05:00Z',
  'slaDays': 7,
  'maintenanceNotice': 'Test-only scheduled maintenance',
  'retainsOtherProducts': false,
  'retention': ['Private financial audit is retained.'],
  'subscriptions': <Object?>[],
};
http.Response deletionResponse(Object? value) =>
    http.Response(jsonEncode({'code': 'OK', 'data': value}), 200);

class DeletionFixture {
  String account = 'account-a';
  Uri base = Uri.parse('https://fixture.example/');
  final receipts = DeletionMemoryReceipt();
  int confirms = 0, closes = 0, statusReads = 0;
  Future<http.Response> Function(http.Request)? override;
  late final AccountDeletionService service;
  DeletionFixture() {
    service = AccountDeletionService(
      baseUri: () => base,
      accountId: () => account,
      receipts: receipts,
      closeCapturedAccount: (uri, id) async {
        expect(uri, base);
        expect(id, account);
        closes++;
        account = '';
      },
      client: MockClient((r) async {
        if (override != null) return override!(r);
        switch (r.url.path.split('/').last) {
          case 'capabilities':
            return deletionResponse({'ready': true});
          case 'authorize':
            return deletionResponse({'authorizationToken': 'test-only-proof'});
          case 'preview':
            return deletionResponse(deletionPreviewJson());
          case 'confirm':
            confirms++;
            expect(receipts.value?['receiptToken'], isNotNull);
            return deletionResponse(deletionStatusJson());
          case 'status':
            statusReads++;
            return deletionResponse(deletionStatusJson());
          default:
            throw StateError('Unexpected route');
        }
      }),
    );
  }
  Future<void> prepare() =>
      service.verify(email: 'test-only@example.invalid', password: 'test-only');
  void saveReceipt() {
    receipts.value = {
      'version': 1,
      'baseUri': base.toString(),
      'accountId': account,
      'requestId': 'request-1',
      'receiptToken': 'test-only-capability',
      'localCleanupComplete': true,
    };
  }
}

void main() {
  test(
    'requires both human acknowledgements and durable receipt before dispatch',
    () async {
      final f = DeletionFixture();
      addTearDown(f.service.dispose);
      await f.prepare();
      expect(
        await f.service.confirmByUser(
          eraseAcknowledged: true,
          billingAcknowledged: false,
        ),
        false,
      );
      expect(f.confirms, 0);
      f.receipts.fail = true;
      expect(
        await f.service.confirmByUser(
          eraseAcknowledged: true,
          billingAcknowledged: true,
        ),
        false,
      );
      expect(f.confirms, 0);
      expect(f.service.errorCode, 'receipt_storage_failed');
      f.receipts.fail = false;
      expect(
        await f.service.confirmByUser(
          eraseAcknowledged: true,
          billingAcknowledged: true,
        ),
        true,
      );
      expect(f.confirms, 1);
      expect(f.closes, 1);
      expect(f.receipts.value?['localCleanupComplete'], true);
      expect(f.receipts.value.toString(), isNot(contains('test-only-proof')));
    },
  );
  test('other signed-in account cannot read previous owner receipt', () async {
    final f = DeletionFixture();
    addTearDown(f.service.dispose);
    f.saveReceipt();
    f.account = 'account-b';
    await f.service.refresh();
    expect(f.statusReads, 0);
    expect(f.service.status, isNull);
    f.account = '';
    f.service.contextChanged();
    await f.service.refresh();
    expect(f.statusReads, 1);
    expect(f.service.status?.state, 'queued');
  });
  test('late status cannot cross an account switch', () async {
    final f = DeletionFixture();
    addTearDown(f.service.dispose);
    f.saveReceipt();
    final started = Completer<void>(), answer = Completer<http.Response>();
    f.override = (r) {
      started.complete();
      return answer.future;
    };
    final work = f.service.refresh();
    await started.future;
    f.account = 'account-b';
    f.service.contextChanged();
    answer.complete(deletionResponse(deletionStatusJson()));
    await work;
    expect(f.service.status, isNull);
    expect(f.service.ready, false);
  });
  test('late proof cannot prepare deletion for the next account', () async {
    final f = DeletionFixture();
    addTearDown(f.service.dispose);
    final started = Completer<void>(), answer = Completer<http.Response>();
    f.override = (r) {
      started.complete();
      return answer.future;
    };
    final work = f.prepare();
    await started.future;
    f.account = 'account-b';
    f.service.contextChanged();
    answer.complete(deletionResponse({'authorizationToken': 'private-proof'}));
    await work;
    expect(f.service.preview, isNull);
    expect(f.confirms, 0);
  });
  test(
    'late server acceptance never logs out a newly switched account',
    () async {
      final f = DeletionFixture();
      addTearDown(f.service.dispose);
      await f.prepare();
      f.override = (r) async {
        f.account = 'account-b';
        f.service.contextChanged();
        return deletionResponse(deletionStatusJson());
      };
      expect(
        await f.service.confirmByUser(
          eraseAcknowledged: true,
          billingAcknowledged: true,
        ),
        true,
      );
      expect(f.closes, 0);
      expect(f.service.status, isNull);
      expect(f.receipts.value?['accountId'], 'account-a');
    },
  );
  test(
    'status remains available while new deletion requests are disabled',
    () async {
      final f = DeletionFixture();
      addTearDown(f.service.dispose);
      f.saveReceipt();
      f.override = (r) async => deletionResponse(
        r.url.path.endsWith('status') ? deletionStatusJson() : {'ready': false},
      );
      await f.service.refresh();
      expect(f.service.ready, false);
      expect(f.service.status?.requestId, 'request-1');
    },
  );
  test(
    'stored receipt and confirmed deadline have no password or public name',
    () async {
      final f = DeletionFixture();
      addTearDown(f.service.dispose);
      await f.prepare();
      await f.service.confirmByUser(
        eraseAcknowledged: true,
        billingAcknowledged: true,
      );
      expect(
        f.receipts.value!.keys,
        unorderedEquals([
          'version',
          'baseUri',
          'accountId',
          'requestId',
          'receiptToken',
          'localCleanupComplete',
        ]),
      );
      expect(f.service.status?.dueAt, DateTime.utc(2026, 9, 20));
    },
  );
}
