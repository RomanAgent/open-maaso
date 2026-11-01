import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

part 'account_device_handoff_transport.dart';

typedef AccountDeviceLeaseAccessTokenProvider =
    Future<String?> Function(MaasoEnvironment environment, String accountUuid);

abstract interface class AccountDeviceLeaseGateway {
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  });

  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  });

  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  });

  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  });

  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  });

  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  });

  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  });
}

abstract interface class AccountRuntimeAuthorityPolicyGateway {
  Future<AccountRuntimeAuthorityPolicy> fetchRuntimeAuthorityPolicy({
    required MaasoEnvironment environment,
    required String accountUuid,
  });
}

abstract interface class AccountRuntimeDiscoveryGateway {
  Future<AccountDevicePresenceListResult> listActivePresences({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
    int limit = 50,
  });

  Future<AccountRuntimeLifecycleEventPage> replayRuntimeLifecycleEvents({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int afterSequence,
    String agentId = 'self',
    int limit = 50,
  });
}

class AccountDeviceLeaseRequestException implements Exception {
  const AccountDeviceLeaseRequestException({
    required this.statusCode,
    required this.code,
  });

  final int statusCode;
  final String code;

  bool get isStaleAuthority =>
      code == 'STALE_RUNTIME_LEASE' || code == 'STALE_RUNTIME_PRESENCE';

  bool get isRequestReuse =>
      code == 'RUNTIME_LEASE_REQUEST_REUSED' ||
      code == 'RUNTIME_PRESENCE_REQUEST_REUSED';

  bool get isEventCursorExpired =>
      statusCode == 410 && code == 'RUNTIME_EVENT_CURSOR_EXPIRED';

  @override
  String toString() =>
      'AccountDeviceLeaseRequestException(statusCode: $statusCode, '
      'code: $code)';
}

