import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/app_invocation_chat_reference.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'app_invocation_draft_snapshot.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast.dart';
import 'app_invocation_execution_contract.dart';
import 'app_invocation_store.dart';

/// Receives only verified, journaled native receipts. It never executes a work.
final class AppInvocationResultStore {
  AppInvocationResultStore({
    required this.database,
    required this.invocationStore,
    required this.media,
    required this.scopeKey,
    required this.mountId,
    required String Function() currentMountId,
    required bool Function() isCurrent,
  }) : _currentMountId = currentMountId,
       _isCurrent = isCurrent {
    if (scopeKey.isEmpty ||
        mountId.isEmpty ||
        invocationStore.scopeKey != scopeKey ||
        invocationStore.mountId != mountId ||
        !invocationStore.usesDatabase(database.raw) ||
        !media.usesDatabase(database.raw))
      throw ArgumentError('invocation_result_scope');
  }
  final DBService database;
  final AppInvocationStore invocationStore;
  final ChatMediaService media;
  final String scopeKey, mountId;
  final String Function() _currentMountId;
  final bool Function() _isCurrent;
  bool _retired = false;
  final _pending = <Future<Object?>>{};
  Future<void>? _drain;
  Future<T> _track<T>(Future<T> Function() operation) {
    final task = Future<T>.sync(operation);
    _pending.add(task);
    return task.whenComplete(() => _pending.remove(task));
  }

  Future<void> deactivateAndDrain() {
    _retired = true;
    return _drain ??= () async {
      while (_pending.isNotEmpty) {
        await Future.wait(
          _pending.toList().map((task) async {
            try {
              await task;
            } on Object {
              /* the caller owns its failure */
            }
          }),
        );
      }
    }();
  }

  static final _results = stringMapStoreFactory.store(
    'app_invocation_results.v1',
  );
  static final _outputIds = stringMapStoreFactory.store(
    'app_invocation_output_ids.v1',
  );
  static const _json = ProjectJsonCanonicalizer(
    maxBytes: 512 * 1024,
    maxDepth: 24,
    maxNodes: 8192,
  );

  bool get isCurrent =>
      !_retired &&
      _isCurrent() &&
      _currentMountId() == mountId &&
      invocationStore.isCurrent &&
      media.isCurrent;
  void _guard() {
    if (!isCurrent) throw StateError('invocation_result_scope_retired');
  }

  void retire() {
    _retired = true;
  }

