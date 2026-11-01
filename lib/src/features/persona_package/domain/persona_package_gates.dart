import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../agent/application/action/agent_action_executor.dart';
import '../../agent/application/skill_routing/lazy_host_skill_registry.dart';
import '../data/persona_package_importer.dart';
import 'persona_package_manifest.dart';

enum PersonaGateStatus { admitted, rejected }

final class PersonaGenerateDecision {
  const PersonaGenerateDecision({
    required this.status,
    this.manifest,
    this.reason,
  });

  final PersonaGateStatus status;
  final PersonaPackageManifest? manifest;
  final String? reason;
}

final class PersonaPackageGenerateGate {
  const PersonaPackageGenerateGate();

  PersonaGenerateDecision validate(Object? candidate) {
    final parsed = PersonaPackageManifestParser.parse(candidate);
    final manifest = parsed.manifest;
    if (manifest == null) {
      final issue = parsed.issue!;
      return PersonaGenerateDecision(
        status: PersonaGateStatus.rejected,
        reason: '${issue.code}:${issue.path}',
      );
    }
    final semanticIssue = validatePersonaManifestSemantics(manifest);
    if (semanticIssue != null) {
      return PersonaGenerateDecision(
        status: PersonaGateStatus.rejected,
        reason: semanticIssue,
      );
    }
    return PersonaGenerateDecision(
      status: PersonaGateStatus.admitted,
      manifest: manifest,
    );
  }
}

final class PersonaInstallContext {
  PersonaInstallContext({
    required this.scope,
    required Map<String, String> availableDependencies,
    required Set<String> allowedSpdxIds,
    required Set<PersonaPermission> hostGrantedPermissions,
    required this.installedAt,
  }) : availableDependencies = Map<String, String>.unmodifiable(
         availableDependencies,
       ),
       allowedSpdxIds = Set<String>.unmodifiable(allowedSpdxIds),
       hostGrantedPermissions = Set<PersonaPermission>.unmodifiable(
         hostGrantedPermissions,
       );

  final PersonaPackageScope scope;
  final Map<String, String> availableDependencies;
  final Set<String> allowedSpdxIds;
  final Set<PersonaPermission> hostGrantedPermissions;
  final DateTime installedAt;
}

final class PersonaLicenseSnapshot {
  const PersonaLicenseSnapshot({
    required this.spdxId,
    required this.noticeRef,
    required this.noticeDigest,
    required this.sourceRef,
    required this.sourceDigest,
  });

  final String spdxId;
  final String noticeRef;
  final String noticeDigest;
  final String sourceRef;
  final String sourceDigest;
}

final class PersonaInstalledSkill {
  PersonaInstalledSkill._({
    required this.id,
    required this.version,
    required this.entryRef,
    required Set<PersonaPermission> permissions,
  }) : permissions = Set<PersonaPermission>.unmodifiable(permissions);

  final String id;
  final String version;
  final String entryRef;
  final Set<PersonaPermission> permissions;
}

final class PersonaInstallation {
  PersonaInstallation._({
    required this.id,
    required this.packageId,
    required this.version,
    required this.manifestDigest,
    required this.archiveDigest,
    required this.scope,
    required Set<PersonaPermission> permissions,
    required Map<String, PersonaInstalledSkill> skillsById,
    required Map<String, String> dependencyVersions,
    required Map<String, String> resourceDigests,
    required this.license,
    required Set<PersonaDeviceCapability> deviceCapabilities,
    required this.faculty,
    required this.installedAt,
  }) : permissions = Set<PersonaPermission>.unmodifiable(permissions),
       skillsById = Map<String, PersonaInstalledSkill>.unmodifiable(skillsById),
       dependencyVersions = Map<String, String>.unmodifiable(
         dependencyVersions,
       ),
       resourceDigests = Map<String, String>.unmodifiable(resourceDigests),
       deviceCapabilities = Set<PersonaDeviceCapability>.unmodifiable(
         deviceCapabilities,
       );

  final String id;
  final String packageId;
  final String version;
  final String manifestDigest;
  final String archiveDigest;
  final PersonaPackageScope scope;
  final Set<PersonaPermission> permissions;
  final Map<String, PersonaInstalledSkill> skillsById;
  final Map<String, String> dependencyVersions;
  final Map<String, String> resourceDigests;
  final PersonaLicenseSnapshot license;
  final Set<PersonaDeviceCapability> deviceCapabilities;
  final PersonaFacultyManifest faculty;
  final DateTime installedAt;
}

