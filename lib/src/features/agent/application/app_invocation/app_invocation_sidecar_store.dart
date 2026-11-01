import 'dart:convert';

import 'package:sembast/sembast.dart';

import 'app_invocation_descriptor.dart';
import 'app_invocation_sidecar.dart';

/// A cache race fence captured before reading a source. This opaque ticket is
/// not an app/runtime grant and carries no operation or device permissions.
final class AppInvocationSidecarReadTicket {
  AppInvocationSidecarReadTicket._(
    this._authority,
    this.sourceOrigin,
    this.sourceId,
    this._sourceEpoch,
    this._localEpoch,
  );
  final Object _authority;
  final String sourceOrigin, sourceId;
  final int _sourceEpoch, _localEpoch;
}

/// Synchronous source invalidation shared by peers on one live account mount.
/// It deliberately holds neither the Database nor any instance's authority.
final class _SidecarSourceFence {
  final epochs = <String, int>{};
  final blockedSources = <String>{};
}

/// Uses the host's existing account DB. Writes only sidecars and invalidation
/// records in its own store; never edits a widget, source or publication.
/// Mount IDs must be unique across remounts, including account A -> B -> A.
final class AppInvocationSidecarStore {
  AppInvocationSidecarStore({
    required Database database,
    required this.scopeKey,
    required this.mountId,
    required String Function() currentMountId,
    required bool Function() isCurrent,
  }) : _database = database,
       _currentMountId = currentMountId,
       _isCurrent = isCurrent {
    if (scopeKey.trim().isEmpty || mountId.trim().isEmpty) {
      throw ArgumentError('invalid_invocation_sidecar_store_scope');
    }
    final mounts = _fences[database] ??= <String, _SidecarSourceFence>{};
    _sharedFence = mounts.putIfAbsent(
      jsonEncode([scopeKey, mountId]),
      _SidecarSourceFence.new,
    );
  }

  final Database _database;
  final String scopeKey, mountId;
  final String Function() _currentMountId;
  final bool Function() _isCurrent;
  final Object _authority = Object();
  late final _SidecarSourceFence _sharedFence;
  Map<String, int> get _localEpochs => _sharedFence.epochs;
  Set<String> get _blockedSources => _sharedFence.blockedSources;
  bool _retired = false;
  // Database object identity is intentional. Do not retain a database through
  // this value or clear a live mount's fence when just one peer retires.
  static final _fences = Expando<Map<String, _SidecarSourceFence>>(
    'invocation_sidecar_source_fences',
  );
  static final _records = stringMapStoreFactory.store(
    'app_invocation_sidecars.v1',
  );

  void _guard() {
    if (_retired || !_isCurrent() || _currentMountId() != mountId) {
      throw StateError('invocation_sidecar_scope_retired');
    }
  }

  String _sourceKey(String origin, String id) =>
      jsonEncode(['source', scopeKey, origin, id]);

  String _sidecarKey(
    AppInvocationDescriptor descriptor,
    String sourceOrigin,
    String adapterId,
    String adapterVersion,
  ) => jsonEncode([
    'sidecar',
    scopeKey,
    sourceOrigin,
    descriptor.identity.sourceId,
    descriptor.identity.revisionId,
    descriptor.identity.sourceDigest,
    descriptor.contractDigest,
    appInvocationSidecarGeneratorVersion,
    adapterId,
    adapterVersion,
  ]);

  void _guardSource(String sourceKey, int localEpoch) {
    _guard();
    if ((_localEpochs[sourceKey] ?? 0) != localEpoch) {
      throw StateError('invocation_sidecar_source_invalidated');
    }
  }

  void _checkLocator(String origin, String id) {
    if (origin.trim().isEmpty ||
        origin.length > 256 ||
        id.trim().isEmpty ||
        id.length > 512) {
      throw ArgumentError('invalid_invocation_sidecar_source');
    }
  }

