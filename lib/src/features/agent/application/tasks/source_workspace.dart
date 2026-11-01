import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';

import 'generated_task_diagnostics.dart';
import 'source_execution_checkpoint.dart';

String sourceWorkspaceDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

enum SourceFileKind { html, css, js }

class SourceWorkspaceProtocolException implements Exception {
  const SourceWorkspaceProtocolException(this.code, {this.reason, this.phase});
  final String code;
  final SourceDiagnosticReason? reason;
  final SourceDiagnosticPhase? phase;
  @override
  String toString() => 'source_workspace:$code';
}

enum SourceDiagnosticPhase { planning, append, inspection, validation }

enum SourceDiagnosticReason {
  planAwaitingCompletion,
  planCompleted,
  missingMetadata,
  unsupportedFields,
  missingFields,
  invalidValueType,
  jsonInvalid,
  jsonIncomplete,
  duplicateField,
  dependencyMissing,
  dependencyCycle,
  requiredFilesMissing,
  identityChanged,
  authorityRejected,
  sourceBindingInvalid,
  inspectionInvalid,
  providerResponseInvalid,
  providerFailure,
  contextTooLarge,
  stalled,
  capacityExceeded,
  validationRejected,
  runtimeFirstFrameRejected,
  sourceLexicalValidationFailed,
  sourceCapabilityValidationFailed,
  exactMatchRejected,
  overlapRejected,
}

/// Closed host facts only. No provider text, unknown field names or reasoning.
class SourceGenerationDiagnostic {
  const SourceGenerationDiagnostic({
    required this.phase,
    required this.reason,
    this.fileId,
    this.knownLength,
    this.closedJson,
    this.explicitPlanEOF,
    this.javascriptUtf16Offset,
    this.javascriptRestrictionRule,
    this.javascriptOffendingName,
  });
  final SourceDiagnosticPhase phase;
  final SourceDiagnosticReason reason;
  final String? fileId;
  final bool? knownLength, closedJson, explicitPlanEOF;
  final int? javascriptUtf16Offset;
  final String? javascriptRestrictionRule, javascriptOffendingName;
  factory SourceGenerationDiagnostic.fromJson(Object? value) {
    final map = _object(value);
    _keys(
      map,
      required: const {'phase', 'reason'},
      optional: const {
        'fileId',
        'knownLength',
        'closedJson',
        'explicitPlanEOF',
        'javascriptUtf16Offset',
        'javascriptRestrictionRule',
        'javascriptOffendingName',
      },
    );
    final phase = SourceDiagnosticPhase.values
        .where((v) => v.name == map['phase'])
        .firstOrNull;
    final reason = SourceDiagnosticReason.values
        .where((v) => v.name == map['reason'])
        .firstOrNull;
    final id = map['fileId'];
    final offset = map['javascriptUtf16Offset'];
    final restrictionRule = map['javascriptRestrictionRule'];
    final offendingName = map['javascriptOffendingName'];
    final capability =
        reason == SourceDiagnosticReason.sourceCapabilityValidationFailed;
    if (phase == null ||
        reason == null ||
        (id != null &&
            (id is! String ||
                !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(id)))) {
      throw const SourceWorkspaceProtocolException('diagnostic');
    }
    if (map.containsKey('javascriptUtf16Offset') &&
            (offset is! int || offset < 0 || offset > 8 * 1024 * 1024) ||
        (reason == SourceDiagnosticReason.sourceLexicalValidationFailed &&
            (phase != SourceDiagnosticPhase.validation || offset == null)) ||
        (offset != null &&
            reason != SourceDiagnosticReason.sourceLexicalValidationFailed &&
            !capability) ||
        capability &&
            (phase != SourceDiagnosticPhase.validation ||
                offset == null ||
                restrictionRule is! String ||
                offendingName is! String ||
                SurfaceProjectValidator.javaScriptRestrictionFact(
                      '${SurfaceProjectValidator.javaScriptRestrictionPrefix} (rule $restrictionRule, name $offendingName, UTF-16 offset $offset)',
                    ) ==
                    null) ||
        !capability &&
            (map.containsKey('javascriptRestrictionRule') ||
                map.containsKey('javascriptOffendingName'))) {
      throw const SourceWorkspaceProtocolException('diagnostic');
    }
    for (final key in ['knownLength', 'closedJson', 'explicitPlanEOF']) {
      if (map.containsKey(key) && map[key] is! bool) {
        throw const SourceWorkspaceProtocolException('diagnostic');
      }
    }
    return SourceGenerationDiagnostic(
      phase: phase,
      reason: reason,
      fileId: id as String?,
      knownLength: map['knownLength'] as bool?,
      closedJson: map['closedJson'] as bool?,
      explicitPlanEOF: map['explicitPlanEOF'] as bool?,
      javascriptUtf16Offset: offset as int?,
      javascriptRestrictionRule: restrictionRule as String?,
      javascriptOffendingName: offendingName as String?,
    );
  }
  Map<String, Object?> toJson() => {
    'phase': phase.name,
    'reason': reason.name,
    'fileId': ?fileId,
    'knownLength': ?knownLength,
    'closedJson': ?closedJson,
    'explicitPlanEOF': ?explicitPlanEOF,
    'javascriptUtf16Offset': ?javascriptUtf16Offset,
    'javascriptRestrictionRule': ?javascriptRestrictionRule,
    'javascriptOffendingName': ?javascriptOffendingName,
  };
}