final class PersonaInstallDecision {
  const PersonaInstallDecision({
    required this.status,
    this.installation,
    this.reason,
  });

  final PersonaGateStatus status;
  final PersonaInstallation? installation;
  final String? reason;
}

final class PersonaPackageInstallGate {
  const PersonaPackageInstallGate();

  PersonaInstallDecision validate({
    required PersonaVerifiedPackage verifiedPackage,
    required PersonaInstallContext context,
  }) {
    final manifest = verifiedPackage.manifest;
    if (!manifest.scope.matches(context.scope)) {
      return const PersonaInstallDecision(
        status: PersonaGateStatus.rejected,
        reason: 'persona_scope_mismatch',
      );
    }
    if (verifiedPackage.manifestDigest != manifest.canonicalDigest) {
      return const PersonaInstallDecision(
        status: PersonaGateStatus.rejected,
        reason: 'manifest_digest_mismatch',
      );
    }
    if (!context.allowedSpdxIds.contains(manifest.license.spdxId)) {
      return const PersonaInstallDecision(
        status: PersonaGateStatus.rejected,
        reason: 'license_not_allowed',
      );
    }
    final dependencySnapshot = <String, String>{};
    for (var index = 0; index < manifest.dependencies.length; index += 1) {
      final dependency = manifest.dependencies[index];
      final installedVersion = context.availableDependencies[dependency.id];
      if (installedVersion != dependency.requiredVersion) {
        return PersonaInstallDecision(
          status: PersonaGateStatus.rejected,
          reason: 'dependency_unsatisfied:$index',
        );
      }
      dependencySnapshot[dependency.id] = installedVersion!;
    }
    if (!context.hostGrantedPermissions.containsAll(manifest.permissions)) {
      return const PersonaInstallDecision(
        status: PersonaGateStatus.rejected,
        reason: 'permission_not_granted',
      );
    }
    final resourceDigests = <String, String>{};
    for (var index = 0; index < manifest.resources.length; index += 1) {
      final resource = manifest.resources[index];
      final receipt = verifiedPackage.resourceReceipts[resource.ref];
      if (receipt == null ||
          receipt.resourceId != resource.id ||
          receipt.kind != resource.kind ||
          receipt.sha256 != resource.sha256 ||
          receipt.manifestDigest != manifest.canonicalDigest) {
        return PersonaInstallDecision(
          status: PersonaGateStatus.rejected,
          reason: 'resource_not_verified:$index',
        );
      }
      resourceDigests[resource.ref] = receipt.sha256;
    }
    if (resourceDigests.length != verifiedPackage.resourceReceipts.length) {
      return const PersonaInstallDecision(
        status: PersonaGateStatus.rejected,
        reason: 'unexpected_verified_resource',
      );
    }

    final notice =
        verifiedPackage.resourceReceipts[manifest.license.noticeRef]!;
    final source =
        verifiedPackage.resourceReceipts[manifest.license.sourceRef]!;
    return PersonaInstallDecision(
      status: PersonaGateStatus.admitted,
      installation: PersonaInstallation._(
        id: 'persona:${manifest.canonicalDigest}',
        packageId: manifest.packageId,
        version: manifest.version,
        manifestDigest: manifest.canonicalDigest,
        archiveDigest: verifiedPackage.archiveDigest,
        scope: manifest.scope,
        permissions: manifest.permissions.toSet(),
        skillsById: <String, PersonaInstalledSkill>{
          for (final skill in manifest.skills)
            skill.id: PersonaInstalledSkill._(
              id: skill.id,
              version: skill.version,
              entryRef: skill.entryRef,
              permissions: skill.permissions.toSet(),
            ),
        },
        dependencyVersions: dependencySnapshot,
        resourceDigests: resourceDigests,
        license: PersonaLicenseSnapshot(
          spdxId: manifest.license.spdxId,
          noticeRef: notice.ref,
          noticeDigest: notice.sha256,
          sourceRef: source.ref,
          sourceDigest: source.sha256,
        ),
        deviceCapabilities: manifest.body.deviceCapabilities.toSet(),
        faculty: manifest.faculty,
        installedAt: context.installedAt,
      ),
    );
  }
}

