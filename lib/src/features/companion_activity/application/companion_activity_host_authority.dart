import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';

enum CompanionActivityHostMutationKind {
  submitEvidence,
  reviewEvidence,
  redeemReward,
}

final class CompanionActivityHostMutationBinding {
  CompanionActivityHostMutationBinding({
    required this.kind,
    required this.scope,
    required this.rolloutGeneration,
    required String operationId,
    required String payloadDigest,
  }) : operationId = canonicalActivityOperationId(operationId),
       payloadDigest = _digest(payloadDigest) {
    if (rolloutGeneration < 0) {
      throw ArgumentError.value(rolloutGeneration, 'rolloutGeneration');
    }
  }

  final CompanionActivityHostMutationKind kind;
  final ActivityScope scope;
  final int rolloutGeneration;
  final String operationId;
  final String payloadDigest;
}

final class CompanionActivityHostAuthority {
  CompanionActivityHostAuthority._({
    required this.issuer,
    required this.verifier,
  });

  factory CompanionActivityHostAuthority.create() {
    final seal = Object();
    return CompanionActivityHostAuthority._(
      issuer: CompanionActivityHostGrantIssuer._(seal),
      verifier: CompanionActivityHostGrantVerifier._(seal),
    );
  }

  final CompanionActivityHostGrantIssuer issuer;
  final CompanionActivityHostGrantVerifier verifier;
}

final class CompanionActivityHostGrantIssuer {
  const CompanionActivityHostGrantIssuer._(this._seal);

  final Object _seal;

  CompanionActivityHostGrant issue({
    required CompanionActivityHostMutationBinding binding,
    required DateTime expiresAt,
  }) => CompanionActivityHostGrant._(
    seal: _seal,
    kind: binding.kind,
    accountId: binding.scope.accountId,
    facadeGeneration: binding.scope.facadeGeneration,
    rolloutGeneration: binding.rolloutGeneration,
    operationId: binding.operationId,
    payloadDigest: binding.payloadDigest,
    expiresAt: expiresAt.toUtc(),
  );
}

final class CompanionActivityHostGrantVerifier {
  const CompanionActivityHostGrantVerifier._(this._seal);

  final Object _seal;

  bool consume({
    required CompanionActivityHostGrant grant,
    required CompanionActivityHostMutationBinding binding,
    required DateTime now,
  }) {
    if (!identical(grant._seal, _seal) || grant._consumed) return false;
    grant._consumed = true;
    return now.toUtc().isBefore(grant._expiresAt) &&
        grant._kind == binding.kind &&
        grant._accountId == binding.scope.accountId &&
        grant._facadeGeneration == binding.scope.facadeGeneration &&
        grant._rolloutGeneration == binding.rolloutGeneration &&
        grant._operationId == binding.operationId &&
        grant._payloadDigest == binding.payloadDigest;
  }
}

/// Exact, account-generation scoped and single-use host authority.
///
/// It has no public constructor or serialization surface. Agent Skills never
/// receive an issuer, verifier, or grant.
final class CompanionActivityHostGrant {
  CompanionActivityHostGrant._({
    required Object seal,
    required CompanionActivityHostMutationKind kind,
    required String accountId,
    required int facadeGeneration,
    required int rolloutGeneration,
    required String operationId,
    required String payloadDigest,
    required DateTime expiresAt,
  }) : _seal = seal,
       _kind = kind,
       _accountId = accountId,
       _facadeGeneration = facadeGeneration,
       _rolloutGeneration = rolloutGeneration,
       _operationId = operationId,
       _payloadDigest = payloadDigest,
       _expiresAt = expiresAt;

  final Object _seal;
  final CompanionActivityHostMutationKind _kind;
  final String _accountId;
  final int _facadeGeneration;
  final int _rolloutGeneration;
  final String _operationId;
  final String _payloadDigest;
  final DateTime _expiresAt;
  bool _consumed = false;
}

String canonicalActivityOperationId(String value) {
  if (value != value.trim() ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'operationId');
  }
  return value;
}

String _digest(String value) {
  final normalized = value.toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'payloadDigest');
  }
  return normalized;
}
