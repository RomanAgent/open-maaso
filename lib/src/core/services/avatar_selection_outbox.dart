import 'dart:async';

import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast.dart';

enum AvatarSelectionOutboxStage {
  prepared,
  applied,
  compensateNeeded,
  compensating,
  superseded;

  static AvatarSelectionOutboxStage parse(Object? value) => switch (value) {
    'prepared' => AvatarSelectionOutboxStage.prepared,
    'applied' => AvatarSelectionOutboxStage.applied,
    'compensateNeeded' => AvatarSelectionOutboxStage.compensateNeeded,
    'compensating' => AvatarSelectionOutboxStage.compensating,
    'superseded' => AvatarSelectionOutboxStage.superseded,
    _ => throw const FormatException('avatar_selection_outbox_stage_invalid'),
  };
}

enum AvatarSelectionOutboxResolution {
  rollForward,
  compensate;

  static AvatarSelectionOutboxResolution parse(Object? value) =>
      switch (value) {
        'rollForward' => AvatarSelectionOutboxResolution.rollForward,
        'compensate' => AvatarSelectionOutboxResolution.compensate,
        _ => throw const FormatException(
          'avatar_selection_outbox_resolution_invalid',
        ),
      };
}

enum AvatarSelectionSupersededReason {
  setVersionConflict,
  compensationVersionConflict,
  currentChanged;

  static AvatarSelectionSupersededReason? parseNullable(Object? value) =>
      switch (value) {
        null => null,
        'setVersionConflict' =>
          AvatarSelectionSupersededReason.setVersionConflict,
        'compensationVersionConflict' =>
          AvatarSelectionSupersededReason.compensationVersionConflict,
        'currentChanged' => AvatarSelectionSupersededReason.currentChanged,
        _ => throw const FormatException(
          'avatar_selection_outbox_superseded_reason_invalid',
        ),
      };
}

sealed class AvatarSelectionOutboxException implements Exception {
  const AvatarSelectionOutboxException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class AvatarSelectionOutboxCorruptException
    extends AvatarSelectionOutboxException {
  const AvatarSelectionOutboxCorruptException()
    : super('avatar_selection_outbox_corrupt');
}

final class AvatarSelectionOutboxConflictException
    extends AvatarSelectionOutboxException {
  const AvatarSelectionOutboxConflictException([String? code])
    : super(code ?? 'avatar_selection_outbox_conflict');
}

final class AvatarSelectionOutboxUnavailableException
    extends AvatarSelectionOutboxException {
  const AvatarSelectionOutboxUnavailableException(super.code);
}

final class AvatarSelectionOutboxEntry {
  const AvatarSelectionOutboxEntry._({
    required this.accountScopeDigest,
    required this.agentScopeDigest,
    required this.ownerGeneration,
    required this.recordRevision,
    required this.stage,
    required this.resolution,
    required this.request,
    required this.compensationKey,
    required this.previousSelection,
    required this.appliedReceipt,
    required this.supersededReason,
    required this.createdAt,
    required this.updatedAt,
  });

  static const int schemaVersion = 1;

  final String accountScopeDigest;
  final String agentScopeDigest;
  final int ownerGeneration;
  final int recordRevision;
  final AvatarSelectionOutboxStage stage;
  final AvatarSelectionOutboxResolution resolution;
  final AvatarSelectionCommitRequest request;
  final String compensationKey;
  final AvatarSelectionState previousSelection;
  final AvatarSelectionReceipt? appliedReceipt;
  final AvatarSelectionSupersededReason? supersededReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get operationKey => request.idempotencyKey;

