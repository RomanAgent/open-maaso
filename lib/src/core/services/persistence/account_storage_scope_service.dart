import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Names that belong to the pre-account storage layout.
///
/// These locations are deliberately descriptive-only. Account-scoped storage
/// must never select them implicitly; a future importer may read them only
/// after explicit user confirmation and must write into a scoped destination.
abstract final class LegacyAccountStorageQuarantine {
  static const bool automaticClaimAllowed = false;
  static const String ownership = 'unclaimed';
  static const String databaseName = 'maaso.db';
  static const String soulDocumentName = 'soul.md';
  static const String masterDocumentName = 'master.md';
  static const String worldDocumentName = 'world.md';
  static const String webMarkdownKeyPrefix = 'maaso.markdown.';

  static const Set<String> documentNames = <String>{
    soulDocumentName,
    masterDocumentName,
    worldDocumentName,
  };

  static const String description =
      'Unscoped legacy storage is quarantined. It must not be claimed by an '
      'account automatically; migration requires an explicit, auditable '
      'import flow.';
}

/// Stable, non-identifying storage namespace for one account in one backend
/// environment.
///
/// Raw account identifiers remain available to account lifecycle code, but are
/// never embedded in any returned database name, key prefix, or relative path.
final class AccountStorageScope {
  factory AccountStorageScope({
    required String environmentKey,
    required String accountUuid,
  }) {
    final validatedEnvironmentKey = _validateEnvironmentKey(environmentKey);
    final validatedAccountUuid = _validateIdentity(
      accountUuid,
      argumentName: 'accountUuid',
    );
    final accountDigest = _deriveDigest(
      domain: _accountDigestDomain,
      fields: <String>[validatedEnvironmentKey, validatedAccountUuid],
    );

    return AccountStorageScope._(
      environmentKey: validatedEnvironmentKey,
      accountUuid: validatedAccountUuid,
      accountDigest: accountDigest,
    );
  }

  AccountStorageScope._({
    required this.environmentKey,
    required this.accountUuid,
    required this.accountDigest,
  }) : accountDirectorySegments = List<String>.unmodifiable(<String>[
         storageRootDirectoryName,
         accountsDirectoryName,
         storageVersion,
         accountDigest,
       ]);

  static const int maxIdentityLength = 256;
  static const String storageVersion = 'v1';
  static const String storageRootDirectoryName = 'maaso';
  static const String accountsDirectoryName = 'accounts';
  static const String agentsDirectoryName = 'agents';
  static const String nativeDatabaseFileName = 'state.db';
  static const Set<String> supportedEnvironmentKeys = <String>{'test', 'prod'};

  static const String _accountDigestDomain =
      'com.futurpals.maaso.storage.account.v1';

  /// The exact backend boundary selected by the signed-in session.
  final String environmentKey;

  /// The opaque account identity. This value is never used directly in names.
  final String accountUuid;

  /// Full SHA-256 digest; intentionally not truncated to avoid collisions.
  final String accountDigest;

  /// Cross-platform logical namespace for account-owned key/value data.
  String get storageNamespace => 'maaso.account.$storageVersion.$accountDigest';

  /// Safe logical database name used by browser and in-memory backends.
  String get databaseName => '$storageNamespace.db';

  String get webDatabaseName => databaseName;

  /// Prefix for browser preferences and document keys owned by this account.
  String get webKeyPrefix => storageNamespace;

  /// Safe path segments relative to the platform application-support root.
  final List<String> accountDirectorySegments;

  String get nativeRelativeDirectory => accountDirectorySegments.join('/');

  List<String> get nativeDatabasePathSegments => List<String>.unmodifiable(
    <String>[...accountDirectorySegments, nativeDatabaseFileName],
  );

  String get nativeDatabaseRelativePath => nativeDatabasePathSegments.join('/');

  AgentStorageScope agent(String agentId) {
    return AgentStorageScope(accountScope: this, agentId: agentId);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AccountStorageScope &&
            other.environmentKey == environmentKey &&
            other.accountUuid == accountUuid;
  }

  @override
  int get hashCode => Object.hash(environmentKey, accountUuid);