  ({int epoch, bool revoked}) _sourceState(
    Map<String, Object?>? row,
    String origin,
    String id,
  ) {
    if (row == null) return (epoch: 0, revoked: false);
    if (row['schemaVersion'] != 1 ||
        row['kind'] != 'source' ||
        row['scopeKey'] != scopeKey ||
        row['sourceOrigin'] != origin ||
        row['sourceId'] != id ||
        row['epoch'] is! int ||
        (row['epoch']! as int) < 0 ||
        (row['epoch']! as int) >= 9007199254740991 ||
        row['revoked'] is! bool) {
      throw StateError('invocation_sidecar_source_state_corrupt');
    }
    return (epoch: row['epoch']! as int, revoked: row['revoked']! as bool);
  }

  /// Capture before an asynchronous source read. A new read after invalidation
  /// may refresh the description only after the caller revalidates that source.
  Future<AppInvocationSidecarReadTicket> beginSourceRead({
    required String sourceOrigin,
    required String sourceId,
  }) async {
    _guard();
    _checkLocator(sourceOrigin, sourceId);
    final key = _sourceKey(sourceOrigin, sourceId);
    final localEpoch = _localEpochs[key] ?? 0;
    final ticket = await _database.transaction((tx) async {
      _guardSource(key, localEpoch);
      final row = await _records.record(key).get(tx);
      _guardSource(key, localEpoch);
      final state = _sourceState(row, sourceOrigin, sourceId);
      return AppInvocationSidecarReadTicket._(
        _authority,
        sourceOrigin,
        sourceId,
        state.epoch,
        localEpoch,
      );
    });
    _guardSource(key, localEpoch);
    return ticket;
  }

  /// The caller must supply a descriptor from its successful current source
  /// read. A cache hit or this ticket never substitutes for that revalidation.
  Future<AppInvocationSidecar> putForDescriptor({
    required AppInvocationDescriptor descriptor,
    required AppInvocationSidecarReadTicket ticket,
    required String adapterId,
    required String adapterVersion,
    required DateTime generatedAt,
  }) async {
    _guard();
    if (!identical(ticket._authority, _authority) ||
        descriptor.identity.scopeKey != scopeKey ||
        descriptor.identity.sourceId != ticket.sourceId) {
      throw StateError('invocation_sidecar_ticket_mismatch');
    }
    final sourceKey = _sourceKey(ticket.sourceOrigin, ticket.sourceId);
    _guardSource(sourceKey, ticket._localEpoch);
    final sidecar = buildAppInvocationSidecar(
      descriptor: descriptor,
      sourceOrigin: ticket.sourceOrigin,
      adapterId: adapterId,
      adapterVersion: adapterVersion,
      generatedAt: generatedAt,
    );
    await _database.transaction((tx) async {
      _guardSource(sourceKey, ticket._localEpoch);
      final source = _records.record(sourceKey);
      final state = _sourceState(
        await source.get(tx),
        ticket.sourceOrigin,
        ticket.sourceId,
      );
      _guardSource(sourceKey, ticket._localEpoch);
      if (state.epoch != ticket._sourceEpoch) {
        throw StateError('invocation_sidecar_source_invalidated');
      }
      await source.put(tx, {
        'schemaVersion': 1,
        'kind': 'source',
        'scopeKey': scopeKey,
        'sourceOrigin': ticket.sourceOrigin,
        'sourceId': ticket.sourceId,
        'epoch': state.epoch,
        'revoked': false,
      });
      _guardSource(sourceKey, ticket._localEpoch);
      await _records
          .record(
            _sidecarKey(
              descriptor,
              ticket.sourceOrigin,
              adapterId,
              adapterVersion,
            ),
          )
          .put(tx, {
            'schemaVersion': 1,
            'kind': 'sidecar',
            'scopeKey': scopeKey,
            'sourceOrigin': ticket.sourceOrigin,
            'sourceId': ticket.sourceId,
            'sourceEpoch': state.epoch,
            'sidecar': sidecar.toJson(),
          });
      _guardSource(sourceKey, ticket._localEpoch);
    });
    _guardSource(sourceKey, ticket._localEpoch);
    _blockedSources.remove(sourceKey);
    return sidecar;
  }