/// Exact side-effect intent. Its digest is derived here from bounded canonical
/// arguments and target, never accepted as a caller assertion.
final class PersonaOperationRequest {
  PersonaOperationRequest({
    required String skillId,
    required String method,
    required Map<String, Object?> arguments,
    required String target,
  }) : skillId = _boundedId(skillId, 'skillId'),
       method = _boundedOperationType(method),
       target = _boundedTarget(target),
       arguments = _boundedCanonicalMap(arguments) {
    canonicalArgsTargetDigest = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'arguments': this.arguments,
              'target': this.target,
            }),
          ),
        )
        .toString();
  }

  final String skillId;
  final String method;
  final Map<String, Object?> arguments;
  final String target;
  late final String canonicalArgsTargetDigest;
}

final class PersonaOnceApprovalReceipt {
  PersonaOnceApprovalReceipt({
    required String id,
    required String issuer,
    required String installationId,
    required String manifestDigest,
    required this.scope,
    required String skillId,
    required String skillVersion,
    required String skillEntryRef,
    required String method,
    required String argsTargetDigest,
    required String callId,
    required this.permission,
    required this.issuedAt,
    required this.expiresAt,
  }) : id = _boundedId(id, 'id'),
       issuer = _boundedIssuer(issuer),
       installationId = _boundedId(installationId, 'installationId'),
       manifestDigest = _boundedSha256(manifestDigest, 'manifestDigest'),
       skillId = _boundedId(skillId, 'skillId'),
       skillVersion = _boundedVersion(skillVersion),
       skillEntryRef = _boundedTarget(skillEntryRef),
       method = _boundedOperationType(method),
       argsTargetDigest = _boundedSha256(argsTargetDigest, 'argsTargetDigest'),
       callId = _boundedId(callId, 'callId') {
    final lifetime = expiresAt.difference(issuedAt);
    if (!expiresAt.isAfter(issuedAt) || lifetime > const Duration(minutes: 5)) {
      throw const PersonaBoundaryValidationException(
        PersonaBoundaryValidationCode.invalidApprovalReceiptBounds,
      );
    }
  }

  final String id;
  final String issuer;
  final String installationId;
  final String manifestDigest;
  final PersonaPackageScope scope;
  final String skillId;
  final String skillVersion;
  final String skillEntryRef;
  final String method;
  final String argsTargetDigest;
  final String callId;
  final PersonaPermission permission;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

abstract interface class PersonaApprovalReceiptVerifier {
  Future<bool> allows({
    required PersonaOnceApprovalReceipt receipt,
    required PersonaInstallation installation,
    required PersonaOperationRequest operation,
    required ActionInvocationContext invocation,
    required DateTime now,
  });
}

abstract interface class PersonaApprovalReceiptConsumer {
  Future<bool> consumeOnce(
    PersonaOnceApprovalReceipt receipt, {
    required DateTime now,
  });
}

abstract interface class PersonaTrustedClock {
  DateTime now();
}

abstract interface class PersonaRuntimeTrustFence {
  String get issuer;

  PersonaPackageScope? currentScope();

  bool isRevoked({
    required String installationId,
    required String manifestDigest,
    required String issuer,
  });
}

final class PersonaAdmissionDecision {
  const PersonaAdmissionDecision._({
    required this.status,
    this.admission,
    this.reason,
  });

  const PersonaAdmissionDecision.admitted(PersonaRuntimeAdmission admission)
    : this._(status: PersonaGateStatus.admitted, admission: admission);

  const PersonaAdmissionDecision.rejected(String reason)
    : this._(status: PersonaGateStatus.rejected, reason: reason);

  final PersonaGateStatus status;
  final PersonaRuntimeAdmission? admission;
  final String? reason;
}

final class PersonaCommitDecision {
  const PersonaCommitDecision._({required this.committed, this.reason});

  const PersonaCommitDecision.committed() : this._(committed: true);

  const PersonaCommitDecision.rejected(String reason)
    : this._(committed: false, reason: reason);

