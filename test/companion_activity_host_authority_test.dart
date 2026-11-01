import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_host_authority.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 4);
  final binding = CompanionActivityHostMutationBinding(
    kind: CompanionActivityHostMutationKind.submitEvidence,
    scope: scope,
    rolloutGeneration: 7,
    operationId: 'submit-1',
    payloadDigest: _digest,
  );

  test('grant is exact, scoped, expiring, and consumed on mismatch', () {
    final authority = CompanionActivityHostAuthority.create();
    final grant = authority.issuer.issue(
      binding: binding,
      expiresAt: DateTime.utc(2026, 8, 30, 9),
    );
    final wrong = CompanionActivityHostMutationBinding(
      kind: CompanionActivityHostMutationKind.reviewEvidence,
      scope: scope,
      rolloutGeneration: 7,
      operationId: 'submit-1',
      payloadDigest: _digest,
    );
    expect(
      authority.verifier.consume(
        grant: grant,
        binding: wrong,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
    expect(
      authority.verifier.consume(
        grant: grant,
        binding: binding,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
  });

  test('rollout generation mismatch consumes and rejects old grant', () {
    final authority = CompanionActivityHostAuthority.create();
    final grant = authority.issuer.issue(
      binding: binding,
      expiresAt: DateTime.utc(2026, 8, 30, 9),
    );
    final afterRollback = CompanionActivityHostMutationBinding(
      kind: binding.kind,
      scope: binding.scope,
      rolloutGeneration: 9,
      operationId: binding.operationId,
      payloadDigest: binding.payloadDigest,
    );

    expect(
      authority.verifier.consume(
        grant: grant,
        binding: afterRollback,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
    expect(
      authority.verifier.consume(
        grant: grant,
        binding: binding,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
  });

  test('grant from another authority and expired grant fail closed', () {
    final authority = CompanionActivityHostAuthority.create();
    final foreign = CompanionActivityHostAuthority.create();
    final foreignGrant = foreign.issuer.issue(
      binding: binding,
      expiresAt: DateTime.utc(2026, 8, 30, 9),
    );
    expect(
      authority.verifier.consume(
        grant: foreignGrant,
        binding: binding,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
    final expired = authority.issuer.issue(
      binding: binding,
      expiresAt: DateTime.utc(2026, 8, 30, 8),
    );
    expect(
      authority.verifier.consume(
        grant: expired,
        binding: binding,
        now: DateTime.utc(2026, 8, 30, 8),
      ),
      isFalse,
    );
  });

  test('operation id rejects whitespace aliases and controls', () {
    expect(canonicalActivityOperationId('op-1'), 'op-1');
    for (final invalid in <String>[' op-1', 'op-1 ', 'op 1', 'op\n1', '']) {
      expect(() => canonicalActivityOperationId(invalid), throwsArgumentError);
    }
  });
}
