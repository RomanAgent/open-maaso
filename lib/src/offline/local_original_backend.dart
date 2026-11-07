import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

/// An in-process adapter for the original account screens. It never opens a
/// socket. The existing services retain their DTO validation and account fences;
/// their records live in the same mounted account database as chat and works.
final class LocalOriginalBackend extends http.BaseClient {
  LocalOriginalBackend({
    required Database Function() database,
    required bool Function() isCurrent,
    required Set<String> origins,
  }) : _database = database,
       _isCurrent = isCurrent,
       _origins = Set.unmodifiable(origins);

  final Database Function() _database;
  final bool Function() _isCurrent;
  final Set<String> _origins;
  final _records = stringMapStoreFactory.store('open_maaso.original_api.v1');
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || !_isCurrent()) {
      throw http.ClientException('Local account is no longer mounted.');
    }
    // Reject remote endpoints, including accidental provider or CDN requests.
    if (!_origins.contains(request.url.origin)) {
      return _response(request, 403, 'LOCAL_NETWORK_DISABLED', null);
    }
    final bytes = <int>[];
    await for (final chunk in request.finalize()) {
      if (bytes.length + chunk.length > 256 * 1024) {
        return _response(request, 413, 'LOCAL_INPUT_TOO_LARGE', null);
      }
      bytes.addAll(chunk);
    }
    if (_closed || !_isCurrent()) {
      throw http.ClientException('Local account is no longer mounted.');
    }
    Map<String, Object?> body;
    try {
      final value = bytes.isEmpty
          ? <String, Object?>{}
          : jsonDecode(utf8.decode(bytes));
      if (value is! Map) throw const FormatException();
      body = Map<String, Object?>.from(value);
    } catch (_) {
      return _response(request, 400, 'VALIDATION', null);
    }
    if (request.url.path == '/v1/privacy/policy') {
      return _response(request, 200, 'OK', _unconfiguredPolicy);
    }
    if (request.url.path.startsWith('/v1/account-deletion/')) {
      return _deletion(request, body);
    }
    try {
      final data = await _database().transaction((txn) async {
        if (_closed || !_isCurrent()) throw StateError('local_account_retired');
        final result = await _dispatch(txn, request, body);
        if (_closed || !_isCurrent()) throw StateError('local_account_retired');
        return result;
      });
      return _response(request, 200, 'OK', data);
    } on _LocalRefusal catch (error) {
      return _response(request, error.status, error.code, null);
    } on FormatException {
      return _response(request, 400, 'VALIDATION', null);
    }
  }

  Future<Object?> _dispatch(
    Transaction txn,
    http.BaseRequest request,
    Map<String, Object?> body,
  ) async {
    final path = request.url.path;
    final write = request.method == 'POST';
    if (request.method != 'GET' && !write) {
      throw const _LocalRefusal(405, 'LOCAL_METHOD_DISABLED');
    }
    if (path == '/v1/identity/me' ||
        path == '/v1/identity/profile' ||
        path == '/v1/identity/profile/update') {
      final previous =
          await _records.record('identity').get(txn) ??
          {
            'playerActorId': 'local-player',
            'playerName': 'test',
            'agentActorId': 'local-agent',
            'agentName': 'Maaso',
            'version': 1,
          };
      if (!write) return previous;
      if (body['expectedVersion'] != previous['version']) {
        throw const _LocalRefusal(409, 'IDENTITY_CONFLICT');
      }
      final next = <String, Object?>{
        ...previous,
        'playerName': IdentityNames.require(
          body['playerName'] as String? ?? '',
        ),
        'agentName': IdentityNames.require(body['agentName'] as String? ?? ''),
        'version': (previous['version'] as int) + 1,
      };
      IdentityProfile.fromJson(next);
      await _records.record('identity').put(txn, next);
      return next;
    }
    if (path == '/v1/identity/companion-profile' ||
        path == '/v1/identity/companion-profile/update') {
      final previous =
          await _records.record('companion').get(txn) ??
          CompanionProfile(
            version: 1,
            avatarPreset: 'orbit',
            agentGender: 'female',
            interests: const ['gaming'],
            onboardingVersion: 1,
          ).toJson();
      if (!write) return previous;
      if (body['expectedVersion'] != previous['version']) {
        throw const _LocalRefusal(409, 'PROFILE_CONFLICT');
      }
      final next = CompanionProfile.fromJson({
        'schemaVersion': 1,
        'version': (previous['version'] as int) + 1,
        'avatarPreset': body['avatarPreset'],
        'avatarJpeg': body['avatarJpeg'],
        'agentGender': body['agentGender'],
        'interests': body['interests'],
        'onboardingVersion': body['onboardingVersion'],
      }).toJson();
      await _records.record('companion').put(txn, next);
      return next;
    }
    if (path == '/v1/privacy/policy') return _unconfiguredPolicy;
    if (path == '/v1/privacy/me') {
      return {
        ..._unconfiguredPolicy,
        'revision': 0,
        'ageStatus': 'unconfirmed',
        'declaredAt': null,
        'consents': <Object?>[],
      };
    }
    // The local edition has no operator/store subscription. Original pages
    // still render their own Free membership and unavailable-purchase state.
    if (path == '/v1/economy/membership') {
      return {'activeTier': '', 'grants': <Object?>[]};
    }
    if (path == '/v1/membership/availability') {
      return {
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'policyVersion': 'local-v1',
        'entitlementVersion': 'local-v1',
        'tiers': [
          for (final tier in ['basic', 'plus', 'pro_v2'])
            {'tier': tier, 'available': false, 'reason': 'model_unavailable'},
        ],
      };
    }
    if (path == '/v1/membership/usage') {
      return {
        'activeTier': null,
        'model': null,
        'quotaUnlimited': true,
        'dailyTokensRemaining': 0,
        'periodTokensRemaining': 0,
        'dailyRequestsRemaining': 0,
        'pendingTokens': 0,
        'resetsAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String(),
      };
    }
    if (path == '/v1/economy/catalog') {
      return {
        'memberships': [
          for (final offer in const [
            ('basic', 990),
            ('plus', 1990),
            ('pro_v2', 2990),
          ])
            {'tier': offer.$1, 'cashUsdCents': offer.$2, 'durationDays': 30},
        ],
        'membershipReady': false,
        'membershipUnavailableReason': 'LOCAL_EDITION',
        'topUpsReady': false,
        'cashCheckoutReady': false,
      };
    }
    if (path == '/v1/store/payments/catalog') {
      return {'offers': <Object?>[], 'retiredProducts': <Object?>[]};
    }
    if (path == '/v1/store/payments/receipts' ||
        path == '/v1/economy/rewards/pending') {
      return <Object?>[];
    }
    if (path == '/v1/economy/ledger') {
      return {'items': <Object?>[], 'nextBeforeId': 0};
    }
    if (path == '/v1/moderation/reviews') return {'items': <Object?>[]};
    if (path == '/v1/people/blocks' && !write) {
      return {
        'items': [
          for (final row in await _records.find(txn))
            if (row.key.startsWith('block:')) row.value,
        ],
      };
    }
    if (path == '/v1/people/blocks' || path == '/v1/people/block-state') {
      final input = write ? body : request.url.queryParameters;
      final actorId = input['actorId'];
      final actorKind = input['actorKind'];
      if (actorId is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$').hasMatch(actorId) ||
          !{'user', 'agent'}.contains(actorKind)) {
        throw const FormatException();
      }
      final record = _records.record('block:$actorKind:$actorId');
      final previous =
          await record.get(txn) ??
          {
            'actor': {'id': actorId, 'kind': actorKind, 'displayName': ''},
            'blocked': false,
            'version': 0,
          };
      if (!write) return previous;
      if (body['expectedVersion'] != previous['version'] ||
          body['blocked'] is! bool) {
        throw const _LocalRefusal(409, 'PEOPLE_CONFLICT');
      }
      final next = {
        ...previous,
        'blocked': body['blocked'],
        'version': (previous['version'] as int) + 1,
      };
      await record.put(txn, next);
      return next;
    }
    if (path == '/v1/asset-store/assets' ||
        path == '/v1/asset-store/workshop') {
      return {'schemaVersion': 1, 'items': <Object?>[], 'nextCursor': null};
    }
    // A route without an implemented local contract must never pretend that a
    // cloud side effect succeeded or escape to a real backend.
    throw const _LocalRefusal(404, 'LOCAL_OPERATION_UNAVAILABLE');
  }

  static const _unconfiguredPolicy = <String, Object?>{
    'ready': false,
    'policy': null,
    'policyHash': null,
  };

  http.StreamedResponse _deletion(
    http.BaseRequest request,
    Map<String, Object?> body,
  ) {
    final operation = request.url.path.split('/').last;
    final now = DateTime.now().toUtc();
    Object? data;
    switch (operation) {
      case 'capabilities':
        data = {'ready': true};
      case 'authorize':
        if (body['email'] != 'test' ||
            body['password'] != 'test123456' ||
            body['expectedAccountUuid'] != 'open-maaso-local-test') {
          return _response(request, 403, 'invalid_credentials', null);
        }
        data = {'authorizationToken': 'local-test-erasure-confirmation'};
      case 'preview':
        if (body['authorizationToken'] != 'local-test-erasure-confirmation') {
          return _response(request, 403, 'verify_again', null);
        }
        data = {
          'previewId': 'local-account-erasure',
          'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
          'slaDays': 1,
          'maintenanceNotice': '删除此设备上的本地测试账号数据。',
          'retainsOtherProducts': true,
          'retention': <Object?>[],
          'subscriptions': <Object?>[],
        };
      case 'confirm':
        if (body['authorizationToken'] != 'local-test-erasure-confirmation' ||
            body['acknowledgeErasure'] != true ||
            body['acknowledgeSubscription'] != true ||
            body['receiptToken'] is! String) {
          return _response(request, 403, 'verify_again', null);
        }
        data = _deletedStatus(now);
      case 'status':
        if (body['receiptToken'] is! String) {
          return _response(request, 403, 'invalid_receipt', null);
        }
        data = _deletedStatus(now);
      default:
        return _response(request, 404, 'LOCAL_OPERATION_UNAVAILABLE', null);
    }
    return _response(request, 200, 'OK', data);
  }

  Map<String, Object?> _deletedStatus(DateTime now) => {
    'requestId': 'local-account-erasure',
    'state': 'completed',
    'requestedAt': now.toIso8601String(),
    'dueAt': now.toIso8601String(),
    'completedAt': now.toIso8601String(),
    'retainsOtherProducts': true,
    'needsOperatorAttention': false,
  };

  http.StreamedResponse _response(
    http.BaseRequest request,
    int status,
    String code,
    Object? data,
  ) {
    final encoded = utf8.encode(jsonEncode({'code': code, 'data': data}));
    return http.StreamedResponse(
      Stream.value(encoded),
      status,
      request: request,
      contentLength: encoded.length,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  void close() => _closed = true;
}

final class _LocalRefusal implements Exception {
  const _LocalRefusal(this.status, this.code);
  final int status;
  final String code;
}

/// Existing recall automatically uses its keyword path when vectors are absent.
final class LocalKeywordEmbeddingBackend extends EmbeddingBackend {
  @override
  bool get isAvailable => false;
  @override
  Future<List<double>?> embed(String text) async => null;
}