  AvatarSelectionCommitRequest get compensationRequest {
    final receipt = appliedReceipt;
    if (receipt == null) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_receipt_missing',
      );
    }
    return AvatarSelectionCommitRequest(
      agentId: request.agentId,
      modelId: receipt.previousSelection.modelId,
      expectedVersion: receipt.selection.version,
      idempotencyKey: compensationKey,
      assetOptions: request.assetOptions,
    );
  }

  Map<String, Object?> toStorageJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'accountScopeDigest': accountScopeDigest,
    'agentScopeDigest': agentScopeDigest,
    'ownerGeneration': ownerGeneration,
    'recordRevision': recordRevision,
    'stage': stage.name,
    'resolution': resolution.name,
    'request': request.toPersistenceJson(),
    'compensationKey': compensationKey,
    'previousSelection': previousSelection.toPersistenceJson(),
    'appliedReceipt': appliedReceipt?.toPersistenceJson(),
    'supersededReason': supersededReason?.name,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  AvatarSelectionOutboxEntry _copyWith({
    int? ownerGeneration,
    int? recordRevision,
    AvatarSelectionOutboxStage? stage,
    AvatarSelectionOutboxResolution? resolution,
    AvatarSelectionReceipt? appliedReceipt,
    bool preserveAppliedReceipt = true,
    AvatarSelectionSupersededReason? supersededReason,
    bool preserveSupersededReason = true,
    DateTime? updatedAt,
  }) => AvatarSelectionOutboxEntry._(
    accountScopeDigest: accountScopeDigest,
    agentScopeDigest: agentScopeDigest,
    ownerGeneration: ownerGeneration ?? this.ownerGeneration,
    recordRevision: recordRevision ?? this.recordRevision,
    stage: stage ?? this.stage,
    resolution: resolution ?? this.resolution,
    request: request,
    compensationKey: compensationKey,
    previousSelection: previousSelection,
    appliedReceipt: preserveAppliedReceipt
        ? appliedReceipt ?? this.appliedReceipt
        : appliedReceipt,
    supersededReason: preserveSupersededReason
        ? supersededReason ?? this.supersededReason
        : supersededReason,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

abstract interface class AvatarSelectionOutbox {
  AgentStorageScope get agentScope;

  int get ownerGeneration;

  Future<AvatarSelectionOutboxEntry?> read();

  Future<AvatarSelectionOutboxEntry?> inspectForRecovery();

  Future<AvatarSelectionOutboxEntry> adoptForRecovery({
    required String operationKey,
    required int expectedRevision,
  });

  Future<AvatarSelectionOutboxEntry> prepare({
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionState previousSelection,
    required String compensationKey,
  });

  Future<AvatarSelectionOutboxEntry> requestCompensation({
    required String operationKey,
    required int expectedRevision,
  });

  Future<AvatarSelectionOutboxEntry> recordApplied({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  });

  Future<AvatarSelectionOutboxEntry> beginCompensation({
    required String operationKey,
    required int expectedRevision,
  });

  Future<AvatarSelectionOutboxEntry> markSuperseded({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionSupersededReason reason,
  });

  Future<void> discardDefinitelyUncommitted({
    required String operationKey,
    required int expectedRevision,
  });

  Future<void> completeLocalCommit({
    required String operationKey,
    required int expectedRevision,
  });

  Future<void> completeCompensation({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  });

  Future<void> completeSuperseded({
    required String operationKey,
    required int expectedRevision,
  });

  Future<void> deactivateAndDrain();
}

/// A single-agent outbox in the already account-scoped Sembast database.
///
/// Historical generations are readable only through [inspectForRecovery] and
/// become writable only after [adoptForRecovery]. Every mutation rechecks the
/// exact operation key, record revision, stage, and current mount inside a
/// short Sembast transaction.
final class SembastAvatarSelectionOutbox implements AvatarSelectionOutbox {
  SembastAvatarSelectionOutbox({
    required DBService accountDatabase,
    required AccountStorageScopeMount mount,
    required this.agentScope,
    required AccountStorageScopeService storageScopes,
    DateTime Function()? clock,
  }) : _accountDatabase = accountDatabase,
       _mount = mount,
       _storageScopes = storageScopes,
       _clock = clock ?? DateTime.now {
    if (agentScope.accountScope != mount.scope) {
      throw ArgumentError.value(
        agentScope,
        'agentScope',
        'must belong to the mounted account scope',
      );
    }
    _positiveJsonInteger(mount.generation, 'ownerGeneration');
    _scopeDigest(mount.scope.accountDigest, 'accountScopeDigest');
    _scopeDigest(agentScope.agentDigest, 'agentScopeDigest');
  }

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('avatar_selection_outbox.v1');

  final DBService _accountDatabase;
  final AccountStorageScopeMount _mount;
  final AccountStorageScopeService _storageScopes;
  final DateTime Function() _clock;

  @override
  final AgentStorageScope agentScope;

  final Set<Future<void>> _operations = <Future<void>>{};
  bool _active = true;
  Future<void>? _drainFuture;

  @override
  int get ownerGeneration => _mount.generation;

  RecordRef<String, Map<String, Object?>> get _record =>
      _store.record(agentScope.agentDigest);

  @override
  Future<AvatarSelectionOutboxEntry?> read() => _admit(() async {
    final entry = await _read(_accountDatabase.raw);
    if (entry != null && entry.ownerGeneration != ownerGeneration) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_generation_not_adopted',
      );
    }
    return entry;
  });

  @override
  Future<AvatarSelectionOutboxEntry?> inspectForRecovery() =>
      _admit(() => _read(_accountDatabase.raw));

  @override
  Future<AvatarSelectionOutboxEntry> adoptForRecovery({
    required String operationKey,
    required int expectedRevision,
  }) => _admit(() {
    _operationKey(operationKey);
    _positiveJsonInteger(expectedRevision, 'expectedRevision');
    return _accountDatabase.raw.transaction((transaction) async {
      final current = _requireEntry(await _read(transaction));
      _requireOperation(current, operationKey, expectedRevision);
      if (current.ownerGeneration == ownerGeneration) return current;
      final next = _next(
        current,
        ownerGeneration: ownerGeneration,
        updatedAt: _nowAfter(current.updatedAt),
      );
      await _putFenced(transaction, next);
      return next;
    });
  });

  @override
  Future<AvatarSelectionOutboxEntry> prepare({
    required AvatarSelectionCommitRequest request,
    required AvatarSelectionState previousSelection,
    required String compensationKey,
  }) => _admit(() {
    AvatarSelectionIdempotencyKey.validate(compensationKey);
    if (request.agentId != agentScope.agentId ||
        previousSelection.agentId != request.agentId ||
        previousSelection.version != request.expectedVersion ||
        compensationKey == request.idempotencyKey) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_prepare_mismatch',
      );
    }
    return _accountDatabase.raw.transaction((transaction) async {
      final current = await _read(transaction);
      if (current != null) {
        if (current.ownerGeneration == ownerGeneration &&
            current.request.hasSameSemanticValue(request) &&
            current.previousSelection.hasSameSemanticValue(previousSelection) &&
            current.compensationKey == compensationKey) {
          return current;
        }
        throw const AvatarSelectionOutboxConflictException();
      }
      final now = _now();
      final prepared = AvatarSelectionOutboxEntry._(
        accountScopeDigest: agentScope.accountScope.accountDigest,
        agentScopeDigest: agentScope.agentDigest,
        ownerGeneration: ownerGeneration,
        recordRevision: 1,
        stage: AvatarSelectionOutboxStage.prepared,
        resolution: AvatarSelectionOutboxResolution.rollForward,
        request: request,
        compensationKey: compensationKey,
        previousSelection: previousSelection,
        appliedReceipt: null,
        supersededReason: null,
        createdAt: now,
        updatedAt: now,
      );
      await _putFenced(transaction, prepared);
      return prepared;
    });
  });

  @override
  Future<AvatarSelectionOutboxEntry> requestCompensation({
    required String operationKey,
    required int expectedRevision,
  }) => _mutate(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    mutation: (current) {
      switch (current.stage) {
        case AvatarSelectionOutboxStage.prepared:
          if (current.resolution ==
              AvatarSelectionOutboxResolution.compensate) {
            return current;
          }
          return _next(
            current,
            resolution: AvatarSelectionOutboxResolution.compensate,
          );
        case AvatarSelectionOutboxStage.applied:
          return _next(
            current,
            stage: AvatarSelectionOutboxStage.compensateNeeded,
            resolution: AvatarSelectionOutboxResolution.compensate,
          );
        case AvatarSelectionOutboxStage.compensateNeeded:
        case AvatarSelectionOutboxStage.compensating:
          return current;
        case AvatarSelectionOutboxStage.superseded:
          throw const AvatarSelectionOutboxConflictException(
            'avatar_selection_outbox_already_superseded',
          );
      }
    },
  );

  @override
  Future<AvatarSelectionOutboxEntry> recordApplied({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  }) => _mutate(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    mutation: (current) {
      receipt.validateAgainst(current.request);
      if (!receipt.previousSelection.hasSameSemanticValue(
        current.previousSelection,
      )) {
        throw const AvatarSelectionOutboxConflictException(
          'avatar_selection_outbox_receipt_previous_mismatch',
        );
      }
      if (current.stage == AvatarSelectionOutboxStage.prepared) {
        return _next(
          current,
          stage:
              current.resolution == AvatarSelectionOutboxResolution.compensate
              ? AvatarSelectionOutboxStage.compensateNeeded
              : AvatarSelectionOutboxStage.applied,
          appliedReceipt: receipt,
        );
      }
      if ((current.stage == AvatarSelectionOutboxStage.applied ||
              current.stage == AvatarSelectionOutboxStage.compensateNeeded) &&
          current.appliedReceipt?.hasSameSemanticValue(receipt) == true) {
        return current;
      }
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_invalid_applied_transition',
      );
    },
  );

  @override
  Future<AvatarSelectionOutboxEntry> beginCompensation({
    required String operationKey,
    required int expectedRevision,
  }) => _mutate(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    mutation: (current) {
      if (current.stage == AvatarSelectionOutboxStage.compensating) {
        return current;
      }
      if (current.stage != AvatarSelectionOutboxStage.compensateNeeded) {
        throw const AvatarSelectionOutboxConflictException(
          'avatar_selection_outbox_invalid_compensation_transition',
        );
      }
      return _next(current, stage: AvatarSelectionOutboxStage.compensating);
    },
  );

  @override
  Future<AvatarSelectionOutboxEntry> markSuperseded({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionSupersededReason reason,
  }) => _mutate(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    mutation: (current) {
      if (current.stage == AvatarSelectionOutboxStage.superseded) {
        if (current.supersededReason == reason) return current;
        throw const AvatarSelectionOutboxConflictException();
      }
      final allowed = switch (reason) {
        AvatarSelectionSupersededReason.setVersionConflict =>
          current.stage == AvatarSelectionOutboxStage.prepared &&
              current.appliedReceipt == null,
        AvatarSelectionSupersededReason.compensationVersionConflict =>
          current.stage == AvatarSelectionOutboxStage.compensating &&
              current.appliedReceipt != null,
        AvatarSelectionSupersededReason.currentChanged =>
          current.stage == AvatarSelectionOutboxStage.applied &&
              current.appliedReceipt != null,
      };
      if (!allowed) {
        throw const AvatarSelectionOutboxConflictException(
          'avatar_selection_outbox_invalid_superseded_transition',
        );
      }
      return _next(
        current,
        stage: AvatarSelectionOutboxStage.superseded,
        supersededReason: reason,
      );
    },
  );

  @override
  Future<void> discardDefinitelyUncommitted({
    required String operationKey,
    required int expectedRevision,
  }) => _deleteExpected(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    predicate: (current) =>
        current.stage == AvatarSelectionOutboxStage.prepared,
    invalidCode: 'avatar_selection_outbox_not_definitely_uncommitted',
  );

  @override
  Future<void> completeLocalCommit({
    required String operationKey,
    required int expectedRevision,
  }) => _deleteExpected(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    predicate: (current) =>
        current.stage == AvatarSelectionOutboxStage.applied &&
        current.resolution == AvatarSelectionOutboxResolution.rollForward &&
        current.appliedReceipt != null,
    invalidCode: 'avatar_selection_outbox_local_commit_not_applied',
  );

  @override
  Future<void> completeCompensation({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionReceipt receipt,
  }) => _deleteExpected(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    predicate: (current) {
      if (current.stage != AvatarSelectionOutboxStage.compensating) {
        return false;
      }
      receipt.validateAgainst(current.compensationRequest);
      return current.appliedReceipt != null &&
          receipt.previousSelection.hasSameSemanticValue(
            current.appliedReceipt!.selection,
          );
    },
    invalidCode: 'avatar_selection_outbox_compensation_not_in_flight',
  );

  @override
  Future<void> completeSuperseded({
    required String operationKey,
    required int expectedRevision,
  }) => _deleteExpected(
    operationKey: operationKey,
    expectedRevision: expectedRevision,
    predicate: (current) =>
        current.stage == AvatarSelectionOutboxStage.superseded &&
        current.supersededReason != null,
    invalidCode: 'avatar_selection_outbox_not_superseded',
  );

  Future<AvatarSelectionOutboxEntry> _mutate({
    required String operationKey,
    required int expectedRevision,
    required AvatarSelectionOutboxEntry Function(
      AvatarSelectionOutboxEntry current,
    )
    mutation,
  }) => _admit(() {
    _operationKey(operationKey);
    _positiveJsonInteger(expectedRevision, 'expectedRevision');
    return _accountDatabase.raw.transaction((transaction) async {
      final current = _requireEntry(await _read(transaction));
      _requireOwnedOperation(current, operationKey, expectedRevision);
      final candidate = mutation(current);
      if (identical(candidate, current)) return current;
      final next = candidate._copyWith(
        recordRevision: current.recordRevision + 1,
        updatedAt: _nowAfter(current.updatedAt),
      );
      _validateEntry(next);
      await _putFenced(transaction, next);
      return next;
    });
  });

  Future<void> _deleteExpected({
    required String operationKey,
    required int expectedRevision,
    required bool Function(AvatarSelectionOutboxEntry current) predicate,
    required String invalidCode,
  }) => _admit(() {
    _operationKey(operationKey);
    _positiveJsonInteger(expectedRevision, 'expectedRevision');
    return _accountDatabase.raw.transaction((transaction) async {
      final current = _requireEntry(await _read(transaction));
      _requireOwnedOperation(current, operationKey, expectedRevision);
      if (!predicate(current)) {
        throw AvatarSelectionOutboxConflictException(invalidCode);
      }
      _requireCurrentMount();
      await _record.delete(transaction);
    });
  });

  AvatarSelectionOutboxEntry _next(
    AvatarSelectionOutboxEntry current, {
    int? ownerGeneration,
    AvatarSelectionOutboxStage? stage,
    AvatarSelectionOutboxResolution? resolution,
    AvatarSelectionReceipt? appliedReceipt,
    AvatarSelectionSupersededReason? supersededReason,
    DateTime? updatedAt,
  }) => current._copyWith(
    ownerGeneration: ownerGeneration,
    recordRevision: current.recordRevision + 1,
    stage: stage,
    resolution: resolution,
    appliedReceipt: appliedReceipt,
    supersededReason: supersededReason,
    updatedAt: updatedAt ?? _nowAfter(current.updatedAt),
  );

  Future<AvatarSelectionOutboxEntry?> _read(DatabaseClient client) async {
    final raw = await _record.get(client);
    if (raw == null) return null;
    try {
      return _decodeEntry(raw);
    } on AvatarSelectionOutboxCorruptException {
      rethrow;
    } on Object {
      throw const AvatarSelectionOutboxCorruptException();
    }
  }

  AvatarSelectionOutboxEntry _decodeEntry(Object? source) {
    final json = _strictMap(source);
    const fields = <String>{
      'schemaVersion',
      'accountScopeDigest',
      'agentScopeDigest',
      'ownerGeneration',
      'recordRevision',
      'stage',
      'resolution',
      'request',
      'compensationKey',
      'previousSelection',
      'appliedReceipt',
      'supersededReason',
      'createdAt',
      'updatedAt',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['schemaVersion'] != AvatarSelectionOutboxEntry.schemaVersion) {
      throw const AvatarSelectionOutboxCorruptException();
    }
    final accountDigest = _scopeDigest(
      json['accountScopeDigest'],
      'accountScopeDigest',
    );
    final agentDigest = _scopeDigest(
      json['agentScopeDigest'],
      'agentScopeDigest',
    );
    if (accountDigest != agentScope.accountScope.accountDigest ||
        agentDigest != agentScope.agentDigest) {
      throw const AvatarSelectionOutboxCorruptException();
    }
    final entry = AvatarSelectionOutboxEntry._(
      accountScopeDigest: accountDigest,
      agentScopeDigest: agentDigest,
      ownerGeneration: _positiveJsonInteger(
        json['ownerGeneration'],
        'ownerGeneration',
      ),
      recordRevision: _positiveJsonInteger(
        json['recordRevision'],
        'recordRevision',
      ),
      stage: AvatarSelectionOutboxStage.parse(json['stage']),
      resolution: AvatarSelectionOutboxResolution.parse(json['resolution']),
      request: AvatarSelectionCommitRequest.fromPersistenceJson(
        json['request'],
      ),
      compensationKey: _operationKey(json['compensationKey']),
      previousSelection: AvatarSelectionState.fromPersistenceJson(
        json['previousSelection'],
      ),
      appliedReceipt: json['appliedReceipt'] == null
          ? null
          : AvatarSelectionReceipt.fromPersistenceJson(json['appliedReceipt']),
      supersededReason: AvatarSelectionSupersededReason.parseNullable(
        json['supersededReason'],
      ),
      createdAt: _utcTimestamp(json['createdAt'], 'createdAt'),
      updatedAt: _utcTimestamp(json['updatedAt'], 'updatedAt'),
    );
    _validateEntry(entry);
    return entry;
  }

  void _validateEntry(AvatarSelectionOutboxEntry entry) {
    _positiveJsonInteger(entry.ownerGeneration, 'ownerGeneration');
    _positiveJsonInteger(entry.recordRevision, 'recordRevision');
    if (entry.request.agentId != agentScope.agentId ||
        entry.previousSelection.agentId != entry.request.agentId ||
        entry.previousSelection.version != entry.request.expectedVersion ||
        entry.compensationKey == entry.operationKey ||
        entry.updatedAt.isBefore(entry.createdAt)) {
      throw const AvatarSelectionOutboxCorruptException();
    }
    final receipt = entry.appliedReceipt;
    if (receipt != null) {
      receipt.validateAgainst(entry.request);
      if (!receipt.previousSelection.hasSameSemanticValue(
        entry.previousSelection,
      )) {
        throw const AvatarSelectionOutboxCorruptException();
      }
    }
    final valid = switch (entry.stage) {
      AvatarSelectionOutboxStage.prepared =>
        receipt == null && entry.supersededReason == null,
      AvatarSelectionOutboxStage.applied =>
        receipt != null &&
            entry.resolution == AvatarSelectionOutboxResolution.rollForward &&
            entry.supersededReason == null,
      AvatarSelectionOutboxStage.compensateNeeded ||
      AvatarSelectionOutboxStage.compensating =>
        receipt != null &&
            entry.resolution == AvatarSelectionOutboxResolution.compensate &&
            entry.supersededReason == null,
      AvatarSelectionOutboxStage.superseded =>
        entry.supersededReason != null &&
            switch (entry.supersededReason!) {
              AvatarSelectionSupersededReason.setVersionConflict =>
                receipt == null,
              AvatarSelectionSupersededReason.compensationVersionConflict =>
                receipt != null &&
                    entry.resolution ==
                        AvatarSelectionOutboxResolution.compensate,
              AvatarSelectionSupersededReason.currentChanged => receipt != null,
            },
    };
    if (!valid) throw const AvatarSelectionOutboxCorruptException();
  }

  Future<void> _putFenced(
    Transaction transaction,
    AvatarSelectionOutboxEntry entry,
  ) async {
    _validateEntry(entry);
    _requireCurrentMount();
    await _record.put(transaction, entry.toStorageJson());
  }

  AvatarSelectionOutboxEntry _requireEntry(AvatarSelectionOutboxEntry? entry) =>
      entry ??
      (throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_missing',
      ));

  void _requireOperation(
    AvatarSelectionOutboxEntry current,
    String operationKey,
    int expectedRevision,
  ) {
    if (current.operationKey != operationKey ||
        current.recordRevision != expectedRevision) {
      throw const AvatarSelectionOutboxConflictException();
    }
  }

  void _requireOwnedOperation(
    AvatarSelectionOutboxEntry current,
    String operationKey,
    int expectedRevision,
  ) {
    _requireOperation(current, operationKey, expectedRevision);
    if (current.ownerGeneration != ownerGeneration) {
      throw const AvatarSelectionOutboxConflictException(
        'avatar_selection_outbox_generation_not_adopted',
      );
    }
  }

  void _requireCurrentMount() {
    if (!_storageScopes.isCurrent(_mount)) {
      throw const AvatarSelectionOutboxUnavailableException(
        'avatar_selection_outbox_stale_mount',
      );
    }
  }

  Future<T> _admit<T>(FutureOr<T> Function() operation) {
    if (!_active) {
      return Future<T>.error(
        const AvatarSelectionOutboxUnavailableException(
          'avatar_selection_outbox_inactive',
        ),
      );
    }
    try {
      _requireCurrentMount();
    } on Object catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
    final result = Future<T>.sync(operation);
    late final Future<void> tracked;
    tracked = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations.remove(tracked));
    _operations.add(tracked);
    return result;
  }

  @override
  Future<void> deactivateAndDrain() {
    final existing = _drainFuture;
    if (existing != null) return existing;
    _active = false;
    late final Future<void> draining;
    draining = _waitForOperations().whenComplete(() {
      if (identical(_drainFuture, draining)) _drainFuture = null;
    });
    _drainFuture = draining;
    return draining;
  }

  Future<void> _waitForOperations() async {
    while (_operations.isNotEmpty) {
      await Future.wait<void>(_operations.toList(growable: false));
    }
  }

  DateTime _now() {
    final value = _clock().toUtc();
    if (!value.isUtc) {
      throw const AvatarSelectionOutboxUnavailableException(
        'avatar_selection_outbox_clock_invalid',
      );
    }
    return value;
  }

  DateTime _nowAfter(DateTime previous) {
    final now = _now();
    return now.isBefore(previous) ? previous : now;
  }
}

Map<String, Object?> _strictMap(Object? source) {
  if (source is! Map) throw const AvatarSelectionOutboxCorruptException();
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    if (entry.key is! String || result.containsKey(entry.key)) {
      throw const AvatarSelectionOutboxCorruptException();
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

int _positiveJsonInteger(Object? value, String field) {
  if (value is! int ||
      value <= 0 ||
      value > maxAvatarSelectionJsonSafeInteger) {
    throw FormatException('avatar_selection_outbox_${field}_invalid');
  }
  return value;
}

String _scopeDigest(Object? value, String field) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('avatar_selection_outbox_${field}_invalid');
  }
  return value;
}

String _operationKey(Object? value) {
  if (value is! String) {
    throw const FormatException(
      'avatar_selection_outbox_operation_key_invalid',
    );
  }
  return AvatarSelectionIdempotencyKey.validate(value);
}

DateTime _utcTimestamp(Object? value, String field) {
  if (value is! String) {
    throw FormatException('avatar_selection_outbox_${field}_invalid');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != value) {
    throw FormatException('avatar_selection_outbox_${field}_invalid');
  }
  return parsed;
}