SourceDiagnosticReason sourceProtocolDiagnostic(
  SourceWorkspaceProtocolException error,
) =>
    error.reason ??
    switch (error.code) {
      'plan_incomplete' ||
      'chunk_incomplete' ||
      'edit_incomplete' ||
      'chunk_bindings_incomplete' => SourceDiagnosticReason.jsonIncomplete,
      'json_duplicate_key' => SourceDiagnosticReason.duplicateField,
      'dependency_missing' => SourceDiagnosticReason.dependencyMissing,
      'dependency_cycle' => SourceDiagnosticReason.dependencyCycle,
      'required_files' => SourceDiagnosticReason.requiredFilesMissing,
      'plan_changed' ||
      'duplicate_file' => SourceDiagnosticReason.identityChanged,
      'game_manifest_authority' ||
      'utility_action_authority' ||
      'manifest_changed' => SourceDiagnosticReason.authorityRejected,
      'chunk_binding' => SourceDiagnosticReason.sourceBindingInvalid,
      'edit_match' => SourceDiagnosticReason.exactMatchRejected,
      'edit_overlap' => SourceDiagnosticReason.overlapRejected,
      'edit_no_progress' => SourceDiagnosticReason.stalled,
      'inspection_binding' => SourceDiagnosticReason.inspectionInvalid,
      'fields' => SourceDiagnosticReason.unsupportedFields,
      'string' ||
      'plan_interfaces' ||
      'plan_done' ||
      'file_kind' ||
      'file_id' ||
      'file_purpose' ||
      'file_dependencies' ||
      'edit_count' ||
      'plan_files' => SourceDiagnosticReason.invalidValueType,
      _ => SourceDiagnosticReason.jsonInvalid,
    };

class SourceFilePlan {
  SourceFilePlan({
    required this.id,
    required this.kind,
    required this.purpose,
    Iterable<String> dependsOn = const [],
  }) : dependsOn = List<String>.unmodifiable(dependsOn);

  factory SourceFilePlan.fromJson(Object? value) {
    final map = _object(value);
    _keys(
      map,
      required: const {'id', 'kind', 'purpose'},
      optional: const {'dependsOn'},
    );
    final id = _string(map['id']);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(id)) {
      throw const SourceWorkspaceProtocolException('file_id');
    }
    final name = _string(map['kind']);
    final kind = SourceFileKind.values.where((v) => v.name == name).firstOrNull;
    if (kind == null) throw const SourceWorkspaceProtocolException('file_kind');
    final purpose = _string(map['purpose']);
    if (purpose.trim().isEmpty) {
      throw const SourceWorkspaceProtocolException('file_purpose');
    }
    final rawDependencies = map['dependsOn'] ?? const <String>[];
    if (rawDependencies is! List || rawDependencies.any((v) => v is! String)) {
      throw const SourceWorkspaceProtocolException('file_dependencies');
    }
    final dependencies = rawDependencies.cast<String>();
    if (dependencies.toSet().length != dependencies.length ||
        dependencies.contains(id)) {
      throw const SourceWorkspaceProtocolException('file_dependencies');
    }
    return SourceFilePlan(
      id: id,
      kind: kind,
      purpose: purpose,
      dependsOn: dependencies,
    );
  }

  final String id;
  final SourceFileKind kind;
  final String purpose;
  final List<String> dependsOn;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'purpose': purpose,
    'dependsOn': dependsOn,
  };
}

class SourceBlueprint {
  SourceBlueprint({
    required this.title,
    required this.summary,
    required this.skillInstructions,
    required Iterable<SourceFilePlan> files,
    this.interfaces = '',
    String decisionSummary = '',
    Map<String, Object?>? manifest,
  }) : decisionSummary = generatedTaskPublicSummary(decisionSummary),
       files = List<SourceFilePlan>.unmodifiable(files),
       manifest = manifest == null
           ? null
           : Map<String, Object?>.unmodifiable(
               SurfaceManifest.fromSpec(manifest).toJson(),
             );

