import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';

const _owner = 'account-a/editor-1';

Map<String, Object?> _event(
  int sequence, {
  String owner = _owner,
  String kind = 'edit',
  String text = '',
  int caret = 0,
  int composingStart = -1,
  int composingEnd = -1,
  Object? attachment,
}) => {
  'owner': owner,
  'sequence': sequence,
  'kind': kind,
  'text': text,
  'selectionBase': caret,
  'selectionExtent': caret,
  'composingStart': composingStart,
  'composingEnd': composingEnd,
  if (attachment != null) 'attachment': attachment,
};

HomeNativeAttachmentSnapshot _attachments({
  int token = 7,
  List<String> ids = const ['A', 'B'],
  String? selectedId,
  bool enabled = true,
}) => HomeNativeAttachmentSnapshot(
  token: token,
  ids: ids,
  selectedId: selectedId,
  enabled: enabled,
);

Map<String, Object?> _attachmentEvent(
  int sequence,
  HomeNativeAttachmentSnapshot before, {
  String text = '',
  int caret = 0,
  int composingStart = -1,
  int composingEnd = -1,
}) => _event(
  sequence,
  kind: before.selectedId == null
      ? 'boundaryDelete'
      : 'deleteSelectedAttachment',
  text: text,
  caret: caret,
  composingStart: composingStart,
  composingEnd: composingEnd,
  attachment: {
    'snapshotToken': before.token,
    'beforeIds': before.ids,
    'beforeSelectedId': before.selectedId,
    'targetId': before.selectedId ?? before.ids.last,
  },
);

Map<String, Object?> _ack(MethodCall call, {bool focused = false}) {
  final args = call.arguments as Map;
  final sequence = args['expectedSequence'] as int? ?? 0;
  return {
    'accepted': true,
    'sequence': sequence,
    if (call.method == 'sync') ...{
      'value': {
        'owner': args['owner'],
        'sequence': sequence,
        'kind': 'edit',
        'text': args['text'],
        'selectionBase': args['selectionBase'],
        'selectionExtent': args['selectionExtent'],
        'composingStart': args['composingStart'],
        'composingEnd': args['composingEnd'],
      },
      'focused': focused,
    },
  };
}

Map<String, Object?> _metrics(
  int revision, {
  String owner = _owner,
  double width = 320,
  double contentHeight = 96,
  double lineHeight = 24,
}) => {
  'owner': owner,
  'metricsRevision': revision,
  'width': width,
  'contentHeight': contentHeight,
  'lineHeight': lineHeight,
};

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _NativeChannel extends MethodChannel {
  _NativeChannel() : super('test/home-native-editor');

  Future<dynamic> Function(MethodCall)? handler;
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? reply;
  bool focused = false;

  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? handler) {
    this.handler = handler;
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final call = MethodCall(method, arguments);
    calls.add(call);
    if (reply case final callback?) return await callback(call) as T?;
    return _ack(call, focused: focused) as T?;
  }

  Future<void> emit(Map<String, Object?> event) async {
    if (event['kind'] == 'focus') focused = true;
    if (event['kind'] == 'blur') focused = false;
    await handler?.call(MethodCall('editingEvent', event));
  }

  Future<void> emitMetrics(Map<String, Object?> metrics) async {
    await handler?.call(MethodCall('layoutMetrics', metrics));
  }
}