  final bool committed;
  final String? reason;
}

/// The only successful return from a Persona effect sink.
///
/// Deliberately carries no generic value: a callback returning `Future<T>` is
/// not assignable to this exact type, so an accidental `async` sink cannot
/// move the irreversible write beyond the account-boundary hold.
enum PersonaSynchronousEffectOutcome { committed }

/// Host-owned consequential sinks must consume this token immediately before
/// their final synchronous write. The token is active only while
/// [PersonaPreparedOperation.commitTo] owns the account boundary hold, and it
/// rechecks grant, account, expiry, and revocation at the linearization point.
final class PersonaOperationCommitToken {
  PersonaOperationCommitToken._({required bool Function() isCurrent})
    : _isCurrent = isCurrent;

  final bool Function() _isCurrent;
  bool _active = true;
  bool _consumed = false;

  bool consume() {
    if (!_active || _consumed || !_isCurrent()) return false;
    _consumed = true;
    return true;
  }

  void _close() => _active = false;
}

/// Trusted host sink for one irreversible Persona operation.
///
/// Implementations must remain synchronous and perform the final write
/// immediately after [PersonaOperationCommitToken.consume] returns true. A
/// retained token is unusable after this method returns, preventing an async
/// effect from carrying authority across an `await`.
final class PersonaSynchronousEffectSink {
  PersonaSynchronousEffectSink._({
    required Object authority,
    required Object nonce,
    required _PersonaEffectIdentity identity,
    required PersonaSynchronousEffectOutcome Function(
      PersonaOperationCommitToken token,
    )
    commit,
  }) : _authority = authority,
       _nonce = nonce,
       _identity = identity,
       _commit = commit;

  final Object _authority;
  final Object _nonce;
  final _PersonaEffectIdentity _identity;
  final PersonaSynchronousEffectOutcome Function(
    PersonaOperationCommitToken token,
  )
  _commit;
  bool _consumed = false;
}

/// Host-owned issuer for exact-operation effect sinks. Creating another
/// authority cannot forge a sink accepted by a gate configured with this
/// authority's verifier.
final class PersonaEffectSinkAuthority {
  PersonaEffectSinkAuthority()
    : _authority = Object(),
      _issuedNonces = Expando<bool>('persona_effect_sink_nonce');

  final Object _authority;
  final Expando<bool> _issuedNonces;

  PersonaEffectSinkVerifier get verifier =>
      PersonaEffectSinkVerifier._(_authority, _issuedNonces);

  PersonaSynchronousEffectSink issue({
    required PersonaPreparedOperation prepared,
    required PersonaSynchronousEffectOutcome Function(
      PersonaOperationCommitToken token,
    )
    commit,
  }) {
    final nonce = Object();
    _issuedNonces[nonce] = true;
    return PersonaSynchronousEffectSink._(
      authority: _authority,
      nonce: nonce,
      identity: prepared._effectIdentity,
      commit: commit,
    );
  }
}

final class PersonaEffectSinkVerifier {
  const PersonaEffectSinkVerifier._(this._authority, this._issuedNonces);

  final Object _authority;
  final Expando<bool> _issuedNonces;

  bool _consume(
    PersonaSynchronousEffectSink sink,
    _PersonaEffectIdentity identity,
  ) {
    if (!identical(_authority, sink._authority) ||
        !identical(identity, sink._identity) ||
        identity.canonicalDigest != sink._identity.canonicalDigest ||
        sink._consumed ||
        _issuedNonces[sink._nonce] != true) {
      return false;
    }
    _issuedNonces[sink._nonce] = false;
    sink._consumed = true;
    return true;
  }
}

/// Immutable effect identity derived only from an admitted Host invocation.
/// The object identity additionally binds a sink to one exact prepared
/// operation, while this digest makes every security-relevant component
/// explicit and auditable.
final class _PersonaEffectIdentity {
  _PersonaEffectIdentity({
    required PersonaRuntimeAdmission admission,
    required PersonaOperationRequest operation,
  }) : canonicalDigest = sha256
           .convert(
             utf8.encode(
               jsonEncode(<String, Object?>{
                 'installationId': admission.installationId,
                 'packageId': admission.packageId,
                 'packageVersion': admission.packageVersion,
                 'manifestDigest': admission.manifestDigest,
                 'archiveDigest': admission.archiveDigest,
                 'issuer': admission.issuer,
                 'skillId': admission.skillId,
                 'skillVersion': admission.skillVersion,
                 'skillEntryRef': admission.skillEntryRef,
                 'method': admission.method,
                 'argsTargetDigest': admission.argsTargetDigest,
                 'permission': admission.permission.wireName,
                 'accountId': admission.scope.accountId,
                 'facadeGeneration': admission.scope.facadeGeneration,
                 'agentId': admission._invocation.agentId,
                 'hostTool': admission._invocation.tool,
                 'hostSkillName': admission._invocation.skillName,
                 'hostMethod': admission._invocation.method,
                 'callId': admission.callId,
                 'receiptId': admission.oneShotReceiptId,
                 'approvalIssuedAt': admission.approvalIssuedAt
                     .toUtc()
                     .toIso8601String(),
                 'approvalExpiresAt': admission.approvalExpiresAt
                     .toUtc()
                     .toIso8601String(),
                 'admissionCapturedAt': admission.capturedAt
                     .toUtc()
                     .toIso8601String(),
                 'admissionExpiresAt': admission.expiresAt
                     .toUtc()
                     .toIso8601String(),
                 'operation': <String, Object?>{
                   'skillId': operation.skillId,
                   'method': operation.method,
                   'arguments': operation.arguments,
                   'target': operation.target,
                 },
               }),
             ),
           )
           .toString();