  factory SourceBlueprint.fromJson(Object? value, {bool partial = false}) {
    final map = _object(value);
    _keys(
      map,
      required: const {'title', 'summary', 'skillInstructions', 'files'},
      optional: const {
        'interfaces',
        'decisionSummary',
        'done',
        'planComplete',
        'manifest',
      },
      partial: partial,
    );
    final rawFiles = map['files'] ?? const <Object?>[];
    if (rawFiles is! List) {
      throw const SourceWorkspaceProtocolException('plan_files');
    }
    final files = rawFiles.map(SourceFilePlan.fromJson).toList();
    if (files.map((f) => f.id).toSet().length != files.length) {
      throw const SourceWorkspaceProtocolException('duplicate_file');
    }
    final interfaces = map['interfaces'] ?? '';
    if (interfaces is! String) {
      throw const SourceWorkspaceProtocolException('plan_interfaces');
    }
    return SourceBlueprint(
      title: partial ? _optionalString(map['title']) : _string(map['title']),
      summary: partial
          ? _optionalString(map['summary'])
          : _string(map['summary']),
      skillInstructions: partial
          ? _optionalString(map['skillInstructions'])
          : _string(map['skillInstructions']),
      files: files,
      interfaces: interfaces,
      // An advisory public note cannot reject an otherwise valid file plan or
      // change source, execution authority or completion status.
      decisionSummary: map['decisionSummary'] is String
          ? map['decisionSummary'] as String
          : '',
      manifest: map['manifest'] == null
          ? null
          : _manifestObject(map['manifest']),
    );
  }

  final String title, summary, skillInstructions, interfaces, decisionSummary;
  final List<SourceFilePlan> files;
  final Map<String, Object?>? manifest;

  void validateUtilityManifest() {
    if (manifest == null) {
      throw const SourceWorkspaceProtocolException('utility_manifest_missing');
    }
    final parsed = SurfaceManifest.fromSpec(manifest);
    for (final action in parsed.actions) {
      if (action.declaredRisk != ActionRisk.localMutation ||
          action.declaredConsequencePolicy !=
              ActionConsequencePolicy.reversible) {
        throw const SourceWorkspaceProtocolException(
          'utility_action_authority',
        );
      }
    }
    if (parsed.schemaVersion != 2 ||
        parsed.diagnoseContract().isNotEmpty ||
        parsed.action('configure') == null) {
      throw const SourceWorkspaceProtocolException('utility_manifest');
    }
  }

  List<SourceFilePlan> orderedFiles({bool partial = false}) {
    final byId = {for (final file in files) file.id: file};
    final ordered = <SourceFilePlan>[];
    final state = <String, int>{};
    void visit(SourceFilePlan file) {
      if (state[file.id] == 2) return;
      if (state[file.id] == 1) {
        throw const SourceWorkspaceProtocolException('dependency_cycle');
      }
      state[file.id] = 1;
      for (final dependency in file.dependsOn) {
        final target = byId[dependency];
        if (target == null) {
          if (partial) continue;
          throw const SourceWorkspaceProtocolException('dependency_missing');
        }
        visit(target);
      }
      state[file.id] = 2;
      ordered.add(file);
    }

    for (final file in files) {
      visit(file);
    }
    if (!partial &&
        (!ordered.any((f) => f.kind == SourceFileKind.html) ||
            !ordered.any((f) => f.kind == SourceFileKind.js))) {
      throw const SourceWorkspaceProtocolException('required_files');
    }
    return List<SourceFilePlan>.unmodifiable(ordered);
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'summary': summary,
    'skillInstructions': skillInstructions,
    'interfaces': interfaces,
    if (decisionSummary.isNotEmpty) 'decisionSummary': decisionSummary,
    'files': files.map((f) => f.toJson()).toList(growable: false),
    if (manifest != null) 'manifest': manifest,
  };
}