class AccountDeviceLeaseTransport
    implements
        AccountDeviceLeaseGateway,
        AccountRuntimeAuthorityPolicyGateway,
        AccountRuntimeDiscoveryGateway {
  AccountDeviceLeaseTransport({
    required AccountDeviceLeaseAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 10),
    this.maximumResponseBytes = 32 * 1024,
  }) : _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final AccountDeviceLeaseAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration requestTimeout;
  final int maximumResponseBytes;

  @override
  Future<AccountRuntimeAuthorityPolicy> fetchRuntimeAuthorityPolicy({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path: 'v1/companion/runtime-authority-policy',
    );
    return AccountRuntimeAuthorityPolicy.fromJson(data);
  }

  @override
  Future<AccountDevicePresenceListResult> listActivePresences({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
    int limit = 50,
  }) async {
    final pageLimit = _pageLimit(limit);
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path: 'v1/companion/runtime-presences',
      queryParameters: <String, String>{
        'agentId': _agentId(agentId),
        'limit': pageLimit.toString(),
      },
    );
    return AccountDevicePresenceListResult.fromJson(data);
  }

  @override
  Future<AccountRuntimeLifecycleEventPage> replayRuntimeLifecycleEvents({
    required MaasoEnvironment environment,
    required String accountUuid,
    required int afterSequence,
    String agentId = 'self',
    int limit = 50,
  }) async {
    if (afterSequence < 0 || afterSequence > maxAccountDeviceLeaseJsonInteger) {
      throw const FormatException('runtime lifecycle cursor is invalid');
    }
    final pageLimit = _pageLimit(limit);
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path: 'v1/companion/runtime-events',
      queryParameters: <String, String>{
        'agentId': _agentId(agentId),
        'afterSequence': afterSequence.toString(),
        'limit': pageLimit.toString(),
      },
    );
    return AccountRuntimeLifecycleEventPage.fromJson(
      data,
      afterSequence: afterSequence,
    );
  }

  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-presences/open',
      body: <String, Object>{
        'agentId': _agentId(agentId),
        'installationId': _identifier(installationId, 'installationId'),
        'runtimeInstanceId': _identifier(
          runtimeInstanceId,
          'runtimeInstanceId',
        ),
        'deviceLabel': _deviceLabel(deviceLabel),
        'platform': _platform(platform),
        'appVersion': _appVersion(appVersion),
        'requestId': _identifier(requestId, 'requestId'),
      },
    );
    _requireExactKeys(data, const <String>{
      'presence',
      'replayed',
    }, 'runtime presence open result');
    return AccountDevicePresenceOperationResult(
      presence: AccountDevicePresenceReceipt.fromJson(data['presence']),
      replayed: _requiredBool(data, 'replayed'),
    );
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-presences/heartbeat',
      body: <String, Object>{
        'agentId': presence.agentId,
        'installationId': presence.installationId,
        'runtimeInstanceId': presence.runtimeInstanceId,
        'presenceSessionId': presence.presenceSessionId,
        'generation': presence.generation,
        'requestId': _identifier(requestId, 'requestId'),
      },
    );
    _requireExactKeys(data, const <String>{
      'presence',
      'replayed',
    }, 'runtime presence heartbeat result');
    return AccountDevicePresenceOperationResult(
      presence: AccountDevicePresenceReceipt.fromJson(data['presence']),
      replayed: _requiredBool(data, 'replayed'),
    );
  }

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-presences/close',
      body: <String, Object>{
        'agentId': presence.agentId,
        'installationId': presence.installationId,
        'runtimeInstanceId': presence.runtimeInstanceId,
        'presenceSessionId': presence.presenceSessionId,
        'generation': presence.generation,
        'requestId': _identifier(requestId, 'requestId'),
      },
    );
    _requireExactKeys(data, const <String>{
      'closed',
      'stale',
      'generation',
    }, 'runtime presence close result');
    final closed = _requiredBool(data, 'closed');
    final stale = _requiredBool(data, 'stale');
    if (closed == stale) {
      throw const FormatException(
        'runtime presence close result is contradictory',
      );
    }
    return AccountDevicePresenceCloseResult(
      closed: closed,
      stale: stale,
      generation: _requiredJsonInteger(data, 'generation', minimum: 1),
    );
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path: 'v1/companion/runtime-lease',
      queryParameters: <String, String>{'agentId': _agentId(agentId)},
    );
    return AccountDeviceLeaseSnapshot.fromJson(data);
  }

  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-lease/acquire',
      body: <String, Object>{
        'agentId': _agentId(agentId),
        'installationId': _identifier(installationId, 'installationId'),
        'runtimeInstanceId': _identifier(
          runtimeInstanceId,
          'runtimeInstanceId',
        ),
        'presenceSessionId': _identifier(
          presenceSessionId,
          'presenceSessionId',
        ),
        'holderProof': _holderProof(holderProof),
        'requestId': _identifier(requestId, 'requestId'),
      },
    );
    _requireExactKeys(data, const <String>{
      'lease',
      'replayed',
    }, 'runtime lease acquire result');
    return AccountDeviceLeaseOperationResult(
      lease: AccountDeviceLeaseReceipt.fromJson(data['lease']),
      replayed: _requiredBool(data, 'replayed'),
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-lease/heartbeat',
      body: _leaseCommandBody(lease, holderProof, requestId),
    );
    _requireExactKeys(data, const <String>{
      'lease',
      'replayed',
    }, 'runtime lease heartbeat result');
    return AccountDeviceLeaseOperationResult(
      lease: AccountDeviceLeaseReceipt.fromJson(data['lease']),
      replayed: _requiredBool(data, 'replayed'),
    );
  }

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    final data = await _request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-lease/release',
      body: _leaseCommandBody(lease, holderProof, requestId),
    );
    _requireExactKeys(data, const <String>{
      'released',
      'stale',
      'epoch',
    }, 'runtime lease release result');
    final released = _requiredBool(data, 'released');
    final stale = _requiredBool(data, 'stale');
    if (released == stale) {
      throw const FormatException(
        'runtime lease release result is contradictory',
      );
    }
    return AccountDeviceLeaseReleaseResult(
      released: released,
      stale: stale,
      epoch: _requiredJsonInteger(data, 'epoch', minimum: 1),
    );
  }

  Map<String, Object> _leaseCommandBody(
    AccountDeviceLeaseReceipt lease,
    String holderProof,
    String requestId,
  ) => <String, Object>{
    'agentId': lease.agentId,
    'leaseId': lease.leaseId,
    'epoch': lease.epoch,
    'runtimeInstanceId': lease.runtimeInstanceId,
    'presenceSessionId': lease.presenceSessionId,
    'holderProof': _holderProof(holderProof),
    'requestId': _identifier(requestId, 'requestId'),
  };

  Future<Map<String, Object?>> _request({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String method,
    required String path,
    Map<String, Object>? body,
    Map<String, String>? queryParameters,
  }) async {
    final account = accountUuid.trim();
    if (account.isEmpty || account != accountUuid || account.length > 128) {
      throw const FormatException('runtime authority account is invalid');
    }
    final credential = (await _accessTokenProvider(
      environment,
      account,
    ))?.trim();
    if (credential == null || credential.isEmpty) {
      throw const AccountDeviceLeaseRequestException(
        statusCode: 0,
        code: 'AUTHENTICATION_REQUIRED',
      );
    }
    final baseUri = Uri.parse('${environment.baseUrl}/');
    if (baseUri.scheme != 'https' || baseUri.host.isEmpty) {
      throw const FormatException('runtime authority endpoint must use HTTPS');
    }
    var uri = baseUri.resolve(path);
    if (queryParameters != null) {
      uri = uri.replace(queryParameters: queryParameters);
    }
    final request = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'Authorization': 'Bearer $credential',
        'Accept': 'application/json',
        'Cache-Control': 'no-store',
        if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      })
      ..followRedirects = false;
    if (body != null) request.body = jsonEncode(body);
    final response = await _httpClient.send(request).timeout(requestTimeout);
    final responseBytes = await _readResponse(response).timeout(requestTimeout);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(responseBytes));
    } catch (_) {
      throw AccountDeviceLeaseRequestException(
        statusCode: response.statusCode,
        code: 'INVALID_RESPONSE',
      );
    }
    if (decoded is! Map) {
      throw AccountDeviceLeaseRequestException(
        statusCode: response.statusCode,
        code: 'INVALID_RESPONSE',
      );
    }
    _rejectResponseSecrets(decoded);
    final envelope = Map<String, Object?>.from(decoded);
    final code = _safeErrorCode(envelope['code']);
    final successStatus =
        response.statusCode >= 200 && response.statusCode < 300;
    if (successStatus && code == 'OK') {
      _requireExactKeys(envelope, const <String>{
        'code',
        'message',
        'traceId',
        'data',
      }, 'runtime authority response envelope');
      final data = envelope['data'];
      if (data is! Map) {
        throw AccountDeviceLeaseRequestException(
          statusCode: response.statusCode,
          code: 'INVALID_RESPONSE',
        );
      }
      return Map<String, Object?>.from(data);
    }
    _requireExactKeys(envelope, const <String>{
      'code',
      'message',
      'traceId',
      'details',
    }, 'runtime authority error envelope');
    if (response.statusCode == 409 && code == 'RUNTIME_LEASE_CONFLICT') {
      throw AccountDeviceLeaseConflict.fromJson(envelope['details']);
    }
    throw AccountDeviceLeaseRequestException(
      statusCode: response.statusCode,
      code: code.isEmpty ? 'HTTP_${response.statusCode}' : code,
    );
  }

  Future<List<int>> _readResponse(http.StreamedResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (maximumResponseBytes <= 0 ||
          chunk.length > maximumResponseBytes - bytes.length) {
        throw AccountDeviceLeaseRequestException(
          statusCode: response.statusCode,
          code: 'RESPONSE_TOO_LARGE',
        );
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  void close() {
    if (_ownsClient) _httpClient.close();
  }

  static String _agentId(String value) {
    if (value != 'self') {
      throw const FormatException('runtime authority agentId is invalid');
    }
    return value;
  }

  static String _identifier(String value, String name) {
    if (value.isEmpty ||
        value != value.trim() ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
      throw FormatException('runtime authority $name is invalid');
    }
    return value;
  }

  static String _deviceLabel(String value) {
    if (value.isEmpty ||
        value != value.trim() ||
        value.runes.length > 80 ||
        value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw const FormatException('runtime authority deviceLabel is invalid');
    }
    return value;
  }

  static String _platform(String value) {
    const supported = <String>{
      'ios',
      'android',
      'macos',
      'windows',
      'linux',
      'web',
      'unknown',
    };
    if (!supported.contains(value)) {
      throw const FormatException('runtime authority platform is invalid');
    }
    return value;
  }

  static String _appVersion(String value) {
    if (value != value.trim() ||
        value.length > 64 ||
        value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      throw const FormatException('runtime authority appVersion is invalid');
    }
    return value;
  }

  static int _pageLimit(int value) {
    if (value < 1 || value > 100) {
      throw const FormatException('runtime authority page limit is invalid');
    }
    return value;
  }

  static String _holderProof(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      throw const FormatException('runtime authority holder proof is invalid');
    }
    return value;
  }

  static bool _requiredBool(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! bool) {
      throw FormatException('runtime authority $key is invalid');
    }
    return value;
  }

  static String _safeErrorCode(Object? value) {
    if (value is! String) return '';
    final normalized = value.trim();
    return RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(normalized) ? normalized : '';
  }

  static int _requiredJsonInteger(
    Map<String, Object?> json,
    String key, {
    required int minimum,
  }) {
    final value = json[key];
    if (value is! int ||
        value < minimum ||
        value > maxAccountDeviceLeaseJsonInteger) {
      throw FormatException('runtime authority $key is invalid');
    }
    return value;
  }

  static void _requireExactKeys(
    Map<String, Object?> json,
    Set<String> allowed,
    String name,
  ) {
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw FormatException('$name contains an unknown field');
    }
  }

  static void _rejectResponseSecrets(Object? value) {
    const forbidden = <String>{
      'holderProof',
      'holderProofHash',
      'proof',
      'proofHash',
      'accessToken',
      'refreshToken',
      'rtcToken',
    };
    if (value is Map) {
      for (final entry in value.entries) {
        if (forbidden.contains(entry.key?.toString())) {
          throw const FormatException(
            'runtime authority response contains a forbidden secret field',
          );
        }
        _rejectResponseSecrets(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectResponseSecrets(item);
      }
    }
  }
}
