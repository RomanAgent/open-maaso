import 'dart:convert';

import 'source_workspace.dart';

enum SourceEditRejectionReason {
  invalidData,
  invalidSourceText,
  emptyOldText,
  unchangedEdit,
  ambiguousMatch,
  noMatch,
  invalidOffset,
  overlap,
}

class SourceEditRejectionFact {
  const SourceEditRejectionFact(this.editIndex, this.reason, {this.matchCount});
  final int editIndex;
  final SourceEditRejectionReason reason;
  final int? matchCount;
  Map<String, Object?> toJson() => {
    'editIndex': editIndex,
    'reason': reason.name,
    'matchCount': ?matchCount,
  };
}

class SourceFileEditRejection extends SourceWorkspaceProtocolException {
  SourceFileEditRejection(
    super.code,
    Iterable<SourceEditRejectionFact> facts, {
    Iterable<int> omittedEditIndices = const [],
  }) : facts = List.unmodifiable(facts),
       omittedEditIndices = List.unmodifiable(omittedEditIndices);
  final List<SourceEditRejectionFact> facts;
  final List<int> omittedEditIndices;
}

typedef _SourceEdit = ({String oldText, String newText, int? startUtf16});

/// Data-only exact replacements bound to one existing virtual source file.
/// Every match is located in the same original source before anything changes.
class SourceFileEdits {
  SourceFileEdits._(this.fileId, this.baseHash, this.edits);

  final String fileId, baseHash;
  final List<({String oldText, String newText, int? startUtf16})> edits;
  List<int> _omittedEditIndices = const [];
  List<int> get omittedEditIndices => _omittedEditIndices;

  factory SourceFileEdits.decode(
    String text, {
    required SourceFileSnapshot file,
    required bool knownLength,
  }) {
    if (knownLength) {
      throw const SourceWorkspaceProtocolException('edit_incomplete');
    }
    final parsed = SourceJsonPrefixDecoder(text).decode();
    final data = parsed.values;
    if (!parsed.complete) {
      throw const SourceWorkspaceProtocolException('edit_incomplete');
    }
    if (data.length != 3 ||
        !data.keys.toSet().containsAll({'fileId', 'baseHash', 'edits'})) {
      throw const SourceWorkspaceProtocolException('fields');
    }
    if (data['fileId'] != file.plan.id || data['baseHash'] != file.prefixHash) {
      throw const SourceWorkspaceProtocolException('chunk_binding');
    }
    final raw = data['edits'];
    if (raw is! List || raw.length > 128) {
      throw const SourceWorkspaceProtocolException('edit_count');
    }
    final edits = <_SourceEdit>[];
    final indices = <int>[];
    final failures = <SourceEditRejectionFact>[];
    for (final (index, value) in raw.indexed) {
      if (value is! Map ||
          value.keys.any(
            (key) => !const {'oldText', 'newText', 'startUtf16'}.contains(key),
          ) ||
          !value.keys.toSet().containsAll({'oldText', 'newText'}) ||
          value['oldText'] is! String ||
          value['newText'] is! String) {
        failures.add(
          SourceEditRejectionFact(index, SourceEditRejectionReason.invalidData),
        );
        continue;
      }
      if (value.containsKey('startUtf16') && value['startUtf16'] is! int) {
        failures.add(
          SourceEditRejectionFact(
            index,
            SourceEditRejectionReason.invalidOffset,
          ),
        );
        continue;
      }
      final oldText = value['oldText'] as String;
      final newText = value['newText'] as String;
      if (utf8.decode(utf8.encode(oldText)) != oldText ||
          utf8.decode(utf8.encode(newText)) != newText) {
        failures.add(
          SourceEditRejectionFact(
            index,
            SourceEditRejectionReason.invalidSourceText,
          ),
        );
        continue;
      }
      if (oldText.isEmpty) {
        failures.add(
          SourceEditRejectionFact(
            index,
            SourceEditRejectionReason.emptyOldText,
          ),
        );
      }
      edits.add((
        oldText: oldText,
        newText: newText,
        startUtf16: value['startUtf16'] as int?,
      ));
      indices.add(index);
    }
    if (failures.isNotEmpty) {
      for (final (index, edit) in edits.indexed) {
        final originalIndex = indices[index];
        if (!failures.any((fact) => fact.editIndex == originalIndex)) {
          _locate(file, edit, originalIndex, failures);
        }
      }
      failures.sort((a, b) => a.editIndex.compareTo(b.editIndex));
      final code = switch (failures.first.reason) {
        SourceEditRejectionReason.invalidData => 'fields',
        SourceEditRejectionReason.invalidSourceText => 'source_unicode',
        SourceEditRejectionReason.emptyOldText ||
        SourceEditRejectionReason.unchangedEdit => 'edit_no_progress',
        _ => 'edit_match',
      };
      throw SourceFileEditRejection(code, failures);
    }
    final result = SourceFileEdits._(
      file.plan.id,
      file.prefixHash,
      List.unmodifiable(edits),
    );
    if (edits.isNotEmpty &&
        edits.every((edit) => edit.oldText == edit.newText)) {
      // Pure unchanged delivery remains no-progress, but fake or malformed
      // unchanged spans must first fail their actual source bindings.
      result.apply(file);
    }
    return result;
  }

