import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'creator_draft.dart';

const creatorTaskMaximumSequence = 9007199254740991;
final _taskUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _taskRequestId = RegExp(r'^[A-Za-z0-9_-]{8,96}$');
final _taskHash = RegExp(r'^[a-f0-9]{64}$');

enum CreatorTaskStatus {
  queued,
  running,
  completed,
  failed,
  cancelled,
  interrupted,
}

final class CreatorTaskImageInput {
  const CreatorTaskImageInput({
    required this.prompt,
    required this.aspectRatio,
    required this.style,
  });
  final String prompt;
  final String aspectRatio;
  final String style;

  factory CreatorTaskImageInput.fromJson(Map<String, Object?> json) {
    _keys(json, {'prompt', 'aspectRatio', 'style'});
    final prompt = _string(json['prompt']);
    final ratio = _string(json['aspectRatio']);
    final style = _string(json['style']);
    if (prompt.isEmpty ||
        prompt.length > 1200 ||
        prompt != prompt.trim() ||
        !{'1:1', '4:5', '9:16', '16:9'}.contains(ratio) ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(style)) {
      throw const FormatException('invalid_task_image_input');
    }
    return CreatorTaskImageInput(
      prompt: prompt,
      aspectRatio: ratio,
      style: style,
    );
  }
  Map<String, Object?> toJson() => {
    'prompt': prompt,
    'aspectRatio': aspectRatio,
    'style': style,
  };
}

final class CreatorTaskArtifact {
  const CreatorTaskArtifact({
    required this.assetId,
    required this.sha256,
    required this.contentType,
    required this.bytes,
    required this.width,
    required this.height,
  });
  final String assetId;
  final String sha256;
  final String contentType;
  final int bytes;
  final int width;
  final int height;

  factory CreatorTaskArtifact.fromJson(Map<String, Object?> json) {
    _keys(json, {
      'kind',
      'assetId',
      'sha256',
      'contentType',
      'bytes',
      'width',
      'height',
    });
    final id = _string(json['assetId']);
    final hash = _string(json['sha256']);
    final type = _string(json['contentType']);
    final bytes = _integer(json['bytes'], maximum: 12 * 1024 * 1024);
    final width = _integer(json['width'], maximum: 4096);
    final height = _integer(json['height'], maximum: 4096);
    if (json['kind'] != 'creator_image' ||
        !RegExp(r'^[A-Za-z0-9_-]{1,96}$').hasMatch(id) ||
        !_taskHash.hasMatch(hash) ||
        !{'image/png', 'image/jpeg'}.contains(type) ||
        width * height > 12000000) {
      throw const FormatException('invalid_task_artifact');
    }
    return CreatorTaskArtifact(
      assetId: id,
      sha256: hash,
      contentType: type,
      bytes: bytes,
      width: width,
      height: height,
    );
  }
  bool matchesAsset(CreatorAssetRef value) =>
      value.id == assetId &&
      value.sha256 == sha256 &&
      value.contentType == contentType &&
      value.bytes == bytes &&
      value.width == width &&
      value.height == height;
  Map<String, Object?> toJson() => {
    'kind': 'creator_image',
    'assetId': assetId,
    'sha256': sha256,
    'contentType': contentType,
    'bytes': bytes,
    'width': width,
    'height': height,
  };
}

final class CreatorTaskReceipt {
  const CreatorTaskReceipt({
    required this.requestId,
    required this.taskId,
    required this.attemptId,
    required this.attempt,
    required this.sequence,
  });
  final String requestId;
  final String taskId;
  final String attemptId;
  final int attempt;
  final int sequence;
  factory CreatorTaskReceipt.fromJson(Map<String, Object?> json) {
    _keys(json, {'requestId', 'taskId', 'attemptId', 'attempt', 'sequence'});
    final request = _string(json['requestId']);
    if (!_taskRequestId.hasMatch(request)) {
      throw const FormatException('invalid_task_receipt');
    }
    return CreatorTaskReceipt(
      requestId: request,
      taskId: _uuid(json['taskId']),
      attemptId: _uuid(json['attemptId']),
      attempt: _integer(json['attempt'], maximum: 10),
      sequence: _integer(json['sequence']),
    );
  }
  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'taskId': taskId,
    'attemptId': attemptId,
    'attempt': attempt,
    'sequence': sequence,
  };
}

