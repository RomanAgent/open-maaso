import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

import 'app_invocation_descriptor.dart';
import 'app_invocation_draft_snapshot.dart';
import 'app_invocation_execution_contract.dart';

/// Reads bytes from the same account's media store inside the caller's database
/// transaction. The owner injects a captured service, never a global lookup.
typedef AppInvocationCommittedImageReader =
    Future<Uint8List?> Function(
      DatabaseClient transaction, {
      required String id,
      required String mime,
      required int byteLength,
    });

/// A durable fixed input identity, never an execution grant.
final class AppInvocationRunRecord {
  AppInvocationRunRecord._(Map<String, Object?> value)
    : value = _json.parse(_json.canonicalize(value))! as Map<String, Object?>;
  final Map<String, Object?> value;
  String get invocationId => value['invocationId']! as String;
  String get submissionToken => value['submissionToken']! as String;
  String get turnId => value['turnId']! as String;
  String get sessionId => value['sessionId']! as String;
  String get contractDigest => value['contractDigest']! as String;
  String get adapterId => value['adapterId']! as String;
  String get adapterVersion => value['adapterVersion']! as String;
  String get status => value['status']! as String;
  AppInvocationIdentity get identity => _identity(value['identity']);
}

/// Only this account's invocation journal/data/temporary outputs are writable.
/// No source, installed app state, preview, publication or manual game key is
/// accepted by any method. Action reservations survive process restart and are
/// never permission to dispatch again.
final class AppInvocationStore {
  AppInvocationStore({
    required Database database,
    required this.scopeKey,
    required this.mountId,
    required this.processId,
    required bool Function() isCurrent,
    AppInvocationCommittedImageReader? committedImageReader,
  }) : _database = database,
       _isCurrent = isCurrent,
       _committedImageReader = committedImageReader {
    if (scopeKey.trim().isEmpty ||
        mountId.trim().isEmpty ||
        processId.trim().isEmpty) {
      throw ArgumentError('invocation_store_scope');
    }
  }
  final Database _database;
  final String scopeKey, mountId, processId;
  final bool Function() _isCurrent;
  final AppInvocationCommittedImageReader? _committedImageReader;
  bool _retired = false;
  final Set<Future<void>> _operations = {};
  Future<void>? _draining;

  Future<T> _operation<T>(Future<T> Function() operation) {
    if (!isCurrent)
      return Future<T>.error(StateError('invocation_store_retired'));
    final settled = Completer<void>();
    _operations.add(settled.future);
    final work = Future<T>.sync(operation);
    return work.whenComplete(() {
      _operations.remove(settled.future);
      settled.complete();
    });
  }

  Future<void> deactivateAndDrain() {
    retire();
    return _draining ??= Future.wait(_operations.toList()).then((_) {});
  }

  static final _runs = stringMapStoreFactory.store('app_invocation_runs.v1');
  static final _submissions = stringMapStoreFactory.store(
    'app_invocation_submissions.v1',
  );
  static final _actions = stringMapStoreFactory.store(
    'app_invocation_actions.v1',
  );
  static final _outputs = stringMapStoreFactory.store(
    'app_invocation_output_bytes.v1',
  );
  static final _data = stringMapStoreFactory.store(
    'app_invocation_application_data.v1',
  );

  bool get isCurrent => !_retired && _isCurrent();
  bool usesDatabase(Database database) => identical(_database, database);
  void _guard([bool Function()? canContinue]) {
    if (!isCurrent || canContinue?.call() == false)
      throw StateError('invocation_store_retired');
  }

  String _key(String invocationId) => jsonEncode([scopeKey, invocationId]);
  String _actionKey(String invocationId, String requestId) =>
      jsonEncode([scopeKey, invocationId, requestId]);
  String _outputKey(String invocationId, String requestId, String outputKey) =>
      jsonEncode([scopeKey, invocationId, requestId, outputKey]);

