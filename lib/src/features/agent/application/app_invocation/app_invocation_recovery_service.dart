import 'dart:async';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';

import 'app_invocation_catalog.dart';
import 'app_invocation_compatibility.dart';
import 'app_invocation_descriptor.dart';
import 'app_invocation_draft_snapshot.dart';
import 'app_invocation_execution_contract.dart';
import 'app_invocation_result_store.dart';
import 'app_invocation_store.dart';

/// Verified local presentation state, never an executable capability.
final class AppInvocationRecoveryView {
  const AppInvocationRecoveryView._({
    required this.reference,
    required this.sourceTitle,
    required this.status,
    required this.canFetchResult,
    required this.canRestoreDraft,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;
  final AppInvocationChatReference reference;
  final String sourceTitle;
  final AppInvocationChatStatus status;
  final bool canFetchResult, canRestoreDraft;
  final bool Function() _isCurrent;
  bool get isCurrent => _isCurrent();
}

/// Only the journal verifier can create this receipt-only input. It has no
/// execution service, source runtime, reserve-action or dispatch callback.
final class AppInvocationRecoveryInput {
  AppInvocationRecoveryInput._(this._service, this.reference, this._owner);
  final AppInvocationRecoveryService _service;
  final AppInvocationChatReference reference;
  final bool Function() _owner;
  AppInvocationIdentity get sourceIdentity => AppInvocationIdentity(
    scopeKey: reference.scopeKey,
    sourceId: reference.sourceId,
    revisionId: reference.revisionId,
    sourceDigest: reference.sourceDigest,
  );
  bool get isCurrent => _service._current(_owner);
  Future<PreparedInvocationResult?> loadResult() =>
      _service._loadResult(reference, _owner);
}

final class AppInvocationRecoveredDraft {
  AppInvocationRecoveredDraft._({
    required this.text,
    required Iterable<PreparedChatMedia> images,
    required this.selection,
    required this.sourceUnavailable,
    required bool Function() isCurrent,
  }) : images = List.unmodifiable(images),
       _isCurrent = isCurrent;
  final String text;
  final List<PreparedChatMedia> images;
  final AppInvocationSelection? selection;
  final bool sourceUnavailable;
  final bool Function() _isCurrent;
  bool get isCurrent => _isCurrent();
}

/// Account-owned local recovery. A reference imported from another client is
/// only a claim until its source, request and session match this journal.
final class AppInvocationRecoveryService extends AppService {
  AppInvocationRecoveryService({
    required DBService database,
    required this.store,
    required this.results,
    required this.media,
    required this.catalog,
    required this.scopeKey,
    required this.mountId,
    required String Function() currentMountId,
    required bool Function() isCurrent,
  }) : _currentMountId = currentMountId,
       _isCurrent = isCurrent {
    if (scopeKey != store.scopeKey ||
        mountId != store.mountId ||
        scopeKey != results.scopeKey ||
        mountId != results.mountId ||
        scopeKey != catalog.scopeKey ||
        mountId != catalog.mountId ||
        !store.usesDatabase(database.raw) ||
        !media.usesDatabase(database.raw) ||
        !identical(results.database.raw, database.raw)) {
      throw ArgumentError('invocation_recovery_scope');
    }
  }
  final AppInvocationStore store;
  final AppInvocationResultStore results;
  final ChatMediaService media;
  final AppInvocationCatalog catalog;
  final String scopeKey, mountId;
  final String Function() _currentMountId;
  final bool Function() _isCurrent;
  final _pending = <Future<void>>{};
  bool _retired = false;
  Future<void>? _draining;

  bool _current([bool Function()? owner]) {
    try {
      return !_retired &&
          _isCurrent() &&
          _currentMountId() == mountId &&
          store.isCurrent &&
          results.isCurrent &&
          media.isCurrent &&
          (owner?.call() ?? true);
    } on Object {
      return false;
    }
  }

  void _guard([bool Function()? owner]) {
    if (!_current(owner)) throw StateError('invocation_recovery_retired');
  }

  Future<T> _track<T>(Future<T> Function() operation) async {
    _guard();
    final settled = Completer<void>();
    _pending.add(settled.future);
    try {
      return await operation();
    } finally {
      _pending.remove(settled.future);
      settled.complete();
    }
  }

  Future<AppInvocationRecoveryView> inspect(
    AppInvocationChatReference reference, {
    required String sessionId,
  }) => _track(() async {
    final verified = await _verify(reference, sessionId, () => true);
    return verified.view;
  });

  Future<AppInvocationChatReference?> referenceForInvocation({
    required String invocationId,
    required String sessionId,
    String? requestId,
    AppInvocationChatStatus? status,
  }) => _track(() async {
    try {
      final run = await store.readRun(invocationId);
      _guard();
      if (run.sessionId != sessionId) return null;
      final raw = run.value['draftSnapshot'];
      if (raw is! Map) return null;
      final snapshot = AppInvocationDraftSnapshot.fromJson(
        Map<String, Object?>.from(raw),
      );
      final receipt = requestId == null
          ? null
          : await store.readReceipt(invocationId, requestId: requestId);
      _guard();
      final committedId = run.value['resultId'] as String?;
      final observed = committedId != null
          ? AppInvocationChatStatus.completed
          : receipt?.status == AppInvocationActionStatus.completed
          ? AppInvocationChatStatus.resultUnavailable
          : requestId != null &&
                (receipt == null ||
                    receipt.status == AppInvocationActionStatus.outcomeUnknown)
          ? AppInvocationChatStatus.outcomeUnknown
          : receipt?.status == AppInvocationActionStatus.cancelled ||
                run.status == 'cancelled'
          ? AppInvocationChatStatus.cancelled
          : AppInvocationChatStatus.failed;
      // A requested label is only a presentation hint; durable evidence wins.
      if (status == AppInvocationChatStatus.resultUnavailable &&
          observed != AppInvocationChatStatus.resultUnavailable) {
        return null;
      }
      final text = snapshot.text.trim();
      var summary = '';
      for (final rune in text.runes) {
        final character = String.fromCharCode(rune);
        if (summary.length + character.length > 240) break;
        summary += character;
      }
      final reference = AppInvocationChatReference(
        scopeKey: scopeKey,
        sessionId: sessionId,
        invocationId: invocationId,
        requestId: requestId,
        resultId: committedId,
        sourceId: run.identity.sourceId,
        revisionId: run.identity.revisionId,
        sourceDigest: run.identity.sourceDigest,
        contractDigest: run.contractDigest,
        sourceTitle: snapshot.sourceTitle,
        status: observed,
        inputSummary: summary.isEmpty ? null : summary,
      );
      await _verify(reference, sessionId, () => true);
      return reference;
    } on Object {
      _guard();
      return null;
    }
  });

  Future<AppInvocationRecoveryInput> prepareRecovery(
    AppInvocationChatReference reference, {
    required String sessionId,
    required bool Function() isOwnerCurrent,
  }) => _track(() async {
    final verified = await _verify(reference, sessionId, isOwnerCurrent);
    if (reference.requestId == null ||
        (!verified.view.canFetchResult &&
            verified.view.status != AppInvocationChatStatus.completed)) {
      throw StateError('invocation_recovery_unavailable');
    }
    return AppInvocationRecoveryInput._(this, reference, isOwnerCurrent);
  });

  Future<PreparedInvocationResult?> _loadResult(
    AppInvocationChatReference reference,
    bool Function() owner,
  ) => _track(() async {
    await _verify(reference, reference.sessionId, owner);
    final requestId = reference.requestId;
    if (requestId == null) throw StateError('invocation_request_unavailable');
    final receipt = await store.readReceipt(
      reference.invocationId,
      requestId: requestId,
    );
    _guard(owner);
    if (receipt == null ||
        receipt.status != AppInvocationActionStatus.completed) {
      return null;
    }
    final prepared = await results.prepareRecovery(
      invocationId: reference.invocationId,
      requestId: requestId,
    );
    _guard(owner);
    return prepared;
  });

  Future<AppInvocationRecoveredDraft> loadDraft(
    AppInvocationChatReference reference, {
    required String sessionId,
    required bool Function() isOwnerCurrent,
  }) => _track(() async {
    final verified = await _verify(reference, sessionId, isOwnerCurrent);
    final snapshot = verified.snapshot;
    if (snapshot == null) throw StateError('invocation_draft_unavailable');
    final images = <PreparedChatMedia>[];
    for (final handle in snapshot.imageHandles) {
      final image = await media.read(
        ChatAttachment(
          id: handle['sha256']! as String,
          kind: 'image',
          byteLength: handle['byteLength']! as int,
        ),
      );
      _guard(isOwnerCurrent);
      if (image == null ||
          image.attachment.id != handle['id'] ||
          image.mime != handle['mime']) {
        throw StateError('invocation_draft_media_unavailable');
      }
      // Rebuild only the local thumbnail; preserve the original encoded bytes.
      images.add(
        await media.prepareInvocationOutput(
          AppInvocationProducedImage(
            producerOutputKey: 'restore:${image.attachment.id}',
            mime: image.mime,
            bytes: image.bytes,
          ),
        ),
      );
      _guard(isOwnerCurrent);
    }
    AppInvocationSelection? selection;
    try {
      final resolved = await catalog.revalidateStoredSelection(snapshot);
      _guard(isOwnerCurrent);
      if (resolved.status ==
              AppInvocationCompatibilityStatus.pendingVerification ||
          resolved.status == AppInvocationCompatibilityStatus.compatible) {
        selection = resolved.selection;
      }
    } on Object {
      // A removed or changed work must not replace the fixed source silently.
      // Text and verified images are still recoverable in the same account.
      _guard(isOwnerCurrent);
    }
    return AppInvocationRecoveredDraft._(
      text: snapshot.text,
      images: images,
      selection: selection,
      sourceUnavailable: selection == null,
      isCurrent: () => _current(isOwnerCurrent),
    );
  });

  Future<_VerifiedInvocation> _verify(
    AppInvocationChatReference reference,
    String sessionId,
    bool Function() owner,
  ) async {
    _guard(owner);
    if (reference.scopeKey != scopeKey || reference.sessionId != sessionId) {
      throw StateError('invocation_reference_scope');
    }
    final run = await store.readRun(reference.invocationId);
    _guard(owner);
    if (run.sessionId != sessionId ||
        run.identity.sourceId != reference.sourceId ||
        run.identity.revisionId != reference.revisionId ||
        run.identity.sourceDigest != reference.sourceDigest ||
        run.contractDigest != reference.contractDigest) {
      throw StateError('invocation_reference_identity');
    }
    final rawSnapshot = run.value['draftSnapshot'];
    final snapshot = rawSnapshot == null
        ? null
        : AppInvocationDraftSnapshot.fromJson(
            Map<String, Object?>.from(rawSnapshot as Map),
          );
    if (snapshot != null &&
        (snapshot.scopeKey != scopeKey ||
            snapshot.sourceId != run.identity.sourceId ||
            snapshot.revisionId != run.identity.revisionId ||
            snapshot.sourceDigest != run.identity.sourceDigest ||
            snapshot.contractDigest != run.contractDigest ||
            snapshot.adapterId != run.adapterId ||
            snapshot.adapterVersion != run.adapterVersion ||
            snapshot.inputDigest != run.value['inputDigest'])) {
      throw StateError('invocation_draft_identity');
    }
    final requestId = reference.requestId;
    final action = requestId == null
        ? null
        : await store.readAction(run.invocationId, requestId: requestId);
    _guard(owner);
    if (requestId != null && action == null) {
      throw StateError('invocation_request_unavailable');
    }
    Map<String, Object?>? result;
    final committedId = run.value['resultId'];
    if (committedId is String) {
      result = await results.readResult(run.invocationId, committedId);
      _guard(owner);
      final manifest = result?['manifest'];
      if (result?['state'] != 'committed' ||
          manifest is! Map ||
          manifest['invocationId'] != run.invocationId ||
          manifest['requestId'] != requestId ||
          manifest['resultId'] != committedId ||
          manifest['contractDigest'] != run.contractDigest ||
          result?['messageId'] != run.value['messageId']) {
        throw StateError('invocation_result_identity');
      }
    }
    if (reference.resultId != null && reference.resultId != committedId) {
      throw StateError('invocation_result_unavailable');
    }
    final manifest = result?['manifest'];
    final title =
        snapshot?.sourceTitle ??
        (manifest is Map ? manifest['sourceTitle'] : null);
    if (title is! String || title != reference.sourceTitle) {
      throw StateError('invocation_source_title_unavailable');
    }
    final status = committedId is String
        ? AppInvocationChatStatus.completed
        : switch (action?['status']) {
            'completed' => AppInvocationChatStatus.resultUnavailable,
            'pending' ||
            'outcomeUnknown' => AppInvocationChatStatus.outcomeUnknown,
            'cancelled' => AppInvocationChatStatus.cancelled,
            'failed' => AppInvocationChatStatus.failed,
            _ =>
              run.status == 'cancelled'
                  ? AppInvocationChatStatus.cancelled
                  : AppInvocationChatStatus.failed,
          };
    return _VerifiedInvocation(
      snapshot,
      AppInvocationRecoveryView._(
        reference: reference,
        sourceTitle: title,
        status: status,
        canFetchResult:
            requestId != null &&
            (status == AppInvocationChatStatus.resultUnavailable ||
                status == AppInvocationChatStatus.outcomeUnknown),
        canRestoreDraft: snapshot != null,
        isCurrent: () => _current(owner),
      ),
    );
  }

  void retire() => _retired = true;
  Future<void> deactivateAndDrain() {
    retire();
    return _draining ??= () async {
      while (_pending.isNotEmpty) {
        await Future.wait(_pending.toList());
      }
    }();
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}

final class _VerifiedInvocation {
  const _VerifiedInvocation(this.snapshot, this.view);
  final AppInvocationDraftSnapshot? snapshot;
  final AppInvocationRecoveryView view;
}