  final String canonicalDigest;
}

final class PersonaPrepareDecision {
  const PersonaPrepareDecision._({this.prepared, this.reason});

  const PersonaPrepareDecision.prepared(PersonaPreparedOperation prepared)
    : this._(prepared: prepared);

  const PersonaPrepareDecision.rejected(String reason) : this._(reason: reason);

  final PersonaPreparedOperation? prepared;
  final String? reason;
}

/// Opaque, one-call capability. Only [PersonaRuntimeAdmissionGate] can mint it.
/// Callers first bind the exact operation with [prepare]. Only the returned
/// [PersonaPreparedOperation] can enter a trusted sink commit boundary.
final class PersonaRuntimeAdmission {
  PersonaRuntimeAdmission._({
    required this.installationId,
    required this.packageId,
    required this.packageVersion,
    required this.manifestDigest,
    required this.archiveDigest,
    required this.issuer,
    required this.skillId,
    required this.skillVersion,
    required this.skillEntryRef,
    required this.method,
    required this.argsTargetDigest,
    required this.permission,
    required this.scope,
    required this.callId,
    required this.expiresAt,
    required this.oneShotReceiptId,
    required this.approvalIssuedAt,
    required this.approvalExpiresAt,
    required this.capturedAt,
    required ActionInvocationContext invocation,
    required GrantedHostTool registeredHostTool,
    required PersonaEffectSinkVerifier effectSinkVerifier,
    required bool Function() isCurrent,
  }) : _invocation = invocation,
       _registeredHostTool = registeredHostTool,
       _effectSinkVerifier = effectSinkVerifier,
       _isCurrent = isCurrent;

  final String installationId;
  final String packageId;
  final String packageVersion;
  final String manifestDigest;
  final String archiveDigest;
  final String issuer;
  final String skillId;
  final String skillVersion;
  final String skillEntryRef;
  final String method;
  final String argsTargetDigest;
  final PersonaPermission permission;
  final PersonaPackageScope scope;
  final String callId;
  final DateTime expiresAt;
  final String oneShotReceiptId;
  final DateTime approvalIssuedAt;
  final DateTime approvalExpiresAt;
  final DateTime capturedAt;
  final ActionInvocationContext _invocation;
  final GrantedHostTool _registeredHostTool;
  final PersonaEffectSinkVerifier _effectSinkVerifier;
  final bool Function() _isCurrent;
  bool _prepareStarted = false;

  PersonaPrepareDecision prepare({required PersonaOperationRequest operation}) {
    if (_prepareStarted) {
      return const PersonaPrepareDecision.rejected(
        'admission_already_consumed',
      );
    }
    _prepareStarted = true;
    if (operation.skillId != skillId ||
        operation.method != method ||
        operation.canonicalArgsTargetDigest != argsTargetDigest) {
      return const PersonaPrepareDecision.rejected('operation_mismatch');
    }
    if (!_isCurrent() ||
        !_invocation.matchesExactHostTool(
          registeredTool: _registeredHostTool,
          skillName: skillId,
          method: method,
          arguments: operation.arguments,
        )) {
      return const PersonaPrepareDecision.rejected('admission_stale');
    }
    return PersonaPrepareDecision.prepared(
      PersonaPreparedOperation._(admission: this, operation: operation),
    );
  }
}

/// Opaque prepared operation. The operation cannot be swapped after prepare,
/// and each instance can enter exactly one synchronous sink commit attempt.
final class PersonaPreparedOperation {
  PersonaPreparedOperation._({
    required PersonaRuntimeAdmission admission,
    required PersonaOperationRequest operation,
  }) : _admission = admission,
       _operation = operation,
       _effectIdentity = _PersonaEffectIdentity(
         admission: admission,
         operation: operation,
       );