final class CreatorTaskSnapshot {
  const CreatorTaskSnapshot({
    required this.taskId,
    required this.agentId,
    required this.attemptId,
    required this.attempt,
    required this.status,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    this.errorCode = '',
    this.artifact,
  });
  final String taskId;
  final String agentId;
  final String attemptId;
  final int attempt;
  final CreatorTaskStatus status;
  final int sequence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String errorCode;
  final CreatorTaskArtifact? artifact;
  bool get canCancel =>
      status == CreatorTaskStatus.queued || status == CreatorTaskStatus.running;
  bool get canRetry =>
      status == CreatorTaskStatus.failed ||
      status == CreatorTaskStatus.cancelled ||
      status == CreatorTaskStatus.interrupted;
  bool get isTerminal => !canCancel;
  factory CreatorTaskSnapshot.fromJson(Map<String, Object?> json) {
    _keys(
      json,
      {
        'taskId',
        'agentId',
        'kind',
        'executionLocation',
        'attemptId',
        'attempt',
        'status',
        'stage',
        'sequence',
        'createdAt',
        'updatedAt',
      },
      optional: {'errorCode', 'result'},
    );
    final agent = _string(json['agentId']);
    final state = CreatorTaskStatus.values.byName(_string(json['status']));
    final error = json['errorCode'] == null ? '' : _string(json['errorCode']);
    final created = DateTime.parse(_string(json['createdAt'])).toUtc();
    final updated = DateTime.parse(_string(json['updatedAt'])).toUtc();
    final artifact = json['result'] == null
        ? null
        : CreatorTaskArtifact.fromJson(_map(json['result']));
    if (json['kind'] != 'creator_image' ||
        json['executionLocation'] != 'server' ||
        !RegExp(r'^[A-Za-z0-9_.:-]{1,96}$').hasMatch(agent) ||
        json['stage'] !=
            (state == CreatorTaskStatus.running ? 'generating' : state.name) ||
        updated.isBefore(created) ||
        error.length > 48 ||
        (state == CreatorTaskStatus.completed) != (artifact != null)) {
      throw const FormatException('invalid_task_snapshot');
    }
    return CreatorTaskSnapshot(
      taskId: _uuid(json['taskId']),
      agentId: agent,
      attemptId: _uuid(json['attemptId']),
      attempt: _integer(json['attempt'], maximum: 10),
      status: state,
      sequence: _integer(json['sequence']),
      createdAt: created,
      updatedAt: updated,
      errorCode: error,
      artifact: artifact,
    );
  }
  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'agentId': agentId,
    'kind': 'creator_image',
    'executionLocation': 'server',
    'attemptId': attemptId,
    'attempt': attempt,
    'status': status.name,
    'stage': status == CreatorTaskStatus.running ? 'generating' : status.name,
    'sequence': sequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (errorCode.isNotEmpty) 'errorCode': errorCode,
    if (artifact != null) 'result': artifact!.toJson(),
  };
  bool sameState(CreatorTaskSnapshot other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

final class CreatorTaskEventPage {
  const CreatorTaskEventPage({
    required this.snapshots,
    required this.nextSequence,
    required this.hasMore,
  });
  final List<CreatorTaskSnapshot> snapshots;
  final int nextSequence;
  final bool hasMore;
  factory CreatorTaskEventPage.fromJson(
    Map<String, Object?> json, {
    required String taskId,
    required String agentId,
    required int afterSequence,
  }) {
    _keys(json, {'events', 'nextSequence', 'hasMore'});
    final raw = json['events'];
    if (raw is! List || raw.length > 100 || json['hasMore'] is! bool) {
      throw const FormatException('invalid_task_events');
    }
    var previous = afterSequence;
    final snapshots = <CreatorTaskSnapshot>[];
    for (final item in raw) {
      final event = _map(item);
      _keys(event, {'sequence', 'task'});
      final snapshot = CreatorTaskSnapshot.fromJson(_map(event['task']));
      if (_integer(event['sequence']) != previous + 1 ||
          snapshot.sequence != previous + 1 ||
          snapshot.taskId != taskId ||
          snapshot.agentId != agentId) {
        throw const FormatException('invalid_task_event_identity');
      }
      snapshots.add(snapshot);
      previous = snapshot.sequence;
    }
    final next = _integer(json['nextSequence'], minimum: 0);
    if (next != previous || (json['hasMore'] == true && snapshots.isEmpty)) {
      throw const FormatException('invalid_task_event_cursor');
    }
    return CreatorTaskEventPage(
      snapshots: List.unmodifiable(snapshots),
      nextSequence: next,
      hasMore: json['hasMore']! as bool,
    );
  }
}

enum CreatorTaskOperation { create, cancel, retry }

final class CreatorTaskCommand {
  const CreatorTaskCommand({
    required this.operation,
    required this.requestId,
    this.expectedAttemptId,
  });
  final CreatorTaskOperation operation;
  final String requestId;
  final String? expectedAttemptId;
  factory CreatorTaskCommand.fromJson(Map<String, Object?> json) {
    _keys(json, {'operation', 'requestId'}, optional: {'expectedAttemptId'});
    final operation = CreatorTaskOperation.values.byName(
      _string(json['operation']),
    );
    final request = _string(json['requestId']);
    final expected = json['expectedAttemptId'] == null
        ? null
        : _uuid(json['expectedAttemptId']);
    if (!_taskRequestId.hasMatch(request) ||
        (operation == CreatorTaskOperation.create) != (expected == null)) {
      throw const FormatException('invalid_task_command');
    }
    return CreatorTaskCommand(
      operation: operation,
      requestId: request,
      expectedAttemptId: expected,
    );
  }
  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'requestId': requestId,
    if (expectedAttemptId != null) 'expectedAttemptId': expectedAttemptId,
  };
}

