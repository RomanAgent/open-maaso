import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An attachment editing chain. External draft changes issue a new token;
/// accepted native keystrokes advance the small snapshot under the same token.
final class HomeNativeAttachmentSnapshot {
  HomeNativeAttachmentSnapshot({
    required this.token,
    required Iterable<String> ids,
    this.selectedId,
    this.enabled = true,
  }) : ids = List.unmodifiable(ids) {
    if (token < 0 ||
        this.ids.length > 4 ||
        this.ids.any((id) => id.isEmpty || id.length > 256) ||
        this.ids.toSet().length != this.ids.length ||
        (selectedId != null && !this.ids.contains(selectedId))) {
      throw ArgumentError('Invalid native attachment snapshot');
    }
  }
  final int token;
  final List<String> ids;
  final String? selectedId;
  final bool enabled;

  Map<String, Object?> toJson() => {
    'token': token,
    'ids': ids,
    'selectedId': selectedId,
    'enabled': enabled,
  };

  bool sameAs(HomeNativeAttachmentSnapshot other) =>
      token == other.token &&
      enabled == other.enabled &&
      selectedId == other.selectedId &&
      _sameIds(ids, other.ids);

  bool admits(HomeNativeAttachmentCommand command) =>
      enabled &&
      command.snapshotToken == token &&
      _sameIds(ids, command.beforeIds) &&
      command.beforeSelectedId == selectedId &&
      (command.kind == HomeNativeEditingEventKind.boundaryDelete
          ? selectedId == null && ids.isNotEmpty && ids.last == command.targetId
          : command.kind ==
                    HomeNativeEditingEventKind.deleteSelectedAttachment &&
                selectedId == command.targetId &&
                ids.contains(command.targetId));