class SourceFileSnapshot {
  SourceFileSnapshot({
    required this.plan,
    this.source = '',
    this.complete = false,
    this.previousSource,
    this.repairDiagnostic,
    Iterable<String> chunkDigests = const [],
  }) : chunkDigests = List<String>.unmodifiable(chunkDigests);
  factory SourceFileSnapshot.fromJson(Object? value) {
    final map = _object(value);
    _keys(
      map,
      required: const {'plan', 'source', 'complete', 'cursor'},
      optional: const {'chunkDigests', 'previousSource', 'repairDiagnostic'},
    );
    final source = _sourceString(map['source']);
    if (map['complete'] is! bool ||
        map['cursor'] is! int ||
        map['cursor'] != utf8.encode(source).length) {
      throw const SourceWorkspaceProtocolException('snapshot_cursor');
    }
    final digests = map['chunkDigests'] ?? const <String>[];
    if (digests is! List || digests.any((v) => v is! String)) {
      throw const SourceWorkspaceProtocolException('snapshot_chunks');
    }
    return SourceFileSnapshot(
      plan: SourceFilePlan.fromJson(map['plan']),
      source: source,
      complete: map['complete'] as bool,
      previousSource: map['previousSource'] == null
          ? null
          : _sourceString(map['previousSource']),
      repairDiagnostic: map['repairDiagnostic'] == null
          ? null
          : _string(map['repairDiagnostic']),
      chunkDigests: digests.cast<String>(),
    );
  }
  final SourceFilePlan plan;
  final String source;
  final bool complete;
  final String? previousSource, repairDiagnostic;
  final List<String> chunkDigests;
  int get cursor => utf8.encode(source).length;
  String get prefixHash => sourceWorkspaceDigest(source);
  Map<String, Object?> toJson() => {
    'plan': plan.toJson(),
    'source': source,
    'complete': complete,
    'cursor': cursor,
    if (previousSource != null) 'previousSource': previousSource,
    if (repairDiagnostic != null) 'repairDiagnostic': repairDiagnostic,
    'chunkDigests': chunkDigests,
  };
}

/// A data-only checkpoint. Account, request, session and execution authority
/// belong to the caller's scoped store and are never carried by this object.
class SourceWorkspaceSnapshot {
  SourceWorkspaceSnapshot({
    required this.requirementSha256,
    required this.experienceType,
    this.blueprint,
    this.blueprintComplete = false,
    Iterable<SourceFileSnapshot> files = const [],
    this.activeFileId,
    this.stallCount = 0,
    this.diagnostic,
    this.executionCheckpoint,
  }) : files = List<SourceFileSnapshot>.unmodifiable(files);
  factory SourceWorkspaceSnapshot.fromJson(Object? value) {
    final map = _object(value);
    _keys(
      map,
      required: const {
        'schemaVersion',
        'requirementSha256',
        'experienceType',
        'blueprint',
        'files',
      },
      optional: const {
        'blueprintComplete',
        'activeFileId',
        'stallCount',
        'diagnostic',
        'executionCheckpoint',
      },
    );
    if (map['schemaVersion'] != 1 && map['schemaVersion'] != 2) {
      throw const SourceWorkspaceProtocolException('snapshot_version');
    }
    if ((map['schemaVersion'] == 2) != (map['executionCheckpoint'] != null)) {
      throw const SourceWorkspaceProtocolException('snapshot_version');
    }
    final rawFiles = map['files'];
    if (rawFiles is! List) {
      throw const SourceWorkspaceProtocolException('snapshot_files');
    }
    final hash = _string(map['requirementSha256']);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const SourceWorkspaceProtocolException('snapshot_digest');
    }
    final kind = _string(map['experienceType']);
    if (kind != 'game' && kind != 'utility') {
      throw const SourceWorkspaceProtocolException('snapshot_experience');
    }
    final blueprint = map['blueprint'] == null
        ? null
        : SourceBlueprint.fromJson(
            map['blueprint'],
            partial: map['blueprintComplete'] != true,
          );
    final files = rawFiles.map(SourceFileSnapshot.fromJson).toList();
    if (files.map((f) => f.plan.id).toSet().length != files.length) {
      throw const SourceWorkspaceProtocolException('snapshot_duplicate_file');
    }
    final complete = map['blueprintComplete'] ?? blueprint != null;
    final active = map['activeFileId'];
    final stall = map['stallCount'] ?? 0;
    if (complete is! bool ||
        (active != null && active is! String) ||
        stall is! int ||
        stall < 0) {
      throw const SourceWorkspaceProtocolException('snapshot_fields');
    }
    if (complete && blueprint == null) {
      throw const SourceWorkspaceProtocolException('snapshot_plan');
    }
    if (blueprint != null) {
      final plans = {for (final p in blueprint.files) p.id: p};
      for (final file in files) {
        if (jsonEncode(plans[file.plan.id]?.toJson()) !=
            jsonEncode(file.plan.toJson())) {
          throw const SourceWorkspaceProtocolException('snapshot_plan_changed');
        }
      }
      if (complete) {
        blueprint.orderedFiles();
        if (kind == 'utility') blueprint.validateUtilityManifest();
        if (kind == 'game' && blueprint.manifest != null) {
          throw const SourceWorkspaceProtocolException(
            'game_manifest_authority',
          );
        }
      }
    } else if (files.isNotEmpty) {
      throw const SourceWorkspaceProtocolException('snapshot_plan');
    }
    return SourceWorkspaceSnapshot(
      requirementSha256: hash,
      experienceType: kind,
      blueprint: blueprint,
      blueprintComplete: complete,
      files: files,
      activeFileId: active as String?,
      stallCount: stall,
      diagnostic: map['diagnostic'] == null
          ? null
          : SourceGenerationDiagnostic.fromJson(map['diagnostic']),
      executionCheckpoint: map['executionCheckpoint'] == null
          ? null
          : SourceExecutionCheckpoint.fromJson(map['executionCheckpoint']),
    );
  }
  final String requirementSha256, experienceType;
  final SourceBlueprint? blueprint;
  final bool blueprintComplete;
  final List<SourceFileSnapshot> files;
  final String? activeFileId;
  final int stallCount;
  final SourceGenerationDiagnostic? diagnostic;
  final SourceExecutionCheckpoint? executionCheckpoint;

  SourceWorkspaceSnapshot withExecutionCheckpoint(
    SourceExecutionCheckpoint? checkpoint,
  ) => SourceWorkspaceSnapshot(
    requirementSha256: requirementSha256,
    experienceType: experienceType,
    blueprint: blueprint,
    blueprintComplete: blueprintComplete,
    files: files,
    activeFileId: activeFileId,
    stallCount: stallCount,
    diagnostic: diagnostic,
    executionCheckpoint: checkpoint,
  );

  /// Source identity excludes transient diagnostics and request bookkeeping.
  /// File order changes caused by replacing one file do not change its identity.
  String get executionDigest {
    final ordered = [...files]..sort((a, b) => a.plan.id.compareTo(b.plan.id));
    return sourceWorkspaceDigest(
      jsonEncode({
        'requirementSha256': requirementSha256,
        'experienceType': experienceType,
        'blueprint': blueprint?.toJson(),
        'blueprintComplete': blueprintComplete,
        'files': ordered.map((file) => file.toJson()).toList(),
      }),
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': executionCheckpoint == null ? 1 : 2,
    'requirementSha256': requirementSha256,
    'experienceType': experienceType,
    'blueprint': blueprint?.toJson(),
    'blueprintComplete': blueprintComplete,
    'files': files.map((f) => f.toJson()).toList(growable: false),
    'activeFileId': activeFileId,
    'stallCount': stallCount,
    if (diagnostic != null) 'diagnostic': diagnostic!.toJson(),
    if (executionCheckpoint != null)
      'executionCheckpoint': executionCheckpoint!.toJson(),
  };
}