/// Local account-owned intent/checkpoint; never includes a token, expiring URL,
/// hidden prompt or action grant. A receipt identifies work but cannot prove its
/// current state. Only snapshot.sequence advances the server journal cursor.
final class CreatorImageTaskBinding {
  const CreatorImageTaskBinding({
    required this.creatorScopeKey,
    required this.draftId,
    required this.draftFingerprint,
    required this.createRequestId,
    required this.input,
    this.receipt,
    this.snapshot,
    this.pendingCommand,
    this.syncIssue = '',
    this.previewAsset,
    this.applied = false,
  });
  final String creatorScopeKey;
  final String draftId;
  final String draftFingerprint;
  final String createRequestId;
  final CreatorTaskImageInput input;
  final CreatorTaskReceipt? receipt;
  final CreatorTaskSnapshot? snapshot;
  final CreatorTaskCommand? pendingCommand;
  final String syncIssue;
  final CreatorAssetRef? previewAsset;
  final bool applied;
  String? get serverTaskId => snapshot?.taskId ?? receipt?.taskId;
  String? get serverAttemptId => snapshot?.attemptId ?? receipt?.attemptId;
  int get serverSequence => snapshot?.sequence ?? 0;
  CreatorImageTaskBinding copyWith({
    CreatorTaskReceipt? receipt,
    CreatorTaskSnapshot? snapshot,
    CreatorTaskCommand? pendingCommand,
    bool clearPending = false,
    String? syncIssue,
    CreatorAssetRef? previewAsset,
    bool clearPreview = false,
    bool? applied,
  }) => CreatorImageTaskBinding(
    creatorScopeKey: creatorScopeKey,
    draftId: draftId,
    draftFingerprint: draftFingerprint,
    createRequestId: createRequestId,
    input: input,
    receipt: receipt ?? this.receipt,
    snapshot: snapshot ?? this.snapshot,
    pendingCommand: clearPending ? null : pendingCommand ?? this.pendingCommand,
    syncIssue: syncIssue ?? this.syncIssue,
    previewAsset: clearPreview ? null : previewAsset ?? this.previewAsset,
    applied: applied ?? this.applied,
  );
  factory CreatorImageTaskBinding.fromJson(Map<String, Object?> json) {
    _keys(
      json,
      {
        'version',
        'creatorScopeKey',
        'draftId',
        'draftFingerprint',
        'createRequestId',
        'input',
        'syncIssue',
        'applied',
      },
      optional: {'receipt', 'snapshot', 'pendingCommand', 'previewAsset'},
    );
    final scope = _string(json['creatorScopeKey']);
    final draft = _string(json['draftId']);
    final fingerprint = _string(json['draftFingerprint']);
    final request = _string(json['createRequestId']);
    final issue = _string(json['syncIssue']);
    final receipt = json['receipt'] == null
        ? null
        : CreatorTaskReceipt.fromJson(_map(json['receipt']));
    final snapshot = json['snapshot'] == null
        ? null
        : CreatorTaskSnapshot.fromJson(_map(json['snapshot']));
    final pending = json['pendingCommand'] == null
        ? null
        : CreatorTaskCommand.fromJson(_map(json['pendingCommand']));
    final preview = json['previewAsset'] == null
        ? null
        : CreatorAssetRef.fromJson(_map(json['previewAsset']));
    if (json['version'] != 1 ||
        scope.isEmpty ||
        scope.length > 512 ||
        draft.isEmpty ||
        draft.length > 160 ||
        !_taskHash.hasMatch(fingerprint) ||
        !_taskRequestId.hasMatch(request) ||
        issue.length > 64 ||
        json['applied'] is! bool ||
        (receipt != null &&
            snapshot != null &&
            receipt.taskId != snapshot.taskId) ||
        (receipt == null &&
            snapshot == null &&
            (pending?.operation != CreatorTaskOperation.create ||
                pending?.requestId != request)) ||
        (preview != null &&
            !(snapshot?.artifact?.matchesAsset(preview) ?? false)) ||
        (json['applied'] == true && preview == null)) {
      throw const FormatException('invalid_server_task_binding');
    }
    return CreatorImageTaskBinding(
      creatorScopeKey: scope,
      draftId: draft,
      draftFingerprint: fingerprint,
      createRequestId: request,
      input: CreatorTaskImageInput.fromJson(_map(json['input'])),
      receipt: receipt,
      snapshot: snapshot,
      pendingCommand: pending,
      syncIssue: issue,
      previewAsset: preview,
      applied: json['applied']! as bool,
    );
  }
  Map<String, Object?> toJson() => {
    'version': 1,
    'creatorScopeKey': creatorScopeKey,
    'draftId': draftId,
    'draftFingerprint': draftFingerprint,
    'createRequestId': createRequestId,
    'input': input.toJson(),
    'syncIssue': syncIssue,
    'applied': applied,
    if (receipt != null) 'receipt': receipt!.toJson(),
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
    if (pendingCommand != null) 'pendingCommand': pendingCommand!.toJson(),
    if (previewAsset != null) 'previewAsset': previewAsset!.toJson(),
  };
}