  HomeNativeAttachmentSnapshot apply(HomeNativeAttachmentCommand command) {
    if (!admits(command)) {
      throw StateError('stale_attachment_command');
    }
    return HomeNativeAttachmentSnapshot(
      token: token,
      enabled: enabled,
      ids: command.kind == HomeNativeEditingEventKind.boundaryDelete
          ? ids
          : ids.where((id) => id != command.targetId),
      selectedId: command.kind == HomeNativeEditingEventKind.boundaryDelete
          ? command.targetId
          : null,
    );
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

final class HomeNativeAttachmentCommand {
  const HomeNativeAttachmentCommand({
    required this.kind,
    required this.snapshotToken,
    required this.beforeIds,
    required this.beforeSelectedId,
    required this.targetId,
  });
  final HomeNativeEditingEventKind kind;
  final int snapshotToken;
  final List<String> beforeIds;
  final String? beforeSelectedId;
  final String targetId;

  static HomeNativeAttachmentCommand? parse(
    Object? raw,
    HomeNativeEditingEventKind kind,
  ) {
    if (raw is! Map ||
        raw['snapshotToken'] is! int ||
        raw['beforeIds'] is! List ||
        raw['targetId'] is! String ||
        (raw['beforeSelectedId'] != null &&
            raw['beforeSelectedId'] is! String)) {
      return null;
    }
    final ids = raw['beforeIds'] as List;
    if (ids.any((id) => id is! String)) {
      return null;
    }
    try {
      final before = HomeNativeAttachmentSnapshot(
        token: raw['snapshotToken'] as int,
        ids: ids.cast<String>(),
        selectedId: raw['beforeSelectedId'] as String?,
      );
      final command = HomeNativeAttachmentCommand(
        kind: kind,
        snapshotToken: before.token,
        beforeIds: before.ids,
        beforeSelectedId: before.selectedId,
        targetId: raw['targetId'] as String,
      );
      return before.admits(command) ? command : null;
    } on ArgumentError {
      return null;
    }
  }
}

final class HomeNativeTextMetrics {
  const HomeNativeTextMetrics({
    required this.revision,
    required this.width,
    required this.contentHeight,
    required this.lineHeight,
  });
  final int revision;
  final double width, contentHeight, lineHeight;

  static HomeNativeTextMetrics? parse(Object? raw, String owner) {
    if (raw is! Map ||
        raw['owner'] != owner ||
        raw['metricsRevision'] is! int) {
      return null;
    }
    final values = [raw['width'], raw['contentHeight'], raw['lineHeight']];
    if (values.any((v) => v is! num || !v.isFinite || v <= 0 || v > 100000)) {
      return null;
    }
    final revision = raw['metricsRevision'] as int;
    if (revision < 1) {
      return null;
    }
    return HomeNativeTextMetrics(
      revision: revision,
      width: (values[0] as num).toDouble(),
      contentHeight: (values[1] as num).toDouble(),
      lineHeight: (values[2] as num).toDouble(),
    );
  }
}

enum HomeNativeEditingEventKind {
  edit,
  boundaryDelete,
  deleteSelectedAttachment,
  focus,
  blur,
}

/// A full, genuine-text snapshot from one native editor instance.
final class HomeNativeEditingEvent {
  const HomeNativeEditingEvent({
    required this.owner,
    required this.sequence,
    required this.kind,
    required this.value,
    this.attachment,
  });

  final String owner;
  final int sequence;
  final HomeNativeEditingEventKind kind;
  final TextEditingValue value;
  final HomeNativeAttachmentCommand? attachment;

  static HomeNativeEditingEvent? parse(
    Object? raw, {
    bool allowInitialSequence = false,
  }) {
    if (raw is! Map) {
      return null;
    }
    final owner = raw['owner'];
    final sequence = raw['sequence'];
    final text = raw['text'];
    final base = raw['selectionBase'];
    final extent = raw['selectionExtent'];
    final composingStart = raw['composingStart'];
    final composingEnd = raw['composingEnd'];
    if (owner is! String ||
        owner.isEmpty ||
        sequence is! int ||
        sequence < (allowInitialSequence ? 0 : 1) ||
        text is! String ||
        base is! int ||
        extent is! int ||
        composingStart is! int ||
        composingEnd is! int ||
        base < 0 ||
        extent < 0 ||
        base > text.length ||
        extent > text.length) {
      return null;
    }
    final kind = HomeNativeEditingEventKind.values
        .where((kind) => kind.name == raw['kind'])
        .firstOrNull;
    if (kind == null) {
      return null;
    }
    final noComposition = composingStart == -1 && composingEnd == -1;
    if (!noComposition &&
        (composingStart < 0 ||
            composingEnd < composingStart ||
            composingEnd > text.length)) {
      return null;
    }
    return HomeNativeEditingEvent(
      owner: owner,
      sequence: sequence,
      kind: kind,
      attachment: HomeNativeAttachmentCommand.parse(raw['attachment'], kind),
      value: TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: base, extentOffset: extent),
        composing: noComposition
            ? TextRange.empty
            : TextRange(start: composingStart, end: composingEnd),
      ),
    );
  }
}

/// Mirrors an isolated native editor into an existing canonical controller.
///
/// Native editing wins over stale programmatic writes. The bridge introduces no
/// text tokens and does not attach a second Flutter text-input connection.
final class HomeNativeTextEditingBridge extends ChangeNotifier {
  HomeNativeTextEditingBridge({
    required this.owner,
    required this.controller,
    this.onAttachmentCommand,
    this.isCurrent,
    HomeNativeAttachmentSnapshot? attachmentSnapshot,
  }) : _attachments =
           attachmentSnapshot ??
           HomeNativeAttachmentSnapshot(
             token: 0,
             ids: const [],
             enabled: false,
           ) {
    if (owner.trim().isEmpty) {
      throw ArgumentError.value(owner, 'owner');
    }
    controller.addListener(_controllerChanged);
  }

  static const viewType = 'maaso/home_text_editor';

  /// Must change when the account or native editor incarnation is replaced.
  final String owner;
  final bool Function()? isCurrent;
  final TextEditingController controller;
  final HomeNativeAttachmentSnapshot? Function(HomeNativeAttachmentCommand)?
  onAttachmentCommand;
  MethodChannel? _channel;
  TextEditingValue? _nativeValue;
  int _connectionGeneration = 0;
  int _faultGeneration = 0;
  int _sequence = 0;
  bool _applyingNative = false;
  bool _syncQueued = false;
  bool _syncRunning = false;
  bool _disposed = false;
  bool _hasFocus = false;
  bool _enabled = true;
  double _fontSize = 16;
  bool _dark = false;
  int? _textColorArgb, _cursorColorArgb, _selectionColorArgb;
  HomeNativeAttachmentSnapshot _attachments;
  HomeNativeTextMetrics? _metrics;
  Completer<void>? _syncSettled;
  final _sequenceWaiters = <({int sequence, Completer<void> done})>[];
  String? _errorCode;
  String? lastAttachmentRejection;