  String apply(SourceFileSnapshot file) {
    if (file.plan.id != fileId || file.prefixHash != baseHash) {
      throw const SourceWorkspaceProtocolException('chunk_binding');
    }
    final ranges = <({int index, int start, int end, String replacement})>[];
    final failures = <SourceEditRejectionFact>[];
    for (final (index, edit) in edits.indexed) {
      final start = _locate(file, edit, index, failures);
      if (start == null) continue;
      ranges.add((
        index: index,
        start: start,
        end: start + edit.oldText.length,
        replacement: edit.newText,
      ));
    }
    if (failures.isNotEmpty) {
      throw SourceFileEditRejection(
        'edit_match',
        failures,
        omittedEditIndices: ranges
            .where(
              (range) =>
                  edits[range.index].oldText == edits[range.index].newText,
            )
            .map((range) => range.index),
      );
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));
    for (var index = 1; index < ranges.length; index++) {
      if (ranges[index].start < ranges[index - 1].end) {
        failures.add(
          SourceEditRejectionFact(
            ranges[index].index,
            SourceEditRejectionReason.overlap,
          ),
        );
        failures.add(
          SourceEditRejectionFact(
            ranges[index - 1].index,
            SourceEditRejectionReason.overlap,
          ),
        );
      }
    }
    if (failures.isNotEmpty) {
      throw SourceFileEditRejection('edit_overlap', failures);
    }
    final meaningful = ranges
        .where(
          (range) => edits[range.index].oldText != edits[range.index].newText,
        )
        .toList();
    if (meaningful.isEmpty) {
      throw SourceFileEditRejection('edit_no_progress', [
        for (final range in ranges)
          SourceEditRejectionFact(
            range.index,
            SourceEditRejectionReason.unchangedEdit,
          ),
      ]);
    }
    _omittedEditIndices = List.unmodifiable(
      ranges
          .where(
            (range) => edits[range.index].oldText == edits[range.index].newText,
          )
          .map((range) => range.index),
    );
    var candidate = file.source;
    for (final range in meaningful.reversed) {
      candidate = candidate.replaceRange(
        range.start,
        range.end,
        range.replacement,
      );
    }
    if (candidate == file.source) {
      throw const SourceWorkspaceProtocolException('edit_no_progress');
    }
    return candidate;
  }

  static bool _boundary(String source, int offset) =>
      offset == source.length ||
      offset >= 0 &&
          offset < source.length &&
          !(source.codeUnitAt(offset) >= 0xDC00 &&
              source.codeUnitAt(offset) <= 0xDFFF);

  static int? _locate(
    SourceFileSnapshot file,
    _SourceEdit edit,
    int index,
    List<SourceEditRejectionFact> failures,
  ) {
    final source = file.source, explicit = edit.startUtf16;
    if (explicit != null) {
      final end = explicit + edit.oldText.length;
      if (explicit < 0 ||
          end > source.length ||
          !_boundary(source, explicit) ||
          !_boundary(source, end)) {
        failures.add(
          SourceEditRejectionFact(
            index,
            SourceEditRejectionReason.invalidOffset,
          ),
        );
        return null;
      }
      if (source.substring(explicit, end) != edit.oldText) {
        failures.add(
          SourceEditRejectionFact(
            index,
            SourceEditRejectionReason.noMatch,
            matchCount: 0,
          ),
        );
        return null;
      }
      return explicit;
    }
    var count = 0, cursor = 0, first = -1;
    for (;;) {
      final match = source.indexOf(edit.oldText, cursor);
      if (match < 0) break;
      if (first < 0) first = match;
      count++;
      cursor = match + 1;
    }
    if (count != 1) {
      failures.add(
        SourceEditRejectionFact(
          index,
          count == 0
              ? SourceEditRejectionReason.noMatch
              : SourceEditRejectionReason.ambiguousMatch,
          matchCount: count,
        ),
      );
      return null;
    }
    return first;
  }
}
