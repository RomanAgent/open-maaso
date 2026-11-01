import 'package:flutter/services.dart';

/// Canonical, process-local draft data for the Home attachment editing boundary.
///
/// Text contains only user content. Keyboard transport, attachment bytes and
/// submission ownership stay with the caller; this value owns none of them.
final class HomeComposerAttachmentDraft {
  HomeComposerAttachmentDraft({
    required this.accountScopeKey,
    required this.revision,
    required this.textValue,
    required Iterable<String> attachmentIds,
    this.selectedAttachmentId,
  }) : attachmentIds = List<String>.unmodifiable(attachmentIds) {
    if (accountScopeKey.trim().isEmpty || revision < 0) {
      throw ArgumentError(
        'A nonempty account scope and revision >= 0 are required',
      );
    }
    _validateTextValue(textValue);
    if (this.attachmentIds.any((id) => id.trim().isEmpty) ||
        this.attachmentIds.toSet().length != this.attachmentIds.length) {
      throw ArgumentError.value(attachmentIds, 'attachmentIds', 'Invalid IDs');
    }
    if (selectedAttachmentId != null &&
        !this.attachmentIds.contains(selectedAttachmentId)) {
      throw ArgumentError.value(selectedAttachmentId, 'selectedAttachmentId');
    }
  }

  final String accountScopeKey;
  final int revision;
  final TextEditingValue textValue;
  final List<String> attachmentIds;
  final String? selectedAttachmentId;

  /// Exact user text, without trimming, normalization or internal markers.
  String get submissionText => textValue.text;

  /// Exact selected user text. Unfocused/collapsed selections copy no text.
  String get selectedText => textValue.selection.isValid
      ? textValue.selection.textInside(textValue.text)
      : '';

  static void _validateTextValue(TextEditingValue value) {
    final selection = value.selection;
    final noSelection =
        selection.baseOffset == -1 && selection.extentOffset == -1;
    if (!noSelection &&
        (!selection.isValid || selection.end > value.text.length)) {
      throw ArgumentError.value(selection, 'textValue.selection');
    }
    final composing = value.composing;
    if (composing != TextRange.empty &&
        (!composing.isValid ||
            !composing.isNormalized ||
            composing.end > value.text.length)) {
      throw ArgumentError.value(composing, 'textValue.composing');
    }
  }
}

/// Pure transitions for attachment selection/deletion, with stale-event guards.
///
/// This is not a keyboard adapter: the caller must supply a verified boundary
/// deletion event. In particular, it does not make mobile soft keyboards emit
/// Backspace at an empty text boundary.
abstract final class HomeComposerAttachmentEditing {
  /// First boundary delete selects the preceding attachment; the next removes it.
  static HomeComposerAttachmentDraft backwardDeleteAtBoundary(
    HomeComposerAttachmentDraft draft, {
    required String expectedScopeKey,
    required int expectedRevision,
  }) {
    if (!_canEditAttachments(draft, expectedScopeKey, expectedRevision) ||
        !draft.textValue.selection.isCollapsed ||
        draft.textValue.selection.extentOffset != 0) {
      return draft;
    }
    if (draft.selectedAttachmentId != null) {
      return _remove(draft, draft.selectedAttachmentId!);
    }
    if (draft.attachmentIds.isEmpty) return draft;
    return _replace(draft, selectedAttachmentId: draft.attachmentIds.last);
  }

  static HomeComposerAttachmentDraft selectAttachment(
    HomeComposerAttachmentDraft draft, {
    required String attachmentId,
    required String expectedScopeKey,
    required int expectedRevision,
  }) {
    if (!_canEditAttachments(draft, expectedScopeKey, expectedRevision) ||
        !draft.attachmentIds.contains(attachmentId) ||
        draft.selectedAttachmentId == attachmentId) {
      return draft;
    }
    return _replace(draft, selectedAttachmentId: attachmentId);
  }

  static HomeComposerAttachmentDraft deleteSelectedAttachment(
    HomeComposerAttachmentDraft draft, {
    required String expectedScopeKey,
    required int expectedRevision,
  }) {
    if (!_canEditAttachments(draft, expectedScopeKey, expectedRevision) ||
        draft.selectedAttachmentId == null) {
      return draft;
    }
    return _remove(draft, draft.selectedAttachmentId!);
  }

  /// Shared removal boundary for a long-press or accessibility delete action.
  static HomeComposerAttachmentDraft removeAttachment(
    HomeComposerAttachmentDraft draft, {
    required String attachmentId,
    required String expectedScopeKey,
    required int expectedRevision,
  }) {
    if (!_canEditAttachments(draft, expectedScopeKey, expectedRevision) ||
        !draft.attachmentIds.contains(attachmentId)) {
      return draft;
    }
    return _remove(draft, attachmentId);
  }

  /// Accepts genuine text/selection/composition edits without interpreting them
  /// as attachment commands. Editing text clears any attachment selection.
  static HomeComposerAttachmentDraft updateText(
    HomeComposerAttachmentDraft draft, {
    required TextEditingValue textValue,
    required String expectedScopeKey,
    required int expectedRevision,
  }) {
    if (!_isCurrent(draft, expectedScopeKey, expectedRevision) ||
        draft.textValue == textValue) {
      return draft;
    }
    return _replace(draft, textValue: textValue);
  }

  static bool _isCurrent(
    HomeComposerAttachmentDraft draft,
    String expectedScopeKey,
    int expectedRevision,
  ) =>
      draft.accountScopeKey == expectedScopeKey &&
      draft.revision == expectedRevision;

  static bool _canEditAttachments(
    HomeComposerAttachmentDraft draft,
    String expectedScopeKey,
    int expectedRevision,
  ) =>
      _isCurrent(draft, expectedScopeKey, expectedRevision) &&
      draft.textValue.composing == TextRange.empty;

  static HomeComposerAttachmentDraft _remove(
    HomeComposerAttachmentDraft draft,
    String attachmentId,
  ) => _replace(
    draft,
    attachmentIds: draft.attachmentIds.where((id) => id != attachmentId),
    selectedAttachmentId: draft.selectedAttachmentId == attachmentId
        ? null
        : draft.selectedAttachmentId,
  );

  static HomeComposerAttachmentDraft _replace(
    HomeComposerAttachmentDraft draft, {
    TextEditingValue? textValue,
    Iterable<String>? attachmentIds,
    String? selectedAttachmentId,
  }) => HomeComposerAttachmentDraft(
    accountScopeKey: draft.accountScopeKey,
    revision: draft.revision + 1,
    textValue: textValue ?? draft.textValue,
    attachmentIds: attachmentIds ?? draft.attachmentIds,
    selectedAttachmentId: selectedAttachmentId,
  );
}