  int get sequence => _sequence;
  bool get hasFocus => _hasFocus;
  bool get attached => _channel != null;
  bool get enabled => _enabled;
  bool get applyingNativeValue => _applyingNative;
  HomeNativeAttachmentSnapshot get attachmentSnapshot => _attachments;
  HomeNativeTextMetrics? get metrics => _metrics;
  String? get errorCode => _errorCode;
  bool get synchronized =>
      attached &&
      !_syncRunning &&
      !_syncQueued &&
      _nativeValue == controller.value &&
      _errorCode == null;

  Map<String, Object?> creationParams({
    required double fontSize,
    required bool dark,
  }) => {
    'owner': owner,
    ..._valueArguments(controller.value),
    'composingStart': -1,
    'composingEnd': -1,
    'attachments': _attachments.toJson(),
    'enabled': _enabled,
    'fontSize': fontSize,
    'dark': dark,
    ..._colors,
  };

  void attachView(int viewId, {MethodChannel? channel}) {
    if (_disposed) {
      return;
    }
    detachView();
    _sequence = 0;
    _metrics = null;
    _nativeValue = _normalizedSelection(
      controller.value,
    ).copyWith(composing: TextRange.empty);
    _applyNativeValue(_nativeValue!);
    _errorCode = null;
    final generation = _connectionGeneration;
    _channel = channel ?? MethodChannel('$viewType/$viewId');
    _channel!.setMethodCallHandler((call) async {
      if (_disposed ||
          isCurrent?.call() == false ||
          generation != _connectionGeneration) {
        return null;
      }
      if (call.method == 'layoutMetrics') {
        final next = HomeNativeTextMetrics.parse(call.arguments, owner);
        if (next != null && next.revision > (_metrics?.revision ?? 0)) {
          _metrics = next;
          notifyListeners();
        }
        return null;
      }
      if (call.method != 'editingEvent') {
        throw MissingPluginException();
      }
      _receive(call.arguments);
      return null;
    });
    _queueSync();
    notifyListeners();
  }