  @override
  String toString() {
    return 'AccountStorageScope('
        'environmentKey: $environmentKey, accountDigest: $accountDigest)';
  }
}

/// Agent-owned child namespace inside an [AccountStorageScope].
final class AgentStorageScope {
  factory AgentStorageScope({
    required AccountStorageScope accountScope,
    required String agentId,
  }) {
    final validatedAgentId = _validateIdentity(
      agentId,
      argumentName: 'agentId',
    );
    final agentDigest = _deriveDigest(
      domain: _agentDigestDomain,
      fields: <String>[accountScope.accountDigest, validatedAgentId],
    );
    return AgentStorageScope._(
      accountScope: accountScope,
      agentId: validatedAgentId,
      agentDigest: agentDigest,
      agentDirectorySegments: List<String>.unmodifiable(<String>[
        ...accountScope.accountDirectorySegments,
        AccountStorageScope.agentsDirectoryName,
        agentDigest,
      ]),
    );
  }

  AgentStorageScope._({
    required this.accountScope,
    required this.agentId,
    required this.agentDigest,
    required this.agentDirectorySegments,
  });

  static const String _agentDigestDomain =
      'com.futurpals.maaso.storage.agent.v1';

  final AccountStorageScope accountScope;

  /// Opaque identity for lifecycle coordination, never for storage naming.
  final String agentId;

  /// Full SHA-256 digest of the parent scope and opaque agent identity.
  final String agentDigest;

  /// Safe path segments relative to the platform application-support root.
  final List<String> agentDirectorySegments;

  String get storageNamespace =>
      '${accountScope.storageNamespace}.agent.$agentDigest';

  String get webKeyPrefix => storageNamespace;

  String get nativeRelativeDirectory => agentDirectorySegments.join('/');

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AgentStorageScope &&
            other.accountScope == accountScope &&
            other.agentId == agentId;
  }

  @override
  int get hashCode => Object.hash(accountScope, agentId);

  @override
  String toString() {
    return 'AgentStorageScope('
        'accountDigest: ${accountScope.accountDigest}, '
        'agentDigest: $agentDigest)';
  }
}

/// Pure in-memory ownership gate for the currently mounted account scope.
///
/// A different account or environment cannot be mounted until the current
/// mount has been explicitly released. Each transition advances [generation],
/// so asynchronous work can fail closed when it holds a stale mount token.
final class AccountStorageScopeService {
  AccountStorageScopeMount? _activeMount;
  int _generation = 0;
  final Set<AccountStorageScopeBoundaryHold> _boundaryHolds =
      Set<AccountStorageScopeBoundaryHold>.identity();
  Completer<void>? _boundaryReleased;

  AccountStorageScope? get activeScope => _activeMount?.scope;

  AccountStorageScopeMount? get activeMount => _activeMount;

  bool get isMounted => _activeMount != null;

  int get generation => _generation;

  /// Completes only after every sensitive UI boundary has acknowledged that
  /// it is no longer visible.
  ///
  /// Account lifecycle code awaits this after invalidating the old mount and
  /// before publishing a replacement account. With no active holds the
  /// returned Future is already complete.
  Future<void> get whenBoundaryReleased =>
      _boundaryReleased?.future ?? Future<void>.value();

  AccountStorageScopeMount mount(AccountStorageScope scope) {
    final current = _activeMount;
    if (current != null) {
      if (current.scope == scope) return current;
      throw StateError(
        'Cannot switch account storage scope while another scope is mounted. '
        'Unmount generation ${current.generation} first.',
      );
    }
    if (_boundaryHolds.isNotEmpty) {
      throw const AccountStorageScopeBoundaryPendingException();
    }

    final mounted = AccountStorageScopeMount._(
      scope: scope,
      generation: ++_generation,
    );
    _activeMount = mounted;
    return mounted;
  }

  void unmount(AccountStorageScopeMount mount) {
    requireCurrent(mount);
    _activeMount = null;
    _generation++;
    mount._invalidate();
  }

  bool isCurrent(AccountStorageScopeMount mount) {
    final current = _activeMount;
    return current != null &&
        current.generation == mount.generation &&
        current.scope == mount.scope;
  }