/// A display/read range; never a replacement for the persisted source string.
class SourceTextRange {
  const SourceTextRange(this.startByte, this.endByte, this.text);
  final int startByte, endByte;
  final String text;
  Map<String, Object?> toJson() => {
    'startByte': startByte,
    'endByte': endByte,
    'text': text,
  };

  static List<SourceTextRange> window(String source, int budget) {
    final bytes = utf8.encode(source);
    if (budget <= 0 || bytes.isEmpty) return const [];
    if (bytes.length <= budget) {
      return [SourceTextRange(0, bytes.length, source)];
    }
    var headEnd = (budget + 1) ~/ 2;
    while (headEnd > 0 && !_boundary(bytes, headEnd)) {
      headEnd--;
    }
    var tailStart = bytes.length - (budget - headEnd);
    while (tailStart < bytes.length && !_boundary(bytes, tailStart)) {
      tailStart++;
    }
    return [
      if (headEnd > 0)
        SourceTextRange(0, headEnd, utf8.decode(bytes.sublist(0, headEnd))),
      if (tailStart < bytes.length)
        SourceTextRange(
          tailStart,
          bytes.length,
          utf8.decode(bytes.sublist(tailStart)),
        ),
    ];
  }
}

bool _boundary(List<int> bytes, int offset) =>
    offset == bytes.length || (bytes[offset] & 0xc0) != 0x80;

/// The model can inspect only source already owned by this exact workspace.
/// There are no paths, host tools, writes or execution permissions in this DTO.
class SourceInspectionRequest {
  const SourceInspectionRequest({
    required this.fileId,
    required this.startByte,
    required this.maxBytes,
    this.sourceVersion = 'current',
  });
  final String fileId, sourceVersion;
  final int startByte, maxBytes;

