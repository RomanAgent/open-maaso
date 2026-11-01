part of 'account_device_lease_transport.dart';

enum AccountHandoffCommand {
  prepare('prepare'),
  targetReady('target-ready'),
  sourceExited('source-exited'),
  completed('completed'),
  cancel('cancel');

  const AccountHandoffCommand(this.path);
  final String path;
}

abstract interface class AccountDeviceHandoffGateway {
  Future<AccountHandoffDrainResult> drainHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required Map<String, Object?> body,
  });
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  });

  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  });
}

/// Reuses the lease client's exact-origin authentication, response limits and
/// no-store transport. It never sends a holder proof in a URL or a GET request.
final class AccountDeviceHandoffTransport
    implements AccountDeviceHandoffGateway {
  const AccountDeviceHandoffTransport(this.transport);
  final AccountDeviceLeaseTransport transport;

  @override
  Future<AccountHandoffDrainResult> drainHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required Map<String, Object?> body,
  }) async => AccountHandoffDrainResult.fromJson(
    await transport._request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-handoffs/drain',
      body: Map<String, Object>.from(body),
    ),
  );

  @override
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  }) async {
    final isPrepare = command == AccountHandoffCommand.prepare;
    if (isPrepare != (handoffId == null)) {
      throw const FormatException('handoff_command_id_mismatch');
    }
    final suffix = isPrepare
        ? command.path
        : '${handoffIdentifier(handoffId)}/${command.path}';
    final data = await transport._request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'POST',
      path: 'v1/companion/runtime-handoffs/$suffix',
      body: Map<String, Object>.from(body),
    );
    final result = AccountHandoffResult.fromJson(data);
    if (handoffId != null && result.requiredHandoff.handoffId != handoffId) {
      throw const FormatException('handoff_response_id_mismatch');
    }
    return result;
  }

  @override
  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  }) async {
    final data = await transport._request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path:
          'v1/companion/runtime-handoffs/${handoffId == null ? 'current' : handoffIdentifier(handoffId)}',
      queryParameters: {
        'agentId': presence.agentId,
        'installationId': presence.installationId,
        'runtimeInstanceId': presence.runtimeInstanceId,
        'presenceSessionId': presence.presenceSessionId,
        'generation': presence.generation.toString(),
      },
    );
    final result = AccountHandoffResult.fromJson(data);
    final handoff = result.handoff;
    if (handoff != null &&
        ((handoffId != null && handoffId != handoff.handoffId) ||
            (!handoff.isSource(presence) && !handoff.isTarget(presence)))) {
      throw const FormatException('handoff_response_actor_mismatch');
    }
    return result;
  }

  /// Read-only bootstrap for a standby renderer. Account runtime services are
  /// deliberately not mounted until the exact transferred lease is installed.
  Future<AvatarSelectionSnapshot> currentAvatar({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) async {
    final data = await transport._request(
      environment: environment,
      accountUuid: accountUuid,
      method: 'GET',
      path: 'v1/avatar-models/selections/current',
      queryParameters: const {'agentId': 'self', 'platformAssets': 'false'},
    );
    // The shared lease transport already validated the wire envelope. These
    // local adapter labels satisfy the selection codec; this is no server trace.
    return AvatarSelectionContractCodec.decodeCurrentResponse({
      'code': 'OK',
      'message': 'OK',
      'traceId': 'local:handoff-readonly-adapter',
      'data': data,
    }, agentId: 'self');
  }
}