  void requireCurrent(AccountStorageScopeMount mount) {
    if (!isCurrent(mount)) {
      throw StateError(
        'Account storage mount generation ${mount.generation} is stale.',
      );
    }
  }

  /// Prevents a replacement account from mounting while sensitive UI owned by
  /// [mount] is still being drained.
  AccountStorageScopeBoundaryHold acquireBoundaryHold(
    AccountStorageScopeMount mount,
  ) {
    requireCurrent(mount);
    if (_boundaryHolds.isEmpty) {
      _boundaryReleased = Completer<void>.sync();
    }
    final hold = AccountStorageScopeBoundaryHold._(this);
    _boundaryHolds.add(hold);
    return hold;
  }

  void _releaseBoundaryHold(AccountStorageScopeBoundaryHold hold) {
    if (!_boundaryHolds.remove(hold) || _boundaryHolds.isNotEmpty) return;
    final released = _boundaryReleased;
    _boundaryReleased = null;
    if (released != null && !released.isCompleted) released.complete();
  }
}

/// Stable failure used when a new account mount would cross sensitive UI.
final class AccountStorageScopeBoundaryPendingException implements Exception {
  const AccountStorageScopeBoundaryPendingException();

  @override
  String toString() => 'AccountStorageScopeBoundaryPendingException';
}

/// Idempotent token that keeps replacement account mounts fenced.
final class AccountStorageScopeBoundaryHold {
  AccountStorageScopeBoundaryHold._(this._service);

  AccountStorageScopeService? _service;

  bool get isReleased => _service == null;

  void release() {
    final service = _service;
    if (service == null) return;
    _service = null;
    service._releaseBoundaryHold(this);
  }
}

/// Immutable fencing token returned by [AccountStorageScopeService.mount].
final class AccountStorageScopeMount {
  AccountStorageScopeMount._({required this.scope, required this.generation});

  final AccountStorageScope scope;
  final int generation;
  final Completer<void> _invalidated = Completer<void>.sync();

  /// Sticky signal completed after this mount stops being current.
  Future<void> get whenInvalidated => _invalidated.future;

  void _invalidate() {
    if (!_invalidated.isCompleted) _invalidated.complete();
  }

  @override
  String toString() {
    return 'AccountStorageScopeMount('
        'accountDigest: ${scope.accountDigest}, generation: $generation)';
  }
}

String _validateEnvironmentKey(String value) {
  final validated = _validateIdentity(value, argumentName: 'environmentKey');
  if (!AccountStorageScope.supportedEnvironmentKeys.contains(validated)) {
    throw ArgumentError.value(
      value,
      'environmentKey',
      'must be one of ${AccountStorageScope.supportedEnvironmentKeys.join(', ')}',
    );
  }
  return validated;
}

String _validateIdentity(String value, {required String argumentName}) {
  if (_controlCharacterPattern.hasMatch(value)) {
    throw ArgumentError.value(
      value,
      argumentName,
      'must not contain control characters',
    );
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, argumentName, 'must not be empty');
  }
  if (trimmed.runes.length > AccountStorageScope.maxIdentityLength) {
    throw ArgumentError.value(
      value,
      argumentName,
      'must be at most ${AccountStorageScope.maxIdentityLength} characters',
    );
  }
  return trimmed;
}

String _deriveDigest({required String domain, required List<String> fields}) {
  final input = BytesBuilder(copy: false)
    ..add(_lengthPrefixedUtf8(_digestProtocolMarker))
    ..add(_lengthPrefixedUtf8(domain));
  for (final field in fields) {
    input.add(_lengthPrefixedUtf8(field));
  }
  return sha256.convert(input.takeBytes()).toString();
}

Uint8List _lengthPrefixedUtf8(String value) {
  final bytes = utf8.encode(value);
  final lengthPrefix = ByteData(4)..setUint32(0, bytes.length, Endian.big);
  return Uint8List.fromList(<int>[
    ...lengthPrefix.buffer.asUint8List(),
    ...bytes,
  ]);
}

const String _digestProtocolMarker = 'maaso.storage-scope.digest.v1';
final RegExp _controlCharacterPattern = RegExp(
  '[\\u0000-\\u001f\\u007f-\\u009f]',
);