  Future<AppInvocationRunRecord> admit({
    required String submissionToken,
    required String turnId,
    required String sessionId,
    required AppInvocationDescriptor descriptor,
    required String adapterId,
    required String adapterVersion,
    required String inputDigest,
    required bool Function() canContinue,
    AppInvocationDraftSnapshot? draftSnapshot,
  }) => _operation(() async {
    _guard(canContinue);
    for (final value in [submissionToken, turnId, sessionId]) {
      requireAppInvocationIdentifier(value);
    }
    if (descriptor.identity.scopeKey != scopeKey ||
        descriptor.contractIssues.isNotEmpty ||
        adapterId.trim().isEmpty ||
        adapterVersion.trim().isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(inputDigest)) {
      throw const FormatException('invocation_admission_invalid');
    }
    if (draftSnapshot != null &&
        (draftSnapshot.scopeKey != scopeKey ||
            draftSnapshot.sourceId != descriptor.identity.sourceId ||
            draftSnapshot.revisionId != descriptor.identity.revisionId ||
            draftSnapshot.sourceDigest != descriptor.identity.sourceDigest ||
            draftSnapshot.contractDigest != descriptor.contractDigest ||
            draftSnapshot.adapterId != adapterId ||
            draftSnapshot.adapterVersion != adapterVersion ||
            draftSnapshot.inputDigest != inputDigest)) {
      throw const FormatException('invocation_draft_binding_mismatch');
    }
    final binding = <String, Object?>{
      'submissionToken': submissionToken,
      'turnId': turnId,
      'sessionId': sessionId,
      'identity': descriptor.identity.toJson(),
      'contractDigest': descriptor.contractDigest,
      'adapterId': adapterId,
      'adapterVersion': adapterVersion,
      'inputDigest': inputDigest,
      if (draftSnapshot != null) 'draftSnapshot': draftSnapshot.toJson(),
    };
    final digest = _digest(binding);
    final result = await _database.transaction((tx) async {
      _guard(canContinue);
      final index = _submissions.record(
        jsonEncode([scopeKey, submissionToken]),
      );
      final previous = await index.get(tx);
      _guard(canContinue);
      if (previous != null) {
        if (previous['bindingDigest'] != digest)
          throw StateError('invocation_submission_conflict');
        final run = await _readRun(tx, previous['invocationId']! as String);
        _guard(canContinue);
        if (run['bindingDigest'] != digest)
          throw StateError('invocation_run_corrupt');
        return AppInvocationRunRecord._(run);
      }
      final invocationId = const Uuid().v4();
      final run = <String, Object?>{
        'schemaVersion': 1,
        'scopeKey': scopeKey,
        'invocationId': invocationId,
        'processId': processId,
        ...binding,
        'bindingDigest': digest,
        'status': 'admitted',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _runs.record(_key(invocationId)).put(tx, run);
      _guard(canContinue);
      await index.put(tx, {
        'bindingDigest': digest,
        'invocationId': invocationId,
      });
      _guard(canContinue);
      return AppInvocationRunRecord._(run);
    });
    _guard(canContinue);
    return result;
  });

  Future<Map<String, Object?>> _readRun(
    DatabaseClient db,
    String invocationId,
  ) async {
    requireAppInvocationIdentifier(invocationId);
    final row = await _runs.record(_key(invocationId)).get(db);
    _guard();
    if (row == null ||
        row['schemaVersion'] != 1 ||
        row['scopeKey'] != scopeKey ||
        row['invocationId'] != invocationId) {
      throw StateError('invocation_run_unavailable');
    }
    return row;
  }

  Future<AppInvocationRunRecord> readRun(String invocationId) => _operation(
    () async {
      _guard();
      return AppInvocationRunRecord._(await _readRun(_database, invocationId));
    },
  );

  /// True means this exact action was durably reserved for the first time.
  /// False means query its existing receipt; never repeat dispatch.
  Future<bool> reserveAction({
    required String invocationId,
    required String requestId,
    required String actionId,
    required Map<String, Object?> arguments,
    required String observationId,
    required int expectedStateVersion,
    required bool Function() canContinue,
  }) => _operation(() async {
    _guard(canContinue);
    requireAppInvocationIdentifier(requestId);
    requireAppInvocationIdentifier(observationId);
    if (actionId.isEmpty ||
        actionId.length > 256 ||
        expectedStateVersion < 0 ||
        expectedStateVersion >= 9007199254740991) {
      throw const FormatException('invocation_action_invalid');
    }
    final frozen = appInvocationResultJson.parse(
      appInvocationResultJson.canonicalize(arguments),
    );
    final binding = <String, Object?>{
      'actionId': actionId,
      'arguments': frozen,
      'observationId': observationId,
      'expectedStateVersion': expectedStateVersion,
    };
    final digest = _digest(binding);
    final created = await _database.transaction((tx) async {
      _guard(canContinue);
      final run = await _readRun(tx, invocationId);
      _guard(canContinue);
      final ref = _actions.record(_actionKey(invocationId, requestId));
      final existing = await ref.get(tx);
      _guard(canContinue);
      if (existing != null) {
        if (existing['identityDigest'] != digest)
          throw StateError('invocation_request_conflict');
        return false;
      }
      if (run['status'] == 'cancelled' || run['status'] == 'resultCommitted')
        throw StateError('invocation_run_sealed');
      final count = await _actions.count(
        tx,
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('invocationId', invocationId),
        ]),
      );
      if (count >= 16) throw StateError('invocation_action_budget');
      await ref.put(tx, {
        'schemaVersion': 1,
        'scopeKey': scopeKey,
        'invocationId': invocationId,
        'requestId': requestId,
        'processId': processId,
        ...binding,
        'identityDigest': digest,
        'status': 'pending',
      });
      _guard(canContinue);
      await _runs.record(_key(invocationId)).put(tx, {
        ...run,
        'status': 'running',
      });
      _guard(canContinue);
      return true;
    });
    _guard(canContinue);
    return created;
  });

  Future<Map<String, Object?>?> readAction(
    String invocationId, {
    required String requestId,
  }) => _operation(() async {
    _guard();
    requireAppInvocationIdentifier(requestId);
    final result = await _database.transaction((tx) async {
      await _readRun(tx, invocationId);
      final ref = _actions.record(_actionKey(invocationId, requestId));
      final row = await ref.get(tx);
      _guard();
      if (row == null) return null;
      _checkActionRow(row, invocationId, requestId);
      if (row['status'] == 'pending' && row['processId'] != processId) {
        final unknown = {...row, 'status': 'outcomeUnknown'};
        await ref.put(tx, unknown);
        _guard();
        return _json.parse(_json.canonicalize(unknown))!
            as Map<String, Object?>;
      }
      return _json.parse(_json.canonicalize(row))! as Map<String, Object?>;
    });
    _guard();
    return result;
  });

  Future<void> settle(
    AppInvocationActionReceipt receipt, {
    required bool Function() canContinue,
  }) => _operation(() async {
    _guard(canContinue);
    await _database.transaction((tx) async {
      _guard(canContinue);
      final run = await _readRun(tx, receipt.invocationId);
      if (!_identity(run['identity']).matches(receipt.identity) ||
          run['contractDigest'] != receipt.contractDigest) {
        throw StateError('invocation_receipt_binding');
      }
      final ref = _actions.record(
        _actionKey(receipt.invocationId, receipt.requestId),
      );
      final action = await ref.get(tx);
      _guard(canContinue);
      if (action == null || action['actionId'] != receipt.actionId)
        throw StateError('invocation_action_unreserved');
      _checkActionRow(action, receipt.invocationId, receipt.requestId);
      if (action['receiptDigest'] != null) {
        if (action['receiptDigest'] == receipt.digest) return;
        // Querying the SAME request can resolve an unknown outcome. Applied or
        // failed receipts are terminal and may never be rewritten.
        if (action['status'] != AppInvocationActionStatus.outcomeUnknown.name ||
            receipt.status == AppInvocationActionStatus.outcomeUnknown) {
          throw StateError('invocation_receipt_conflict');
        }
      }
      final existingOutputs = await _outputs.find(
        tx,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('scopeKey', scopeKey),
            Filter.equals('invocationId', receipt.invocationId),
          ]),
        ),
      );
      _guard(canContinue);
      final retainedBytes = existingOutputs.fold<int>(
        0,
        (sum, row) => sum + (row.value['byteLength']! as int),
      );
      if (retainedBytes +
              receipt.outputs.fold<int>(
                0,
                (sum, image) => sum + image.bytes.length,
              ) >
          appInvocationMaximumImages * appInvocationMaximumImageBytes) {
        throw StateError('invocation_output_budget');
      }
      for (final output in receipt.outputs) {
        await _outputs
            .record(
              _outputKey(
                receipt.invocationId,
                receipt.requestId,
                output.producerOutputKey,
              ),
            )
            .put(tx, {
              'scopeKey': scopeKey,
              'invocationId': receipt.invocationId,
              'requestId': receipt.requestId,
              ...output.toMetadataJson(),
              'data': base64Encode(output.bytes),
            });
        _guard(canContinue);
      }
      await ref.put(tx, {
        ...action,
        'status': receipt.status.name,
        'receipt': receipt.toJson(),
        'receiptDigest': receipt.digest,
      });
      _guard(canContinue);
      if (run['status'] != 'cancelled' && run['status'] != 'resultCommitted') {
        await _runs.record(_key(receipt.invocationId)).put(tx, {
          ...run,
          'status': receipt.status.name,
          'lastRequestId': receipt.requestId,
        });
      }
      _guard(canContinue);
    });
    _guard(canContinue);
  });

  Future<AppInvocationActionReceipt?> readReceipt(
    String invocationId, {
    required String requestId,
  }) => _operation(() async {
    _guard();
    final result = await _database.transaction((tx) async {
      final run = await _readRun(tx, invocationId);
      final row = await _actions
          .record(_actionKey(invocationId, requestId))
          .get(tx);
      _guard();
      if (row == null) return null;
      _checkActionRow(row, invocationId, requestId);
      final wire = row['receipt'];
      if (wire == null) return null;
      if (wire is! Map ||
          wire['schemaVersion'] != 1 ||
          wire['invocationId'] != invocationId ||
          wire['requestId'] != requestId) {
        throw StateError('invocation_receipt_corrupt');
      }
      final images = <AppInvocationProducedImage>[];
      final metadata = wire['outputs'];
      if (metadata is! List || metadata.length > appInvocationMaximumImages)
        throw StateError('invocation_receipt_corrupt');
      for (final item in metadata) {
        if (item is! Map || item['producerOutputKey'] is! String)
          throw StateError('invocation_receipt_corrupt');
        final bytes = await _outputs
            .record(
              _outputKey(
                invocationId,
                requestId,
                item['producerOutputKey']! as String,
              ),
            )
            .get(tx);
        _guard();
        if (bytes == null ||
            bytes['scopeKey'] != scopeKey ||
            bytes['invocationId'] != invocationId ||
            bytes['requestId'] != requestId ||
            bytes['producerOutputKey'] != item['producerOutputKey'] ||
            bytes['sha256'] != item['sha256'] ||
            bytes['mime'] != item['mime'] ||
            bytes['byteLength'] != item['byteLength']) {
          throw StateError('invocation_output_unavailable');
        }
        final Uint8List originalBytes;
        final encoded = bytes['data'];
        if (encoded is String) {
          if (encoded.length >
              ((appInvocationMaximumImageBytes + 2) ~/ 3) * 4) {
            throw StateError('invocation_output_corrupt');
          }
          originalBytes = Uint8List.fromList(base64Decode(encoded));
        } else {
          final reader = _committedImageReader;
          if (reader == null ||
              bytes['mediaId'] != item['sha256'] ||
              item['mime'] is! String ||
              item['byteLength'] is! int) {
            throw StateError('invocation_output_unavailable');
          }
          final linked = await reader(
            tx,
            id: bytes['mediaId']! as String,
            mime: item['mime']! as String,
            byteLength: item['byteLength']! as int,
          );
          _guard();
          if (linked == null) {
            throw StateError('invocation_output_unavailable');
          }
          originalBytes = linked;
        }
        final image = AppInvocationProducedImage(
          producerOutputKey: item['producerOutputKey']! as String,
          mime: item['mime']! as String,
          bytes: originalBytes,
        );
        if (_json.canonicalize(image.toMetadataJson()) !=
                _json.canonicalize(item) ||
            image.sha256Digest != bytes['sha256'])
          throw StateError('invocation_output_corrupt');
        images.add(image);
      }
      final receipt = AppInvocationActionReceipt(
        invocationId: invocationId,
        requestId: requestId,
        actionId: wire['actionId']! as String,
        identity: _identity(wire['identity']),
        contractDigest: wire['contractDigest']! as String,
        status: AppInvocationActionStatus.values.byName(
          wire['status']! as String,
        ),
        stateVersion: wire['stateVersion']! as int,
        result: wire['result'],
        outputs: images,
        errorCode: wire['errorCode'] as String?,
      );
      if (!receipt.identity.matches(_identity(run['identity'])) ||
          receipt.contractDigest != run['contractDigest'] ||
          receipt.actionId != row['actionId'] ||
          receipt.digest != row['receiptDigest']) {
        throw StateError('invocation_receipt_corrupt');
      }
      return receipt;
    });
    _guard();
    return result;
  });

  /// Invoked by the result publisher inside its existing media/message/result
  /// transaction. A completed action is not a committed chat result until here.
  Future<void> markResultCommitted(
    Transaction tx, {
    required String invocationId,
    required String resultId,
    required int messageId,
    required bool Function() canContinue,
    String? requestId,
  }) => _operation(() async {
    _guard(canContinue);
    requireAppInvocationIdentifier(resultId);
    if (messageId < 0) throw ArgumentError('invocation_message_id');
    final run = await _readRun(tx, invocationId);
    _guard(canContinue);
    if (run['resultId'] != null) {
      if (run['resultId'] != resultId || run['messageId'] != messageId)
        throw StateError('invocation_result_conflict');
      return;
    }
    final completed = await _actions.count(
      tx,
      filter: Filter.and([
        Filter.equals('scopeKey', scopeKey),
        Filter.equals('invocationId', invocationId),
        Filter.equals('status', AppInvocationActionStatus.completed.name),
      ]),
    );
    _guard(canContinue);
    if (completed == 0) throw StateError('invocation_result_without_receipt');
    // Only the explicitly published final receipt is compacted. Intermediate
    // action receipts and callers without this optional link retain their
    // bounded temporary bytes for recovery.
    if (requestId != null) {
      requireAppInvocationIdentifier(requestId);
      final action = await _actions
          .record(_actionKey(invocationId, requestId))
          .get(tx);
      _guard(canContinue);
      if (action == null) {
        throw StateError('invocation_result_without_receipt');
      }
      _checkActionRow(action, invocationId, requestId);
      final receipt = action['receipt'];
      if (action['status'] != AppInvocationActionStatus.completed.name ||
          receipt is! Map ||
          receipt['schemaVersion'] != 1 ||
          receipt['invocationId'] != invocationId ||
          receipt['requestId'] != requestId ||
          receipt['status'] != AppInvocationActionStatus.completed.name ||
          receipt['actionId'] != action['actionId'] ||
          _digest(receipt) != action['receiptDigest'] ||
          receipt['contractDigest'] != run['contractDigest'] ||
          !_identity(receipt['identity']).matches(_identity(run['identity']))) {
        throw StateError('invocation_result_receipt_mismatch');
      }
      final metadata = receipt['outputs'];
      if (metadata is! List || metadata.length > appInvocationMaximumImages) {
        throw StateError('invocation_receipt_corrupt');
      }
      final reader = _committedImageReader;
      if (reader != null) {
        for (final item in metadata) {
          if (item is! Map ||
              item['producerOutputKey'] is! String ||
              item['sha256'] is! String ||
              item['mime'] is! String ||
              item['byteLength'] is! int) {
            throw StateError('invocation_receipt_corrupt');
          }
          final ref = _outputs.record(
            _outputKey(
              invocationId,
              requestId,
              item['producerOutputKey']! as String,
            ),
          );
          final temporary = await ref.get(tx);
          _guard(canContinue);
          if (temporary == null ||
              temporary['scopeKey'] != scopeKey ||
              temporary['invocationId'] != invocationId ||
              temporary['requestId'] != requestId ||
              temporary['producerOutputKey'] != item['producerOutputKey'] ||
              temporary['sha256'] != item['sha256'] ||
              temporary['mime'] != item['mime'] ||
              temporary['byteLength'] != item['byteLength']) {
            throw StateError('invocation_output_corrupt');
          }
          final linked = await reader(
            tx,
            id: item['sha256']! as String,
            mime: item['mime']! as String,
            byteLength: item['byteLength']! as int,
          );
          _guard(canContinue);
          if (linked == null) {
            throw StateError('invocation_published_output_unavailable');
          }
          final image = AppInvocationProducedImage(
            producerOutputKey: item['producerOutputKey']! as String,
            mime: item['mime']! as String,
            bytes: linked,
          );
          if (_json.canonicalize(image.toMetadataJson()) !=
              _json.canonicalize(item)) {
            throw StateError('invocation_output_corrupt');
          }
          final compacted = Map<String, Object?>.of(temporary)..remove('data');
          await ref.put(tx, {...compacted, 'mediaId': image.sha256Digest});
          _guard(canContinue);
        }
      }
    }
    await _runs.record(_key(invocationId)).put(tx, {
      ...run,
      'status': 'resultCommitted',
      'resultId': resultId,
      'messageId': messageId,
    });
    _guard(canContinue);
  });

  Future<void> cancel(String invocationId) => _operation(() async {
    _guard();
    await _database.transaction((tx) async {
      final run = await _readRun(tx, invocationId);
      if (run['status'] != 'resultCommitted') {
        await _runs.record(_key(invocationId)).put(tx, {
          ...run,
          'status': 'cancelled',
        });
      }
      _guard();
    });
    _guard();
  });

  AppInvocationApplicationDataPort applicationDataPort(
    String invocationId, {
    required bool Function() canContinue,
    void Function(Map<String, Object?> values)? validate,
  }) {
    _guard(canContinue);
    requireAppInvocationIdentifier(invocationId);
    return _InvocationDataPort(this, invocationId, canContinue, validate);
  }

  void retire() {
    _retired = true;
  }

  void _checkActionRow(
    Map<String, Object?> row,
    String invocationId,
    String requestId,
  ) {
    if (row['schemaVersion'] != 1 ||
        row['scopeKey'] != scopeKey ||
        row['invocationId'] != invocationId ||
        row['requestId'] != requestId) {
      throw StateError('invocation_action_corrupt');
    }
  }
}