  String _resultKey(String invocationId, String resultId) =>
      jsonEncode([scopeKey, invocationId, resultId]);
  static bool _ownerCurrent(bool Function()? owner) {
    try {
      return owner?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  static String _digest(Object? value) =>
      sha256.convert(utf8.encode(_json.canonicalize(value))).toString();

  Future<PreparedInvocationResult> prepare({
    required AppInvocationActionReceipt receipt,
    required String sourceTitle,
    required String summary,
    AppletChatReference? appletReference,
    bool Function()? isOwnerCurrent,
  }) => _track(
    () => _prepare(
      receipt: receipt,
      sourceTitle: sourceTitle,
      summary: summary,
      appletReference: appletReference,
      isOwnerCurrent: isOwnerCurrent,
    ),
  );

  Future<PreparedInvocationResult> _prepare({
    required AppInvocationActionReceipt receipt,
    required String sourceTitle,
    required String summary,
    AppletChatReference? appletReference,
    bool Function()? isOwnerCurrent,
  }) async {
    void check() {
      _guard();
      if (!_ownerCurrent(isOwnerCurrent))
        throw StateError('invocation_result_owner_retired');
    }

    check();
    if (receipt.identity.scopeKey != scopeKey ||
        receipt.status != AppInvocationActionStatus.completed ||
        sourceTitle.trim().isEmpty ||
        sourceTitle.length > 160 ||
        summary.length > 8192 ||
        (summary.trim().isEmpty && receipt.outputs.isEmpty)) {
      throw const FormatException('invocation_result_invalid');
    }
    final reference = appletReference == null
        ? null
        : AppletChatReference.tryParse(appletReference.toJson());
    if (appletReference != null &&
        (reference == null ||
            reference.id != receipt.identity.sourceId ||
            reference.scopeKey != scopeKey ||
            reference.sourceSha256 != receipt.identity.sourceDigest ||
            'cloud:${reference.revision}' != receipt.identity.revisionId)) {
      throw const FormatException('invocation_result_reference');
    }
    final persisted = await invocationStore.readReceipt(
      receipt.invocationId,
      requestId: receipt.requestId,
    );
    check();
    if (persisted == null || persisted.digest != receipt.digest)
      throw StateError('invocation_result_receipt_mismatch');
    final run = await invocationStore.readRun(receipt.invocationId);
    check();
    if (!run.identity.matches(persisted.identity) ||
        run.contractDigest != persisted.contractDigest) {
      throw StateError('invocation_result_identity_conflict');
    }
    final rawDraft = run.value['draftSnapshot'];
    if (rawDraft != null) {
      final draft = AppInvocationDraftSnapshot.fromJson(rawDraft);
      if (draft.sourceTitle != sourceTitle ||
          draft.scopeKey != scopeKey ||
          draft.sourceId != persisted.identity.sourceId ||
          draft.revisionId != persisted.identity.revisionId ||
          draft.sourceDigest != persisted.identity.sourceDigest ||
          draft.contractDigest != persisted.contractDigest) {
        throw StateError('invocation_result_source_metadata');
      }
    }
    final resultId =
        'result-${_digest([scopeKey, receipt.invocationId, receipt.requestId])}';
    final invocationReference = AppInvocationChatReference(
      scopeKey: scopeKey,
      sessionId: run.sessionId,
      invocationId: persisted.invocationId,
      sourceId: persisted.identity.sourceId,
      revisionId: persisted.identity.revisionId,
      sourceDigest: persisted.identity.sourceDigest,
      contractDigest: persisted.contractDigest,
      sourceTitle: sourceTitle,
      status: AppInvocationChatStatus.completed,
      requestId: persisted.requestId,
      resultId: resultId,
    );
    final outputs = <Map<String, Object?>>[
      for (final output in persisted.outputs)
        {
          ...output.toMetadataJson(),
          'outputId': _digest([
            scopeKey,
            receipt.invocationId,
            output.producerOutputKey,
          ]),
          'mediaId': output.sha256Digest,
        },
    ];
    final manifest = <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': scopeKey,
      'invocationId': persisted.invocationId,
      'requestId': persisted.requestId,
      'resultId': resultId,
      'identity': persisted.identity.toJson(),
      'contractDigest': persisted.contractDigest,
      'receiptDigest': persisted.digest,
      'status': persisted.status.name,
      'sessionId': run.sessionId,
      'invocationReference': invocationReference.toJson(),
      'sourceTitle': sourceTitle,
      'summary': summary,
      'result': persisted.result,
      'outputs': outputs,
      if (reference != null) 'appletReference': reference.toJson(),
    };
    final fingerprint = _digest(manifest);
    final key = _resultKey(persisted.invocationId, resultId);
    // This identity mapping precedes decoding/import, including failed imports.
    await database.raw.transaction((tx) async {
      check();
      for (final output in outputs) {
        final idKey = jsonEncode([
          scopeKey,
          persisted.invocationId,
          output['producerOutputKey'],
        ]);
        final record = _outputIds.record(idKey);
        final old = await record.get(tx);
        check();
        if (old != null &&
            _json.canonicalize(old) != _json.canonicalize(output))
          throw StateError('invocation_output_identity_conflict');
        if (old == null) await record.put(tx, output);
        check();
      }
      final record = _results.record(key);
      final old = await record.get(tx);
      check();
      if (old != null && old['fingerprint'] != fingerprint)
        throw StateError('invocation_result_identity_conflict');
      if (old == null)
        await record.put(tx, {
          'state': 'collectingOutputs',
          'fingerprint': fingerprint,
          'manifest': manifest,
        });
      check();
    });
    final images = <PreparedChatMedia>[];
    for (final output in persisted.outputs) {
      images.add(await media.prepareInvocationOutput(output));
      check();
    }
    return PreparedInvocationResult._(
      this,
      key: key,
      resultId: resultId,
      receipt: persisted,
      summary: summary,
      reference: reference,
      invocationReference: invocationReference,
      isOwnerCurrent: isOwnerCurrent,
      manifest: manifest,
      fingerprint: fingerprint,
      images: images,
    );
  }

  /// Re-receives the original journaled outcome; never runs or changes a work.
  /// Established wording/metadata are immutable across recovery turns.
  Future<PreparedInvocationResult> prepareRecovery({
    required String invocationId,
    required String requestId,
  }) => _track(() => _prepareRecovery(invocationId, requestId));

  Future<PreparedInvocationResult> _prepareRecovery(
    String invocationId,
    String requestId,
  ) async {
    _guard();
    final receipt = await invocationStore.readReceipt(
      invocationId,
      requestId: requestId,
    );
    _guard();
    if (receipt == null ||
        receipt.status != AppInvocationActionStatus.completed) {
      throw StateError('invocation_result_unavailable');
    }
    final id = 'result-${_digest([scopeKey, invocationId, requestId])}';
    final record = await _results
        .record(_resultKey(invocationId, id))
        .get(database.raw);
    _guard();
    if (record != null) {
      final manifest = record['manifest'];
      if (manifest is! Map ||
          _digest(manifest) != record['fingerprint'] ||
          manifest['scopeKey'] != scopeKey ||
          manifest['invocationId'] != invocationId ||
          manifest['requestId'] != requestId ||
          manifest['resultId'] != id ||
          manifest['receiptDigest'] != receipt.digest ||
          manifest['summary'] is! String ||
          manifest['sourceTitle'] is! String)
        throw StateError('invocation_result_corrupt');
      final rawReference = manifest['appletReference'];
      final reference = AppletChatReference.tryParse(rawReference);
      if (rawReference != null && reference == null)
        throw StateError('invocation_result_corrupt');
      return _prepare(
        receipt: receipt,
        sourceTitle: manifest['sourceTitle'] as String,
        summary: manifest['summary'] as String,
        appletReference: reference,
      );
    }
    final run = await invocationStore.readRun(invocationId);
    _guard();
    final draft = AppInvocationDraftSnapshot.fromJson(
      run.value['draftSnapshot'],
    );
    if (draft.scopeKey != scopeKey ||
        draft.sourceId != receipt.identity.sourceId ||
        draft.revisionId != receipt.identity.revisionId ||
        draft.sourceDigest != receipt.identity.sourceDigest ||
        draft.contractDigest != receipt.contractDigest ||
        !run.identity.matches(receipt.identity) ||
        run.contractDigest != receipt.contractDigest ||
        draft.sourceTitle.trim().isEmpty) {
      throw StateError('invocation_result_metadata_unavailable');
    }
    final summary = AgentPromptCatalog.currentLocale.name.startsWith('zh')
        ? '${draft.sourceTitle}已完成'
        : '${draft.sourceTitle} completed';
    return _prepare(
      receipt: receipt,
      sourceTitle: draft.sourceTitle,
      summary: summary,
    );
  }

  Future<Map<String, Object?>?> readResult(
    String invocationId,
    String resultId,
  ) => _track(() => _readResult(invocationId, resultId));

  Future<Map<String, Object?>?> _readResult(
    String invocationId,
    String resultId,
  ) async {
    _guard();
    final value = await _results
        .record(_resultKey(invocationId, resultId))
        .get(database.raw);
    _guard();
    return value == null
        ? null
        : Map<String, Object?>.from(
            _json.parse(_json.canonicalize(value)) as Map,
          );
  }
}

/// A single native-owned final publication, never constructible from model JSON.
final class PreparedInvocationResult
    implements ConversationPublicationTransaction {
  PreparedInvocationResult._(
    this._store, {
    required String key,
    required this.resultId,
    required AppInvocationActionReceipt receipt,
    required this.summary,
    required AppletChatReference? reference,
    required this.invocationReference,
    required bool Function()? isOwnerCurrent,
    required Map<String, Object?> manifest,
    required String fingerprint,
    required List<PreparedChatMedia> images,
  }) : _key = key,
       _isOwnerCurrent = isOwnerCurrent,
       _receipt = receipt,
       _referenceJson = reference == null
           ? null
           : AppInvocationResultStore._json.canonicalize(reference.toJson()),
       _manifest = AppInvocationResultStore._json.canonicalize(manifest),
       _fingerprint = fingerprint,
       _images = List.unmodifiable(images);
  final AppInvocationResultStore _store;
  final bool Function()? _isOwnerCurrent;
  final String _key, resultId, summary, _manifest, _fingerprint;
  final AppInvocationActionReceipt _receipt;
  final List<PreparedChatMedia> _images;
  final AppInvocationChatReference invocationReference;
  final String? _referenceJson;
  AppletChatReference? get appletReference => _referenceJson == null
      ? null
      : AppletChatReference.tryParse(
          AppInvocationResultStore._json.parse(_referenceJson),
        );
  String get utteranceId => 'invocation:$resultId';
  String get invocationId => _receipt.invocationId;
  String get scopeKey => _store.scopeKey;
  String get idempotencyKey =>
      'invocation-result:${AppInvocationResultStore._digest([scopeKey, invocationId, resultId])}';
  List<ChatAttachment> get attachments =>
      List.unmodifiable(_images.map((image) => image.attachment));
  bool get isCurrent =>
      _store.isCurrent &&
      AppInvocationResultStore._ownerCurrent(_isOwnerCurrent);
  void _guard() {
    _store._guard();
    if (!AppInvocationResultStore._ownerCurrent(_isOwnerCurrent)) {
      throw StateError('invocation_result_owner_retired');
    }
  }

  @override
  Future<T> trackPublication<T>(Future<T> Function() operation) =>
      _store._track(() {
        _guard();
        return operation();
      });

  @override
  bool usesDatabase(Database database) =>
      identical(_store.database.raw, database);
  void _checkMessage(ChatMessage message) {
    _guard();
    if (message.sessionId != invocationReference.sessionId ||
        AppInvocationResultStore._json.canonicalize(
              message.invocationReference?.toJson(),
            ) !=
            AppInvocationResultStore._json.canonicalize(
              invocationReference.toJson(),
            ) ||
        message.content != summary ||
        message.idempotencyKey != idempotencyKey ||
        message.utteranceId != utteranceId ||
        AppInvocationResultStore._json.canonicalize(
              message.attachments.map((a) => a.toJson()).toList(),
            ) !=
            AppInvocationResultStore._json.canonicalize(
              attachments.map((a) => a.toJson()).toList(),
            ) ||
        AppInvocationResultStore._json.canonicalize(
              message.appletReference?.toJson(),
            ) !=
            AppInvocationResultStore._json.canonicalize(
              appletReference?.toJson(),
            ))
      throw StateError('invocation_publication_changed');
  }

  @override
  Future<ChatMessage?> findExisting(
    Transaction transaction,
    ChatMessage proposed,
  ) async {
    _checkMessage(proposed);
    final row = await AppInvocationResultStore._results
        .record(_key)
        .get(transaction);
    _guard();
    if (row == null || row['fingerprint'] != _fingerprint)
      throw StateError('invocation_result_identity_conflict');
    if (row['state'] != 'committed') return null;
    if (row['messageId'] is! int || row['message'] is! Map)
      throw StateError('invocation_result_corrupt');
    final message = ChatMessage.fromJson(
      Map<String, Object?>.from(row['message'] as Map),
      id: row['messageId'] as int,
    );
    _checkMessage(message);
    return message;
  }

  @override
  Future<void> commit(
    Transaction transaction,
    ChatMessage committed, {
    required bool Function() mayPublish,
  }) async {
    _checkMessage(committed);
    if (!mayPublish() || committed.id == null)
      throw StateError('invocation_result_cancelled');
    await _store.media.persistInvocationOutputs(transaction, _images);
    _guard();
    if (!mayPublish()) throw StateError('invocation_result_cancelled');
    await _store.invocationStore.markResultCommitted(
      transaction,
      invocationId: invocationId,
      resultId: resultId,
      requestId: _receipt.requestId,
      messageId: committed.id!,
      canContinue: () => isCurrent && mayPublish(),
    );
    _guard();
    await AppInvocationResultStore._results.record(_key).put(transaction, {
      'state': 'committed',
      'fingerprint': _fingerprint,
      'manifest': AppInvocationResultStore._json.parse(_manifest),
      'messageId': committed.id,
      'message': committed.toJson(),
    });
    _guard();
    if (!mayPublish()) throw StateError('invocation_result_cancelled');
  }
}
