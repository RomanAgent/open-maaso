import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Private, account-owned continuation data for one source-generation request.
/// It carries no credentials, tool grants, provider reasoning or executable
/// authority. The producer verifies source and authoring-policy bindings before
/// restoring it; model output can never supply this object.
class SourceExecutionCheckpoint {
  SourceExecutionCheckpoint({
    required this.operation,
    required this.workspaceDigest,
    required this.rulesDigest,
    required this.systemPrompt,
    required this.userPrompt,
    required this.phase,
    required this.displayBytes,
    required Map<String, Object?> state,
    this.fileId,
    this.requestPending = true,
  }) : _stateJson = jsonEncode(state) {
    _validate();
  }

  static const maxBytes = 512 * 1024;
  final String operation, workspaceDigest, rulesDigest;
  final String systemPrompt, userPrompt, phase;
  final String? fileId;
  final int displayBytes;
  final bool requestPending;
  final String _stateJson;

  // Return a fresh tree so callers cannot mutate an already persisted request.
  Map<String, Object?> get state =>
      Map<String, Object?>.from(jsonDecode(_stateJson) as Map);

  String get requestDigest =>
      sha256.convert(utf8.encode(jsonEncode(_payload()))).toString();

  Map<String, Object?> _payload() => {
    'schemaVersion': 1,
    'operation': operation,
    'workspaceDigest': workspaceDigest,
    'rulesDigest': rulesDigest,
    'fileId': fileId,
    'systemPrompt': systemPrompt,
    'userPrompt': userPrompt,
    'phase': phase,
    'displayBytes': displayBytes,
    'state': state,
    'requestPending': requestPending,
  };

  Map<String, Object?> toJson() => {
    ..._payload(),
    'requestDigest': requestDigest,
  };

  factory SourceExecutionCheckpoint.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 12 ||
        !value.keys.toSet().containsAll(const {
          'schemaVersion',
          'operation',
          'workspaceDigest',
          'rulesDigest',
          'fileId',
          'systemPrompt',
          'userPrompt',
          'phase',
          'displayBytes',
          'state',
          'requestDigest',
          'requestPending',
        }) ||
        value['schemaVersion'] != 1 ||
        value['operation'] is! String ||
        value['workspaceDigest'] is! String ||
        value['rulesDigest'] is! String ||
        value['systemPrompt'] is! String ||
        value['userPrompt'] is! String ||
        value['phase'] is! String ||
        value['displayBytes'] is! int ||
        value['requestPending'] is! bool ||
        value['state'] is! Map ||
        (value['state'] as Map).keys.any((key) => key is! String) ||
        (value['fileId'] != null && value['fileId'] is! String)) {
      throw const FormatException('source_execution_checkpoint_invalid');
    }
    final checkpoint = SourceExecutionCheckpoint(
      operation: value['operation'] as String,
      workspaceDigest: value['workspaceDigest'] as String,
      rulesDigest: value['rulesDigest'] as String,
      systemPrompt: value['systemPrompt'] as String,
      userPrompt: value['userPrompt'] as String,
      phase: value['phase'] as String,
      displayBytes: value['displayBytes'] as int,
      fileId: value['fileId'] as String?,
      state: Map<String, Object?>.from(value['state'] as Map),
      requestPending: value['requestPending'] as bool,
    );
    if (value['requestDigest'] != checkpoint.requestDigest) {
      throw const FormatException('source_execution_checkpoint_digest');
    }
    return checkpoint;
  }

  void _validate() {
    final hash = RegExp(r'^[a-f0-9]{64}$');
    if (!const {'plan', 'write', 'repair'}.contains(operation) ||
        !hash.hasMatch(workspaceDigest) ||
        !hash.hasMatch(rulesDigest) ||
        !const {'planning', 'append', 'inspection'}.contains(phase) ||
        displayBytes < 0 ||
        displayBytes > 128 * 1024 ||
        (requestPending && systemPrompt.isEmpty) ||
        (operation == 'plan') != (fileId == null) ||
        (fileId != null &&
            !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(fileId!)) ||
        utf8.encode(jsonEncode(_payload())).length > maxBytes) {
      throw const FormatException('source_execution_checkpoint_invalid');
    }
  }
}