  Future<AppInvocationSidecar?> readForDescriptor({
    required AppInvocationDescriptor descriptor,
    required String sourceOrigin,
    required String adapterId,
    required String adapterVersion,
  }) async {
    _guard();
    _checkLocator(sourceOrigin, descriptor.identity.sourceId);
    if (descriptor.identity.scopeKey != scopeKey) {
      throw StateError('invocation_sidecar_scope_mismatch');
    }
    final sourceKey = _sourceKey(sourceOrigin, descriptor.identity.sourceId);
    if (_blockedSources.contains(sourceKey)) return null;
    final localEpoch = _localEpochs[sourceKey] ?? 0;
    final result = await _database.transaction((tx) async {
      _guardSource(sourceKey, localEpoch);
      final sourceRow = await _records.record(sourceKey).get(tx);
      _guardSource(sourceKey, localEpoch);
      if (sourceRow == null) return null;
      final state = _sourceState(
        sourceRow,
        sourceOrigin,
        descriptor.identity.sourceId,
      );
      _guardSource(sourceKey, localEpoch);
      if (state.revoked) return null;
      final record = _records.record(
        _sidecarKey(descriptor, sourceOrigin, adapterId, adapterVersion),
      );
      final row = await record.get(tx);
      _guardSource(sourceKey, localEpoch);
      if (row == null) return null;
      if (row['schemaVersion'] != 1 ||
          row['kind'] != 'sidecar' ||
          row['scopeKey'] != scopeKey ||
          row['sourceOrigin'] != sourceOrigin ||
          row['sourceId'] != descriptor.identity.sourceId ||
          row['sourceEpoch'] != state.epoch) {
        await record.delete(tx);
        _guardSource(sourceKey, localEpoch);
        return null;
      }
      try {
        return AppInvocationSidecar.restoreForDescriptor(
          record: row['sidecar'],
          descriptor: descriptor,
          sourceOrigin: sourceOrigin,
          adapterId: adapterId,
          adapterVersion: adapterVersion,
        );
      } on FormatException {
        await record.delete(tx);
        _guardSource(sourceKey, localEpoch);
        return null;
      }
    });
    _guardSource(sourceKey, localEpoch);
    return result;
  }

  /// Synchronously fences outstanding work, then persists the invalidation.
  /// Only this source's description records are removed. Invalidation reasons
  /// must come from the host; a missing row in a partial search is not withdrawal.
  Future<void> invalidateSource({
    required String sourceOrigin,
    required String sourceId,
    required String reason,
  }) async {
    _guard();
    _checkLocator(sourceOrigin, sourceId);
    if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(reason)) {
      throw ArgumentError('invalid_invocation_sidecar_invalidation_reason');
    }
    final key = _sourceKey(sourceOrigin, sourceId);
    _localEpochs[key] = (_localEpochs[key] ?? 0) + 1;
    _blockedSources.add(key);
    await _database.transaction((tx) async {
      _guard();
      final record = _records.record(key);
      final state = _sourceState(await record.get(tx), sourceOrigin, sourceId);
      _guard();
      if (state.epoch >= 9007199254740990) {
        throw StateError('invocation_sidecar_epoch_exhausted');
      }
      await record.put(tx, {
        'schemaVersion': 1,
        'kind': 'source',
        'scopeKey': scopeKey,
        'sourceOrigin': sourceOrigin,
        'sourceId': sourceId,
        'epoch': state.epoch + 1,
        'revoked': true,
        'reason': reason,
      });
      _guard();
      await _records.delete(
        tx,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('kind', 'sidecar'),
            Filter.equals('scopeKey', scopeKey),
            Filter.equals('sourceOrigin', sourceOrigin),
            Filter.equals('sourceId', sourceId),
          ]),
        ),
      );
      _guard();
    });
    _guard();
  }

  /// Does not close or erase the shared host database.
  void retire() {
    _retired = true;
  }
}