Map<String, Object?> creatorTaskMap(Object? value) => _map(value);
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('invalid_task_object');
  }
  return Map<String, Object?>.from(value);
}

String _string(Object? value) {
  if (value is! String) throw const FormatException('invalid_task_string');
  return value;
}

String _uuid(Object? value) {
  final text = _string(value);
  if (!_taskUuid.hasMatch(text)) {
    throw const FormatException('invalid_task_uuid');
  }
  return text;
}

int _integer(
  Object? value, {
  int minimum = 1,
  int maximum = creatorTaskMaximumSequence,
}) {
  if (value is! int || value < minimum || value > maximum) {
    throw const FormatException('invalid_task_integer');
  }
  return value;
}

void _keys(
  Map<String, Object?> json,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  if (!required.every(json.containsKey) ||
      json.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    throw const FormatException('invalid_task_fields');
  }
}

String creatorDraftTaskFingerprint(CreatorDraft draft) {
  final json = draft.toJson()
    ..remove('status')
    ..remove('asset')
    ..remove('updatedAt');
  return sha256.convert(utf8.encode(jsonEncode(json))).toString();
}

String creatorDraftApplicationRevision(CreatorDraft draft) =>
    sha256.convert(utf8.encode(jsonEncode(draft.toJson()))).toString();
