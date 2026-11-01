import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import '../data/deletion_receipt_store.dart';
import '../domain/deletion_models.dart';

/// Register above account runtime ownership: its narrow receipt remains readable
/// after the captured account's sign-out and local scoped cleanup.
final class AccountDeletionService extends AppService with ChangeNotifier {
  AccountDeletionService({
    required Uri Function() baseUri,
    required String Function() accountId,
    required this.closeCapturedAccount,
    required this.receipts,
    this.requestEmailCode,
    http.Client? client,
  }) : _baseUri = baseUri,
       _accountId = accountId,
       _client = client ?? http.Client(),
       _ownsClient = client == null;
  final Uri Function() _baseUri;
  final String Function() _accountId;
  final Future<void> Function(Uri baseUri, String accountId)
  closeCapturedAccount;
  final Future<int> Function(String email)? requestEmailCode;
  final DeletionReceiptStore receipts;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false,
      busy = false,
      ready = false,
      localCleanupPending = false;
  String? errorCode;
  DeletionPreview? preview;
  DeletionStatus? status;
  String? _proof, _preparedContext, _visibleContext;
  Map<String, Object?>? _receipt;
  bool get signedIn => _accountId().isNotEmpty;
  String get contextKey => '${_baseUri()}|${_accountId()}';
  void _emit() {
    if (!_closed) notifyListeners();
  }

  void contextChanged() {
    if (_visibleContext == contextKey) return;
    _visibleContext = contextKey;
    _proof = null;
    _preparedContext = null;
    _receipt = null;
    preview = null;
    status = null;
    ready = false;
    localCleanupPending = false;
    errorCode = null;
    _emit();
  }

  bool _mayReadReceipt(Map<String, Object?> r) =>
      r['baseUri'] == _baseUri().toString() &&
      (_accountId().isEmpty || r['accountId'] == _accountId());

  void _check(String c) {
    if (_closed || c != contextKey) {
      contextChanged();
      throw const DeletionException('context_changed');
    }
  }

