import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/application/home_composer_attachment_editing.dart';

const _scope = 'https://example.test|account-a';

HomeComposerAttachmentDraft _draft({
  String text = '',
  TextSelection selection = const TextSelection.collapsed(offset: 0),
  TextRange composing = TextRange.empty,
  List<String> attachments = const ['first', 'second'],
  String? selected,
}) => HomeComposerAttachmentDraft(
  accountScopeKey: _scope,
  revision: 7,
  textValue: TextEditingValue(
    text: text,
    selection: selection,
    composing: composing,
  ),
  attachmentIds: attachments,
  selectedAttachmentId: selected,
);

HomeComposerAttachmentDraft _backspace(HomeComposerAttachmentDraft draft) =>
    HomeComposerAttachmentEditing.backwardDeleteAtBoundary(
      draft,
      expectedScopeKey: _scope,
      expectedRevision: draft.revision,
    );

void main() {
  test('boundary deletion selects then removes one adjacent image', () {
    final original = _draft(text: ' keep this\n');
    final selected = _backspace(original);
    expect(selected.attachmentIds, ['first', 'second']);
    expect(selected.selectedAttachmentId, 'second');
    expect(selected.revision, 8);

    final removed = _backspace(selected);
    expect(removed.attachmentIds, ['first']);
    expect(removed.selectedAttachmentId, isNull);
    expect(removed.revision, 9);
    expect(removed.textValue, original.textValue);
    expect(original.attachmentIds, ['first', 'second']);
    expect(original.selectedAttachmentId, isNull);

    final selectNext = _backspace(removed);
    expect(selectNext.selectedAttachmentId, 'first');
    final empty = _backspace(selectNext);
    expect(empty.attachmentIds, isEmpty);
    expect(_backspace(empty), same(empty));
  });

  test('ordinary text deletion and unfocused input do not delete images', () {
    for (final selection in [
      const TextSelection.collapsed(offset: 1),
      const TextSelection(baseOffset: 0, extentOffset: 2),
      const TextSelection(baseOffset: 2, extentOffset: 0),
      const TextSelection.collapsed(offset: -1),
    ]) {
      final draft = _draft(text: '文字', selection: selection);
      expect(_backspace(draft), same(draft));
    }
  });

  test('selected-image deletion removes that image without changing text', () {
    final draft = _draft(
      text: '草稿',
      selection: const TextSelection.collapsed(offset: 2),
    );
    final selected = HomeComposerAttachmentEditing.selectAttachment(
      draft,
      attachmentId: 'first',
      expectedScopeKey: _scope,
      expectedRevision: draft.revision,
    );
    final removed = HomeComposerAttachmentEditing.deleteSelectedAttachment(
      selected,
      expectedScopeKey: _scope,
      expectedRevision: selected.revision,
    );
    expect(removed.attachmentIds, ['second']);
    expect(removed.textValue, draft.textValue);
    expect(removed.selectedAttachmentId, isNull);
  });

  test('long-press deletion preserves a different selected image', () {
    final draft = _draft(selected: 'second');
    final removed = HomeComposerAttachmentEditing.removeAttachment(
      draft,
      attachmentId: 'first',
      expectedScopeKey: _scope,
      expectedRevision: draft.revision,
    );
    expect(removed.attachmentIds, ['second']);
    expect(removed.selectedAttachmentId, 'second');
  });

  test('unknown or already-selected image actions are no-ops', () {
    final draft = _draft(selected: 'first');
    for (final id in ['missing', 'first']) {
      expect(
        HomeComposerAttachmentEditing.selectAttachment(
          draft,
          attachmentId: id,
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        same(draft),
      );
    }
    expect(
      HomeComposerAttachmentEditing.removeAttachment(
        draft,
        attachmentId: 'missing',
        expectedScopeKey: _scope,
        expectedRevision: draft.revision,
      ),
      same(draft),
    );
    final unselected = _draft();
    expect(
      HomeComposerAttachmentEditing.deleteSelectedAttachment(
        unselected,
        expectedScopeKey: _scope,
        expectedRevision: unselected.revision,
      ),
      same(unselected),
    );
  });

  test(
    'composition blocks every attachment action but permits IME text edits',
    () {
      final draft = _draft(
        text: 'ni',
        composing: const TextRange(start: 0, end: 2),
        selected: 'first',
      );
      expect(_backspace(draft), same(draft));
      expect(
        HomeComposerAttachmentEditing.selectAttachment(
          draft,
          attachmentId: 'second',
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        same(draft),
      );
      expect(
        HomeComposerAttachmentEditing.deleteSelectedAttachment(
          draft,
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        same(draft),
      );
      expect(
        HomeComposerAttachmentEditing.removeAttachment(
          draft,
          attachmentId: 'first',
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        same(draft),
      );

      const composed = TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      final updated = HomeComposerAttachmentEditing.updateText(
        draft,
        textValue: composed,
        expectedScopeKey: _scope,
        expectedRevision: draft.revision,
      );
      expect(updated.textValue, composed);
      expect(updated.attachmentIds, draft.attachmentIds);
      expect(updated.selectedAttachmentId, isNull);
      expect(updated.revision, draft.revision + 1);
    },
  );

  for (final staleScope in [false, true]) {
    test(
      '${staleScope ? 'account' : 'revision'} mismatch rejects every edit',
      () {
        final draft = _draft(selected: 'first');
        final scope = staleScope ? 'https://example.test|account-b' : _scope;
        final revision = staleScope ? draft.revision : draft.revision - 1;
        final results = [
          HomeComposerAttachmentEditing.backwardDeleteAtBoundary(
            draft,
            expectedScopeKey: scope,
            expectedRevision: revision,
          ),
          HomeComposerAttachmentEditing.selectAttachment(
            draft,
            attachmentId: 'second',
            expectedScopeKey: scope,
            expectedRevision: revision,
          ),
          HomeComposerAttachmentEditing.deleteSelectedAttachment(
            draft,
            expectedScopeKey: scope,
            expectedRevision: revision,
          ),
          HomeComposerAttachmentEditing.removeAttachment(
            draft,
            attachmentId: 'first',
            expectedScopeKey: scope,
            expectedRevision: revision,
          ),
          HomeComposerAttachmentEditing.updateText(
            draft,
            textValue: const TextEditingValue(text: 'old callback'),
            expectedScopeKey: scope,
            expectedRevision: revision,
          ),
        ];
        for (final result in results) {
          expect(result, same(draft));
        }
      },
    );
  }

  test('a replayed first deletion cannot remove the newly selected image', () {
    final draft = _draft();
    final selected = _backspace(draft);
    expect(
      HomeComposerAttachmentEditing.backwardDeleteAtBoundary(
        selected,
        expectedScopeKey: _scope,
        expectedRevision: draft.revision,
      ),
      same(selected),
    );
  });

  test(
    'genuine text updates clear image selection and identical edits do not',
    () {
      final draft = _draft(text: 'keep', selected: 'first');
      expect(
        HomeComposerAttachmentEditing.updateText(
          draft,
          textValue: draft.textValue,
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        same(draft),
      );
      final updated = HomeComposerAttachmentEditing.updateText(
        draft,
        textValue: draft.textValue.copyWith(
          selection: const TextSelection.collapsed(offset: 3),
        ),
        expectedScopeKey: _scope,
        expectedRevision: draft.revision,
      );
      expect(updated.submissionText, 'keep');
      expect(updated.selectedAttachmentId, isNull);
      expect(updated.attachmentIds, draft.attachmentIds);
    },
  );

  test(
    'submission and selected text preserve Unicode and possible marker literals',
    () {
      const text = '  中文👩🏽‍💻\n\u200b\u2060\ufffc  ';
      final emojiStart = text.indexOf('👩');
      final emojiEnd = text.indexOf('\n');
      final draft = _draft(
        text: text,
        selection: TextSelection(
          baseOffset: emojiEnd,
          extentOffset: emojiStart,
        ),
      );
      expect(draft.submissionText, text);
      expect(draft.selectedText, '👩🏽‍💻');
      expect(
        _draft(
          text: text,
          selection: TextSelection(baseOffset: 0, extentOffset: text.length),
        ).selectedText,
        text,
      );
      expect(_draft(text: text).selectedText, '');
      expect(
        _draft(
          text: text,
          selection: const TextSelection.collapsed(offset: -1),
        ).selectedText,
        '',
      );
    },
  );

  test('attachment identities are immutable snapshots', () {
    final ids = ['first', 'second'];
    final draft = _draft(attachments: ids);
    ids.clear();
    expect(draft.attachmentIds, ['first', 'second']);
    expect(() => draft.attachmentIds.add('third'), throwsUnsupportedError);
  });

  test(
    'zero-length marked text remains IME-owned for every attachment action',
    () {
      final draft = _draft(
        composing: const TextRange(start: 0, end: 0),
        selected: 'first',
      );
      final results = [
        _backspace(draft),
        HomeComposerAttachmentEditing.selectAttachment(
          draft,
          attachmentId: 'second',
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        HomeComposerAttachmentEditing.deleteSelectedAttachment(
          draft,
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
        HomeComposerAttachmentEditing.removeAttachment(
          draft,
          attachmentId: 'first',
          expectedScopeKey: _scope,
          expectedRevision: draft.revision,
        ),
      ];
      for (final result in results) {
        expect(result, same(draft));
      }
    },
  );

  test('invalid attachment identity or editing ranges are rejected', () {
    expect(() => _draft(attachments: ['same', 'same']), throwsArgumentError);
    expect(() => _draft(attachments: ['']), throwsArgumentError);
    expect(() => _draft(selected: 'missing'), throwsArgumentError);
    expect(
      () => _draft(
        text: 'x',
        selection: const TextSelection.collapsed(offset: 2),
      ),
      throwsArgumentError,
    );
    expect(
      () => _draft(text: 'x', composing: const TextRange(start: 0, end: 2)),
      throwsArgumentError,
    );
  });
}
