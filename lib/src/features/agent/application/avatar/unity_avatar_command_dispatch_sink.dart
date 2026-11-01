import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';

import 'unity_avatar_transport.dart';

/// Fixed-code failure from the ticketed Unity avatar command protocol.
final class UnityAvatarArbiterProtocolException implements Exception {
  const UnityAvatarArbiterProtocolException(this.code);

  final String code;

  @override
  String toString() => 'UnityAvatarArbiterProtocolException($code)';
}

/// The single ticketed dispatch sink owned by one [UnityAvatarRuntime].
///
/// Native method completion only acknowledges that a command was accepted by
/// the bridge. This sink completes solely after the Unity receiver emits an
/// exact `commandResult` after its final validation and concrete mutation.
final class UnityAvatarCommandDispatchSink
    implements AvatarCommandDispatchSink {
  UnityAvatarCommandDispatchSink({
    required UnityAvatarTransport transport,
    required bool Function() rendererReady,
    this.maximumReceiptWait = const Duration(milliseconds: 400),
  }) : _transport = transport,
       _rendererReady = rendererReady {
    if (maximumReceiptWait <= Duration.zero ||
        maximumReceiptWait > const Duration(seconds: 5)) {
      throw ArgumentError.value(maximumReceiptWait, 'maximumReceiptWait');
    }
  }

  static const String commandMethod = 'avatarArbiterCommand';
  static const String resetMethod = 'avatarArbiterReset';
  static const int maximumPendingReceipts = 8;
  static const int maximumPayloadBytes = 256 * 1024;
  static const Set<String> _commandResultFields = <String>{
    'protocolVersion',
    'requestId',
    'method',
    'ok',
    'code',
    'ticket',
    'rendererId',
    'ownerToken',
    'commitToken',
    'accountGeneration',
    'rendererGeneration',
    'channel',
    'fingerprint',
    'payloadSha256',
    'deadlineEpochMs',
    'clearsChannel',
  };
  static const Set<String> _resetResultFields = <String>{
    'protocolVersion',
    'requestId',
    'method',
    'ok',
    'code',
    'requirementId',
    'rendererId',
    'targetOwnerToken',
    'commitToken',
    'retiredAccountGeneration',
    'retiredRendererGeneration',
    'targetAccountGeneration',
    'targetRendererGeneration',
    'payloadSha256',
    'deadlineEpochMs',
  };

  final UnityAvatarTransport _transport;
  final bool Function() _rendererReady;
  final Duration maximumReceiptWait;
  final Map<String, _PendingUnityAvatarReceipt> _pending =
      <String, _PendingUnityAvatarReceipt>{};
  final Random _random = Random.secure();

  Future<void> _tail = Future<void>.value();
  int _requestSequence = 0;
  bool _rendererUnavailable = false;
  bool _closed = false;

  int get pendingReceiptCount => _pending.length;
  bool get isClosed => _closed;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) => _enqueue(() => _dispatch(operation));

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) => _enqueue(() => _resetOrDispose(operation));

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<AvatarCommandDispatchReceipt> _dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    _requireAvailable();
    if (!AvatarProductionOwnership.allowsCommand(operation)) {
      throw const UnityAvatarArbiterProtocolException('authority_stale');
    }
    final permit = operation.issueRendererMutationPermit();
    if (permit == null) {
      throw const UnityAvatarArbiterProtocolException('operation_stale');
    }
    _validateDeadline(permit.deadlineEpochMs);
    if (utf8.encode(permit.payloadJson).length > maximumPayloadBytes) {
      throw const UnityAvatarArbiterProtocolException('payload_too_large');
    }

    final requestId = _nextRequestId();
    final expected = permit.toTransportJson(requestId: requestId);
    final result = await _sendAndAwait(
      method: commandMethod,
      requestId: requestId,
      expected: expected,
      deadlineEpochMs: permit.deadlineEpochMs,
      finalAuthorityCheck: () =>
          AvatarProductionOwnership.allowsCommand(operation),
    );
    if (result['ok'] != true) {
      throw UnityAvatarArbiterProtocolException(
        _allowedFailureCode(result['code']),
      );
    }
    final receipt = operation.acceptRendererReceipt(permit);
    if (receipt == null) {
      throw const UnityAvatarArbiterProtocolException('receipt_stale');
    }
    return receipt;
  }

  Future<AvatarRendererResetReceipt> _resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    _requireAvailable();
    if (!AvatarProductionOwnership.allowsReset(operation)) {
      throw const UnityAvatarArbiterProtocolException('authority_stale');
    }
    final now = DateTime.now();
    final deadline = now.add(maximumReceiptWait);
    final permit = operation.issueRendererResetPermit(deadline: deadline);
    if (permit == null) {
      throw const UnityAvatarArbiterProtocolException('operation_stale');
    }
    final requestId = _nextRequestId();
    final expected = permit.toTransportJson(requestId: requestId);
    final result = await _sendAndAwait(
      method: resetMethod,
      requestId: requestId,
      expected: expected,
      deadlineEpochMs: permit.deadlineEpochMs,
      finalAuthorityCheck: () =>
          AvatarProductionOwnership.allowsReset(operation),
    );
    if (result['ok'] != true) {
      throw UnityAvatarArbiterProtocolException(
        _allowedFailureCode(result['code']),
      );
    }
    final receipt = operation.acceptRendererResetReceipt(permit);
    if (receipt == null) {
      throw const UnityAvatarArbiterProtocolException('receipt_stale');
    }
    return receipt;
  }

  Future<Map<String, Object?>> _sendAndAwait({
    required String method,
    required String requestId,
    required Map<String, Object?> expected,
    required int deadlineEpochMs,
    required bool Function() finalAuthorityCheck,
  }) async {
    if (_pending.length >= maximumPendingReceipts) {
      throw const UnityAvatarArbiterProtocolException('pending_limit');
    }
    final completer = Completer<Map<String, Object?>>();
    unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
    _pending[requestId] = _PendingUnityAvatarReceipt(
      method: method,
      expected: expected,
      completer: completer,
    );
    try {
      try {
        if (!finalAuthorityCheck()) {
          throw const UnityAvatarArbiterProtocolException('authority_stale');
        }
        await _transport.invokeMethod<void>(method, expected);
      } on MissingPluginException {
        throw const UnityAvatarArbiterProtocolException(
          'transport_unavailable',
        );
      } on PlatformException catch (error) {
        throw UnityAvatarArbiterProtocolException(
          _allowedTransportCode(error.code),
        );
      }

      final remaining = Duration(
        milliseconds: deadlineEpochMs - DateTime.now().millisecondsSinceEpoch,
      );
      if (remaining <= Duration.zero) {
        throw const UnityAvatarArbiterProtocolException('deadline_expired');
      }
      return await completer.future.timeout(
        remaining < maximumReceiptWait ? remaining : maximumReceiptWait,
        onTimeout: () =>
            throw const UnityAvatarArbiterProtocolException('receipt_timeout'),
      );
    } finally {
      final pending = _pending[requestId];
      if (identical(pending?.completer, completer)) {
        _pending.remove(requestId);
      }
    }
  }

  /// Accepts a decoded Unity `commandResult`. Invalid, stale, forged, and late
  /// acknowledgements are ignored without exposing their input in errors.
  bool handleCommandResult(Map<String, dynamic> result) {
    if (_closed) return false;
    final requestId = result['requestId'];
    if (requestId is! String || !_validRequestId(requestId)) return false;
    final pending = _pending[requestId];
    if (pending == null || pending.completer.isCompleted) return false;
    if (!_matchesReceipt(result, pending)) return false;
    pending.completer.complete(Map<String, Object?>.from(result));
    return true;
  }

  void markRendererReady() {
    if (_closed) return;
    _rendererUnavailable = false;
  }

  void markRendererUnavailable() {
    if (_closed) return;
    _rendererUnavailable = true;
    _failPending('renderer_unavailable');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _rendererUnavailable = true;
    _failPending('runtime_closed');
  }

  void _requireAvailable() {
    if (_closed) {
      throw const UnityAvatarArbiterProtocolException('runtime_closed');
    }
    if (_rendererUnavailable || !_rendererReady()) {
      throw const UnityAvatarArbiterProtocolException('renderer_unavailable');
    }
  }

  void _validateDeadline(int deadlineEpochMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (deadlineEpochMs <= now ||
        deadlineEpochMs >
            now + const Duration(seconds: 5).inMilliseconds + 100) {
      throw const UnityAvatarArbiterProtocolException('deadline_invalid');
    }
  }

  void _failPending(String code) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final receipt in pending) {
      if (!receipt.completer.isCompleted) {
        receipt.completer.completeError(
          UnityAvatarArbiterProtocolException(code),
        );
      }
    }
  }

  String _nextRequestId() {
    _requestSequence += 1;
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return 'a${_requestSequence}_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  static bool _matchesReceipt(
    Map<String, dynamic> result,
    _PendingUnityAvatarReceipt pending,
  ) {
    final expected = pending.expected;
    final method = result['method'];
    final expectedFields = pending.method == commandMethod
        ? _commandResultFields
        : _resetResultFields;
    if (result.length != expectedFields.length ||
        !result.keys.toSet().containsAll(expectedFields) ||
        method != pending.method ||
        result['protocolVersion'] != 1 ||
        result['requestId'] != expected['requestId'] ||
        result['rendererId'] != expected['rendererId'] ||
        result['commitToken'] != expected['commitToken'] ||
        result['payloadSha256'] != expected['payloadSha256'] ||
        result['deadlineEpochMs'] != expected['deadlineEpochMs'] ||
        result['ok'] is! bool ||
        result['code'] is! String) {
      return false;
    }
    final ok = result['ok']! as bool;
    final code = result['code']! as String;
    if (!_validReceiptCode(method: pending.method, ok: ok, code: code)) {
      return false;
    }
    if (pending.method == commandMethod) {
      return result['ticket'] == expected['ticket'] &&
          result['ownerToken'] == expected['ownerToken'] &&
          result['accountGeneration'] == expected['accountGeneration'] &&
          result['rendererGeneration'] == expected['rendererGeneration'] &&
          result['channel'] == expected['channel'] &&
          result['fingerprint'] == expected['fingerprint'] &&
          result['clearsChannel'] == expected['clearsChannel'];
    }
    return result['requirementId'] == expected['requirementId'] &&
        result['targetOwnerToken'] == expected['targetOwnerToken'] &&
        result['retiredAccountGeneration'] ==
            expected['retiredAccountGeneration'] &&
        result['retiredRendererGeneration'] ==
            expected['retiredRendererGeneration'] &&
        result['targetAccountGeneration'] ==
            expected['targetAccountGeneration'] &&
        result['targetRendererGeneration'] ==
            expected['targetRendererGeneration'];
  }

  static bool _validReceiptCode({
    required String method,
    required bool ok,
    required String code,
  }) {
    if (ok) return code.isEmpty;
    if (method == commandMethod) {
      return code == 'deadline_expired' ||
          code == 'owner_mismatch' ||
          code == 'stale_ticket' ||
          code == 'invalid_command' ||
          code == 'mutation_failed';
    }
    return code == 'deadline_expired' ||
        code == 'reset_rejected' ||
        code == 'mutation_failed';
  }

  static bool _validRequestId(String value) =>
      value.isNotEmpty &&
      value.length <= 96 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static String _allowedFailureCode(Object? raw) => switch (raw) {
    'deadline_expired' => 'deadline_expired',
    'owner_mismatch' => 'owner_mismatch',
    'stale_ticket' => 'stale_ticket',
    'invalid_command' => 'invalid_command',
    'mutation_failed' => 'mutation_failed',
    'reset_rejected' => 'reset_rejected',
    _ => 'renderer_rejected',
  };

  static String _allowedTransportCode(String raw) => switch (raw) {
    'invalid_unity_avatar_arbiter_command' =>
      'invalid_unity_avatar_arbiter_command',
    'avatar_arbiter_multi_renderer_unsupported' =>
      'avatar_arbiter_multi_renderer_unsupported',
    'unity_avatar_sidecar_unavailable' => 'transport_unavailable',
    'not_ready' => 'renderer_unavailable',
    _ => 'transport_failed',
  };
}

final class _PendingUnityAvatarReceipt {
  const _PendingUnityAvatarReceipt({
    required this.method,
    required this.expected,
    required this.completer,
  });

  final String method;
  final Map<String, Object?> expected;
  final Completer<Map<String, Object?>> completer;
}