  final PersonaRuntimeAdmission _admission;
  final PersonaOperationRequest _operation;
  final _PersonaEffectIdentity _effectIdentity;
  bool _commitStarted = false;

  PersonaCommitDecision commitTo({required PersonaSynchronousEffectSink sink}) {
    if (_commitStarted) {
      return const PersonaCommitDecision.rejected(
        'prepared_operation_already_consumed',
      );
    }
    _commitStarted = true;
    if (!_admission._effectSinkVerifier._consume(sink, _effectIdentity)) {
      return const PersonaCommitDecision.rejected('effect_sink_untrusted');
    }
    if (!_admission._isCurrent()) {
      return const PersonaCommitDecision.rejected('admission_stale');
    }
    final hold = _admission._invocation.acquireAccountBoundaryHold();
    if (hold == null) {
      return const PersonaCommitDecision.rejected('admission_stale');
    }
    try {
      if (!_admission._isCurrent() ||
          !_admission._invocation.matchesExactHostTool(
            registeredTool: _admission._registeredHostTool,
            skillName: _admission.skillId,
            method: _admission.method,
            arguments: _operation.arguments,
          )) {
        return const PersonaCommitDecision.rejected('admission_stale');
      }
      final token = PersonaOperationCommitToken._(
        isCurrent: _admission._isCurrent,
      );
      try {
        final outcome = sink._commit(token);
        if (!token._consumed) {
          return const PersonaCommitDecision.rejected(
            'effect_token_not_consumed',
          );
        }
        if (outcome != PersonaSynchronousEffectOutcome.committed) {
          return const PersonaCommitDecision.rejected('effect_sink_failed');
        }
        return const PersonaCommitDecision.committed();
      } on Object {
        return const PersonaCommitDecision.rejected('effect_sink_failed');
      } finally {
        token._close();
      }
    } finally {
      hold.release();
    }
  }
}

final class PersonaRuntimeAdmissionGate {
  PersonaRuntimeAdmissionGate({
    required this.clock,
    required this.trustFence,
    required this.approvalReceiptVerifier,
    required this.receiptConsumer,
    required GrantedHostTool registeredHostTool,
    required PersonaEffectSinkVerifier effectSinkVerifier,
    this.maxAdmissionLifetime = const Duration(seconds: 30),
  }) : _registeredHostTool = registeredHostTool,
       _effectSinkVerifier = effectSinkVerifier {
    if (maxAdmissionLifetime <= Duration.zero ||
        maxAdmissionLifetime > const Duration(seconds: 30)) {
      throw const PersonaBoundaryValidationException(
        PersonaBoundaryValidationCode.invalidAdmissionLifetime,
      );
    }
  }

  final PersonaTrustedClock clock;
  final PersonaRuntimeTrustFence trustFence;
  final PersonaApprovalReceiptVerifier approvalReceiptVerifier;
  final PersonaApprovalReceiptConsumer receiptConsumer;
  final GrantedHostTool _registeredHostTool;
  final PersonaEffectSinkVerifier _effectSinkVerifier;
  final Duration maxAdmissionLifetime;

