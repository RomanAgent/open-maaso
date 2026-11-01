import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/application/home_native_text_editing_bridge.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_native_text_editor.dart';

/// Real Home bridge fixture: platform text events cross its MethodChannel.
/// This models the native protocol, not UITextView rendering or a real IME.
class HomeNativeEditorHarness {
  // Platform view creation order and exact owner identity are observable in tests.
  int get creationCount => _created;
  int _created = 0;
  final _editors = <int, _Editor>{};
  final calls = <MethodCall>[];
  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() => _messenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    handlePlatformCall,
  );

  Future<Object?> handlePlatformCall(MethodCall call) async {
    if (call.method != 'create') return null;
    final args = call.arguments as Map;
    if (args['viewType'] != HomeNativeTextEditingBridge.viewType) return null;
    final raw = args['params'];
    final params =
        const StandardMessageCodec().decodeMessage(
              raw is ByteData ? raw : ByteData.sublistView(raw as Uint8List),
            )
            as Map;
    final id = args['id'] as int;
    final editor = _Editor(Map<String, Object?>.from(params));
    _editors[id] = editor;
    _created++;
    final channel = MethodChannel(
      '${HomeNativeTextEditingBridge.viewType}/$id',
    );
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final body = Map<String, Object?>.from(call.arguments as Map);
      if (call.method == 'dispose') {
        editor.retired = true;
        return null;
      }
      if (editor.retired || body['owner'] != editor.value['owner'])
        return {'accepted': false, 'sequence': editor.sequence};
      if (body['expectedSequence'] != editor.sequence)
        return {'accepted': false, 'sequence': editor.sequence};
      if (call.method == 'sync') {
        editor.value.addAll(body);
        await _metrics(id, editor);
      } else if (call.method == 'blur' || call.method == 'focus') {
        editor.focused = call.method == 'focus';
        if (call.method == 'blur') {
          editor.value['composingStart'] = -1;
          editor.value['composingEnd'] = -1;
        }
        await _event(id, editor, kind: call.method);
      }
      return {
        'accepted': true,
        'sequence': editor.sequence,
        'focused': editor.focused,
        'value': _eventValue(editor, 'edit'),
      };
    });
    return null;
  }

  Map<String, Object?> _eventValue(_Editor editor, String kind) => {
    for (final name in [
      'owner',
      'text',
      'selectionBase',
      'selectionExtent',
      'composingStart',
      'composingEnd',
    ])
      name: editor.value[name],
    'sequence': editor.sequence,
    'kind': kind,
  };

  Future<void> _deliver(
    int id,
    String method,
    Map<String, Object?> body,
  ) async {
    final done = Completer<void>();
    _messenger.handlePlatformMessage(
      '${HomeNativeTextEditingBridge.viewType}/$id',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, body)),
      (_) => done.complete(),
    );
    await done.future;
  }

  Future<void> _event(
    int id,
    _Editor editor, {
    String kind = 'edit',
    Map<String, Object?>? attachment,
  }) async {
    editor.sequence++;
    await _deliver(id, 'editingEvent', {
      ..._eventValue(editor, kind),
      if (attachment != null) 'attachment': attachment,
    });
  }

  Future<void> _metrics(int id, _Editor editor) async {
    editor.metrics++;
    await _deliver(id, 'layoutMetrics', {
      'owner': editor.value['owner'],
      'metricsRevision': editor.metrics,
      'width': 300.0,
      'contentHeight': math.max(
        32.0,
        (editor.value['text'] as String).split('\n').length * 24.0,
      ),
      'lineHeight': 24.0,
    });
  }

  MapEntry<int, _Editor> get _active =>
      _editors.entries.lastWhere((entry) => !entry.value.retired);

  Future<void> enterText(
    WidgetTester tester,
    String text, {
    TextSelection? selection,
    TextRange composing = TextRange.empty,
  }) async {
    if (find.byType(HomeNativeTextEditor).evaluate().isEmpty) {
      await tester.enterText(
        find.byKey(const ValueKey('home-composer-editor')),
        text,
      );
      return;
    }
    final active = _active, editor = active.value;
    if (!editor.focused) {
      editor.focused = true;
      await _event(active.key, editor, kind: 'focus');
    }
    editor.value.addAll({
      'text': text,
      'selectionBase': selection?.baseOffset ?? text.length,
      'selectionExtent': selection?.extentOffset ?? text.length,
      'composingStart': composing.start,
      'composingEnd': composing.end,
    });
    await _event(active.key, editor);
    await _metrics(active.key, editor);
    await tester.pump();
  }

  Future<void> focus() async {
    final active = _active;
    active.value.focused = true;
    await _event(active.key, active.value, kind: 'focus');
  }

  Future<void> blur() async {
    final active = _active;
    active.value.focused = false;
    active.value.value['composingStart'] = -1;
    active.value.value['composingEnd'] = -1;
    await _event(active.key, active.value, kind: 'blur');
  }

  Future<void> deleteAtBoundary(WidgetTester tester) async {
    final active = _active, editor = active.value;
    final snapshot = Map<String, Object?>.from(
      editor.value['attachments'] as Map,
    );
    final ids = List<String>.from(snapshot['ids'] as List);
    final selected = snapshot['selectedId'] as String?;
    final kind = selected == null
        ? 'boundaryDelete'
        : 'deleteSelectedAttachment';
    final target = selected ?? ids.last;
    editor.value['attachments'] = {
      ...snapshot,
      'ids': selected == null ? ids : ids.where((id) => id != target).toList(),
      'selectedId': selected == null ? target : null,
    };
    await _event(
      active.key,
      editor,
      kind: kind,
      attachment: {
        'snapshotToken': snapshot['token'],
        'beforeIds': ids,
        'beforeSelectedId': selected,
        'targetId': target,
      },
    );
    await tester.pump();
  }

  void dispose() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final id in _editors.keys) {
      _messenger.setMockMethodCallHandler(
        MethodChannel('${HomeNativeTextEditingBridge.viewType}/$id'),
        null,
      );
    }
    _editors.clear();
  }
}

class _Editor {
  _Editor(this.value);
  final Map<String, Object?> value;
  int sequence = 0, metrics = 0;
  bool focused = false, retired = false;
}