  static SourceInspectionRequest? tryDecode(String text) {
    final decoded = SourceJsonPrefixDecoder(text).decode();
    if (!decoded.values.containsKey('read')) return null;
    if (!decoded.complete) {
      throw const SourceWorkspaceProtocolException('inspection_binding');
    }
    try {
      _keys(decoded.values, required: const {'read'});
      final data = _object(decoded.values['read']);
      _keys(
        data,
        required: const {'fileId', 'startByte', 'maxBytes'},
        optional: const {'sourceVersion'},
      );
      final version = data.containsKey('sourceVersion')
          ? data['sourceVersion']
          : 'current';
      if (data['fileId'] is! String ||
          data['startByte'] is! int ||
          data['maxBytes'] is! int ||
          data['startByte']! as int < 0 ||
          data['maxBytes']! as int < 4 ||
          data['maxBytes']! as int > 16 * 1024 ||
          (version != 'current' && version != 'previous')) {
        throw const SourceWorkspaceProtocolException('inspection_binding');
      }
      return SourceInspectionRequest(
        fileId: data['fileId']! as String,
        startByte: data['startByte']! as int,
        maxBytes: data['maxBytes']! as int,
        sourceVersion: version as String,
      );
    } on SourceWorkspaceProtocolException catch (error) {
      throw SourceWorkspaceProtocolException(
        error.code,
        reason: error.reason,
        phase: SourceDiagnosticPhase.inspection,
      );
    }
  }

  SourceInspectionResult read(
    SourceWorkspaceSnapshot workspace, {
    int? displayBytes,
  }) {
    if (startByte < 0 ||
        maxBytes < 4 ||
        maxBytes > 16 * 1024 ||
        (sourceVersion != 'current' && sourceVersion != 'previous')) {
      throw const SourceWorkspaceProtocolException('inspection_binding');
    }
    final file = workspace.files
        .where((file) => file.plan.id == fileId)
        .firstOrNull;
    final source = sourceVersion == 'previous'
        ? file?.previousSource
        : file?.source;
    if (source == null) {
      throw const SourceWorkspaceProtocolException('inspection_binding');
    }
    final bytes = utf8.encode(source);
    if (startByte > bytes.length || !_boundary(bytes, startByte)) {
      throw const SourceWorkspaceProtocolException('inspection_binding');
    }
    final allowance = displayBytes == null
        ? maxBytes
        : displayBytes.clamp(4, maxBytes);
    var end = (startByte + allowance).clamp(startByte, bytes.length);
    while (end > startByte && !_boundary(bytes, end)) {
      end--;
    }
    return SourceInspectionResult(
      fileId: fileId,
      sourceVersion: sourceVersion,
      fullBytes: bytes.length,
      sha256: sourceWorkspaceDigest(source),
      range: SourceTextRange(
        startByte,
        end,
        utf8.decode(bytes.sublist(startByte, end)),
      ),
    );
  }
}

class SourceInspectionResult {
  const SourceInspectionResult({
    required this.fileId,
    required this.sourceVersion,
    required this.fullBytes,
    required this.sha256,
    required this.range,
  });
  final String fileId, sourceVersion, sha256;
  final int fullBytes;
  final SourceTextRange range;
  String get ledgerKey =>
      '$fileId/$sourceVersion/$sha256/${range.startByte}/${range.endByte}';
  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'sourceVersion': sourceVersion,
    'fullBytes': fullBytes,
    'sha256': sha256,
    ...range.toJson(),
  };
}

class SourceChunk {
  const SourceChunk({
    required this.fileId,
    required this.baseCursor,
    required this.prefixHash,
    required this.append,
    required this.done,
  });
  final String fileId, prefixHash, append;
  final int baseCursor;
  final bool done;

  /// Known-length responses may contribute only decoded complete characters
  /// of an append string after all bindings have been completely validated.
  /// The truncated response can never mark a file complete.
  factory SourceChunk.decode(
    String text, {
    required bool knownLength,
    required SourceFileSnapshot file,
  }) {
    final prefix = SourceJsonPrefixDecoder(text).decode();
    final map = prefix.values;
    _keys(
      map,
      required: const {'fileId', 'baseCursor', 'prefixHash', 'append', 'done'},
      partial: knownLength,
    );
    if (!knownLength && !prefix.complete) {
      throw const SourceWorkspaceProtocolException('chunk_incomplete');
    }
    if (!prefix.completeKeys.containsAll(const {
      'fileId',
      'baseCursor',
      'prefixHash',
    })) {
      throw const SourceWorkspaceProtocolException('chunk_bindings_incomplete');
    }
    if (map['baseCursor'] is! int ||
        map['fileId'] != file.plan.id ||
        map['baseCursor'] != file.cursor ||
        map['prefixHash'] != file.prefixHash) {
      throw const SourceWorkspaceProtocolException('chunk_binding');
    }
    final append = map['append'];
    if (append is! String) {
      throw const SourceWorkspaceProtocolException('chunk_append');
    }
    if (!knownLength && map['done'] is! bool) {
      throw const SourceWorkspaceProtocolException('chunk_done');
    }
    return SourceChunk(
      fileId: file.plan.id,
      baseCursor: file.cursor,
      prefixHash: file.prefixHash,
      append: append,
      done: !knownLength && map['done'] == true,
    );
  }
}