  Future<PersonaAdmissionDecision> admit({
    required PersonaInstallation installation,
    required PersonaPermission permission,
    required PersonaOperationRequest operation,
    required PersonaOnceApprovalReceipt approvalReceipt,
  }) async {
    final String issuer;
    try {
      issuer = _boundedIssuer(trustFence.issuer);
    } on Object {
      return const PersonaAdmissionDecision.rejected('trust_boundary_invalid');
    }
    final invocation = ActionInvocationContext.current;
    if (invocation == null) {
      return const PersonaAdmissionDecision.rejected(
        'host_invocation_required',
      );
    }
    final skill = installation.skillsById[operation.skillId];
    if (skill == null) {
      return const PersonaAdmissionDecision.rejected('skill_not_installed');
    }

    DateTime? trustedNow() {
      try {
        return clock.now().toUtc();
      } on Object {
        return null;
      }
    }

    String? staleReason() {
      try {
        final now = trustedNow();
        if (now == null) return 'trust_boundary_invalid';
        final currentScope = trustFence.currentScope();
        if (trustFence.issuer != issuer) return 'trust_boundary_changed';
        if (!identical(ActionInvocationContext.current, invocation) ||
            !invocation.isCurrent) {
          return 'host_invocation_stale';
        }
        if (currentScope == null ||
            !installation.scope.matches(currentScope) ||
            invocation.accountScope != installation.scope.accountId ||
            invocation.runtimeGeneration !=
                installation.scope.facadeGeneration) {
          return 'persona_scope_mismatch';
        }
        if (trustFence.isRevoked(
          installationId: installation.id,
          manifestDigest: installation.manifestDigest,
          issuer: issuer,
        )) {
          return 'persona_revoked';
        }
        if (!invocation.matchesExactHostTool(
          registeredTool: _registeredHostTool,
          skillName: skill.id,
          method: operation.method,
          arguments: operation.arguments,
        )) {
          return 'host_binding_mismatch';
        }
        if (!skill.permissions.contains(permission)) {
          return 'skill_permission_not_declared';
        }
        if (approvalReceipt.issuer != issuer ||
            approvalReceipt.installationId != installation.id ||
            approvalReceipt.manifestDigest != installation.manifestDigest ||
            !approvalReceipt.scope.matches(installation.scope) ||
            approvalReceipt.skillId != skill.id ||
            approvalReceipt.skillVersion != skill.version ||
            approvalReceipt.skillEntryRef != skill.entryRef ||
            approvalReceipt.method != operation.method ||
            approvalReceipt.argsTargetDigest !=
                operation.canonicalArgsTargetDigest ||
            approvalReceipt.callId != invocation.callId ||
            approvalReceipt.permission != permission ||
            approvalReceipt.issuedAt.toUtc().isAfter(now) ||
            !approvalReceipt.expiresAt.toUtc().isAfter(now)) {
          return 'approval_mismatch';
        }
        return null;
      } on Object {
        return 'trust_boundary_invalid';
      }
    }

    var reason = staleReason();
    if (reason != null) return PersonaAdmissionDecision.rejected(reason);
    var now = trustedNow();
    if (now == null) {
      return const PersonaAdmissionDecision.rejected('trust_boundary_invalid');
    }
    final bool verified;
    try {
      verified = await approvalReceiptVerifier.allows(
        receipt: approvalReceipt,
        installation: installation,
        operation: operation,
        invocation: invocation,
        now: now,
      );
    } on Object {
      return const PersonaAdmissionDecision.rejected('approval_invalid');
    }
    if (!verified) {
      return const PersonaAdmissionDecision.rejected('approval_invalid');
    }
    reason = staleReason();
    if (reason != null) return PersonaAdmissionDecision.rejected(reason);

    now = trustedNow();
    if (now == null) {
      return const PersonaAdmissionDecision.rejected('trust_boundary_invalid');
    }
    final bool consumed;
    try {
      consumed = await receiptConsumer.consumeOnce(approvalReceipt, now: now);
    } on Object {
      return const PersonaAdmissionDecision.rejected('approval_consume_failed');
    }
    if (!consumed) {
      return const PersonaAdmissionDecision.rejected('approval_replayed');
    }
    reason = staleReason();
    if (reason != null) return PersonaAdmissionDecision.rejected(reason);

    now = trustedNow();
    if (now == null) {
      return const PersonaAdmissionDecision.rejected('trust_boundary_invalid');
    }
    final boundedExpiry = now.add(maxAdmissionLifetime);
    final receiptExpiry = approvalReceipt.expiresAt.toUtc();
    final expiresAt = receiptExpiry.isBefore(boundedExpiry)
        ? receiptExpiry
        : boundedExpiry;
    reason = staleReason();
    final finalNow = trustedNow();
    if (reason != null || finalNow == null || !expiresAt.isAfter(finalNow)) {
      return PersonaAdmissionDecision.rejected(reason ?? 'approval_expired');
    }

    bool isCurrent() {
      final currentNow = trustedNow();
      return currentNow != null &&
          staleReason() == null &&
          currentNow.isBefore(expiresAt);
    }

    return PersonaAdmissionDecision.admitted(
      PersonaRuntimeAdmission._(
        installationId: installation.id,
        packageId: installation.packageId,
        packageVersion: installation.version,
        manifestDigest: installation.manifestDigest,
        archiveDigest: installation.archiveDigest,
        issuer: issuer,
        skillId: skill.id,
        skillVersion: skill.version,
        skillEntryRef: skill.entryRef,
        method: operation.method,
        argsTargetDigest: operation.canonicalArgsTargetDigest,
        permission: permission,
        scope: installation.scope,
        callId: invocation.callId,
        expiresAt: expiresAt,
        oneShotReceiptId: approvalReceipt.id,
        approvalIssuedAt: approvalReceipt.issuedAt.toUtc(),
        approvalExpiresAt: approvalReceipt.expiresAt.toUtc(),
        capturedAt: now,
        invocation: invocation,
        registeredHostTool: _registeredHostTool,
        effectSinkVerifier: _effectSinkVerifier,
        isCurrent: isCurrent,
      ),
    );
  }
}

String _boundedId(String value, String _) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 256 ||
      !RegExp(r'^[a-zA-Z0-9._:@-]+$').hasMatch(normalized)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidIdentifier,
    );
  }
  return normalized;
}

