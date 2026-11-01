import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_audit_store.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'safe audit entry survives sink and persistence reconstruction',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'action-contract-v2-audit-reconstruction.db',
      );
      addTearDown(database.close);
      final persistence = SembastActionContractV2AuditPersistence(
        accountDatabase: database,
      );
      final sink = ActionAuditLogContractV2Sink(
        ActionAuditLog(),
        persistence: persistence,
      );

      final auditId = await sink.record(
        _record(
          arguments: const <String, Object?>{'secret': 'must-not-be-retained'},
        ),
      );
      final reconstructed = SembastActionContractV2AuditPersistence(
        accountDatabase: database,
      );
      final rows = await reconstructed.readAll();

      expect(rows, hasLength(1));
      expect(rows.single['auditId'], auditId);
      expect(rows.single['argumentsDigest'], isA<String>());
      expect(rows.single.toString(), isNot(contains('must-not-be-retained')));
      expect(() => rows.single['code'] = 'mutated', throwsUnsupportedError);
    },
  );

  test('sink surfaces persistence failure to the contract caller', () async {
    final sink = ActionAuditLogContractV2Sink(
      ActionAuditLog(),
      persistence: _FailingPersistence(),
    );
    await expectLater(sink.record(_record()), throwsStateError);
  });
}

ActionContractAuditRecord _record({
  Object? arguments = const <String, Object?>{},
}) {
  return ActionContractAuditRecord(
    stage: ActionAuditStage.decided,
    invocation: const ActionContractInvocationScope(
      accountScope: 'account_scope_1234',
      accountGeneration: 7,
      agentId: 'agent_1234',
      callId: 'call_1234',
    ),
    actionIndex: 0,
    channel: ActionContractChannel.structured,
    definition: ActionDefinition(
      id: 'test.read',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'additionalProperties': false,
      },
      scopes: const <AgentActionScope>{AgentActionScope.chat},
      risk: ActionRisk.readOnly,
      consequencePolicy: ActionConsequencePolicy.reversible,
      handler: (_) => const <String, Object?>{},
    ),
    arguments: arguments,
    target: 'test.read',
    outcome: ActionAuditOutcome.allowed,
    code: 'v2.enforce_admitted',
    occurredAt: DateTime.utc(2026, 8, 30),
  );
}

final class _FailingPersistence implements ActionContractV2AuditPersistence {
  @override
  Future<void> append(ActionAuditEntry entry) async {
    throw StateError('synthetic persistence failure');
  }
}