void main() {
  test(
    'native snapshots retain exact genuine UTF16 text and selection',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      const text = '  中文👩🏽‍💻\n\u200b\u2060\ufffc  ';
      await channel.emit(_event(1, text: text, caret: text.length));
      await _flush();
      expect(controller.text, text);
      expect(controller.selection.extentOffset, text.length);
      expect(bridge.creationParams(fontSize: 16, dark: false)['text'], text);
      final sync = channel.calls.lastWhere((call) => call.method == 'sync');
      expect((sync.arguments as Map)['text'], text);
      expect(
        channel.calls.any((call) => call.method.contains('Clipboard')),
        isFalse,
      );
      expect(bridge.synchronized, isTrue);
    },
  );

  test(
    'old owner, duplicate and out-of-order events cannot edit draft',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(_event(1, owner: 'retired', text: 'old'));
      expect(controller.text, '');
      await channel.emit(_event(1, text: 'new', caret: 3));
      await channel.emit(_event(1, text: 'duplicate'));
      await channel.emit(_event(3, text: 'gap'));
      expect(controller.text, 'new');
      expect(bridge.sequence, 1);
      expect(bridge.errorCode, 'native_sequence_gap');
      await channel.emit(_event(2, text: 'next', caret: 4));
      await _flush();
      expect(controller.text, 'next');
      expect(bridge.sequence, 2);
    },
  );

  test(
    'rapid B B A A commands advance one fixed-target snapshot chain',
    () async {
      final controller = TextEditingController();
      final commands = <HomeNativeAttachmentCommand>[];
      var draft = _attachments();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: draft,
        onAttachmentCommand: (command) {
          commands.add(command);
          draft = draft.apply(command);
          return draft;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      final events = [
        _attachmentEvent(1, _attachments()),
        _attachmentEvent(2, _attachments(selectedId: 'B')),
        _attachmentEvent(3, _attachments(ids: ['A'])),
        _attachmentEvent(4, _attachments(ids: ['A'], selectedId: 'A')),
      ];
      await Future.wait(events.map(channel.emit));
      await channel.emit(events.last);
      await _flush();
      expect(commands.map((command) => command.kind), [
        HomeNativeEditingEventKind.boundaryDelete,
        HomeNativeEditingEventKind.deleteSelectedAttachment,
        HomeNativeEditingEventKind.boundaryDelete,
        HomeNativeEditingEventKind.deleteSelectedAttachment,
      ]);
      expect(commands.map((command) => command.targetId), ['B', 'B', 'A', 'A']);
      expect(commands.map((command) => command.snapshotToken), everyElement(7));
      expect(commands.map((command) => command.beforeIds), [
        ['A', 'B'],
        ['A', 'B'],
        ['A'],
        ['A'],
      ]);
      expect(commands.map((command) => command.beforeSelectedId), [
        null,
        'B',
        null,
        'A',
      ]);
      expect(bridge.attachmentSnapshot.ids, isEmpty);
      expect(bridge.attachmentSnapshot.selectedId, isNull);
      expect(bridge.attachmentSnapshot.token, 7);
      expect(bridge.lastAttachmentRejection, isNull);
      expect(bridge.sequence, 4);
      expect(controller.text, '');
      expect(bridge.synchronized, isTrue);
      final sync = channel.calls.lastWhere((call) => call.method == 'sync');
      expect((sync.arguments as Map)['attachments'], draft.toJson());
    },
  );

  test(
    'external snapshot change rejects queued target and still consumes sequence',
    () async {
      final controller = TextEditingController();
      final previous = _attachments(selectedId: 'B');
      var draft = previous;
      final targets = <String>[];
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: draft,
        onAttachmentCommand: (command) {
          targets.add(command.targetId);
          draft = draft.apply(command);
          return draft;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      draft = _attachments(token: 8, selectedId: 'A');
      bridge.setAttachmentSnapshot(draft);
      await channel.emit(_attachmentEvent(1, previous));
      expect(targets, isEmpty);
      expect(bridge.sequence, 1);
      expect(bridge.lastAttachmentRejection, 'snapshot_changed');
      expect(bridge.attachmentSnapshot.sameAs(draft), isTrue);
      await channel.emit(_attachmentEvent(2, draft));
      await _flush();
      expect(targets, ['A']);
      expect(bridge.sequence, 2);
      expect(bridge.attachmentSnapshot.ids, ['B']);
      expect(bridge.lastAttachmentRejection, isNull);
      expect(controller.text, '');
      expect(bridge.synchronized, isTrue);
    },
  );

  test(
    'same IDs with a new token cannot revive an old queued deletion',
    () async {
      final controller = TextEditingController();
      final old = _attachments(ids: ['B'], selectedId: 'B');
      var calls = 0;
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: old,
        onAttachmentCommand: (_) {
          calls++;
          return null;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      bridge.setAttachmentSnapshot(_attachments(token: 8, ids: []));
      final replacement = _attachments(token: 9, ids: ['B'], selectedId: 'B');
      bridge.setAttachmentSnapshot(replacement);
      await channel.emit(_attachmentEvent(1, old));
      await _flush();
      expect(calls, 0);
      expect(bridge.sequence, 1);
      expect(bridge.lastAttachmentRejection, 'snapshot_changed');
      expect(bridge.attachmentSnapshot.sameAs(replacement), isTrue);
    },
  );

  test(
    'changed selection rejects a queued fixed target even with the same token',
    () async {
      final controller = TextEditingController();
      final old = _attachments(selectedId: 'B');
      var calls = 0;
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: old,
        onAttachmentCommand: (_) {
          calls++;
          return null;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      final selectedA = _attachments(selectedId: 'A');
      bridge.setAttachmentSnapshot(selectedA);
      await channel.emit(_attachmentEvent(1, old));
      expect(calls, 0);
      expect(bridge.sequence, 1);
      expect(bridge.lastAttachmentRejection, 'snapshot_changed');
      expect(bridge.attachmentSnapshot.sameAs(selectedA), isTrue);
    },
  );

  test(
    'draft callback must return the exact accepted attachment transition',
    () async {
      final controller = TextEditingController();
      final initial = _attachments();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: initial,
        onAttachmentCommand: (_) => _attachments(selectedId: 'A'),
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(_attachmentEvent(1, initial));
      expect(bridge.sequence, 1);
      expect(bridge.lastAttachmentRejection, 'draft_changed');
      expect(bridge.attachmentSnapshot.sameAs(initial), isTrue);
    },
  );

  test(
    'missing and malformed attachment envelopes never reach the draft',
    () async {
      final controller = TextEditingController();
      var calls = 0;
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: _attachments(),
        onAttachmentCommand: (_) {
          calls++;
          return null;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      const valid = <String, Object?>{
        'snapshotToken': 7,
        'beforeIds': ['A', 'B'],
        'beforeSelectedId': null,
        'targetId': 'B',
      };
      for (final envelope in <Object?>[
        null,
        <String, Object?>{},
        {...valid, 'snapshotToken': -1},
        {...valid, 'snapshotToken': 7.0},
        {
          ...valid,
          'beforeIds': ['A', 'A'],
        },
        {
          ...valid,
          'beforeIds': ['A', 1],
        },
        {
          ...valid,
          'beforeIds': ['A', 'B', 'C', 'D', 'E'],
        },
        {...valid, 'beforeSelectedId': 'unknown'},
        {...valid, 'targetId': 'A'},
      ]) {
        await channel.emit(
          _event(1, kind: 'boundaryDelete', attachment: envelope),
        );
        expect(calls, 0);
        expect(bridge.sequence, 0);
        expect(bridge.errorCode, 'invalid_attachment_event');
        expect(bridge.attachmentSnapshot.ids, ['A', 'B']);
        expect(controller.text, '');
      }
    },
  );

  test(
    'composition edits are mirrored while attachment callbacks are rejected',
    () async {
      final controller = TextEditingController();
      var deletes = 0;
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: _attachments(),
        onAttachmentCommand: (_) {
          deletes++;
          return null;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(
        _event(1, text: 'ni', composingStart: 0, composingEnd: 2),
      );
      expect(controller.value.composing, const TextRange(start: 0, end: 2));
      await channel.emit(
        _attachmentEvent(
          2,
          _attachments(),
          text: 'ni',
          composingStart: 0,
          composingEnd: 2,
        ),
      );
      expect(deletes, 0);
      expect(bridge.sequence, 1);
      expect(bridge.errorCode, 'invalid_attachment_event');
      controller.value = controller.value.copyWith(composing: TextRange.empty);
      expect(controller.value.composing, const TextRange(start: 0, end: 2));
      expect(bridge.errorCode, 'programmatic_composition_rejected');
    },
  );

  test(
    'rejected programmatic writes restore last native text without retry loop',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(_event(1, text: 'native', caret: 6));
      await _flush();
      channel.reply = (call) async => {'accepted': false, 'sequence': 1};
      controller.value = const TextEditingValue(
        text: 'programmatic',
        selection: TextSelection.collapsed(offset: 12),
      );
      await _flush();
      expect(controller.text, 'native');
      expect(bridge.errorCode, 'native_sync_rejected');
      final count = channel.calls.length;
      await _flush();
      expect(channel.calls, hasLength(count));
    },
  );

  test('an older sync ACK cannot clear a newer rejected-event fault', () async {
    final controller = TextEditingController();
    final bridge = HomeNativeTextEditingBridge(
      owner: _owner,
      controller: controller,
      attachmentSnapshot: _attachments(),
    );
    final channel = _NativeChannel();
    addTearDown(() {
      bridge.dispose();
      controller.dispose();
    });
    bridge.attachView(1, channel: channel);
    await _flush();
    final pending = Completer<Object?>();
    channel.reply = (call) =>
        call.method == 'sync' ? pending.future : Future.value(null);
    final composing = _event(1, text: 'ni', composingStart: 0, composingEnd: 2);
    await channel.emit(composing);
    await _flush();
    await channel.emit(
      _attachmentEvent(
        2,
        _attachments(),
        text: 'ni',
        composingStart: 0,
        composingEnd: 2,
      ),
    );
    expect(bridge.errorCode, 'invalid_attachment_event');
    pending.complete({
      'accepted': true,
      'sequence': 1,
      'value': composing,
      'focused': false,
    });
    await _flush();
    expect(bridge.errorCode, 'invalid_attachment_event');
    expect(bridge.synchronized, isFalse);
    expect(bridge.sequence, 1);
    expect(controller.text, 'ni');
    expect(controller.value.composing, const TextRange(start: 0, end: 2));
  });

  test(
    'sync mirrors native normalized selection instead of requested offsets',
    () async {
      final controller = TextEditingController.fromValue(
        const TextEditingValue(
          text: 'ab',
          selection: TextSelection(baseOffset: 2, extentOffset: 0),
        ),
      );
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      channel.reply = (call) async => {
        'accepted': true,
        'sequence': 0,
        'focused': false,
        'value': {
          ..._event(1, text: 'ab', caret: 2),
          'sequence': 0,
          'selectionBase': 0,
        },
      };
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      expect(
        controller.value.selection,
        const TextSelection(baseOffset: 0, extentOffset: 2),
      );
      expect(bridge.synchronized, isTrue);
    },
  );

  test('late sync reply cannot overwrite newer native edits', () async {
    final controller = TextEditingController(text: 'initial');
    final bridge = HomeNativeTextEditingBridge(
      owner: _owner,
      controller: controller,
    );
    final channel = _NativeChannel();
    final pending = Completer<Object?>();
    channel.reply = (call) => call.method == 'sync'
        ? pending.future
        : Future.value({'accepted': true, 'sequence': 0});
    addTearDown(() {
      bridge.dispose();
      controller.dispose();
    });
    bridge.attachView(1, channel: channel);
    await _flush();
    await channel.emit(_event(1, text: 'newer', caret: 5));
    channel.reply = null;
    pending.complete({
      'accepted': true,
      'sequence': 0,
      'focused': false,
      'value': _event(0, text: 'initial', caret: 7),
    });
    await _flush();
    expect(controller.text, 'newer');
    expect(bridge.sequence, 1);
    expect(bridge.synchronized, isTrue);
  });

  test(
    'detach retires handler and in-flight reply before replacement view',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final old = _NativeChannel();
      final pending = Completer<Object?>();
      old.reply = (call) =>
          call.method == 'sync' ? pending.future : Future.value(null);
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: old);
      final oldHandler = old.handler!;
      await _flush();
      bridge.detachView();
      final replacement = _NativeChannel();
      bridge.attachView(2, channel: replacement);
      await replacement.emit(_event(1, text: 'replacement', caret: 11));
      await oldHandler(
        MethodCall('editingEvent', _event(1, text: 'old callback')),
      );
      pending.complete({
        'accepted': true,
        'sequence': 0,
        'value': _event(0),
        'focused': false,
      });
      await _flush();
      expect(controller.text, 'replacement');
      expect(old.handler, isNull);
      expect(old.calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );

  test(
    'creation retires stale composing range but preserves visible text',
    () async {
      final controller = TextEditingController.fromValue(
        const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      final params = bridge.creationParams(fontSize: 16, dark: false);
      expect(params['text'], '拼音');
      expect(params['composingStart'], -1);
      bridge.attachView(1, channel: _NativeChannel());
      await _flush();
      expect(controller.text, '拼音');
      expect(controller.value.composing, TextRange.empty);
    },
  );

  test('focus and blur follow native receipts, not command optimism', () async {
    final controller = TextEditingController();
    final bridge = HomeNativeTextEditingBridge(
      owner: _owner,
      controller: controller,
    );
    final channel = _NativeChannel();
    addTearDown(() {
      bridge.dispose();
      controller.dispose();
    });
    bridge.attachView(1, channel: channel);
    await _flush();
    expect(await bridge.requestFocus(), isTrue);
    expect(bridge.hasFocus, isFalse);
    await channel.emit(_event(1, kind: 'focus'));
    expect(bridge.hasFocus, isTrue);
    await bridge.relinquishFocus();
    await channel.emit(_event(2, kind: 'blur'));
    expect(bridge.hasFocus, isFalse);
  });

  for (final entry in <String, Map<String, Object?>>{
    'text': _event(1, text: 'changed'),
    'selection': _event(1, text: 'ab', caret: 1),
    'zero-length composition': _event(
      1,
      text: 'ab',
      composingStart: 0,
      composingEnd: 0,
    ),
  }.entries) {
    test(
      'native ${entry.key} edit clears selection within the same attachment token',
      () async {
        final controller = TextEditingController.fromValue(
          const TextEditingValue(
            text: 'ab',
            selection: TextSelection.collapsed(offset: 0),
          ),
        );
        final bridge = HomeNativeTextEditingBridge(
          owner: _owner,
          controller: controller,
          attachmentSnapshot: _attachments(selectedId: 'B'),
        );
        final channel = _NativeChannel();
        addTearDown(() {
          bridge.dispose();
          controller.dispose();
        });
        bridge.attachView(1, channel: channel);
        await _flush();
        await channel.emit(entry.value);
        await _flush();
        expect(bridge.attachmentSnapshot.selectedId, isNull);
        expect(bridge.attachmentSnapshot.ids, ['A', 'B']);
        expect(bridge.attachmentSnapshot.token, 7);
        final sync = channel.calls.lastWhere((call) => call.method == 'sync');
        expect(
          ((sync.arguments as Map)['attachments'] as Map)['selectedId'],
          isNull,
        );
      },
    );
  }

  test(
    'layout metrics require current owner and increasing independent revision',
    () async {
      final controller = TextEditingController(text: 'draft');
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emitMetrics(_metrics(1, owner: 'other-account'));
      expect(bridge.metrics, isNull);
      await channel.emitMetrics(_metrics(1));
      expect(bridge.metrics?.revision, 1);
      expect(bridge.metrics?.width, 320);
      expect(bridge.metrics?.contentHeight, 96);
      expect(bridge.metrics?.lineHeight, 24);
      for (final staleOrInvalid in [
        _metrics(1, contentHeight: 500),
        _metrics(0),
        _metrics(2, width: 0),
        _metrics(2, contentHeight: double.nan),
        _metrics(2, lineHeight: -1),
        _metrics(2, owner: 'retired'),
      ]) {
        await channel.emitMetrics(staleOrInvalid);
        expect(bridge.metrics?.revision, 1);
        expect(bridge.metrics?.contentHeight, 96);
      }
      await channel.emitMetrics(_metrics(2, width: 280, contentHeight: 240));
      expect(bridge.metrics?.revision, 2);
      expect(bridge.metrics?.width, 280);
      expect(bridge.metrics?.contentHeight, 240);
      expect(bridge.sequence, 0);
      expect(controller.text, 'draft');
    },
  );

  test(
    'replacement view rejects captured old metrics handler with same owner',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final old = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: old);
      await _flush();
      final oldHandler = old.handler!;
      await old.emitMetrics(_metrics(9));
      final replacement = _NativeChannel();
      bridge.attachView(2, channel: replacement);
      await _flush();
      expect(bridge.metrics, isNull);
      await oldHandler(
        MethodCall('layoutMetrics', _metrics(100, contentHeight: 900)),
      );
      expect(bridge.metrics, isNull);
      await replacement.emitMetrics(_metrics(1, contentHeight: 48));
      expect(bridge.metrics?.revision, 1);
      expect(bridge.metrics?.contentHeight, 48);
      expect(bridge.sequence, 0);
      expect(old.handler, isNull);
    },
  );

  test(
    'semantic ARGB style sync preserves live native composition and focus',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.setStyle(
        fontSize: 16,
        dark: false,
        textColorArgb: 0xff183044,
        cursorColorArgb: 0xff005599,
        selectionColorArgb: 0x47005599,
      );
      final creation = bridge.creationParams(fontSize: 16, dark: false);
      expect(creation['textColorArgb'], 0xff183044);
      expect(creation['cursorColorArgb'], 0xff005599);
      expect(creation['selectionColorArgb'], 0x47005599);
      bridge.attachView(1, channel: channel);
      await _flush();
      final handler = channel.handler;
      await channel.emit(
        _event(
          1,
          kind: 'focus',
          text: 'ni',
          caret: 2,
          composingStart: 0,
          composingEnd: 2,
        ),
      );
      await _flush();
      final nativeValue = controller.value;
      bridge.setStyle(
        fontSize: 22,
        dark: true,
        textColorArgb: 0xffe0eeee,
        cursorColorArgb: 0xff156677,
        selectionColorArgb: 0x47156677,
      );
      await _flush();
      final sync =
          channel.calls.lastWhere((call) => call.method == 'sync').arguments
              as Map;
      expect(sync['fontSize'], 22.0);
      expect(sync['dark'], isTrue);
      expect(sync['textColorArgb'], 0xffe0eeee);
      expect(sync['cursorColorArgb'], 0xff156677);
      expect(sync['selectionColorArgb'], 0x47156677);
      expect(sync['text'], 'ni');
      expect(sync['selectionBase'], 2);
      expect(sync['composingStart'], 0);
      expect(sync['composingEnd'], 2);
      expect(controller.value, nativeValue);
      expect(bridge.hasFocus, isTrue);
      expect(bridge.synchronized, isTrue);
      expect(channel.handler, same(handler));
      expect(channel.calls.where((call) => call.method == 'dispose'), isEmpty);
    },
  );

  test(
    'commit and blur waits for final editing events after the native receipt',
    () async {
      final controller = TextEditingController();
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(
        _event(
          1,
          kind: 'focus',
          text: 'ni',
          caret: 2,
          composingStart: 0,
          composingEnd: 2,
        ),
      );
      await _flush();
      var blurRequested = false;
      channel.reply = (call) async {
        if (call.method == 'blur') {
          blurRequested = true;
          return {'accepted': true, 'sequence': 3};
        }
        return _ack(call, focused: channel.focused);
      };
      var completed = false;
      final committed = bridge.commitAndBlur().then((value) {
        completed = true;
        return value;
      });
      await _flush();
      expect(blurRequested, isTrue);
      expect(completed, isFalse);
      await channel.emit(_event(2, text: '你', caret: 1));
      expect(completed, isFalse);
      await channel.emit(_event(3, kind: 'blur', text: '你', caret: 1));
      expect(await committed, isTrue);
      expect(controller.text, '你');
      expect(controller.value.composing, TextRange.empty);
      expect(bridge.hasFocus, isFalse);
      expect(bridge.synchronized, isTrue);
    },
  );

  test(
    'invalid ranges and unknown commands never become canonical snapshots',
    () {
      expect(
        HomeNativeEditingEvent.parse({..._event(1), 'selectionBase': -1}),
        isNull,
      );
      expect(
        HomeNativeEditingEvent.parse({..._event(1), 'kind': 'send'}),
        isNull,
      );
      expect(
        HomeNativeEditingEvent.parse(
          _event(1, text: 'a', composingStart: 1, composingEnd: 0),
        ),
        isNull,
      );
      expect(
        HomeNativeEditingEvent.parse(_event(1, text: 'a', caret: 2)),
        isNull,
      );
    },
  );

  test(
    'zero-length native marked range rejects an attachment delete event',
    () async {
      final controller = TextEditingController();
      var deletes = 0;
      final bridge = HomeNativeTextEditingBridge(
        owner: _owner,
        controller: controller,
        attachmentSnapshot: _attachments(),
        onAttachmentCommand: (_) {
          deletes++;
          return null;
        },
      );
      final channel = _NativeChannel();
      addTearDown(() {
        bridge.dispose();
        controller.dispose();
      });
      bridge.attachView(1, channel: channel);
      await _flush();
      await channel.emit(_event(1, composingStart: 0, composingEnd: 0));
      await _flush();
      await channel.emit(
        _attachmentEvent(2, _attachments(), composingStart: 0, composingEnd: 0),
      );
      expect(deletes, 0);
      expect(bridge.sequence, 1);
      expect(bridge.errorCode, 'invalid_attachment_event');
      expect(controller.value.composing, const TextRange(start: 0, end: 0));
    },
  );
}