final class _InvocationDataPort implements AppInvocationApplicationDataPort {
  _InvocationDataPort(
    this.store,
    this.invocationId,
    this.canContinue,
    this.validate,
  );
  final AppInvocationStore store;
  @override
  final String invocationId;
  final bool Function() canContinue;
  final void Function(Map<String, Object?> values)? validate;
  @override
  bool get isCurrent => store.isCurrent && canContinue();
  @override
  Future<({int version, Map<String, Object?> values})> read() =>
      store._operation(() async {
        store._guard(canContinue);
        await store._readRun(store._database, invocationId);
        final row = await AppInvocationStore._data
            .record(store._key(invocationId))
            .get(store._database);
        store._guard(canContinue);
        return _snapshot(row);
      });

  @override
  Future<({int version, Map<String, Object?> values})> save(
    Map<String, Object?> values, {
    required int expectedVersion,
    required bool Function() canContinue,
  }) => store._operation(() async {
    void guard() {
      store._guard(this.canContinue);
      store._guard(canContinue);
    }

    guard();
    if (expectedVersion < 0 || expectedVersion >= 9007199254740990)
      throw StateError('invocation_data_version');
    final frozen =
        appInvocationResultJson.parse(
              appInvocationResultJson.canonicalize(values),
            )!
            as Map<String, Object?>;
    validate?.call(frozen);
    final result = await store._database.transaction((tx) async {
      guard();
      final run = await store._readRun(tx, invocationId);
      if (run['status'] == 'cancelled' || run['status'] == 'resultCommitted')
        throw StateError('invocation_run_sealed');
      final ref = AppInvocationStore._data.record(store._key(invocationId));
      final previous = _snapshot(await ref.get(tx));
      guard();
      if (previous.version != expectedVersion)
        throw StateError('invocation_data_conflict');
      final next = (version: previous.version + 1, values: frozen);
      await ref.put(tx, {
        'scopeKey': store.scopeKey,
        'invocationId': invocationId,
        'version': next.version,
        'values': next.values,
      });
      guard();
      return next;
    });
    guard();
    return result;
  });

  ({int version, Map<String, Object?> values}) _snapshot(
    Map<String, Object?>? row,
  ) {
    if (row == null) return (version: 0, values: const {});
    if (row['scopeKey'] != store.scopeKey ||
        row['invocationId'] != invocationId ||
        row['version'] is! int ||
        (row['version']! as int) < 1 ||
        row['values'] is! Map<String, Object?>)
      throw StateError('invocation_data_corrupt');
    final values =
        appInvocationResultJson.parse(
              appInvocationResultJson.canonicalize(row['values']),
            )!
            as Map<String, Object?>;
    validate?.call(values);
    return (version: row['version']! as int, values: values);
  }
}

const _json = ProjectJsonCanonicalizer();
String _digest(Object? value) =>
    sha256.convert(utf8.encode(_json.canonicalize(value))).toString();
AppInvocationIdentity _identity(Object? value) {
  if (value is! Map) throw StateError('invocation_identity_corrupt');
  return AppInvocationIdentity(
    scopeKey: value['scopeKey']! as String,
    sourceId: value['sourceId']! as String,
    revisionId: value['revisionId']! as String,
    sourceDigest: value['sourceDigest']! as String,
  );
}