  Future<Object?> _api(
    Uri base,
    String path,
    Map<String, Object?>? body,
  ) async {
    if (_closed) throw const DeletionException('closed');
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['localhost', '127.0.0.1'].contains(base.host))) {
      throw const DeletionException('unconfigured');
    }
    final request =
        http.Request(
            body == null ? 'GET' : 'POST',
            base.resolve('v1/account-deletion/$path'),
          )
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if ((streamed.contentLength ?? 0) > 64 * 1024) {
      throw const DeletionException('invalid_response');
    }
    final bytes = <int>[];
    await for (final chunk in streamed.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024) {
        throw const DeletionException('invalid_response');
      }
    }
    final j = deletionObject(jsonDecode(utf8.decode(bytes)));
    if (streamed.statusCode != 200 || j['code'] != 'OK') {
      throw DeletionException(
        j['code'] is String ? j['code']! as String : 'unavailable',
      );
    }
    return j['data'];
  }

  Future<void> refresh() async {
    contextChanged();
    if (busy) return;
    final c = contextKey, base = _baseUri();
    busy = true;
    errorCode = null;
    _emit();
    try {
      final saved = await receipts.read();
      _check(c);
      if (saved != null && _mayReadReceipt(saved)) {
        final received = DeletionStatus.fromJson(
          await _api(base, 'status', {'receiptToken': saved['receiptToken']}),
        );
        _check(c);
        _receipt = saved;
        status = received;
        localCleanupPending = saved['localCleanupComplete'] != true;
      }
      final j = deletionObject(await _api(base, 'capabilities', null));
      _check(c);
      ready = j['ready'] == true;
    } catch (e) {
      errorCode = e is DeletionException ? e.code : 'unavailable';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> verify({
    required String email,
    required String password,
    int? codeId,
    String? code,
  }) async {
    contextChanged();
    if (busy) return;
    busy = true;
    errorCode = null;
    preview = null;
    final c = contextKey;
    final base = _baseUri();
    final account = _accountId();
    _emit();
    try {
      if (account.isEmpty) throw const DeletionException('sign_in_required');
      final auth = deletionObject(
        await _api(base, 'authorize', {
          'method': codeId == null ? 'password' : 'email_code',
          'email': email.trim(),
          if (codeId == null) 'password': password,
          'codeId': ?codeId,
          if (codeId != null) 'code': code,
          'expectedAccountUuid': account,
        }),
      );
      _check(c);
      _proof = deletionString(auth['authorizationToken']);
      final p = DeletionPreview.fromJson(
        await _api(base, 'preview', {'authorizationToken': _proof}),
      );
      _check(c);
      preview = p;
      _preparedContext = c;
    } catch (e) {
      _proof = null;
      errorCode = e is DeletionException ? e.code : 'verification_failed';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<bool> confirmByUser({
    required bool eraseAcknowledged,
    required bool billingAcknowledged,
  }) async {
    contextChanged();
    if (busy || preview == null || !eraseAcknowledged || !billingAcknowledged) {
      return false;
    }
    busy = true;
    errorCode = null;
    _emit();
    var accepted = false;
    try {
      final c = _preparedContext;
      if (c == null) throw const DeletionException('verify_again');
      _check(c);
      final base = _baseUri(), account = _accountId();
      final existing = _receipt;
      final receiptToken = existing?['requestId'] == preview!.id
          ? deletionString(existing!['receiptToken'])
          : base64UrlEncode(
              List<int>.generate(32, (_) => Random.secure().nextInt(256)),
            ).replaceAll('=', '');
      final receipt = <String, Object?>{
        'version': 1,
        'baseUri': base.toString(),
        'accountId': account,
        'requestId': preview!.id,
        'receiptToken': receiptToken,
        'localCleanupComplete': false,
      };
      await receipts.write(receipt);
      _receipt = receipt;
      _check(c);
      final received = DeletionStatus.fromJson(
        await _api(base, 'confirm', {
          'previewId': preview!.id,
          'authorizationToken': _proof,
          'receiptToken': receiptToken,
          'acknowledgeErasure': true,
          'acknowledgeSubscription': true,
        }),
      );
      accepted = true;
      _check(c);
      status = received;
      _proof = null;
      preview = null;
      localCleanupPending = true;
      // A switched account is never logged out or erased by this old completion.
      _check(c);
      await closeCapturedAccount(base, account);
      receipt['localCleanupComplete'] = true;
      await receipts.write(receipt);
      if (_mayReadReceipt(receipt)) {
        _receipt = receipt;
        status = received;
        localCleanupPending = false;
      }
    } catch (e) {
      errorCode = e is DeletionException
          ? e.code
          : (accepted ? 'local_cleanup_pending' : 'request_uncertain');
    } finally {
      busy = false;
      _emit();
    }
    return accepted;
  }

  Future<void> finishLocalCleanupByUser() async {
    contextChanged();
    final r = _receipt;
    if (busy || r == null || status == null) return;
    busy = true;
    _emit();
    try {
      final base = Uri.parse(deletionString(r['baseUri']));
      if (base != _baseUri()) {
        throw const DeletionException('receipt_environment_mismatch');
      }
      final account = deletionString(r['accountId']);
      if (_accountId().isNotEmpty && account != _accountId()) {
        throw const DeletionException('context_changed');
      }
      await closeCapturedAccount(base, account);
      r['localCleanupComplete'] = true;
      await receipts.write(r);
      localCleanupPending = false;
      errorCode = null;
    } catch (e) {
      errorCode = e is DeletionException ? e.code : 'local_cleanup_pending';
    } finally {
      busy = false;
      _emit();
    }
  }

  @override
  void onClose() {
    dispose();
    super.onClose();
  }

  @override
  void dispose() {
    _closed = true;
    _proof = null;
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