class SourceJsonPrefix {
  SourceJsonPrefix({
    required Map<String, Object?> values,
    required Set<String> completeKeys,
    required this.complete,
  }) : values = Map<String, Object?>.unmodifiable(values),
       completeKeys = Set<String>.unmodifiable(completeKeys);
  final Map<String, Object?> values;
  final Set<String> completeKeys;
  final bool complete;
}

/// A JSON lexer, never eval or bracket repair. It records only complete values
/// and complete string characters; incomplete objects in arrays are discarded.
class SourceJsonPrefixDecoder {
  SourceJsonPrefixDecoder(this.source);
  final String source;
  int _offset = 0;
  SourceJsonPrefix decode() {
    _space();
    if (!_take('{')) {
      throw const SourceWorkspaceProtocolException('json_object');
    }
    final parsed = _map(0);
    _space();
    if (parsed.complete && _offset != source.length) {
      throw const SourceWorkspaceProtocolException('json_trailing');
    }
    return SourceJsonPrefix(
      values: parsed.value as Map<String, Object?>,
      completeKeys: parsed.keys,
      complete: parsed.complete,
    );
  }

  _PrefixValue _map(int depth) {
    if (depth > 32) throw const SourceWorkspaceProtocolException('json_depth');
    final result = <String, Object?>{};
    final completeKeys = <String>{};
    _space();
    if (_take('}')) return _PrefixValue(result, true, keys: completeKeys);
    while (_offset < source.length) {
      if (!_take('"')) throw const SourceWorkspaceProtocolException('json_key');
      final key = _text();
      if (!key.complete) return _PrefixValue(result, false, keys: completeKeys);
      final name = key.value as String;
      if (result.containsKey(name)) {
        throw const SourceWorkspaceProtocolException('json_duplicate_key');
      }
      // A fully received key is part of the contract even if its value was
      // cut off. Never hide an authority field behind an unfinished colon.
      result[name] = null;
      _space();
      if (!_take(':')) {
        if (_offset == source.length) {
          return _PrefixValue(result, false, keys: completeKeys);
        }
        throw const SourceWorkspaceProtocolException('json_colon');
      }
      _space();
      if (_offset == source.length) {
        return _PrefixValue(result, false, keys: completeKeys);
      }
      final value = _value(depth + 1);
      result[name] = value.value;
      if (!value.complete) {
        return _PrefixValue(result, false, keys: completeKeys);
      }
      completeKeys.add(name);
      _space();
      if (_take('}')) return _PrefixValue(result, true, keys: completeKeys);
      if (_offset == source.length) {
        return _PrefixValue(result, false, keys: completeKeys);
      }
      if (!_take(',')) {
        throw const SourceWorkspaceProtocolException('json_separator');
      }
      _space();
    }
    return _PrefixValue(result, false, keys: completeKeys);
  }

  _PrefixValue _value(int depth) {
    if (depth > 32) throw const SourceWorkspaceProtocolException('json_depth');
    if (_take('"')) return _text();
    if (_take('{')) return _map(depth);
    if (_take('[')) {
      final result = <Object?>[];
      _space();
      if (_take(']')) return _PrefixValue(result, true);
      while (_offset < source.length) {
        final value = _value(depth + 1);
        if (!value.complete) return _PrefixValue(result, false);
        result.add(value.value);
        _space();
        if (_take(']')) return _PrefixValue(result, true);
        if (_offset == source.length) return _PrefixValue(result, false);
        if (!_take(',')) {
          throw const SourceWorkspaceProtocolException('json_separator');
        }
        _space();
      }
      return _PrefixValue(result, false);
    }
    final start = _offset;
    while (_offset < source.length && !',]} \r\n\t'.contains(source[_offset])) {
      _offset++;
    }
    if (_offset == source.length) return const _PrefixValue(null, false);
    if (_offset == start) {
      throw const SourceWorkspaceProtocolException('json_value');
    }
    final token = source.substring(start, _offset);
    try {
      final value = jsonDecode(token);
      if (value is num && !value.isFinite) throw const FormatException();
      return _PrefixValue(value, true);
    } on FormatException {
      throw const SourceWorkspaceProtocolException('json_value');
    }
  }