  void detachView() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    _connectionGeneration++;
    _channel = null;
    channel.setMethodCallHandler(null);
    unawaited(
      channel
          .invokeMethod<Object?>('dispose', {'owner': owner})
          .catchError((Object _) => null),
    );
    _syncQueued = false;
    _syncRunning = false;
    _nativeValue = null;
    _completeSettled();
    for (final waiter in _sequenceWaiters) {
      if (!waiter.done.isCompleted) {
        waiter.done.complete();
      }
    }
    _sequenceWaiters.clear();
    _hasFocus = false;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void setAttachmentSnapshot(HomeNativeAttachmentSnapshot snapshot) {
    if (_disposed || _attachments.sameAs(snapshot)) {
      return;
    }
    _attachments = snapshot;
    _queueSync();
  }

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) {
      return;
    }
    _enabled = enabled;
    _queueSync();
  }

  void setStyle({
    required double fontSize,
    required bool dark,
    int? textColorArgb,
    int? cursorColorArgb,
    int? selectionColorArgb,
  }) {
    if (_disposed) {
      return;
    }
    final boundedSize = fontSize.isFinite
        ? fontSize.clamp(10.0, 48.0).toDouble()
        : 16.0;
    if (_fontSize == boundedSize &&
        _dark == dark &&
        _textColorArgb == textColorArgb &&
        _cursorColorArgb == cursorColorArgb &&
        _selectionColorArgb == selectionColorArgb) {
      return;
    }
    _fontSize = boundedSize;
    _dark = dark;
    _textColorArgb = textColorArgb;
    _cursorColorArgb = cursorColorArgb;
    _selectionColorArgb = selectionColorArgb;
    _queueSync();
  }

  Future<bool> requestFocus() => _command('focus');
  Future<bool> relinquishFocus() => _command('blur');

  /// Waits for the native IME's final value before a typed send or voice entry.
  Future<bool> commitAndBlur() async {
    for (var attempt = 0; attempt < 3 && attached && !_disposed; attempt++) {
      _queueSync();
      await (_syncSettled?.future ?? Future<void>.value()).timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (!synchronized) {
        return false;
      }
      final before = _sequence;
      if (!await _command('blur')) {
        if (_sequence > before) continue;
        return false;
      }
      _queueSync();
      await (_syncSettled?.future ?? Future<void>.value()).timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      return synchronized &&
          !_hasFocus &&
          controller.value.composing == TextRange.empty;
    }
    return false;
  }

  Future<bool> _command(String method) async {
    final channel = _channel;
    final generation = _connectionGeneration;
    final faultGeneration = _faultGeneration;
    final sequence = _sequence;
    if (_disposed || channel == null) {
      return false;
    }
    try {
      final reply = await channel.invokeMethod<Object?>(method, {
        'owner': owner,
        'expectedSequence': _sequence,
      });
      if (reply is Map &&
          reply['accepted'] == true &&
          reply['sequence'] is int &&
          (reply['sequence'] as int) > _sequence &&
          generation == _connectionGeneration) {
        final done = Completer<void>();
        final waiter = (sequence: reply['sequence'] as int, done: done);
        _sequenceWaiters.add(waiter);
        await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
        _sequenceWaiters.remove(waiter);
        if (_sequence < waiter.sequence) {
          return false;
        }
      }
      return !_disposed &&
          generation == _connectionGeneration &&
          reply is Map &&
          reply['accepted'] == true;
    } on Object {
      if (!_disposed &&
          generation == _connectionGeneration &&
          faultGeneration == _faultGeneration &&
          sequence == _sequence) {
        _recordFault('native_command_failed');
      }
      return false;
    }
  }

  void _receive(Object? raw) {
    final event = HomeNativeEditingEvent.parse(raw);
    if (event == null) {
      _recordFault('invalid_native_event');
      return;
    }
    if (event.owner != owner || event.sequence <= _sequence) {
      return;
    }
    if (event.sequence != _sequence + 1) {
      _recordFault('native_sequence_gap');
      return;
    }
    final attachmentEvent =
        event.kind == HomeNativeEditingEventKind.boundaryDelete ||
        event.kind == HomeNativeEditingEventKind.deleteSelectedAttachment;
    if (attachmentEvent &&
        (event.value.composing != TextRange.empty ||
            event.attachment == null ||
            event.value != _nativeValue ||
            (event.kind == HomeNativeEditingEventKind.boundaryDelete &&
                (!event.value.selection.isCollapsed ||
                    event.value.selection.extentOffset != 0)))) {
      _recordFault('invalid_attachment_event');
      return;
    }
    _sequence = event.sequence;
    for (final waiter in _sequenceWaiters) {
      if (waiter.sequence <= _sequence && !waiter.done.isCompleted) {
        waiter.done.complete();
      }
    }
    if (attachmentEvent) {
      final command = event.attachment!;
      final before = _attachments;
      if (before.admits(command)) {
        final next = onAttachmentCommand?.call(command);
        if (next != null && next.sameAs(before.apply(command))) {
          _attachments = next;
          lastAttachmentRejection = null;
        } else {
          lastAttachmentRejection = 'draft_changed';
        }
      } else {
        lastAttachmentRejection = 'snapshot_changed';
      }
      notifyListeners();
      _queueSync();
      return;
    }
    if (event.kind == HomeNativeEditingEventKind.edit &&
        event.value != _nativeValue &&
        _attachments.selectedId != null) {
      _attachments = HomeNativeAttachmentSnapshot(
        token: _attachments.token,
        ids: _attachments.ids,
        enabled: _attachments.enabled,
      );
    }
    _nativeValue = event.value;
    _errorCode = null;
    _applyNativeValue(event.value);
    if (event.kind == HomeNativeEditingEventKind.focus) {
      _hasFocus = true;
    }
    if (event.kind == HomeNativeEditingEventKind.blur) {
      _hasFocus = false;
    }
    notifyListeners();
    // The native side predicts selection between rapid presses; acknowledge the
    // actual Flutter attachment state after processing each ordered event.
    _queueSync();
  }

  void _applyNativeValue(TextEditingValue value) {
    if (_disposed || isCurrent?.call() == false) {
      return;
    }
    _applyingNative = true;
    try {
      controller.value = value;
    } finally {
      _applyingNative = false;
    }
  }

  void _controllerChanged() {
    if (_applyingNative || _disposed) {
      return;
    }
    if (_nativeValue case final native?
        when controller.value.composing != native.composing) {
      _applyNativeValue(native);
      _recordFault('programmatic_composition_rejected');
      return;
    }
    _queueSync();
  }

  void _queueSync() {
    if (_disposed || _channel == null) {
      return;
    }
    _syncQueued = true;
    _syncSettled ??= Completer<void>();
    if (!_syncRunning) {
      scheduleMicrotask(_flushSync);
    }
  }

  void _recordFault(String code) {
    _faultGeneration++;
    _errorCode = code;
    // A rejected receive does not advance the native sequence. Invalidate older
    // acknowledgments separately so they cannot erase this newer failure.
    _syncQueued = false;
    notifyListeners();
  }

  Future<void> _flushSync() async {
    final channel = _channel;
    if (_disposed || channel == null || _syncRunning || !_syncQueued) {
      return;
    }
    final generation = _connectionGeneration;
    final faultGeneration = _faultGeneration;
    final sequence = _sequence;
    final desired = _normalizedSelection(controller.value);
    _syncQueued = false;
    _syncRunning = true;
    try {
      final reply = await channel.invokeMethod<Object?>('sync', {
        'owner': owner,
        'expectedSequence': sequence,
        ..._valueArguments(desired),
        'attachments': _attachments.toJson(),
        'enabled': _enabled,
        'fontSize': _fontSize,
        'dark': _dark,
        ..._colors,
      });
      if (_disposed ||
          isCurrent?.call() == false ||
          generation != _connectionGeneration ||
          faultGeneration != _faultGeneration) {
        return;
      }
      if (_sequence == sequence) {
        final acceptedValue = reply is Map
            ? HomeNativeEditingEvent.parse(
                reply['value'],
                allowInitialSequence: true,
              )
            : null;
        if (reply is Map &&
            reply['accepted'] == true &&
            reply['sequence'] == sequence &&
            acceptedValue?.owner == owner &&
            acceptedValue?.sequence == sequence) {
          _nativeValue = acceptedValue!.value;
          if (controller.value == desired ||
              _normalizedSelection(controller.value) == desired) {
            _applyNativeValue(acceptedValue.value);
          }
          if (reply['focused'] is bool) {
            _hasFocus = reply['focused'] as bool;
          }
          _errorCode = null;
        } else {
          // Do not queue an old programmatic draft to overwrite ongoing IME
          // composition. Restore the last native snapshot and report rejection.
          if (_nativeValue case final value?) {
            _applyNativeValue(value);
          }
          _recordFault('native_sync_rejected');
        }
      }
    } on Object {
      if (!_disposed &&
          generation == _connectionGeneration &&
          faultGeneration == _faultGeneration &&
          sequence == _sequence) {
        _recordFault('native_sync_failed');
      }
    } finally {
      if (!_disposed && generation == _connectionGeneration) {
        _syncRunning = false;
        notifyListeners();
        if (_syncQueued) {
          scheduleMicrotask(_flushSync);
        } else
          _completeSettled();
      }
    }
  }

  void _completeSettled() {
    final settled = _syncSettled;
    _syncSettled = null;
    if (settled != null && !settled.isCompleted) {
      settled.complete();
    }
  }

  Map<String, Object?> get _colors => {
    if (_textColorArgb != null) 'textColorArgb': _textColorArgb,
    if (_cursorColorArgb != null) 'cursorColorArgb': _cursorColorArgb,
    if (_selectionColorArgb != null) 'selectionColorArgb': _selectionColorArgb,
  };

  static TextEditingValue _normalizedSelection(TextEditingValue value) =>
      value.selection.isValid
      ? value
      : value.copyWith(
          selection: TextSelection.collapsed(offset: value.text.length),
        );

  static Map<String, Object?> _valueArguments(TextEditingValue raw) {
    final value = _normalizedSelection(raw);
    return {
      'text': value.text,
      'selectionBase': value.selection.baseOffset,
      'selectionExtent': value.selection.extentOffset,
      'composingStart': value.composing.start,
      'composingEnd': value.composing.end,
    };
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    controller.removeListener(_controllerChanged);
    detachView();
    super.dispose();
  }
}