String _boundedIssuer(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:-]*$').hasMatch(normalized)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidIssuer,
    );
  }
  return normalized;
}

String _boundedOperationType(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      !RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(normalized)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidOperationType,
    );
  }
  return normalized;
}

String _boundedSha256(String value, String _) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidSha256,
    );
  }
  return normalized;
}

String _boundedTarget(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 512 ||
      normalized.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidTarget,
    );
  }
  return normalized;
}

String _boundedVersion(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 64 ||
      !RegExp(
        r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
      ).hasMatch(normalized)) {
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.invalidVersion,
    );
  }
  return normalized;
}

Map<String, Object?> _boundedCanonicalMap(Map<String, Object?> input) {
  var nodes = 0;
  var stringUnits = 0;

  Object? visit(Object? value, int depth) {
    nodes += 1;
    if (nodes > 512 || depth > 8) {
      throw const PersonaBoundaryValidationException(
        PersonaBoundaryValidationCode.operationStructureBudgetExceeded,
      );
    }
    if (value == null || value is bool) return value;
    if (value is num) {
      if (!value.isFinite || value.abs() > 1e15) {
        throw const PersonaBoundaryValidationException(
          PersonaBoundaryValidationCode.operationNumberOutOfBounds,
        );
      }
      return value;
    }
    if (value is String) {
      if (value.length > 2048) {
        throw const PersonaBoundaryValidationException(
          PersonaBoundaryValidationCode.operationStringOutOfBounds,
        );
      }
      stringUnits += value.length;
      if (stringUnits > 16 * 1024) {
        throw const PersonaBoundaryValidationException(
          PersonaBoundaryValidationCode.operationStringBudgetExceeded,
        );
      }
      return value;
    }
    if (value is List<Object?>) {
      if (value.length > 128) {
        throw const PersonaBoundaryValidationException(
          PersonaBoundaryValidationCode.operationListOutOfBounds,
        );
      }
      return List<Object?>.unmodifiable(
        value.map((item) => visit(item, depth + 1)),
      );
    }
    if (value is Map<String, Object?>) {
      if (value.length > 128) {
        throw const PersonaBoundaryValidationException(
          PersonaBoundaryValidationCode.operationObjectOutOfBounds,
        );
      }
      final keys = value.keys.toList(growable: false)..sort();
      final result = <String, Object?>{};
      for (final key in keys) {
        if (key.isEmpty ||
            key.length > 64 ||
            !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(key)) {
          throw const PersonaBoundaryValidationException(
            PersonaBoundaryValidationCode.invalidOperationArgumentKey,
          );
        }
        stringUnits += key.length;
        result[key] = visit(value[key], depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    throw const PersonaBoundaryValidationException(
      PersonaBoundaryValidationCode.unsupportedOperationArgumentValue,
    );
  }

  return visit(input, 1)! as Map<String, Object?>;
}