  _PrefixValue _text() {
    final result = StringBuffer();
    while (_offset < source.length) {
      var unit = source.codeUnitAt(_offset++);
      if (unit == 34) return _PrefixValue(result.toString(), true);
      if (unit < 32) {
        throw const SourceWorkspaceProtocolException('json_control');
      }
      if (unit == 92) {
        if (_offset == source.length) {
          return _PrefixValue(result.toString(), false);
        }
        final escape = source[_offset++];
        if (escape != 'u') {
          const escapes = {
            '"': 34,
            '\\': 92,
            '/': 47,
            'b': 8,
            'f': 12,
            'n': 10,
            'r': 13,
            't': 9,
          };
          final decoded = escapes[escape];
          if (decoded == null) {
            throw const SourceWorkspaceProtocolException('json_escape');
          }
          result.writeCharCode(decoded);
          continue;
        }
        if (_offset + 4 > source.length) {
          return _PrefixValue(result.toString(), false);
        }
        final hex = source.substring(_offset, _offset + 4);
        if (!RegExp(r'^[a-fA-F0-9]{4}$').hasMatch(hex)) {
          throw const SourceWorkspaceProtocolException('json_unicode');
        }
        unit = int.parse(hex, radix: 16);
        _offset += 4;
      }
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (_offset >= source.length) {
          return _PrefixValue(result.toString(), false);
        }
        int low;
        if (source[_offset] == '\\') {
          if (_offset + 6 > source.length) {
            return _PrefixValue(result.toString(), false);
          }
          final lowText = source.substring(_offset, _offset + 6);
          if (!RegExp(r'^\\u[a-fA-F0-9]{4}$').hasMatch(lowText)) {
            throw const SourceWorkspaceProtocolException('json_unicode');
          }
          low = int.parse(lowText.substring(2), radix: 16);
          _offset += 6;
        } else {
          low = source.codeUnitAt(_offset++);
        }
        if (low < 0xDC00 || low > 0xDFFF) {
          throw const SourceWorkspaceProtocolException('json_unicode');
        }
        result.writeCharCode(
          0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00),
        );
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        throw const SourceWorkspaceProtocolException('json_unicode');
      } else {
        result.writeCharCode(unit);
      }
    }
    return _PrefixValue(result.toString(), false);
  }

  bool _take(String token) {
    if (!source.startsWith(token, _offset)) return false;
    _offset += token.length;
    return true;
  }

  void _space() {
    while (_offset < source.length && ' \r\n\t'.contains(source[_offset])) {
      _offset++;
    }
  }
}

class _PrefixValue {
  const _PrefixValue(this.value, this.complete, {this.keys = const {}});
  final Object? value;
  final bool complete;
  final Set<String> keys;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const SourceWorkspaceProtocolException('object');
  }
  return Map<String, Object?>.from(value);
}

String _string(Object? value) {
  if (value is! String) throw const SourceWorkspaceProtocolException('string');
  return value;
}

String _optionalString(Object? value) => value == null ? '' : _string(value);

String _sourceString(Object? value) {
  final source = _string(value);
  if (utf8.decode(utf8.encode(source)) != source) {
    throw const SourceWorkspaceProtocolException('source_unicode');
  }
  return source;
}

Map<String, Object?> _manifestObject(Object? value) {
  final manifest = _object(value);
  _keys(
    manifest,
    required: const {'schemaVersion', 'events', 'actions'},
    optional: const {'instructions'},
  );
  for (final name in ['events', 'actions']) {
    final entries = manifest[name];
    if (entries is! List) {
      throw const SourceWorkspaceProtocolException('utility_manifest');
    }
    for (final entry in entries) {
      _keys(
        _object(entry),
        required: const {'name', 'schema', 'risk', 'consequencePolicy'},
      );
    }
  }
  return manifest;
}

void _keys(
  Map<String, Object?> value, {
  required Set<String> required,
  Set<String> optional = const {},
  bool partial = false,
}) {
  if (value.keys.any(
    (key) => !required.contains(key) && !optional.contains(key),
  )) {
    throw const SourceWorkspaceProtocolException(
      'fields',
      reason: SourceDiagnosticReason.unsupportedFields,
    );
  }
  if (!partial && !value.keys.toSet().containsAll(required)) {
    throw const SourceWorkspaceProtocolException(
      'fields',
      reason: SourceDiagnosticReason.missingFields,
    );
  }
}
